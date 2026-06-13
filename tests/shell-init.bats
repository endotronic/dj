#!/usr/bin/env bats
#
# Tests for the shell init layer:
#   ~/.bashrc, ~/.bash_profile, ~/.zshrc, ~/.zprofile (loaders)
#   ~/.config/shell/* (POSIX shared)
#   ~/.config/bash/*  (bash-only)
#   ~/.config/zsh/*   (zsh-only)
#
# Each test stages the shell tree into a sandboxed $HOME with
# install_shell_layer, then runs an interactive-style shell
# invocation and asserts on the resulting env / aliases / functions.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  install_shell_layer
}

teardown() {
  sandbox_teardown
}

# Convenience: source ~/.bashrc in an interactive-ish bash and run
# the given command. Forces interactive mode (-i) so .bashrc's
# `case $- in *i*) ;; *) return ;; esac` guard doesn't bail.
in_bash() {
  # Combine the command's stderr with its stdout (so tests can
  # assert on usage messages and the like), but discard bash's own
  # interactive-mode warnings (e.g. "cannot set terminal process
  # group") so they don't drown the assertions.
  bash -ic "$1 2>&1" 2>/dev/null
}

# --- DOTFILES_OS / env exports --------------------------------------------

@test "sourcing .bashrc sets DOTFILES_OS" {
  run in_bash 'printf %s "$DOTFILES_OS"'
  [ "$status" -eq 0 ]
  case "$output" in
    darwin|linux|wsl) ;;
    *) printf 'unexpected OS: %s\n' "$output" >&2; false ;;
  esac
}

@test "sourcing .bashrc sets EDITOR=nvim" {
  run in_bash 'printf %s "$EDITOR"'
  [ "$output" = "nvim" ]
}

@test "sourcing .bashrc sets VISUAL=nvim" {
  run in_bash 'printf %s "$VISUAL"'
  [ "$output" = "nvim" ]
}

@test "sourcing .bashrc exports XDG dirs even when unset" {
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
  run in_bash 'printf "%s|%s|%s|%s" \
    "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"'
  [ "$output" = "$HOME/.config|$HOME/.local/share|$HOME/.cache|$HOME/.local/state" ]
}

# --- PATH manipulation -----------------------------------------------------

@test "sourcing prepends \$HOME/.dotfiles/scripts and \$HOME/.local/bin to PATH" {
  run in_bash 'case ":$PATH:" in
    *":$HOME/.dotfiles/scripts:"*"$HOME/.local/bin:"*) echo ok ;;
    *":$HOME/.local/bin:"*"$HOME/.dotfiles/scripts:"*) echo ok ;;
    *) echo "PATH=$PATH" ;;
  esac'
  [ "$output" = "ok" ]
}

@test "PATH prepend is idempotent across re-sourcing" {
  run in_bash 'source ~/.bashrc; source ~/.bashrc; \
    n_scripts=$(echo "$PATH" | tr : "\n" | grep -cx "$HOME/.dotfiles/scripts" || true); \
    n_local=$(echo "$PATH" | tr : "\n" | grep -cx "$HOME/.local/bin" || true); \
    printf "%s|%s" "$n_scripts" "$n_local"'
  [ "$output" = "1|1" ]
}

# --- dot alias and helpers --------------------------------------------------

@test "dot is an alias to git --git-dir/--work-tree" {
  run in_bash 'alias dot'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "git --git-dir" ]]
  [[ "$output" =~ "\$HOME/.config.git" ]]
}

@test "dot_add is a defined function" {
  run in_bash 'declare -F dot_add'
  [ "$status" -eq 0 ]
  [[ "$output" =~ dot_add ]]
}

@test "dot-add alias points to dot_add" {
  run in_bash 'alias dot-add'
  [ "$status" -eq 0 ]
  [[ "$output" =~ dot_add ]]
}

@test "dot_add with no args prints usage and exits non-zero" {
  run in_bash 'dot_add'
  [ "$status" -ne 0 ]
  [[ "$output" =~ usage ]]
}

# --- mkcd function --------------------------------------------------------

@test "mkcd creates and cd's into a new directory" {
  run in_bash 'mkcd "$HOME/test-mkcd-dir" && pwd'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/test-mkcd-dir" ]
  [ -d "$HOME/test-mkcd-dir" ]
}

@test "mkcd with no args fails with usage" {
  run in_bash 'mkcd'
  [ "$status" -ne 0 ]
}

# --- OS-conditional file sourcing ----------------------------------------

@test "per-OS file is sourced when DOTFILES_OS matches a file in os/" {
  # Add a marker to the linux file (the OS this host returns).
  os=$(sh "$HOME/.dotfiles/scripts/os-detect.sh" >/dev/null; \
       . "$HOME/.dotfiles/scripts/os-detect.sh"; printf %s "$DOTFILES_OS")
  [ -n "$os" ]
  cat >> "$HOME/.config/shell/os/$os.sh" <<'EOF'
export DOTFILES_SHELL_OS_FILE_LOADED=yes
EOF
  run in_bash 'printf %s "$DOTFILES_SHELL_OS_FILE_LOADED"'
  [ "$output" = "yes" ]
}

@test "per-host file is sourced when one matches hostname" {
  hn=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo unknown)
  mkdir -p "$HOME/.config/shell/host"
  printf 'export DOTFILES_HOST_FILE_LOADED=yes\n' \
    > "$HOME/.config/shell/host/$hn.sh"
  run in_bash 'printf %s "$DOTFILES_HOST_FILE_LOADED"'
  [ "$output" = "yes" ]
}

# --- secrets.sh -----------------------------------------------------------

@test "secrets.sh is a no-op when no decrypted secret env exists" {
  run in_bash 'printf %s "${DOTFILES_TEST_SECRET:-unset}"'
  [ "$output" = "unset" ]
}

@test "secrets.sh loads ~/.secrets/api-keys.env into the env" {
  mkdir -p "$HOME/.secrets"
  printf 'DOTFILES_TEST_SECRET=loaded\n' > "$HOME/.secrets/api-keys.env"
  run in_bash 'printf %s "$DOTFILES_TEST_SECRET"'
  [ "$output" = "loaded" ]
}

# --- bash-only sub-files --------------------------------------------------

@test "bash init sets history options (HISTSIZE)" {
  run in_bash 'printf %s "$HISTSIZE"'
  [ "$output" = "100000" ]
}

@test "bash init enables histappend" {
  run in_bash 'shopt -p histappend | grep -q "shopt -s histappend" && echo ok'
  [ "$output" = "ok" ]
}

# --- zsh layer (skipped if zsh missing) -----------------------------------

@test "zsh: sourcing .zshrc sets DOTFILES_OS" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -ic 'printf %s "$DOTFILES_OS"'
  [ "$status" -eq 0 ]
  case "$output" in
    darwin|linux|wsl) ;;
    *) printf 'unexpected OS: %s\n' "$output" >&2; false ;;
  esac
}

@test "zsh: dot is an alias" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -ic 'alias dot'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "git --git-dir" ]]
}

@test "zsh: history settings (HISTSIZE) are set" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -ic 'printf %s "$HISTSIZE"'
  [ "$output" = "100000" ]
}
