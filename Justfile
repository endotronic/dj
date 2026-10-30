# Daily-use verbs. After install.sh, these wrap the underlying
# dot/sops/scripts machinery in discoverable commands.
#
# `just` defaults to listing recipes.

# Hand arguments to recipes as real positional parameters ($1, "$@") instead
# of interpolating them into the recipe's command line. The default mode
# re-quotes arguments as it splices them in, so by the time a recipe body
# runs, quoting is gone and the shell re-processes the text: a prompt like
# `dj claude 'fix the `id` bug'` had its backticks executed by the recipe's
# own shell, and a flag whose value contains a space arrived glued to its
# argument. Recipes that want the old space-joined form can still interpolate
# {{ARGS}} explicitly; everything here renders identically either way.
set positional-arguments

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

# The pull half shared by `sync` and `upgrade`. Public repo first: the
# private lists name scripts, renames and hooks that live there, and the
# steps below should run the freshly pulled versions. That pull only ever
# warns (see sync-public.sh); the private pull is the part that must work.
# Once the private rebase has succeeded, any local commits sitting on top
# of upstream (e.g. `dj authorized-keys`, which commits but never pushes)
# are pushed -- a sync that only pulls makes it too easy to forget. No
# upstream, or nothing ahead of it, means nothing to push.
# The authorized-keys rebuild picks up any *other* machine's public key
# that arrived in the pull; --no-register keeps sync from staging
# anything of this machine's own in the repo as a side effect.
_pull:
    @sh "{{SCRIPTS}}/sync-public.sh"
    git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" pull --rebase
    @if [ -n "$(git --git-dir="{{DOT_DIR}}" rev-list '@{upstream}..HEAD' 2>/dev/null)" ]; then git --git-dir="{{DOT_DIR}}" --work-tree="$HOME" push; fi
    @just apply-secrets
    @sh "{{SCRIPTS}}/authorized-keys.sh" --no-register

# What `sync` and `upgrade` close with: only what needs attention, and a
# single line when nothing does. Never fails the recipe -- pending work
# is exactly what `upgrade` goes on to fix, so it must not abort there.
_migrate-report:
    @sh "{{SCRIPTS}}/migrate.sh" --quiet || true

# Pull both repos (public code, then private config), push local private commits, rematerialize secrets, report stale state.
sync: _pull _migrate-report

# Register this machine's SSH public key in ~/.ssh/authorized_keys.d/
# (tracked, so every other machine ends up trusting this one) and
# rebuild ~/.ssh/authorized_keys from every machine's key there.
# Commit and push afterward for the registration to reach the others.
authorized-keys *ARGS:
    sh "{{SCRIPTS}}/authorized-keys.sh" {{ARGS}}

# Pull, then install any newly-added packages and run their post-install hooks.
# The migration report comes last so it reflects the result, not the before.
upgrade: _pull install-packages postinstall _migrate-report

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

# Bootstrap a brand-new machine over SSH from this one: ensures a
# reachable ssh-agent with this machine's shared identity loaded, then
# forwards it to run install.sh on the target with this machine's own
# --private-repo remote and --sops (so the target fetches the age key
# back over the same forwarded connection) filled in automatically.
# Extra args (--system-type, --theme, ...) pass through to install.sh.
#
# Usage: dj setup [user@]hostname [--system-type TYPE] [--theme '#rrggbb']
setup HOSTSPEC *ARGS:
    sh "{{SCRIPTS}}/dj-setup.sh" "{{HOSTSPEC}}" {{ARGS}}

# Add this machine's own user (id -un) to an existing machine over SSH
# as root, then bootstrap this project into that account's home
# directory -- a brand-new one if the account didn't exist yet
# (distro-appropriate useradd, no /etc/skel), or the existing one in
# place (normal install.sh conflict resolution) if it did. Extra args
# (--system-type, --theme, ...) pass through to install.sh.
#
# Usage: dj setup-root hostname [--system-type TYPE] [--theme '#rrggbb']
setup-root HOSTSPEC *ARGS:
    sh "{{SCRIPTS}}/dj-setup-root.sh" "{{HOSTSPEC}}" {{ARGS}}

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
# Args become a one-shot query via `claude -p`; no args -> interactive,
# which needs a terminal (headless with no prompt explains itself rather
# than inheriting claude's confusing print-mode error). A prompt piped on
# stdin works either way.
# Pass -y or --yolo (anywhere in args) to add --dangerously-skip-permissions.
# Remote Control is OFF by default: it exists to mirror the session to
# Anthropic's bridge so another device can watch it, which defeats the
# local-only point of this launcher. Pass --remote-control to opt in (it
# also re-enables the feature-flag service, which RC needs and which this
# recipe otherwise disables). The --settings guard below keeps
# remoteControlAtStartup from re-arming it from a settings file.
# Always enables auto-mode. If -r/--resume is present, -p/--print is
# skipped (resume implies an interactive session).
# Launches through scripts/claude-local.sh, i.e. via the shared LiteLLM
# proxy (self-hosted vLLM model by default, Anthropic via /model), same
# as the `claude-local` alias. Requires ~/.config/claude-local/env and
# LITELLM_MASTER_KEY (dj apply-secrets).
alias c := claude

