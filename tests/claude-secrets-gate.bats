#!/usr/bin/env bats
#
# Tests for modules/claude/secrets-gate.sh -- the Claude Code PreToolUse
# hook that keeps materialized plaintext secrets out of the model's
# context (docs/design.md). Each test feeds one tool-call JSON on stdin
# and asserts on the decision the gate prints.
#
# The gate anchors on $HOME, ~, and $HOME-style references; these tests
# run with HOME in the sandbox, so the fixture paths are the sandbox's
# own. Paths outside HOME (a bats-style $SANDBOX/other/...) must pass
# untouched -- that's how test fixtures elsewhere stay runnable.

load test_helper

setup() {
  sandbox_setup
  GATE="$DOTFILES_REPO_ROOT/modules/claude/secrets-gate.sh"
  mkdir -p "$HOME/.secrets" "$HOME/.private/secrets" "$HOME/.ssh" \
           "$HOME/.config/sops/age"
  printf 'API_TOKEN=t\n' > "$HOME/.secrets/api.env"
  printf 'ENC[]\n' > "$HOME/.private/secrets/manifest.txt.enc"
  printf 'k\n' > "$HOME/.ssh/id_ed25519"
  printf 'k pub\n' > "$HOME/.ssh/id_ed25519.pub"
  printf 'age1x\n' > "$HOME/.config/sops/age/keys.txt"
}

teardown() {
  sandbox_teardown
}

# Feed one Bash tool call through the gate.
run_gate() {
  local j
  j=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
  printf '%s' "$j" | sh "$GATE"
}

# Literal substring checks (case, not [[ == ]] -- the deny reason contains
# regex characters like * and ( that pattern matching would trip over).
denied() {
  case $output in
    *'"permissionDecision":"deny"'*) ;;
    *) printf 'gate output: %s\n' "$output" >&2; return 1 ;;
  esac
}
allowed() {
  case $output in
    *permissionDecision*) printf 'gate output: %s\n' "$output" >&2; return 1 ;;
    *) ;;
  esac
}

# --- shape 1: readers of plaintext secret paths ---

@test "gate: denies cat of a ~/.secrets file (tilde form)" {
  run run_gate 'cat ~/.secrets/api.env'
  denied
}

@test "gate: denies cat with the absolute home path" {
  run run_gate "cat $HOME/.secrets/api.env"
  denied
}

@test "gate: denies cat with a \$HOME/ reference" {
  run run_gate 'cat "$HOME/.secrets/api.env"'
  denied
}

@test "gate: denies head of the materialized GPG key under ~/.private" {
  run run_gate 'head -5 ~/.private/gpg/private-key.asc'
  denied
}

@test "gate: denies reading the age key file" {
  run run_gate 'cat ~/.config/sops/age/keys.txt'
  denied
}

@test "gate: denies reading an SSH private key" {
  run run_gate 'cat ~/.ssh/id_ed25519'
  denied
}

@test "gate: denies the shared git-host key too" {
  run run_gate 'cat ~/.ssh/id_githost'
  denied
}

@test "gate: denies a grep for a pattern inside ~/.secrets" {
  run run_gate 'grep apikey ~/.secrets/*.env'
  denied
}

@test "gate: denies a python one-liner reading the secret file" {
  run run_gate "python3 -c \"print(open('$HOME/.secrets/api.env').read())\""
  denied
}

# --- shape 1 exceptions: inert verbs and non-secrets ---

@test "gate: allows ls of the secrets directory" {
  run run_gate 'ls -la ~/.secrets/'
  allowed
}

@test "gate: allows a test -r existence check" {
  run run_gate 'test -r ~/.secrets/api.env && echo present'
  allowed
}

@test "gate: allows catting an .enc ciphertext file" {
  run run_gate 'cat ~/.private/secrets/manifest.txt.enc'
  allowed
}

@test "gate: allows catting a *.pub public key" {
  run run_gate 'cat ~/.ssh/id_ed25519.pub'
  allowed
}

@test "gate: allows ~/.ssh/config (tracked, no private material)" {
  run run_gate 'cat ~/.ssh/config'
  allowed
}

@test "gate: allows paths outside HOME (bats fixtures)" {
  run run_gate 'cat /tmp/bats-run-123/other/.secrets/api-keys.env'
  allowed
}

