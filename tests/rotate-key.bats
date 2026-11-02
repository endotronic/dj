#!/usr/bin/env bats
#
# Tests for scripts/rotate-key.sh.
# Happy-path tests require sops + age-keygen; they skip otherwise.

load test_helper

SCRIPT=$DOTFILES_REPO_ROOT/scripts/rotate-key.sh

setup() {
  sandbox_setup
  stub_dir_setup
}

teardown() {
  sandbox_teardown
}

requires_sops_and_age() {
  command -v sops      >/dev/null 2>&1 || skip "sops not installed"
  command -v age-keygen >/dev/null 2>&1 || skip "age not installed"
}

# Set up a sandboxed fake repo with a real age key + .sops.yaml.
# Stubs git; exports FAKE_REPO, DOT_DIR, OLD_PUB, SOPS_AGE_KEY_FILE.
sops_sandbox() {
  requires_sops_and_age
  FAKE_REPO="$SANDBOX/fake-repo"
  mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/secrets"
  cp "$SCRIPT" "$FAKE_REPO/scripts/rotate-key.sh"

  age-keygen -o "$XDG_CONFIG_HOME/sops/age/keys.txt" 2>/dev/null
  chmod 600 "$XDG_CONFIG_HOME/sops/age/keys.txt"
  OLD_PUB=$(awk '/^# public key:/ { print $NF; exit }' \
    "$XDG_CONFIG_HOME/sops/age/keys.txt")

  cat > "$FAKE_REPO/.sops.yaml" <<EOF
creation_rules:
  - path_regex: secrets/.*\\.enc\$
    age: $OLD_PUB
EOF

  export SOPS_AGE_KEY_FILE="$XDG_CONFIG_HOME/sops/age/keys.txt"
  # PRIVATE_DIR tells the script where .sops.yaml and secrets/ live.
  export PRIVATE_DIR="$FAKE_REPO"

  DOT_DIR="$SANDBOX/fake.git"
  mkdir -p "$DOT_DIR"
  stub_cmd git

  export FAKE_REPO DOT_DIR OLD_PUB
}

# Encrypt content into a fake secrets file. Returns the enc path.
make_enc_file() {
  local rel="$1" content="$2"
  local enc_path="$FAKE_REPO/secrets/${rel}.enc"
  mkdir -p "$(dirname "$enc_path")"
  ( cd "$FAKE_REPO" && printf '%s\n' "$content" | \
      sops --encrypt --input-type binary --output-type binary \
      --filename-override "secrets/${rel}.enc" /dev/stdin > "$enc_path" )
}

# --- error paths (no sops/age needed) ----------------------------------------

@test "age-keygen missing exits with error" {
  for util in awk cat chmod cp dirname find mkdir rm sed sort; do
    src=$(command -v "$util" 2>/dev/null)
    [ -n "$src" ] && [ -f "$src" ] && cp "$src" "$STUB_BIN/$util" \
      && chmod +x "$STUB_BIN/$util" || true
  done
  abs_sh=$(command -v sh)
  stub_cmd sops
  printf '# public key: age1dummy\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  PATH="$STUB_BIN"
  run "$abs_sh" "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "age-keygen not found" ]]
}

@test "sops missing exits with error" {
  for util in awk cat chmod cp dirname find mkdir rm sed sort; do
    src=$(command -v "$util" 2>/dev/null)
    [ -n "$src" ] && [ -f "$src" ] && cp "$src" "$STUB_BIN/$util" \
      && chmod +x "$STUB_BIN/$util" || true
  done
  abs_sh=$(command -v sh)
  stub_cmd age-keygen
  printf '# public key: age1dummy\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  PATH="$STUB_BIN"
  run "$abs_sh" "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sops not found" ]]
}

@test "missing age key exits with error" {
  stub_cmd age-keygen
  stub_cmd sops
  rm -f "$XDG_CONFIG_HOME/sops/age/keys.txt"
  run sh "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "age key not found" ]]
}

