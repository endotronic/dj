#!/bin/sh
# Migration: public-repo-guard
#
# The public repo's git hooks (scripts/pre-commit-personal.sh) refuse a
# commit containing anything from your personal denylist. Hooks aren't part
# of a clone, so a machine that cloned before this existed has none.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "the public repo's pre-commit and commit-msg hooks are installed"; }

check() {
  [ -f "$REPO_ROOT/scripts/install-public-hooks.sh" ] || return 2
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 2
  sh "$REPO_ROOT/scripts/install-public-hooks.sh" --check
}

fix() {
  sh "$REPO_ROOT/scripts/install-public-hooks.sh"
}

migration_main "$@"
