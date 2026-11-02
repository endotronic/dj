#!/bin/sh
# Migration: dotfiles-origin-ssh
#
# For someone who maintains their own fork of dj: https is what lets
# the very first clone work with zero credentials, but it can never
# push. Once the shared git-host key (~/.ssh/id_githost) is on the
# machine there's no reason to keep it, so this rewrites the dj
# checkout's origin to the matching git@host:path form.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "~/.dotfiles origin is a pushable ssh remote"; }

dotfiles_origin() { git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true; }

check() {
  [ -r "$HOME/.ssh/id_githost" ] || return 2
  _o=$(dotfiles_origin)
  [ -n "$_o" ] || return 2
  case "$_o" in
    http://*|https://*) return 1 ;;
  esac
  return 0
}

fix() {
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

migration_main "$@"