@test "missing .sops.yaml exits with error" {
  stub_cmd age-keygen
  stub_cmd sops
  printf '# public key: age1dummy\nAGE-SECRET-KEY-...\n' \
    > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  # PRIVATE_DIR defaults to $HOME/.private which doesn't exist in sandbox,
  # so $PRIVATE_DIR/.sops.yaml won't be found.
  run sh "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ ".sops.yaml not found" ]]
}

# --- happy path (requires sops + age) ----------------------------------------

@test "new key differs from old key" {
  sops_sandbox
  run sh "$FAKE_REPO/scripts/rotate-key.sh"
  [ "$status" -eq 0 ]
  new_pub=$(awk '/^# public key:/ { print $NF; exit }' \
    "$XDG_CONFIG_HOME/sops/age/keys.txt")
  [ -n "$new_pub" ]
  [ "$new_pub" != "$OLD_PUB" ]
}

@test ".sops.yaml references only the new key after rotation" {
  sops_sandbox
  sh "$FAKE_REPO/scripts/rotate-key.sh" >/dev/null 2>&1
  new_pub=$(awk '/^# public key:/ { print $NF; exit }' \
    "$XDG_CONFIG_HOME/sops/age/keys.txt")
  grep -qF "age: $new_pub" "$FAKE_REPO/.sops.yaml"
  ! grep -qF "$OLD_PUB" "$FAKE_REPO/.sops.yaml"
}

@test "no .sops.yaml.bak left after rotation" {
  sops_sandbox
  sh "$FAKE_REPO/scripts/rotate-key.sh" >/dev/null 2>&1
  [ ! -f "$FAKE_REPO/.sops.yaml.bak" ]
}

@test "encrypted files can be decrypted with new key after rotation" {
  sops_sandbox
  make_enc_file "env/test" "secret-value"
  sh "$FAKE_REPO/scripts/rotate-key.sh" >/dev/null 2>&1
  # SOPS_AGE_KEY_FILE still points to keys.txt, which now has the new key.
  result=$(sops --decrypt --input-type binary --output-type binary \
    "$FAKE_REPO/secrets/env/test.enc")
  [ "$result" = "secret-value" ]
}

@test "git add called for .sops.yaml and all enc files" {
  sops_sandbox
  make_enc_file "env/api" "api=abc"
  make_enc_file "ssh/id_ed25519" "fake-key"
  sh "$FAKE_REPO/scripts/rotate-key.sh" >/dev/null 2>&1
  grep -q "^git.*add.*\.sops\.yaml" "$SANDBOX/stub.log"
  grep -q "^git.*add.*env/api\.enc"        "$SANDBOX/stub.log"
  grep -q "^git.*add.*ssh/id_ed25519\.enc" "$SANDBOX/stub.log"
}

@test "git commit called with rotation message containing new public key" {
  sops_sandbox
  sh "$FAKE_REPO/scripts/rotate-key.sh" >/dev/null 2>&1
  new_pub=$(awk '/^# public key:/ { print $NF; exit }' \
    "$XDG_CONFIG_HOME/sops/age/keys.txt")
  grep -q "^git.*commit.*rotate age key" "$SANDBOX/stub.log"
  grep -qF "$new_pub" "$SANDBOX/stub.log"
}

@test "reminder is printed to stdout" {
  sops_sandbox
  run sh "$FAKE_REPO/scripts/rotate-key.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "REMINDER" ]]
  [[ "$output" =~ "distribute" ]]
  [[ "$output" =~ "dj sync" ]]
}

@test "rotation with no secrets still updates .sops.yaml and commits" {
  sops_sandbox
  # No .enc files — secrets dir is empty.
  run sh "$FAKE_REPO/scripts/rotate-key.sh"
  [ "$status" -eq 0 ]
  new_pub=$(awk '/^# public key:/ { print $NF; exit }' \
    "$XDG_CONFIG_HOME/sops/age/keys.txt")
  grep -qF "age: $new_pub" "$FAKE_REPO/.sops.yaml"
  grep -q "^git.*commit" "$SANDBOX/stub.log"
}
