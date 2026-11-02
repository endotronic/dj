#!/usr/bin/env bats
#
# Tests for scripts/secret-add.sh. Round-trip tests (real sops encrypt/decrypt)
# require sops + age to be installed; they `skip` otherwise. Error-path tests
# run unconditionally.

load test_helper

SCRIPT=$DOTFILES_REPO_ROOT/scripts/secret-add.sh

setup() {
  sandbox_setup
  stub_dir_setup
}

teardown() {
  sandbox_teardown
}

requires_sops_and_age() {
  command -v sops >/dev/null 2>&1 || skip "sops not installed"
  command -v age-keygen >/dev/null 2>&1 || skip "age not installed"
}

# Set up a fake repo root under $SANDBOX with a real age key + .sops.yaml.
# Populates $FAKE_REPO, $DOT_DIR (stubbed bare git dir), and exports
# SOPS_AGE_KEY_FILE so sops finds the sandboxed key.
sops_sandbox() {
  requires_sops_and_age
  FAKE_REPO="$SANDBOX/fake-repo"
  mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/secrets"
  cp "$DOTFILES_REPO_ROOT/scripts/secret-add.sh" "$FAKE_REPO/scripts/"

  age-keygen -o "$XDG_CONFIG_HOME/sops/age/keys.txt" 2>/dev/null
  chmod 600 "$XDG_CONFIG_HOME/sops/age/keys.txt"
  PUB=$(awk '/^# public key:/ { print $NF; exit }' \
    "$XDG_CONFIG_HOME/sops/age/keys.txt")
  cat > "$FAKE_REPO/.sops.yaml" <<EOF
creation_rules:
  - path_regex: secrets/.*\\.enc\$
    age: $PUB
EOF
  export SOPS_AGE_KEY_FILE="$XDG_CONFIG_HOME/sops/age/keys.txt"
  # PRIVATE_DIR tells the script where to find/write secrets and .sops.yaml.
  export PRIVATE_DIR="$FAKE_REPO"

  DOT_DIR="$SANDBOX/fake.git"
  mkdir -p "$DOT_DIR"
  stub_cmd git
  export FAKE_REPO DOT_DIR PUB
}

# Decrypt a sops-encrypted binary file and return its content on stdout.
sops_decrypt_binary() {
  sops --decrypt --input-type binary --output-type binary "$1"
}

# --- error paths (no sops/age needed) --------------------------------------

@test "no args prints usage and exits 1" {
  run sh "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "usage" ]]
}

@test "unreadable src exits 1 with message" {
  stub_cmd sops
  run sh "$SCRIPT" "$HOME/does-not-exist.txt"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "not readable" ]]
}

@test "sops not on PATH exits 1 with message" {
  src="$HOME/secret.txt"
  printf 'content\n' > "$src"
  # Use absolute path for sh; restrict PATH so sops (a system binary) is invisible
  PATH="$STUB_BIN" run /bin/sh "$SCRIPT" "$src"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "sops not found" ]]
}

@test "age key missing exits 1 with message" {
  stub_cmd sops
  src="$HOME/secret.txt"
  printf 'content\n' > "$src"
  rm -f "$XDG_CONFIG_HOME/sops/age/keys.txt"
  run sh "$SCRIPT" "$src"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "age key not found" ]]
}

@test ".sops.yaml missing exits 1 with message" {
  stub_cmd sops
  printf 'dummy\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  src="$HOME/secret.txt"
  printf 'content\n' > "$src"
  # PRIVATE_DIR defaults to $HOME/.private which doesn't exist in the sandbox,
  # so no .sops.yaml will be found.
  run sh "$SCRIPT" "$src"
  [ "$status" -eq 1 ]
  [[ "$output" =~ ".sops.yaml not found" ]]
}

@test "non-home dst exits 1 with message" {
  stub_cmd sops
  printf 'dummy\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  src="$HOME/secret.txt"
  printf 'content\n' > "$src"
  run sh "$SCRIPT" "$src" "/tmp/should-fail"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "under \$HOME" ]]
}

# --- happy path (requires sops + age) ----------------------------------------

