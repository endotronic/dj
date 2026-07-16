#!/usr/bin/env bats
#
# Tests for scripts/install-antigravity.sh. Uses stub curl + stub bash to
# avoid hitting the network. Each test is fully sandboxed.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export INSTALL_ANTIGRAVITY="$DOTFILES_REPO_ROOT/scripts/install-antigravity.sh"
}

teardown() {
  sandbox_teardown
}

# Build a PATH that contains the basic utilities needed to run the
# script but does NOT contain `agy`. Symlink each utility into
# $STUB_BIN, then point PATH at $STUB_BIN alone. Pass the names of
# utilities to include as args; curl is excluded by default so tests
# can decide whether to provide it.
clean_path() {
  for u in "$@"; do
    p=$(command -v "$u" 2>/dev/null) || continue
    ln -sf "$p" "$STUB_BIN/$u" 2>/dev/null || true
  done
  export PATH="$STUB_BIN"
}

# Default set of utilities needed by install-antigravity.sh + the test
# stubs' heredocs (bash for the pipe, cat for heredoc emission,
# touch+chmod for the install script creating an agy stub) plus the
# utilities bats itself uses for post-run assertions (grep).
clean_path_default() {
  clean_path bash sh dash cat touch chmod printf grep
}

@test "no-op when agy is already on PATH" {
  clean_path_default
  stub_cmd agy

  run sh "$INSTALL_ANTIGRAVITY"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already on PATH" ]]

  # curl must not have been called.
  if [ -f "$SANDBOX/stub.log" ]; then
    ! grep -q '^curl' "$SANDBOX/stub.log"
  fi
}

@test "errors clearly when curl is missing" {
  # Cleaned PATH with no curl symlink. command -v is a shell builtin,
  # so the script can still run; it just finds nothing.
  clean_path_default

  run sh "$INSTALL_ANTIGRAVITY"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "curl is required" ]]
}

@test "happy path: pipes vendor script to bash, agy becomes available" {
  clean_path_default
  # Stub curl: log the URL, then emit an install script (to stdout)
  # that creates an executable at $STUB_BIN/agy. The script's
  # `curl ... | bash` runs that script, so agy appears on PATH.
  cat > "$STUB_BIN/curl" <<EOF
#!/bin/sh
{ printf 'curl'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
cat <<'INSTALLER'
#!/bin/sh
touch "$STUB_BIN/agy"
chmod +x "$STUB_BIN/agy"
INSTALLER
EOF
  chmod +x "$STUB_BIN/curl"

  run sh "$INSTALL_ANTIGRAVITY"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "installing via" ]]
  [[ "$output" =~ "installed:" ]]
  grep -q 'antigravity.google/cli/install.sh' "$SANDBOX/stub.log"
  [ -x "$STUB_BIN/agy" ]
}

@test "honors ANTIGRAVITY_INSTALL_URL override" {
  clean_path_default
  cat > "$STUB_BIN/curl" <<EOF
#!/bin/sh
{ printf 'curl'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
cat <<'INSTALLER'
#!/bin/sh
touch "$STUB_BIN/agy"
chmod +x "$STUB_BIN/agy"
INSTALLER
EOF
  chmod +x "$STUB_BIN/curl"

  export ANTIGRAVITY_INSTALL_URL=https://example.test/install.sh
  run sh "$INSTALL_ANTIGRAVITY"
  [ "$status" -eq 0 ]
  grep -q 'example.test/install.sh' "$SANDBOX/stub.log"
  # And did NOT use the default vendor URL.
  ! grep -q 'antigravity.google/cli/install.sh' "$SANDBOX/stub.log"
}

@test "warns but exits 0 if vendor script completes but agy is still missing" {
  clean_path_default
  # Stub curl outputs a no-op install script. No agy binary appears,
  # but this is a PATH warning, not a hard failure.
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
echo "true"
EOF
  chmod +x "$STUB_BIN/curl"

  run sh "$INSTALL_ANTIGRAVITY"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn:" ]]
}
