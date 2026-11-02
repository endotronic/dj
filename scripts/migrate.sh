#!/bin/sh
# Detect -- and where it's safe, repair -- persistent machine state
# that newer versions of this project expect but that an older
# bootstrap left stale or never created.
#
# Pulling new code does NOT retroactively fix machine state. When
# install.sh starts setting up something new (a git config, a derived
# file, a renamed key), machines bootstrapped before that commit keep
# running without it, usually silently. This script is where those
# one-time catch-up repairs live.
#
# Usage:
#   migrate.sh            report status; exit 1 if anything is pending
#   migrate.sh --fix      apply the auto-fixable repairs, then re-check
#   migrate.sh --list     list known migrations and exit
#   migrate.sh --only ID  restrict to one migration (repeatable)
#   migrate.sh --quiet    omit the "ok" lines; print only what needs attention
#                         (what `dj sync` / `dj upgrade` close with)
#
# Each migration is a (check, fix) pair. check exits:
#   0 = already satisfied      1 = pending      2 = N/A on this machine
#
# Some migrations are MANUAL: detected but never auto-applied, because
# the repair rotates a credential, removes software, or needs a
# decision a script shouldn't make on your behalf. Those print the
# exact commands instead of running them.
#
# Every auto-fix must be idempotent: running --fix twice is a no-op the
# second time, and running it on a machine that never had the problem
# does nothing.
#
# Each migration is its own script, migrations/NN-<id>.sh, run as
# `<script> desc|check|fix` (see migrations/README.md). NN only orders
# them; the id is what --only and the report use.
#
# DOT_DIR, DOTFILES_REPO_ROOT and DOTFILES_BACKUP_DIR are overridable
# for tests. DOTFILES_REPO_ROOT is where migrations look for sibling
# scripts (install-packages.sh, ...); the migrations themselves always
# come from this script's own tree.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DJ_ROOT=$(CDPATH= cd -- "$script_dir/.." && pwd)

DJ_MIGRATION_LIB=$script_dir/lib/migration.sh
DOT_DIR=${DOT_DIR:-$HOME/.config.git}
DOTFILES_REPO_ROOT=${DOTFILES_REPO_ROOT:-$DJ_ROOT}
DJ_MIGRATE_BACKUP=${DOTFILES_BACKUP_DIR:-$HOME/.dotfiles-backup/$(date -u +%Y%m%dT%H%M%SZ)}
export DJ_MIGRATION_LIB DOT_DIR DOTFILES_REPO_ROOT DJ_MIGRATE_BACKUP

FIX=0
LIST=0
QUIET=0
ONLY=''

while [ $# -gt 0 ]; do
  case "$1" in
    --fix)    FIX=1 ;;
    --list)   LIST=1 ;;
    -q|--quiet) QUIET=1 ;;
    --only)   shift; ONLY="$ONLY ${1:?--only needs a migration id}" ;;
    --only=*) ONLY="$ONLY ${1#*=}" ;;
    -h|--help)
      sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

# Every migration script, in run order, one path per line.
migration_files() {
  for _f in "$DJ_ROOT"/migrations/*.sh; do
    [ -f "$_f" ] && printf '%s\n' "$_f"
  done
  return 0
}

migration_id() {
  _id=${1##*/}
  _id=${_id%.sh}
  case "$_id" in
    [0-9]*-*) _id=${_id#*-} ;;
  esac
  printf '%s' "$_id"
}

is_manual() { grep -q '^# dj-migration: manual' "$1"; }

migration_desc() { sh "$1" desc 2>/dev/null || echo "(no description: $1)"; }

selected() {
  [ -z "$ONLY" ] && return 0
  for _s in $ONLY; do
    [ "$_s" = "$1" ] && return 0
  done
  return 1
}

if [ "$LIST" -eq 1 ]; then
  migration_files | while IFS= read -r f; do
    if is_manual "$f"; then _tag='manual'; else _tag='auto'; fi
    printf '%-22s %-7s %s\n' "$(migration_id "$f")" "$_tag" "$(migration_desc "$f")"
  done
  exit 0
fi

pending=0
manual=0
failed=0

# Read from a file rather than a pipe, so the counters survive the loop.
_files=$(mktemp)
trap 'rm -f "$_files"' EXIT INT TERM
migration_files > "$_files"

while IFS= read -r f; do
  m=$(migration_id "$f")
  selected "$m" || continue
  status=0
  sh "$f" check </dev/null || status=$?
  case "$status" in
    0) [ "$QUIET" -eq 1 ] || printf '  ok      %s\n' "$(migration_desc "$f")" ;;
    2) : ;;  # not applicable here -- stay silent
    *)
      if is_manual "$f"; then
        printf '  MANUAL  %s\n' "$(migration_desc "$f")"
        sh "$f" fix </dev/null || true
        manual=$((manual + 1))
      elif [ "$FIX" -eq 1 ]; then
        printf '  fixing  %s\n' "$(migration_desc "$f")"
        _ok=0
        sh "$f" fix || _ok=$?
        recheck=0
        sh "$f" check </dev/null || recheck=$?
        if [ "$_ok" -eq 0 ] && [ "$recheck" -eq 0 ]; then
          printf '  ok      %s\n' "$(migration_desc "$f")"
        else
          failed=$((failed + 1))
        fi
      else
        printf '  MIGR    %s\n' "$(migration_desc "$f")"
        printf '          repair: dj migrate --fix --only %s\n' "$m"
        pending=$((pending + 1))
      fi
      ;;
  esac
done < "$_files"

# Quiet and clean prints just the one summary line, with no blank line
# above it (there is no list for it to separate from).
if [ "$QUIET" -ne 1 ] || [ "$((pending + manual + failed))" -gt 0 ]; then
  echo
fi
if [ "$pending" -gt 0 ]; then
  printf '[migrate] %s pending migration(s) -- repair with: dj migrate --fix\n' "$pending"
fi
if [ "$manual" -gt 0 ]; then
  printf '[migrate] %s migration(s) need a decision (see above); not auto-applied\n' "$manual"
fi
if [ "$failed" -gt 0 ]; then
  printf '[migrate] %s migration(s) could not be completed\n' "$failed"
fi
if [ "$((pending + manual + failed))" -eq 0 ]; then
  printf '[migrate] machine state is up to date\n'
  exit 0
fi
exit 1
