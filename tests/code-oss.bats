#!/usr/bin/env bats
#
# Tests for packages/scripts/code-oss.sh (the VSCodium fallback installer for
# apt and brew systems) and packages/postinstall/open-remote-ssh.sh (the
# Open Remote - SSH extension hook for code-oss / codium).
#
# PATH is swapped for a farm of symlinks to just the tools these scripts call,
# plus per-test stubs, so a host that really has codium, apt-get or brew can't
# leak into the results.

load test_helper

SCRIPT="$DOTFILES_REPO_ROOT/packages/scripts/code-oss.sh"
HOOK="$DOTFILES_REPO_ROOT/packages/postinstall/open-remote-ssh.sh"

setup() {
  sandbox_setup
  stub_dir_setup

  local farm="$SANDBOX/farm" c src
  mkdir -p "$farm"
  for c in sh awk cat chmod cmp cp dirname env grep mkdir mktemp mv rm sed tee; do
    src="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$src" ] && ln -sf "$src" "$farm/$c"
  done
  export PATH="$STUB_BIN:$farm"

  export DOTFILES_KEYRING_DIR="$SANDBOX/keyrings"
  export DOTFILES_APT_SOURCES_DIR="$SANDBOX/sources.list.d"
  mkdir -p "$DOTFILES_KEYRING_DIR" "$DOTFILES_APT_SOURCES_DIR"
  export DOTFILES_VSCODE_ARGV="$HOME/.vscode-oss/argv.json"
}

teardown() {
  sandbox_teardown
}

stub_uname() {
  printf '#!/bin/sh\n[ "$1" = -s ] && echo %s || echo %s\n' "$1" "$1" > "$STUB_BIN/uname"
  chmod +x "$STUB_BIN/uname"
}

# curl that "downloads" a key (`-o FILE`), or an empty file when asked to.
stub_curl() {
  cat > "$STUB_BIN/curl" <<STUB
#!/bin/sh
{ printf 'curl'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
while [ \$# -gt 0 ]; do
  if [ "\$1" = -o ]; then
    if [ "\${CURL_EMPTY:-0}" = 1 ]; then : > "\$2"; else printf 'PGPKEY\n' > "\$2"; fi
  fi
  shift
done
exit 0
STUB
  chmod +x "$STUB_BIN/curl"
}

stub_gpg() {
  printf '#!/bin/sh\ncat\n' > "$STUB_BIN/gpg"
  chmod +x "$STUB_BIN/gpg"
}

# --- code-oss.sh ------------------------------------------------------------

apt_env() {
  stub_uname Linux
  stub_sudo_passthrough
  stub_cmd apt-get
  stub_curl
  stub_gpg
}

@test "code-oss.sh: passes sh -n" {
  run sh -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "code-oss.sh: exits 0 without doing anything when codium is already installed" {
  apt_env
  stub_cmd codium
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  ! stub_called apt-get
  ! stub_called curl
}

@test "code-oss.sh: apt -- adds VSCodium's signed repo, then installs codium" {
  apt_env
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$DOTFILES_KEYRING_DIR/vscodium-archive-keyring.gpg" ]
  src="$DOTFILES_APT_SOURCES_DIR/vscodium.sources"
  [ -f "$src" ]
  grep -qx 'URIs: https://download.vscodium.com/debs' "$src"
  grep -qx 'Suites: vscodium' "$src"
  grep -qx "Signed-By: $DOTFILES_KEYRING_DIR/vscodium-archive-keyring.gpg" "$src"
  grep -q "apt-get update" "$SANDBOX/stub.log"
  grep -q "apt-get install -y codium" "$SANDBOX/stub.log"
}

@test "code-oss.sh: apt -- a second run does not download the key again or rewrite the source" {
  apt_env
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  cp "$DOTFILES_APT_SOURCES_DIR/vscodium.sources" "$SANDBOX/first"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl' "$SANDBOX/stub.log")" -eq 1 ]
  cmp "$DOTFILES_APT_SOURCES_DIR/vscodium.sources" "$SANDBOX/first"
}

@test "code-oss.sh: apt -- an empty key download fails cleanly and installs nothing" {
  apt_env
  CURL_EMPTY=1 run sh "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not download the VSCodium repo key"* ]]
  [ ! -e "$DOTFILES_APT_SOURCES_DIR/vscodium.sources" ]
  ! grep -q "apt-get install" "$SANDBOX/stub.log"
}

@test "code-oss.sh: macOS -- installs the vscodium cask" {
  stub_uname Darwin
  stub_cmd brew
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "brew install --cask vscodium" "$SANDBOX/stub.log"
}

@test "code-oss.sh: macOS without Homebrew fails with a message" {
  stub_uname Darwin
  run sh "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Homebrew not found"* ]]
}

@test "code-oss.sh: Linux without apt (e.g. Arch) has no install path and says so" {
  stub_uname Linux
  run sh "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Arch uses the"* ]]
}

# --- open-remote-ssh.sh -----------------------------------------------------

