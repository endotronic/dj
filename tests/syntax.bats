#!/usr/bin/env bats
#
# Syntax smoke tests for every shell file in the repo. Catches typos
# and missing closes that other tests would only flag at runtime
# (which is too late for files like .bashrc that only get sourced
# inside interactive shells).
#
# Three groups, each checked with the right interpreter:
#   POSIX (sh -n):     scripts/*.sh, .config/shell/**/*.sh, install.sh
#   bash (bash -n):    .bashrc, .bash_profile, .config/bash/*.sh
#   zsh  (zsh -n):     .zshrc, .zprofile, .config/zsh/*.zsh,
#                      .config/zsh/init.sh
#                      (skipped if zsh not on PATH)

load test_helper

@test "every POSIX file passes sh -n" {
  errors=""
  for f in "$DOTFILES_REPO_ROOT/install.sh" \
           "$DOTFILES_REPO_ROOT"/scripts/*.sh \
           "$DOTFILES_REPO_ROOT"/packages/scripts/*.sh \
           "$_DOTFILES_SHELL_ROOT"/.config/shell/*.sh \
           "$_DOTFILES_SHELL_ROOT"/.config/shell/os/*.sh; do
    [ -e "$f" ] || continue
    if ! sh -n "$f" 2>/dev/null; then
      errors="$errors $f"
    fi
  done
  if [ -n "$errors" ]; then
    printf 'syntax errors in:%s\n' "$errors" >&2
    false
  fi
}

@test "every bash file passes bash -n" {
  errors=""
  for f in "$_DOTFILES_SHELL_ROOT/.bashrc" \
           "$_DOTFILES_SHELL_ROOT/.bash_profile" \
           "$_DOTFILES_SHELL_ROOT"/.config/bash/*.sh; do
    [ -e "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      errors="$errors $f"
    fi
  done
  if [ -n "$errors" ]; then
    printf 'bash syntax errors in:%s\n' "$errors" >&2
    false
  fi
}

@test "every zsh file passes zsh -n" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  errors=""
  for f in "$_DOTFILES_SHELL_ROOT/.zshrc" \
           "$_DOTFILES_SHELL_ROOT/.zprofile" \
           "$_DOTFILES_SHELL_ROOT"/.config/zsh/*.zsh \
           "$_DOTFILES_SHELL_ROOT/.config/zsh/init.sh"; do
    [ -e "$f" ] || continue
    if ! zsh -n "$f" 2>/dev/null; then
      errors="$errors $f"
    fi
  done
  if [ -n "$errors" ]; then
    printf 'zsh syntax errors in:%s\n' "$errors" >&2
    false
  fi
}

@test "all scripts/*.sh are executable" {
  missing=""
  for f in "$DOTFILES_REPO_ROOT"/scripts/*.sh \
           "$DOTFILES_REPO_ROOT"/packages/scripts/*.sh; do
    [ -e "$f" ] || continue
    [ -x "$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    printf 'not executable:%s\n' "$missing" >&2
    false
  fi
}

@test "install.sh is executable" {
  [ -x "$DOTFILES_REPO_ROOT/install.sh" ]
}
