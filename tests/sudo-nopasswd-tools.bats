#!/usr/bin/env bats
#
# Tests for packages/postinstall/sudo-nopasswd-tools.sh -- the hook behind
# the sudo-nopasswd-tools migration (tests/migrate.bats covers the
# migration's own check/fix flow around it).
#
# The sandbox only PREPENDS $STUB_BIN to PATH, so the host's own wg /
# docker would always be visible; PATH is swapped for a farm of symlinks to
# just the binaries the hook calls, plus whichever tool stubs a test adds.

load test_helper

HOOK="$DOTFILES_REPO_ROOT/packages/postinstall/sudo-nopasswd-tools.sh"

setup() {
  sandbox_setup
  stub_dir_setup
  [ "$(uname -s)" = Linux ] || skip "sudoers.d is Linux-only"
  [ "$(id -u)" -ne 0 ] || skip "needs a non-root user"

  export DOTFILES_SUDOERS_DIR="$SANDBOX/sudoers.d"
  mkdir -p "$DOTFILES_SUDOERS_DIR"

  local farm="$SANDBOX/farm" c src
  mkdir -p "$farm"
  for c in sh cat chmod cmp cp grep id install ls mkdir mktemp paste rm rmdir sed stat tr uname; do
    src="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$src" ] && ln -sf "$src" "$farm/$c"
  done
  export PATH="$STUB_BIN:$farm"

  # The sandbox has no privilege to drop, so sudo just runs its arguments.
  printf '#!/bin/sh\nexec "$@"\n' > "$STUB_BIN/sudo"
  printf '#!/bin/sh\n[ "${VISUDO_FAIL:-0}" = 1 ] && exit 1\nexit 0\n' > "$STUB_BIN/visudo"
  chmod +x "$STUB_BIN/sudo" "$STUB_BIN/visudo"
}

teardown() {
  sandbox_teardown
}

stub_tool() {
  printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$1"
  chmod +x "$STUB_BIN/$1"
}

dropin() { printf '%s/dj-nopasswd-%s' "$DOTFILES_SUDOERS_DIR" "$(id -un)"; }

@test "sudo-nopasswd-tools: passes sh -n" {
  run sh -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "sudo-nopasswd-tools: an unknown argument exits 2" {
  run sh "$HOOK" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "sudo-nopasswd-tools: --specs prints nothing when no tool is installed" {
  run sh "$HOOK" --specs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sudo-nopasswd-tools: --specs limits wg to show and leaves docker and zfs unrestricted" {
  stub_tool wg
  stub_tool docker
  stub_tool zfs
  run sh "$HOOK" --specs
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$STUB_BIN/wg show *" ]
  [ "${lines[1]}" = "$STUB_BIN/docker" ]
  [ "${lines[2]}" = "$STUB_BIN/zfs" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "sudo-nopasswd-tools: --specs only lists the tools that are installed" {
  stub_tool docker
  run sh "$HOOK" --specs
  [ "$output" = "$STUB_BIN/docker" ]
}

@test "sudo-nopasswd-tools: --specs prints nothing without a sudoers.d directory" {
  stub_tool docker
  rmdir "$DOTFILES_SUDOERS_DIR"
  run sh "$HOOK" --specs
  [ -z "$output" ]
}

@test "sudo-nopasswd-tools: --specs prints nothing when visudo is missing" {
  stub_tool docker
  rm "$STUB_BIN/visudo"
  run sh "$HOOK" --specs
  [ -z "$output" ]
}

@test "sudo-nopasswd-tools: skips cleanly where it does not apply" {
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not applicable"* ]]
  [ -z "$(ls -A "$DOTFILES_SUDOERS_DIR")" ]
}

@test "sudo-nopasswd-tools: installs a 0440 drop-in scoped to this user and the installed tools" {
  stub_tool wg
  stub_tool docker
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  [ -f "$(dropin)" ]
  [ "$(stat -c %a "$(dropin)")" = 440 ]
  grep -qF "$(id -un) ALL=(root) NOPASSWD: $STUB_BIN/wg show *, $STUB_BIN/docker" "$(dropin)"
  [[ "$output" == *"revoke with: sudo rm"* ]]
}

@test "sudo-nopasswd-tools: running twice leaves the same drop-in" {
  stub_tool docker
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  cp "$(dropin)" "$SANDBOX/first"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  cmp "$(dropin)" "$SANDBOX/first"
}

@test "sudo-nopasswd-tools: refuses to install a rule visudo rejects" {
  stub_tool docker
  VISUDO_FAIL=1 run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed visudo validation"* ]]
  [ ! -e "$(dropin)" ]
}

@test "sudo-nopasswd-tools: leaves no temp file behind" {
  stub_tool docker
  export TMPDIR="$SANDBOX/tmp"
  mkdir -p "$TMPDIR"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
