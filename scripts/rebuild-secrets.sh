#!/bin/sh
# Decrypt every entry in secrets/manifest.txt.enc to its target path.
# Idempotent: re-running overwrites the target.
#
# Manifest format (one entry per non-comment, non-blank line):
#   <src>  <dst>  <mode>
# where:
#   src   = path relative to PRIVATE_DIR (must exist, SOPS-encrypted)
#   dst   = absolute path or ~/-prefixed
#   mode  = chmod mode (e.g. 0600)

set -eu

PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
MANIFEST_ENC=$PRIVATE_DIR/secrets/manifest.txt.enc
AGE_KEY=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt

log() { printf '[rebuild-secrets] %s\n' "$*"; }

if [ ! -r "$MANIFEST_ENC" ]; then
  log "no manifest at $MANIFEST_ENC; nothing to do"
  exit 0
fi

if ! command -v sops >/dev/null 2>&1; then
  printf 'error: sops not found on PATH\n' >&2
  exit 1
fi

if [ ! -r "$AGE_KEY" ]; then
  printf 'error: age key not found at %s\n' "$AGE_KEY" >&2
  printf '  transport it from another machine, or run scripts/sops-init.sh\n' >&2
  exit 1
fi

umask 077
tmp_manifest=$(mktemp)
trap 'rm -f "$tmp_manifest"' EXIT INT TERM

sops -d "$MANIFEST_ENC" > "$tmp_manifest"

n_applied=0
n_skipped=0
while IFS= read -r line || [ -n "$line" ]; do
  cleaned=$(printf '%s\n' "$line" | sed 's/#.*//' | awk '{$1=$1; print}')
  [ -z "$cleaned" ] && continue

  src=$(printf '%s\n' "$cleaned" | awk '{print $1}')
  dst_raw=$(printf '%s\n' "$cleaned" | awk '{print $2}')
  mode=$(printf '%s\n' "$cleaned" | awk '{print $3}')

  if [ -z "$src" ] || [ -z "$dst_raw" ]; then
    log "warn: skipping malformed line: $cleaned"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  case "$dst_raw" in
    '~/'*)     dst=$HOME/${dst_raw#"~/"} ;;
    '$HOME/'*) dst=$HOME/${dst_raw#'$HOME/'} ;;
    /*)        dst=$dst_raw ;;
    *)
      log "warn: dst must be absolute or ~/-prefixed (got: $dst_raw)"
      n_skipped=$((n_skipped + 1))
      continue ;;
  esac

  src_full=$PRIVATE_DIR/$src
  if [ ! -r "$src_full" ]; then
    log "warn: src not found: $src"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  mkdir -p "$(dirname "$dst")"
  sops -d "$src_full" > "$dst"
  if [ -n "$mode" ]; then
    chmod "$mode" "$dst"
  fi
  log "$src -> $dst (mode ${mode:-keep})"
  n_applied=$((n_applied + 1))
done < "$tmp_manifest"

log "applied=$n_applied skipped=$n_skipped"
