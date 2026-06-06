#!/usr/bin/env bats
#
# Tests for scripts/install-claude.sh. Uses stub curl + stub sh to
# avoid hitting the network. Each test is fully sandboxed.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export INSTALL_CLAUDE="$DOTFILES_REPO_ROOT/scripts/install-claude.sh"
}

teardown() {
  sandbox_teardown
}

# Build a PATH that contains the basic utilities needed to run the
# script but does NOT contain `claude` (which is /usr/bin/claude on
# this host and would otherwise short-circuit every test). Symlink
# each utility into $STUB_BIN, then point PATH at $STUB_BIN alone.
# Pass the names of utilities to include as args; curl is excluded by
# default so tests can decide whether to provide it.
clean_path() {
  for u in "$@"; do
    p=$(command -v "$u" 2>/dev/null) || continue
    ln -sf "$p" "$STUB_BIN/$u" 2>/dev/null || true
  done
  export PATH="$STUB_BIN"
}

# Default set of utilities needed by install-claude.sh + the test
# stubs' heredocs (sh for the pipe, cat for heredoc emission,
# touch+chmod for the install script creating a claude stub) plus the
# utilities bats itself uses for post-run assertions (grep).
clean_path_default() {
  clean_path bash sh dash cat touch chmod printf grep
}

@test "no-op when claude is already on PATH" {
  clean_path_default
  stub_cmd claude

  run sh "$INSTALL_CLAUDE"
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

  run sh "$INSTALL_CLAUDE"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "curl is required" ]]
}

@test "happy path: pipes vendor script to sh, claude becomes available" {
  clean_path_default
  # Stub curl: log the URL, then emit an install script (to stdout)
  # that creates an executable at $STUB_BIN/claude. The script's
  # `curl ... | sh` runs that script, so claude appears on PATH.
  cat > "$STUB_BIN/curl" <<EOF
#!/bin/sh
{ printf 'curl'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
cat <<'INSTALLER'
#!/bin/sh
touch "$STUB_BIN/claude"
chmod +x "$STUB_BIN/claude"
INSTALLER
EOF
  chmod +x "$STUB_BIN/curl"

  run sh "$INSTALL_CLAUDE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "installing via" ]]
  [[ "$output" =~ "installed:" ]]
  grep -q 'claude.ai/install.sh' "$SANDBOX/stub.log"
  [ -x "$STUB_BIN/claude" ]
}

@test "honors CLAUDE_INSTALL_URL override" {
  clean_path_default
  cat > "$STUB_BIN/curl" <<EOF
#!/bin/sh
{ printf 'curl'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
cat <<'INSTALLER'
#!/bin/sh
touch "$STUB_BIN/claude"
chmod +x "$STUB_BIN/claude"
INSTALLER
EOF
  chmod +x "$STUB_BIN/curl"

  export CLAUDE_INSTALL_URL=https://example.test/install.sh
  run sh "$INSTALL_CLAUDE"
  [ "$status" -eq 0 ]
  grep -q 'example.test/install.sh' "$SANDBOX/stub.log"
  # And did NOT use the default vendor URL.
  ! grep -q 'claude.ai/install.sh' "$SANDBOX/stub.log"
}

@test "warns but exits 0 if vendor script completes but claude is still missing" {
  clean_path_default
  # Stub curl outputs a no-op install script. No claude binary appears,
  # but this is a PATH warning, not a hard failure.
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
echo "true"
EOF
  chmod +x "$STUB_BIN/curl"

  run sh "$INSTALL_CLAUDE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn:" ]]
}
