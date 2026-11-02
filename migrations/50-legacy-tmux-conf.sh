#!/bin/sh
# Migration: legacy-tmux-conf
#
# install.sh step 7b backs these up, but only during install. tmux
# loads ~/.tmux.conf in addition to -- and before -- the tracked
# ~/.config/tmux/tmux.conf, at a path the conflict-aware checkout
# never walks (it only visits tracked paths), so a hand-written
# pre-dotfiles ~/.tmux.conf otherwise coexists forever.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "no legacy ~/.tmux.conf shadowing the tracked config"; }

check() {
  [ -f "$HOME/.config/tmux/tmux.conf" ] || return 2
  for _f in "$HOME"/.tmux.conf*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    return 1
  done
  return 0
}

fix() {
  _bk=$(backup_dir)
  for _f in "$HOME"/.tmux.conf*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    mv "$_f" "$_bk/"
    log "backed up $_f -> $_bk/"
  done
  log "restart the tmux server (tmux kill-server) to drop it from memory"
}

migration_main "$@"
