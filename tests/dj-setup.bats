#!/usr/bin/env bats
#
# Tests for scripts/dj-setup.sh (`dj setup [user@]host ...`). It
# bootstraps a brand-new machine over `ssh -A -t`, filling in this
# machine's own --private-repo and --sops from local git state. ssh,
# ssh-agent, ssh-add, and ssh-keygen are all stubbed -- no real
# network or agent involved. git and the SSH key file are real (a
# throwaway repo/bare-repo under the sandboxed $HOME), since the
# remote-URL and branch derivation logic is the part worth exercising
# for real.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export SETUP="$DOTFILES_REPO_ROOT/scripts/dj-setup.sh"
  export DOT_DIR="$HOME/.config.git"
  export DOTFILES_DIR="$HOME/.dotfiles"
  mkdir -p "$HOME/.ssh"
  printf 'fake-private-key\n' > "$HOME/.ssh/id_ed25519"
}

teardown() {
  sandbox_teardown
}

# ---------- fixture builders -------------------------------------------

private_repo_with_remote() {
  remote_url=${1:-git@git.example.com:kevin/dotfiles.git}
  git init --bare -q "$DOT_DIR"
  git --git-dir="$DOT_DIR" remote add gitea "$remote_url"
}

dotfiles_repo_with_origin() {
  origin_url=$1
  branch=${2:-master}
  mkdir -p "$DOTFILES_DIR"
  git -C "$DOTFILES_DIR" init -q -b "$branch" 2>/dev/null \
    || { git -C "$DOTFILES_DIR" init -q && git -C "$DOTFILES_DIR" checkout -q -b "$branch"; }
  git -C "$DOTFILES_DIR" config user.email t@t
  git -C "$DOTFILES_DIR" config user.name t
  git -C "$DOTFILES_DIR" config commit.gpgsign false
  printf 'marker\n' > "$DOTFILES_DIR/MARKER"
  git -C "$DOTFILES_DIR" add -A
  git -C "$DOTFILES_DIR" commit -q -m init
  git -C "$DOTFILES_DIR" remote add origin "$origin_url"
}

# ssh-add -l: exit code and stdout are driven by two control files a
# test can pre-seed, defaulting to "reachable agent, no keys loaded".
stub_ssh_add() {
  printf '%s\n' "${1:-0}" > "$SANDBOX/ssh_add_list_rc"
  printf '%s' "${2:-}" > "$SANDBOX/ssh_add_list_out"
  cat > "$STUB_BIN/ssh-add" <<'EOF'
#!/bin/sh
{ printf 'ssh-add'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
if [ "$1" = "-l" ]; then
  cat "$SANDBOX/ssh_add_list_out" 2>/dev/null || true
  exit "$(cat "$SANDBOX/ssh_add_list_rc" 2>/dev/null || echo 0)"
fi
exit 0
EOF
  chmod +x "$STUB_BIN/ssh-add"
}

stub_ssh_agent() {
  cat > "$STUB_BIN/ssh-agent" <<'EOF'
#!/bin/sh
{ printf 'ssh-agent'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
printf 'SSH_AUTH_SOCK=/tmp/fake.sock; export SSH_AUTH_SOCK;\n'
EOF
  chmod +x "$STUB_BIN/ssh-agent"
}

stub_ssh_keygen() {
  cat > "$STUB_BIN/ssh-keygen" <<'EOF'
#!/bin/sh
{ printf 'ssh-keygen'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
printf '256 SHA256:FAKEFINGERPRINT test@test (ED25519)\n'
EOF
  chmod +x "$STUB_BIN/ssh-keygen"
}

# Records each argv element of the final `ssh` call on its own line in
# $SANDBOX/ssh_argv_N (1-indexed) plus the total count in
# $SANDBOX/ssh_argc -- unlike the generic space-joining stub_cmd, this
# preserves argument boundaries, which is exactly what matters here
# (the whole remote pipeline must arrive as ONE argument to ssh).
stub_ssh_records_argv() {
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/bin/sh
i=0
for a in "$@"; do
  i=$((i + 1))
  printf '%s' "$a" > "$SANDBOX/ssh_argv_$i"
done
printf '%s' "$#" > "$SANDBOX/ssh_argc"
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
}

default_stubs() {
  stub_ssh_add 0 "$1"
  stub_ssh_agent
  stub_ssh_keygen
  stub_ssh_records_argv
}

# ---------- argument / precondition errors ----------------------------

@test "no arguments prints usage and exits 2" {
  run sh "$SETUP"
  [ "$status" -eq 2 ]
  [[ "$output" =~ usage ]]
}

@test "missing SSH key exits 1" {
  rm -f "$HOME/.ssh/id_ed25519"
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 1 ]
  [[ "$output" =~ "no SSH key at" ]]
}

@test "private repo with no remote configured exits 1" {
  default_stubs
  git init --bare -q "$DOT_DIR"
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 1 ]
  [[ "$output" =~ "has no remote configured" ]]
}

# ---------- ssh-agent lifecycle -----------------------------------------

@test "starts a new ssh-agent when none is reachable" {
  stub_ssh_add 2 ""
  stub_ssh_agent
  stub_ssh_keygen
  stub_ssh_records_argv
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  stub_called ssh-agent
}

@test "does not start a new agent when one is already reachable" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  ! stub_called ssh-agent
}

