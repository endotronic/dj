#!/usr/bin/env bats
#
# Tests for scripts/ssh-menu-register.sh: adds a Host entry to
# ~/.ssh/config under a section header derived from a system type, so
# the machine shows up in the tmux NEW menu (see
# ~/.config/tmux/scripts/gen-ssh-menu.sh, which groups Host entries
# under whatever full-line comment precedes them).
#
# bats' `run` captures stdout, so it's never a tty -- can_prompt() is
# always false here. That means the --yes/--no/interactive-prompt
# paths aren't reachable through `run`; every test instead drives the
# script the way a non-interactive caller (install.sh, dj-setup.sh)
# does: passing --type/--alias/--hostname/--user directly, with --yes
# to skip the confirmation prompt.

load test_helper

setup() {
  sandbox_setup
  export SCRIPT="$DOTFILES_REPO_ROOT/scripts/ssh-menu-register.sh"
  export DOT_DIR="$HOME/.config.git"
  mkdir -p "$HOME/.ssh"
}

teardown() {
  sandbox_teardown
}

# --- non-interactive skip behavior --------------------------------------

@test "not attached to a terminal and no --yes: does nothing" {
  run sh "$SCRIPT" --type server --hostname mercury.home --user kevin
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.ssh/config" ]
}

@test "--no is a no-op regardless of other flags" {
  run sh "$SCRIPT" --no --type server --hostname mercury.home --user kevin
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.ssh/config" ]
}

# --- happy path (--yes bypasses the confirmation prompt) ----------------

@test "--yes with full flags adds a Host entry under a new section" {
  run sh "$SCRIPT" --yes --type server --alias mercury --hostname mercury.home.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^# Servers$' "$HOME/.ssh/config"
  grep -q '^Host mercury$' "$HOME/.ssh/config"
  grep -q '    HostName mercury.home.example' "$HOME/.ssh/config"
  grep -q '    User kevin' "$HOME/.ssh/config"
}

@test "alias defaults to the hostname's first label when omitted, non-interactively" {
  run sh "$SCRIPT" --yes --type server --hostname ruby.air.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^Host ruby$' "$HOME/.ssh/config"
}

@test "no hostname available non-interactively: skips without creating the file" {
  run sh "$SCRIPT" --yes --type server
  [ "$status" -eq 0 ]
  [[ "$output" =~ "skipping" ]]
  [ ! -f "$HOME/.ssh/config" ]
}

# --- section-title resolution --------------------------------------------

@test "unknown type falls back to Ucfirst(type) + s" {
  run sh "$SCRIPT" --yes --type laptop --alias hal --hostname hal.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^# Laptops$' "$HOME/.ssh/config"
}

@test "type mapped in ssh-menu-sections.txt uses that title verbatim" {
  mkdir -p "$XDG_CONFIG_HOME/dj"
  printf 'vm VMs\n' > "$XDG_CONFIG_HOME/dj/ssh-menu-sections.txt"

  run sh "$SCRIPT" --yes --type vm --alias ruby --hostname ruby.air.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^# VMs$' "$HOME/.ssh/config"
}

@test "no type resolvable (no flag, no persisted system-type): files under Other" {
  run sh "$SCRIPT" --yes --alias plain --hostname plain.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^# Other$' "$HOME/.ssh/config"
}

@test "empty --type (dj-setup registering a common-only target) does not fall back to the local system-type" {
  mkdir -p "$(dirname "$XDG_CONFIG_HOME/dotfiles/system-type")"
  printf 'desktop\n' > "$XDG_CONFIG_HOME/dotfiles/system-type"

  run sh "$SCRIPT" --yes --type '' --alias plain --hostname plain.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^# Other$' "$HOME/.ssh/config"
  ! grep -q '^# Desktops$' "$HOME/.ssh/config"
}

@test "omitted --type falls back to the local persisted system-type" {
  mkdir -p "$(dirname "$XDG_CONFIG_HOME/dotfiles/system-type")"
  printf 'desktop\n' > "$XDG_CONFIG_HOME/dotfiles/system-type"

  run sh "$SCRIPT" --yes --alias here --hostname here.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^# Desktops$' "$HOME/.ssh/config"
}

