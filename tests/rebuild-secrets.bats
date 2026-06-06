#!/usr/bin/env bats
#
# Tests for scripts/rebuild-secrets.sh. Round-trip tests (encrypt with
# sops, decrypt with the script, check target content) require sops +
# age to be installed; they `skip` otherwise. Error-path tests run
# unconditionally.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export REBUILD="$DOTFILES_REPO_ROOT/scripts/rebuild-secrets.sh"
}

teardown() {
  sandbox_teardown
}

requires_sops_and_age() {
  command -v sops >/dev/null 2>&1 || skip "sops not installed"
  command -v age-keygen >/dev/null 2>&1 || skip "age not installed"
}

# Set up a fully working SOPS environment under SANDBOX:
#   - generates an age key at $XDG_CONFIG_HOME/sops/age/keys.txt
#   - writes a fake "repo root" with a .sops.yaml pointing at that key
#   - sets $FAKE_REPO so tests can drop encrypted files under
#     $FAKE_REPO/secrets/
sops_sandbox() {
  requires_sops_and_age
  FAKE_REPO="$SANDBOX/fake-repo"
  mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/secrets"
  cp "$DOTFILES_REPO_ROOT/scripts/rebuild-secrets.sh"  "$FAKE_REPO/scripts/"

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
  # PRIVATE_DIR points at FAKE_REPO so the script finds secrets/ there.
  export PRIVATE_DIR="$FAKE_REPO"
  export FAKE_REPO PUB
}

# Encrypt $2 (a string) into $FAKE_REPO/$1 using sops.
sops_encrypt_to() {
  local rel="$1" content="$2"
  mkdir -p "$(dirname "$FAKE_REPO/$rel")"
  ( cd "$FAKE_REPO" && printf '%s' "$content" | sops -e --input-type binary \
      --output-type binary --filename-override "$rel" /dev/stdin > "$rel" )
}

# --- error paths (no sops/age needed) --------------------------------------

@test "no manifest is a graceful no-op, exit 0" {
  # PRIVATE_DIR defaults to $HOME/.private which doesn't exist in the sandbox,
  # so the script should exit cleanly without touching the real secrets.
  run sh "$REBUILD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no manifest" ]]
}

@test "manifest present but age key missing returns error" {
  requires_sops_and_age
  sops_sandbox
  sops_encrypt_to secrets/manifest.txt.enc "# empty manifest"
  rm -f "$XDG_CONFIG_HOME/sops/age/keys.txt"
  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "age key not found" ]]
}

# --- happy path (requires sops + age) -------------------------------------

@test "decrypts a single env entry to target path with mode 0600" {
  sops_sandbox
  sops_encrypt_to secrets/env/api.env.enc "OPENAI_API_KEY=sk-test123"

  # Manifest entry: one line referencing the env file.
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/env/api.env.enc  ~/.secrets/api.env  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.secrets/api.env" ]
  grep -q "OPENAI_API_KEY=sk-test123" "$HOME/.secrets/api.env"
  mode=$(stat -c '%a' "$HOME/.secrets/api.env" 2>/dev/null \
       || stat -f '%Lp' "$HOME/.secrets/api.env")
  [ "$mode" = "600" ]
}

@test "expands HOME-variable in dst paths" {
  sops_sandbox
  sops_encrypt_to secrets/foo.enc "hello"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/foo.enc  \$HOME/some/where/foo  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/some/where/foo" ]
}

@test "rejects manifest entry with relative dst (not absolute or ~/)" {
  sops_sandbox
  sops_encrypt_to secrets/foo.enc "hello"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/foo.enc  relative/path  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn" ]]
}

@test "missing src file is warned and skipped, run still succeeds" {
  sops_sandbox
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/does-not-exist.enc  ~/elsewhere/foo  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "src not found" ]]
}

@test "manifest comments and blank lines are ignored" {
  sops_sandbox
  sops_encrypt_to secrets/foo.enc "content-foo"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
# this is a comment

secrets/foo.enc  ~/out/foo  0600

# trailing comment
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q content-foo "$HOME/out/foo"
}
