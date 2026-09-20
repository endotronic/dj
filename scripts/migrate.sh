#!/bin/sh
# Detect -- and where it's safe, repair -- persistent machine state
# that newer versions of this project expect but that an older
# bootstrap left stale or never created.
#
# Pulling new code does NOT retroactively fix machine state. When
# install.sh starts setting up something new (a git config, a derived
# file, a renamed key), machines bootstrapped before that commit keep
# running without it, usually silently. This script is where those
# one-time catch-up repairs live.
#
# Usage:
#   migrate.sh            report status; exit 1 if anything is pending
#   migrate.sh --fix      apply the auto-fixable repairs, then re-check
#   migrate.sh --list     list known migrations and exit
#   migrate.sh --only ID  restrict to one migration (repeatable)
#
# Each migration is a (check, fix) pair. check exits:
#   0 = already satisfied      1 = pending      2 = N/A on this machine
#
# Some migrations are MANUAL: detected but never auto-applied, because
# the repair rotates a credential, removes software, or needs a
# decision a script shouldn't make on your behalf. Those print the
# exact commands instead of running them.
#
# Every auto-fix must be idempotent: running --fix twice is a no-op the
# second time, and running it on a machine that never had the problem
# does nothing.
#
# DOT_DIR, DOTFILES_REPO_ROOT and DOTFILES_BACKUP_DIR are overridable
# for tests.

set -eu

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
REPO_ROOT=${DOTFILES_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}

TMUX_MIN_MAJOR=3
TMUX_MIN_MINOR=4

FIX=0
LIST=0
ONLY=''

while [ $# -gt 0 ]; do
  case "$1" in
    --fix)    FIX=1 ;;
    --list)   LIST=1 ;;
    --only)   shift; ONLY="$ONLY ${1:?--only needs a migration id}" ;;
    --only=*) ONLY="$ONLY ${1#*=}" ;;
    -h|--help)
      sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

log() { printf '        %s\n' "$*"; }

dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

# Lazily created, shared by every migration that displaces a file.
backup_dir() {
  if [ -z "${_MIG_BACKUP:-}" ]; then
    _MIG_BACKUP=${DOTFILES_BACKUP_DIR:-$HOME/.dotfiles-backup/$(date -u +%Y%m%dT%H%M%SZ)}
    mkdir -p "$_MIG_BACKUP"
  fi
  printf '%s' "$_MIG_BACKUP"
}

# Every known migration, in the order they should run.
MIGRATIONS='git-refspec dotfiles-origin-ssh ssh-pubkey ssh-machine-identity
            legacy-tmux-conf tmux-version pending-packages postinstall-hooks
            agy-installed'

# Migrations that are detected but never auto-applied.
MANUAL_MIGRATIONS='ssh-machine-identity postinstall-hooks'

migration_desc() {
  case "$1" in
    git-refspec)          echo "private bare repo has origin/* refs and branch tracking" ;;
    dotfiles-origin-ssh)  echo "~/.dotfiles origin is a pushable ssh remote" ;;
    ssh-pubkey)           echo "this machine's SSH public key exists beside its private key" ;;
    ssh-machine-identity) echo "machine SSH identity is distinct from the shared git-host key" ;;
    legacy-tmux-conf)     echo "no legacy ~/.tmux.conf shadowing the tracked config" ;;
    tmux-version)         echo "tmux is new enough for clickable status buttons (>= 3.4)" ;;
    pending-packages)     echo "every package in the active lists is installed" ;;
    postinstall-hooks)    echo "every listed post-install hook has a script" ;;
    agy-installed)        echo "agy (antigravity) is installed, as the package list asks" ;;
    *)                    echo "(unknown migration: $1)" ;;
  esac
}

is_manual() {
  for _m in $MANUAL_MIGRATIONS; do
    [ "$_m" = "$1" ] && return 0
  done
  return 1
}

ssh_fp() {
  ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'
}

