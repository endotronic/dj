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

# --- packages/postinstall/zfs-vdev-textfile-collector.sh --------------------

# Stubs `zpool` to serve canned output for `list -H -o name`,
# `status -P <pool>` and `status <pool>`, keyed by files this writes
# under $SANDBOX. `write_zpool_stub POOL CONFIG_TEXT SCAN_LINE`
# (re)registers one pool; call it more than once to model a
# multi-pool host.
write_zpool_stub() {
  local pool="$1" config="$2" scan="$3"
  printf '%s\n' "$pool" >> "$SANDBOX/zpool-pools.txt"
  cat <<EOF > "$SANDBOX/zpool-status-P-$pool.txt"
config:
$config
errors: No known data errors
EOF
  cat <<EOF > "$SANDBOX/zpool-status-$pool.txt"
  pool: $pool
 state: ONLINE
  scan: $scan
config:
$config
errors: No known data errors
EOF

  cat > "$STUB_BIN/zpool" <<EOF
#!/bin/sh
if [ "\$1" = "list" ]; then
  cat "$SANDBOX/zpool-pools.txt"
  exit 0
fi
if [ "\$1" = "status" ] && [ "\$2" = "-P" ]; then
  cat "$SANDBOX/zpool-status-P-\$3.txt" 2>/dev/null
  exit 0
fi
if [ "\$1" = "status" ]; then
  cat "$SANDBOX/zpool-status-\$2.txt" 2>/dev/null
  exit 0
fi
exit 1
EOF
  chmod +x "$STUB_BIN/zpool"
}

zfs_config_ok() {
  cat <<'EOF'

	NAME                                    STATE     READ WRITE CKSUM
	tank                                    ONLINE       0     0     0
	  raidz2-0                              ONLINE       0     0     0
	    /dev/disk/by-id/ata-DISK1-part1     ONLINE       0     0     0
	    /dev/disk/by-id/ata-DISK2-part1     ONLINE       0     0     2
EOF
}

@test "zfs-vdev-textfile-collector.sh: skips when zpool is not on PATH" {
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-vdev-textfile-collector.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "zpool not found" ]]
}

@test "zfs-vdev-textfile-collector.sh: emits per-vdev errors, scrub state, and last-completed scrub" {
  write_zpool_stub tank "$(zfs_config_ok)" \
    'scrub repaired 0B in 00:19:25 with 0 errors on Sun Sep 13 00:43:33 2026'
  textfile_dir="$SANDBOX/textfile"
  state_dir="$SANDBOX/state"
  mkdir -p "$textfile_dir"

  DOTFILES_TEXTFILE_COLLECTOR_DIR="$textfile_dir" DOTFILES_ZFS_SCRUB_STATE_DIR="$state_dir" \
    PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-vdev-textfile-collector.sh"
  [ "$status" -eq 0 ]

  out="$textfile_dir/zfs_vdev.prom"
  [ -f "$out" ]
  grep -qF 'zfs_vdev_read_errors{zpool="tank",vdev="/dev/disk/by-id/ata-DISK1-part1"} 0' "$out"
  grep -qF 'zfs_vdev_cksum_errors{zpool="tank",vdev="/dev/disk/by-id/ata-DISK2-part1"} 2' "$out"
  grep -qF 'zfs_scrub_state{zpool="tank"} 2' "$out"
  grep -qF 'zfs_last_scrub_errors{zpool="tank"} 0' "$out"
  expected_epoch=$(date -d 'Sun Sep 13 00:43:33 2026' +%s)
  grep -qF "zfs_last_scrub_completed_seconds{zpool=\"tank\"} $expected_epoch" "$out"
}

