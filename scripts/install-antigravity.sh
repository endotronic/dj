#!/bin/sh
# Install Antigravity CLI via the vendor's official install script.
# Idempotent: no-op if `agy` is already on PATH. Run from install.sh
# after install-packages.sh, since Antigravity CLI isn't shipped
# through apt/pacman/brew (single compiled binary, vendor-distributed).
#
# This pipes a remote shell script to `bash`. That's the install path
# Google publishes; we trust the vendor on this. The URL can be
# overridden with ANTIGRAVITY_INSTALL_URL for testing or mirroring.

set -eu

URL=${ANTIGRAVITY_INSTALL_URL:-https://antigravity.google/cli/install.sh}

log() { printf '[install-antigravity] %s\n' "$*"; }

if command -v agy >/dev/null 2>&1; then
  log "agy already on PATH at $(command -v agy); nothing to do"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '[install-antigravity] error: curl is required but not on PATH\n' >&2
  exit 1
fi

if ! command -v bash >/dev/null 2>&1; then
  printf '[install-antigravity] error: bash is required but not on PATH\n' >&2
  exit 1
fi

log "agy not found; installing via $URL"
curl -fsSL "$URL" | bash

# The vendor installs to ~/.local/bin, which may not yet be in PATH
# (env.sh hasn't been sourced yet on a fresh machine). Add it now so
# the verification check below can find the just-installed binary.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

if command -v agy >/dev/null 2>&1; then
  log "installed: $(command -v agy)"
else
  log "warn: vendor install ran but agy not found on PATH"
  log "  reload your shell or run: . ~/.bashrc"
fi