claude *ARGS:
    #!/bin/sh
    set -eu
    command -v claude >/dev/null 2>&1 || { echo "claude not on PATH; install Claude Code first" >&2; exit 127; }
    yolo_flag=""
    # Remote Control is off unless asked for. The --settings guard below
    # keeps a settings file's remoteControlAtStartup from arming it behind
    # this recipe's back; it's skipped when the caller passed their own
    # --settings, since only one such flag can take effect.
    rc=0
    resuming=0
    user_settings=""
    prompt=""
    # Sort the caller's arguments into three buckets: flags this recipe owns,
    # flags to hand straight to claude, and the prompt text.
    #
    # "$@" is the caller's own argv, one element per word, because of the
    # `set positional-arguments` at the top of this file. Interpolating
    # {{ARGS}} instead -- what this recipe used to do -- hands the whole line
    # to this shell to re-parse, which silently expands $HOME inside a prompt,
    # runs its backticks, and glues --settings' JSON value onto the word after
    # it. A counted rotation (POSIX has no arrays) rebuilds the pass-through
    # list with the boundaries it came in with.
    #
    # Telling a prompt from a flag's value is the one genuinely ambiguous
    # thing here: `dj claude --model opus hi` has two bare words and only one
    # is the prompt. The answer is claude's own, so this lists the flags that
    # take a value (from `claude --help`). A flag missing from the list
    # degrades to what this recipe always did -- its value read as prompt
    # text -- so staleness is a wrong prompt, never a lost one.
    n=$#
    while [ "$n" -gt 0 ]; do
      arg=$1
      shift
      n=$((n - 1))
      case "$arg" in
        -y|--yolo)
          yolo_flag="--dangerously-skip-permissions" ;;
        --remote-control)    rc=1 ;;
        --no-remote-control) rc=0 ;;
        -r|--resume)
          resuming=1 ;;
        -p|--print)
          # Added below, only when there's a prompt to go with it; -r means
          # an interactive session, where it would be wrong.
          ;;
        --settings)
          if [ "$n" -eq 0 ]; then
            echo "dj claude: --settings needs a value" >&2
            exit 2
          fi
          user_settings=$1
          shift
          n=$((n - 1))
          set -- "$@" --settings "$user_settings" ;;
        --settings=*)
          user_settings=${arg#--settings=}
          set -- "$@" --settings "$user_settings" ;;
        -*)
          # A flag this recipe doesn't know: pass it through, and if it's one
          # that takes a value, carry the value with it so the word after it
          # isn't mistaken for the prompt.
          set -- "$@" "$arg"
          case "$arg" in
            --model|--fallback-model|--agent|--agents|--effort|--name|-n|\
            --system-prompt|--append-system-prompt|--input-format|\
            --output-format|--permission-mode|--session-id|--setting-sources|\
            --debug-file|--plugin-dir|--plugin-url|--max-budget-usd|\
            --add-dir|--mcp-config|--tools|--allowedTools|--allowed-tools|\
            --disallowedTools|--disallowed-tools|--betas|--file|--json-schema)
              if [ "$n" -gt 0 ]; then
                set -- "$@" "$1"
                shift
                n=$((n - 1))
              fi ;;
          esac ;;
        *)
          prompt="$prompt $arg" ;;
      esac
    done
    prompt="${prompt# }"
    rc_settings=""
    if [ "$rc" -eq 1 ]; then
      rc_flag="--remote-control"
      # Remote Control needs feature-flag evaluation, which the launcher
      # otherwise turns off.
      gb=0
      if [ -z "$user_settings" ]; then
        rc_settings='{"remoteControlAtStartup":true}'
      fi
    else
      rc_flag=""
      gb=1
      if [ -z "$user_settings" ]; then
        rc_settings='{"remoteControlAtStartup":false}'
      fi
    fi
    launcher="{{SCRIPTS}}/claude-local.sh"
    cd "$HOME/.dotfiles"
    # "$@" now holds only the flags being passed through; put the session
    # selector in front of them, then this recipe's own flags in front of
    # that. Each `set --` keeps every word its own argument.
    if [ "$resuming" -eq 1 ]; then
      set -- -r "$@"
      [ -z "$prompt" ] || set -- "$@" "$prompt"
    elif [ -n "$prompt" ]; then
      set -- -p "$prompt" "$@"
    fi
    if [ -n "$rc_settings" ]; then
      set -- --settings "$rc_settings" "$@"
    fi
    set -- --enable-auto-mode "$@"
    [ -z "$rc_flag" ] || set -- "$rc_flag" "$@"
    [ -z "$yolo_flag" ] || set -- "$yolo_flag" "$@"
    if [ "$resuming" -eq 1 ]; then
      CLAUDE_LOCAL_DISABLE_GROWTHBOOK=$gb sh "$launcher" "$@"
    elif [ -z "$prompt" ]; then
      # No prompt means an interactive session, which needs a terminal.
      # Without one, claude silently switches to print mode and then fails
      # on the empty input with "Input must be provided either through
      # stdin or as a prompt argument when using --print" -- naming a flag
      # this recipe never passed. Say what is actually wrong instead.
      #
      # A pipe or a redirected file still falls through untouched: claude
      # reads the prompt from stdin, which is how `echo ... | dj claude`
      # works. Everything else -- a closed stdin, or /dev/null, which is
      # neither a terminal nor readable -- gets the explanation rather than
      # claude's message about a flag this recipe never sent.
      if [ -t 0 ] || [ -p /dev/stdin ] 2>/dev/null || [ -f /dev/stdin ] 2>/dev/null; then
        CLAUDE_LOCAL_DISABLE_GROWTHBOOK=$gb sh "$launcher" "$@"
      else
        echo "dj claude: no prompt given, and stdin is not a terminal to open a session in." >&2
        echo "  pass one:  dj claude \"your question\"" >&2
        echo "  or pipe it: echo \"your question\" | dj claude" >&2
        exit 2
      fi
    else
      tmpout=$(mktemp)
      tmperr=$(mktemp)
      CLAUDE_LOCAL_DISABLE_GROWTHBOOK=$gb sh "$launcher" "$@" >"$tmpout" 2>"$tmperr" &
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