@test "zfs-vdev-textfile-collector.sh: keeps last completed scrub time when the current scan was canceled" {
  textfile_dir="$SANDBOX/textfile"
  state_dir="$SANDBOX/state"
  mkdir -p "$textfile_dir"

  write_zpool_stub tank "$(zfs_config_ok)" \
    'scrub repaired 0B in 00:19:25 with 0 errors on Sun Sep 13 00:43:33 2026'
  DOTFILES_TEXTFILE_COLLECTOR_DIR="$textfile_dir" DOTFILES_ZFS_SCRUB_STATE_DIR="$state_dir" \
    PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-vdev-textfile-collector.sh"
  [ "$status" -eq 0 ]
  expected_epoch=$(date -d 'Sun Sep 13 00:43:33 2026' +%s)

  # Second run: the pool's most recent scan is now a cancel, with no
  # completion timestamp of its own -- the cached one from the first
  # run must still show up.
  rm -f "$SANDBOX/zpool-pools.txt"
  write_zpool_stub tank "$(zfs_config_ok)" \
    'scrub canceled on Tue Sep 15 10:11:14 2026'
  DOTFILES_TEXTFILE_COLLECTOR_DIR="$textfile_dir" DOTFILES_ZFS_SCRUB_STATE_DIR="$state_dir" \
    PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-vdev-textfile-collector.sh"
  [ "$status" -eq 0 ]

  out="$textfile_dir/zfs_vdev.prom"
  grep -qF 'zfs_scrub_state{zpool="tank"} 3' "$out"
  grep -qF "zfs_last_scrub_completed_seconds{zpool=\"tank\"} $expected_epoch" "$out"
}

@test "zfs-vdev-textfile-collector.sh: skips a config line with a trailing annotation instead of misparsing it" {
  textfile_dir="$SANDBOX/textfile"
  mkdir -p "$textfile_dir"
  config=$(cat <<'EOF'

	NAME                                    STATE     READ WRITE CKSUM
	tank                                    ONLINE       0     0     0
	  raidz2-0                              ONLINE       0     0     0
	    /dev/disk/by-id/ata-DISK1-part1     ONLINE       0     0     0  (resilvering)
EOF
)
  write_zpool_stub tank "$config" 'resilver in progress since Mon Sep 14 00:00:00 2026'

  DOTFILES_TEXTFILE_COLLECTOR_DIR="$textfile_dir" DOTFILES_ZFS_SCRUB_STATE_DIR="$SANDBOX/state" \
    PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-vdev-textfile-collector.sh"
  [ "$status" -eq 0 ]

  out="$textfile_dir/zfs_vdev.prom"
  ! grep -q 'vdev="/dev/disk/by-id/ata-DISK1-part1"' "$out"
  grep -qF 'zfs_scrub_state{zpool="tank"} 4' "$out"
}

# --- packages/postinstall/zfs-textfile-collector.sh --------------------------

@test "zfs-textfile-collector.sh: exits 0 when zpool is not on PATH" {
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-textfile-collector.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "zpool not found" ]]
}

@test "zfs-textfile-collector.sh: exits 0 when systemctl is not on PATH" {
  stub_cmd zpool
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-textfile-collector.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "systemctl not found" ]]
}

@test "zfs-textfile-collector.sh: deploys the collector script and enables the timer" {
  stub_cmd zpool
  stub_cmd systemctl
  stub_sudo_passthrough

  bin_dest="$SANDBOX/usr-local-bin/zfs-vdev-textfile-collector.sh"
  unit_dir="$SANDBOX/systemd-units"
  textfile_dir="$SANDBOX/textfile"
  mkdir -p "$unit_dir" "$textfile_dir"

  DOTFILES_ZFS_COLLECTOR_BIN="$bin_dest" DOTFILES_SYSTEMD_UNIT_DIR="$unit_dir" \
    DOTFILES_TEXTFILE_COLLECTOR_DIR="$textfile_dir" \
    PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$DOTFILES_REPO_ROOT/packages/postinstall/zfs-textfile-collector.sh"
  [ "$status" -eq 0 ]

  [ -x "$bin_dest" ]
  grep -qF "$bin_dest" "$unit_dir/zfs-vdev-textfile-collector.service"
  grep -qF "DOTFILES_TEXTFILE_COLLECTOR_DIR=$textfile_dir" "$unit_dir/zfs-vdev-textfile-collector.service"
  [ -f "$unit_dir/zfs-vdev-textfile-collector.timer" ]
  [[ "$(stub_log)" =~ "systemctl daemon-reload" ]]
  [[ "$(stub_log)" =~ "systemctl enable --now zfs-vdev-textfile-collector.timer" ]]
}

# --- packages/postinstall/node-exporter-upstream.sh -------------------------

NE_HOOK() { printf '%s' "$DOTFILES_REPO_ROOT/packages/postinstall/node-exporter-upstream.sh"; }

# Upstream's asset naming is arch-specific; mirror the hook's own mapping
# so these tests run on whatever machine they're invoked from.
ne_arch() {
  case "$(uname -m)" in
    x86_64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l) printf 'armv7' ;;
    *) printf 'amd64' ;;
  esac
}

