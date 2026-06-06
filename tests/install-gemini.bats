#!/usr/bin/env bats
#
# Tests for scripts/install-gemini.sh. Uses stub npm to avoid hitting
# the network. Each test is fully sandboxed.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export INSTALL_GEMINI="$DOTFILES_REPO_ROOT/scripts/install-gemini.sh"
}

teardown() {
  sandbox_teardown
}

# Build a PATH containing only the named utilities (no gemini by default).
clean_path() {
  for u in "$@"; do
    p=$(command -v "$u" 2>/dev/null) || continue
    ln -sf "$p" "$STUB_BIN/$u" 2>/dev/null || true
  done
  export PATH="$STUB_BIN"
}

clean_path_default() {
  clean_path sh dash cat touch chmod printf grep
}

@test "no-op when gemini is already on PATH" {
  clean_path_default
  stub_cmd gemini

  run sh "$INSTALL_GEMINI"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already on PATH" ]]

  # npm must not have been called
  if [ -f "$SANDBOX/stub.log" ]; then
    ! grep -q '^npm' "$SANDBOX/stub.log"
  fi
}

@test "exits non-zero with warning when npm is missing" {
  clean_path_default

  run sh "$INSTALL_GEMINI"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "npm not found" ]]
}

@test "happy path: installs via npm, gemini becomes available" {
  clean_path_default
  stub_sudo_passthrough
  # Stub npm: log the call and create a gemini executable.
  cat > "$STUB_BIN/npm" <<EOF
#!/bin/sh
{ printf 'npm'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
touch "$STUB_BIN/gemini"
chmod +x "$STUB_BIN/gemini"
EOF
  chmod +x "$STUB_BIN/npm"

  run sh "$INSTALL_GEMINI"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "installing via npm" ]]
  [[ "$output" =~ "installed:" ]]
  grep -q '@google/gemini-cli' "$SANDBOX/stub.log"
  [ -x "$STUB_BIN/gemini" ]
}

@test "warns but exits 0 if npm runs but gemini still not on PATH" {
  clean_path_default
  stub_sudo_passthrough
  # Stub npm: log the call but don't create a gemini binary.
  cat > "$STUB_BIN/npm" <<EOF
#!/bin/sh
{ printf 'npm'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
EOF
  chmod +x "$STUB_BIN/npm"

  run sh "$INSTALL_GEMINI"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn:" ]]
}

@test "npm is called with install -g @google/gemini-cli" {
  clean_path_default
  stub_sudo_passthrough
  cat > "$STUB_BIN/npm" <<EOF
#!/bin/sh
{ printf 'npm'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
touch "$STUB_BIN/gemini"
chmod +x "$STUB_BIN/gemini"
EOF
  chmod +x "$STUB_BIN/npm"

  run sh "$INSTALL_GEMINI"
  grep -q 'npm install -g @google/gemini-cli' "$SANDBOX/stub.log"
}
