# Daily-use verbs. After install.sh, these wrap the underlying
# dot/sops/scripts machinery in discoverable commands.
#
# `just` defaults to listing recipes.

DOT_DIR := env_var_or_default("DOT_DIR", env_var("HOME") + "/.config.git")
TIER_FILE := env_var_or_default("XDG_CONFIG_HOME", env_var("HOME") + "/.config") + "/dotfiles/system-type"
SCRIPTS := justfile_directory() + "/scripts"
PRIVATE_DIR := env_var_or_default("PRIVATE_DIR", env_var("HOME") + "/.private")
SECRETS := PRIVATE_DIR + "/secrets"

default:
    @just --list

# Run the bats test suite (default: all tests). Pass a path or .bats
# file to scope, e.g. `just test tests/os-detect.bats`.
test ARGS="tests/":
    cd "{{justfile_directory()}}" && bats {{ARGS}}

# Pull latest changes and rematerialize any updated secrets.
sync:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" pull --rebase
    @just apply-secrets

# Pull, then install any newly-added packages and run their post-install hooks.
upgrade: sync install-packages postinstall

# Stage a file or directory from $HOME into the bare repo and show status.
add +PATHS:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" add {{PATHS}}
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" status

# Show the bare repo's status. Same as `dot status`.
status:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" status

# Commit currently-staged changes. Opens $EDITOR for the message.
# For one-liner messages, use `dot commit -m "your msg"` directly
# (avoids just's argument-quoting limitations).
commit:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" commit

# Push committed changes to the remote.
push:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" push

# Show unstaged changes. Same as `dot diff`.
diff:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" diff

# Install (or update) packages per the active tier.
install-packages:
    sh "{{SCRIPTS}}/install-packages.sh"

# Run post-install hooks listed in ~/.config/dj/postinstall/ (idempotent
# system-level setup beyond a plain package install: enabling a service,
# group membership, an /etc/fstab entry, etc -- see
# packages/postinstall/<name>.sh for the mechanism).
postinstall:
    sh "{{SCRIPTS}}/run-postinstall.sh"

# Persist a new system type (any identifier, e.g. desktop|server|laptop|none).
# Does not install -- the type is just a lookup key for
# ~/.config/dj/packages/types/<type>.txt.
system-type TYPE:
    #!/bin/sh
    case "{{TYPE}}" in
      none|'')
        rm -f "{{TIER_FILE}}"
        echo "system-type cleared (common-only)"
        ;;
      *[!A-Za-z0-9_-]*)
        echo "error: TYPE must contain only letters, digits, _ and -" >&2
        exit 2
        ;;
      *)
        mkdir -p "$(dirname "{{TIER_FILE}}")"
        printf '%s\n' "{{TYPE}}" > "{{TIER_FILE}}"
        echo "system-type set to {{TYPE}}; run 'just upgrade' to install its packages"
        ;;
    esac

# First-time SOPS setup: generate age key and write .sops.yaml.
sops-init:
    sh "{{SCRIPTS}}/sops-init.sh"

# Decrypt every entry in the secrets manifest to its target path.
apply-secrets:
    @if [ -x "{{SCRIPTS}}/rebuild-secrets.sh" ]; then \
      sh "{{SCRIPTS}}/rebuild-secrets.sh"; \
    else \
      echo "[just] rebuild-secrets.sh not present yet; skipping"; \
    fi

# Edit an encrypted secret in-place via sops.
secret-edit NAME:
    sops "{{SECRETS}}/{{NAME}}.enc"

# Encrypt a plaintext file, register it in the manifest, and stage both.
# dst and mode are optional; dst defaults to src path, mode to src permissions.
secret-add SRC *ARGS:
    sh "{{SCRIPTS}}/secret-add.sh" "{{SRC}}" {{ARGS}}

# Rotate the SOPS age key: generate a new keypair, re-encrypt all secrets,
# update .sops.yaml, replace keys.txt, and commit. Prints a reminder to
# distribute the new private key out-of-band.
rotate:
    sh "{{SCRIPTS}}/rotate-key.sh"

# Re-encrypt ~/.claude/.credentials.json into the secret store.
# Run after `claude login` or whenever the on-disk credentials change.
# Does NOT commit/push -- prints next steps.
claude-creds-snapshot:
    sh "{{SCRIPTS}}/claude-creds-snapshot.sh"

