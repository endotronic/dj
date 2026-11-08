#!/bin/sh
# Link scripts/pre-commit-personal.sh into the public repo's git hooks as
# pre-commit and commit-msg. Idempotent. A hook you already have there
# (anything that is not our symlink) is left alone and reported.
#
# Usage: install-public-hooks.sh [--check]
#   --check   change nothing; exit 1 if a hook is missing, 0 if all are in place

set -eu

REPO=${DOTFILES_REPO_ROOT:-${DJ_REPO_ROOT:-$HOME/.dotfiles}}
SRC=$REPO/scripts/pre-commit-personal.sh
CHECK=0
[ "${1:-}" = --check ] && CHECK=1

[ -f "$SRC" ] || exit 0
# The common dir, so a linked worktree installs into the one shared hooks dir.
common=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || exit 0
hooks=$(cd "$REPO" && cd "$common" && pwd -P)/hooks

rc=0
for name in pre-commit commit-msg; do
  dst=$hooks/$name
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$SRC" ]; then
    continue
  elif [ -e "$dst" ] || [ -L "$dst" ]; then
    printf 'public repo already has its own %s hook; not replacing it\n' "$name" >&2
    continue
  fi
  rc=1
  [ "$CHECK" -eq 1 ] && continue
  mkdir -p "$hooks"
  ln -s "$SRC" "$dst"
  chmod +x "$SRC"
  rc=0
done
[ "$CHECK" -eq 1 ] && exit "$rc"
exit 0
