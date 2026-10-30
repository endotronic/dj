#!/usr/bin/env bats
#
# Coverage for the Justfile's `claude` recipe: how it sorts its arguments
# into the launcher's flags, and what it does when there is nothing to run.
#
# The recipe is exercised for real, not with --dry-run: $HOME and the
# Justfile both point into a sandbox whose scripts/claude-local.sh is a stub
# that records the env, argv and stdin it got. That distinguishes "the
# recipe passes this" from "the recipe mentions this", which a dry run can't.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
  stub_dir_setup

  FAKE="$SANDBOX/dotfiles"
  mkdir -p "$FAKE/scripts" "$SANDBOX/home/.dotfiles"
  cp "$DOTFILES_REPO_ROOT/Justfile" "$FAKE/Justfile"

  # The launcher stub: records env, argv and whatever stdin it was given.
  # Nothing it writes is a real network path, so no test here can reach a
  # real proxy.
  cat > "$FAKE/scripts/claude-local.sh" <<EOF
#!/bin/sh
{
  printf 'GB=%s\n' "\${CLAUDE_LOCAL_DISABLE_GROWTHBOOK-<unset>}"
  for a in "\$@"; do printf 'A=%s\n' "\$a"; done
  printf 'STDIN=[%s]\n' "\$(cat)"
} > "$SANDBOX/launcher.args"
echo launcher-ran
exit \${LAUNCHER_STUB_STATUS:-0}
EOF
  chmod +x "$FAKE/scripts/claude-local.sh"

  # Just enough `claude` for the recipe's presence check; the launcher is
  # stubbed, so it is never actually run. PATH ends up as $STUB_BIN alone
  # (see finish_path) so a real claude on the host can't satisfy the check
  # by accident, and can't leak into any other part of the recipe either.
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$STUB_BIN/claude"

  # The recipe and its launcher shell out only to what's linked here, which
  # is the whole point: the sandbox can't reach the host's claude at all.
  for u in just sh bash cat printf grep sed rm mkdir ls mktemp sleep env; do
    p=$(command -v "$u" 2>/dev/null) && ln -sf "$p" "$STUB_BIN/$u"
  done

  export HOME="$SANDBOX/home"
  export PATH="$STUB_BIN"
  JUST="just --justfile $FAKE/Justfile"
}

teardown() {
  sandbox_teardown
}

# Launch the recipe with FILE on stdin (/dev/null by default: neither a
# terminal nor a pipe, which is exactly what a non-interactive caller has).
run_claude() {
  local file=/dev/null
  case "$1" in
    --stdin=*) file=${1#--stdin=}; shift ;;
  esac
  ( $JUST claude "$@" < "$file" )
}

launcher_arg() { printf '%s\n' "$1"; }
launcher_got() { grep -qxF "A=$1" "$SANDBOX/launcher.args" 2>/dev/null; }
launcher_misses() { ! launcher_got "$1"; }

@test "claude: a prompt becomes a one-shot query" {
  run run_claude "what is 2 plus 2"
  [ "$status" -eq 0 ]
  launcher_got '-p'
  launcher_got 'what is 2 plus 2'
}

@test "claude: runs through the local launcher and always enables auto-mode" {
  run run_claude hi
  [ "$status" -eq 0 ]
  [[ "$output" == *"launcher-ran"* ]]
  launcher_got '--enable-auto-mode'
}

@test "claude: no args and no terminal says so instead of failing obscurely" {
  # The bug this guards: with no tty and no prompt, claude silently drops
  # into print mode and errors about a --print flag the recipe never sent.
  run run_claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a terminal"* ]]
  [[ "$output" == *'dj claude "your question"'* ]]
  [[ "$output" != *"--print"* ]]
  [ ! -e "$SANDBOX/launcher.args" ]   # never launched anything
}

@test "claude: a piped prompt is read from stdin, not turned into a flag" {
  # The guard above must not swallow the legitimate `echo ... | dj claude`.
  printf 'a prompt from a pipe\n' > "$SANDBOX/prompt.txt"
  run run_claude --stdin="$SANDBOX/prompt.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"launcher-ran"* ]]
  grep -q '^STDIN=\[a prompt from a pipe\]$' "$SANDBOX/launcher.args"
  launcher_misses '-p'
}

