# Shared helpers for the dotfiles test suite. Each .bats file loads
# this with `load test_helper`.
#
# Test environment philosophy: every test runs in a sandbox that
# completely isolates HOME, XDG_CONFIG_HOME, and PATH from the real
# system. Stubs replace `sudo` and pkg-manager binaries so scripts
# can run their install paths without touching the host.

# DOTFILES_REPO_ROOT: the operational root (.dotfiles/ dir) — where
# scripts/, packages/, tests/, etc. live after the move.
DOTFILES_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOTFILES_REPO_ROOT

# _DOTFILES_SHELL_ROOT: the actual git repo root — where .bashrc,
# .config/, etc. live (one level above DOTFILES_REPO_ROOT).
_DOTFILES_SHELL_ROOT="$(cd "$DOTFILES_REPO_ROOT/.." && pwd)"
export _DOTFILES_SHELL_ROOT

# --- sandbox ----------------------------------------------------------------

# Create a fresh sandbox: temp $SANDBOX dir, override HOME and
# XDG_CONFIG_HOME inside it. Saves originals so teardown can restore.
sandbox_setup() {
  SANDBOX="$(mktemp -d)"
  export SANDBOX

  _ORIG_HOME="$HOME"
  _ORIG_XDG="${XDG_CONFIG_HOME:-}"
  _ORIG_PATH="$PATH"

  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/dotfiles" "$XDG_CONFIG_HOME/sops/age"
}

sandbox_teardown() {
  export HOME="$_ORIG_HOME"
  if [ -n "${_ORIG_XDG:-}" ]; then
    export XDG_CONFIG_HOME="$_ORIG_XDG"
  else
    unset XDG_CONFIG_HOME
  fi
  export PATH="$_ORIG_PATH"
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# --- PATH stubs -------------------------------------------------------------

# Initialize $STUB_BIN and prepend it to PATH. Subsequent stub_cmd
# calls write executables there.
stub_dir_setup() {
  STUB_BIN="$SANDBOX/stub-bin"
  mkdir -p "$STUB_BIN"
  export STUB_BIN
  export PATH="$STUB_BIN:$PATH"
}

# Create a stub that logs its invocation to $SANDBOX/stub.log and
# exits 0. Use stub_log / stub_called to assert on what ran.
stub_cmd() {
  local name="$1"
  cat > "$STUB_BIN/$name" <<EOF
#!/bin/sh
{ printf '%s' "$name"; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } \
  >> "$SANDBOX/stub.log"
exit 0
EOF
  chmod +x "$STUB_BIN/$name"
}

# Stub `sudo` as a passthrough that just runs its arguments. Useful
# when the script's behavior under sudo is what we want to observe,
# without actually elevating.
stub_sudo_passthrough() {
  cat > "$STUB_BIN/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
  chmod +x "$STUB_BIN/sudo"
}

# Remove a binary from the stub PATH (e.g. to simulate "not installed").
unstub_cmd() {
  rm -f "$STUB_BIN/$1"
}

# Dump the stub call log (empty string if nothing called).
stub_log() {
  cat "$SANDBOX/stub.log" 2>/dev/null || true
}

# Return 0 if any logged invocation started with the given command name.
stub_called() {
  local name="$1"
  [ -f "$SANDBOX/stub.log" ] && grep -q "^$name\b" "$SANDBOX/stub.log"
}

# --- fake bare repo for install.sh -----------------------------------------

# Initialize a working src repo at $SRC_REPO with a default git
# identity. Use add_to_repo / publish_repo to populate.
make_src_repo() {
  SRC_REPO="$SANDBOX/src-repo"
  BARE_REPO="$SANDBOX/dotfiles.git"
  git init -q "$SRC_REPO"
  ( cd "$SRC_REPO" && git config user.email test@example.com \
                   && git config user.name testuser \
                   && git config commit.gpgsign false )
  export SRC_REPO BARE_REPO
}

# Write file content into the src repo (creates parent dirs).
# Usage: add_to_repo path "content"
add_to_repo() {
  local path="$1" content="$2"
  mkdir -p "$SRC_REPO/$(dirname "$path")"
  printf '%s\n' "$content" > "$SRC_REPO/$path"
}

# Commit any pending changes and (re-)publish to the bare clone.
publish_repo() {
  ( cd "$SRC_REPO" && git add -A && git commit -q -m "test commit" )
  rm -rf "$BARE_REPO"
  git clone -q --bare "$SRC_REPO" "$BARE_REPO"
}

# Wrap `dot` for use in assertions: operates on the sandboxed bare repo.
dot() {
  git --git-dir="$HOME/.config.git" --work-tree="$HOME" "$@"
}

# --- shell-layer staging --------------------------------------------------

# Copy the full shell config tree (and scripts/os-detect.sh, which
# init.sh sources) into the sandbox $HOME. After this you can do:
#   bash -c 'source ~/.bashrc; ...'
# and have a self-contained interactive-shell init under test.
install_shell_layer() {
  cp "$_DOTFILES_SHELL_ROOT/.bashrc"       "$HOME/.bashrc"
  cp "$_DOTFILES_SHELL_ROOT/.bash_profile" "$HOME/.bash_profile"
  cp "$_DOTFILES_SHELL_ROOT/.zshrc"        "$HOME/.zshrc"
  cp "$_DOTFILES_SHELL_ROOT/.zprofile"     "$HOME/.zprofile"
  mkdir -p "$HOME/.config" "$HOME/.dotfiles/scripts"
  cp -r "$_DOTFILES_SHELL_ROOT/.config/shell" "$HOME/.config/"
  cp -r "$_DOTFILES_SHELL_ROOT/.config/bash"  "$HOME/.config/"
  cp -r "$_DOTFILES_SHELL_ROOT/.config/zsh"   "$HOME/.config/"
  cp "$DOTFILES_REPO_ROOT/scripts/os-detect.sh" "$HOME/.dotfiles/scripts/"
}