@test "adds the key when the reachable agent has no keys loaded" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  grep -qx "ssh-add $HOME/.ssh/id_ed25519" "$SANDBOX/stub.log"
}

@test "does not re-add a key already loaded in the agent" {
  default_stubs "256 SHA256:FAKEFINGERPRINT test@test (ED25519)"
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  ! grep -qx "ssh-add $HOME/.ssh/id_ed25519" "$SANDBOX/stub.log"
}

# ---------- raw install.sh URL derivation -------------------------------

@test "derives the raw install URL from a git@github.com origin" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git main

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_4")
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/someuser/somerepo/main/install.sh"* ]]
}

@test "derives the raw install URL from an https://github.com origin" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin https://github.com/someuser/somerepo.git develop

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_4")
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/someuser/somerepo/develop/install.sh"* ]]
}

@test "falls back to the default raw URL for a non-github origin" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin https://gitlab.example.com/someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_4")
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/endotronic/dj/master/install.sh"* ]]
}

# ---------- private-repo / sops / ssh invocation shape ------------------

@test "ssh is invoked with -A -t, the hostspec, and exactly one remote-command argument" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" kevin@testhost
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/ssh_argc")" = 4 ]
  [ "$(cat "$SANDBOX/ssh_argv_1")" = "-A" ]
  [ "$(cat "$SANDBOX/ssh_argv_2")" = "-t" ]
  [ "$(cat "$SANDBOX/ssh_argv_3")" = "kevin@testhost" ]
}

@test "remote command includes this machine's own private-repo URL and identity" {
  default_stubs ""
  private_repo_with_remote git@git.example.com:kevin/dotfiles.git
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_4")
  [[ "$remote_cmd" == *"--private-repo 'git@git.example.com:kevin/dotfiles.git'"* ]]
  expected_user=$(id -un)
  expected_host=$(hostname -s 2>/dev/null || uname -n)
  [[ "$remote_cmd" == *"--sops '$expected_user@$expected_host'"* ]]
}

# ---------- quoting safety: the actual bug class this guards against ----

@test "extra args survive being re-parsed by a real shell, hex-color '#' included" {
  # Regression: naively string-joining args (e.g. with $*) loses their
  # original quoting, so `--theme '#2596be'` reconstructed unquoted
  # would have its value's '#' truncate the rest of the line as a
  # comment once the remote shell parses it. Verify end-to-end: run
  # the exact captured remote command through a real `sh -c` (with
  # curl and the inner install.sh's `sh -s --` replaced by stubs that
  # just dump argv) and confirm '#2596be' arrives intact.
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be'
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_4")

  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
cat <<'SCRIPT'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
SCRIPT
EOF
  chmod +x "$STUB_BIN/curl"

  run sh -c "$remote_cmd"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--theme" ]]
  [[ "$output" =~ "#2596be" ]]
  # The value must appear as its own line, not merged/truncated.
  printf '%s\n' "$output" | grep -qx '#2596be'
}
