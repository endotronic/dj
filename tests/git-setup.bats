#!/usr/bin/env bats
#
# Tests for scripts/git-setup.sh.

load test_helper

SCRIPT="$DOTFILES_REPO_ROOT/scripts/git-setup.sh"

setup() {
  sandbox_setup
  stub_dir_setup

  git init --bare "$HOME/.config.git" -q
  git --git-dir="$HOME/.config.git" --work-tree="$HOME" \
    config status.showUntrackedFiles no
  git --git-dir="$HOME/.config.git" config user.email test@example.com
  git --git-dir="$HOME/.config.git" config user.name  testuser
  git --git-dir="$HOME/.config.git" config commit.gpgsign false
  export DOT_DIR="$HOME/.config.git"

  # Stub out ssh-keygen and gpg so tests don't touch real crypto.
  stub_ssh_keygen_creates_key
  stub_gpg_no_existing_keys
}

teardown() {
  sandbox_teardown
}

# --- Stub helpers ------------------------------------------------------------

# ssh-keygen stub: detects -f <path> and creates fake key files there.
stub_ssh_keygen_creates_key() {
  cat > "$STUB_BIN/ssh-keygen" << 'EOF'
#!/bin/sh
# Parse -f <keypath> from arguments.
prev=
keypath=
for a in "$@"; do
  if [ "$prev" = "-f" ]; then keypath="$a"; fi
  prev="$a"
done
{ printf 'ssh-keygen'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
if [ -n "$keypath" ]; then
  printf 'fake-ed25519-private-key\n' > "$keypath"
  printf 'ssh-ed25519 AAAA fake-key test@example.com\n' > "${keypath}.pub"
fi
exit 0
EOF
  chmod +x "$STUB_BIN/ssh-keygen"
}

# GPG stub: no existing secret keys; quick-gen-key succeeds;
# --list-secret-keys with an email returns a fake key entry.
stub_gpg_no_existing_keys() {
  cat > "$STUB_BIN/gpg" << 'EOF'
#!/bin/sh
{ printf 'gpg'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"

# --list-secret-keys: if an email arg is present (key-ID lookup after gen),
# emit a fake sec line; otherwise emit nothing (no pre-existing keys).
case "$*" in
  *--list-secret-keys*--keyid-format*LONG*@*)
    printf 'sec   rsa4096/TESTKEY123456 2024-01-01 [S]\n'
    ;;
  *--list-secret-keys*)
    : # no output => no existing keys
    ;;
  *--quick-gen-key*)
    : # generation succeeds silently
    ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/gpg"
}

# GPG stub: reports an existing secret key on any --list-secret-keys call.
stub_gpg_existing_key() {
  cat > "$STUB_BIN/gpg" << 'EOF'
#!/bin/sh
{ printf 'gpg'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
case "$*" in
  *--list-secret-keys*)
    printf 'sec   rsa4096/EXISTINGKEY0000 2024-01-01 [S]\n'
    ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/gpg"
}

gitcfg() { git -C "$HOME" config --global "$@" 2>/dev/null || true; }

staged_files() {
  git --git-dir="$HOME/.config.git" --work-tree="$HOME" \
    diff --cached --name-only
}

# --- Argument parsing --------------------------------------------------------

@test "--no exits 0 immediately" {
  run sh "$SCRIPT" --no
  [ "$status" -eq 0 ]
}

@test "unknown argument exits 2" {
  run sh "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "unknown argument" ]]
}

# --- Git identity ------------------------------------------------------------

@test "existing git identity is adopted without changes" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already configured" ]]
  [ "$(gitcfg user.name)"  = "Jane Dev" ]
  [ "$(gitcfg user.email)" = "jane@example.com" ]
}

@test "missing identity with --yes: skips prompt, push.autoSetupRemote still set" {
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ "$(gitcfg push.autoSetupRemote)" = "true" ]
}

@test "push.autoSetupRemote set when identity already exists" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"
  sh "$SCRIPT" --yes >/dev/null
  [ "$(gitcfg push.autoSetupRemote)" = "true" ]
}

# --- SSH key -----------------------------------------------------------------

