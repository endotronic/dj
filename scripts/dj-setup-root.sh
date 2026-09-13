#!/bin/sh
# Add a new admin user to an existing machine, over SSH as root, then
# bootstrap this project into a brand-new home directory for them --
# or, if the account already exists, into whatever home directory it
# already has, with install.sh's normal conflict-aware checkout.
#
# Usage: dj-setup-root.sh hostname [extra install.sh args...]
#   dj setup-root lobos
#   dj setup-root lobos --system-type server --theme '#2596be'
#
# The new account's username is always this machine's own invoking
# user (`id -un`) -- the same name `dj setup` would use if it were run
# for that account directly. There is no username flag: this script
# is specifically "give me my own account on that box," not a general
# user-creation tool.
#
# What it does, all over one root SSH connection (multiplexed so any
# password is only typed once):
#   1. Checks whether the user already exists on the target (its
#      package manager is detected either way -- apt vs pacman differ
#      in admin-group name, "sudo" vs "wheel").
#      - If not: creates the account with useradd, explicitly skipping
#        /etc/skel (--skel /dev/null) since this project's own
#        install.sh populates the home directory instead.
#      - If it does: its home directory and identity are used as-is.
#      Either way, an account with no usable password (a brand-new one,
#      or one left over from an earlier interrupted/pre-fix run of this
#      very script) has no way to answer sudo's own password prompt, so
#      it's given what a fresh account needs: sudo itself installed if
#      the host doesn't have it at all (root-only appliance images like
#      Proxmox typically don't, since root never needed it), admin-group
#      membership, and a narrow, temporary NOPASSWD rule via a single
#      /etc/sudoers.d drop-in scoped to just this username -- removed
#      again at the very end, success or failure. An account that
#      already has a real password is left alone, same as pointing
#      `dj setup` at it directly.
#   2. Pushes this machine's own age key (required) and git-host
#      deploy key (optional -- a warning is printed if it's missing,
#      same as dj-setup.sh) directly into the target user's home
#      directory and chowns them to that user, since there is no
#      agent-forwarding path into a `su -` session to rely on instead.
#   3. Runs install.sh as that user via `su - USER -c '...'` -- not a
#      second `ssh` hop, since the fresh account has no password or
#      authorized key of its own yet to authenticate one with. `su -`
#      resets $HOME (and everything else) to the target account's own,
#      so install.sh's normal $HOME-relative logic just works.
#
# Unlike dj-setup.sh, this script does not forward this machine's own
# SSH agent (-A): su -l resets the environment, and even if
# SSH_AUTH_SOCK survived, the socket's permissions wouldn't let the
# new, different local user read it. The git-host key is pushed
# directly instead (step 2), same as dj-setup.sh's own non-agent
# fallback path.
#
# Nor does it register the target in ~/.ssh/config the way dj-setup.sh
# does: that registration is keyed by hostname, and a machine that
# already has one user on it is presumably already registered --
# registering it again here would be redundant, and wrong for a
# username that isn't part of the tmux menu's addressing at all.

set -eu

log() { printf '[dj-setup-root] %s\n' "$*"; }

if [ $# -lt 1 ]; then
  printf 'usage: dj-setup-root.sh hostname [extra install.sh args...]\n' >&2
  exit 2
fi

HOSTSPEC=$1
shift

case "$HOSTSPEC" in
  root@*) TARGET_HOST=${HOSTSPEC#root@} ;;
  *@*)
    printf 'error: dj-setup-root.sh always connects as root -- got %s. Use dj setup for an existing non-root account.\n' "$HOSTSPEC" >&2
    exit 2
    ;;
  *) TARGET_HOST=$HOSTSPEC ;;
esac
ROOT_HOSTSPEC="root@$TARGET_HOST"

TARGET_USER=$(id -un)

# ---------- 0. Prompt for --system-type if the caller didn't pass one ------
# Same rationale and behavior as dj-setup.sh: install.sh silently
# defaults to a common-only install when this is omitted, which is
# easy to do by accident here too.

