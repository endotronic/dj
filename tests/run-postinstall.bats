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
