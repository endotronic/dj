#!/usr/bin/env bats
#
# Tests for packages/scripts/code-oss.sh (the VSCodium fallback installer for
# apt and brew systems).
#
# PATH is swapped for a farm of symlinks to just the tools these scripts call,
# plus per-test stubs, so a host that really has codium, apt-get or brew can't
# leak into the results.

load test_helper

SCRIPT="$DOTFILES_REPO_ROOT/packages/scripts/code-oss.sh"

setup() {
  sandbox_setup
  stub_dir_setup

  local farm="$SANDBOX/farm" c src
  mkdir -p "$farm"
  for c in sh awk cat chmod cmp cp dirname env grep mkdir mktemp mv rm sed tee; do
    src="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$src" ] && ln -sf "$src" "$farm/$c"
  done
  export PATH="$STUB_BIN:$farm"

  export DOTFILES_KEYRING_DIR="$SANDBOX/keyrings"
  export DOTFILES_APT_SOURCES_DIR="$SANDBOX/sources.list.d"
  mkdir -p "$DOTFILES_KEYRING_DIR" "$DOTFILES_APT_SOURCES_DIR"
  export DOTFILES_VSCODE_ARGV="$HOME/.vscode-oss/argv.json"
}

teardown() {
  sandbox_teardown
}

stub_uname() {
  printf '#!/bin/sh\n[ "$1" = -s ] && echo %s || echo %s\n' "$1" "$1" > "$STUB_BIN/uname"
  chmod +x "$STUB_BIN/uname"
}

# curl that "downloads" a key (`-o FILE`), or an empty file when asked to.
stub_curl() {
  cat > "$STUB_BIN/curl" <<STUB
#!/bin/sh
{ printf 'curl'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
while [ \$# -gt 0 ]; do
  if [ "\$1" = -o ]; then
    if [ "\${CURL_EMPTY:-0}" = 1 ]; then : > "\$2"; else printf 'PGPKEY\n' > "\$2"; fi
  fi
  shift
done
exit 0
STUB
  chmod +x "$STUB_BIN/curl"
}

stub_gpg() {
  printf '#!/bin/sh\ncat\n' > "$STUB_BIN/gpg"
  chmod +x "$STUB_BIN/gpg"
}

# --- code-oss.sh ------------------------------------------------------------

apt_env() {
  stub_uname Linux
  stub_sudo_passthrough
  stub_cmd apt-get
  stub_curl
  stub_gpg
}

@test "code-oss.sh: passes sh -n" {
  run sh -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "code-oss.sh: exits 0 without doing anything when codium is already installed" {
  apt_env
  stub_cmd codium
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  ! stub_called apt-get
  ! stub_called curl
}

@test "code-oss.sh: apt -- adds VSCodium's signed repo, then installs codium" {
  apt_env
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$DOTFILES_KEYRING_DIR/vscodium-archive-keyring.gpg" ]
  src="$DOTFILES_APT_SOURCES_DIR/vscodium.sources"
  [ -f "$src" ]
  grep -qx 'URIs: https://download.vscodium.com/debs' "$src"
  grep -qx 'Suites: vscodium' "$src"
  grep -qx "Signed-By: $DOTFILES_KEYRING_DIR/vscodium-archive-keyring.gpg" "$src"
  grep -q "apt-get update" "$SANDBOX/stub.log"
  grep -q "apt-get install -y codium" "$SANDBOX/stub.log"
}

@test "code-oss.sh: apt -- a second run does not download the key again or rewrite the source" {
  apt_env
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  cp "$DOTFILES_APT_SOURCES_DIR/vscodium.sources" "$SANDBOX/first"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl' "$SANDBOX/stub.log")" -eq 1 ]
  cmp "$DOTFILES_APT_SOURCES_DIR/vscodium.sources" "$SANDBOX/first"
}

@test "code-oss.sh: apt -- an empty key download fails cleanly and installs nothing" {
  apt_env
  CURL_EMPTY=1 run sh "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not download the VSCodium repo key"* ]]
  [ ! -e "$DOTFILES_APT_SOURCES_DIR/vscodium.sources" ]
  ! grep -q "apt-get install" "$SANDBOX/stub.log"
}

@test "code-oss.sh: macOS -- installs the vscodium cask" {
  stub_uname Darwin
  stub_cmd brew
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "brew install --cask vscodium" "$SANDBOX/stub.log"
}

@test "code-oss.sh: macOS without Homebrew fails with a message" {
  stub_uname Darwin
  run sh "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Homebrew not found"* ]]
}

@test "code-oss.sh: Linux without apt (e.g. Arch) has no install path and says so" {
  stub_uname Linux
  run sh "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Arch uses the"* ]]
}

