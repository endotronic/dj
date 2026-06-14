#!/usr/bin/env bats
#
# Tests for scripts/shell-consolidate.sh.

load test_helper

SCRIPT="$DOTFILES_REPO_ROOT/scripts/shell-consolidate.sh"

setup() {
  sandbox_setup
  stub_dir_setup

  # Provide a stub zsh so command -v zsh succeeds on machines without it.
  # The script never runs zsh directly; it only checks for its presence.
  printf '#!/bin/sh\nexec /usr/bin/env bash "$@"\n' > "$STUB_BIN/zsh"
  chmod +x "$STUB_BIN/zsh"

  git init --bare "$HOME/.config.git" -q
  git --git-dir="$HOME/.config.git" --work-tree="$HOME" \
    config status.showUntrackedFiles no
  git --git-dir="$HOME/.config.git" config user.email test@example.com
  git --git-dir="$HOME/.config.git" config user.name  testuser
  git --git-dir="$HOME/.config.git" config commit.gpgsign false
  export DOT_DIR="$HOME/.config.git"
}

teardown() {
  sandbox_teardown
}

write_plain_bashrc() { printf '# plain bashrc\nexport FOO=bar\n' > "$HOME/.bashrc"; }
write_plain_zshrc()  { printf '# plain zshrc\nexport BAR=baz\n' > "$HOME/.zshrc";  }

write_loader_bashrc() {
  printf '[ -r "$HOME/.config/shell/init.sh" ] && . "$HOME/.config/shell/init.sh"\n' \
    > "$HOME/.bashrc"
}
write_loader_zshrc() {
  printf '[ -r "$HOME/.config/shell/init.sh" ] && . "$HOME/.config/shell/init.sh"\n' \
    > "$HOME/.zshrc"
}

staged_files() {
  git --git-dir="$HOME/.config.git" --work-tree="$HOME" \
    diff --cached --name-only
}

# --- no-op cases -------------------------------------------------------------

@test "both shells already thin loaders: exits 0, no files created" {
  write_loader_bashrc
  write_loader_zshrc
  # (test 4 covers this too; this exercises the early-exit path explicitly)
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.config/shell" ]
}

@test ".bashrc already a thin loader (zshrc also done): skipped" {
  write_loader_bashrc
  write_loader_zshrc
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.config/shell" ]
}

@test "both shells already thin loaders (via individual writes): skipped" {
  write_loader_bashrc
  write_loader_zshrc
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.config/shell" ]
}

@test "both RCs are thin loaders: skipped" {
  write_loader_bashrc
  write_loader_zshrc
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.config/shell" ]
}

@test "--no skips even with plain .bashrc" {
  write_plain_bashrc
  run sh "$SCRIPT" --no
  [ "$status" -eq 0 ]
  grep -q 'plain bashrc' "$HOME/.bashrc"
  [ ! -d "$HOME/.config/shell" ]
}

@test "no DOT_DIR: skips with log message" {
  write_plain_bashrc
  run env DOT_DIR="$SANDBOX/nonexistent.git" sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no bare repo" ]]
  [ ! -d "$HOME/.config/shell" ]
}

@test "non-interactive without --yes: skips" {
  write_plain_bashrc
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "non-interactive" ]]
  [ ! -d "$HOME/.config/shell" ]
}

@test "unknown argument exits 2" {
  run sh "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "unknown argument" ]]
}

# --- conflict check ----------------------------------------------------------

@test "aborts with exit 1 if .config/shell/init.sh already exists" {
  write_plain_bashrc
  mkdir -p "$HOME/.config/shell"
  printf '# existing\n' > "$HOME/.config/shell/init.sh"

  run sh "$SCRIPT" --yes
  [ "$status" -eq 1 ]
  [[ "$output" =~ "already exist" ]]
  [[ "$output" =~ "no changes made" ]]
}

@test "aborts if .config/bash/init.sh already exists" {
  write_plain_bashrc
  mkdir -p "$HOME/.config/bash"
  printf '# existing\n' > "$HOME/.config/bash/init.sh"

  run sh "$SCRIPT" --yes
  [ "$status" -eq 1 ]
  [[ "$output" =~ "already exist" ]]
}

