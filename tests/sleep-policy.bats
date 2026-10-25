#!/usr/bin/env bats
#
# Tests for packages/postinstall/sleep-policy.sh.
#
# PATH is swapped for a farm of symlinks to just the binaries the hook
# calls, plus stubs, so the host's own systemctl / hypridle never leak in.

load test_helper

HOOK="$DOTFILES_REPO_ROOT/packages/postinstall/sleep-policy.sh"

setup() {
  sandbox_setup
  stub_dir_setup
  [ "$(uname -s)" = Linux ] || skip "Linux-only"

  export DOTFILES_SLEEP_ETC="$SANDBOX/etc"
  export DOTFILES_POWER_SUPPLY_DIR="$SANDBOX/power_supply"
  export DOTFILES_CMDLINE_FILE="$SANDBOX/cmdline"
  mkdir -p "$DOTFILES_SLEEP_ETC" "$DOTFILES_POWER_SUPPLY_DIR/BAT0"
  printf 'root=/dev/x resume=/dev/x resume_offset=1\n' > "$DOTFILES_CMDLINE_FILE"

  local farm="$SANDBOX/farm" c src
  mkdir -p "$farm"
  for c in sh cat chmod cmp dirname grep install ls mkdir mktemp rm rmdir uname; do
    src="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$src" ] && ln -sf "$src" "$farm/$c"
  done
  export PATH="$STUB_BIN:$farm"

  export SYSTEMCTL_LOG="$SANDBOX/systemctl.log"
  printf '#!/bin/sh\nexec "$@"\n' > "$STUB_BIN/sudo"
  printf '#!/bin/sh\necho "$*" >> "$SYSTEMCTL_LOG"\nexit 0\n' > "$STUB_BIN/systemctl"
  chmod +x "$STUB_BIN/sudo" "$STUB_BIN/systemctl"
}

teardown() {
  sandbox_teardown
}

@test "no battery: skips and writes nothing" {
  rmdir "$DOTFILES_POWER_SUPPLY_DIR/BAT0"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no battery" ]]
  [ -z "$(ls -A "$DOTFILES_SLEEP_ETC")" ]
}

@test "no resume= on the kernel command line: skips and writes nothing" {
  printf 'root=/dev/x\n' > "$DOTFILES_CMDLINE_FILE"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hibernation not configured" ]]
  [ -z "$(ls -A "$DOTFILES_SLEEP_ETC")" ]
}

@test "writes the sleep, logind and UPower drop-ins" {
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  grep -qx 'HibernateDelaySec=50min' "$DOTFILES_SLEEP_ETC/systemd/sleep.conf.d/10-hibernate-delay.conf"
  grep -qx 'HandleLidSwitch=suspend-then-hibernate' "$DOTFILES_SLEEP_ETC/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf"
  grep -qx 'HandleLidSwitchExternalPower=suspend-then-hibernate' "$DOTFILES_SLEEP_ETC/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf"
  f="$DOTFILES_SLEEP_ETC/UPower/UPower.conf.d/10-hibernate-at-5.conf"
  grep -qx 'PercentageAction=5' "$f"
  grep -qx 'CriticalPowerAction=Hibernate' "$f"
}

@test "first run reloads logind and restarts upower" {
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  grep -q 'kill -s HUP systemd-logind.service' "$SYSTEMCTL_LOG"
  grep -q 'restart upower.service' "$SYSTEMCTL_LOG"
}

@test "second run changes nothing and reloads nothing" {
  sh "$HOOK" >/dev/null 2>&1
  : > "$SYSTEMCTL_LOG"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  ! grep -q -e 'HUP' -e 'restart upower' "$SYSTEMCTL_LOG"
  [[ ! "$output" =~ "wrote" ]]
}

@test "a drifted drop-in is rewritten" {
  sh "$HOOK" >/dev/null 2>&1
  printf '[Sleep]\nHibernateDelaySec=5min\n' > "$DOTFILES_SLEEP_ETC/systemd/sleep.conf.d/10-hibernate-delay.conf"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  grep -qx 'HibernateDelaySec=50min' "$DOTFILES_SLEEP_ETC/systemd/sleep.conf.d/10-hibernate-delay.conf"
}

@test "hypridle installed with a user unit: enables and starts it" {
  printf '#!/bin/sh\n' > "$STUB_BIN/hypridle"; chmod +x "$STUB_BIN/hypridle"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  grep -q -e '--user enable hypridle.service' "$SYSTEMCTL_LOG"
  grep -q -e '--user start hypridle.service' "$SYSTEMCTL_LOG"
}

@test "hypridle missing: warns but still succeeds" {
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hypridle not installed" ]]
}
