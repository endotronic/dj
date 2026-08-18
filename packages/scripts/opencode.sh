#!/bin/sh
# Install opencode from opencode.ai when it is not available in the
# distro's package repository (apt; pacman and brew ship it directly).
# --no-modify-path is required: the vendor script otherwise appends a
# PATH export to .bashrc/.zshrc, which this repo already tracks and
# manages itself.
set -eu
command -v opencode >/dev/null 2>&1 && exit 0

printf '[opencode] installing via opencode.ai installer\n'
curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
sudo install -m 0755 "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode
