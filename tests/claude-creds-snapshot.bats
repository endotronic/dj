#!/usr/bin/env bats
#
# Tests for scripts/claude-creds-snapshot.sh. Happy-path tests (which
# round-trip through sops + age) skip when those binaries are missing;
# error-path tests run unconditionally.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export SNAPSHOT_SCRIPT="$DOTFILES_REPO_ROOT/scripts/claude-creds-snapshot.sh"
}

teardown() {
  sandbox_teardown
}

requires_sops_and_age() {
  command -v sops >/dev/null 2>&1 || skip "sops not installed"
  command -v age-keygen >/dev/null 2>&1 || skip "age not installed"
}

# Stand up a fake private dir at $FAKE_REPO with the script wired up,
# an age key, and a .sops.yaml that targets secrets/.*\.enc$.
# Sets PRIVATE_DIR=$FAKE_REPO so the script uses it for secrets.
snapshot_sandbox() {
  requires_sops_and_age
  FAKE_REPO="$SANDBOX/fake-repo"
  mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/secrets"
  cp "$DOTFILES_REPO_ROOT/scripts/claude-creds-snapshot.sh" \
     "$FAKE_REPO/scripts/"

  age-keygen -o "$XDG_CONFIG_HOME/sops/age/keys.txt" 2>/dev/null
  chmod 600 "$XDG_CONFIG_HOME/sops/age/keys.txt"
  PUB=$(awk '/^# public key:/ { print $NF; exit }' \
    "$XDG_CONFIG_HOME/sops/age/keys.txt")
  cat > "$FAKE_REPO/.sops.yaml" <<EOF
creation_rules:
  - path_regex: secrets/.*\.enc\$
    age: $PUB
EOF
  export SOPS_AGE_KEY_FILE="$XDG_CONFIG_HOME/sops/age/keys.txt"
  export PRIVATE_DIR="$FAKE_REPO"
  export FAKE_REPO PUB
}

# --- error paths (no sops/age required) ------------------------------------

@test "aborts on Darwin with Keychain pointer" {
  # Stub uname to claim Darwin. PATH ordering puts $STUB_BIN first.
  cat > "$STUB_BIN/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
  chmod +x "$STUB_BIN/uname"

  run sh "$SNAPSHOT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "macOS detected" ]]
  [[ "$output" =~ "Keychain" ]]
}

@test "missing source credentials file errors with claude-login pointer" {
  export CLAUDE_CREDS_SRC="$SANDBOX/no-such-file.json"
  run sh "$SNAPSHOT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no credentials file at" ]]
  [[ "$output" =~ "claude login" ]]
}

@test "missing sops binary errors clearly" {
  # Source file exists, but no sops on PATH (clean stub PATH only).
  export PATH="$STUB_BIN:/usr/bin:/bin"
  src="$SANDBOX/creds.json"
  printf '{"token":"x"}\n' > "$src"
  export CLAUDE_CREDS_SRC="$src"

  if command -v sops >/dev/null 2>&1; then
    skip "sops is on the base PATH and can't be hidden from this test"
  fi

  run sh "$SNAPSHOT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sops not on PATH" ]]
}

@test "missing .sops.yaml in PRIVATE_DIR errors with sops-init pointer" {
  requires_sops_and_age
  src="$SANDBOX/creds.json"
  printf '{"token":"x"}\n' > "$src"
  export CLAUDE_CREDS_SRC="$src"
  # PRIVATE_DIR has no .sops.yaml
  export PRIVATE_DIR="$SANDBOX/empty-private"
  mkdir -p "$PRIVATE_DIR"

  run sh "$SNAPSHOT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ ".sops.yaml not found" ]]
  [[ "$output" =~ "sops-init" ]]
}

# --- happy path (requires sops + age) --------------------------------------