# --- insertion placement ---------------------------------------------------

@test "existing matching section: new host is appended under it, not a duplicate header" {
  cat > "$HOME/.ssh/config" <<'EOF'
# Servers

Host mercury
    HostName mercury.home.example
    User kevin

# VMs

Host ruby
    HostName ruby.air.example
    User kevin
EOF

  run sh "$SCRIPT" --yes --type server --alias venus --hostname venus.home.example --user kevin
  [ "$status" -eq 0 ]
  [ "$(grep -c '^# Servers$' "$HOME/.ssh/config")" -eq 1 ]
  grep -q '^Host venus$' "$HOME/.ssh/config"
  # venus lands within the Servers section, before the VMs header.
  awk '/^# Servers$/{f=1} /^# VMs$/{f=0} f && /^Host venus$/{found=1} END{exit !found}' "$HOME/.ssh/config"
}

@test "no matching section exists yet: a new one is appended at the end" {
  cat > "$HOME/.ssh/config" <<'EOF'
# Servers

Host mercury
    HostName mercury.home.example
    User kevin
EOF
  mkdir -p "$XDG_CONFIG_HOME/dj"
  printf 'vm VMs\n' > "$XDG_CONFIG_HOME/dj/ssh-menu-sections.txt"

  run sh "$SCRIPT" --yes --type vm --alias ruby --hostname ruby.air.example --user kevin
  [ "$status" -eq 0 ]
  grep -q '^# VMs$' "$HOME/.ssh/config"
  awk '/^# VMs$/{f=1} f && /^Host ruby$/{found=1} END{exit !found}' "$HOME/.ssh/config"
}

@test "empty ~/.ssh/config: creates it with one section" {
  run sh "$SCRIPT" --yes --type server --alias mercury --hostname mercury.home.example --user kevin
  [ "$status" -eq 0 ]
  [ -f "$HOME/.ssh/config" ]
  grep -q '^# Servers$' "$HOME/.ssh/config"
}

# --- idempotency ------------------------------------------------------------

@test "re-running with the same alias is a no-op (already present)" {
  sh "$SCRIPT" --yes --type server --alias mercury --hostname mercury.home.example --user kevin >/dev/null

  run sh "$SCRIPT" --yes --type server --alias mercury --hostname mercury.home.example --user kevin
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already" ]]
  [ "$(grep -c '^Host mercury$' "$HOME/.ssh/config")" -eq 1 ]
}

@test "alias already present under any Host line (multi-target) is detected" {
  cat > "$HOME/.ssh/config" <<'EOF'
Host mercury mercury.home.example
    User kevin
EOF

  run sh "$SCRIPT" --yes --type server --alias mercury --hostname mercury.home.example --user kevin
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already" ]]
  [ "$(grep -c '^Host' "$HOME/.ssh/config")" -eq 1 ]
}

@test "invalid alias is rejected without touching the file" {
  run sh "$SCRIPT" --yes --type server --alias 'bad alias!' --hostname mercury.home.example --user kevin
  [ "$status" -eq 0 ]
  [[ "$output" =~ "must contain only" ]]
  [ ! -f "$HOME/.ssh/config" ]
}

# --- staging into the private repo -----------------------------------------

@test "with a private repo present, the config is staged via dot add" {
  git init --bare -q "$DOT_DIR"
  git --git-dir="$DOT_DIR" --work-tree="$HOME" config user.email t@t
  git --git-dir="$DOT_DIR" --work-tree="$HOME" config user.name t

  run sh "$SCRIPT" --yes --type server --alias mercury --hostname mercury.home.example --user kevin
  [ "$status" -eq 0 ]
  [[ "$output" =~ "staged" ]]
  run git --git-dir="$DOT_DIR" --work-tree="$HOME" diff --cached --name-only
  [[ "$output" == *".ssh/config"* ]]
}

@test "without a private repo, no staging is attempted and no error occurs" {
  run sh "$SCRIPT" --yes --type server --alias mercury --hostname mercury.home.example --user kevin
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "staged" ]]
}

@test "unknown argument exits 2" {
  run sh "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "unknown argument" ]]
}