@test "gate: allows grepping repo code that MENTIONS .secrets paths" {
  run run_gate 'grep -rn "\.secrets/" ~/.dotfiles/scripts/'
  allowed
}

@test "gate: allows dj secret-add (registers a secret, prints nothing)" {
  run run_gate 'dj secret-add ~/.ssh/somekey'
  allowed
}

@test "gate: allows dj apply-secrets and the launchers" {
  run run_gate 'dj apply-secrets'
  allowed
  run run_gate 'sh ~/.config/dj/claude/launcher'
  allowed
}

# --- shape 2: decryptors run as the tool call ---

@test "gate: denies sops --decrypt on a secrets .enc file" {
  run run_gate 'sops --decrypt ~/.private/secrets/manifest.txt.enc'
  denied
}

@test "gate: allows sops --decrypt of the .sops.yaml canary (doctor)" {
  run run_gate 'sops --decrypt ~/.private/.sops.yaml'
  allowed
}

@test "gate: denies age -d on ciphertext" {
  run run_gate 'age -d -i ~/.config/sops/age/keys.txt file.enc'
  denied
}

@test "gate: a decryptor counts in any command position" {
  run run_gate 'bash -c "sops -d ~/.private/secrets/a.enc"'
  denied
  run run_gate 'sudo sops --decrypt ~/.private/secrets/a.enc'
  denied
  run run_gate 'x=$(sops -d ~/.private/secrets/a.enc); echo ok'
  denied
  run run_gate 'true && SOPS_AGE_KEY_FILE=k sops -d ~/.private/secrets/a.enc'
  denied
  run run_gate 'age -i ~/.config/sops/age/keys.txt -d file.enc'
  denied
}

@test "gate: merely mentioning sops or age beside .enc paths is not decrypting" {
  # The real case that tripped it: checking that committed .enc files are
  # actually SOPS-encrypted, with "sops-encrypted" in an echo.
  run run_gate 'echo "changed .enc today that are NOT sops-encrypted:"; for f in $(git log --name-only --format= -- .private | grep "\.enc$"); do git show HEAD:$f | grep -q sops || echo "SUSPECT $f"; done'
  allowed
  run run_gate 'echo "run age -d on file.enc yourself"'
  allowed
}

# --- shape 3: environment dumps ---

@test "gate: denies printenv naming a credential variable" {
  run run_gate 'printenv API_TOKEN'
  denied
}

@test "gate: denies env piped through a credential grep" {
  run run_gate 'env | grep -i api_key'
  denied
}

@test "gate: allows a plain env dump with no credential context" {
  run run_gate 'env | sort'
  allowed
}

@test "gate: allows #!/usr/bin/env shebangs (not command-position env)" {
  run run_gate 'head -1 ~/.dotfiles/scripts/migrate.sh'
  allowed
}

# Prose in a commit/PR message flows into git, not into new context --
# documenting the gate must not deny itself. These three shapes all
# regressed during development.
@test "gate: allows a commit message mentioning secrets paths and env dumps" {
  run run_gate 'git commit -m "secrets.sh: env/printenv in a tool call shows nothing; ~/.secrets values stay unexported"'
  allowed
}

@test "gate: allows a commit message naming secret paths" {
  run run_gate 'git commit -m "gate ~/.private/gpg and ~/.ssh/id_githost reads"'
  allowed
}

@test "gate: still denies cat even when a -m flag appears in the same command" {
  run run_gate 'cat ~/.secrets/api.env | git commit -m x --file -'
  denied
}

@test "gate: allows prose that merely mentions printenv mid-sentence" {
  run run_gate 'echo "printenv shows nothing after this change"'
  allowed
}

@test "gate: still denies a real printenv after a separator" {
  run run_gate 'true; printenv API_TOKEN'
  denied
}

@test "gate: allows running a command with a clean env (env -i, not a dump)" {
  run run_gate 'env -i HOME=/home/user PATH=/usr/bin bash -lc "echo done"'
  allowed
}

@test "gate: allows env NAME=value command (setting one var, not a dump)" {
  run run_gate 'env API_TOKEN=$X curl -s https://api.example'
  allowed
}

@test "gate: denies export -p filtered to credentials" {
  run run_gate 'cd /tmp && export -p | grep -i token'
  denied
}