@test "on conflict no new files are written" {
  write_plain_bashrc
  mkdir -p "$HOME/.config/shell"
  printf '# existing\n' > "$HOME/.config/shell/init.sh"

  original_bashrc=$(cat "$HOME/.bashrc")
  sh "$SCRIPT" --yes 2>/dev/null || true

  # .bashrc must be unchanged.
  [ "$(cat "$HOME/.bashrc")" = "$original_bashrc" ]
  # None of the other new files should exist.
  [ ! -f "$HOME/.config/shell/env.sh" ]
  [ ! -f "$HOME/.config/bash/init.sh" ]
}

@test "lists all conflicting files before aborting" {
  write_plain_bashrc
  mkdir -p "$HOME/.config/shell" "$HOME/.config/bash"
  printf '# s\n' > "$HOME/.config/shell/init.sh"
  printf '# b\n' > "$HOME/.config/bash/init.sh"

  run sh "$SCRIPT" --yes
  [ "$status" -eq 1 ]
  [[ "$output" =~ ".config/shell/init.sh" ]]
  [[ "$output" =~ ".config/bash/init.sh" ]]
}

# --- migrate mode (existing .bashrc) -----------------------------------------

@test "migrate: creates thin loader .bashrc" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q '\.config/shell/init\.sh' "$HOME/.bashrc"
  grep -q '\.config/bash/init\.sh'  "$HOME/.bashrc"
}

@test "migrate: original .bashrc content preserved in .config/bash/init.sh" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  [ -f "$HOME/.config/bash/init.sh" ]
  grep -q 'plain bashrc' "$HOME/.config/bash/init.sh"
}

@test "migrate: creates completion/prompt/functions sub-files" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  [ -f "$HOME/.config/bash/completion.sh" ]
  [ -f "$HOME/.config/bash/prompt.sh" ]
  [ -f "$HOME/.config/bash/functions.sh" ]
}

@test "migrate: bash/init.sh sources sub-files" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'completion\.sh' "$HOME/.config/bash/init.sh"
  grep -q 'prompt\.sh'     "$HOME/.config/bash/init.sh"
}

@test "migrate: prompt.sh has starship guard" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'command -v starship' "$HOME/.config/bash/prompt.sh"
  grep -q 'PS1=' "$HOME/.config/bash/prompt.sh"
}

@test "migrate: .bash_profile created" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  [ -f "$HOME/.bash_profile" ]
  grep -q '\.bashrc' "$HOME/.bash_profile"
}

@test "migrate: existing .bash_profile with .bashrc reference not overwritten" {
  write_plain_bashrc
  printf '# custom profile\n. "$HOME/.bashrc"\n' > "$HOME/.bash_profile"
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'custom profile' "$HOME/.bash_profile"
}

@test "migrate: bash files staged in bare repo" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  staged=$(staged_files)
  printf '%s\n' "$staged" | grep -q '\.bashrc'
  printf '%s\n' "$staged" | grep -q '\.config/bash/init\.sh'
  printf '%s\n' "$staged" | grep -q '\.config/bash/completion\.sh'
  printf '%s\n' "$staged" | grep -q '\.config/bash/prompt\.sh'
}

# --- create mode (no .bashrc) ------------------------------------------------

@test "create: fresh .bashrc written as thin loader" {
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  [ -f "$HOME/.bashrc" ]
  grep -q '\.config/shell/init\.sh' "$HOME/.bashrc"
}

@test "create: bash sub-files written (completion, prompt, functions)" {
  sh "$SCRIPT" --yes >/dev/null
  [ -f "$HOME/.config/bash/completion.sh" ]
  [ -f "$HOME/.config/bash/prompt.sh" ]
  [ -f "$HOME/.config/bash/functions.sh" ]
}

@test "create: bash/init.sh sources sub-files" {
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'completion\.sh' "$HOME/.config/bash/init.sh"
  grep -q 'prompt\.sh'     "$HOME/.config/bash/init.sh"
}

@test "create: prompt.sh has starship guard" {
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'command -v starship' "$HOME/.config/bash/prompt.sh"
  grep -q 'PS1=' "$HOME/.config/bash/prompt.sh"
}

