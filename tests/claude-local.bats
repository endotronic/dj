#!/usr/bin/env bats
#
# Tests for scripts/claude-local.sh. uvx (the LiteLLM proxy), curl (its
# health check) and claude are stubbed; each test is fully sandboxed.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export CLAUDE_LOCAL="$DOTFILES_REPO_ROOT/scripts/claude-local.sh"
  CONF="$HOME/.config/claude-local"
  mkdir -p "$CONF"
  printf 'model_list: []\n' > "$CONF/litellm.yaml"
  cat > "$CONF/env" <<'EOF'
CLAUDE_LOCAL_MODEL=local-model
CLAUDE_LOCAL_CONTEXT=262144
CLAUDE_LOCAL_LITELLM_VERSION=9.9.9
EOF
  export VLLM_API_KEY=test-key
  export ANTHROPIC_API_KEY=should-be-unset
  export CLAUDE_LOCAL_STARTUP_TRIES=20

  # Only what the script and stubs need, so a real uvx/claude/curl on
  # this host can never leak into a test.
  for u in sh cat printf python3 od tr mktemp rm tail env sleep grep cut sed chmod ls mkdir; do
    p=$(command -v "$u" 2>/dev/null) && ln -sf "$p" "$STUB_BIN/$u"
  done
  export PATH="$STUB_BIN"

  # Fake proxy: record args + master key + pid, then stay up until killed.
  cat > "$STUB_BIN/uvx" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$SANDBOX/uvx.args"
printf '%s\n' "\$LITELLM_MASTER_KEY" > "$SANDBOX/uvx.key"
printf '%s\n' "\$\$" > "$SANDBOX/uvx.pid"
exec sleep 60
EOF
  # Health check succeeds once the fake proxy has started.
  cat > "$STUB_BIN/curl" <<EOF
#!/bin/sh
[ -f "$SANDBOX/uvx.pid" ]
EOF
  # Record the environment and args claude was launched with.
  cat > "$STUB_BIN/claude" <<EOF
#!/bin/sh
{
  printf 'BASE=%s\n' "\$ANTHROPIC_BASE_URL"
  printf 'HEADERS=%s\n' "\$ANTHROPIC_CUSTOM_HEADERS"
  printf 'MODEL=%s\n' "\$ANTHROPIC_MODEL"
  printf 'HAIKU=%s\n' "\$ANTHROPIC_DEFAULT_HAIKU_MODEL"
  printf 'CONTEXT=%s\n' "\$CLAUDE_CODE_MAX_CONTEXT_TOKENS"
  printf 'APIKEY=%s\n' "\${ANTHROPIC_API_KEY-<unset>}"
  printf 'ARGS=%s\n' "\$*"
} > "$SANDBOX/claude.env"
exit \${CLAUDE_STUB_STATUS:-0}
EOF
  chmod +x "$STUB_BIN/uvx" "$STUB_BIN/curl" "$STUB_BIN/claude"
}

teardown() {
  [ -f "$SANDBOX/uvx.pid" ] && kill "$(cat "$SANDBOX/uvx.pid")" 2>/dev/null
  sandbox_teardown
}

claude_env() { grep "^$1=" "$SANDBOX/claude.env" | cut -d= -f2-; }

@test "routes claude through a per-session proxy with the configured model" {
  run sh "$CLAUDE_LOCAL" -p hello
  [ "$status" -eq 0 ]

  [[ "$(claude_env BASE)" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]
  port=$(claude_env BASE | sed 's/.*://')
  [ "$(cat "$SANDBOX/uvx.args")" = "--quiet --from litellm[proxy]==9.9.9 litellm --config $CONF/litellm.yaml --host 127.0.0.1 --port $port" ]
  [ "$(claude_env HEADERS)" = "x-litellm-api-key: Bearer $(cat "$SANDBOX/uvx.key")" ]
  [ -n "$(cat "$SANDBOX/uvx.key")" ]
  [ "$(claude_env MODEL)" = local-model ]
  [ "$(claude_env HAIKU)" = local-model ]
  [ "$(claude_env CONTEXT)" = 262144 ]
  [ "$(claude_env APIKEY)" = "<unset>" ]
  [ "$(claude_env ARGS)" = "-p hello" ]
}

@test "stops the proxy and removes its temp dir when claude exits" {
  export TMPDIR="$SANDBOX/tmp"
  mkdir -p "$TMPDIR"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -eq 0 ]
  ! kill -0 "$(cat "$SANDBOX/uvx.pid")" 2>/dev/null
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "each session gets a fresh proxy key" {
  run sh "$CLAUDE_LOCAL"
  first=$(cat "$SANDBOX/uvx.key")
  rm -f "$SANDBOX/uvx.pid"
  run sh "$CLAUDE_LOCAL"
  [ "$first" != "$(cat "$SANDBOX/uvx.key")" ]
}

@test "propagates claude's exit status" {
  export CLAUDE_STUB_STATUS=3
  run sh "$CLAUDE_LOCAL"
  [ "$status" -eq 3 ]
}

@test "fails with the proxy log when the proxy dies during startup" {
  cat > "$STUB_BIN/uvx" <<'EOF'
#!/bin/sh
echo "boom: bad config"
exit 1
EOF
  printf '#!/bin/sh\nexit 7\n' > "$STUB_BIN/curl"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"boom: bad config"* ]]
  [[ "$output" == *"exited during startup"* ]]
  [ ! -f "$SANDBOX/claude.env" ]
}

@test "gives up when the proxy never becomes healthy" {
  printf '#!/bin/sh\nexit 7\n' > "$STUB_BIN/curl"
  export CLAUDE_LOCAL_STARTUP_TRIES=2
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not come up"* ]]
  [ ! -f "$SANDBOX/claude.env" ]
  ! kill -0 "$(cat "$SANDBOX/uvx.pid")" 2>/dev/null
}

@test "errors when the LiteLLM config is missing" {
  rm "$CONF/litellm.yaml"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing $CONF/litellm.yaml"* ]]
}

@test "errors when no model is configured" {
  printf 'CLAUDE_LOCAL_LITELLM_VERSION=9.9.9\n' > "$CONF/env"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_LOCAL_MODEL not set"* ]]
}

@test "errors when the LiteLLM version is not pinned" {
  printf 'CLAUDE_LOCAL_MODEL=local-model\n' > "$CONF/env"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_LOCAL_LITELLM_VERSION not set"* ]]
}

@test "errors when uvx is not installed" {
  rm "$STUB_BIN/uvx"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uvx not found"* ]]
}

@test "warns but still runs when VLLM_API_KEY is unset" {
  unset VLLM_API_KEY
  run sh "$CLAUDE_LOCAL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VLLM_API_KEY unset"* ]]
  [ -f "$SANDBOX/claude.env" ]
}

