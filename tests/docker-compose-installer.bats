#!/usr/bin/env bats
#
# Tests for packages/scripts/docker-compose.sh. Stub curl serves a fake
# release (latest redirect, binary, .sha256) and stub sudo runs commands
# directly, so nothing leaves the sandbox.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  SCRIPT="$DOTFILES_REPO_ROOT/packages/scripts/docker-compose.sh"
  export DOTFILES_COMPOSE_PLUGIN_DIR="$SANDBOX/plugins"
  export DOTFILES_COMPOSE_SYMLINK_DEST="$SANDBOX/bin/docker-compose"
  export DOTFILES_COMPOSE_RELEASES_URL="https://example.com/docker/compose/releases"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/release"
  printf '#!/bin/sh\necho "Docker Compose version v9.9.9"\n' > "$SANDBOX/release/asset"
  export FAKE_SUM_OK=1

  # Only these tools on PATH (no real docker-compose, curl or sudo).
  for u in sh awk sed sha256sum mktemp rm cat cp install ln chmod mkdir uname printf head readlink grep; do
    p=$(command -v "$u" 2>/dev/null) && ln -sf "$p" "$STUB_BIN/$u"
  done
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
# -w url_effective on .../latest -> print the "redirected" tag URL.
out=; url=; want_eff=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -w) want_eff=1; shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$url" >> "$SANDBOX/curl.log"
case "$url" in
  */latest) [ -n "$want_eff" ] && printf '%s' "${url%/latest}/tag/v9.9.9"; exit 0 ;;
  *.sha256)
    if [ "$FAKE_SUM_OK" = 1 ]; then sum=$(sha256sum "$SANDBOX/release/asset" | awk '{print $1}')
    else sum=0000000000000000000000000000000000000000000000000000000000000000; fi
    printf '%s *docker-compose-linux-x\n' "$sum" > "$out" ;;
  *) cp "$SANDBOX/release/asset" "$out" ;;
esac
EOF
  printf '#!/bin/sh\nexec "$@"\n' > "$STUB_BIN/sudo"
  chmod +x "$STUB_BIN/curl" "$STUB_BIN/sudo"
  export PATH="$STUB_BIN"
}

teardown() {
  sandbox_teardown
}

@test "no-op when docker-compose is already on PATH" {
  stub_cmd docker-compose
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/curl.log" ]
  [ ! -e "$DOTFILES_COMPOSE_PLUGIN_DIR/docker-compose" ]
}

@test "installs the latest release as a CLI plugin and links it onto PATH" {
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -x "$DOTFILES_COMPOSE_PLUGIN_DIR/docker-compose" ]
  [ "$(readlink "$DOTFILES_COMPOSE_SYMLINK_DEST")" = "$DOTFILES_COMPOSE_PLUGIN_DIR/docker-compose" ]
  grep -q '/download/v9.9.9/docker-compose-linux-' "$SANDBOX/curl.log"
  grep -q '\.sha256$' "$SANDBOX/curl.log"
}

@test "a checksum mismatch installs nothing" {
  export FAKE_SUM_OK=0
  run sh "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$DOTFILES_COMPOSE_PLUGIN_DIR/docker-compose" ]
  [ ! -e "$DOTFILES_COMPOSE_SYMLINK_DEST" ]
}
