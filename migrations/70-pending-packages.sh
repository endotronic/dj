#!/bin/sh
# Migration: pending-packages
#
# The personal package lists travel via `dj sync`, but pulling a list
# doesn't install anything -- that's `dj install-packages`, which needs
# sudo and so is deliberately not part of sync. A machine can therefore
# sit for months with packages listed but absent.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "every package in the active lists is installed"; }

# Both report lines: packages the manager installs, and SKIP tools a
# fallback script installs. Joined on one line; empty when nothing is due.
pending_package_line() {
  sh "$REPO_ROOT/scripts/install-packages.sh" --dry-run 2>/dev/null \
    | sed -n -E 's/^.*to install( via fallback script)?: (.*)$/\2/p' \
    | grep -vx '(none)' | tr '\n' ' ' | sed 's/ *$//'
}

check() {
  [ -f "$REPO_ROOT/scripts/install-packages.sh" ] || return 2
  _p=$(pending_package_line)
  [ -n "$_p" ] || return 0
  return 1
}

fix() {
  log "installing: $(pending_package_line)"
  sh "$REPO_ROOT/scripts/install-packages.sh"
}

migration_main "$@"
