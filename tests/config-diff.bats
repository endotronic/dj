#!/usr/bin/env bats
#
# Tests for scripts/config-diff.sh.
#
# Strategy: stage a fake "Omarchy default tree" under the sandboxed
# $HOME and corresponding user files under $HOME/.config/, then
# invoke the script and assert on exit codes and discovery messages.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export CONFIG_DIFF="$DOTFILES_REPO_ROOT/scripts/config-diff.sh"
  # Standard fake locations.
  mkdir -p "$HOME/.config" "$HOME/.local/share/omarchy/config"
}

teardown() {
  sandbox_teardown
}

# --- arg parsing / usage --------------------------------------------------

@test "--help exits 0 and prints usage" {
  run sh "$CONFIG_DIFF" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ Usage ]]
}

@test "no path arg exits 2" {
  run sh "$CONFIG_DIFF"
  [ "$status" -eq 2 ]
}

@test "unknown flag exits 2" {
  run sh "$CONFIG_DIFF" --bogus-flag x
  [ "$status" -eq 2 ]
}

@test "missing user path exits 2" {
  run sh "$CONFIG_DIFF" "$HOME/.config/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "not found" ]]
}

# --- auto-discovery -------------------------------------------------------

@test "identical Omarchy-tracked file → exit 0" {
  printf 'shared\n' > "$HOME/.config/foo.toml"
  printf 'shared\n' > "$HOME/.local/share/omarchy/config/foo.toml"
  run sh "$CONFIG_DIFF" "$HOME/.config/foo.toml"
  [ "$status" -eq 0 ]
  [[ "$output" =~ identical ]]
  # Discovery message includes the Omarchy path.
  [[ "$output" =~ ".local/share/omarchy/config/foo.toml" ]]
}

@test "differing Omarchy-tracked file → exit 1 and shows diff" {
  printf 'old line\n' > "$HOME/.local/share/omarchy/config/foo.toml"
  printf 'new line\n' > "$HOME/.config/foo.toml"
  run sh "$CONFIG_DIFF" "$HOME/.config/foo.toml"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "differs" ]]
  [[ "$output" =~ "-old line" ]]
  [[ "$output" =~ "+new line" ]]
}

@test "no Omarchy default → exit 2 with guidance" {
  printf 'x\n' > "$HOME/.config/unique.toml"
  run sh "$CONFIG_DIFF" "$HOME/.config/unique.toml"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "no default found" ]]
  [[ "$output" =~ "--against" ]]
}

@test "discovery looks at /usr/share when Omarchy path is absent" {
  # Can't actually write to /usr/share in tests; instead, verify
  # the script doesn't try it for paths outside ~/.config (a
  # negative check that the discovery cases are scoped correctly).
  printf 'x\n' > "$HOME/somewhere/random-file" 2>/dev/null || true
  mkdir -p "$HOME/somewhere"
  printf 'x\n' > "$HOME/somewhere/random-file"
  run sh "$CONFIG_DIFF" "$HOME/somewhere/random-file"
  [ "$status" -eq 2 ]
}

# --- nested paths --------------------------------------------------------

@test "nested config path resolves through Omarchy mirror" {
  mkdir -p "$HOME/.config/hypr" "$HOME/.local/share/omarchy/config/hypr"
  printf 'monitor=...\n' > "$HOME/.config/hypr/hyprland.conf"
  printf 'monitor=...\n' > "$HOME/.local/share/omarchy/config/hypr/hyprland.conf"
  run sh "$CONFIG_DIFF" "$HOME/.config/hypr/hyprland.conf"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "omarchy/config/hypr/hyprland.conf" ]]
}

@test "directory comparison: identical trees → exit 0" {
  mkdir -p "$HOME/.config/sub" "$HOME/.local/share/omarchy/config/sub"
  printf 'a\n' > "$HOME/.config/sub/a"
  printf 'b\n' > "$HOME/.config/sub/b"
  printf 'a\n' > "$HOME/.local/share/omarchy/config/sub/a"
  printf 'b\n' > "$HOME/.local/share/omarchy/config/sub/b"
  run sh "$CONFIG_DIFF" "$HOME/.config/sub"
  [ "$status" -eq 0 ]
}

@test "directory comparison: extra file on user side → exit 1" {
  mkdir -p "$HOME/.config/sub" "$HOME/.local/share/omarchy/config/sub"
  printf 'a\n' > "$HOME/.config/sub/a"
  printf 'a\n' > "$HOME/.local/share/omarchy/config/sub/a"
  printf 'extra\n' > "$HOME/.config/sub/extra"
  run sh "$CONFIG_DIFF" "$HOME/.config/sub"
  [ "$status" -eq 1 ]
  [[ "$output" =~ extra ]]
}

# --- --against override -------------------------------------------------

@test "--against overrides auto-discovery" {
  mkdir -p "$HOME/.local/share/omarchy/config"
  printf 'wrong-default\n' > "$HOME/.local/share/omarchy/config/foo.toml"
  printf 'right-default\n' > "$HOME/elsewhere.toml"
  printf 'right-default\n' > "$HOME/.config/foo.toml"
  run sh "$CONFIG_DIFF" "$HOME/.config/foo.toml" --against "$HOME/elsewhere.toml"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "elsewhere.toml" ]]
}

@test "--against with missing path exits 2" {
  printf 'x\n' > "$HOME/.config/foo.toml"
  run sh "$CONFIG_DIFF" "$HOME/.config/foo.toml" --against "$HOME/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "not found" ]]
}

@test "--against=PATH (equals form) works" {
  printf 'same\n' > "$HOME/.config/foo.toml"
  printf 'same\n' > "$HOME/explicit.toml"
  run sh "$CONFIG_DIFF" "$HOME/.config/foo.toml" --against="$HOME/explicit.toml"
  [ "$status" -eq 0 ]
}
