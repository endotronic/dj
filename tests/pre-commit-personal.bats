#!/usr/bin/env bats
#
# Tests for scripts/pre-commit-personal.sh (the public repo's denylist
# hook) and scripts/install-public-hooks.sh (which links it in).

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export HOOK="$DOTFILES_REPO_ROOT/scripts/pre-commit-personal.sh"
  export INSTALL="$DOTFILES_REPO_ROOT/scripts/install-public-hooks.sh"
  export DJ_PERSONAL_DENYLIST="$SANDBOX/denylist.txt"
  printf '# comment\n\nbob\nbob.example.org\n' > "$DJ_PERSONAL_DENYLIST"

  TEST_REPO="$SANDBOX/test-repo"
  git init -q "$TEST_REPO"
  cd "$TEST_REPO"
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
}

teardown() {
  sandbox_teardown
}

@test "no denylist file: always passes" {
  rm "$DJ_PERSONAL_DENYLIST"
  echo "bob lives here" > a.txt
  git add a.txt
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "comment-only denylist: passes" {
  echo "# nothing" > "$DJ_PERSONAL_DENYLIST"
  echo "bob" > a.txt
  git add a.txt
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "clean staged change passes" {
  echo "hello alice on host1.example.com" > a.txt
  git add a.txt
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "denylisted word in an added line is rejected, with file and line" {
  printf 'ok\nssh bob@host1\n' > a.txt
  git add a.txt
  run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.txt:2: ssh bob@host1"* ]]
}

@test "match is case-insensitive" {
  echo "Hi BOB" > a.txt
  git add a.txt
  run sh "$HOOK"
  [ "$status" -eq 1 ]
}

@test "match is on word boundaries: bobcat is fine" {
  echo "a bobcat" > a.txt
  git add a.txt
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "a file name alone does not trip it" {
  echo "fine" > bob.txt
  git add bob.txt
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "removing a personal line is allowed" {
  echo "bob" > a.txt
  git add a.txt
  git commit -q --no-verify -m seed
  echo "clean" > a.txt
  git add a.txt
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "commit-msg mode rejects a personal message, ignoring # comments" {
  printf 'fix thing\n# bob in a comment\n' > msg
  run sh "$HOOK" msg
  [ "$status" -eq 0 ]
  printf 'fix thing for bob\n' > msg
  run sh "$HOOK" msg
  [ "$status" -eq 1 ]
  [[ "$output" == *"commit message"* ]]
}

@test "installed hooks make a real git commit fail, and --no-verify overrides" {
  DOTFILES_REPO_ROOT="$TEST_REPO" run sh "$INSTALL"
  [ "$status" -eq 0 ]
  # Point the repo's scripts/ at the real one for the symlink target.
  mkdir -p scripts
  cp "$HOOK" scripts/pre-commit-personal.sh
  DOTFILES_REPO_ROOT="$TEST_REPO" run sh "$INSTALL"
  [ -L .git/hooks/pre-commit ]
  [ -L .git/hooks/commit-msg ]
  echo "bob" > a.txt
  git add a.txt
  run git commit -m "add"
  [ "$status" -ne 0 ]
  run git commit --no-verify -m "add"
  [ "$status" -eq 0 ]
}

@test "install is idempotent and --check reports state" {
  mkdir -p scripts
  cp "$HOOK" scripts/pre-commit-personal.sh
  export DOTFILES_REPO_ROOT="$TEST_REPO"
  run sh "$INSTALL" --check
  [ "$status" -eq 1 ]
  sh "$INSTALL"
  sh "$INSTALL"
  run sh "$INSTALL" --check
  [ "$status" -eq 0 ]
}

@test "install leaves a hook of the user's own alone" {
  mkdir -p scripts
  cp "$HOOK" scripts/pre-commit-personal.sh
  printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  export DOTFILES_REPO_ROOT="$TEST_REPO"
  run sh "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -L .git/hooks/pre-commit ]
  [[ "$output" == *"own pre-commit hook"* ]]
  [ -L .git/hooks/commit-msg ]
}

@test "public-repo-guard migration: pending, then satisfied after fix" {
  mkdir -p scripts
  cp "$HOOK" scripts/pre-commit-personal.sh
  cp "$INSTALL" scripts/install-public-hooks.sh
  export DOTFILES_REPO_ROOT="$TEST_REPO" DJ_REPO_ROOT="$TEST_REPO"
  export DJ_MIGRATION_LIB="$BATS_TEST_DIRNAME/../scripts/lib/migration.sh"
  M="$BATS_TEST_DIRNAME/../migrations/66-public-repo-guard.sh"
  run sh "$M" check
  [ "$status" -eq 1 ]
  run sh "$M" fix
  [ "$status" -eq 0 ]
  run sh "$M" check
  [ "$status" -eq 0 ]
}
