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
  _known_types=
  if [ -d "$TYPES_DIR" ]; then
    for _f in "$TYPES_DIR"/*.txt; do
      [ -e "$_f" ] || continue
      _b=$(basename "$_f" .txt)
      _known_types="${_known_types:+$_known_types, }$_b"
    done
  fi
  printf '[dj-setup] system type for %s%s [blank = common-only]: ' \
    "$HOSTSPEC" "${_known_types:+ (known: $_known_types)}" >&2
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
for arg in "$@"; do
  MAIN_CMD="$MAIN_CMD $(q "$arg")"
done

# Clean up the pushed age key afterward regardless of outcome, while
# preserving install.sh's own exit status rather than masking it with
# the cleanup command's.
CLEANUP="rc=\$?; shred -u $(q "$REMOTE_TMP_KEY") 2>/dev/null || rm -f $(q "$REMOTE_TMP_KEY"); exit \$rc"
# DOTFILES_ACCEPT_NEW_HOSTS: see the comment above SSH_ACCEPT_NEW --
# this is what makes install.sh apply the same accept-new treatment to
# its own private-repo clone, connecting out from the target.
REMOTE_CMD="export DOTFILES_ACCEPT_NEW_HOSTS=1; { $MAIN_CMD; }; $CLEANUP"

log "bootstrapping $HOSTSPEC (private-repo=$PRIVATE_REPO_URL)"
ssh -A -t $SSH_ACCEPT_NEW "$HOSTSPEC" "$REMOTE_CMD"
