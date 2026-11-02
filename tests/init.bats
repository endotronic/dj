#!/usr/bin/env bats
#
# Tests for scripts/init.sh (dj init).

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  INIT="$DOTFILES_REPO_ROOT/scripts/init.sh"
  git init -q --bare "$HOME/.config.git"
  git --git-dir="$HOME/.config.git" config user.email alice@example.com
  git --git-dir="$HOME/.config.git" config user.name alice
  git --git-dir="$HOME/.config.git" config commit.gpgsign false
  export PRIVATE_DIR="$HOME/.private"
}

teardown() {
  sandbox_teardown
}

staged() { git --git-dir="$HOME/.config.git" --work-tree="$HOME" diff --cached --name-only; }

@test "refuses without a private repo" {
  rm -rf "$HOME/.config.git"
  run sh "$INIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run install.sh first"* ]]
}

@test "scaffolds the lists and modules.txt and stages them" {
  run sh "$INIT"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/dj/packages/common.txt" ]
  [ -f "$HOME/.config/dj/postinstall/common.txt" ]
  [ -f "$HOME/.config/dj/modules.txt" ]
  staged | grep -qx '.config/dj/packages/common.txt'
  staged | grep -qx '.config/dj/modules.txt'
  [[ "$output" == *"dot remote add origin"* ]]
}

@test "keeps an existing list as it is" {
  mkdir -p "$HOME/.config/dj/packages"
  printf 'mine\n' > "$HOME/.config/dj/packages/common.txt"
  run sh "$INIT"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/dj/packages/common.txt")" = mine ]
}

@test "stages the shell layer when there is one" {
  printf '# loader\n' > "$HOME/.bashrc"
  run sh "$INIT"
  staged | grep -qx '.bashrc'
}

@test "--remote sets origin, --commit commits" {
  run sh "$INIT" --remote git@example.com:alice/config.git --commit
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$HOME/.config.git" remote get-url origin)" = git@example.com:alice/config.git ]
  git --git-dir="$HOME/.config.git" rev-parse --verify -q HEAD >/dev/null
  [[ "$output" != *"dot remote add origin"* ]]
}

@test "does nothing to a repo that already has commits" {
  sh "$INIT" --commit >/dev/null
  rm "$HOME/.config/dj/modules.txt"
  run sh "$INIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has commits"* ]]
  [ ! -f "$HOME/.config/dj/modules.txt" ]
}