# ---------- git-refspec ----------
#
# `git clone --bare` deliberately writes no remote.origin.fetch and no
# branch.<b>.remote/merge: a bare repo is normally a server-side
# mirror, so git assumes you don't want a copy-of-a-copy origin/*
# namespace inside it. This project uses a bare repo as a working
# checkout of $HOME, so we do want both.
#
# Without the refspec, fetch has nowhere to record what it saw except
# FETCH_HEAD (one transient file, overwritten every fetch), so
# origin/master never exists: no ahead/behind, and no
# `origin/master..master` ranges to ask what's unpushed. `dj sync`
# still works (pull --rebase falls back to FETCH_HEAD), which is
# exactly why this stays invisible until the day you need it.

check_git_refspec() {
  [ -d "$DOT_DIR" ] || return 2
  dot remote get-url origin >/dev/null 2>&1 || return 2
  [ -n "$(dot config --get-all remote.origin.fetch 2>/dev/null || true)" ] || return 1
  _b=$(dot symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$_b" ]; then
    [ -n "$(dot config --get "branch.$_b.remote" 2>/dev/null || true)" ] || return 1
  fi
  return 0
}

fix_git_refspec() {
  if [ -z "$(dot config --get-all remote.origin.fetch 2>/dev/null || true)" ]; then
    dot config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    log "set remote.origin.fetch on $DOT_DIR"
  fi
  _b=$(dot symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$_b" ]; then
    dot config "branch.$_b.remote" origin
    dot config "branch.$_b.merge" "refs/heads/$_b"
    log "set upstream tracking: $_b -> origin/$_b"
  fi
  # Populate the refs now so origin/* exists immediately; an offline
  # machine still gets the config and fills in on its next sync.
  if dot fetch origin >/dev/null 2>&1; then
    log "fetched origin"
  else
    log "warn: could not reach origin; config is set and populates on next sync"
  fi
}

# ---------- dotfiles-origin-ssh ----------
#
# install.sh step 13b: https is what lets the very first clone work
# with zero credentials, but it can never push. Once ~/.ssh/id_githost
# exists there's no reason to keep it. Machines bootstrapped before
# 13b landed still carry the https remote and fail to push.

dotfiles_origin() { git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true; }

check_dotfiles_origin_ssh() {
  [ -r "$HOME/.ssh/id_githost" ] || return 2
  _o=$(dotfiles_origin)
  [ -n "$_o" ] || return 2
  case "$_o" in
    http://*|https://*) return 1 ;;
  esac
  return 0
}

fix_dotfiles_origin_ssh() {
  _o=$(dotfiles_origin)
  _rest=${_o#*://}
  _host=${_rest%%/*}
  _path=${_rest#*/}
  [ "$_host" != "$_rest" ] && [ -n "$_path" ] || {
    log "warn: cannot parse origin URL: $_o"
    return 1
  }
  git -C "$REPO_ROOT" remote set-url origin "git@$_host:$_path"
  log "rewrote origin: $_o -> git@$_host:$_path"
}

# ---------- ssh-pubkey ----------
#
# Machines publish their identity as ~/.ssh/authorized_keys.d/
# <hostname>.pub (§5.3), which authorized-keys.sh copies from
# ~/.ssh/id_ed25519.pub. Bootstraps predating that convention left
# only the private key, so registration silently logged "nothing of
# our own to register" and the machine never joined the trust set.

check_ssh_pubkey() {
  [ -f "$HOME/.ssh/id_ed25519" ] || return 2
  [ -f "$HOME/.ssh/id_ed25519.pub" ] || return 1
  return 0
}

fix_ssh_pubkey() {
  command -v ssh-keygen >/dev/null 2>&1 || {
    log "warn: ssh-keygen not found; cannot derive the public key"
    return 1
  }
  # -P '' so a passphrase-protected key fails outright rather than
  # blocking on a prompt in a non-interactive run.
  if ssh-keygen -y -P '' -f "$HOME/.ssh/id_ed25519" > "$HOME/.ssh/id_ed25519.pub" 2>/dev/null; then
    chmod 644 "$HOME/.ssh/id_ed25519.pub"
    log "derived ~/.ssh/id_ed25519.pub from the private key"
    log "next: dj authorized-keys    (registers + commits this machine)"
  else
    rm -f "$HOME/.ssh/id_ed25519.pub"
    log "warn: could not derive the public key (passphrase-protected?)"
    log "warn: by hand: ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub"
    return 1
  fi
}

# ---------- ssh-machine-identity (MANUAL) ----------
#
# §5.3.1 splits two concerns that used to share one key: this
# machine's own identity (~/.ssh/id_ed25519, generated locally, never
# distributed) and git-host access (~/.ssh/id_githost, one shared key
# in the manifest). A machine bootstrapped under the old
# one-key-copied-everywhere model has the SAME key in both slots --
# and once it registers itself in authorized_keys.d, it publishes the
# shared forge key as its machine identity to every other machine,
# which is precisely what §5.3 exists to prevent.
#
# MANUAL because the repair rotates a credential: until every other
# machine has synced the new pluto.pub, outbound SSH from here to them
# stops working. Inbound SSH and git-host access are unaffected.

check_ssh_machine_identity() {
  [ -f "$HOME/.ssh/id_ed25519" ] || return 2
  [ -f "$HOME/.ssh/id_githost" ] || return 2
  _a=$(ssh_fp "$HOME/.ssh/id_ed25519")
  _b=$(ssh_fp "$HOME/.ssh/id_githost")
  [ -n "$_a" ] && [ -n "$_b" ] || return 2
  [ "$_a" = "$_b" ] && return 1
  return 0
}

fix_ssh_machine_identity() {
  log "This machine's SSH identity IS the shared git-host key:"
  log "  $(ssh_fp "$HOME/.ssh/id_ed25519")"
  log "so ~/.ssh/authorized_keys.d/$(hostname -s).pub publishes the forge key"
  log "to every other machine (§5.3 exists to prevent exactly this)."
  log ""
  log "Rotating is safe but not silent -- until your other machines run"
  log "dj sync, outbound ssh from here to them will fail. Inbound ssh and"
  log "git-host access are unaffected. To rotate:"
  log ""
  log "  bk=\"\$HOME/.dotfiles-backup/\$(date -u +%Y%m%dT%H%M%SZ)/.ssh\"; mkdir -p \"\$bk\""
  log "  mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub \"\$bk\"/"
  log "  ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519 \\"
  log "      -C \"\$(id -un)@\$(hostname -s) (machine identity)\""
  log "  dj authorized-keys && dot push"
}

# ---------- legacy-tmux-conf ----------
#
# install.sh step 7b backs these up, but only during install. tmux
# loads ~/.tmux.conf in addition to -- and before -- the tracked
# ~/.config/tmux/tmux.conf, at a path the conflict-aware checkout
# never walks (it only visits tracked paths), so a hand-written
# pre-dotfiles ~/.tmux.conf otherwise coexists forever.

check_legacy_tmux_conf() {
  [ -f "$HOME/.config/tmux/tmux.conf" ] || return 2
  for _f in "$HOME"/.tmux.conf*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    return 1
  done
  return 0
}

fix_legacy_tmux_conf() {
  _bk=$(backup_dir)
  for _f in "$HOME"/.tmux.conf*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    mv "$_f" "$_bk/"
    log "backed up $_f -> $_bk/"
  done
  log "restart the tmux server (tmux kill-server) to drop it from memory"
}

# ---------- tmux-version ----------
#
# tmux.conf's clickable status-bar buttons (NEW / <-- / -->) use the
# range=user style and #{mouse_status_range}, both new in tmux 3.4. On
# an older tmux the config still loads and the buttons simply do
# nothing -- no error, no hint. The repair defers to the tmux-backports
# post-install hook, which upgrades from <codename>-backports on Debian
# and deliberately no-ops elsewhere.

tmux_version_str() { tmux -V 2>/dev/null | awk '{print $2}'; }

tmux_version_ge_min() {
  _v=$(tmux_version_str)
  [ -n "$_v" ] || return 1
  _v=${_v#next-}
  _v=$(printf '%s' "$_v" | sed 's/[^0-9.].*//')   # "3.2a" -> "3.2"
  _maj=${_v%%.*}
  _min=${_v#*.}
  _min=${_min%%.*}
  [ "$_min" = "$_v" ] && _min=0
  [ -n "$_maj" ] || return 1
  [ -n "$_min" ] || _min=0
  case "$_maj$_min" in *[!0-9]*) return 1 ;; esac
  [ "$(( _maj * 100 + _min ))" -ge "$(( TMUX_MIN_MAJOR * 100 + TMUX_MIN_MINOR ))" ]
}

check_tmux_version() {
  command -v tmux >/dev/null 2>&1 || return 2
  tmux_version_ge_min || return 1
  return 0
}

fix_tmux_version() {
  _hook="$REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ -f "$_hook" ] || {
    log "warn: $_hook not found; cannot upgrade tmux automatically"
    return 1
  }
  sh "$_hook" || true
  if tmux_version_ge_min; then
    log "tmux upgraded to $(tmux_version_str)"
    log "restart the tmux server (tmux kill-server) to pick it up"
    return 0
  fi
  # Debian is the only distro the hook can upgrade; elsewhere -- notably
  # Ubuntu, whose -backports pocket carries no newer tmux -- there is no
  # package-manager path, and saying so beats pretending.
  log "tmux is $(tmux_version_str); no apt/pacman/brew upgrade path on this"
  log "distro. tmux.conf's clickable status buttons (NEW / <-- / -->) stay"
  log "inert below ${TMUX_MIN_MAJOR}.${TMUX_MIN_MINOR}; everything else in it works normally."
  return 1
}

# ---------- pending-packages ----------
#
# The personal package lists travel via `dj sync`, but pulling a list
# doesn't install anything -- that's `dj install-packages`, which needs
# sudo and so is deliberately not part of sync. A machine can therefore
# sit for months with packages listed but absent.

pending_package_line() {
  sh "$REPO_ROOT/scripts/install-packages.sh" --dry-run 2>/dev/null \
    | sed -n 's/^.*to install: \(.*\)$/\1/p' | head -1
}

check_pending_packages() {
  [ -f "$REPO_ROOT/scripts/install-packages.sh" ] || return 2
  _p=$(pending_package_line)
  [ -n "$_p" ] || return 0
  return 1
}

fix_pending_packages() {
  log "installing: $(pending_package_line)"
  sh "$REPO_ROOT/scripts/install-packages.sh"
}

# ---------- postinstall-hooks (MANUAL) ----------
#
# A name in ~/.config/dj/postinstall/*.txt with no matching
# packages/postinstall/<name>.sh makes run-postinstall.sh warn and exit
# non-zero on every run, so `dj upgrade` never ends clean. MANUAL
# because the fix is a decision -- write the hook, or drop the entry.

check_postinstall_hooks() {
  [ -f "$REPO_ROOT/scripts/run-postinstall.sh" ] || return 2
  sh "$REPO_ROOT/scripts/run-postinstall.sh" --dry-run >/dev/null 2>&1 || return 1
  return 0
}

fix_postinstall_hooks() {
  sh "$REPO_ROOT/scripts/run-postinstall.sh" --dry-run 2>&1 >/dev/null \
    | sed 's/^/        /' || true
  log ""
  log "Either write the hook (packages/postinstall/<name>.sh, POSIX sh,"
  log "idempotent, + bats coverage per CLAUDE.md §2.8), or drop the name"
  log "from ~/.config/dj/postinstall/ and commit with dot."
}

# ---------- agy-installed ----------
#
# agy is SKIP in every renames file and has no packages/scripts/agy.sh
# fallback, so install-packages silently passes over it -- only
# install.sh knows to run install-antigravity.sh. A machine that got
# `agy` by pulling the list rather than by bootstrapping never has it.

agy_listed() {
  for _l in "$HOME/.config/dj/packages/common.txt" \
            "$HOME/.config/dj/packages/types/${DOTFILES_SYSTEM_TYPE:-none}.txt" \
            "$HOME/.config/dj/packages/hosts/$(hostname -s 2>/dev/null || hostname).txt"; do
    [ -f "$_l" ] || continue
    grep -qx 'agy' "$_l" 2>/dev/null && return 0
  done
  return 1
}

check_agy_installed() {
  agy_listed || return 2
  [ -f "$REPO_ROOT/scripts/install-antigravity.sh" ] || return 2
  command -v agy >/dev/null 2>&1 || return 1
  return 0
}

fix_agy_installed() {
  sh "$REPO_ROOT/scripts/install-antigravity.sh"
  if command -v gemini >/dev/null 2>&1; then
    log "note: the superseded gemini CLI is still installed; remove with"
    log "      sudo npm -g rm @google/gemini-cli"
  fi
}

# ---------- dispatch ----------

run_check() {
  case "$1" in
    git-refspec)          check_git_refspec ;;
    dotfiles-origin-ssh)  check_dotfiles_origin_ssh ;;
    ssh-pubkey)           check_ssh_pubkey ;;
    ssh-machine-identity) check_ssh_machine_identity ;;
    legacy-tmux-conf)     check_legacy_tmux_conf ;;
    tmux-version)         check_tmux_version ;;
    pending-packages)     check_pending_packages ;;
    postinstall-hooks)    check_postinstall_hooks ;;
    agy-installed)        check_agy_installed ;;
    *) return 2 ;;
  esac
}

