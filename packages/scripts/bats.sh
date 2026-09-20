#!/bin/sh
# Install bats-core from upstream when the distro's package is older
# than the test suite needs.
#
# Unlike the other fallback installers here, this one cannot
# short-circuit on `command -v bats`: Debian/Ubuntu DO ship a `bats`
# package, it is just stuck at 1.2.1, which predates
# `bats_require_minimum_version` (bats 1.5). A too-old bats does not
# fail the affected files -- it aborts them in setup_file, so they are
# silently never run. Hence the version check rather than a presence
# check.
set -eu

BATS_MIN_MAJOR=${BATS_MIN_MAJOR:-1}
BATS_MIN_MINOR=${BATS_MIN_MINOR:-5}
BATS_VERSION=${BATS_VERSION:-1.11.1}
BATS_INSTALL_PREFIX=${BATS_INSTALL_PREFIX:-/usr/local}
BATS_INSTALL_URL=${BATS_INSTALL_URL:-https://github.com/bats-core/bats-core/archive/refs/tags/v$BATS_VERSION.tar.gz}

# "Bats 1.2.1" / "Bats 1.11.1" -> satisfies the floor?
bats_ok() {
  _v=$(bats --version 2>/dev/null | awk '{print $2}')
  [ -n "$_v" ] || return 1
  _maj=${_v%%.*}
  _min=${_v#*.}
  _min=${_min%%.*}
  [ "$_min" = "$_v" ] && _min=0
  case "$_maj$_min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(( _maj * 100 + _min ))" -ge "$(( BATS_MIN_MAJOR * 100 + BATS_MIN_MINOR ))" ]
}

if command -v bats >/dev/null 2>&1 && bats_ok; then
  exit 0
fi

for _dep in curl tar; do
  command -v "$_dep" >/dev/null 2>&1 || {
    printf '[bats] %s is required to install bats-core\n' "$_dep" >&2
    exit 1
  }
done

printf '[bats] installing bats-core %s to %s\n' "$BATS_VERSION" "$BATS_INSTALL_PREFIX"

_tmp=$(mktemp -d)
# Leave nothing behind on failure -- this runs unattended from
# `dj migrate --fix`.
trap 'rm -rf "$_tmp"' EXIT INT TERM

curl -fsSL "$BATS_INSTALL_URL" -o "$_tmp/bats.tar.gz"
tar -xzf "$_tmp/bats.tar.gz" -C "$_tmp"

_src=$(find "$_tmp" -maxdepth 1 -type d -name 'bats-core-*' | head -1)
[ -n "$_src" ] || {
  printf '[bats] could not find extracted bats-core source in %s\n' "$_tmp" >&2
  exit 1
}

sudo "$_src/install.sh" "$BATS_INSTALL_PREFIX"

# install.sh lands in $PREFIX/bin, which may sit behind the distro copy
# in this shell's already-resolved PATH cache.
hash -r 2>/dev/null || true

if ! command -v bats >/dev/null 2>&1 || ! bats_ok; then
  printf '[bats] bats is still %s after install; is %s/bin ahead of /usr/bin on PATH?\n' \
    "$(bats --version 2>/dev/null || echo missing)" "$BATS_INSTALL_PREFIX" >&2
  exit 1
fi

printf '[bats] %s\n' "$(bats --version)"
