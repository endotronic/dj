#!/bin/sh
# Install glow from GitHub releases when it is not available in the
# distro's package repository (only in Debian sid, not Debian/Ubuntu
# stable; pacman and brew ship it directly).
set -eu
command -v glow >/dev/null 2>&1 && exit 0

GLOW_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  'https://github.com/charmbracelet/glow/releases/latest' \
  | sed 's|.*releases/tag/v||')

case "$(uname -m)" in
  x86_64)        ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)
    printf '[glow] unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1 ;;
esac

URL="https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${ARCH}.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '[glow] installing v%s (%s)\n' "$GLOW_VERSION" "$ARCH"
curl -fsSL "$URL" | tar -xz -C "$TMP" glow
sudo install -m 0755 "$TMP/glow" /usr/local/bin/glow
