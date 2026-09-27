#!/usr/bin/env bats
#
# Tests for scripts/claude-local.sh. The script spawns nothing, so the
# only stub is `claude` itself, which records the env it was launched
# with; each test is fully sandboxed.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export CLAUDE_LOCAL="$DOTFILES_REPO_ROOT/scripts/claude-local.sh"
  CONF="$HOME/.config/claude-local"
  mkdir -p "$CONF"
  cat > "$CONF/env" <<'EOF'
CLAUDE_LOCAL_MODEL=local-model
CLAUDE_LOCAL_CONTEXT=262144
CLAUDE_LOCAL_PROXY_URL=https://litellm.example.invalid
EOF
  export LITELLM_MASTER_KEY=shared-test-key
  export ANTHROPIC_API_KEY=should-be-unset

  # Only what the script and stubs need, so a real claude on this host
  # can never leak into a test.
  for u in sh cat printf grep cut sed rm mkdir ls env; do
    p=$(command -v "$u" 2>/dev/null) && ln -sf "$p" "$STUB_BIN/$u"
  done
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
  printf 'AUTHTOKEN=%s\n' "\${ANTHROPIC_AUTH_TOKEN-<unset>}"
  printf 'ARGS=%s\n' "\$*"
} > "$SANDBOX/claude.env"
exit \${CLAUDE_STUB_STATUS:-0}
EOF
  chmod +x "$STUB_BIN/claude"
  export PATH="$STUB_BIN"
}

teardown() {
  sandbox_teardown
}

claude_env() { grep "^$1=" "$SANDBOX/claude.env" | cut -d= -f2-; }

@test "routes claude to the shared proxy with the configured model" {
  run sh "$CLAUDE_LOCAL" -p hello
  [ "$status" -eq 0 ]

  [ "$(claude_env BASE)" = "https://litellm.example.invalid" ]
  [ "$(claude_env HEADERS)" = "x-litellm-api-key: Bearer shared-test-key" ]
  [ "$(claude_env MODEL)" = local-model ]
  [ "$(claude_env HAIKU)" = local-model ]
  [ "$(claude_env CONTEXT)" = 262144 ]
  [ "$(claude_env APIKEY)" = "<unset>" ]
  [ "$(claude_env AUTHTOKEN)" = "<unset>" ]
  [ "$(claude_env ARGS)" = "-p hello" ]
}

@test "spawns nothing: succeeds with no uvx or curl on PATH" {
  export TMPDIR="$SANDBOX/tmp"
  mkdir -p "$TMPDIR"
  # setup() puts no uvx/curl stubs on PATH: any attempt to start a
  # per-session proxy would fail here.
  run sh "$CLAUDE_LOCAL"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "propagates claude's exit status" {
  export CLAUDE_STUB_STATUS=3
  run sh "$CLAUDE_LOCAL"
  [ "$status" -eq 3 ]
}

@test "errors when no model is configured" {
  printf 'CLAUDE_LOCAL_CONTEXT=262144\nCLAUDE_LOCAL_PROXY_URL=https://litellm.example.invalid\n' > "$CONF/env"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_LOCAL_MODEL not set"* ]]
}

@test "errors when the proxy URL is not configured" {
  printf 'CLAUDE_LOCAL_MODEL=local-model\n' > "$CONF/env"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_LOCAL_PROXY_URL not set"* ]]
}

@test "errors when the master key is missing" {
  unset LITELLM_MASTER_KEY
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"LITELLM_MASTER_KEY unset"* ]]
  [ ! -f "$SANDBOX/claude.env" ]
}

@test "errors when claude is not installed" {
  rm "$STUB_BIN/claude"
  run sh "$CLAUDE_LOCAL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude not found"* ]]
}
