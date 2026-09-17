#!/usr/bin/env bats
#
# Tests for scripts/run-postinstall.sh.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
  stub_dir_setup
  export RUN_POSTINSTALL="$DOTFILES_REPO_ROOT/scripts/run-postinstall.sh"
}

teardown() {
  sandbox_teardown
}

# --- argument parsing -----------------------------------------------------

@test "--help exits 0 and prints usage" {
  run sh "$RUN_POSTINSTALL" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ Usage ]]
}

@test "--system-type with invalid characters exits 2" {
  run sh "$RUN_POSTINSTALL" --system-type 'not a type'
  [ "$status" -eq 2 ]
  [[ "$output" =~ "invalid system-type" ]]
}

@test "unknown argument exits 2" {
  run sh "$RUN_POSTINSTALL" --not-a-flag
  [ "$status" -eq 2 ]
  [[ "$output" =~ "unknown argument" ]]
}

# --- no lists / empty lists -------------------------------------------------

@test "no hook lists present exits 0 with a 'no hooks listed' message" {
  fake_lists="$SANDBOX/fake-postinstall"
  DOTFILES_DJ_POSTINSTALL_DIR="$fake_lists" run sh "$RUN_POSTINSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no hooks listed" ]]
}

# --- happy path: hook script runs -------------------------------------------

@test "a listed hook with a matching script runs it" {
  fake_lists="$SANDBOX/fake-postinstall"
  fake_hooks="$SANDBOX/fake-hooks"
  mkdir -p "$fake_lists" "$fake_hooks"
  printf 'myhook\n' > "$fake_lists/common.txt"
  marker="$SANDBOX/myhook-ran"
  printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$fake_hooks/myhook.sh"
  chmod +x "$fake_hooks/myhook.sh"

  DOTFILES_DJ_POSTINSTALL_DIR="$fake_lists" DOTFILES_POSTINSTALL_DIR="$fake_hooks" \
    run sh "$RUN_POSTINSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "running myhook" ]]
  [ -f "$marker" ]
}

@test "--dry-run reports what would run without running it" {
  fake_lists="$SANDBOX/fake-postinstall"
  fake_hooks="$SANDBOX/fake-hooks"
  mkdir -p "$fake_lists" "$fake_hooks"
  printf 'myhook\n' > "$fake_lists/common.txt"
  marker="$SANDBOX/myhook-ran"
  printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$fake_hooks/myhook.sh"
  chmod +x "$fake_hooks/myhook.sh"

  DOTFILES_DJ_POSTINSTALL_DIR="$fake_lists" DOTFILES_POSTINSTALL_DIR="$fake_hooks" \
    run sh "$RUN_POSTINSTALL" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "would run myhook" ]]
  [ ! -f "$marker" ]
}

# --- missing hook script ----------------------------------------------------

@test "a listed hook without a matching script warns and exits nonzero" {
  fake_lists="$SANDBOX/fake-postinstall"
  fake_hooks="$SANDBOX/fake-hooks"
  mkdir -p "$fake_lists" "$fake_hooks"
  printf 'ghosthook\n' > "$fake_lists/common.txt"

  DOTFILES_DJ_POSTINSTALL_DIR="$fake_lists" DOTFILES_POSTINSTALL_DIR="$fake_hooks" \
    run --separate-stderr sh "$RUN_POSTINSTALL"
  [ "$status" -ne 0 ]
  [[ "$stderr" =~ "no hook script for ghosthook" ]]
}

# --- failing hook ------------------------------------------------------------

