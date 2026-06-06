#!/bin/sh
# Encrypt a plaintext file into the secrets store and register it in
# the manifest. Stages both the encrypted file and the updated manifest
# via the bare-repo git alias.
#
# Usage: secret-add.sh <src> [dst] [mode]
#
#   src   plaintext file to encrypt (absolute path or ~/-prefixed)
#   dst   deploy destination (default: same path as src)
#   mode  chmod mode applied by apply-secrets (default: detected from src)
#
# After running, review with `dot status`, then:
#   dot commit -m 'secrets: add <name>' && dot push

set -eu

PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
DOT_DIR=${DOT_DIR:-$HOME/.config.git}
MANIFEST_ENC=$PRIVATE_DIR/secrets/manifest.txt.enc
MANIFEST_REL=secrets/manifest.txt.enc
AGE_KEY=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt

log() { printf '[secret-add] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ $# -lt 1 ] && { printf 'usage: secret-add.sh <src> [dst] [mode]\n' >&2; exit 1; }

src=$1
dst=${2:-}
mode_arg=${3:-}

# Expand ~ in src
case "$src" in '~/'*) src=$HOME/${src#~/} ;; esac
[ -r "$src" ] || die "source file not readable: $src"

# Normalize dst; default to src
if [ -n "$dst" ]; then
  case "$dst" in
    '~/'*)     dst=$HOME/${dst#?/} ;;  # ?/ strips ~/ without tilde-expanding the pattern
    '$HOME/'*) dst=$HOME/${dst#'$HOME/'} ;;
    /*)        : ;;
    *)         die "dst must be absolute or ~/-prefixed (got: $dst)" ;;
  esac
else
  dst=$src
fi

# Ensure dst is under $HOME
case "$dst" in
  "$HOME/"*) : ;;
  *)         die "dst must be under \$HOME (got: $dst)" ;;
esac

# Detect mode from src permissions if not given
if [ -n "$mode_arg" ]; then
  mode=$mode_arg
else
  mode=$(stat -c '%a' "$src" 2>/dev/null || stat -f '%Lp' "$src" 2>/dev/null || echo '0600')
  [ -z "$mode" ] && mode=0600
fi

# Derive relative path and encrypted output path
_rel=${dst#${HOME}/}
enc_rel=secrets/${_rel}.enc
enc_path=$PRIVATE_DIR/$enc_rel

# Prerequisites
command -v sops >/dev/null 2>&1 || die "sops not found on PATH"
[ -r "$AGE_KEY" ] || die "age key not found at $AGE_KEY; run 'dj sops-init' first"
[ -f "$PRIVATE_DIR/.sops.yaml" ] || die ".sops.yaml not found at $PRIVATE_DIR; run 'dj sops-init' first"

# Encrypt src (cd to PRIVATE_DIR so sops finds .sops.yaml via directory walk)
mkdir -p "$(dirname "$enc_path")"
( cd "$PRIVATE_DIR" && sops --encrypt --input-type binary --output-type binary \
    --filename-override "$enc_rel" /dev/stdin > "$enc_path" ) < "$src"
log "encrypted $src -> $enc_rel"

# Update or create manifest
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

new_entry=$(printf '%s  %s  %s' "$enc_rel" "~/${_rel}" "$mode")

if [ -f "$MANIFEST_ENC" ]; then
  sops -d "$MANIFEST_ENC" > "$tmp"
  if grep -qF "$enc_rel" "$tmp" 2>/dev/null; then
    log "warn: $enc_rel already in manifest; skipping manifest update"
  else
    printf '%s\n' "$new_entry" >> "$tmp"
    ( cd "$PRIVATE_DIR" && sops --encrypt --input-type binary --output-type binary \
        --filename-override "$MANIFEST_REL" /dev/stdin > "$MANIFEST_ENC" ) < "$tmp"
    log "manifest updated: $enc_rel -> ~/${_rel} ($mode)"
  fi
else
  printf '%s\n' "$new_entry" > "$tmp"
  ( cd "$PRIVATE_DIR" && sops --encrypt --input-type binary --output-type binary \
      --filename-override "$MANIFEST_REL" /dev/stdin > "$MANIFEST_ENC" ) < "$tmp"
  log "manifest created: $enc_rel -> ~/${_rel} ($mode)"
fi

# Stage both files via the bare-repo git
git --git-dir="$DOT_DIR" --work-tree="$HOME" add "$enc_path" "$MANIFEST_ENC"
log "staged. next: dot commit -m 'secrets: add ${_rel}' && dot push"