@test "gate: allows ordinary commands" {
  run run_gate 'git status'
  allowed
  run run_gate 'dj doctor'
  allowed
}

# --- review fixes: bypasses and false positives found by running the gate
# against a corpus of real-looking commands ---

@test "gate: the word secret-add elsewhere in a command is not an exemption" {
  run run_gate 'cat ~/.secrets/api.env ; # secret-add'
  denied
  run run_gate 'grep secret-add ~/.secrets/api.env'
  denied
}

@test "gate: dj secret-add and secret-add.sh themselves stay allowed" {
  run run_gate 'dj secret-add ~/.secrets/new.env'
  allowed
  run run_gate 'sh ~/.dotfiles/scripts/secret-add.sh ~/.secrets/new.env'
  allowed
}

@test "gate: secret-add chained with a reader is not exempt" {
  run run_gate 'dj secret-add ~/.secrets/new.env && cat ~/.secrets/api.env'
  denied
}

@test "gate: a flag containing the letter m does not blank the path after it" {
  run run_gate 'cat --number "$HOME/.secrets/api.env"'
  denied
}

@test "gate: message bodies are still blanked, including the --message= form" {
  run run_gate 'git commit -m "docs: cat ~/.secrets/containers and grep it"'
  allowed
  run run_gate 'git commit --message="docs: cat ~/.secrets/x"'
  allowed
  run run_gate 'gh pr create --title "t ~/.secrets cat" --body "grep ~/.secrets/x"'
  allowed
}

@test "gate: a reader after a pipe does not count against a listing" {
  run run_gate 'ls ~/.secrets/ | grep api'
  allowed
  run run_gate 'ls -la ~/.secrets | head'
  allowed
}

@test "gate: a reader piped FROM the secret file still counts" {
  run run_gate 'cat ~/.secrets/api.env | head -1'
  denied
  run run_gate 'echo hi && cat ~/.secrets/api.env'
  denied
}

@test "gate: the directory itself counts (recursive grep, find -exec)" {
  run run_gate 'grep -r TOKEN ~/.secrets'
  denied
  run run_gate "find ~/.secrets -name '*.env' -exec cat {} \\;"
  denied
}

@test "gate: xargs pairs with a secret path anywhere in the command" {
  run run_gate 'ls ~/.secrets/*.env | xargs cat'
  denied
}

@test "gate: more readers (tac, cut, diff) and a backslash-continued path" {
  run run_gate 'tac ~/.secrets/api.env'
  denied
  run run_gate 'cut -d= -f2 ~/.secrets/api.env'
  denied
  run run_gate 'diff ~/.secrets/api.env ~/.secrets/other.env'
  denied
  run run_gate 'cat \
  ~/.secrets/api.env'
  denied
}

@test "gate: sourcing a secret file to use it (not show it) stays allowed" {
  run run_gate '. ~/.secrets/api.env; curl -H "Authorization: token $API_TOKEN" https://x.example'
  allowed
}

@test "gate: reading /proc/self/environ is an environment dump" {
  run run_gate 'cat /proc/self/environ'
  denied
}

@test "gate: set, declare -x and export filtered to credentials are dumps" {
  run run_gate 'set | grep TOKEN'
  denied
  run run_gate 'declare -x | grep SECRET'
  denied
  run run_gate 'export | grep -i token'
  denied
}

@test "gate: set -e and a bare env piped to sort are not credential dumps" {
  run run_gate 'set -e'
  allowed
  run run_gate 'env | sort'
  allowed
}

@test "gate: stays silent (allows) on malformed input" {
  run bash -c "printf '%s' 'not json at all' | sh '$GATE'"
  [ "$status" -eq 0 ]
  allowed
}

@test "gate: denies reading a path listed in secret-paths.txt" {
  mkdir -p "$HOME/.config/dj/claude"
  printf '# app tokens\n.config/someapp/token\n.config/other/**\n' > "$HOME/.config/dj/claude/secret-paths.txt"
  run run_gate 'cat ~/.config/someapp/token'
  [[ "$output" == *deny* ]]
  run run_gate 'cat ~/.config/other/sub/file.json'
  [[ "$output" == *deny* ]]
  run run_gate 'cat ~/.config/someapp/settings.toml'
  [[ "$output" != *deny* ]]
}