@test "SSH key generated when absent" {
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ -f "$HOME/.ssh/id_ed25519" ]
  [ -f "$HOME/.ssh/id_ed25519.pub" ]
}

@test "ssh-keygen called with ed25519 and empty passphrase" {
  sh "$SCRIPT" --yes >/dev/null
  stub_called ssh-keygen
  grep -q '\-t ed25519' "$SANDBOX/stub.log"
  grep -q '\-N ' "$SANDBOX/stub.log"
}

@test "SSH key not regenerated when already present" {
  mkdir -p "$HOME/.ssh"
  printf 'existing-key\n' > "$HOME/.ssh/id_ed25519"
  printf 'ssh-ed25519 EXISTING test\n' > "$HOME/.ssh/id_ed25519.pub"

  sh "$SCRIPT" --yes >/dev/null

  # Stub log should not contain ssh-keygen.
  ! stub_called ssh-keygen
  grep -q 'existing-key' "$HOME/.ssh/id_ed25519"
}

@test "ssh-keygen missing: SSH key step skipped gracefully" {
  # Remove our stub; if a real ssh-keygen still exists on PATH we can't
  # hide it without complex PATH surgery, so skip the test on such hosts.
  rm -f "$STUB_BIN/ssh-keygen"
  if command -v ssh-keygen >/dev/null 2>&1; then
    skip "real ssh-keygen found in PATH; cannot simulate absence"
  fi

  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.ssh/id_ed25519" ]
  [[ "$output" =~ "ssh-keygen not found" ]]
}

# --- GPG key -----------------------------------------------------------------

@test "gpg missing: GPG step skipped gracefully" {
  rm -f "$STUB_BIN/gpg"
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [[ "$output" =~ "gpg not found" ]]
}

@test "existing GPG key: new key not generated" {
  stub_gpg_existing_key
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"

  sh "$SCRIPT" --yes >/dev/null

  ! grep -q -- '--quick-gen-key' "$SANDBOX/stub.log" 2>/dev/null || {
    echo "quick-gen-key was unexpectedly called"; return 1
  }
}

@test "new GPG key generated when no secret keys exist and identity is set" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"

  sh "$SCRIPT" --yes >/dev/null

  grep -q -- '--quick-gen-key' "$SANDBOX/stub.log"
}

@test "git configured to sign commits after new GPG key" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"

  sh "$SCRIPT" --yes >/dev/null

  [ "$(gitcfg commit.gpgsign)" = "true" ]
  signing_key=$(gitcfg user.signingkey)
  [ -n "$signing_key" ]
}

@test "git signing NOT configured when GPG key pre-existed" {
  stub_gpg_existing_key
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"

  sh "$SCRIPT" --yes >/dev/null

  # commit.gpgsign should not be set by this script.
  [ "$(gitcfg commit.gpgsign)" != "true" ]
}

@test "GPG key not generated when identity is missing" {
  # No git name/email configured, non-interactive (--yes skips prompt).
  sh "$SCRIPT" --yes >/dev/null

  ! grep -q -- '--quick-gen-key' "$SANDBOX/stub.log" 2>/dev/null || {
    echo "quick-gen-key unexpectedly called without identity"; return 1
  }
}

# --- Staging -----------------------------------------------------------------

@test ".gitconfig staged in bare repo after identity set" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"

  sh "$SCRIPT" --yes >/dev/null

  staged=$(staged_files)
  printf '%s\n' "$staged" | grep -q '\.gitconfig'
}

@test "SSH public key staged in bare repo after generation" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"

  sh "$SCRIPT" --yes >/dev/null

  staged=$(staged_files)
  printf '%s\n' "$staged" | grep -q '\.ssh/id_ed25519\.pub'
}

@test "no DOT_DIR: staging skipped but script succeeds" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"
  run env DOT_DIR="$SANDBOX/nonexistent.git" sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
}

# --- Idempotence -------------------------------------------------------------

@test "running twice is idempotent" {
  git config --global user.name  "Jane Dev"
  git config --global user.email "jane@example.com"

  sh "$SCRIPT" --yes >/dev/null

  # Second run should not regenerate SSH key.
  rm -f "$SANDBOX/stub.log"
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  ! stub_called ssh-keygen
}
