#!/usr/bin/env bats
#
# Tests for the claude module's migrations: claude-statusline and
# claude-secrets-rules (Claude Code settings.json merges).

load test_helper

MIGRATE="$DOTFILES_REPO_ROOT/scripts/migrate.sh"

setup() {
  sandbox_setup
  stub_dir_setup
  FAKE_ROOT="$SANDBOX/repo"
  mkdir -p "$FAKE_ROOT/scripts"
  export DOTFILES_REPO_ROOT="$FAKE_ROOT"
  export DOT_DIR="$HOME/.config.git"
  export DOTFILES_BACKUP_DIR="$SANDBOX/backup"
  export DJ_MODULES=claude
}

teardown() {
  sandbox_teardown
}

# --- claude-statusline ------------------------------------------------------

statusline_script() {
  mkdir -p "$HOME/.claude"
  printf '#!/usr/bin/env bash\n' > "$HOME/.claude/statusline-command.sh"
}

@test "claude-statusline: N/A without the tracked script" {
  run sh "$MIGRATE" --only claude-statusline
  [ "$status" -eq 0 ]
  [[ "$output" != *"statusline"* ]]
}

@test "claude-statusline: pending when settings.json is missing" {
  statusline_script
  run sh "$MIGRATE" --only claude-statusline
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "claude-statusline: --fix creates settings.json, then reports ok" {
  statusline_script
  run sh "$MIGRATE" --fix --only claude-statusline
  [ "$status" -eq 0 ]
  [ "$(jq -r .statusLine.command "$HOME/.claude/settings.json")" = "bash $HOME/.claude/statusline-command.sh" ]
  run sh "$MIGRATE" --only claude-statusline
  [ "$status" -eq 0 ]
}

@test "claude-statusline: --fix merges, preserving other settings" {
  statusline_script
  printf '{"theme":"dark","permissions":{"defaultMode":"auto"}}\n' > "$HOME/.claude/settings.json"
  run sh "$MIGRATE" --fix --only claude-statusline
  [ "$status" -eq 0 ]
  [ "$(jq -r .theme "$HOME/.claude/settings.json")" = "dark" ]
  [ "$(jq -r .permissions.defaultMode "$HOME/.claude/settings.json")" = "auto" ]
  [ "$(jq -r .statusLine.type "$HOME/.claude/settings.json")" = "command" ]
}

@test "claude-statusline: --fix replaces a stale command" {
  statusline_script
  printf '{"statusLine":{"type":"command","command":"bash /old/home/.claude/statusline-command.sh"}}\n' > "$HOME/.claude/settings.json"
  run sh "$MIGRATE" --fix --only claude-statusline
  [ "$status" -eq 0 ]
  [ "$(jq -r .statusLine.command "$HOME/.claude/settings.json")" = "bash $HOME/.claude/statusline-command.sh" ]
}

# --- claude-secrets-rules ---------------------------------------------------

# The migration reads settings.json (Claude Code's own, untracked file) and
# registers the module's secrets-gate.sh, which ships beside it.
secrets_gate() { :; }

secrets_claude() {
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$STUB_BIN/claude"
}

@test "claude-secrets-rules: N/A without claude on PATH" {
  secrets_gate
  PATH="$STUB_BIN:/usr/bin:/bin" run sh "$MIGRATE" --only claude-secrets-rules
  [ "$status" -eq 0 ]
  [[ "$output" != *"secrets-rules"* ]]
}

@test "claude-secrets-rules: pending when settings.json is missing" {
  secrets_gate
  secrets_claude
  run sh "$MIGRATE" --only claude-secrets-rules
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "claude-secrets-rules: --fix creates settings.json with deny rules, hook and env" {
  secrets_gate
  secrets_claude
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  [ "$status" -eq 0 ]
  sf="$HOME/.claude/settings.json"
  [ "$(jq -r .env.DOTFILES_SKIP_SECRETS "$sf")" = "1" ]
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$sf")" = "Bash" ]
  [[ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$sf")" == *"modules/claude/secrets-gate.sh"* ]]
  # Rules use Claude Code's //absolute path syntax (see settings.local.json).
  jq -e '.permissions.deny | index("Read(//'"${HOME#/}"'/.secrets/**)") != null' "$sf" >/dev/null
  jq -e '.permissions.deny | index("Read(//'"${HOME#/}"'/.ssh/*id_*)") != null' "$sf" >/dev/null
  run sh "$MIGRATE" --only claude-secrets-rules
  [ "$status" -eq 0 ]
}

@test "claude-secrets-rules: --fix preserves everything else in settings.json" {
  secrets_gate
  secrets_claude
  mkdir -p "$HOME/.claude"
  printf '{"theme":"dark","permissions":{"defaultMode":"auto","allow":["Bash(git *)"]},"model":"sonnet"}\n' \
    > "$HOME/.claude/settings.json"
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  [ "$status" -eq 0 ]
  sf="$HOME/.claude/settings.json"
  [ "$(jq -r .theme "$sf")" = "dark" ]
  [ "$(jq -r .model "$sf")" = "sonnet" ]
  [ "$(jq -r .permissions.defaultMode "$sf")" = "auto" ]
  [ "$(jq -r '.permissions.allow[0]' "$sf")" = "Bash(git *)" ]
  [ "$(jq -r '.permissions.deny | length' "$sf")" -gt 10 ]
}

@test "claude-secrets-rules: --fix twice is a no-op and never duplicates" {
  secrets_gate
  secrets_claude
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  n1=$(jq '.permissions.deny | length' "$HOME/.claude/settings.json")
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  [ "$status" -eq 0 ]
  [ "$(jq '.permissions.deny | length' "$HOME/.claude/settings.json")" = "$n1" ]
  [ "$(jq '.hooks.PreToolUse | length' "$HOME/.claude/settings.json")" = 1 ]
}

@test "claude-secrets-rules: --fix keeps an existing unrelated PreToolUse hook" {
  secrets_gate
  secrets_claude
  mkdir -p "$HOME/.claude"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"sh /usr/bin/true"}]}]}}\n' \
    > "$HOME/.claude/settings.json"
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  [ "$status" -eq 0 ]
  sf="$HOME/.claude/settings.json"
  [ "$(jq '.hooks.PreToolUse | length' "$sf")" = 2 ]
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$sf")" = "Edit" ]
}


