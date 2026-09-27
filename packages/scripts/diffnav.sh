#!/bin/sh
# Install diffnav (git diff pager with a file tree) from GitHub
# releases; it is not in Ubuntu's apt repos (Debian ships it natively,
# see renames/debian.txt; pacman and brew ship it directly).
set -eu
command -v diffnav >/dev/null 2>&1 && exit 0

VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  'https://github.com/dlvhdr/diffnav/releases/latest' \
  | sed 's|.*releases/tag/v||')

case "$(uname -s)" in
  Linux)  OS=Linux ;;
  Darwin) OS=Darwin ;;
  *) printf '[diffnav] unsupported OS: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64)        ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)
    printf '[diffnav] unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1 ;;
esac

URL="https://github.com/dlvhdr/diffnav/releases/download/v${VERSION}/diffnav_${OS}_${ARCH}.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '[diffnav] installing v%s (%s %s)\n' "$VERSION" "$OS" "$ARCH"
curl -fsSL "$URL" | tar -xz -C "$TMP" diffnav
sudo install -m 0755 "$TMP/diffnav" /usr/local/bin/diffnav
