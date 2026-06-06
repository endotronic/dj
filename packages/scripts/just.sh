#!/bin/sh
# Install just from just.systems when it is not available in the
# distro's package repository.
set -eu
command -v just >/dev/null 2>&1 && exit 0

if ! command -v bash >/dev/null 2>&1; then
  printf '[just] bash is required for the just installer\n' >&2
  exit 1
fi

printf '[just] installing via just.systems installer\n'
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
  | sudo bash -s -- --to /usr/local/bin