@test "claude-secrets-rules: a gate registered at an old path is pending, and --fix replaces it" {
  # A machine set up before the gate moved still names the old file, which
  # no longer exists: Claude Code can't run it, so the gate is silently off.
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"sh /old/scripts/claude-secrets-gate.sh"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"sh /x/other.sh"},
                             {"type":"command","command":"sh /old2/secrets-gate.sh"}]}]}}
EOF
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  [ "$status" -eq 0 ]
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  [ "$status" -eq 0 ]
  run sh "$MIGRATE" --only claude-secrets-rules
  [ "$status" -eq 0 ]
  sf="$HOME/.claude/settings.json"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | test("secrets-gate"))] | length' "$sf")" -eq 1 ]
  [[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("secrets-gate"))][0]' "$sf")" == *"modules/claude/secrets-gate.sh" ]]
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "sh /x/other.sh")] | length' "$sf")" -eq 1 ]
  [ "$(jq '.hooks.PreToolUse | length' "$sf")" -eq 2 ]
}

@test "claude-secrets-rules: secret-paths.txt entries become deny rules too" {
  secrets_claude
  mkdir -p "$HOME/.config/dj/claude"
  printf '.config/someapp/token\n' > "$HOME/.config/dj/claude/secret-paths.txt"
  run sh "$MIGRATE" --fix --only claude-secrets-rules
  [ "$status" -eq 0 ]
  jq -e '.permissions.deny | index("Read(//'"${HOME#/}"'/.config/someapp/token)") != null' \
    "$HOME/.claude/settings.json" >/dev/null
}

@test "claude migrations don't exist while the module is disabled" {
  export DJ_MODULES=
  run sh "$MIGRATE" --list
  [[ "$output" != *"claude-"* ]]
}

# --- claude-local-context -----------------------------------------------------
#
# The link lands in the real checkout, so these tests run against a copy of
# the repo instead.

copy_repo() {
  COPY="$SANDBOX/dj"
  mkdir -p "$COPY"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$BATS_TEST_DIRNAME/../migrations" \
        "$BATS_TEST_DIRNAME/../modules" "$COPY/"
  export DJ_MODULES_DIR="$COPY/modules"
  MIGRATE="$COPY/scripts/migrate.sh"
}

@test "claude-local-context: N/A without ~/.config/dj/AGENTS.md" {
  copy_repo
  run sh "$MIGRATE" --only claude-local-context
  [ "$status" -eq 0 ]
  [[ "$output" != *"CLAUDE.local.md"* ]]
}

@test "claude-local-context: --fix links the notes, then reports ok" {
  copy_repo
  mkdir -p "$HOME/.config/dj"
  echo "# my machines" > "$HOME/.config/dj/AGENTS.md"
  run sh "$MIGRATE" --only claude-local-context
  [ "$status" -eq 1 ]
  run sh "$MIGRATE" --fix --only claude-local-context
  [ "$status" -eq 0 ]
  [ "$(readlink "$COPY/CLAUDE.local.md")" = "$HOME/.config/dj/AGENTS.md" ]
  run sh "$MIGRATE" --only claude-local-context
  [ "$status" -eq 0 ]
}

@test "claude-local-context: a real CLAUDE.local.md is backed up, not clobbered" {
  copy_repo
  mkdir -p "$HOME/.config/dj"
  echo "# my machines" > "$HOME/.config/dj/AGENTS.md"
  echo "# hand-written" > "$COPY/CLAUDE.local.md"
  run sh "$MIGRATE" --fix --only claude-local-context
  [ "$status" -eq 0 ]
  [ -L "$COPY/CLAUDE.local.md" ]
  grep -q hand-written "$SANDBOX/backup/CLAUDE.local.md"
}
