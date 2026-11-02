#!/bin/sh
# Install sops from GitHub releases when it is not available in the
# distro's package repository.
set -eu
command -v sops >/dev/null 2>&1 && exit 0

# Resolve the latest release tag via the redirect URL.
SOPS_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  'https://github.com/getsops/sops/releases/latest' \
  | sed 's|.*releases/tag/v||')

case "$(uname -m)" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)
    printf '[sops] unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1 ;;
esac

URL="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

printf '[sops] installing v%s (%s)\n' "$SOPS_VERSION" "$ARCH"
curl -fsSL -o "$TMP" "$URL"
sudo install -m 0755 "$TMP" /usr/local/bin/sops
