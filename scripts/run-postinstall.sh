#!/bin/sh
# Idempotent post-install hook runner.
#
# Two distinct roots, mirroring install-packages.sh:
#   - lists:     ~/.config/dj/postinstall/{common.txt,types/<type>.txt,
#                hosts/<hostname>.txt} -- which hooks to run on this
#                machine. Private, travels via `dj sync`.
#                DOTFILES_DJ_POSTINSTALL_DIR overrides the root (tests).
#   - mechanism: packages/postinstall/<name>.sh in the public tooling
#                repo -- the actual idempotent hook scripts. They may
#                use sudo for narrow, explicit system-level changes
#                (enabling a service, group membership, an /etc/fstab
#                entry, ...) that a plain package-manager install
#                can't express. DOTFILES_POSTINSTALL_DIR overrides
#                this root (tests).
#
# A hook is just a name -> POSIX sh script lookup; nothing ties it to
# a package-manager package, so a hook unrelated to any package (e.g.
# an fstab entry) is exactly as easy to add as one that follows a
# package install (e.g. enabling the docker service).

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
Usage: run-postinstall.sh [--system-type TYPE] [--dry-run]

Resolves the active hook list (~/.config/dj/postinstall/common.txt +
types/TYPE.txt + hosts/<hostname>.txt, whichever exist) and runs each
named hook's packages/postinstall/<name>.sh if present. Hooks must be
idempotent; they may use sudo for explicit, narrow system-level
changes.
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
  '') ;;
  *[!A-Za-z0-9_-]*)
    printf 'error: invalid system-type: %s (letters, digits, _ and - only)\n' \
      "$DOTFILES_SYSTEM_TYPE" >&2
    exit 2 ;;
esac

lists_dir=${DOTFILES_DJ_POSTINSTALL_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dj/postinstall}
hooks_dir=${DOTFILES_POSTINSTALL_DIR:-$repo_root/packages/postinstall}

active_list=$(mktemp)
trap 'rm -f "$active_list"' EXIT INT TERM

read_hooklist() {
  [ -f "$1" ] || return 0
  awk 'NF && $1 !~ /^#/ { print $1 }' "$1" >> "$active_list"
}

_hostname=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || printf '')

read_hooklist "$lists_dir/common.txt"
[ -n "${DOTFILES_SYSTEM_TYPE:-}" ] && read_hooklist "$lists_dir/types/$DOTFILES_SYSTEM_TYPE.txt"
[ -n "$_hostname" ] && read_hooklist "$lists_dir/hosts/$_hostname.txt"

if [ ! -s "$active_list" ]; then
  printf '[run-postinstall] no hooks listed\n'
  exit 0
fi

printf '[run-postinstall] OS=%s TYPE=%s\n' "$DOTFILES_OS" "${DOTFILES_SYSTEM_TYPE:-none}"

rc=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  hook="$hooks_dir/$name.sh"
  if [ ! -f "$hook" ]; then
    printf '[run-postinstall] WARNING: no hook script for %s (expected %s)\n' "$name" "$hook" >&2
    rc=1
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf '[run-postinstall] (dry-run) would run %s\n' "$name"
    continue
  fi
  printf '[run-postinstall] running %s\n' "$name"
  if sh "$hook"; then
    :
  else
    printf '[run-postinstall] WARNING: hook %s failed\n' "$name" >&2
    rc=1
  fi
done < "$active_list"

exit "$rc"
