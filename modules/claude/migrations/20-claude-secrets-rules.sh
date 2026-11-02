#!/bin/sh
# Migration: claude-secrets-rules
#
# Claude Code reads permissions and hooks from ~/.claude/settings.json --
# untracked machine state it rewrites itself, same problem as the status
# line (claude-statusline), so this merges the three keys that keep
# materialized plaintext secrets out of a model's context:
#
#   permissions.deny  -- Read/Edit denial rules for every path where
#                        apply-secrets materializes plaintext (the secrets
#                        manifest's destinations), the age key, Claude Code's
#                        own credential, and SSH private keys. A deny
#                        rule beats any allow, including a project's
#                        Read(~/**).
#   hooks.PreToolUse  -- the module's secrets-gate.sh, because deny
#                        rules gate the Read/Edit tools only and cannot
#                        say "any Bash command that touches these
#                        paths". The gate also blocks sops/age
#                        decryptors run as tool calls.
#   env               -- DOTFILES_SKIP_SECRETS=1, so nested shells that
#                        source shell/secrets.sh inside a session don't
#                        (re)load secret values even unexported
#                        . The files stay the on-disk truth; the
#                        launchers and recipes that need values read
#                        them by path, which neither the env nor a
#                        model's context ever sees.
#
# N/A without claude on PATH (nothing to gate) or without the gate
# script. All three merges are idempotent; existing keys are preserved.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

claude_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

desc() { echo "Claude Code's settings.json denies and gates plaintext secret paths"; }

# The gate ships beside this migration, in the claude module.
gate_script() { printf '%s/secrets-gate.sh' "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"; }
secrets_gate_cmd() { printf 'sh %s' "$(gate_script)"; }

# One rule per line; both check and fix read this, so they can't drift.
secrets_deny_patterns() {
  _h=${HOME#/}
  _c=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  _c=${_c#/}
  printf '%s\n' \
    "Read(//$_h/.secrets/**)" \
    "Edit(//$_h/.secrets/**)" \
    "Read(//$_h/.private/**)" \
    "Edit(//$_h/.private/**)" \
    "Read(//$_h/.config/sops/**)" \
    "Edit(//$_h/.config/sops/**)" \
    "Read(//$_c/.credentials.json)" \
    "Edit(//$_c/.credentials.json)" \
    "Read(//$_h/.ssh/id_*)" \
    "Read(//$_h/.ssh/*id_*)" \
    "Edit(//$_h/.ssh/id_*)" \
    "Edit(//$_h/.ssh/*id_*)" \
    "Read(//$_h/.aws/**)" \
    "Read(//$_h/.gnupg/**)" \
    "Read(//$_h/.netrc)" \
    "Edit(//$_h/.netrc)"
  # Plaintext an app keeps elsewhere, listed by the user (same file the
  # gate reads): one home-relative path or glob per line.
  _paths=${DOTFILES_DJ_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dj}/claude/secret-paths.txt
  if [ -r "$_paths" ]; then
    awk 'NF && $1 !~ /^#/ { sub(/^~\//, "", $1); print $1 }' "$_paths" \
      | while IFS= read -r _p; do
          printf '%s\n' "Read(//$_h/$_p)" "Edit(//$_h/$_p)"
        done
  fi
}

check() {
  [ -f "$(gate_script)" ] || return 2
  command -v claude >/dev/null 2>&1 || return 2
  _sf="$(claude_dir)/settings.json"
  [ -r "$_sf" ] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    printf 'claude-secrets-rules: jq is required to inspect %s\n' "$_sf" >&2
    return 1
  fi
  jq -e '.env.DOTFILES_SKIP_SECRETS == "1"' "$_sf" >/dev/null 2>&1 || return 1
  # The registered command must be THIS gate, exactly: an entry left from
  # an older layout (a moved checkout, the gate's old path) names a file
  # that no longer exists, and Claude Code treats a hook it can't run as a
  # non-blocking error -- the gate would be silently off.
  jq -e --arg gate "$(secrets_gate_cmd)" '[.hooks.PreToolUse[]?.hooks[]?.command // empty]
         | any(. == $gate)' "$_sf" >/dev/null 2>&1 || return 1
  secrets_deny_patterns | while IFS= read -r _p; do
    jq -e --arg p "$_p" '(.permissions.deny // []) | index($p) != null' \
      "$_sf" >/dev/null 2>&1 || exit 1
  done || return 1
  return 0
}

fix() {
  _gate=$(secrets_gate_cmd)
  [ -f "$(gate_script)" ] || {
    printf 'claude-secrets-rules: %s not found\n' "$(gate_script)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'claude-secrets-rules: jq is required to merge into %s\n' \
      "$(claude_dir)/settings.json" >&2
    return 1
  }
  _sd=$(claude_dir)
  _sf="$_sd/settings.json"
  mkdir -p "$_sd"
  [ -s "$_sf" ] || printf '{}\n' > "$_sf"
  _denys=$(secrets_deny_patterns | jq -R -s 'split("\n") | map(select(length > 0))')
  _tmp="$_sf.secrets-rules.$$"
  if jq --arg gate "$_gate" --argjson denys "$_denys" '
      .permissions //= {}
      | .permissions.deny = (((.permissions.deny // []) + $denys) | unique)
      | .env = ((.env // {}) + {DOTFILES_SKIP_SECRETS: "1"})
      | .hooks //= {}
      | .hooks.PreToolUse = (
          # Drop any other secrets-gate registration (a stale path), and
          # any hook group that leaves empty; other hooks are untouched.
          ((.hooks.PreToolUse // [])
            | map(if any(.hooks[]?; ((.command // "") | test("secrets-gate")) and .command != $gate)
                  then .hooks |= map(select((((.command // "") | test("secrets-gate")) | not)
                                            or .command == $gate))
                  else . end)
            | map(select((.hooks // [1]) | length > 0))) as $pt
          | if any($pt[]?; any(.hooks[]?; .command == $gate))
            then $pt
            else $pt + [{matcher: "Bash",
                         hooks: [{type: "command", command: $gate}]}]
            end )
    ' "$_sf" > "$_tmp"; then
    mv "$_tmp" "$_sf"
  else
    rm -f "$_tmp"
    return 1
  fi
}

migration_main "$@"
