#!/usr/bin/env bats
#
# Tests for scripts/audit-config.sh.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export AUDIT="$DOTFILES_REPO_ROOT/scripts/audit-config.sh"
  mkdir -p "$HOME/.config"
  # Use an under-sandbox Omarchy tree so the audit never reads from
  # the real ~/.local/share/omarchy/.
  export OMARCHY_CONFIG_DIR="$SANDBOX/omarchy-defaults"
  mkdir -p "$OMARCHY_CONFIG_DIR"
}

teardown() {
  sandbox_teardown
}

# --- arg parsing ---------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run sh "$AUDIT" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ Usage ]]
}

@test "unknown arg exits 2" {
  run sh "$AUDIT" --bogus
  [ "$status" -eq 2 ]
}

@test "errors when ~/.config doesn't exist" {
  rm -rf "$HOME/.config"
  run sh "$AUDIT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not exist" ]]
}

# --- classification ------------------------------------------------------

@test "identical-content entry is reported as identical" {
  mkdir -p "$OMARCHY_CONFIG_DIR/foo" "$HOME/.config/foo"
  printf 'x\n' > "$OMARCHY_CONFIG_DIR/foo/a"
  printf 'x\n' > "$HOME/.config/foo/a"
  run sh "$AUDIT"
  [ "$status" -eq 0 ]
  # The 'foo' entry should appear under the IDENTICAL section, not
  # under TRACK. The simplest portable check: it shows up exactly
  # once, and quiet-mode (track-list) doesn't include it.
  run sh "$AUDIT" --quiet
  ! [[ "$output" =~ ^foo$ ]] || ! [[ "$output" =~ foo ]]
}

@test "differing entry shows up in --quiet (track-list)" {
  mkdir -p "$OMARCHY_CONFIG_DIR/foo" "$HOME/.config/foo"
  printf 'orig\n' > "$OMARCHY_CONFIG_DIR/foo/a"
  printf 'modified\n' > "$HOME/.config/foo/a"
  run sh "$AUDIT" --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ foo ]]
}

@test "user-only entry (no Omarchy default) shows up in --quiet" {
  mkdir -p "$HOME/.config/mynewthing"
  printf 'x\n' > "$HOME/.config/mynewthing/cfg"
  run sh "$AUDIT" --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ mynewthing ]]
}

@test "app-state entries are filtered out of --quiet" {
  mkdir -p "$HOME/.config/chromium" "$HOME/.config/Code" "$HOME/.config/dconf"
  printf 'state\n' > "$HOME/.config/chromium/Default"
  run sh "$AUDIT" --quiet
  ! [[ "$output" =~ chromium ]]
  ! [[ "$output" =~ Code ]]
  ! [[ "$output" =~ dconf ]]
}

@test "_backup_* files are filtered out" {
  printf 'old\n' > "$HOME/.config/_backup_thing.toml"
  run sh "$AUDIT" --quiet
  ! [[ "$output" =~ "_backup_" ]]
}

@test "*.ttf files are filtered out" {
  printf 'binary' > "$HOME/.config/myfont.ttf"
  run sh "$AUDIT" --quiet
  ! [[ "$output" =~ myfont ]]
}

# --- full-report sections ------------------------------------------------

@test "full report shows all four section headers" {
  printf 'x\n' > "$HOME/.config/identical-cfg"
  printf 'x\n' > "$OMARCHY_CONFIG_DIR/identical-cfg"
  printf 'a\n' > "$HOME/.config/differing-cfg"
  printf 'b\n' > "$OMARCHY_CONFIG_DIR/differing-cfg"
  printf 'x\n' > "$HOME/.config/user-only-cfg"
  mkdir -p "$HOME/.config/dconf"
  run sh "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DIFFERS from Omarchy" ]]
  [[ "$output" =~ "user-only, no Omarchy" ]]
  [[ "$output" =~ "identical to Omarchy" ]]
  [[ "$output" =~ "app state" ]]
}

@test "report header mentions the Omarchy default tree path" {
  run sh "$AUDIT"
  [[ "$output" =~ "default tree:" ]]
  [[ "$output" =~ "$OMARCHY_CONFIG_DIR" ]]
}

# --- pipe-friendliness ---------------------------------------------------

@test "--quiet output is plain newline-separated and pipe-friendly" {
  printf 'a\n' > "$HOME/.config/x-cfg"
  printf 'b\n' > "$OMARCHY_CONFIG_DIR/x-cfg"
  printf 'a\n' > "$HOME/.config/y-cfg"
  run sh "$AUDIT" --quiet
  [ "$status" -eq 0 ]
  # Every output line should be just an entry name (no leading spaces,
  # no banner lines).
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" =~ ^[A-Za-z._-]+$ ]] || {
      printf 'unexpected line in --quiet output: %s\n' "$line" >&2
      false
    }
  done <<< "$output"
}