# Launch opencode in the dotfiles project context -- the opencode
# counterpart of `dj claude`, same cwd and arg conventions. opencode
# reads CLAUDE.md and .claude/skills/ as fallbacks, so it gets the same
# project context. Args become a one-shot query via `opencode run`
# (streams its own output, so no spinner); no args -> TUI.
# Pass -y or --yolo (anywhere in args) to add --auto. -r/--resume maps
# to opencode's --continue; -c/--continue and -s/--session pass through.
# Any of those skips `run` (resume implies an interactive session).
alias o := opencode

opencode *ARGS:
    #!/bin/sh
    set -eu
    command -v opencode >/dev/null 2>&1 || { echo "opencode not on PATH; install opencode first" >&2; exit 127; }
    auto_flag=""
    resuming=0
    rest=""
    # Same counted rotation as the claude recipe above: "$@" holds the
    # caller's words with their boundaries, so a prompt containing $ or `
    # reaches opencode as text rather than being re-parsed here.
    n=$#
    while [ "$n" -gt 0 ]; do
      arg=$1
      shift
      n=$((n - 1))
      case "$arg" in
        -y|--yolo)              auto_flag="--auto" ;;
        -r|--resume)            resuming=1; rest="$rest --continue" ;;
        -c|--continue|-s|--session) resuming=1; rest="$rest $arg" ;;
        *)                      rest="$rest $arg" ;;
      esac
    done
    rest="${rest# }"
    cd "$HOME/.dotfiles"
    if [ "$resuming" -eq 1 ] || [ -z "$rest" ]; then
      # shellcheck disable=SC2086  # deliberate: flags assembled above
      exec opencode $rest $auto_flag
    else
      exec opencode run $auto_flag "$rest"
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

# Sanity checks: env, tool presence, key/permission checks, and
# stale machine state. Pass --fix to apply the auto-fixable repairs.
doctor *ARGS:
    #!/bin/sh
    set -u
    . "{{SCRIPTS}}/os-detect.sh"
    echo "DOTFILES_OS=$DOTFILES_OS"
    echo "DOTFILES_PKG=${DOTFILES_PKG:-<none>}"
    echo "DOTFILES_SYSTEM_TYPE=${DOTFILES_SYSTEM_TYPE:-<none>}"
    echo
    rc=0
    for tool in git sops age just nvim tmux starship rg fd fzf jq curl openssl claude; do
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
    if [ -f "{{SCRIPTS}}/migrate.sh" ]; then
      sh "{{SCRIPTS}}/migrate.sh" {{ARGS}} || rc=1
    else
      echo "  miss  migrate.sh not present"
      rc=1
    fi
    exit $rc

# Report -- and with --fix, repair -- machine state that newer versions
# of this project expect but that an older bootstrap never set up.
# `--list` shows every known migration; `--only ID` narrows to one.
migrate *ARGS:
    @sh "{{SCRIPTS}}/migrate.sh" {{ARGS}}