@test "encrypts source file to secrets/claude/credentials.json.enc" {
  snapshot_sandbox
  src="$SANDBOX/creds.json"
  printf '{"sessionKey":"abc123","exp":1700000000}\n' > "$src"
  export CLAUDE_CREDS_SRC="$src"

  run sh "$FAKE_REPO/scripts/claude-creds-snapshot.sh"
  [ "$status" -eq 0 ]
  enc="$FAKE_REPO/secrets/claude/credentials.json.enc"
  [ -f "$enc" ]

  # Encrypted file is not equal to plaintext.
  ! cmp -s "$src" "$enc"

  # And decrypts back to the original payload.
  decrypted=$(sops -d "$enc")
  [[ "$decrypted" =~ "sessionKey" ]]
  [[ "$decrypted" =~ "abc123" ]]
}

@test "snapshot is idempotent and overwrites previous encryption" {
  snapshot_sandbox
  src="$SANDBOX/creds.json"
  printf '{"sessionKey":"first"}\n' > "$src"
  export CLAUDE_CREDS_SRC="$src"

  run sh "$FAKE_REPO/scripts/claude-creds-snapshot.sh"
  [ "$status" -eq 0 ]
  enc="$FAKE_REPO/secrets/claude/credentials.json.enc"
  first_sum=$(sha256sum "$enc" | awk '{print $1}')

  # Update the source, re-snapshot.
  printf '{"sessionKey":"second"}\n' > "$src"
  run sh "$FAKE_REPO/scripts/claude-creds-snapshot.sh"
  [ "$status" -eq 0 ]
  second_sum=$(sha256sum "$enc" | awk '{print $1}')

  # File still exists, decrypts to the new contents.
  [ -f "$enc" ]
  decrypted=$(sops -d "$enc")
  [[ "$decrypted" =~ "second" ]]
  # Encrypted bytes generally differ (new nonce, new MAC); not asserting
  # inequality of digests since sops behavior could theoretically be
  # deterministic, but the decrypted-content check above is the real one.
  [ -n "$first_sum" ] && [ -n "$second_sum" ]
}

@test "creates manifest.txt.enc with correct entry when none exists" {
  snapshot_sandbox
  src="$SANDBOX/creds.json"
  printf '{"sessionKey":"abc"}\n' > "$src"
  export CLAUDE_CREDS_SRC="$src"
  export DOT_DIR="$SANDBOX/no-such-git"  # skip staging

  run sh "$FAKE_REPO/scripts/claude-creds-snapshot.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "manifest created" ]]

  manifest="$FAKE_REPO/secrets/manifest.txt.enc"
  [ -f "$manifest" ]
  content=$(sops -d "$manifest")
  [[ "$content" =~ "secrets/claude/credentials.json.enc" ]]
  [[ "$content" =~ "~/.claude/.credentials.json" ]]
  [[ "$content" =~ "0600" ]]
}

@test "appends to existing manifest without duplicating entry" {
  snapshot_sandbox
  src="$SANDBOX/creds.json"
  printf '{"sessionKey":"abc"}\n' > "$src"
  export CLAUDE_CREDS_SRC="$src"
  export DOT_DIR="$SANDBOX/no-such-git"  # skip staging

  # Pre-populate manifest with an unrelated entry.
  existing="secrets/other.enc  ~/.other  0644"
  printf '%s\n' "$existing" > "$SANDBOX/manifest-plain.txt"
  ( cd "$FAKE_REPO" && sops --encrypt --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc \
      "$SANDBOX/manifest-plain.txt" > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/claude-creds-snapshot.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "manifest updated" ]]

  content=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  [[ "$content" =~ "secrets/other.enc" ]]
  [[ "$content" =~ "secrets/claude/credentials.json.enc" ]]
}

@test "does not duplicate manifest entry on re-run" {
  snapshot_sandbox
  src="$SANDBOX/creds.json"
  printf '{"sessionKey":"abc"}\n' > "$src"
  export CLAUDE_CREDS_SRC="$src"
  export DOT_DIR="$SANDBOX/no-such-git"  # skip staging

  run sh "$FAKE_REPO/scripts/claude-creds-snapshot.sh"
  [ "$status" -eq 0 ]

  run sh "$FAKE_REPO/scripts/claude-creds-snapshot.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "manifest entry already present" ]]

  content=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  count=$(printf '%s\n' "$content" | grep -c "credentials.json.enc" || true)
  [ "$count" -eq 1 ]
}
