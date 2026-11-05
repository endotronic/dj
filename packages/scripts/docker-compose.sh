#!/bin/sh
# Install Docker Compose v2 from Docker's GitHub releases where the package
# manager has none: Debian with Debian's own docker.io (no
# docker-compose-plugin, which only Docker's apt repository ships;
# docker-compose-v2 is Ubuntu's package; Debian's docker-compose is the
# unmaintained v1).
#
# Installed as a Docker CLI plugin, so `docker compose` works, and linked
# onto PATH so `docker-compose` does too -- the same layout
# packages/postinstall/docker-compose.sh produces for packaged plugins.
# The download is checked against the release's published SHA-256.
set -eu
command -v docker-compose >/dev/null 2>&1 && exit 0

plugin_dir=${DOTFILES_COMPOSE_PLUGIN_DIR:-/usr/local/lib/docker/cli-plugins}
bin_link=${DOTFILES_COMPOSE_SYMLINK_DEST:-/usr/local/bin/docker-compose}
releases=${DOTFILES_COMPOSE_RELEASES_URL:-https://github.com/docker/compose/releases}

case "$(uname -m)" in
  x86_64|amd64)  ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  armv7l)        ARCH=armv7 ;;
  *)
    printf '[docker-compose] unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1 ;;
esac

VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$releases/latest" \
  | sed 's|.*/releases/tag/||')
case "$VERSION" in
  v[0-9]*) ;;
  *) printf '[docker-compose] could not determine the latest release (got: %s)\n' "$VERSION" >&2
     exit 1 ;;
esac

asset="docker-compose-linux-$ARCH"
url="$releases/download/$VERSION/$asset"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '[docker-compose] installing %s (%s)\n' "$VERSION" "$ARCH"
curl -fsSL -o "$TMP/$asset" "$url"
curl -fsSL -o "$TMP/$asset.sha256" "$url.sha256"
expected=$(awk '{ print $1; exit }' "$TMP/$asset.sha256")
actual=$(sha256sum "$TMP/$asset" | awk '{ print $1 }')
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  printf '[docker-compose] checksum mismatch for %s; not installing\n' "$asset" >&2
  exit 1
fi

sudo install -d -m 0755 "$plugin_dir"
sudo install -m 0755 "$TMP/$asset" "$plugin_dir/docker-compose"
sudo ln -sf "$plugin_dir/docker-compose" "$bin_link"
printf '[docker-compose] installed %s/docker-compose, linked from %s\n' "$plugin_dir" "$bin_link"
