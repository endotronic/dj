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
#      ~/.config.git) and its own [user@]host (for --sops) so the
#      target doesn't need either spelled out by hand.
#   3. Resolves the raw install.sh URL from ~/.dotfiles' own origin
#      remote + current branch, so a fork just works without editing
#      this script.
#   4. Runs install.sh on the target via `ssh -A -t`: the forwarded
#      agent covers both the private-repo clone AND the --sops scp
#      fetch back to this machine (same shared identity, already
#      authorized on both ends per this repo's cross-machine SSH
#      trust setup).
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

# Single-quote a value for safe embedding in a reconstructed shell
# command line: close the quote, emit an escaped literal quote, reopen.
q() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

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

# ---------- 2. This machine's own private-repo remote and identity ---------

PRIVATE_REMOTE_NAME=$(git --git-dir="$DOT_DIR" remote 2>/dev/null | head -n1)
if [ -z "$PRIVATE_REMOTE_NAME" ]; then
  printf 'error: %s has no remote configured -- wire one up first (dot remote add ...)\n' "$DOT_DIR" >&2
  exit 1
fi
PRIVATE_REPO_URL=$(git --git-dir="$DOT_DIR" remote get-url "$PRIVATE_REMOTE_NAME")

SOPS_SRC="$(id -un)@$(hostname -s 2>/dev/null || uname -n)"

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

REMOTE_CMD="curl -fsSL $(q "$RAW_INSTALL_URL") | sh -s -- --private-repo $(q "$PRIVATE_REPO_URL") --sops $(q "$SOPS_SRC")"
for arg in "$@"; do
  REMOTE_CMD="$REMOTE_CMD $(q "$arg")"
done

log "bootstrapping $HOSTSPEC (private-repo=$PRIVATE_REPO_URL sops=$SOPS_SRC)"
ssh -A -t "$HOSTSPEC" "$REMOTE_CMD"
