#!/bin/sh
# Bootstrap a brand-new machine over SSH from this one, using this
# machine's own SSH identity via agent forwarding to solve the
# chicken-and-egg problem of install.sh needing SSH access to clone
# the private repo before it has restored any SSH key of its own.
#
# Usage: dj-setup.sh [user@]hostname [extra install.sh args...]
#   dj setup yolo
#   dj setup kevin@yolo --system-type server --theme '#2596be'
#
# What it does:
#   1. Ensures a reachable ssh-agent with this machine's shared
#      identity (~/.ssh/id_ed25519) loaded, starting one if needed.
#   2. Resolves this machine's own private-repo remote URL (from
#      ~/.config.git) so the target doesn't need it spelled out by
#      hand, then pushes this machine's own age key to a temp path on
#      the target via a plain scp (one fewer round trip and prompt
#      than making the target dial back out via --sops); the temp
#      copy is removed after install.sh finishes, success or failure.
#   3. Resolves the raw install.sh URL from ~/.dotfiles' own origin
#      remote + current branch, so a fork just works without editing
#      this script.
#   4. Runs install.sh on the target via `ssh -A -t`: the forwarded
#      agent covers the private-repo clone (the age key was already
#      pushed directly in step 2, so no --sops round trip is needed
#      for that part).
#
# This whole run is one deliberate, explicitly-initiated bootstrap, so
# every never-before-seen host it touches -- the target itself, and,
# on the target, install.sh's own private-repo clone -- skips the
# interactive host-key confirmation prompt via
# StrictHostKeyChecking=accept-new (a *changed* host key is still
# rejected, same as always; only *new* ones are auto-trusted).
#
# Any extra arguments (--system-type, --theme, --on-conflict, ...) are
# passed through to the remote install.sh unchanged and safely
# re-quoted -- naively string-joining them would let something like
# --theme '#2596be' get truncated as a comment by the remote shell.

set -eu

DOTFILES_DIR=${DOTFILES_DIR:-$HOME/.dotfiles}
DOT_DIR=${DOT_DIR:-$HOME/.config.git}
SSH_KEY=$HOME/.ssh/id_ed25519

log() { printf '[dj-setup] %s\n' "$*"; }

