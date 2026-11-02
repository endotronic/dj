#!/usr/bin/env bats
#
# Tests for the shared-git-key module's migrations.

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
  export DJ_MODULES=shared-git-key
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
}

teardown() {
  sandbox_teardown
}

# --- dotfiles-origin-ssh ----------------------------------------------------

setup_public_repo() {
  mkdir -p "$FAKE_ROOT"
  git init -q "$FAKE_ROOT"
  git -C "$FAKE_ROOT" remote add origin "$1"
}

@test "dotfiles-origin-ssh: N/A without a git-host key" {
  setup_public_repo https://github.com/u/r.git
  run sh "$MIGRATE" --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
}

@test "dotfiles-origin-ssh: pending when https and the key exists" {
  setup_public_repo https://github.com/u/r.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --only dotfiles-origin-ssh
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "dotfiles-origin-ssh: --fix rewrites https to the scp-style ssh form" {
  setup_public_repo https://github.com/u/r.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --fix --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
  [ "$(git -C "$FAKE_ROOT" remote get-url origin)" = 'git@github.com:u/r.git' ]
}

@test "dotfiles-origin-ssh: works for a self-hosted forge, not just github" {
  setup_public_repo https://git.example.com/alice/dotfiles.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --fix --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
  [ "$(git -C "$FAKE_ROOT" remote get-url origin)" = \
    'git@git.example.com:alice/dotfiles.git' ]
}

@test "dotfiles-origin-ssh: ok when origin is already ssh" {
  setup_public_repo git@github.com:u/r.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- ssh-machine-identity (manual) -----------------------------------------

@test "ssh-machine-identity: ok when the two keys differ" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C machine
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_githost"  -C forge
  run sh "$MIGRATE" --only ssh-machine-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "ssh-machine-identity: flagged MANUAL when machine key == git-host key" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C shared
  cp "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --only ssh-machine-identity
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"ssh-keygen"* ]]
}

@test "ssh-machine-identity: --fix never rotates the key on its own" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C shared
  cp "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_githost"
  before="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519" | awk '{print $2}')"
  run sh "$MIGRATE" --fix --only ssh-machine-identity
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [ "$(ssh-keygen -lf "$HOME/.ssh/id_ed25519" | awk '{print $2}')" = "$before" ]
}


@test "shared-git-key migrations don't exist while the module is disabled" {
  export DJ_MODULES=
  run sh "$MIGRATE" --list
  [[ "$output" != *"dotfiles-origin-ssh"* ]]
  [[ "$output" != *"ssh-machine-identity"* ]]
}
