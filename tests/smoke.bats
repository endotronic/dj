#!/usr/bin/env bats

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
}

teardown() {
  sandbox_teardown
}

@test "sandbox isolates HOME under SANDBOX dir" {
  [ -d "$HOME" ]
  case "$HOME" in
    "$SANDBOX"/*) ;;
    *) false ;;
  esac
}

@test "stub_cmd creates an executable that logs to stub.log" {
  stub_cmd hello
  run hello arg1 arg2
  [ "$status" -eq 0 ]
  [ "$(stub_log)" = "hello arg1 arg2" ]
}

@test "stub_called returns true after stub invocation" {
  stub_cmd hello
  hello x
  stub_called hello
}

@test "make_src_repo + add_to_repo + publish_repo produces a bare clone" {
  make_src_repo
  add_to_repo .bashrc "# hi"
  publish_repo
  [ -d "$BARE_REPO" ]
  run git --git-dir="$BARE_REPO" show HEAD:.bashrc
  [ "$status" -eq 0 ]
  [ "$output" = "# hi" ]
}
