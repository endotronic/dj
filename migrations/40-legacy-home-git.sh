#!/bin/sh
# Migration: legacy-home-git (MANUAL)
# dj-migration: manual
#
# Before this project existed, $HOME itself was a plain (non-bare) git
# repo -- work-tree $HOME, .git at ~/.git. That pattern is deprecated,
# but a machine that used it keeps the repo forever, and it collides
# with the current design in two ways that never announce themselves:
#
#   1. Any plain `git` command run from $HOME (or any subdirectory
#      without its own .git) resolves to it, not to the private bare
#      repo. A stray `git checkout` or `git stash` there silently
#      reverts files the private repo owns -- ~/.bashrc is tracked by
#      both.
#   2. Its ~/.gitignore is read work-tree-relative, so it governs the
#      private bare repo too. Entries meant for the old repo (.ssh,
#      .local, .profile, .tmux.conf) make `dot add` on those paths
#      quietly do nothing.
#
# MANUAL because the old repo can hold commits and working-tree edits
# that exist nowhere else -- deciding what to salvage is a judgement
# call, not a repair.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "no legacy git repo with $HOME as its work tree"; }

legacy_home_git_paths() {
  for _p in "$HOME/.git" "$HOME/.gitignore"; do
    [ -e "$_p" ] && printf '%s\n' "$_p"
  done
  return 0
}

check() {
  # The private repo is bare at ~/.config.git; $HOME is never a git
  # work tree in this design, so anything here is the legacy repo.
  [ -e "$HOME/.git" ] || [ -e "$HOME/.gitignore" ] || return 0
  return 1
}

fix() {
  log "\$HOME is still a git work tree from the pre-dotfiles pattern:"
  legacy_home_git_paths | while IFS= read -r _p; do log "  $_p"; done

  if [ -d "$HOME/.git" ] && command -v git >/dev/null 2>&1; then
    _dirty=$(git --git-dir="$HOME/.git" --work-tree="$HOME" \
               status --porcelain --untracked-files=no 2>/dev/null | wc -l)
    [ "$_dirty" -gt 0 ] && log "it has $_dirty tracked file(s) with uncommitted changes"
    _br=$(git --git-dir="$HOME/.git" --work-tree="$HOME" \
            symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$_br" ]; then
      _ahead=$(git --git-dir="$HOME/.git" --work-tree="$HOME" \
                 rev-list --count "@{upstream}..$_br" 2>/dev/null || echo unknown)
      log "branch '$_br' has $_ahead commit(s) not on its upstream"
    fi
  fi

  log "salvage anything you still want, then move it aside (reversible):"
  log "  mkdir -p ~/.dotfiles-backup/\$(date -u +%Y%m%dT%H%M%SZ)"
  log "  mv ~/.git ~/.gitignore ~/.dotfiles-backup/<that-dir>/"
  return 1
}

migration_main "$@"
