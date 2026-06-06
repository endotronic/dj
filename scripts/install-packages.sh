#!/bin/sh
# Idempotent package installer.
# Reads packages/{common,desktop,server}.txt, resolves logical names
# through packages/renames/<pkg-mgr>.txt, and installs only what's
# missing. The active tier comes from DOTFILES_SYSTEM_TYPE (set by
# os-detect.sh, persisted in ~/.config/dotfiles/system-type) but can
# be overridden with --system-type.
#
# For tools not available in a distro's package repo, place an install
# script at packages/scripts/<logical-name>.sh and mark the tool SKIP
# in the appropriate renames file. The script runs when the binary is
# absent; DOTFILES_PACKAGES_DIR overrides the packages/ root (useful
# in tests).

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

. "$script_dir/os-detect.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --system-type)   shift; DOTFILES_SYSTEM_TYPE=${1:-} ;;
    --system-type=*) DOTFILES_SYSTEM_TYPE=${1#*=} ;;
    -n|--dry-run)    DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: install-packages.sh [--system-type {desktop|server}] [--dry-run]

Resolves the active package list (packages/common.txt + tier file if
set) through packages/renames/<pkg-mgr>.txt, then installs missing
tools via the detected package manager.

For tools not available in the package repo, place packages/scripts/<name>.sh
and mark the tool SKIP in the renames file; the script is run as a fallback.
EOF
      exit 0 ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

: "${DRY_RUN:=0}"

case "${DOTFILES_SYSTEM_TYPE:-}" in
  ''|desktop|server) ;;
  *)
    printf 'error: invalid system-type: %s (want desktop|server|empty)\n' \
      "$DOTFILES_SYSTEM_TYPE" >&2
    exit 2 ;;
esac

if [ -z "${DOTFILES_PKG:-}" ]; then
  printf 'error: no supported package manager (apt|pacman|brew) on PATH\n' >&2
  exit 1
fi

packages_dir=${DOTFILES_PACKAGES_DIR:-$repo_root/packages}
scripts_dir=$packages_dir/scripts
pkg_renames=$packages_dir/renames/$DOTFILES_PKG.txt
# Distro-specific renames take priority over pkg-manager renames (e.g. ubuntu > apt).
distro_renames=
if [ -n "${DOTFILES_DISTRO:-}" ]; then
  _dr="$packages_dir/renames/$DOTFILES_DISTRO.txt"
  [ -f "$_dr" ] && distro_renames=$_dr
  unset _dr
fi

active_list=$(mktemp)
trap 'rm -f "$active_list"' EXIT INT TERM

read_pkglist() {
  [ -f "$1" ] || return 0
  awk 'NF && $1 !~ /^#/ { print $1 }' "$1" >> "$active_list"
}

read_pkglist "$packages_dir/common.txt"
case "${DOTFILES_SYSTEM_TYPE:-}" in
  desktop|server) read_pkglist "$packages_dir/$DOTFILES_SYSTEM_TYPE.txt" ;;
esac

resolve_name() {
  _rn=
  if [ -n "${distro_renames:-}" ]; then
    _rn=$(awk -v want="$1" '$1 == want { print $2; exit }' "$distro_renames")
  fi
  if [ -z "$_rn" ] && [ -f "$pkg_renames" ]; then
    _rn=$(awk -v want="$1" '$1 == want { print $2; exit }' "$pkg_renames")
  fi
  printf '%s' "$_rn"
}

# missing: logical names to install via pkg manager (still missing from PATH)
# skipped: logical names marked SKIP (may have packages/scripts/ fallbacks)
missing=
skipped=
already=
while IFS= read -r logical; do
  [ -z "$logical" ] && continue
  mapped=$(resolve_name "$logical")
  actual=${mapped:-$logical}
  if [ "$actual" = SKIP ]; then
    skipped="$skipped $logical"
    continue
  fi
  if command -v "$logical" >/dev/null 2>&1; then
    already="$already $logical"
  else
    missing="$missing $logical"
  fi
done < "$active_list"

# Build display string with resolved actual package names for the report.
_to_install_display=
for _l in $missing; do
  _a=$(resolve_name "$_l"); _to_install_display="$_to_install_display ${_a:-$_l}"
done

printf '[install-packages] OS=%s PKG=%s DISTRO=%s TIER=%s\n' \
  "$DOTFILES_OS" "$DOTFILES_PKG" "${DOTFILES_DISTRO:-none}" "${DOTFILES_SYSTEM_TYPE:-none}"
printf '[install-packages] already installed:%s\n' "${already:- (none)}"
printf '[install-packages] skipped (SKIP):%s\n' "${skipped:- (none)}"
printf '[install-packages] to install:%s\n'      "${_to_install_display:- (none)}"

[ "$DRY_RUN" = 1 ] && { printf '[install-packages] --dry-run set; not installing\n'; exit 0; }
[ -z "$missing" ] && [ -z "$skipped" ] && exit 0

# Install via package manager one tool at a time; warn on failure instead of
# aborting the whole run. A later fallback-script pass handles anything still
# missing (including tools that were SKIP and have a packages/scripts/<name>.sh).
if [ -n "$missing" ]; then
  case "$DOTFILES_PKG" in
    apt)
      sudo apt-get update
      for _l in $missing; do
        _a=$(resolve_name "$_l"); _a=${_a:-$_l}
        if sudo apt-get install -y "$_a"; then
          :
        else
          printf '[install-packages] WARNING: apt could not install %s (%s)\n' \
            "$_l" "$_a" >&2
        fi
      done
      ;;
    pacman)
      for _l in $missing; do
        _a=$(resolve_name "$_l"); _a=${_a:-$_l}
        if sudo pacman -S --needed --noconfirm "$_a"; then
          :
        else
          printf '[install-packages] WARNING: pacman could not install %s (%s)\n' \
            "$_l" "$_a" >&2
        fi
      done
      ;;
    brew)
      for _l in $missing; do
        _a=$(resolve_name "$_l"); _a=${_a:-$_l}
        if brew install "$_a"; then
          :
        else
          printf '[install-packages] WARNING: brew could not install %s (%s)\n' \
            "$_l" "$_a" >&2
        fi
      done
      ;;
  esac
fi

# Fallback: for any tool still absent (including SKIP items), run
# packages/scripts/<logical>.sh if present.
for _l in $missing $skipped; do
  command -v "$_l" >/dev/null 2>&1 && continue
  _script="$scripts_dir/${_l}.sh"
  [ -f "$_script" ] || continue
  printf '[install-packages] running fallback script for %s\n' "$_l"
  if sh "$_script"; then
    printf '[install-packages] installed %s via script\n' "$_l"
  else
    printf '[install-packages] WARNING: fallback script for %s failed\n' "$_l" >&2
  fi
done

# Final summary of anything that could not be installed by any means.
_still_missing=
for _l in $missing $skipped; do
  command -v "$_l" >/dev/null 2>&1 || _still_missing="$_still_missing $_l"
done
if [ -n "$_still_missing" ]; then
  printf '[install-packages] WARNING: could not install:%s\n' "$_still_missing" >&2
fi
