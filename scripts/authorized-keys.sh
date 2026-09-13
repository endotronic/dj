#!/bin/sh
# Assemble ~/.ssh/authorized_keys from the per-machine public keys in
# ~/.ssh/authorized_keys.d/, and register this machine's own public
# key there if it isn't already present.
#
# Usage: authorized-keys.sh [--no-register]
#   --no-register   rebuild only; don't add this machine's own key.
#                   Used by `dj sync`, where the only new material is
#                   other machines' keys arriving from the repo.
#
# Registering this machine's own key also commits it (message: "Add
# SSH public key for <hostname>") -- but deliberately does NOT push;
# that stays a separate, explicit step so a newly bootstrapped machine
# never pushes to the private repo on its own.
#
# Why a directory of <hostname>.pub files instead of one tracked
# authorized_keys: each machine only ever writes its own file and
# never touches anyone else's, so two machines bootstrapping in
# parallel can't produce a merge conflict, and revoking a machine is
# `rm ~/.ssh/authorized_keys.d/<host>.pub` + push rather than an edit
# to a file everyone else is also editing. authorized_keys itself is
# a build artifact -- deliberately NOT tracked, rebuilt here from
# whatever .d entries exist.
#
# This replaces the older model where one SSH *private* key was
# distributed to every machine through the secrets manifest: one
# compromised machine meant one key valid on every machine and every
# git host at once. Now each machine's private key stays put and only
# public keys travel (see CLAUDE.md §5.3).

set -eu

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
SSH_DIR=$HOME/.ssh
KEYS_D=$SSH_DIR/authorized_keys.d
AUTH_KEYS=$SSH_DIR/authorized_keys
PUBKEY=$SSH_DIR/id_ed25519.pub
BACKUP_DIR=${BACKUP_DIR:-$HOME/.dotfiles-backup/$(date -u +%Y%m%dT%H%M%SZ)}

REGISTER=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-register) REGISTER=0 ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

log() { printf '[authorized-keys] %s\n' "$*"; }
dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

mkdir -p "$KEYS_D"
chmod 700 "$SSH_DIR" "$KEYS_D"

# ---------- 1. Register this machine's own public key ----------

if [ "$REGISTER" -eq 1 ]; then
  if [ ! -r "$PUBKEY" ]; then
    log "no public key at $PUBKEY yet; nothing of our own to register"
  else
    _host=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo unknown)
    _mine=$KEYS_D/$_host.pub
    if [ -f "$_mine" ] && cmp -s "$PUBKEY" "$_mine"; then
      log "this machine ($_host) is already registered"
    else
      cp "$PUBKEY" "$_mine"
      chmod 644 "$_mine"
      log "registered this machine's public key as authorized_keys.d/$_host.pub"
      if [ -d "$DOT_DIR" ]; then
        if dot add "$_mine" 2>/dev/null; then
          if dot commit -m "Add SSH public key for $_host" >/dev/null; then
            log "committed -- push (dot push) so other machines trust this one"
          else
            log "warn: staged $_mine but the commit failed -- commit it yourself"
          fi
        else
          log "warn: could not stage $_mine (is the private repo set up?)"
        fi
      fi
    fi
  fi
fi

# ---------- 2. Rebuild authorized_keys from the directory ----------

_built=$(mktemp)
trap 'rm -f "$_built"' EXIT INT TERM

for _f in "$KEYS_D"/*.pub; do
  [ -e "$_f" ] || continue
  printf '# %s\n' "$(basename "$_f" .pub)" >> "$_built"
  cat "$_f" >> "$_built"
done

if [ ! -s "$_built" ]; then
  # Never truncate an existing authorized_keys just because the
  # directory is empty -- that would lock out every machine that can
  # currently reach this one.
  log "warn: no keys in $KEYS_D; leaving $AUTH_KEYS untouched"
  exit 0
fi

# Any key line already in authorized_keys but not represented in the
# rebuilt content is about to be dropped (e.g. a key added by hand
# before this mechanism existed). Back the old file up rather than
# silently revoking someone's access.
if [ -f "$AUTH_KEYS" ]; then
  _orphans=0
  while IFS= read -r _line; do
    case "$_line" in
      ''|'#'*) continue ;;
    esac
    grep -qxF "$_line" "$_built" || _orphans=$((_orphans + 1))
  done < "$AUTH_KEYS"
  if [ "$_orphans" -gt 0 ]; then
    mkdir -p "$BACKUP_DIR/.ssh"
    cp "$AUTH_KEYS" "$BACKUP_DIR/.ssh/authorized_keys"
    log "warn: $_orphans key(s) in $AUTH_KEYS aren't in $KEYS_D and are being dropped"
    log "warn: previous file backed up to $BACKUP_DIR/.ssh/authorized_keys"
    log "warn: to keep one, add it as $KEYS_D/<name>.pub and re-run"
  fi
fi

if [ -f "$AUTH_KEYS" ] && cmp -s "$_built" "$AUTH_KEYS"; then
  log "authorized_keys already up to date ($(grep -c '^ssh-' "$_built") key(s))"
else
  cp "$_built" "$AUTH_KEYS"
  log "rebuilt $AUTH_KEYS from $KEYS_D ($(grep -c '^ssh-' "$_built") key(s))"
fi
chmod 600 "$AUTH_KEYS"