# An editor stub: `--list-extensions` prints $EDITOR_EXTS, `--install-extension`
# is logged (and fails when EDITOR_FAIL=1).
stub_editor() {
  cat > "$STUB_BIN/$1" <<STUB
#!/bin/sh
{ printf '%s' "$1"; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
case "\$1" in
  --list-extensions) printf '%s\n' "\${EDITOR_EXTS:-}" ;;
  --install-extension) [ "\${EDITOR_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/$1"
}

@test "open-remote-ssh.sh: passes sh -n" {
  run sh -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "open-remote-ssh.sh: skips when no editor is installed" {
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"neither code-oss nor codium is installed"* ]]
}

@test "open-remote-ssh.sh: installs the extension into codium, and leaves argv.json alone" {
  stub_editor codium
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  grep -q "codium --install-extension jeanp413.open-remote-ssh" "$SANDBOX/stub.log"
  [ ! -e "$DOTFILES_VSCODE_ARGV" ]
}

@test "open-remote-ssh.sh: does not reinstall an extension that is already there" {
  stub_editor codium
  EDITOR_EXTS='jeanp413.open-remote-ssh' run sh "$HOOK"
  [ "$status" -eq 0 ]
  ! grep -q -- "--install-extension" "$SANDBOX/stub.log"
}

@test "open-remote-ssh.sh: extension id match is case-insensitive and whole-line" {
  stub_editor codium
  EDITOR_EXTS='JeanP413.Open-Remote-SSH' run sh "$HOOK"
  ! grep -q -- "--install-extension" "$SANDBOX/stub.log"
  : > "$SANDBOX/stub.log"
  EDITOR_EXTS='someone.jeanp413.open-remote-ssh-fork' run sh "$HOOK"
  grep -q -- "--install-extension" "$SANDBOX/stub.log"
}

@test "open-remote-ssh.sh: code-oss -- creates argv.json enabling the proposed API when missing" {
  stub_editor code-oss
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  grep -q "code-oss --install-extension jeanp413.open-remote-ssh" "$SANDBOX/stub.log"
  grep -qF '"enable-proposed-api": ["jeanp413.open-remote-ssh"]' "$DOTFILES_VSCODE_ARGV"
}

@test "open-remote-ssh.sh: code-oss -- inserts the key into an existing JSONC argv.json, keeping everything else" {
  stub_editor code-oss
  mkdir -p "$(dirname "$DOTFILES_VSCODE_ARGV")"
  cat > "$DOTFILES_VSCODE_ARGV" <<'JSON'
// Runtime arguments
{
	// Enable crash reporting
	"enable-crash-reporter": false,
	"crash-reporter-id": "abc-123"
}
JSON
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  grep -qF '"enable-proposed-api": ["jeanp413.open-remote-ssh"],' "$DOTFILES_VSCODE_ARGV"
  grep -qF '// Runtime arguments' "$DOTFILES_VSCODE_ARGV"
  grep -qF '"crash-reporter-id": "abc-123"' "$DOTFILES_VSCODE_ARGV"
  [ -f "$DOTFILES_VSCODE_ARGV.dj-backup" ]
  ! grep -q enable-proposed-api "$DOTFILES_VSCODE_ARGV.dj-backup"
}

@test "open-remote-ssh.sh: code-oss -- argv.json already enabling it is left byte-for-byte alone" {
  stub_editor code-oss
  mkdir -p "$(dirname "$DOTFILES_VSCODE_ARGV")"
  printf '{\n  "enable-proposed-api": ["jeanp413.open-remote-ssh"]\n}\n' > "$DOTFILES_VSCODE_ARGV"
  cp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/before"
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  cmp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/before"
  [ ! -e "$DOTFILES_VSCODE_ARGV.dj-backup" ]
}

@test "open-remote-ssh.sh: code-oss -- an existing proposed-api list is never rewritten; says what to add" {
  stub_editor code-oss
  mkdir -p "$(dirname "$DOTFILES_VSCODE_ARGV")"
  printf '{\n  "enable-proposed-api": ["other.ext"]\n}\n' > "$DOTFILES_VSCODE_ARGV"
  cp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/before"
  run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"by hand"* ]]
  cmp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/before"
}

@test "open-remote-ssh.sh: code-oss -- an unrecognised argv.json layout is reported, not rewritten" {
  stub_editor code-oss
  mkdir -p "$(dirname "$DOTFILES_VSCODE_ARGV")"
  printf '{ "enable-crash-reporter": false }\n' > "$DOTFILES_VSCODE_ARGV"
  cp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/before"
  run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognised layout"* ]]
  cmp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/before"
}

@test "open-remote-ssh.sh: a failed install warns and exits non-zero so the next run retries" {
  stub_editor codium
  EDITOR_FAIL=1 run sh "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not install"* ]]
}

@test "open-remote-ssh.sh: running twice leaves the same argv.json" {
  stub_editor code-oss
  run sh "$HOOK"
  [ "$status" -eq 0 ]
  cp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/first"
  EDITOR_EXTS='jeanp413.open-remote-ssh' run sh "$HOOK"
  [ "$status" -eq 0 ]
  cmp "$DOTFILES_VSCODE_ARGV" "$SANDBOX/first"
}
