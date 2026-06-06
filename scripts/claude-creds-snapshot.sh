#!/bin/sh
# Snapshot the current Claude Code credentials into the SOPS-encrypted
# secret store and register them in the secrets manifest. Run this
# whenever ~/.claude/.credentials.json changes (login, token refresh)
# and you want other machines to inherit the new tokens via `dj sync`.
#
# This script writes the encrypted file, updates manifest.txt.enc, and
# stages both. It does NOT commit/push.
# Follow up with: dot commit -m 'claude: refresh credentials snapshot' && dot push
#
# macOS note: Claude Code stores credentials in the Keychain, not in
# ~/.claude/.credentials.json. This script aborts on macOS with a
# pointer to `claude login` as the per-machine setup step.

set -eu

PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
DOT_DIR=${DOT_DIR:-$HOME/.config.git}
SRC=${CLAUDE_CREDS_SRC:-$HOME/.claude/.credentials.json}
DST_REL=secrets/claude/credentials.json.enc
DST=$PRIVATE_DIR/$DST_REL
MANIFEST_ENC=$PRIVATE_DIR/secrets/manifest.txt.enc
MANIFEST_REL=secrets/manifest.txt.enc
MANIFEST_ENTRY="$DST_REL  ~/.claude/.credentials.json  0600"

log() { printf '[claude-creds-snapshot] %s\n' "$*"; }

case "$(uname -s)" in
  Darwin)
    cat >&2 <<EOF
[claude-creds-snapshot] macOS detected: Claude Code uses the Keychain,
  not a flat credentials file. This snapshot mechanism only helps on
  Linux/WSL. On a fresh Mac, run \`claude login\` once.
EOF
    exit 1 ;;
esac

if [ ! -r "$SRC" ]; then
  cat >&2 <<EOF
[claude-creds-snapshot] no credentials file at $SRC
  Run \`claude login\` first, then re-run this script.
EOF
  exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
  printf '[claude-creds-snapshot] error: sops not on PATH\n' >&2
  exit 1
fi

if [ ! -f "$PRIVATE_DIR/.sops.yaml" ]; then
  cat >&2 <<EOF
[claude-creds-snapshot] error: $PRIVATE_DIR/.sops.yaml not found.
  Run \`dj sops-init\` first to bootstrap SOPS.
EOF
  exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

# Encrypt credentials as an opaque binary blob so rebuild-secrets.sh
# rematerializes it byte-for-byte. Encrypting from repo_root lets sops
# discover .sops.yaml via directory walk; --filename-override makes the
# creation-rule path_regex match the encrypted destination.
mkdir -p "$(dirname "$DST")"
umask 077
( cd "$PRIVATE_DIR" && sops --encrypt --input-type binary --output-type binary \
    --filename-override "$DST_REL" "$SRC" > "$DST" )
log "wrote $DST"

# Update or create manifest
if [ -f "$MANIFEST_ENC" ]; then
  sops -d "$MANIFEST_ENC" > "$tmp"
  if grep -qF "$DST_REL" "$tmp" 2>/dev/null; then
    log "manifest entry already present"
  else
    printf '%s\n' "$MANIFEST_ENTRY" >> "$tmp"
    ( cd "$PRIVATE_DIR" && sops --encrypt --input-type binary --output-type binary \
        --filename-override "$MANIFEST_REL" /dev/stdin > "$MANIFEST_ENC" ) < "$tmp"
    log "manifest updated"
  fi
else
  printf '%s\n' "$MANIFEST_ENTRY" > "$tmp"
  ( cd "$PRIVATE_DIR" && sops --encrypt --input-type binary --output-type binary \
      --filename-override "$MANIFEST_REL" /dev/stdin > "$MANIFEST_ENC" ) < "$tmp"
  log "manifest created"
fi

# Stage both files via the bare-repo git
if [ -d "$DOT_DIR" ]; then
  git --git-dir="$DOT_DIR" --work-tree="$HOME" add "$DST" "$MANIFEST_ENC"
  log "staged. next: dot commit -m 'claude: refresh credentials snapshot' && dot push"
else
  log "no bare repo at $DOT_DIR; stage manually:"
  log "  dot add ~/.private/$DST_REL"
  log "  dot add ~/.private/$MANIFEST_REL"
  log "  dot commit -m 'claude: refresh credentials snapshot' && dot push"
fi