# Write a fake node_exporter at $1 reporting version $2, shaped like the
# real `--version` banner the hook parses.
write_fake_ne() {
  cat > "$1" <<EOF
#!/bin/sh
printf 'node_exporter, version %s (branch: HEAD, revision: abc)\n' "$2"
EOF
  chmod +x "$1"
}

# Stub curl so that `-o <path> <url>` produces a real .tar.gz laid out
# exactly as upstream ships it, with a fake binary inside reporting
# $NE_DL_VERSION. Lets the extract/install path run for real.
stub_ne_curl() {
  : "${NE_DL_VERSION:=1.9.1}"
  cat > "$STUB_BIN/curl" <<EOF
#!/bin/sh
{ printf 'curl'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
out=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac
done
[ -n "\$out" ] || exit 0
d="\$(mktemp -d)"
dir="node_exporter-${NE_DL_VERSION}.linux-$(ne_arch)"
mkdir -p "\$d/\$dir"
cat > "\$d/\$dir/node_exporter" <<INNER
#!/bin/sh
printf 'node_exporter, version %s (branch: HEAD)\n' "${NE_DL_VERSION}"
INNER
chmod +x "\$d/\$dir/node_exporter"
tar -czf "\$out" -C "\$d" "\$dir"
rm -rf "\$d"
EOF
  chmod +x "$STUB_BIN/curl"
}

# Common sandbox wiring: old packaged binary, sandboxed bin/drop-in dirs.
ne_setup_env() {
  NE_BIN_DIR="$SANDBOX/ne-bin"
  NE_DROPIN_DIR="$SANDBOX/ne-dropin"
  NE_PACKAGED="$SANDBOX/packaged-node-exporter"
  mkdir -p "$NE_BIN_DIR" "$NE_DROPIN_DIR"
  write_fake_ne "$NE_PACKAGED" "${NE_PACKAGED_VERSION:-1.3.1}"
  export DOTFILES_NE_BIN_DIR="$NE_BIN_DIR"
  export DOTFILES_NE_DROPIN_DIR="$NE_DROPIN_DIR"
  export DOTFILES_NE_PACKAGED_BIN="$NE_PACKAGED"
  export DOTFILES_NE_TEXTFILE_DIR="$SANDBOX/textfile"
  export DOTFILES_NE_UNIT="fake-node-exporter.service"
  export DOTFILES_NE_VERSION="${NE_DL_VERSION:-1.9.1}"
  # Empty fake sysfs by default, so the host's own CPUs never leak in.
  mkdir -p "$SANDBOX/cpu-sysfs"
  export DOTFILES_NE_CPU_SYSFS="$SANDBOX/cpu-sysfs"
  # Debian's /etc/default file, present unless a test removes it.
  : > "$SANDBOX/ne-defaults"
  export DOTFILES_NE_DEFAULTS_FILE="$SANDBOX/ne-defaults"
}

# Give the fake sysfs a cpu with cpuinfo_avg_freq.
ne_fake_avg_freq() {
  mkdir -p "$SANDBOX/cpu-sysfs/cpu0/cpufreq"
  : > "$SANDBOX/cpu-sysfs/cpu0/cpufreq/cpuinfo_avg_freq"
}

@test "node-exporter-upstream.sh: skips when systemd is absent" {
  ne_setup_env
  PATH="$STUB_BIN" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no systemd" ]]
}

@test "node-exporter-upstream.sh: skips when the distro package is not installed" {
  ne_setup_env
  rm -f "$NE_PACKAGED"
  stub_cmd systemctl
  PATH="$STUB_BIN" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "skipping" ]]
}

@test "node-exporter-upstream.sh: leaves a new-enough packaged binary alone" {
  NE_PACKAGED_VERSION=1.9.1 ne_setup_env
  stub_cmd systemctl
  stub_sudo_passthrough
  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already >= " ]]
  [ ! -e "$NE_DROPIN_DIR/10-upstream-binary.conf" ]
}

@test "node-exporter-upstream.sh: installs upstream binary and writes the drop-in when packaged is too old" {
  ne_setup_env
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [ -x "$NE_BIN_DIR/node_exporter" ]
  dropin="$NE_DROPIN_DIR/10-upstream-binary.conf"
  [ -f "$dropin" ]
  # ExecStart must be cleared before being re-set, or systemd rejects it.
  grep -qx 'ExecStart=' "$dropin"
  grep -q "ExecStart=$NE_BIN_DIR/node_exporter --collector.textfile.directory=$SANDBOX/textfile \$ARGS" "$dropin"
}

