#!/bin/sh
# Install the Google Gemini CLI via npm.
# Idempotent: no-op if `gemini` is already on PATH. Run from install.sh
# after install-packages.sh. Gemini CLI is not shipped through
# apt/pacman/brew, so npm is the documented install path.
#
# Returns non-zero if installation cannot proceed (npm missing) or fails.
# install.sh calls this with error-suppression so a failure here does
# NOT abort the overall bootstrap — it only emits a warning.

set -eu

log() { printf '[install-gemini] %s\n' "$*"; }

if command -v gemini >/dev/null 2>&1; then
  log "gemini already on PATH at $(command -v gemini); nothing to do"
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  printf '[install-gemini] warn: npm not found; skipping gemini install\n' >&2
  printf '[install-gemini] warn: install Node.js/npm, then run: npm install -g @google/gemini-cli\n' >&2
  exit 1
fi

log "gemini not found; installing via npm"
sudo npm install -g @google/gemini-cli

if command -v gemini >/dev/null 2>&1; then
  log "installed: $(command -v gemini)"
else
  log "warn: npm install ran but gemini not found on PATH"
  log "  reload your shell or run: npm install -g @google/gemini-cli"
fi