_has_system_type=0
for _arg in "$@"; do
  case "$_arg" in
    --system-type|--system-type=*) _has_system_type=1 ;;
  esac
done

if [ "$_has_system_type" -eq 0 ]; then
  TYPES_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/dj/packages/types
  _have_known_types=0
  if [ -d "$TYPES_DIR" ]; then
    for _f in "$TYPES_DIR"/*.txt; do
      [ -e "$_f" ] || continue
      if [ "$_have_known_types" -eq 0 ]; then
        printf '[dj-setup-root] known system types:\n' >&2
        _have_known_types=1
      fi
      printf '  - %s\n' "$(basename "$_f" .txt)" >&2
    done
  fi
  printf '[dj-setup-root] system type for %s [blank = common-only]: ' "$HOSTSPEC" >&2
  read -r _system_type_answer || _system_type_answer=
  case "$_system_type_answer" in
    '') ;;
    *[!A-Za-z0-9_-]*)
      printf 'error: system type must contain only letters, digits, _ and - (got: %s)\n' \
        "$_system_type_answer" >&2
      exit 2
      ;;
    *)
      set -- "$@" --system-type "$_system_type_answer"
      ;;
  esac
fi

# ---------- 0b. Determine --theme if omitted: claude, else random ----------
# Identical strategy to dj-setup.sh -- see its comments for the full
# rationale. Kept in lockstep deliberately rather than shared, since
# duplicating this one self-contained block is cheaper than the
# indirection of a sourced lib for two call sites.

_has_theme=0
for _arg in "$@"; do
  case "$_arg" in
    --theme|--theme=*) _has_theme=1 ;;
  esac
done

if [ "$_has_theme" -eq 0 ]; then
  _generated_theme=
  if command -v claude >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    _theme_prompt="Respond with ONLY a 6-digit hex color code (like #2596be) and nothing else -- no explanation, no markdown -- that you associate with or that is evocative of the word \"$HOSTSPEC\" (for example, what a similar-sounding color name suggests). If nothing specific comes to mind, pick any pleasant accent color."
    _generated_theme=$(timeout 20 claude -p "$_theme_prompt" 2>/dev/null | grep -oE '#[0-9a-fA-F]{6}' | head -n1) || _generated_theme=
  fi
  if [ -n "$_generated_theme" ]; then
    log "generated tmux theme color for $HOSTSPEC via claude: $_generated_theme"
  else
    _rand_hex=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [ -z "$_rand_hex" ]; then
      _rand_hex=$(awk -v seed="$$$(date +%s)" 'BEGIN { srand(seed); printf "%06x", int(rand() * 16777216) }')
    fi
    _generated_theme="#$_rand_hex"
    log "no theme from claude; generated a random one for $HOSTSPEC: $_generated_theme"
  fi
  set -- "$@" --theme "$_generated_theme"
fi

# Single-quote a value for safe embedding in a reconstructed shell
# command line -- see dj-setup.sh for the same helper and rationale.
q() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ---------- 0c. Multiplex all connections to the target over one auth ------
# Same rationale as dj-setup.sh: several separate ssh/scp calls below
# would otherwise each prompt for root's password on their own.

SSH_ACCEPT_NEW="-o StrictHostKeyChecking=accept-new"
CTL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dj-setup-root-ctl.XXXXXX")
CTL_PATH="$CTL_DIR/control"
SSH_MUX="-o ControlMaster=auto -o ControlPath=$CTL_PATH -o ControlPersist=10m"
SSH_OPTS="$SSH_ACCEPT_NEW $SSH_MUX"
cleanup_mux() {
  ssh -o ControlPath="$CTL_PATH" -O exit "$ROOT_HOSTSPEC" >/dev/null 2>&1 || true
  rm -rf "$CTL_DIR"
}
trap cleanup_mux EXIT

# ---------- 1. This machine's own private-repo remote -----------------------

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
PRIVATE_REMOTE_NAME=$(git --git-dir="$DOT_DIR" remote 2>/dev/null | head -n1)
if [ -z "$PRIVATE_REMOTE_NAME" ]; then
  printf 'error: %s has no remote configured -- wire one up first (dot remote add ...)\n' "$DOT_DIR" >&2
  exit 1
fi
PRIVATE_REPO_URL=$(git --git-dir="$DOT_DIR" remote get-url "$PRIVATE_REMOTE_NAME")

AGE_KEY_LOCAL=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt
if [ ! -r "$AGE_KEY_LOCAL" ]; then
  printf 'error: no age key at %s -- nothing to push for secrets decryption\n' "$AGE_KEY_LOCAL" >&2
  exit 1
fi
GIT_KEY_LOCAL=$HOME/.ssh/id_githost

# ---------- 2. Raw install.sh URL, derived from ~/.dotfiles' own origin -----

DOTFILES_DIR=${DOTFILES_DIR:-$HOME/.dotfiles}
ORIGIN=$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null || true)
BRANCH=$(git -C "$DOTFILES_DIR" branch --show-current 2>/dev/null || true)
BRANCH=${BRANCH:-master}
case "$ORIGIN" in
  git@github.com:*)     REPO_PATH=${ORIGIN#git@github.com:} ;;
  https://github.com/*) REPO_PATH=${ORIGIN#https://github.com/} ;;
  *)                    REPO_PATH= ;;
esac
REPO_PATH=${REPO_PATH%.git}
if [ -n "$REPO_PATH" ]; then
  RAW_INSTALL_URL="https://raw.githubusercontent.com/$REPO_PATH/$BRANCH/install.sh"
else
  RAW_INSTALL_URL=${DOTFILES_REPO_RAW_URL:-https://raw.githubusercontent.com/endotronic/dj/master/install.sh}
fi

# ---------- 3. Check for / create the account on the target -----------------
#
# Run as root, non-interactively: prints CREATED=0|1 and HOME_DIR=...
# on success. Distro handling genuinely differs here -- Debian/Ubuntu
# (apt) and Arch (pacman) name their sudo-capable group differently
# ("sudo" vs "wheel") -- so the target's own package manager is
# detected remotely rather than assumed from this machine's.
#
# --skel /dev/null deliberately skips /etc/skel: this project's own
# install.sh (run next, as this new user) populates the home directory
# instead, so a distro-default .bashrc etc. would just be clutter to
# back up and discard during install.sh's own conflict-aware checkout.
USER_CHECK_BODY=$(cat <<'BODY'
set -eu
USERNAME=$1

if   command -v apt    >/dev/null 2>&1; then PKG_MGR=apt;    ADMIN_GROUP=sudo
elif command -v pacman >/dev/null 2>&1; then PKG_MGR=pacman; ADMIN_GROUP=wheel
else
  printf 'error: no supported package manager found on target (expected apt or pacman)\n' >&2
  exit 1
fi

CREATED=0
if id -u "$USERNAME" >/dev/null 2>&1; then
  HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)
else
  CREATED=1
  SHELL_BIN=/bin/bash
  command -v bash >/dev/null 2>&1 || SHELL_BIN=/bin/sh
  HOME_DIR="/home/$USERNAME"
  useradd --create-home --home-dir "$HOME_DIR" --skel /dev/null --shell "$SHELL_BIN" "$USERNAME"
fi

# A locked/passwordless account has no way to answer sudo's own
# password prompt, so it needs the same temporary NOPASSWD grant a
# fresh account gets -- whether it's actually fresh (CREATED=1), or a
# leftover from an earlier, interrupted or pre-fix run of this very
# script (CREATED=0 but never finished being provisioned). A
# pre-existing account with a real password already has its own
# working sudo access and is left untouched, same as `dj setup` would.
NEEDS_SUDO_SETUP=$CREATED
if [ "$NEEDS_SUDO_SETUP" = 0 ]; then
  case "$(passwd -S "$USERNAME" 2>/dev/null | awk '{print $2}')" in
    L|NP|'') NEEDS_SUDO_SETUP=1 ;;
  esac
fi

if [ "$NEEDS_SUDO_SETUP" = 1 ]; then
  # Appliance-style root-only images (Proxmox included) often ship
  # with no sudo binary at all, since root itself never needed one
  # there -- but this account does, to run install.sh's own
  # privileged steps (package installs, etc.). Install it now, while
  # still root, rather than deferring straight to the no-sudo warning
  # further down.
  if ! command -v sudo >/dev/null 2>&1; then
    # `apt-get update` alone commonly exits non-zero here (e.g.
    # Proxmox's enterprise/ceph repos 401ing without a paid
    # subscription) even though the repo that actually has `sudo`
    # refreshed fine -- so its failure must not block the install
    # that follows.
    case "$PKG_MGR" in
      apt)    { apt-get update -qq || true; } && apt-get install -y sudo ;;
      pacman) pacman -Sy --noconfirm sudo ;;
    esac || printf 'warn: failed to install sudo on this host -- will fall back to a NOPASSWD-less warning\n' >&2
  fi

  if getent group "$ADMIN_GROUP" >/dev/null 2>&1; then
    usermod -aG "$ADMIN_GROUP" "$USERNAME"
    if [ "$ADMIN_GROUP" = wheel ] && ! grep -qE '^[^#]*%wheel[[:space:]]' /etc/sudoers 2>/dev/null; then
      printf 'warn: %%wheel is not enabled in /etc/sudoers -- uncomment it for %s to use sudo normally afterward\n' "$USERNAME" >&2
    fi
  else
    printf 'warn: no %s group on this host -- %s was not added to any admin group\n' "$ADMIN_GROUP" "$USERNAME" >&2
  fi

  # Scoped to just this username via its own sudoers.d drop-in --
  # removed again by dj-setup-root.sh's final cleanup, success or
  # failure, once the bootstrap under this user finishes.
  if command -v sudo >/dev/null 2>&1; then
    SUDOERS_DROPIN="/etc/sudoers.d/dj-setup-root-$USERNAME"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USERNAME" > "$SUDOERS_DROPIN"
    chmod 0440 "$SUDOERS_DROPIN"
    visudo -cf "$SUDOERS_DROPIN" || { rm -f "$SUDOERS_DROPIN"; printf 'error: generated sudoers drop-in failed validation\n' >&2; exit 1; }
  else
    printf 'warn: no sudo on this host -- install.sh steps that need it will fail for %s\n' "$USERNAME" >&2
  fi
fi

printf 'CREATED=%s\nHOME_DIR=%s\n' "$CREATED" "$HOME_DIR"
BODY
)
USER_CHECK_CMD="sh -c $(q "$USER_CHECK_BODY") -- $(q "$TARGET_USER")"

log "checking/creating $TARGET_USER@$TARGET_HOST"
USER_CHECK_OUT=$(ssh $SSH_OPTS "$ROOT_HOSTSPEC" "$USER_CHECK_CMD")
CREATED=$(printf '%s\n' "$USER_CHECK_OUT" | sed -n 's/^CREATED=//p')
REMOTE_HOME=$(printf '%s\n' "$USER_CHECK_OUT" | sed -n 's/^HOME_DIR=//p')
if [ -z "$REMOTE_HOME" ]; then
  printf 'error: could not determine home directory for %s@%s\n' "$TARGET_USER" "$TARGET_HOST" >&2
  exit 1
fi
if [ "$CREATED" = 1 ]; then
  log "created $TARGET_USER on $TARGET_HOST (home: $REMOTE_HOME)"
else
  log "$TARGET_USER already exists on $TARGET_HOST (home: $REMOTE_HOME) -- bootstrapping in place"
fi
SUDOERS_DROPIN="/etc/sudoers.d/dj-setup-root-$TARGET_USER"

# ---------- 4. Push the age key (and git-host key, if present) --------------
#
# Pushed directly into the target user's own home and chowned to them,
# since there is no agent-forwarding path into the `su -` session
# below to rely on instead (see the header comment).

REMOTE_AGEKEY="$REMOTE_HOME/.dj-setup-root-agekey"
scp -q $SSH_OPTS "$AGE_KEY_LOCAL" "$ROOT_HOSTSPEC:$REMOTE_AGEKEY"

REMOTE_GITKEY=
if [ -r "$GIT_KEY_LOCAL" ]; then
  REMOTE_GITKEY="$REMOTE_HOME/.dj-setup-root-gitkey"
  scp -q $SSH_OPTS "$GIT_KEY_LOCAL" "$ROOT_HOSTSPEC:$REMOTE_GITKEY"
else
  log "no deploy key at $GIT_KEY_LOCAL; the target's private-repo clone may have no credentials"
fi

CHOWN_CMD="chown $(q "$TARGET_USER") $(q "$REMOTE_AGEKEY") && chmod 600 $(q "$REMOTE_AGEKEY")"
[ -n "$REMOTE_GITKEY" ] && CHOWN_CMD="$CHOWN_CMD && chown $(q "$TARGET_USER") $(q "$REMOTE_GITKEY") && chmod 600 $(q "$REMOTE_GITKEY")"
ssh $SSH_OPTS "$ROOT_HOSTSPEC" "$CHOWN_CMD"

# ---------- 5. Run install.sh as the target user, via su - ------------------
#
# `su - USER -c '...'` rather than a second ssh hop: a freshly created
# account has no password or authorized key yet to SSH in with, and
# `su -` gives install.sh exactly what it needs anyway ($HOME and
# everything else reset to the target account's own).

ENSURE_CURL='command -v curl >/dev/null 2>&1 || \
{ command -v apt-get >/dev/null 2>&1 && { sudo apt-get update || true; } && sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y curl; } || \
{ command -v pacman >/dev/null 2>&1 && sudo pacman -Sy --noconfirm curl; } || \
{ printf "error: curl is missing and no known package manager was found\n" >&2; exit 1; }'

INNER_CMD="export DOTFILES_ACCEPT_NEW_HOSTS=1; $ENSURE_CURL && curl -fsSL $(q "$RAW_INSTALL_URL") | sh -s -- --private-repo $(q "$PRIVATE_REPO_URL") --age-key $(q "$REMOTE_AGEKEY")"
[ -n "$REMOTE_GITKEY" ] && INNER_CMD="$INNER_CMD --git-key $(q "$REMOTE_GITKEY")"
for arg in "$@"; do
  INNER_CMD="$INNER_CMD $(q "$arg")"
done
INNER_CLEANUP="rc=\$?; shred -u $(q "$REMOTE_AGEKEY") 2>/dev/null || rm -f $(q "$REMOTE_AGEKEY")"
[ -n "$REMOTE_GITKEY" ] && INNER_CLEANUP="$INNER_CLEANUP; shred -u $(q "$REMOTE_GITKEY") 2>/dev/null || rm -f $(q "$REMOTE_GITKEY")"
INNER_CMD="{ $INNER_CMD; }; $INNER_CLEANUP; exit \$rc"

SU_CMD="su - $(q "$TARGET_USER") -c $(q "$INNER_CMD")"
# Always attempt the sudoers drop-in removal, whether or not this run
# created it (a pre-existing account never had one, so this is a
# harmless no-op for it) -- and regardless of install.sh's own outcome.
REMOTE_CMD="{ $SU_CMD; }; rc=\$?; rm -f $(q "$SUDOERS_DROPIN") 2>/dev/null; exit \$rc"

log "bootstrapping $TARGET_USER@$TARGET_HOST (private-repo=$PRIVATE_REPO_URL)"
ssh -t $SSH_OPTS "$ROOT_HOSTSPEC" "$REMOTE_CMD"
