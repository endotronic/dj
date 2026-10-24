#!/usr/bin/env bats
#
# Tests for ~/.config/tmux/scripts/gen-ssh-menu.sh (private repo, reached
# via _DOTFILES_SHELL_ROOT): regenerates the tmux snippet that binds the
# "NEW" menu twice -- the MouseDown1Status click dispatcher and a
# `bind Tab` keyboard binding -- both over one statically baked
# display-menu entry list.
#
# The script reads $HOME/.ssh/config and $HOME dirs and writes
# $HOME/.config/tmux/generated/ssh-menu.conf, so the sandboxed HOME from
# test_helper isolates everything it touches. TMUX_NESTED is the only
# input that isn't filesystem state (tmux.conf exports it when @is_nested
# is on).

load test_helper

setup() {
  sandbox_setup
  SCRIPT="$_DOTFILES_SHELL_ROOT/.config/tmux/scripts/gen-ssh-menu.sh"
  OUT="$HOME/.config/tmux/generated/ssh-menu.conf"
  mkdir -p "$HOME/.ssh"
  unset TMUX_NESTED
}

teardown() {
  sandbox_teardown
}

gen() {
  sh "$SCRIPT"
}

# --- both bindings, same entries ----------------------------------------

@test "generates the mouse dispatcher and a Tab keyboard bind" {
  printf '# Servers\nHost mercury\n    HostName mercury.example\n' > "$HOME/.ssh/config"
  run gen
  [ "$status" -eq 0 ]
  grep -q '^bind -T root MouseDown1Status if-shell' "$OUT"
  grep -q '^bind Tab display-menu -T "NEW" -x C -y C' "$OUT"
}

@test "the Tab bind bakes in the same entries as the mouse bind" {
  printf '# Servers\nHost mercury\n    HostName mercury.example\n' > "$HOME/.ssh/config"
  gen
  # the MouseDown1Status bind spans backslash-continuation lines
  mouse_line="$(awk '{ sub(/\\$/, ""); printf "%s ", $0 }' "$OUT" | grep 'MouseDown1Status')"
  tab_line="$(grep '^bind Tab' "$OUT")"
  printf '%s' "$mouse_line" | grep -qF '"new-window -n '"'"'mercury'"'"' '"'"'ssh mercury'"'"'"'
  printf '%s' "$tab_line" | grep -qF '"new-window -n '"'"'mercury'"'"' '"'"'ssh mercury'"'"'"'
}

@test "Tab bind centers (-x C -y C) and omits -O" {
  gen
  grep '^bind Tab' "$OUT" | grep -q -- '-x C -y C'
  ! grep '^bind Tab' "$OUT" | grep -q -- '-O'
}

@test "menu always leads with a plain home entry even with no config" {
  gen
  grep '^bind Tab' "$OUT" | grep -qF '"home" "" "new-window"'
}

# --- home subdir entries iff present -------------------------------------

@test "services/projects/notebook entries appear iff the directory exists" {
  mkdir -p "$HOME/services" "$HOME/notebook"
  gen
  grep '^bind Tab' "$OUT" | grep -qF "\"services\" \"\" \"new-window -n 'services' -c '$HOME/services'\""
  grep '^bind Tab' "$OUT" | grep -qF "\"notebook\" \"\" \"new-window -n 'notebook' -c '$HOME/notebook'\""
  # no ~/projects -> neither the top-level entry nor the Projects section
  ! grep '^bind Tab' "$OUT" | grep -qF "new-window -n 'projects'"
  ! grep '^bind Tab' "$OUT" | grep -qF ']Projects'
}

@test "Projects section lists subdirectories of ~/projects" {
  mkdir -p "$HOME/projects/alpha" "$HOME/projects/beta"
  gen
  grep '^bind Tab' "$OUT" | grep -qF "]Projects"
  grep '^bind Tab' "$OUT" | grep -qF "new-window -n 'alpha' -c '$HOME/projects/alpha'"
  grep '^bind Tab' "$OUT" | grep -qF "new-window -n 'beta' -c '$HOME/projects/beta'"
}

# --- ssh config parsing -------------------------------------------------

@test "unsectioned hosts get no header; sectioned hosts get a disabled themed header" {
  printf 'Host lonely\n    HostName lonely.example\n# VMs\nHost ruby\n    HostName ruby.example\n' \
    > "$HOME/.ssh/config"
  gen
  grep '^bind Tab' "$OUT" | grep -qF '"-#[fg=#{@theme_color}]VMs"'
  grep '^bind Tab' "$OUT" | grep -qF 'ssh lonely'
  grep '^bind Tab' "$OUT" | grep -qF 'ssh ruby'
}

@test "wildcard, negated, own-hostname, and HostName-less entries are skipped" {
  me="$(hostname -s 2>/dev/null || uname -n)"
  {
    printf 'Host *\n    IdentityFile ~/.ssh/id_x\n'
    printf 'Host !excluded\n    HostName x.example\n'
    printf 'Host %s\n    HostName self.example\n' "$me"
    printf 'Host keyonly\n    IdentityFile ~/.ssh/id_y\n'
    printf 'Host real\n    HostName real.example\n'
  } > "$HOME/.ssh/config"
  gen
  grep '^bind Tab' "$OUT" | grep -qF 'ssh real'
  ! grep '^bind Tab' "$OUT" | grep -qF 'ssh keyonly'
  [ -z "$me" ] || ! grep '^bind Tab' "$OUT" | grep -qF "ssh $me"
  ! grep '^bind Tab' "$OUT" | grep -qF 'ssh !excluded'
}

# --- nested tmux --------------------------------------------------------

@test "nested tmux omits ssh hosts but keeps Projects and home entries" {
  printf '# Servers\nHost mercury\n    HostName mercury.example\n' > "$HOME/.ssh/config"
  mkdir -p "$HOME/projects/alpha"
  TMUX_NESTED=1 gen
  grep '^bind Tab' "$OUT" | grep -qF 'alpha'
  grep '^bind Tab' "$OUT" | grep -qF '"home"'
  ! grep '^bind Tab' "$OUT" | grep -qF 'ssh mercury'
}
