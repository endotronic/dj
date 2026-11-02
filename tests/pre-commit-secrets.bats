#!/usr/bin/env bats
#
# Tests for scripts/pre-commit-secrets.sh: the git hook that rejects
# plaintext files staged under .private/secrets/.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export HOOK="$DOTFILES_REPO_ROOT/scripts/pre-commit-secrets.sh"

  # Each test runs in a fresh git repo so we can stage arbitrary
  # files without interfering with the dotfiles repo itself.
  TEST_REPO="$SANDBOX/test-repo"
  mkdir -p "$TEST_REPO/.private/secrets"
  git init -q "$TEST_REPO"
  cd "$TEST_REPO"
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
}

teardown() {
  sandbox_teardown
}

@test "empty staged set passes" {
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test ".private/secrets/foo.enc passes" {
  touch .private/secrets/foo.enc
  git add .private/secrets/foo.enc
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test ".private/secrets/bar.pub passes" {
  touch .private/secrets/bar.pub
  git add .private/secrets/bar.pub
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test ".private/secrets/README.md passes" {
  touch .private/secrets/README.md
  git add .private/secrets/README.md
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test ".private/secrets/manifest.txt.example passes" {
  touch .private/secrets/manifest.txt.example
  git add .private/secrets/manifest.txt.example
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test ".private/secrets/.gitkeep passes" {
  touch .private/secrets/.gitkeep
  git add .private/secrets/.gitkeep
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test ".private/secrets/bad-plaintext is rejected" {
  echo "API_KEY=oops" > .private/secrets/bad-plaintext
  git add .private/secrets/bad-plaintext
  run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" =~ .private/secrets/bad-plaintext ]]
}

@test ".private/secrets/bare.key (no allowed suffix) is rejected" {
  echo "private key" > .private/secrets/bare.key
  git add .private/secrets/bare.key
  run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" =~ .private/secrets/bare.key ]]
}

@test "non-secrets paths are unaffected" {
  echo "x" > some-tool.conf
  git add some-tool.conf
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "multiple offending files all listed in output" {
  echo "a" > .private/secrets/one
  echo "b" > .private/secrets/two
  touch .private/secrets/ok.enc
  git add .private/secrets/one .private/secrets/two .private/secrets/ok.enc
  run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" =~ .private/secrets/one ]]
  [[ "$output" =~ .private/secrets/two ]]
  # ok.enc should NOT be flagged
  if [[ "$output" =~ .private/secrets/ok\.enc ]]; then
    printf 'unexpectedly flagged .private/secrets/ok.enc:\n%s\n' "$output" >&2
    false
  fi
}

@test "nested path .private/secrets/foo/bar.enc passes" {
  mkdir -p .private/secrets/foo
  touch .private/secrets/foo/bar.enc
  git add .private/secrets/foo/bar.enc
  run sh "$HOOK"
  [ "$status" -eq 0 ]
}

@test "nested plaintext .private/secrets/foo/bar is rejected" {
  mkdir -p .private/secrets/foo
  echo "secret" > .private/secrets/foo/bar
  git add .private/secrets/foo/bar
  run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" =~ .private/secrets/foo/bar ]]
}
