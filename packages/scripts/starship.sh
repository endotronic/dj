#!/bin/sh
# Install starship from starship.rs when it is not available in the
# distro's package repository.
set -eu
command -v starship >/dev/null 2>&1 && exit 0

printf '[starship] installing via starship.rs installer\n'
curl -sS https://starship.rs/install.sh | sudo sh -s -- --yes
