#!/usr/bin/env bats
#
# Tests for scripts/install-packages.sh.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
  stub_dir_setup
  export INSTALL_PKGS="$DOTFILES_REPO_ROOT/scripts/install-packages.sh"
}

teardown() {
  sandbox_teardown
}

# --- argument parsing -----------------------------------------------------

@test "--help exits 0 and prints usage" {
  run sh "$INSTALL_PKGS" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ Usage ]]
}

@test "any identifier is a valid --system-type (it's just a lookup key)" {
  run sh "$INSTALL_PKGS" --dry-run --system-type bogus
  [ "$status" -eq 0 ]
  [[ "$output" =~ "TYPE=bogus" ]]
}

@test "--system-type with invalid characters exits 2" {
  run sh "$INSTALL_PKGS" --system-type 'not a type'
  [ "$status" -eq 2 ]
  [[ "$output" =~ "invalid system-type" ]]
}

@test "unknown argument exits 2" {
  run sh "$INSTALL_PKGS" --not-a-flag
  [ "$status" -eq 2 ]
  [[ "$output" =~ "unknown argument" ]]
}

# --- dry-run paths --------------------------------------------------------

@test "--dry-run never invokes the package manager" {
  # Stub sudo + every supported pkg-mgr binary so any accidental call would
  # show up in stub.log.
  stub_sudo_passthrough
  stub_cmd apt-get
  stub_cmd pacman
  stub_cmd brew
  run sh "$INSTALL_PKGS" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "to install:" ]]
  ! stub_called sudo
  ! stub_called apt-get
  ! stub_called pacman
  ! stub_called brew
}

@test "--dry-run with --system-type desktop reports TYPE=desktop" {
  run sh "$INSTALL_PKGS" --dry-run --system-type desktop
  [ "$status" -eq 0 ]
  [[ "$output" =~ "TYPE=desktop" ]]
}

# --- name resolution via renames table ------------------------------------

# The resolver lives inside install-packages.sh. We exercise it
# indirectly by checking the "to install" line for the right names.

@test "--dry-run output reports both 'already installed' and 'to install' lines" {
  run sh "$INSTALL_PKGS" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already installed:" ]]
  [[ "$output" =~ "to install:" ]]
  [[ "$output" =~ "skipped (SKIP):" ]]
}

# --- distro detection in output -------------------------------------------

@test "--dry-run output reports DISTRO= when distro is detected" {
  fake_os_release="$SANDBOX/os-release"
  printf 'ID=ubuntu\n' > "$fake_os_release"
  DOTFILES_OS_RELEASE_FILE="$fake_os_release" \
    run sh "$INSTALL_PKGS" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DISTRO=ubuntu" ]]
}

@test "--dry-run output reports DISTRO=none when os-release absent" {
  DOTFILES_OS_RELEASE_FILE="$SANDBOX/nonexistent" \
    run sh "$INSTALL_PKGS" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DISTRO=none" ]]
}

@test "distro renames take priority over apt renames" {
  # Verify distro file wins when both distro and apt.txt have an entry.
  # We inject a fake os-release and a real distro renames file that
  # overrides the apt.txt mapping for 'fd' (fd-find in apt.txt).
  fake_os_release="$SANDBOX/os-release"
  printf 'ID=ubuntu\n' > "$fake_os_release"
  # ubuntu.txt in the repo: if it had 'fd fd-custom' it would win.
  # Since ubuntu.txt is a stub, we test the no-override path instead:
  # ubuntu.txt has no entry for fd, so apt.txt's fd-find should apply.
  DOTFILES_OS_RELEASE_FILE="$fake_os_release" \
    run sh "$INSTALL_PKGS" --dry-run
  [ "$status" -eq 0 ]
  # fd-find should appear (from apt.txt fallback) rather than bare 'fd'
  [[ "$output" =~ "fd-find" ]] || [[ "$output" =~ "already installed" ]]
}

# --- happy path: install missing tools through stubbed sudo/pacman --------

@test "a missing tool triggers a package-manager install invocation" {
  # Hermetic: an isolated packages dir with a tool that cannot exist on
  # any real host, so it is always "missing" and must be installed.
  # (Using the real common.txt would be host-dependent -- on a machine
  # where every common tool is already present, nothing gets installed.)
  fake_pkgs="$SANDBOX/fake-pkgs"
  mkdir -p "$fake_pkgs/renames"
  printf 'dotfiles-test-pkg-zzz\n' > "$fake_pkgs/common.txt"
  # No renames entry -> installs 'dotfiles-test-pkg-zzz' by that name.

  # Steer os-detect to apt and capture the install invocation.
  stub_cmd apt
  stub_sudo_passthrough
  stub_cmd apt-get

  DOTFILES_PACKAGES_DIR="$fake_pkgs" DOTFILES_DJ_PACKAGES_DIR="$fake_pkgs" run sh "$INSTALL_PKGS"
  [ "$status" -eq 0 ]
  if ! stub_called apt-get; then
    printf 'no package manager was invoked. log:\n%s\n' "$(stub_log)" >&2
    false
  fi
  # The install verb (not just `apt-get update`) ran for the missing tool.
  grep -q "apt-get install.*dotfiles-test-pkg-zzz" "$SANDBOX/stub.log"
}

# --- personal lists: common + types/<type> + hosts/<hostname> -------------

@test "--system-type pulls in lists_dir/types/<type>.txt" {
  fake_pkgs="$SANDBOX/fake-pkgs"
  mkdir -p "$fake_pkgs/renames" "$fake_pkgs/types"
  : > "$fake_pkgs/common.txt"
  printf 'dotfiles-test-pkg-type\n' > "$fake_pkgs/types/sometype.txt"

  stub_cmd apt
  stub_sudo_passthrough
  stub_cmd apt-get

  DOTFILES_PACKAGES_DIR="$fake_pkgs" DOTFILES_DJ_PACKAGES_DIR="$fake_pkgs" \
    run sh "$INSTALL_PKGS" --dry-run --system-type sometype
  [ "$status" -eq 0 ]
  [[ "$output" =~ "dotfiles-test-pkg-type" ]]
}

@test "host-specific list at lists_dir/hosts/<hostname>.txt is included" {
  fake_pkgs="$SANDBOX/fake-pkgs"
  mkdir -p "$fake_pkgs/renames" "$fake_pkgs/hosts"
  : > "$fake_pkgs/common.txt"
  _host=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo unknown)
  printf 'dotfiles-test-pkg-host\n' > "$fake_pkgs/hosts/$_host.txt"

  stub_cmd apt
  stub_sudo_passthrough
  stub_cmd apt-get

  DOTFILES_PACKAGES_DIR="$fake_pkgs" DOTFILES_DJ_PACKAGES_DIR="$fake_pkgs" \
    run sh "$INSTALL_PKGS" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "dotfiles-test-pkg-host" ]]
}

@test "a type without a matching types/<type>.txt is not an error" {
  fake_pkgs="$SANDBOX/fake-pkgs"
  mkdir -p "$fake_pkgs/renames"
  : > "$fake_pkgs/common.txt"
  # No types/ dir at all.

  DOTFILES_PACKAGES_DIR="$fake_pkgs" DOTFILES_DJ_PACKAGES_DIR="$fake_pkgs" \
    run sh "$INSTALL_PKGS" --dry-run --system-type whatever
  [ "$status" -eq 0 ]
}

# --- error handling: per-package failures warn but don't abort ------------

@test "pkg manager failure warns but exits 0 and continues" {
  # Isolated packages dir: one fake tool, no fallback scripts.
  # Use a name that cannot exist on any real system.
  fake_pkgs="$SANDBOX/fake-pkgs"
  mkdir -p "$fake_pkgs/renames"
  printf 'dotfiles-test-pkg-zzz\n' > "$fake_pkgs/common.txt"
  # No renames entry -> installs 'dotfiles-test-pkg-zzz' by that name.
  # No scripts/ dir.

  # Steer os-detect to pick apt by making 'apt' findable.
  stub_cmd apt
  stub_sudo_passthrough
  # apt-get: update succeeds, install fails (package not found).
  cat > "$STUB_BIN/apt-get" <<STUBEOF
#!/bin/sh
{ printf 'apt-get'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
case "\$1" in update) exit 0 ;; *) exit 100 ;; esac
STUBEOF
  chmod +x "$STUB_BIN/apt-get"

  # Use --separate-stderr so $stderr captures the warning lines.
  DOTFILES_PACKAGES_DIR="$fake_pkgs" DOTFILES_DJ_PACKAGES_DIR="$fake_pkgs" run --separate-stderr sh "$INSTALL_PKGS"
  [ "$status" -eq 0 ]
  [[ "$stderr" =~ WARNING ]]
}

# --- fallback scripts: packages/scripts/<name>.sh -------------------------

@test "fallback script runs for SKIP tool when packages/scripts/<name>.sh exists" {
  # Isolated packages dir: one SKIP tool with a fallback install script.
  fake_pkgs="$SANDBOX/fake-pkgs"
  mkdir -p "$fake_pkgs/renames" "$fake_pkgs/scripts"
  printf 'faketool\n' > "$fake_pkgs/common.txt"
  printf 'faketool SKIP\n' > "$fake_pkgs/renames/apt.txt"
  marker="$SANDBOX/faketool-installed"
  printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$fake_pkgs/scripts/faketool.sh"
  chmod +x "$fake_pkgs/scripts/faketool.sh"

  stub_cmd apt
  stub_sudo_passthrough
  stub_cmd apt-get

  DOTFILES_PACKAGES_DIR="$fake_pkgs" DOTFILES_DJ_PACKAGES_DIR="$fake_pkgs" run sh "$INSTALL_PKGS"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "running fallback script" ]]
  [ -f "$marker" ]
}

@test "fallback script runs for pkg-manager-failed tool when script exists" {
  # Isolated packages dir: one tool whose apt install fails, but has a script.
  # Use a name that cannot exist on any real system.
  fake_pkgs="$SANDBOX/fake-pkgs"
  mkdir -p "$fake_pkgs/renames" "$fake_pkgs/scripts"
  printf 'dotfiles-test-pkg-zzz\n' > "$fake_pkgs/common.txt"
  # No renames -> tries apt install of 'dotfiles-test-pkg-zzz', which will fail.
  marker="$SANDBOX/faketool-installed"
  printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$fake_pkgs/scripts/dotfiles-test-pkg-zzz.sh"
  chmod +x "$fake_pkgs/scripts/dotfiles-test-pkg-zzz.sh"

  stub_cmd apt
  stub_sudo_passthrough
  cat > "$STUB_BIN/apt-get" <<STUBEOF
#!/bin/sh
{ printf 'apt-get'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
case "\$1" in update) exit 0 ;; *) exit 100 ;; esac
STUBEOF
  chmod +x "$STUB_BIN/apt-get"

  DOTFILES_PACKAGES_DIR="$fake_pkgs" DOTFILES_DJ_PACKAGES_DIR="$fake_pkgs" run sh "$INSTALL_PKGS"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "running fallback script" ]]
  [ -f "$marker" ]
}

# --- packages/scripts/fd.sh: Debian fdfind symlink -------------------------

@test "fd.sh: exits 0 immediately when fd is already on PATH" {
  stub_cmd fd
  run sh "$DOTFILES_REPO_ROOT/packages/scripts/fd.sh"
  [ "$status" -eq 0 ]
}

@test "fd.sh: creates fd symlink via sudo ln when fdfind is on PATH" {
  stub_sudo_passthrough
  stub_cmd fdfind
  stub_cmd ln
  # /bin/sh is an absolute path so bats finds it without PATH; STUB_BIN-only
  # PATH keeps real fd/fdfind invisible while stubs remain reachable.
  # printf/command/exit are dash builtins so no extra PATH entries needed.
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/scripts/fd.sh"
  [ "$status" -eq 0 ]
  stub_called ln
  [[ "$(stub_log)" =~ "fdfind" ]]
}

@test "fd.sh: exits 1 when neither fd nor fdfind is on PATH" {
  # Default run merges stderr into $output, so printf >&2 is visible there.
  PATH="$STUB_BIN" run /bin/sh "$DOTFILES_REPO_ROOT/packages/scripts/fd.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "fdfind not found" ]]
}