if [ $# -lt 1 ]; then
  printf 'usage: dj-setup.sh [user@]hostname [extra install.sh args...]\n' >&2
  exit 2
fi

HOSTSPEC=$1
shift

if [ ! -r "$SSH_KEY" ]; then
  printf 'error: no SSH key at %s -- nothing to forward\n' "$SSH_KEY" >&2
  exit 1
fi

# ---------- 0. Prompt for --system-type if the caller didn't pass one ------
#
# install.sh silently defaults to a common-only install when
# --system-type is omitted, which is easy to do by accident here and
# not what you want for a real machine. If it's missing, ask -- listing
# this machine's own known types (from ~/.config/dj/packages/types/)
# as a hint -- rather than silently propagating the omission. A blank
# answer (including non-interactive stdin, which reads as EOF/empty)
# keeps the common-only default.

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
        printf '[dj-setup] known system types:\n' >&2
        _have_known_types=1
      fi
      printf '  - %s\n' "$(basename "$_f" .txt)" >&2
    done
  fi
  printf '[dj-setup] system type for %s [blank = common-only]: ' "$HOSTSPEC" >&2
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
#
# First choice is claude, best-effort: skip straight to the random
# fallback below on any failure (claude missing, no `timeout` binary
# to bound it, a non-hex or empty response, an actual timeout) rather
# than risk blocking or hanging an otherwise-unattended bootstrap.
# Only claude is attempted here -- its non-interactive `-p` query is
# the same invocation already relied on elsewhere in this repo (the
# `claude` Justfile recipe), so it's a known-good contract. agy/
# opencode's exact non-interactive query syntax isn't confidently
# known, and guessing wrong risks a hang the timeout can't fully guard
# against (e.g. if it drops into an interactive prompt that itself
# ignores the outer timeout's signal) -- not attempted.
#
# If claude didn't produce one either, generate a random hex color --
# unlike the claude attempt, this tier always succeeds, so every
# machine ends up with *some* distinct accent color instead of
# falling through to install.sh's single shared #2596be default.

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
      # /dev/urandom missing/unreadable (shouldn't happen on any OS
      # this repo targets, but this tier must always succeed): fall
      # back to awk's rand(), seeded from pid + time.
      _rand_hex=$(awk -v seed="$$$(date +%s)" 'BEGIN { srand(seed); printf "%06x", int(rand() * 16777216) }')
    fi
    _generated_theme="#$_rand_hex"
    log "no theme from claude; generated a random one for $HOSTSPEC: $_generated_theme"
  fi
  set -- "$@" --theme "$_generated_theme"
fi

# Single-quote a value for safe embedding in a reconstructed shell
# command line: close the quote, emit an escaped literal quote, reopen.
q() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# This whole run is one deliberate, explicitly-initiated bootstrap, so
# skip the interactive "authenticity of host ... can't be established"
# yes/no prompt for every never-before-seen host it touches: the
# target itself (below) and, on the target, git.kevinfinity.com-style
# private-repo hosts (via DOTFILES_ACCEPT_NEW_HOSTS, exported into the
# remote command further down). StrictHostKeyChecking=accept-new, not
# =no: a *changed* host key is still rejected, same as always -- only
# *new* ones are auto-trusted.
SSH_ACCEPT_NEW="-o StrictHostKeyChecking=accept-new"

# ---------- 1. Ensure a reachable ssh-agent with the shared key loaded -----

rc=0
ssh-add -l >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  log "no reachable ssh-agent; starting one"
  eval "$(ssh-agent -s)" >/dev/null
fi

FPR=$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')
if [ -z "$FPR" ] || ! ssh-add -l 2>/dev/null | grep -qF "$FPR"; then
  ssh-add "$SSH_KEY"
fi

# ---------- 2. This machine's own private-repo remote ----------------------

PRIVATE_REMOTE_NAME=$(git --git-dir="$DOT_DIR" remote 2>/dev/null | head -n1)
if [ -z "$PRIVATE_REMOTE_NAME" ]; then
  printf 'error: %s has no remote configured -- wire one up first (dot remote add ...)\n' "$DOT_DIR" >&2
  exit 1
fi
PRIVATE_REPO_URL=$(git --git-dir="$DOT_DIR" remote get-url "$PRIVATE_REMOTE_NAME")

# ---------- 2b. Push this machine's age key to a temp path on the target ---
#
# install.sh also supports --sops [user@]host to have the *target*
# scp the key back from here -- but since we're already about to have
# a live, authenticated connection to the target (that's how step 4's
# ssh -A -t works at all), pushing it there ourselves up front is one
# fewer round trip and one fewer credential prompt than making the
# target dial back out to us. The temp copy is removed after
# install.sh runs, success or failure, by the trailing cleanup in the
# remote command built below.

AGE_KEY_LOCAL=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt
if [ ! -r "$AGE_KEY_LOCAL" ]; then
  printf 'error: no age key at %s -- nothing to push for secrets decryption\n' "$AGE_KEY_LOCAL" >&2
  exit 1
fi
REMOTE_TMP_KEY="/tmp/dj-setup-agekey-$$"
scp -q $SSH_ACCEPT_NEW "$AGE_KEY_LOCAL" "$HOSTSPEC:$REMOTE_TMP_KEY"

# ---------- 2c. Push the git-host deploy key the same way ------------------
#
# The target's very first private-repo clone happens before the
# tracked ~/.ssh/config (which points ssh at this key for that host)
# has been checked out, so the key has to arrive out of band exactly
# like the age key does. Optional: without one, the clone falls back
# to whatever the forwarded agent offers.

GIT_KEY_LOCAL=$HOME/.ssh/id_githost
REMOTE_TMP_GITKEY=
if [ -r "$GIT_KEY_LOCAL" ]; then
  REMOTE_TMP_GITKEY="/tmp/dj-setup-gitkey-$$"
  scp -q $SSH_ACCEPT_NEW "$GIT_KEY_LOCAL" "$HOSTSPEC:$REMOTE_TMP_GITKEY"
else
  log "no deploy key at $GIT_KEY_LOCAL; the target's clone will rely on the forwarded agent"
fi

# ---------- 3. Raw install.sh URL, derived from ~/.dotfiles' own origin ----

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

# ---------- 4. Build the remote command and run it over a forwarded agent --

# install.sh is fetched via curl, but a genuinely fresh machine may not
# have it yet -- install it first via whatever package manager is
# present, same env vars as install.sh's own apt path (avoids
# needrestart's interactive dialog on Debian/Ubuntu).
ENSURE_CURL='command -v curl >/dev/null 2>&1 || \
{ command -v apt-get >/dev/null 2>&1 && sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y curl; } || \
{ command -v pacman >/dev/null 2>&1 && sudo pacman -Sy --noconfirm curl; } || \
{ command -v brew >/dev/null 2>&1 && brew install curl; } || \
{ printf "error: curl is missing and no known package manager was found\n" >&2; exit 1; }'

MAIN_CMD="$ENSURE_CURL && curl -fsSL $(q "$RAW_INSTALL_URL") | sh -s -- --private-repo $(q "$PRIVATE_REPO_URL") --age-key $(q "$REMOTE_TMP_KEY")"
[ -n "$REMOTE_TMP_GITKEY" ] \
  && MAIN_CMD="$MAIN_CMD --git-key $(q "$REMOTE_TMP_GITKEY")"
for arg in "$@"; do
  MAIN_CMD="$MAIN_CMD $(q "$arg")"
done

# Clean up both pushed keys afterward regardless of outcome, while
# preserving install.sh's own exit status rather than masking it with
# the cleanup command's.
CLEANUP="rc=\$?"
for _tmp in "$REMOTE_TMP_KEY" ${REMOTE_TMP_GITKEY:+"$REMOTE_TMP_GITKEY"}; do
  CLEANUP="$CLEANUP; shred -u $(q "$_tmp") 2>/dev/null || rm -f $(q "$_tmp")"
done
CLEANUP="$CLEANUP; exit \$rc"
# DOTFILES_ACCEPT_NEW_HOSTS: see the comment above SSH_ACCEPT_NEW --
# this is what makes install.sh apply the same accept-new treatment to
# its own private-repo clone, connecting out from the target.
REMOTE_CMD="export DOTFILES_ACCEPT_NEW_HOSTS=1; { $MAIN_CMD; }; $CLEANUP"

log "bootstrapping $HOSTSPEC (private-repo=$PRIVATE_REPO_URL)"
ssh -A -t $SSH_ACCEPT_NEW "$HOSTSPEC" "$REMOTE_CMD"
