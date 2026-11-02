#!/bin/sh
# First run for someone with no private repo yet: lay out the private
# config dj reads, stage it, and say how to publish it.
#
# Usage: init.sh [--remote URL] [--commit]
#
#   --remote URL  set the private repo's origin (an empty private repo you
#                 created on your git host)
#   --commit      commit what was staged ("Initial dj config")
#
# Run after install.sh without --private-repo, which leaves an empty bare
# repo at ~/.config.git. Creates only what's missing:
#
#   ~/.config/dj/packages/common.txt    from packages/template/common.txt
#   ~/.config/dj/postinstall/common.txt empty, with a comment
#   ~/.config/dj/modules.txt            empty, with a comment
#   ~/.private/.sops.yaml               via sops-init.sh, when sops/age exist
#
# and stages them, plus the shell layer and this machine's
# authorized_keys.d entry when present. Nothing is pushed.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
DJ_DIR=${DOTFILES_DJ_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dj}

REMOTE=
COMMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remote)   shift; REMOTE=${1:?--remote needs a URL} ;;
    --remote=*) REMOTE=${1#*=} ;;
    --commit)   COMMIT=1 ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '[init] %s\n' "$*"; }
dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

if [ ! -d "$DOT_DIR" ]; then
  log "no private repo at $DOT_DIR -- run install.sh first"
  exit 1
fi

# Only for a repo with no history: one that already has commits came from
# somewhere, and its layout is its owner's business.
if dot rev-parse --verify -q HEAD >/dev/null 2>&1; then
  log "the private repo already has commits; nothing to initialize"
  exit 0
fi

seed() {  # seed PATH CONTENT-SOURCE(file or -)
  [ -e "$1" ] && return 0
  mkdir -p "$(dirname "$1")"
  if [ "$2" = - ]; then cat > "$1"; else cp "$2" "$1"; fi
  log "created ${1#"$HOME"/}"
}

seed "$DJ_DIR/packages/common.txt" "$repo_root/packages/template/common.txt"
seed "$DJ_DIR/postinstall/common.txt" - <<'EOF'
# Post-install hooks to run on every machine, one name per line.
# A name runs packages/postinstall/<name>.sh from dj, or <name>.sh in
# this directory for one of your own.
EOF
seed "$DJ_DIR/modules.txt" - <<'EOF'
# Opt-in dj modules enabled on every machine (dj module list).
EOF

if [ ! -f "$PRIVATE_DIR/.sops.yaml" ]; then
  if command -v sops >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    PRIVATE_DIR="$PRIVATE_DIR" sh "$script_dir/sops-init.sh" >/dev/null
    log "created ${PRIVATE_DIR#"$HOME"/}/.sops.yaml (age key: ~/.config/sops/age/keys.txt -- back it up)"
  else
    log "sops/age not installed; skipping secrets setup (dj sops-init later)"
  fi
fi

for p in "$DJ_DIR" "$PRIVATE_DIR/.sops.yaml" \
         "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zprofile" \
         "$HOME/.config/shell" "$HOME/.config/bash" "$HOME/.config/zsh" \
         "$HOME/.ssh/authorized_keys.d"; do
  [ -e "$p" ] && dot add -- "$p"
done
log "staged:"
dot diff --cached --name-only | sed 's/^/  /'

if [ -n "$REMOTE" ]; then
  if dot remote get-url origin >/dev/null 2>&1; then
    dot remote set-url origin "$REMOTE"
  else
    dot remote add origin "$REMOTE"
  fi
  log "origin -> $REMOTE"
fi

if [ "$COMMIT" -eq 1 ]; then
  dot commit -q -m "Initial dj config"
  log "committed"
fi

cat <<EOF

[init] next:
EOF
[ "$COMMIT" -eq 1 ] || echo "  dot commit -m 'Initial dj config'"
dot remote get-url origin >/dev/null 2>&1 \
  || echo "  dot remote add origin <url of an empty private repo>"
cat <<'EOF'
  dot push -u origin HEAD
  dj migrate --fix        # sets up remote-tracking refs for dj sync
EOF
