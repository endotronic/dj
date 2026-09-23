#!/bin/sh
# Launch mcp-grafana (stdio) for Claude Code, which registers this
# script -- not the binary -- as its user-scope `grafana` MCP server
# (migrate.sh's claude-mcp-grafana, CLAUDE.md §10.7).
#
# Credentials are read here, at launch, from the SOPS secret
# materialized to ~/.secrets/grafana.env (GRAFANA_URL, GRAFANA_TOKEN),
# rather than baked into `claude mcp add -e ...`: that would copy the
# token into ~/.claude.json in plaintext, outside the manifest, where a
# rotated token would silently go stale. Already-exported values win,
# so a shell that sourced secrets.sh (or a one-off override) is honored.
set -eu

env_file="${GRAFANA_ENV_FILE:-$HOME/.secrets/grafana.env}"

if [ -z "${GRAFANA_URL:-}" ] || [ -z "${GRAFANA_TOKEN:-}${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  if [ -r "$env_file" ]; then
    _url=${GRAFANA_URL:-}
    _tok=${GRAFANA_TOKEN:-}
    set -a
    . "$env_file"
    set +a
    [ -z "$_url" ] || GRAFANA_URL=$_url
    [ -z "$_tok" ] || GRAFANA_TOKEN=$_tok
  fi
fi

# mcp-grafana's own name for it; GRAFANA_TOKEN is the name everything
# else here uses.
: "${GRAFANA_SERVICE_ACCOUNT_TOKEN:=${GRAFANA_TOKEN:-}}"
export GRAFANA_SERVICE_ACCOUNT_TOKEN

if [ -z "${GRAFANA_URL:-}" ] || [ -z "$GRAFANA_SERVICE_ACCOUNT_TOKEN" ]; then
  printf '[grafana-mcp] GRAFANA_URL / GRAFANA_TOKEN not set and not in %s (run: dj apply-secrets)\n' "$env_file" >&2
  exit 1
fi
export GRAFANA_URL

command -v mcp-grafana >/dev/null 2>&1 || {
  printf '[grafana-mcp] mcp-grafana not installed (run: dj install-packages)\n' >&2
  exit 1
}

exec mcp-grafana "$@"
