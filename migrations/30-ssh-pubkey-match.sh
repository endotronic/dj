#!/bin/sh
# Migration: ssh-pubkey-match
#
# Manifest keys restore only the private half; their .pub is
# untracked and owned by nothing. When rebuild-secrets.sh writes a
# private key over a path that already had a different, hand-made key,
# the old .pub stays behind. ssh then offers the stale public key, the
# server accepts it, and signing fails ("private key ... contents do
# not match public") -- Permission denied, with nothing pointing at the
# .pub. rebuild-secrets.sh now regenerates the .pub itself; this
# repairs machines that went stale before it did.
#
# Checks every ~/.ssh/<name> + <name>.pub pair, not just manifest keys:
# a mismatched pair is broken whatever its origin. A passphrase-
# protected key can't be derived without a prompt, so it's skipped.

# Prints each ~/.ssh/*.pub whose key material differs from the public
# half derived from its private key.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "every ~/.ssh/*.pub matches the private key beside it"; }

ssh_mismatched_pubs() {
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  for _pub in "$HOME"/.ssh/*.pub; do
    _priv=${_pub%.pub}
    [ -f "$_pub" ] && [ -f "$_priv" ] || continue
    _derived=$(ssh-keygen -y -P '' -f "$_priv" 2>/dev/null | awk '{print $1, $2}') || continue
    [ -n "$_derived" ] || continue
    [ "$_derived" = "$(awk '{print $1, $2; exit}' "$_pub")" ] || printf '%s\n' "$_pub"
  done
  return 0
}

check() {
  [ -n "$(ssh_mismatched_pubs)" ] && return 1
  return 0
}

fix() {
  _bk=$(backup_dir)
  for _pub in $(ssh_mismatched_pubs); do
    mkdir -p "$_bk/.ssh"
    cp -p "$_pub" "$_bk/.ssh/"
    ssh-keygen -y -P '' -f "${_pub%.pub}" > "$_pub"
    chmod 644 "$_pub"
    log "regenerated $_pub from its private key (stale copy: $_bk/.ssh/)"
  done
}

migration_main "$@"
