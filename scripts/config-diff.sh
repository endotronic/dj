#!/bin/sh
# config-diff.sh — Compare a config path under $HOME against the
# distribution / Omarchy default version, to help decide whether
# it's worth tracking in the dotfiles repo.
#
# Usage:
#   config-diff.sh <path>
#   config-diff.sh <path> --against <default-path>
#   config-diff.sh --help
#
# Auto-discovery (first match wins) for paths under $HOME/.config/<rel>:
#   $HOME/.local/share/omarchy/config/<rel>   (Omarchy)
#   /usr/share/<rel>                            (distro packages)
#   /etc/<rel>                                  (sysadmin defaults)
#
# Exit codes:
#   0  identical (or no default found and nothing tracked to do)
#   1  differs
#   2  no default found, or invalid usage

set -eu

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

DEFAULT_OVERRIDE=
USER_PATH=

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0 ;;
    --against)
      shift
      DEFAULT_OVERRIDE=${1:-}
      [ -n "$DEFAULT_OVERRIDE" ] || { printf 'error: --against needs a path\n' >&2; exit 2; } ;;
    --against=*)
      DEFAULT_OVERRIDE=${1#*=} ;;
    --)
      shift
      USER_PATH=${1:-}
      break ;;
    -*)
      printf 'error: unknown flag: %s\n' "$1" >&2
      exit 2 ;;
    *)
      if [ -z "$USER_PATH" ]; then
        USER_PATH=$1
      else
        printf 'error: only one <path> may be given (got extra: %s)\n' "$1" >&2
        exit 2
      fi ;;
  esac
  shift
done

if [ -z "$USER_PATH" ]; then
  usage >&2
  exit 2
fi

# Normalize to an absolute path.
case "$USER_PATH" in
  '~/'*) USER_PATH=$HOME/${USER_PATH#~/} ;;
  /*)    ;;
  *)     USER_PATH=$(pwd)/$USER_PATH ;;
esac

if [ ! -e "$USER_PATH" ]; then
  printf 'error: not found: %s\n' "$USER_PATH" >&2
  exit 2
fi

# Resolve the "default" side: explicit --against, else auto-discover.
DEFAULT_PATH=
if [ -n "$DEFAULT_OVERRIDE" ]; then
  case "$DEFAULT_OVERRIDE" in
    '~/'*) DEFAULT_PATH=$HOME/${DEFAULT_OVERRIDE#~/} ;;
    *)     DEFAULT_PATH=$DEFAULT_OVERRIDE ;;
  esac
  [ -e "$DEFAULT_PATH" ] || {
    printf 'error: --against path not found: %s\n' "$DEFAULT_PATH" >&2
    exit 2
  }
else
  case "$USER_PATH" in
    "$HOME"/.config/*)
      rel=${USER_PATH#"$HOME"/.config/}
      for cand in \
        "$HOME/.local/share/omarchy/config/$rel" \
        "/usr/share/$rel" \
        "/etc/$rel"
      do
        if [ -e "$cand" ]; then
          DEFAULT_PATH=$cand
          break
        fi
      done ;;
  esac
fi

if [ -z "$DEFAULT_PATH" ]; then
  printf '[config-diff] no default found for %s\n' "$USER_PATH" >&2
  printf '[config-diff] try: --against <path> to compare explicitly\n' >&2
  exit 2
fi

printf '[config-diff] comparing:\n'
printf '  yours:   %s\n' "$USER_PATH"
printf '  default: %s\n' "$DEFAULT_PATH"
printf '\n'

# diff -ruN treats missing as empty (so added files in either side
# show as full additions); -r recurses for directories.
if diff -ruN "$DEFAULT_PATH" "$USER_PATH"; then
  printf '\n[config-diff] identical\n'
  exit 0
else
  printf '\n[config-diff] differs\n'
  exit 1
fi
