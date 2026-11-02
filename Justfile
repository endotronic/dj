# dj's daily verbs. Run through bin/dj (on PATH via the shell layer), which
# points just at this file from any directory. `dj` alone lists recipes.

# Hand arguments to recipes as real positional parameters ($1, "$@") instead
# of interpolating them into the recipe's command line. Interpolation
# re-quotes arguments as it splices them in, so by the time a recipe body
# runs the shell re-parses the text: backticks in an argument would run, a
# value containing a space would split. Recipes that take arguments read
# "$@"; {{ARGS}} is never interpolated into a command.
set positional-arguments

DOT_DIR := env_var_or_default("DOT_DIR", env_var("HOME") + "/.config.git")
TIER_FILE := env_var_or_default("XDG_CONFIG_HOME", env_var("HOME") + "/.config") + "/dotfiles/system-type"
DJ_DIR := env_var_or_default("DOTFILES_DJ_DIR", env_var_or_default("XDG_CONFIG_HOME", env_var("HOME") + "/.config") + "/dj")
SCRIPTS := justfile_directory() + "/scripts"
PRIVATE_DIR := env_var_or_default("PRIVATE_DIR", env_var("HOME") + "/.private")
SECRETS := PRIVATE_DIR + "/secrets"

default:
    @just --justfile "{{justfile()}}" --list

