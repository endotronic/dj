#!/bin/sh
# Migration: required-deps
#
# git, gpg, sops, age and just are dj's own requirements: the package lists
# never name them, and only install.sh (its step 5) installs them. A machine
# that skipped that step -- a $HOME copied from another install, a distro
# package that was later removed -- therefore fails `dj doctor` forever
# while pending-packages reports nothing to do. This installs whichever are
# missing, the way install.sh does: through install-packages.sh, from a
# throwaway list so the user's own lists are untouched.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

REQUIRED="git gpg sops age just"

desc() { echo "dj's required tools are installed ($REQUIRED)"; }

# The required tools that are not on PATH, space-separated; empty when all are.
missing_tools() {
  for _t in $REQUIRED; do
    command -v "$_t" >/dev/null 2>&1 || printf '%s ' "$_t"
  done
}

check() {
  [ -f "$REPO_ROOT/scripts/install-packages.sh" ] || return 2
  [ -z "$(missing_tools)" ] || return 1
}

fix() {
  _missing=$(missing_tools)
  [ -n "$_missing" ] || return 0
  log "installing: $_missing"
  _dir=$(mktemp -d)
  for _t in $_missing; do printf '%s\n' "$_t"; done > "$_dir/common.txt"
  _rc=0
  DOTFILES_DJ_PACKAGES_DIR="$_dir" sh "$REPO_ROOT/scripts/install-packages.sh" || _rc=$?
  rm -rf "$_dir"
  return "$_rc"
}

migration_main "$@"