# Launch Claude Code in the dotfiles project context. Runs from
# ~/.dotfiles -- the operational root, which carries CLAUDE.md and
# .claude/skills/ and where the bulk of the editable tooling (scripts,
# tests, Justfile, packages) lives. Claude edits the live $HOME files
# directly via the bare repo (`dot`); there is no separate dev clone.
# Args become a one-shot query via `claude -p`; no args -> interactive.
# Pass -y or --yolo (anywhere in args) to add --dangerously-skip-permissions.
# Remote Control is enabled by default; pass --no-remote-control to opt out.
# Always enables auto-mode. If -r/--resume is present, -p/--print is
# skipped (resume implies an interactive session).
alias c := claude

claude *ARGS:
    #!/bin/sh
    set -eu
    command -v claude >/dev/null 2>&1 || { echo "claude not on PATH; install Claude Code first" >&2; exit 127; }
    yolo_flag=""
    remote_flag="--remote-control"
    resuming=0
    rest=""
    for arg in {{ARGS}}; do
      case "$arg" in
        -y|--yolo)            yolo_flag="--dangerously-skip-permissions" ;;
        --no-remote-control)  remote_flag="" ;;
        -r|--resume)          resuming=1; rest="$rest $arg" ;;
        *)                    rest="$rest $arg" ;;
      esac
    done
    rest="${rest# }"
    cd "$HOME/.dotfiles"
    if [ "$resuming" -eq 1 ]; then
      claude $rest $yolo_flag $remote_flag --enable-auto-mode
    elif [ -z "$rest" ]; then
      claude $yolo_flag $remote_flag --enable-auto-mode
    else
      tmpout=$(mktemp)
      tmperr=$(mktemp)
      claude -p "$rest" $yolo_flag $remote_flag --enable-auto-mode >"$tmpout" 2>"$tmperr" &
      pid=$!
      i=0
      while kill -0 "$pid" 2>/dev/null; do
        case $((i % 4)) in
          0) s='-' ;; 1) s="\\" ;; 2) s='|' ;; 3) s='/' ;;
        esac
        printf '\r%s Thinking...' "$s" >&2
        sleep 0.1
        i=$((i + 1))
      done
      printf '\r                  \r' >&2
      wait "$pid" && rc=0 || rc=$?
      cat "$tmperr" >&2
      cat "$tmpout"
      rm -f "$tmpout" "$tmperr"
      exit "$rc"
    fi

# Audit every entry under ~/.config and classify it against the
# Omarchy default tree. Pass -q for a newline-separated track-list
# you can pipe.
audit-config *ARGS:
    sh "{{SCRIPTS}}/audit-config.sh" {{ARGS}}

# Diff a $HOME config path against the corresponding distro/Omarchy default.
config-diff PATH:
    @if [ -x "{{SCRIPTS}}/config-diff.sh" ]; then \
      sh "{{SCRIPTS}}/config-diff.sh" "{{PATH}}"; \
    else \
      echo "[just] config-diff.sh not present yet"; \
    fi

# Sanity checks: env, tool presence, key/permission checks.
doctor:
    #!/bin/sh
    set -u
    . "{{SCRIPTS}}/os-detect.sh"
    echo "DOTFILES_OS=$DOTFILES_OS"
    echo "DOTFILES_PKG=${DOTFILES_PKG:-<none>}"
    echo "DOTFILES_SYSTEM_TYPE=${DOTFILES_SYSTEM_TYPE:-<none>}"
    echo
    rc=0
    for tool in git sops age just nvim tmux starship rg fd fzf jq gh curl openssl claude; do
      if command -v "$tool" >/dev/null 2>&1; then
        printf '  ok    %s\n' "$tool"
      else
        printf '  miss  %s\n' "$tool"
        rc=1
      fi
    done
    AGE_KEY="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
    if [ -r "$AGE_KEY" ]; then
      echo "  ok    age key at $AGE_KEY"
    else
      echo "  miss  age key at $AGE_KEY (needed for secret decryption)"
    fi
    for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
      if [ -e "$k" ]; then
        mode=$(stat -c '%a' "$k" 2>/dev/null || stat -f '%Lp' "$k" 2>/dev/null)
        if [ "$mode" = 600 ]; then
          printf '  ok    %s perms=600\n' "$k"
        else
          printf '  warn  %s perms=%s (want 600)\n' "$k" "$mode"
        fi
      fi
    done
    exit $rc
