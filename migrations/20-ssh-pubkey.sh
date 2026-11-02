#!/bin/sh
# Migration: ssh-pubkey
#
# Machines publish their identity as ~/.ssh/authorized_keys.d/
# <hostname>.pub, which authorized-keys.sh copies from
# ~/.ssh/id_ed25519.pub. Bootstraps predating that convention left
# only the private key, so registration silently logged "nothing of
# our own to register" and the machine never joined the trust set.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "this machine's SSH public key exists beside its private key"; }

check() {
  [ -f "$HOME/.ssh/id_ed25519" ] || return 2
  [ -f "$HOME/.ssh/id_ed25519.pub" ] || return 1
  return 0
}

fix() {
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

migration_main "$@"
