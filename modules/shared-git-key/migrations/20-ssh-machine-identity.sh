#!/bin/sh
# Migration: ssh-machine-identity (MANUAL)
# dj-migration: manual
#
# This module splits two concerns that are easy to conflate: this
# machine's own identity (~/.ssh/id_ed25519, generated locally, never
# distributed) and git-host access (~/.ssh/id_githost, one shared key
# in the manifest). A machine bootstrapped under the old
# one-key-copied-everywhere model has the SAME key in both slots --
# and once it registers itself in authorized_keys.d, it publishes the
# shared forge key as its machine identity to every other machine,
# which is precisely what per-machine identity exists to prevent.
#
# MANUAL because the repair rotates a credential: until every other
# machine has synced the new <hostname>.pub, outbound SSH from here to them
# stops working. Inbound SSH and git-host access are unaffected.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "machine SSH identity is distinct from the shared git-host key"; }

check() {
  [ -f "$HOME/.ssh/id_ed25519" ] || return 2
  [ -f "$HOME/.ssh/id_githost" ] || return 2
  _a=$(ssh_fp "$HOME/.ssh/id_ed25519")
  _b=$(ssh_fp "$HOME/.ssh/id_githost")
  [ -n "$_a" ] && [ -n "$_b" ] || return 2
  [ "$_a" = "$_b" ] && return 1
  return 0
}

fix() {
  log "This machine's SSH identity IS the shared git-host key:"
  log "  $(ssh_fp "$HOME/.ssh/id_ed25519")"
  log "so ~/.ssh/authorized_keys.d/$(hostname -s 2>/dev/null || uname -n).pub publishes the forge key"
  log "to every other machine (per-machine identity exists to prevent this)."
  log ""
  log "Rotating is safe but not silent -- until your other machines run"
  log "dj sync, outbound ssh from here to them will fail. Inbound ssh and"
  log "git-host access are unaffected. To rotate:"
  log ""
  log "  bk=\"\$HOME/.dotfiles-backup/\$(date -u +%Y%m%dT%H%M%SZ)/.ssh\"; mkdir -p \"\$bk\""
  log "  mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub \"\$bk\"/"
  log "  ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519 \\"
  log "      -C \"\$(id -un)@\$(hostname -s 2>/dev/null || uname -n) (machine identity)\""
  log "  dj authorized-keys && dot push"
}

migration_main "$@"
