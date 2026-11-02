#!/usr/bin/env bats
#
# Syntax smoke tests for every shell file in the repo. Catches typos and
# missing closes that other tests would only flag at runtime.
#
# POSIX files are checked with `sh -n`; anything under a bash/ or zsh/
# template directory with the matching interpreter (zsh skipped when it
# isn't installed).

load test_helper

posix_files() {
  find "$DOTFILES_REPO_ROOT" -path "$DOTFILES_REPO_ROOT/.git" -prune -o \
       -type f \( -name '*.sh' -o -path '*/bin/*' \) -print \
    | grep -v -e '/templates/bash/' -e '/templates/zsh/' -e '/tests/'
}

@test "every POSIX file passes sh -n" {
  errors=""
  for f in $(posix_files); do
    sh -n "$f" 2>/dev/null || errors="$errors $f"
  done
  if [ -n "$errors" ]; then
    printf 'syntax errors in:%s\n' "$errors" >&2
    false
  fi
}

@test "every bash template passes bash -n" {
  errors=""
  for f in $(find "$DOTFILES_REPO_ROOT" -path '*/templates/bash/*' -type f 2>/dev/null); do
    bash -n "$f" 2>/dev/null || errors="$errors $f"
  done
  [ -z "$errors" ] || { printf 'bash syntax errors in:%s\n' "$errors" >&2; false; }
}

@test "every zsh template passes zsh -n" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  errors=""
  for f in $(find "$DOTFILES_REPO_ROOT" -path '*/templates/zsh/*' -type f 2>/dev/null); do
    zsh -n "$f" 2>/dev/null || errors="$errors $f"
  done
  [ -z "$errors" ] || { printf 'zsh syntax errors in:%s\n' "$errors" >&2; false; }
}

@test "every script is executable" {
  missing=""
  for f in $(posix_files); do
    case "$f" in */lib/*|*/templates/*) continue ;; esac
    [ -x "$f" ] || missing="$missing $f"
  done
  [ -z "$missing" ] || { printf 'not executable:%s\n' "$missing" >&2; false; }
}