run_fix() {
  case "$1" in
    git-refspec)          fix_git_refspec ;;
    dotfiles-origin-ssh)  fix_dotfiles_origin_ssh ;;
    ssh-pubkey)           fix_ssh_pubkey ;;
    ssh-machine-identity) fix_ssh_machine_identity ;;
    legacy-tmux-conf)     fix_legacy_tmux_conf ;;
    tmux-version)         fix_tmux_version ;;
    pending-packages)     fix_pending_packages ;;
    postinstall-hooks)    fix_postinstall_hooks ;;
    agy-installed)        fix_agy_installed ;;
    *) return 1 ;;
  esac
}

selected() {
  [ -z "$ONLY" ] && return 0
  for _s in $ONLY; do
    [ "$_s" = "$1" ] && return 0
  done
  return 1
}

if [ "$LIST" -eq 1 ]; then
  for m in $MIGRATIONS; do
    if is_manual "$m"; then _tag='manual'; else _tag='auto'; fi
    printf '%-22s %-7s %s\n' "$m" "$_tag" "$(migration_desc "$m")"
  done
  exit 0
fi

pending=0
manual=0
failed=0

for m in $MIGRATIONS; do
  selected "$m" || continue
  status=0
  run_check "$m" || status=$?
  case "$status" in
    0) printf '  ok      %s\n' "$(migration_desc "$m")" ;;
    2) : ;;  # not applicable here -- stay silent
    *)
      if is_manual "$m"; then
        printf '  MANUAL  %s\n' "$(migration_desc "$m")"
        run_fix "$m" || true
        manual=$((manual + 1))
      elif [ "$FIX" -eq 1 ]; then
        printf '  fixing  %s\n' "$(migration_desc "$m")"
        _ok=0
        run_fix "$m" || _ok=$?
        recheck=0
        run_check "$m" || recheck=$?
        if [ "$_ok" -eq 0 ] && [ "$recheck" -eq 0 ]; then
          printf '  ok      %s\n' "$(migration_desc "$m")"
        else
          failed=$((failed + 1))
        fi
      else
        printf '  MIGR    %s\n' "$(migration_desc "$m")"
        printf '          repair: dj migrate --fix --only %s\n' "$m"
        pending=$((pending + 1))
      fi
      ;;
  esac
done

echo
if [ "$pending" -gt 0 ]; then
  printf '[migrate] %s pending migration(s) -- repair with: dj migrate --fix\n' "$pending"
fi
if [ "$manual" -gt 0 ]; then
  printf '[migrate] %s migration(s) need a decision (see above); not auto-applied\n' "$manual"
fi
if [ "$failed" -gt 0 ]; then
  printf '[migrate] %s migration(s) could not be completed\n' "$failed"
fi
if [ "$((pending + manual + failed))" -eq 0 ]; then
  printf '[migrate] machine state is up to date\n'
  exit 0
fi
exit 1
