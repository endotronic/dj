#!/usr/bin/env bats
#
# Tests for scripts/module.sh and how migrate.sh picks up module
# migrations.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  MODULE_SH="$DOTFILES_REPO_ROOT/scripts/module.sh"
  MIGRATE="$DOTFILES_REPO_ROOT/scripts/migrate.sh"
  DJ_MODULES_DIR="$SANDBOX/modules"
  export DJ_MODULES_DIR
  mkdir -p "$DJ_MODULES_DIR/alpha/migrations" "$DJ_MODULES_DIR/alpha/hooks" "$DJ_MODULES_DIR/beta"
  echo "The alpha feature" > "$DJ_MODULES_DIR/alpha/MODULE"
  echo "The beta feature" > "$DJ_MODULES_DIR/beta/MODULE"
  cat > "$DJ_MODULES_DIR/alpha/migrations/10-alpha-thing.sh" <<'MIG'
#!/bin/sh
. "${DJ_MIGRATION_LIB:?}"
desc() { echo "alpha thing is set up"; }
check() { return 1; }
fix() { :; }
migration_main "$@"
MIG
  printf '#!/bin/sh\necho "alpha pre-clone ran"\n' > "$DJ_MODULES_DIR/alpha/hooks/pre-clone.sh"
}

teardown() {
  sandbox_teardown
}

@test "list shows every module as off by default" {
  run sh "$MODULE_SH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"*"off"*"The alpha feature"* ]]
  [[ "$output" == *"beta"*"off"*"The beta feature"* ]]
}

@test "enable writes modules.txt once, and list shows it on" {
  run sh "$MODULE_SH" enable alpha
  [ "$status" -eq 0 ]
  run sh "$MODULE_SH" enable alpha
  [[ "$output" == *"already enabled"* ]]
  [ "$(grep -cx alpha "$HOME/.config/dj/modules.txt")" -eq 1 ]
  run sh "$MODULE_SH" list
  [[ "$output" == *"alpha"*"on"* ]]
  [[ "$output" == *"beta"*"off"* ]]
}

@test "disable removes it" {
  sh "$MODULE_SH" enable alpha beta
  run sh "$MODULE_SH" disable alpha
  [ "$status" -eq 0 ]
  ! grep -qx alpha "$HOME/.config/dj/modules.txt"
  grep -qx beta "$HOME/.config/dj/modules.txt"
}

@test "enabling an unknown module fails and writes nothing" {
  run sh "$MODULE_SH" enable nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such module"* ]]
  ! grep -qx nope "$HOME/.config/dj/modules.txt" 2>/dev/null
}

@test "enabled: exit status reflects modules.txt and DJ_MODULES" {
  run sh "$MODULE_SH" enabled alpha
  [ "$status" -ne 0 ]
  DJ_MODULES="beta, alpha" run sh "$MODULE_SH" enabled alpha
  [ "$status" -eq 0 ]
  sh "$MODULE_SH" enable beta
  run sh "$MODULE_SH" enabled beta
  [ "$status" -eq 0 ]
}

@test "hook runs only enabled modules' hooks for that phase" {
  run sh "$MODULE_SH" hook pre-clone
  [ "$status" -eq 0 ]
  [[ "$output" != *"alpha pre-clone ran"* ]]
  DJ_MODULES=alpha run sh "$MODULE_SH" hook pre-clone
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha pre-clone ran"* ]]
  DJ_MODULES=alpha run sh "$MODULE_SH" hook post-secrets
  [ "$status" -eq 0 ]
}

@test "migrate: a disabled module's migrations don't exist; an enabled one's run" {
  DOTFILES_REPO_ROOT="$SANDBOX/repo"
  export DOTFILES_REPO_ROOT
  mkdir -p "$DOTFILES_REPO_ROOT"
  run sh "$MIGRATE" --list
  [[ "$output" != *"alpha-thing"* ]]
  sh "$MODULE_SH" enable alpha
  run sh "$MIGRATE" --list
  [[ "$output" == *"alpha-thing"*"auto"* ]]
  run sh "$MIGRATE" --only alpha-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR    alpha thing is set up"* ]]
}