@test "a hook that exits nonzero warns but doesn't abort other hooks" {
  fake_lists="$SANDBOX/fake-postinstall"
  fake_hooks="$SANDBOX/fake-hooks"
  mkdir -p "$fake_lists" "$fake_hooks"
  printf 'badhook\ngoodhook\n' > "$fake_lists/common.txt"
  printf '#!/bin/sh\nexit 1\n' > "$fake_hooks/badhook.sh"
  chmod +x "$fake_hooks/badhook.sh"
  marker="$SANDBOX/goodhook-ran"
  printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$fake_hooks/goodhook.sh"
  chmod +x "$fake_hooks/goodhook.sh"

  DOTFILES_DJ_POSTINSTALL_DIR="$fake_lists" DOTFILES_POSTINSTALL_DIR="$fake_hooks" \
    run --separate-stderr sh "$RUN_POSTINSTALL"
  [ "$status" -ne 0 ]
  [[ "$stderr" =~ "hook badhook failed" ]]
  [ -f "$marker" ]
}

# --- personal lists: common + types/<type> + hosts/<hostname> -------------

@test "--system-type pulls in lists_dir/types/<type>.txt" {
  fake_lists="$SANDBOX/fake-postinstall"
  fake_hooks="$SANDBOX/fake-hooks"
  mkdir -p "$fake_lists/types" "$fake_hooks"
  : > "$fake_lists/common.txt"
  printf 'typehook\n' > "$fake_lists/types/sometype.txt"
  marker="$SANDBOX/typehook-ran"
  printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$fake_hooks/typehook.sh"
  chmod +x "$fake_hooks/typehook.sh"

  DOTFILES_DJ_POSTINSTALL_DIR="$fake_lists" DOTFILES_POSTINSTALL_DIR="$fake_hooks" \
    run sh "$RUN_POSTINSTALL" --system-type sometype
  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

@test "host-specific list at lists_dir/hosts/<hostname>.txt is included" {
  fake_lists="$SANDBOX/fake-postinstall"
  fake_hooks="$SANDBOX/fake-hooks"
  mkdir -p "$fake_lists/hosts" "$fake_hooks"
  : > "$fake_lists/common.txt"
  _host=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo unknown)
  printf 'hosthook\n' > "$fake_lists/hosts/$_host.txt"
  marker="$SANDBOX/hosthook-ran"
  printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$fake_hooks/hosthook.sh"
  chmod +x "$fake_hooks/hosthook.sh"

  DOTFILES_DJ_POSTINSTALL_DIR="$fake_lists" DOTFILES_POSTINSTALL_DIR="$fake_hooks" \
    run sh "$RUN_POSTINSTALL"
  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

# --- packages/postinstall/docker.sh -----------------------------------------

@test "docker.sh: exits 0 immediately when docker is not on PATH" {
  # Hermetic: restrict PATH to STUB_BIN-only so a real, system-installed
  # docker can't leak in (mirrors packages/scripts/fd.sh's pattern).
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/docker.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "docker not installed" ]]
}

@test "docker.sh: enables the service and adds the user to the docker group" {
  stub_cmd docker
  stub_sudo_passthrough
  stub_cmd systemctl
  cat > "$STUB_BIN/getent" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "group docker") exit 0 ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$STUB_BIN/getent"
  cat > "$STUB_BIN/id" <<'EOF'
#!/bin/sh
printf 'wheel\n'
EOF
  chmod +x "$STUB_BIN/id"
  stub_cmd usermod

  # docker.sh pipes through tr/grep, which aren't dash builtins -- keep
  # real /usr/bin:/bin reachable (after STUB_BIN, so stubs still win
  # for the names we stub) instead of the docker.sh-not-installed
  # test's fully hermetic PATH=STUB_BIN.
  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/docker.sh"
  [ "$status" -eq 0 ]
  stub_called systemctl
  [[ "$(stub_log)" =~ "systemctl enable --now docker" ]]
  [[ "$(stub_log)" =~ "usermod -aG docker" ]]
}

