#!/bin/sh
# Migration: claude-local-context
#
# Your own notes about your machines and setup -- hostnames, services,
# decisions -- belong in the private repo, not in dj. Keep them at
# ~/.config/dj/AGENTS.md; this links them into the dj checkout as
# CLAUDE.local.md (gitignored there), which Claude Code loads alongside
# the repo's own AGENTS.md whenever it runs in ~/.dotfiles (dj claude).
#
# Not at the private repo's root: that root is $HOME, and an AGENTS.md
# or CLAUDE.md there would load into every agent session anywhere under
# your home directory.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "your ~/.config/dj/AGENTS.md is linked into dj as CLAUDE.local.md"; }

notes() { printf '%s' "${DOTFILES_DJ_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dj}/AGENTS.md"; }
link() { printf '%s/CLAUDE.local.md' "$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"; }

check() {
  [ -f "$(notes)" ] || return 2
  [ -L "$(link)" ] && [ "$(readlink "$(link)")" = "$(notes)" ] && return 0
  return 1
}

fix() {
  _l=$(link)
  if [ -e "$_l" ] && [ ! -L "$_l" ]; then
    _bk=$(backup_dir)
    mv "$_l" "$_bk/"
    log "moved an existing $_l to $_bk/"
  fi
  ln -sfn "$(notes)" "$_l"
  log "linked $_l -> $(notes)"
}

migration_main "$@"
