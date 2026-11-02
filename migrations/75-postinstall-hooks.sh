#!/bin/sh
# Migration: postinstall-hooks (MANUAL)
# dj-migration: manual
#
# A name in ~/.config/dj/postinstall/*.txt with no matching script
# (~/.config/dj/postinstall/<name>.sh or packages/postinstall/<name>.sh)
# makes run-postinstall.sh warn and exit
# non-zero on every run, so `dj upgrade` never ends clean. MANUAL
# because the fix is a decision -- write the hook, or drop the entry.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "every listed post-install hook has a script"; }

check() {
  [ -f "$REPO_ROOT/scripts/run-postinstall.sh" ] || return 2
  on_nixos && return 2
  sh "$REPO_ROOT/scripts/run-postinstall.sh" --dry-run >/dev/null 2>&1 || return 1
  return 0
}

fix() {
  sh "$REPO_ROOT/scripts/run-postinstall.sh" --dry-run 2>&1 >/dev/null \
    | sed 's/^/        /' || true
  log ""
  log "Either write the hook (~/.config/dj/postinstall/<name>.sh: POSIX sh,"
  log "idempotent), or drop the name from ~/.config/dj/postinstall/ and"
  log "commit with dot."
}

migration_main "$@"