# Run the bats suite: this repo's tests, then your own in ~/.config/dj/tests/
# if you have any. Pass paths to run just those.
test *ARGS:
    #!/bin/sh
    set -eu
    cd "{{justfile_directory()}}"
    if [ $# -gt 0 ]; then exec bats "$@"; fi
    bats tests/
    if [ -d "{{DJ_DIR}}/tests" ]; then bats "{{DJ_DIR}}/tests/"; fi

# The pull half shared by `sync` and `upgrade`. Public repo first: the
# private lists name scripts, renames and hooks that live here, and the
# steps below should run the freshly pulled versions. That pull only ever
# warns (see sync-public.sh); the private pull is the part that must work.
# Local private commits sitting on top of upstream (e.g. from
# `dj authorized-keys`, which commits but never pushes) are pushed once
# the rebase has succeeded. The authorized-keys rebuild picks up other
# machines' keys from the pull; --no-register keeps sync from staging
# anything of this machine's own.
_pull:
    @sh "{{SCRIPTS}}/sync-public.sh"
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" pull --rebase
    @if [ -n "$(git --git-dir="{{DOT_DIR}}" rev-list '@{upstream}..HEAD' 2>/dev/null)" ]; then git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" push; fi
    @just --justfile "{{justfile()}}" apply-secrets
    @sh "{{SCRIPTS}}/authorized-keys.sh" --no-register

# What `sync` and `upgrade` close with: only what needs attention, and a
# single line when nothing does. Never fails the recipe.
_migrate-report:
    @sh "{{SCRIPTS}}/migrate.sh" --quiet || true

# Exit with a hint unless module $1 is enabled. Module recipes call this first.
_require-module NAME:
    @sh "{{SCRIPTS}}/module.sh" enabled "$1" || { echo "the '$1' module is not enabled here; enable it with: dj module enable $1" >&2; exit 2; }

# Pull both repos (code, then config), push local private commits, rematerialize secrets, report stale state.
sync: _pull _migrate-report

# Pull, then install newly listed packages and run post-install hooks.
upgrade: _pull install-packages postinstall _migrate-report

# Register this machine's SSH public key in ~/.ssh/authorized_keys.d/ and
# rebuild ~/.ssh/authorized_keys from every machine's key there. Commits the
# registration; push it for the other machines to see.
authorized-keys *ARGS:
    sh "{{SCRIPTS}}/authorized-keys.sh" "$@"

# Stage files from $HOME into the private repo (relative paths are relative to where you ran dj).
add +PATHS:
    cd "{{invocation_directory()}}" && git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" add "$@"
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" status

# The private repo's status (same as `dot status`).
status:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" status

# Commit staged private-repo changes ($EDITOR for the message).
commit:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" commit

# Push private-repo commits.
push:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" push

# Unstaged private-repo changes (same as `dot diff`).
diff:
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" diff

# Install whatever the active package lists name that isn't installed yet.
install-packages *ARGS:
    sh "{{SCRIPTS}}/install-packages.sh" "$@"

# Run the post-install hooks the active lists name.
postinstall *ARGS:
    sh "{{SCRIPTS}}/run-postinstall.sh" "$@"

# Persist this machine's system type (any identifier; `none` clears it). Doesn't install anything.
system-type TYPE:
    #!/bin/sh
    case "$1" in
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
        printf '%s\n' "$1" > "{{TIER_FILE}}"
        echo "system-type set to $1; run 'dj upgrade' to install its packages"
        ;;
    esac

# List, enable or disable opt-in modules: dj module [list|enable NAME|disable NAME].
module *ARGS:
    @sh "{{SCRIPTS}}/module.sh" "$@"

# First-time SOPS setup: generate an age key and write .sops.yaml.
sops-init:
    sh "{{SCRIPTS}}/sops-init.sh"

# Decrypt every secrets-manifest entry to its target path.
apply-secrets:
    sh "{{SCRIPTS}}/rebuild-secrets.sh"

# Edit an encrypted secret in place, e.g. `dj secret-edit env/api-keys.env`.
secret-edit NAME:
    sops "{{SECRETS}}/$1.enc"

# Encrypt a file, register it in the manifest, stage both: dj secret-add SRC [DST] [MODE].
secret-add SRC *ARGS:
    sh "{{SCRIPTS}}/secret-add.sh" "$@"

# Rotate the age key: new keypair, re-encrypt every secret, commit.
rotate:
    sh "{{SCRIPTS}}/rotate-key.sh"

# Classify each ~/.config entry against the distro's default tree (-q: just the track-list).
audit-config *ARGS:
    sh "{{SCRIPTS}}/audit-config.sh" "$@"

# Diff a config path against the distro's default for it.
config-diff PATH:
    sh "{{SCRIPTS}}/config-diff.sh" "$1"

# Sanity checks plus stale machine state; --fix applies the auto-fixable repairs.
doctor *ARGS:
    #!/bin/sh
    set -u
    . "{{SCRIPTS}}/os-detect.sh"
    echo "DOTFILES_OS=$DOTFILES_OS"
    echo "DOTFILES_PKG=${DOTFILES_PKG:-<none>}"
    echo "DOTFILES_SYSTEM_TYPE=${DOTFILES_SYSTEM_TYPE:-<none>}"
    echo "modules: $(sh "{{SCRIPTS}}/module.sh" list | awk '$2 == "on" { printf "%s ", $1 }')"
    echo
    rc=0
    # dj's own requirements. Your package lists are checked below, by the
    # pending-packages migration.
    for tool in git gpg sops age just; do
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
    keys_d="$HOME/.ssh/authorized_keys.d"
    if [ -d "$keys_d" ]; then
      n=$(find "$keys_d" -name '*.pub' 2>/dev/null | wc -l)
      printf '  ok    %s machine key(s) in authorized_keys.d\n' "$n"
      host=$(hostname -s 2>/dev/null || uname -n)
      if [ -f "$keys_d/$host.pub" ]; then
        printf '  ok    this machine (%s) is registered for cross-machine SSH\n' "$host"
      else
        printf '  warn  this machine (%s) is not registered -- run: dj authorized-keys\n' "$host"
        rc=1
      fi
    else
      printf '  miss  %s -- run: dj authorized-keys\n' "$keys_d"
      rc=1
    fi
    for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_githost"; do
      if [ -e "$k" ]; then
        mode=$(stat -c '%a' "$k" 2>/dev/null || stat -f '%Lp' "$k" 2>/dev/null)
        if [ "$mode" = 600 ]; then
          printf '  ok    %s perms=600\n' "$k"
        else
          printf '  warn  %s perms=%s (want 600)\n' "$k" "$mode"
        fi
      fi
    done
    echo
    echo "-- machine state (migrations) --"
    sh "{{SCRIPTS}}/migrate.sh" "$@" || rc=1
    exit $rc

# Report -- and with --fix, repair -- machine state newer code expects (--list, --only ID).
migrate *ARGS:
    @sh "{{SCRIPTS}}/migrate.sh" "$@"
