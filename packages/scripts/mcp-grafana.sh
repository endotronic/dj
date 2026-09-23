#!/bin/sh
# Install mcp-grafana (Grafana's MCP server) from GitHub releases; it is
# not in apt or pacman (brew ships it directly). Launched by
# scripts/grafana-mcp.sh, which Claude Code runs as its user-scope
# `grafana` MCP server (see CLAUDE.md §10.7).
set -eu
command -v mcp-grafana >/dev/null 2>&1 && exit 0

VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  'https://github.com/grafana/mcp-grafana/releases/latest' \
  | sed 's|.*releases/tag/v||')

case "$(uname -s)" in
  Linux)  OS=Linux ;;
  Darwin) OS=Darwin ;;
  *) printf '[mcp-grafana] unsupported OS: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64)        ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)
    printf '[mcp-grafana] unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1 ;;
esac

URL="https://github.com/grafana/mcp-grafana/releases/download/v${VERSION}/mcp-grafana_${OS}_${ARCH}.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '[mcp-grafana] installing v%s (%s %s)\n' "$VERSION" "$OS" "$ARCH"
curl -fsSL "$URL" | tar -xz -C "$TMP" mcp-grafana
sudo install -m 0755 "$TMP/mcp-grafana" /usr/local/bin/mcp-grafana
