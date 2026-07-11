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

# --- pre-existing target backup --------------------------------------------

@test "pre-existing target with different content is backed up, not silently overwritten" {
  sops_sandbox
  sops_encrypt_to secrets/id_ed25519.enc "incoming-private-key"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/id_ed25519.enc  ~/.ssh/id_ed25519  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  mkdir -p "$HOME/.ssh"
  printf 'pre-existing-local-key' > "$HOME/.ssh/id_ed25519"

  export BACKUP_DIR="$SANDBOX/backup"
  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already existed with different content" ]]
  [[ "$output" =~ "backed_up=1" ]]
  grep -q incoming-private-key "$HOME/.ssh/id_ed25519"
  grep -q pre-existing-local-key "$BACKUP_DIR/$HOME/.ssh/id_ed25519"
}

@test "pre-existing target with identical content is not flagged as backed up" {
  sops_sandbox
  sops_encrypt_to secrets/foo.enc "same-content"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/foo.enc  ~/out/foo  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  mkdir -p "$HOME/out"
  printf 'same-content' > "$HOME/out/foo"

  export BACKUP_DIR="$SANDBOX/backup"
  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "backed_up=0" ]]
  [ ! -d "$BACKUP_DIR" ]
}

# --- GPG key/ownertrust import ---------------------------------------------

# GPG stub: logs every invocation; --import and --import-ownertrust succeed.
stub_gpg_import_ok() {
  cat > "$STUB_BIN/gpg" << 'EOF'
#!/bin/sh
{ printf 'gpg'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
exit 0
EOF
  chmod +x "$STUB_BIN/gpg"
}

@test "imports GPG key and ownertrust when manifest restores them" {
  sops_sandbox
  stub_gpg_import_ok
  sops_encrypt_to secrets/.private/gpg/private-key.asc.enc "fake-armored-key"
  sops_encrypt_to secrets/.private/gpg/ownertrust.txt.enc "fake-ownertrust"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/.private/gpg/private-key.asc.enc  ~/.private/gpg/private-key.asc  0600
secrets/.private/gpg/ownertrust.txt.enc   ~/.private/gpg/ownertrust.txt   0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.private/gpg/private-key.asc" ]
  [ -f "$HOME/.private/gpg/ownertrust.txt" ]
  [[ "$output" =~ "imported GPG key" ]]
  [[ "$output" =~ "imported GPG ownertrust" ]]
  grep -q -- '--import .*private-key.asc' "$SANDBOX/stub.log"
  grep -q -- '--import-ownertrust' "$SANDBOX/stub.log"
}

@test "no GPG files materialized: import step is a no-op" {
  sops_sandbox
  stub_gpg_import_ok
  sops_encrypt_to secrets/foo.enc "content-foo"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/foo.enc  ~/out/foo  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  ! grep -q -- '--import' "$SANDBOX/stub.log" 2>/dev/null || {
    echo "gpg --import unexpectedly called"; return 1
  }
}

@test "GPG key materialized but gpg missing: warns and continues" {
  sops_sandbox
  sops_encrypt_to secrets/.private/gpg/private-key.asc.enc "fake-armored-key"
  manifest="$SANDBOX/manifest-plain"
  cat > "$manifest" <<EOF
secrets/.private/gpg/private-key.asc.enc  ~/.private/gpg/private-key.asc  0600
EOF
  ( cd "$FAKE_REPO" && sops -e --input-type binary --output-type binary \
      --filename-override secrets/manifest.txt.enc "$manifest" \
      > secrets/manifest.txt.enc )

  rm -f "$STUB_BIN/gpg"
  if command -v gpg >/dev/null 2>&1; then
    skip "real gpg found in PATH; cannot simulate absence"
  fi

  run sh "$FAKE_REPO/scripts/rebuild-secrets.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "gpg not found" ]]
}
