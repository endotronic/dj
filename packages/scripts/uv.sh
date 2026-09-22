#!/bin/sh
# Install uv (and uvx) from astral.sh when it is not available in the
# distro's package repository (apt; pacman and brew ship it directly).
# UV_NO_MODIFY_PATH is required: the vendor script otherwise appends a
# PATH export to shell rc files, which this repo already tracks and
# manages itself.
set -eu
command -v uv >/dev/null 2>&1 && exit 0

printf '[uv] installing via astral.sh installer\n'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -LsSf https://astral.sh/uv/install.sh \
  | env UV_INSTALL_DIR="$tmp" UV_NO_MODIFY_PATH=1 sh
sudo install -m 0755 "$tmp/uv" "$tmp/uvx" /usr/local/bin/