@test "docker.sh: skips group add when already a member" {
  stub_cmd docker
  stub_sudo_passthrough
  stub_cmd systemctl
  cat > "$STUB_BIN/getent" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$STUB_BIN/getent"
  cat > "$STUB_BIN/id" <<'EOF'
#!/bin/sh
printf 'wheel docker\n'
EOF
  chmod +x "$STUB_BIN/id"
  cat > "$STUB_BIN/usermod" <<EOF
#!/bin/sh
{ printf 'usermod'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
exit 0
EOF
  chmod +x "$STUB_BIN/usermod"

  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/docker.sh"
  [ "$status" -eq 0 ]
  ! stub_called usermod
}

# --- packages/postinstall/docker-compose.sh ---------------------------------

@test "docker-compose.sh: no-op when docker-compose is already on PATH" {
  stub_cmd docker-compose
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/docker-compose.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "docker-compose.sh: symlinks the cli-plugin onto PATH when absent" {
  plugin_dir="$SANDBOX/cli-plugins"
  mkdir -p "$plugin_dir"
  printf '#!/bin/sh\nexit 0\n' > "$plugin_dir/docker-compose"
  chmod +x "$plugin_dir/docker-compose"
  link_target="$SANDBOX/usr-local-bin/docker-compose"
  mkdir -p "$(dirname "$link_target")"

  stub_sudo_passthrough
  # Hermetic: PATH=STUB_BIN only, so a real, system-installed
  # docker-compose can't short-circuit the check. `ln` isn't a dash
  # builtin, so stub it as a thin wrapper around the real binary.
  cat > "$STUB_BIN/ln" <<'EOF'
#!/bin/sh
exec /usr/bin/ln "$@"
EOF
  chmod +x "$STUB_BIN/ln"

  DOTFILES_CLI_PLUGINS_DIRS="$plugin_dir" \
    DOTFILES_COMPOSE_SYMLINK_DEST="$link_target" \
    PATH="$STUB_BIN" \
    run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/docker-compose.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "symlinked" ]]
  [ -L "$link_target" ]
}

@test "docker-compose.sh: warns and exits 0 when no plugin is found anywhere" {
  # Empty fake dir, not the real /usr/lib/docker/cli-plugins -- this
  # machine has the real plugin installed, which would otherwise leak in.
  empty_dir="$SANDBOX/empty-cli-plugins"
  mkdir -p "$empty_dir"
  DOTFILES_CLI_PLUGINS_DIRS="$empty_dir" \
    PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/docker-compose.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no docker-compose plugin found" ]]
}

# --- packages/postinstall/tmux-backports.sh ---------------------------------

# Stubs `dpkg` (handles `-s tmux` via $TMUX_DPKG_INSTALLED, and passes
# `--compare-versions` through to the real binary -- that subcommand is
# a pure version-string comparator with no dpkg-database side effects,
# same reasoning as docker-compose.sh's real-`ln` passthrough stub),
# `dpkg-query` (prints $TMUX_NEW_VERSION once the apt-get stub below
# has "installed" it, else $TMUX_OLD_VERSION) and `apt-get` (logs its
# args; touches a marker on the actual `install -t ... tmux` call so
# dpkg-query's stub can flip versions).
stub_tmux_backports_apt() {
  : "${TMUX_DPKG_INSTALLED:=1}"
  : "${TMUX_OLD_VERSION:=3.3a-3}"
  : "${TMUX_NEW_VERSION:=3.5a-2~bpo12+1}"
  marker="$SANDBOX/tmux-upgraded"

  cat > "$STUB_BIN/dpkg" <<EOF
#!/bin/sh
case "\$1" in
  --compare-versions) shift; exec /usr/bin/dpkg --compare-versions "\$@" ;;
  -s) [ "$TMUX_DPKG_INSTALLED" = 1 ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$STUB_BIN/dpkg"

  cat > "$STUB_BIN/dpkg-query" <<EOF
#!/bin/sh
if [ -f "$marker" ]; then printf '%s\n' "$TMUX_NEW_VERSION"; else printf '%s\n' "$TMUX_OLD_VERSION"; fi
EOF
  chmod +x "$STUB_BIN/dpkg-query"

  cat > "$STUB_BIN/apt-get" <<EOF
#!/bin/sh
{ printf 'apt-get'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
case " \$* " in
  *" install "*" -t "*) touch "$marker" ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/apt-get"
}