@test "create: all bash files staged in bare repo" {
  sh "$SCRIPT" --yes >/dev/null
  staged=$(staged_files)
  printf '%s\n' "$staged" | grep -q '\.bashrc'
  printf '%s\n' "$staged" | grep -q '\.config/bash/init\.sh'
  printf '%s\n' "$staged" | grep -q '\.config/bash/completion\.sh'
  printf '%s\n' "$staged" | grep -q '\.config/bash/prompt\.sh'
}

# --- shared layer ------------------------------------------------------------

@test "shared POSIX layer created under .config/shell/" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  [ -f "$HOME/.config/shell/init.sh" ]
  [ -f "$HOME/.config/shell/env.sh" ]
  [ -f "$HOME/.config/shell/aliases.sh" ]
  [ -f "$HOME/.config/shell/functions.sh" ]
  [ -f "$HOME/.config/shell/secrets.sh" ]
  [ -d "$HOME/.config/shell/os" ]
  [ -d "$HOME/.config/shell/host" ]
}

@test "shared layer seeds dot alias and dot_add/mkcd/dj functions" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q "alias dot='git --git-dir=\"\$HOME/.config.git\" --work-tree=\"\$HOME\"'" \
    "$HOME/.config/shell/aliases.sh"
  grep -q 'dot_add()' "$HOME/.config/shell/functions.sh"
  grep -q "alias dot-add='dot_add'" "$HOME/.config/shell/functions.sh"
  grep -q 'mkcd()' "$HOME/.config/shell/functions.sh"
  grep -q 'dj()' "$HOME/.config/shell/functions.sh"
  grep -q '\.config\.git' "$HOME/.config/shell/functions.sh"
}

@test "OS stub files created for linux, darwin, wsl" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  [ -f "$HOME/.config/shell/os/linux.sh" ]
  [ -f "$HOME/.config/shell/os/darwin.sh" ]
  [ -f "$HOME/.config/shell/os/wsl.sh" ]
}

@test "shared layer staged in bare repo" {
  write_plain_bashrc
  sh "$SCRIPT" --yes >/dev/null
  staged=$(staged_files)
  printf '%s\n' "$staged" | grep -q '\.config/shell/init\.sh'
  printf '%s\n' "$staged" | grep -q '\.config/shell/env\.sh'
}

# --- zsh migrate mode --------------------------------------------------------

@test "migrate zsh: creates thin loader .zshrc" {
  write_plain_zshrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q '\.config/shell/init\.sh' "$HOME/.zshrc"
  grep -q '\.config/zsh/init\.sh'   "$HOME/.zshrc"
}

@test "migrate zsh: original content preserved in .config/zsh/init.sh" {
  write_plain_zshrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'plain zshrc' "$HOME/.config/zsh/init.sh"
}

@test "migrate zsh: creates completion/prompt/functions sub-files" {
  write_plain_zshrc
  sh "$SCRIPT" --yes >/dev/null
  [ -f "$HOME/.config/zsh/completion.zsh" ]
  [ -f "$HOME/.config/zsh/prompt.zsh" ]
  [ -f "$HOME/.config/zsh/functions.zsh" ]
}

@test "migrate zsh: init.sh sources sub-files" {
  write_plain_zshrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'completion\.zsh' "$HOME/.config/zsh/init.sh"
  grep -q 'prompt\.zsh'     "$HOME/.config/zsh/init.sh"
}

@test "migrate zsh: prompt.zsh has starship guard" {
  write_plain_zshrc
  sh "$SCRIPT" --yes >/dev/null
  grep -q 'command -v starship' "$HOME/.config/zsh/prompt.zsh"
}

# --- both shells -------------------------------------------------------------

@test "migrate both shells in one pass" {
  write_plain_bashrc
  write_plain_zshrc
  run sh "$SCRIPT" --yes
  [ "$status" -eq 0 ]
  grep -q '\.config/shell/init\.sh' "$HOME/.bashrc"
  grep -q '\.config/shell/init\.sh' "$HOME/.zshrc"
  grep -q 'plain bashrc' "$HOME/.config/bash/init.sh"
  grep -q 'plain zshrc'  "$HOME/.config/zsh/init.sh"
}