@test "claude: Remote Control is off by default, and pinned off in settings" {
  # Off by default: this launcher exists to keep the session on the local
  # proxy, and RC mirrors it to Anthropic's bridge.
  run run_claude hi
  [ "$status" -eq 0 ]
  launcher_misses '--remote-control'
  launcher_got '{"remoteControlAtStartup":false}'
  grep -q '^GB=1$' "$SANDBOX/launcher.args"   # RC off, so flags may go
}

@test "claude: --remote-control opts in and re-enables feature flags" {
  # Remote Control refuses to run without feature-flag evaluation, so
  # opting in has to lift the GrowthBook disable.
  run run_claude --remote-control hi
  [ "$status" -eq 0 ]
  launcher_got '--remote-control'
  launcher_got '{"remoteControlAtStartup":true}'
  grep -q '^GB=0$' "$SANDBOX/launcher.args"
}

@test "claude: --no-remote-control keeps it off" {
  run run_claude --no-remote-control hi
  [ "$status" -eq 0 ]
  launcher_misses '--remote-control'
}

@test "claude: -y maps to --dangerously-skip-permissions anywhere in args" {
  run run_claude hi -y
  [ "$status" -eq 0 ]
  launcher_got '--dangerously-skip-permissions'
}

@test "claude: -r resumes instead of going one-shot" {
  run run_claude -r
  [ "$status" -eq 0 ]
  launcher_got '-r'
  launcher_misses '-p'
}

@test "claude: exits 127 when claude is not installed" {
  rm "$STUB_BIN/claude"
  # 127 is the point here, not a missing test binary.
  run -127 run_claude hi
  [ "$status" -eq 127 ]
  [[ "$output" == *"claude not on PATH"* ]]
}

@test "claude: propagates the launcher's exit status" {
  export LAUNCHER_STUB_STATUS=7
  run run_claude hi
  [ "$status" -eq 7 ]
}

@test "claude: -r skips -p even when both are given" {
  run run_claude -r -p hello
  [ "$status" -eq 0 ]
  launcher_got '-r'
  launcher_misses '-p'
}

# --- arguments keep their boundaries --------------------------------------
#
# The recipe reads "$@" rather than interpolating {{ARGS}}, which is the
# difference between handing claude the caller's words and handing this
# recipe's shell a line of text to re-parse. Pinned because the interpolated
# form has two failure modes that both look like success: a prompt containing
# $HOME or `id` was expanded and executed by the recipe shell, and the value
# of --settings arrived glued to whatever followed it.

@test "claude: a prompt with a dollar sign reaches the launcher verbatim" {
  run run_claude 'why does $GRAFANA_URL fail'
  [ "$status" -eq 0 ]
  launcher_got 'why does $GRAFANA_URL fail'
}

@test "claude: a prompt with command substitution is not executed" {
  marker="$SANDBOX/pwned"
  run run_claude "check \$(touch $marker)"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  launcher_got "check \$(touch $marker)"
}

@test "claude: --settings keeps its value as its own argument" {
  run run_claude --settings '{"model": "opus"}' hi
  [ "$status" -eq 0 ]
  # One --settings: the caller's, with the Remote Control guard dropped
  # rather than appended -- two would make the winner depend on order.
  [ "$(grep -c '^A=--settings$' "$SANDBOX/launcher.args")" -eq 1 ]
  launcher_got '{"model": "opus"}'
  launcher_got 'hi'
  launcher_misses '{"remoteControlAtStartup":false}'
}

@test "claude: a flag's value is not mistaken for the prompt" {
  # `--model opus hi` has two bare words and only one is the prompt.
  run run_claude --model opus hi
  [ "$status" -eq 0 ]
  launcher_got '--model'
  launcher_got 'opus'
  launcher_got 'hi'
  # ...and "opus" is not ALSO the prompt: exactly one -p, with "hi" after it.
  [ "$(grep -c '^A=-p$' "$SANDBOX/launcher.args")" -eq 1 ]
}

@test "claude: -r with a prompt passes both, and never -p" {
  run run_claude -r "continue this"
  [ "$status" -eq 0 ]
  launcher_got '-r'
  launcher_got 'continue this'
  launcher_misses '-p'
}
