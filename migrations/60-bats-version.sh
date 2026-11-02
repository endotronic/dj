#!/bin/sh
# Migration: bats-version
#
# Two test files call `bats_require_minimum_version 1.5.0`, which bats
# 1.2.1 -- all Debian/Ubuntu ships -- does not define. The result is
# not a failing test but an aborted setup_file: those files' tests are
# never run at all, and the suite's summary line still reads "ok" for
# everything it did manage to execute. That is precisely the silent
# capability loss this script exists to catch, so it gets a real
# version predicate rather than the `command -v bats` presence check
# `dj doctor`'s package audit does.
#
# Fresh machines don't need this: bats is marked SKIP in
# renames/apt.txt, so install-packages.sh runs the fallback installer
# for it instead. This repairs the machines bootstrapped before that.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "bats is new enough to run the whole test suite (>= 1.5)"; }

BATS_MIN_MAJOR=1
BATS_MIN_MINOR=5

bats_version_str() { bats --version 2>/dev/null | awk '{print $2}'; }

bats_version_ge_min() {
  _v=$(bats_version_str)
  [ -n "$_v" ] || return 1
  _maj=${_v%%.*}
  _min=${_v#*.}
  _min=${_min%%.*}
  [ "$_min" = "$_v" ] && _min=0
  case "$_maj$_min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(( _maj * 100 + _min ))" -ge "$(( BATS_MIN_MAJOR * 100 + BATS_MIN_MINOR ))" ]
}

check() {
  # No bats at all is pending-packages' problem, not this one.
  command -v bats >/dev/null 2>&1 || return 2
  bats_version_ge_min || return 1
  return 0
}

fix() {
  _inst="$REPO_ROOT/packages/scripts/bats.sh"
  [ -f "$_inst" ] || {
    log "warn: $_inst not found; cannot upgrade bats automatically"
    return 1
  }
  sh "$_inst" || true
  hash -r 2>/dev/null || true
  if bats_version_ge_min; then
    log "bats upgraded to $(bats_version_str)"
    return 0
  fi
  log "bats is still $(bats_version_str); the distro package shadows the"
  log "upstream build, or the install failed. Check that /usr/local/bin"
  log "precedes /usr/bin on PATH, then re-run: sh $_inst"
  return 1
}

migration_main "$@"
