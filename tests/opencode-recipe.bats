#!/usr/bin/env bats
#
# Coverage for the opencode module's `dj opencode` recipe, run for real
# against a stub opencode that records its argv.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup

  cat > "$STUB_BIN/opencode" <<EOF
#!/bin/sh
for a in "\$@"; do printf 'A=%s\n' "\$a"; done > "$SANDBOX/opencode.args"
exit \${OPENCODE_STUB_STATUS:-0}
EOF
  chmod +x "$STUB_BIN/opencode"

  for u in just sh cat printf grep sed rm mkdir ls awk tr dirname; do
    p=$(command -v "$u" 2>/dev/null) && ln -sf "$p" "$STUB_BIN/$u"
  done
  export PATH="$STUB_BIN"
  export DJ_MODULES=opencode
  JUST="just --justfile $DOTFILES_REPO_ROOT/Justfile"
}

teardown() {
  sandbox_teardown
}

got() { grep -qxF "A=$1" "$SANDBOX/opencode.args"; }

@test "opencode: a prompt becomes a one-shot run with the words intact" {
  run $JUST opencode what is this repo
  [ "$status" -eq 0 ]
  got run
  got 'what is this repo'
}

@test "opencode: -y maps to --auto" {
  run $JUST opencode -y hi
  [ "$status" -eq 0 ]
  got --auto
}

@test "opencode: -r resumes with --continue instead of a one-shot run" {
  run $JUST opencode -r
  [ "$status" -eq 0 ]
  got --continue
  ! got run
}

@test "opencode: a resume value with a space stays one argument" {
  run $JUST opencode -s 'my session'
  [ "$status" -eq 0 ]
  got -s
  got 'my session'
}

@test "opencode: a resume value with glob characters is not expanded" {
  # The recipe runs in the repo root, where LICENS? would match LICENSE.
  run $JUST opencode -s 'LICENS?'
  [ "$status" -eq 0 ]
  got 'LICENS?'
  ! got LICENSE
}

@test "opencode: -r becomes --continue, and --auto still goes last" {
  run $JUST opencode -y -r
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/opencode.args")" = $'A=--continue\nA=--auto' ]
}

@test "opencode: no args opens the TUI" {
  run $JUST opencode
  [ "$status" -eq 0 ]
  ! got run
}

@test "opencode: the o alias works" {
  run $JUST o hi
  [ "$status" -eq 0 ]
  got hi
}

@test "opencode: refuses with a hint when the module is disabled" {
  export DJ_MODULES=
  run $JUST opencode hi
  [ "$status" -eq 2 ]
  [[ "$output" == *"dj module enable opencode"* ]]
  [ ! -e "$SANDBOX/opencode.args" ]
}
