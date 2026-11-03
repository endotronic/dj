#!/bin/sh
# Migration: claude-local-context
#
# Your own notes about your machines and setup -- hostnames, services,
# decisions -- belong in the private repo, not in dj. Keep them at
# ~/.config/dj/AGENTS.md; this links them into the dj checkout as
# .claude/AGENTS.md (gitignored there), which Claude Code loads alongside
# the repo's own AGENTS.md whenever it runs in ~/.dotfiles (dj claude).
#
# Not CLAUDE.local.md: Claude Code loads a directory's AGENTS.md only when
# that directory has no CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md,
# so linking the notes in under that name would hide dj's own AGENTS.md.
# A link left there by an earlier version of this migration is removed.
#
# Not at the private repo's root: that root is $HOME, and an AGENTS.md
# or CLAUDE.md there would load into every agent session anywhere under
# your home directory.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "your ~/.config/dj/AGENTS.md is linked into dj as .claude/AGENTS.md"; }

notes() { printf '%s' "${DOTFILES_DJ_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dj}/AGENTS.md"; }
root() { CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd; }
link() { printf '%s/.claude/AGENTS.md' "$(root)"; }
# The old location: our own symlink there would hide AGENTS.md.
old_link() { printf '%s/CLAUDE.local.md' "$(root)"; }
old_link_ours() { [ -L "$(old_link)" ] && [ "$(readlink "$(old_link)")" = "$(notes)" ]; }

check() {
  [ -f "$(notes)" ] || return 2
  old_link_ours && return 1
  [ -L "$(link)" ] && [ "$(readlink "$(link)")" = "$(notes)" ] && return 0
  return 1
}

fix() {
  if old_link_ours; then
    rm -f "$(old_link)"
    log "removed $(old_link) (it made Claude Code skip AGENTS.md)"
  fi
  _l=$(link)
  mkdir -p "$(dirname "$_l")"
  if [ -e "$_l" ] && [ ! -L "$_l" ]; then
    _bk=$(backup_dir)
    mv "$_l" "$_bk/"
    log "moved an existing $_l to $_bk/"
  fi
  ln -sfn "$(notes)" "$_l"
  log "linked $_l -> $(notes)"
}

migration_main "$@"
