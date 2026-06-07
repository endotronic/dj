#!/usr/bin/env bats
#
# Tests for scripts/os-detect.sh: DOTFILES_OS / DOTFILES_PKG /
# DOTFILES_SYSTEM_TYPE detection.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export OS_DETECT="$DOTFILES_REPO_ROOT/scripts/os-detect.sh"
}

teardown() {
  sandbox_teardown
}

# --- OS detection ----------------------------------------------------------

@test "DOTFILES_OS is set to a known value" {
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_OS"'
  [ "$status" -eq 0 ]
  case "$output" in
    darwin|linux|wsl|unknown) ;;
    *) printf 'unexpected OS: %s\n' "$output" >&2; false ;;
  esac
}

# --- package-manager detection (uses stubs so we don't depend on host) ----

@test "DOTFILES_PKG=pacman when pacman is on PATH (linux)" {
  # On this Arch host the real pacman is present; explicit stub
  # ensures the test is hermetic.
  stub_cmd pacman
  unstub_cmd apt
  unstub_cmd brew
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_PKG"'
  [ "$status" -eq 0 ]
  # Only assert when we detected linux; macOS/WSL would differ.
  case "$(sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_OS"')" in
    linux|wsl) [ "$output" = "pacman" ] || [ "$output" = "apt" ] ;;
    *) skip "not linux/wsl" ;;
  esac
}

@test "DOTFILES_PKG=apt when apt is on PATH before pacman (linux)" {
  stub_cmd apt
  stub_cmd pacman
  case "$(sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_OS"')" in
    linux|wsl) ;;
    *) skip "not linux/wsl" ;;
  esac
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_PKG"'
  [ "$output" = "apt" ]
}

# --- persisted system-type ------------------------------------------------

@test "DOTFILES_SYSTEM_TYPE empty when file is absent" {
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_SYSTEM_TYPE"'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "DOTFILES_SYSTEM_TYPE=desktop when persisted" {
  printf 'desktop\n' > "$XDG_CONFIG_HOME/dotfiles/system-type"
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_SYSTEM_TYPE"'
  [ "$output" = "desktop" ]
}

@test "DOTFILES_SYSTEM_TYPE accepts arbitrary identifiers, not just desktop|server" {
  printf 'laptop\n' > "$XDG_CONFIG_HOME/dotfiles/system-type"
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_SYSTEM_TYPE"'
  [ "$output" = "laptop" ]
}

@test "DOTFILES_SYSTEM_TYPE=server when persisted" {
  printf 'server\n' > "$XDG_CONFIG_HOME/dotfiles/system-type"
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_SYSTEM_TYPE"'
  [ "$output" = "server" ]
}

@test "DOTFILES_SYSTEM_TYPE rejected when persisted file contains invalid characters" {
  printf 'not a valid type!\n' > "$XDG_CONFIG_HOME/dotfiles/system-type"
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_SYSTEM_TYPE"'
  [ "$output" = "" ]
}

@test "DOTFILES_SYSTEM_TYPE strips surrounding whitespace" {
  printf '  desktop \n' > "$XDG_CONFIG_HOME/dotfiles/system-type"
  run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_SYSTEM_TYPE"'
  [ "$output" = "desktop" ]
}

# --- distro detection -----------------------------------------------------

@test "DOTFILES_DISTRO set from ID in fake os-release" {
  printf 'ID=ubuntu\nVERSION_ID="22.04"\n' > "$SANDBOX/os-release"
  DOTFILES_OS_RELEASE_FILE="$SANDBOX/os-release" \
    run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_DISTRO"'
  [ "$status" -eq 0 ]
  [ "$output" = "ubuntu" ]
}

@test "DOTFILES_DISTRO is debian when os-release says debian" {
  printf 'ID=debian\nVERSION_ID="12"\n' > "$SANDBOX/os-release"
  DOTFILES_OS_RELEASE_FILE="$SANDBOX/os-release" \
    run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_DISTRO"'
  [ "$output" = "debian" ]
}

@test "DOTFILES_DISTRO empty when os-release absent" {
  DOTFILES_OS_RELEASE_FILE="$SANDBOX/nonexistent" \
    run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_DISTRO"'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "DOTFILES_DISTRO empty when os-release has no ID" {
  printf 'NAME="Some OS"\n' > "$SANDBOX/os-release"
  DOTFILES_OS_RELEASE_FILE="$SANDBOX/os-release" \
    run sh -c '. "$OS_DETECT" && printf %s "$DOTFILES_DISTRO"'
  [ "$output" = "" ]
}

# --- idempotency -----------------------------------------------------------

@test "sourcing twice does not change the result" {
  printf 'desktop\n' > "$XDG_CONFIG_HOME/dotfiles/system-type"
  run sh -c '. "$OS_DETECT"; . "$OS_DETECT"; printf "%s/%s" "$DOTFILES_OS" "$DOTFILES_SYSTEM_TYPE"'
  [ "$status" -eq 0 ]
  case "$output" in
    */desktop) ;;
    *) printf 'got: %s\n' "$output" >&2; false ;;
  esac
}