@test "encrypts src to derived enc path under secrets/" {
  sops_sandbox
  src="$HOME/.ssh/id_ed25519"
  mkdir -p "$HOME/.ssh"
  printf 'fake-ssh-key\n' > "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src"
  [ "$status" -eq 0 ]

  enc="$FAKE_REPO/secrets/.ssh/id_ed25519.enc"
  [ -f "$enc" ]
  result=$(sops_decrypt_binary "$enc")
  [ "$result" = "fake-ssh-key" ]
}

@test "creates manifest when none exists" {
  sops_sandbox
  src="$HOME/.ssh/id_ed25519"
  mkdir -p "$HOME/.ssh"
  printf 'fake-key\n' > "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src"
  [ "$status" -eq 0 ]

  [ -f "$FAKE_REPO/secrets/manifest.txt.enc" ]
  manifest=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  [[ "$manifest" =~ "secrets/.ssh/id_ed25519.enc" ]]
  [[ "$manifest" =~ "~/.ssh/id_ed25519" ]]
}

@test "appends entry to existing manifest" {
  sops_sandbox

  # Create an existing manifest with one entry
  existing=$(printf 'secrets/env/api.enc  ~/.secrets/api  0600\n')
  ( cd "$FAKE_REPO" && printf '%s' "$existing" | \
      sops --encrypt --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc /dev/stdin \
      > secrets/manifest.txt.enc )

  src="$HOME/.ssh/id_ed25519"
  mkdir -p "$HOME/.ssh"
  printf 'fake-key\n' > "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src"
  [ "$status" -eq 0 ]

  manifest=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  [[ "$manifest" =~ "secrets/env/api.enc" ]]
  [[ "$manifest" =~ "secrets/.ssh/id_ed25519.enc" ]]
}

@test "duplicate entry: warns and does not add a second line" {
  sops_sandbox
  src="$HOME/.ssh/id_ed25519"
  mkdir -p "$HOME/.ssh"
  printf 'fake-key\n' > "$src"

  # Add once
  sh "$FAKE_REPO/scripts/secret-add.sh" "$src" >/dev/null 2>&1

  # Re-encrypt the source (simulating a key rotation)
  printf 'rotated-key\n' > "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn" ]]

  # Manifest should still have exactly one entry for this path
  manifest=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  count=$(printf '%s\n' "$manifest" | grep -c 'secrets/.ssh/id_ed25519.enc' || true)
  [ "$count" -eq 1 ]
}

@test "explicit dst overrides path derivation" {
  sops_sandbox
  src="$HOME/plaintext-key"
  printf 'key-content\n' > "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src" "~/.ssh/id_ed25519"
  [ "$status" -eq 0 ]

  [ -f "$FAKE_REPO/secrets/.ssh/id_ed25519.enc" ]
  manifest=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  [[ "$manifest" =~ "~/.ssh/id_ed25519" ]]
}

@test "explicit mode stored in manifest" {
  sops_sandbox
  src="$HOME/secret.txt"
  printf 'content\n' > "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src" "" "0400"
  [ "$status" -eq 0 ]

  manifest=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  [[ "$manifest" =~ "0400" ]]
}

@test "mode defaults to source file permissions" {
  sops_sandbox
  src="$HOME/secret.txt"
  printf 'content\n' > "$src"
  chmod 0640 "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src"
  [ "$status" -eq 0 ]

  manifest=$(sops -d "$FAKE_REPO/secrets/manifest.txt.enc")
  [[ "$manifest" =~ "640" ]]
}

@test "stages enc file and manifest via git" {
  sops_sandbox
  src="$HOME/.ssh/id_ed25519"
  mkdir -p "$HOME/.ssh"
  printf 'fake-key\n' > "$src"

  run sh "$FAKE_REPO/scripts/secret-add.sh" "$src"
  [ "$status" -eq 0 ]

  # git stub should have been called with 'add' and both paths
  grep -q "^git.*add.*id_ed25519.enc" "$SANDBOX/stub.log"
  grep -q "^git.*add.*manifest.txt.enc" "$SANDBOX/stub.log"
}