write_os_release() {
  os_release="$SANDBOX/os-release"
  printf 'ID=%s\n' "$1" > "$os_release"
  [ -n "${2:-}" ] && printf 'VERSION_CODENAME=%s\n' "$2" >> "$os_release"
  export DOTFILES_OS_RELEASE_FILE="$os_release"
}

@test "tmux-backports.sh: skips when dpkg is not present" {
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not a dpkg system" ]]
}

@test "tmux-backports.sh: skips when apt-get is not present" {
  stub_cmd dpkg
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "apt-get not found" ]]
}

@test "tmux-backports.sh: skips on non-Debian distro" {
  stub_cmd dpkg
  stub_cmd apt-get
  write_os_release arch
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not Debian" ]]
}

@test "tmux-backports.sh: skips when tmux is not installed" {
  TMUX_DPKG_INSTALLED=0 stub_tmux_backports_apt
  write_os_release debian bookworm
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "tmux not installed" ]]
}

@test "tmux-backports.sh: skips when the installed tmux already meets the minimum" {
  TMUX_OLD_VERSION="3.5a-1" stub_tmux_backports_apt
  write_os_release debian bookworm
  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already >= 3.4" ]]
  ! stub_called apt-get
}

@test "tmux-backports.sh: below the minimum with no VERSION_CODENAME warns and exits nonzero" {
  stub_tmux_backports_apt
  write_os_release debian
  PATH="$STUB_BIN:/usr/bin:/bin" run --separate-stderr /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -ne 0 ]
  [[ "$stderr" =~ "could not determine VERSION_CODENAME" ]]
}

@test "tmux-backports.sh: below the minimum installs from <codename>-backports" {
  stub_tmux_backports_apt
  stub_sudo_passthrough
  write_os_release debian bookworm
  sources_dir="$SANDBOX/sources.list.d"
  mkdir -p "$sources_dir"

  DOTFILES_APT_SOURCES_DIR="$sources_dir" \
    PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "upgraded tmux 3.3a-3 -> 3.5a-2~bpo12+1" ]]
  [ -f "$sources_dir/bookworm-backports.list" ]
  grep -qxF 'deb http://deb.debian.org/debian bookworm-backports main' "$sources_dir/bookworm-backports.list"
  [[ "$(stub_log)" =~ "apt-get install -y -t bookworm-backports tmux" ]]
}

@test "tmux-backports.sh: does not duplicate an existing sources.list.d entry" {
  stub_tmux_backports_apt
  stub_sudo_passthrough
  write_os_release debian bookworm
  sources_dir="$SANDBOX/sources.list.d"
  mkdir -p "$sources_dir"
  printf 'deb http://deb.debian.org/debian bookworm-backports main\n' \
    > "$sources_dir/bookworm-backports.list"
  # Stubbed as a plain logger (not a real pipe-to-file tee) so its
  # absence from the call log proves the skip branch was taken, rather
  # than being masked by tee idempotently rewriting the same line.
  stub_cmd tee

  DOTFILES_APT_SOURCES_DIR="$sources_dir" \
    PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$sources_dir/bookworm-backports.list")" -eq 1 ]
  ! stub_called tee
}

@test "tmux-backports.sh: warns and exits nonzero if the version is still too old afterward" {
  TMUX_NEW_VERSION="3.3a-3" stub_tmux_backports_apt
  stub_sudo_passthrough
  write_os_release debian bookworm
  sources_dir="$SANDBOX/sources.list.d"
  mkdir -p "$sources_dir"

  DOTFILES_APT_SOURCES_DIR="$sources_dir" \
    PATH="$STUB_BIN:/usr/bin:/bin" run --separate-stderr /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/tmux-backports.sh"
  [ "$status" -ne 0 ]
  [[ "$stderr" =~ "WARNING: tmux still 3.3a-3" ]]
}