@test "node-exporter-upstream.sh: passes the textfile directory explicitly (upstream has no Debian default)" {
  ne_setup_env
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  grep -q -- '--collector.textfile.directory=' "$NE_DROPIN_DIR/10-upstream-binary.conf"
}

@test "node-exporter-upstream.sh: reloads and restarts the unit" {
  ne_setup_env
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$(stub_log)" =~ "systemctl daemon-reload" ]]
  [[ "$(stub_log)" =~ "systemctl restart fake-node-exporter.service" ]]
}

@test "node-exporter-upstream.sh: is idempotent -- second run re-downloads nothing and rewrites nothing" {
  ne_setup_env
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  rm -f "$SANDBOX/stub.log"

  PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "skipping download" ]]
  [[ "$output" =~ "drop-in already current" ]]
  ! stub_called curl
  [[ ! "$(stub_log)" =~ "daemon-reload" ]]
}

@test "node-exporter-upstream.sh: disables cpufreq on arm64 when cpuinfo_avg_freq exists (it EAGAINs when idle)" {
  ne_setup_env
  ne_fake_avg_freq
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  DOTFILES_NE_MACHINE=aarch64 PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  grep -q "ExecStart=$NE_BIN_DIR/node_exporter --collector.textfile.directory=$SANDBOX/textfile --no-collector.cpufreq \$ARGS" \
    "$NE_DROPIN_DIR/10-upstream-binary.conf"
}

@test "node-exporter-upstream.sh: keeps cpufreq on arm64 without cpuinfo_avg_freq" {
  ne_setup_env
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  DOTFILES_NE_MACHINE=aarch64 PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  ! grep -q -- '--no-collector.cpufreq' "$NE_DROPIN_DIR/10-upstream-binary.conf"
}

@test "node-exporter-upstream.sh: keeps cpufreq on x86_64 even with cpuinfo_avg_freq" {
  ne_setup_env
  ne_fake_avg_freq
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  DOTFILES_NE_MACHINE=x86_64 PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  ! grep -q -- '--no-collector.cpufreq' "$NE_DROPIN_DIR/10-upstream-binary.conf"
}

@test "node-exporter-upstream.sh: new-enough packaged binary on arm64 with cpuinfo_avg_freq keeps the packaged binary, adds the flag" {
  NE_PACKAGED_VERSION=1.9.1 ne_setup_env
  ne_fake_avg_freq
  stub_cmd systemctl
  stub_sudo_passthrough
  stub_ne_curl
  DOTFILES_NE_MACHINE=aarch64 PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "overriding arguments only" ]]
  grep -q "ExecStart=$NE_PACKAGED --collector.textfile.directory=$SANDBOX/textfile --no-collector.cpufreq \$ARGS" \
    "$NE_DROPIN_DIR/10-upstream-binary.conf"
  ! stub_called curl
  [ ! -e "$NE_BIN_DIR/node_exporter" ]
  [[ "$(stub_log)" =~ "systemctl restart fake-node-exporter.service" ]]
}

@test "node-exporter-upstream.sh: new-enough packaged binary without Debian's defaults file is left alone, with a warning" {
  NE_PACKAGED_VERSION=1.9.1 ne_setup_env
  ne_fake_avg_freq
  rm -f "$SANDBOX/ne-defaults"
  stub_cmd systemctl
  stub_sudo_passthrough
  DOTFILES_NE_MACHINE=aarch64 PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not overriding" ]]
  [ ! -e "$NE_DROPIN_DIR/10-upstream-binary.conf" ]
}

@test "node-exporter-upstream.sh: new-enough packaged binary with the flag is idempotent" {
  NE_PACKAGED_VERSION=1.9.1 ne_setup_env
  ne_fake_avg_freq
  stub_cmd systemctl
  stub_sudo_passthrough
  DOTFILES_NE_MACHINE=aarch64 PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  rm -f "$SANDBOX/stub.log"
  DOTFILES_NE_MACHINE=aarch64 PATH="$STUB_BIN:/usr/bin:/bin" run /bin/sh "$(NE_HOOK)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "drop-in already current" ]]
  [[ ! "$(stub_log)" =~ "daemon-reload" ]]
}
