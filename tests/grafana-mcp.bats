#!/usr/bin/env bats
#
# Tests for scripts/grafana-mcp.sh -- the launcher Claude Code runs as
# its user-scope `grafana` MCP server.

load test_helper

LAUNCHER="$DOTFILES_REPO_ROOT/scripts/grafana-mcp.sh"

setup() {
  sandbox_setup
  stub_dir_setup
  unset GRAFANA_URL GRAFANA_TOKEN GRAFANA_SERVICE_ACCOUNT_TOKEN
  # A fake mcp-grafana that reports the environment it was handed.
  cat > "$STUB_BIN/mcp-grafana" <<'EOF'
#!/bin/sh
printf 'url=%s token=%s args=%s\n' "$GRAFANA_URL" "$GRAFANA_SERVICE_ACCOUNT_TOKEN" "$*"
EOF
  chmod +x "$STUB_BIN/mcp-grafana"
}

teardown() {
  sandbox_teardown
}

write_secret() {
  mkdir -p "$HOME/.secrets"
  printf 'GRAFANA_TOKEN=from-file\nGRAFANA_URL=https://file.example\n' > "$HOME/.secrets/grafana.env"
}

@test "grafana-mcp.sh: reads URL and token from ~/.secrets/grafana.env" {
  write_secret
  run sh "$LAUNCHER" --debug
  [ "$status" -eq 0 ]
  [ "$output" = "url=https://file.example token=from-file args=--debug" ]
}

@test "grafana-mcp.sh: already-exported values win over the file" {
  write_secret
  GRAFANA_URL=https://env.example GRAFANA_TOKEN=from-env run sh "$LAUNCHER"
  [ "$status" -eq 0 ]
  [ "$output" = "url=https://env.example token=from-env args=" ]
}

@test "grafana-mcp.sh: a partially-exported environment is completed from the file" {
  write_secret
  GRAFANA_TOKEN=from-env run sh "$LAUNCHER"
  [ "$status" -eq 0 ]
  [ "$output" = "url=https://file.example token=from-env args=" ]
}

@test "grafana-mcp.sh: fails clearly with no credentials anywhere" {
  run sh "$LAUNCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dj apply-secrets"* ]]
}

@test "grafana-mcp.sh: fails clearly when mcp-grafana is not installed" {
  write_secret
  rm "$STUB_BIN/mcp-grafana"
  PATH="$STUB_BIN:/usr/bin:/bin" run sh "$LAUNCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dj install-packages"* ]]
}
