#!/bin/sh
# Manage opt-in modules (see scripts/lib/modules.sh).
#
# Usage:
#   module.sh list              every module, its state, and what it does
#   module.sh enable NAME...    add to ~/.config/dj/modules.txt
#   module.sh disable NAME...   remove from it
#   module.sh enabled NAME      exit 0 if enabled (for scripts and recipes)
#   module.sh hook PHASE        run hooks/PHASE.sh of every enabled module
#
# modules.txt lives in the private repo, so enabling a module on one
# machine enables it everywhere once committed (`dot add` it).

set -eu

DJ_LIB_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/lib" && pwd)
. "$DJ_LIB_DIR/modules.sh"

die() { printf 'module: %s\n' "$*" >&2; exit 2; }

cmd=${1:-list}
[ $# -gt 0 ] && shift

case "$cmd" in
  list)
    for _d in "$DJ_MODULES_DIR"/*/; do
      _m=$(basename "$_d")
      dj_module_exists "$_m" || continue
      if dj_module_enabled "$_m"; then _s=on; else _s=off; fi
      printf '%-16s %-4s %s\n' "$_m" "$_s" "$(head -1 "$_d/MODULE")"
    done ;;
  enable|disable)
    [ $# -gt 0 ] || die "usage: module.sh $cmd NAME..."
    _mf=$(dj_modules_file)
    mkdir -p "$(dirname "$_mf")"
    [ -f "$_mf" ] || printf '# Opt-in dj modules enabled on every machine (dj module list).\n' > "$_mf"
    for _m in "$@"; do
      dj_module_exists "$_m" || die "no such module: $_m (see: dj module list)"
      if [ "$cmd" = enable ]; then
        if awk 'NF && $1 !~ /^#/ { print $1 }' "$_mf" | grep -Fxq -- "$_m"; then
          printf 'module: %s already enabled\n' "$_m"
        else
          printf '%s\n' "$_m" >> "$_mf"
          printf 'module: enabled %s\n' "$_m"
        fi
      else
        _tmp=$_mf.tmp.$$
        awk -v m="$_m" '$1 != m' "$_mf" > "$_tmp" && mv "$_tmp" "$_mf"
        printf 'module: disabled %s\n' "$_m"
      fi
    done
    printf 'module: commit it so other machines follow: dot add %s && dot commit\n' "$_mf" ;;
  enabled)
    [ $# -eq 1 ] || die "usage: module.sh enabled NAME"
    dj_module_enabled "$1" ;;
  hook)
    [ $# -eq 1 ] || die "usage: module.sh hook PHASE"
    _rc=0
    for _m in $(dj_enabled_modules); do
      _h=$DJ_MODULES_DIR/$_m/hooks/$1.sh
      [ -f "$_h" ] || continue
      sh "$_h" || { printf 'module: %s %s hook failed\n' "$_m" "$1" >&2; _rc=1; }
    done
    exit "$_rc" ;;
  -h|--help)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    die "unknown command: $cmd" ;;
esac
