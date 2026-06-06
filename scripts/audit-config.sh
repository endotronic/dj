#!/bin/sh
# audit-config.sh — Survey every entry under $HOME/.config and
# classify it against the Omarchy default tree at
# ~/.local/share/omarchy/config/.
#
# Categories:
#   IDENTICAL  → don't track; Omarchy already owns this
#   DIFFERS    → user-customized vs Omarchy default; likely worth tracking
#   USER-ONLY  → no Omarchy default; decide case-by-case
#   APP-STATE  → filtered out (browser caches, runtime dirs, etc.)
#
# Usage:
#   audit-config.sh            full report
#   audit-config.sh -q | --quiet  only the "TRACK" list (DIFFERS + USER-ONLY)
#   audit-config.sh -h         help

set -eu

QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet) QUIET=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

OM=${OMARCHY_CONFIG_DIR:-$HOME/.local/share/omarchy/config}

# App-state entries: tool caches, browser data, runtime state. These
# never belong in dotfiles and shouldn't even be analyzed.
SKIP_RE='^(\.android|autostart|_backup_.*|capacitor|chromium|Code|dconf|freerdp|go|gtk-3\.0|ibus|fcitx|fcitx5|libreoffice|libvirt|mise|nautilus|nextjs-nodejs|obsidian|pulse|remmina|Signal|spotify|systemd|Typora|yay|.*\.ttf|hyprland-preview-share-picker)$'

identical=
differs=
user_only=
skip=

if [ ! -d "$HOME/.config" ]; then
  printf 'error: $HOME/.config does not exist\n' >&2
  exit 1
fi

for entry in $(ls -A "$HOME/.config" 2>/dev/null); do
  if printf '%s\n' "$entry" | grep -qE "$SKIP_RE"; then
    skip="$skip $entry"
    continue
  fi
  full=$HOME/.config/$entry
  [ -e "$full" ] || continue
  default=$OM/$entry
  if [ ! -e "$default" ]; then
    user_only="$user_only $entry"
  elif diff -rq "$default" "$full" >/dev/null 2>&1; then
    identical="$identical $entry"
  else
    differs="$differs $entry"
  fi
done

print_list() {
  for e in $1; do printf '  %s\n' "$e"; done
}

if [ "$QUIET" = 1 ]; then
  for e in $differs $user_only; do printf '%s\n' "$e"; done
  exit 0
fi

cat <<EOF
config audit: $(echo $identical $differs $user_only $skip | wc -w) entries under ~/.config
default tree: $OM

EOF

echo "=== TRACK: DIFFERS from Omarchy default ==="
print_list "$differs"
echo
echo "=== TRACK?: user-only, no Omarchy default ==="
print_list "$user_only"
echo
echo "=== SKIP: identical to Omarchy default ==="
print_list "$identical"
echo
echo "=== SKIP: app state (pre-filtered) ==="
print_list "$skip"
