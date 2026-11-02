#!/usr/bin/env bats
#
# Tests for bin/dj and the Justfile recipes that aren't thin wrappers.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
  stub_dir_setup
  command -v just >/dev/null 2>&1 || skip "just not installed"
  DJ="$DOTFILES_REPO_ROOT/bin/dj"
}

teardown() {
  sandbox_teardown
}

@test "dj with no arguments lists recipes" {
  run "$DJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync"* ]]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"module"* ]]
}

@test "dj works through a symlink elsewhere on PATH" {
  ln -s "$DJ" "$STUB_BIN/dj"
  run dj --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync"* ]]
}

@test "dj explains a missing just" {
  farm="$SANDBOX/farm"; mkdir -p "$farm"
  for c in sh dirname readlink; do ln -s "$(command -v $c)" "$farm/$c"; done
  PATH="$farm" run -127 "$DJ"
  [ "$status" -eq 127 ]
  [[ "$output" == *"'just' is not installed"* ]]
}

@test "system-type: persists a valid type, rejects a bad one, clears with none" {
  run "$DJ" system-type laptop
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CONFIG_HOME/dotfiles/system-type")" = laptop ]
  run "$DJ" system-type 'bad type'
  [ "$status" -eq 2 ]
  run "$DJ" system-type none
  [ ! -f "$XDG_CONFIG_HOME/dotfiles/system-type" ]
}

@test "arguments reach recipes intact: backticks and spaces are not re-parsed" {
  run "$DJ" system-type 'a`touch $HOME/pwned`b'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/pwned" ]
}

@test "add: relative paths resolve against where dj was run" {
  git init -q --bare "$HOME/.config.git"
  mkdir -p "$HOME/proj"
  echo x > "$HOME/proj/file"
  cd "$HOME/proj"
  run "$DJ" add file
  [ "$status" -eq 0 ]
  git --git-dir="$HOME/.config.git" --work-tree="$HOME" diff --cached --name-only | grep -qx proj/file
}

@test "a module recipe guard explains how to enable the module" {
  run "$DJ" _require-module nosuchmodule
  [ "$status" -eq 2 ]
  [[ "$output" == *"dj module enable nosuchmodule"* ]]
}

@test "module: lists modules" {
  run "$DJ" module list
  [ "$status" -eq 0 ]
}
