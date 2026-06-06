#!/bin/sh
# First-time SOPS setup for this machine.
#
# - If ~/.config/sops/age/keys.txt is missing, generates a new age
#   keypair and writes it there with mode 600.
# - If .sops.yaml at the repo root is missing, writes a minimal one
#   with the machine's public key as the only recipient.
#
# Re-running on a configured machine is safe and does nothing.
#
# For multi-machine setups, the simplest path is to copy
# ~/.config/sops/age/keys.txt to every machine (single shared key,
# .sops.yaml has one recipient). For per-machine keys, see the
# Secrets section of README.md.

set -eu

PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
AGE_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age
AGE_KEY_FILE=$AGE_DIR/keys.txt
SOPS_YAML=$PRIVATE_DIR/.sops.yaml

log() { printf '[sops-init] %s\n' "$*"; }

if ! command -v age-keygen >/dev/null 2>&1; then
  printf 'error: age-keygen not found; install age first\n' >&2
  exit 1
fi
if ! command -v sops >/dev/null 2>&1; then
  printf 'error: sops not found; install sops first\n' >&2
  exit 1
fi

if [ -r "$AGE_KEY_FILE" ]; then
  log "age key already at $AGE_KEY_FILE"
else
  log "generating new age keypair at $AGE_KEY_FILE"
  mkdir -p "$AGE_DIR"
  chmod 700 "$AGE_DIR"
  umask 077
  age-keygen -o "$AGE_KEY_FILE"
  chmod 600 "$AGE_KEY_FILE"
fi

# Extract public key from the keyfile.
PUB_KEY=$(awk '/^# public key:/ { print $NF; exit }' "$AGE_KEY_FILE")
if [ -z "$PUB_KEY" ]; then
  printf 'error: could not read public key from %s\n' "$AGE_KEY_FILE" >&2
  exit 1
fi
log "public key: $PUB_KEY"

if [ -e "$SOPS_YAML" ]; then
  log ".sops.yaml already exists; not overwriting"
  log "to add this machine's key, edit .sops.yaml manually then run:"
  log "  find ~/.private/secrets -name '*.enc' -exec sops updatekeys {} \\;"
else
  log "writing $SOPS_YAML with this key as recipient"
  mkdir -p "$PRIVATE_DIR"
  cat > "$SOPS_YAML" <<EOF
creation_rules:
  - path_regex: secrets/.*\\.enc\$
    age: $PUB_KEY
EOF
fi

cat <<EOF

[sops-init] done. next steps:

  # add a secret to the encrypted store:
  dj secret-add ~/.ssh/id_ed25519

  # define what gets materialized where (manifest is auto-managed by secret-add):
  sops $PRIVATE_DIR/secrets/manifest.txt.enc

  # apply (decrypt to target paths):
  dj apply-secrets
EOF
