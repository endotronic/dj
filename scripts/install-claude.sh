#!/bin/sh
# Install Claude Code via the vendor's official install script.
# Idempotent: no-op if `claude` is already on PATH. Run from install.sh
# after install-packages.sh, since Claude Code isn't shipped through
# apt/pacman/brew (only the AUR has it, and we don't depend on AUR
# helpers being present).
#
# This pipes a remote shell script to `sh`. That's the install path
# Anthropic publishes; we trust the vendor on this. The URL can be
# overridden with CLAUDE_INSTALL_URL for testing or mirroring.

set -eu

URL=${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}

log() { printf '[install-claude] %s\n' "$*"; }

if command -v claude >/dev/null 2>&1; then
  log "claude already on PATH at $(command -v claude); nothing to do"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '[install-claude] error: curl is required but not on PATH\n' >&2
  exit 1
fi

if ! command -v bash >/dev/null 2>&1; then
  printf '[install-claude] error: bash is required but not on PATH\n' >&2
  exit 1
fi

log "claude not found; installing via $URL"
curl -fsSL "$URL" | bash

# The vendor installs to ~/.local/bin, which may not yet be in PATH
# (env.sh hasn't been sourced yet on a fresh machine). Add it now so
# the verification check below can find the just-installed binary.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

if command -v claude >/dev/null 2>&1; then
  log "installed: $(command -v claude)"
else
  log "warn: vendor install ran but claude not found on PATH"
  log "  reload your shell or run: . ~/.bashrc"
fi
