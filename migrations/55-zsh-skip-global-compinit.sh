#!/bin/sh
# Migration: zsh-skip-global-compinit
#
# dj's zsh layer (~/.config/zsh/completion.zsh) runs compinit itself, and
# runs it with -i when there's no terminal, where compinit can't ask about
# insecure completion directories. Debian and Ubuntu's /etc/zsh/zshrc runs
# a second, plain compinit before it, unless skip_global_compinit=1 is set
# by then -- which means in ~/.zshenv, the only user file zsh reads first.
# That second call is redundant, and without a terminal (zsh -ic from a
# script, over ssh) it prints "not interactive and can't open terminal"
# into the output. The variable means nothing anywhere else, so it's set
# on every machine with dj's zsh layer, like the rest of the config.
#
# Existing lines in ~/.zshenv are kept; the setting is appended.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "~/.zshenv skips the distro's duplicate compinit"; }

has_setting() {
  grep -q '^[[:space:]]*skip_global_compinit=1' "$HOME/.zshenv" 2>/dev/null
}

check() {
  [ -f "$HOME/.config/zsh/completion.zsh" ] || return 2
  has_setting && return 0
  return 1
}

fix() {
  has_setting && return 0
  {
    [ -s "$HOME/.zshenv" ] && echo
    echo "# dj's zsh layer runs compinit itself: skip the distro's own one"
    echo "# (Debian/Ubuntu /etc/zsh/zshrc), which runs first and, without a"
    echo "# terminal, aborts noisily over insecure completion directories."
    echo "skip_global_compinit=1"
  } >> "$HOME/.zshenv"
  log "added skip_global_compinit=1 to ~/.zshenv; track it with: dot add ~/.zshenv"
}

migration_main "$@"
