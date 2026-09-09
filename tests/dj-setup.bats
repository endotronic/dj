#!/usr/bin/env bats
#
# Tests for scripts/dj-setup.sh (`dj setup [user@]host ...`). It
# bootstraps a brand-new machine over `ssh -A -t`, filling in this
# machine's own --private-repo (from ~/.config.git's remote) and
# pushing its own age key to the target via a plain scp (replacing an
# --sops round trip). ssh, scp, ssh-agent, ssh-add, and ssh-keygen are
# all stubbed -- no real network or agent involved. git and the SSH
# key file are real (a throwaway repo/bare-repo under the sandboxed
# $HOME), since the remote-URL and branch derivation logic is the part
# worth exercising for real.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export SETUP="$DOTFILES_REPO_ROOT/scripts/dj-setup.sh"
  export DOT_DIR="$HOME/.config.git"
  export DOTFILES_DIR="$HOME/.dotfiles"
  mkdir -p "$HOME/.ssh" "$XDG_CONFIG_HOME/sops/age"
  printf 'fake-private-key\n' > "$HOME/.ssh/id_ed25519"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  stub_cmd scp
  # $STUB_BIN is only prepended to PATH, not exclusive -- without a
  # stub here, `command -v claude` would fall through to the REAL
  # claude binary (this repo is developed inside Claude Code, so it's
  # genuinely on PATH) and every test reaching the theme-auto-generate
  # code would fire a real, non-hermetic invocation of it. Default to
  # "unavailable" (exit 1, no output); tests that actually exercise
  # theme generation install their own working stub instead.
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUB_BIN/claude"
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

# ---------- theme auto-generation via claude when omitted ---------------

@test "generates --theme via claude when omitted and claude returns a valid hex color" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
printf 'Sure! #ff0000 seems fitting.\n'
EOF
  chmod +x "$STUB_BIN/claude"

  run sh "$SETUP" testhost --system-type server < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "generated tmux theme color for testhost via claude: #ff0000" ]]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"'--theme' '#ff0000'"* ]]
}

@test "falls back to a random --theme when claude produces no valid hex color" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
printf 'I cannot help with that.\n'
EOF
  chmod +x "$STUB_BIN/claude"

  run sh "$SETUP" testhost --system-type server < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no theme from claude; generated a random one for testhost:" ]]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" =~ \'--theme\'\ \'#[0-9a-f]{6}\' ]]
}

@test "falls back to a random --theme when claude isn't on PATH at all" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  unstub_cmd claude
  # Same PATH-restriction technique as the timeout-unavailable test
  # below: unstub_cmd alone isn't enough since PATH still falls
  # through to the real system `claude` further down.
  for u in git awk basename sed grep head od tr date; do
    ln -sf "$(command -v "$u")" "$STUB_BIN/$u"
  done

  PATH="$STUB_BIN" run /bin/sh "$SETUP" testhost --system-type server < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" =~ \'--theme\'\ \'#[0-9a-f]{6}\' ]]
}

@test "claude is never invoked when --theme is already supplied" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  stub_cmd claude

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  ! stub_called claude
}

@test "claude is never invoked, and theme still falls back to random, when timeout is unavailable" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  stub_cmd claude
  # unstub_cmd alone isn't enough -- PATH still falls through to the
  # real system `timeout` further down. Restrict PATH to $STUB_BIN
  # (which never had a `timeout` stub) instead, symlinking in the
  # other real utilities dj-setup.sh still needs.
  for u in git awk basename sed grep head od tr date; do
    ln -sf "$(command -v "$u")" "$STUB_BIN/$u"
  done

  PATH="$STUB_BIN" run /bin/sh "$SETUP" testhost --system-type server < /dev/null
  [ "$status" -eq 0 ]
  ! stub_called claude
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" =~ \'--theme\'\ \'#[0-9a-f]{6}\' ]]
}

# ---------- system-type prompt when omitted -----------------------------

@test "prompts for system-type when omitted, and injects a valid answer" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost <<< 'server'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "system type for testhost" ]]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"'--system-type' 'server'"* ]]
}

@test "blank answer to the system-type prompt keeps the common-only default" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost <<< ''
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" != *"--system-type"* ]]
}

@test "no stdin at all (EOF) keeps the common-only default without hanging" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" != *"--system-type"* ]]
}

@test "invalid system-type answer exits 2" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost <<< 'not a valid type'
  [ "$status" -eq 2 ]
  [[ "$output" =~ "must contain only letters, digits" ]]
}

@test "already-supplied --system-type skips the prompt entirely" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type desktop < /dev/null
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "system type for" ]]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"'--system-type' 'desktop'"* ]]
}

@test "prompt lists known system types from ~/.config/dj/packages/types/" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  mkdir -p "$XDG_CONFIG_HOME/dj/packages/types"
  : > "$XDG_CONFIG_HOME/dj/packages/types/desktop.txt"
  : > "$XDG_CONFIG_HOME/dj/packages/types/server.txt"

  run sh "$SETUP" testhost <<< ''
  [ "$status" -eq 0 ]
  [[ "$output" =~ "known: desktop, server" ]]
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
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/someuser/somerepo/main/install.sh"* ]]
}

@test "derives the raw install URL from an https://github.com origin" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin https://github.com/someuser/somerepo.git develop

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/someuser/somerepo/develop/install.sh"* ]]
}

@test "falls back to the default raw URL for a non-github origin" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin https://gitlab.example.com/someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/endotronic/dj/master/install.sh"* ]]
}

# ---------- private-repo / sops / ssh invocation shape ------------------

@test "ssh is invoked with -A -t, accept-new, the hostspec, and exactly one remote-command argument" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" kevin@testhost
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/ssh_argc")" = 6 ]
  [ "$(cat "$SANDBOX/ssh_argv_1")" = "-A" ]
  [ "$(cat "$SANDBOX/ssh_argv_2")" = "-t" ]
  [ "$(cat "$SANDBOX/ssh_argv_3")" = "-o" ]
  [ "$(cat "$SANDBOX/ssh_argv_4")" = "StrictHostKeyChecking=accept-new" ]
  [ "$(cat "$SANDBOX/ssh_argv_5")" = "kevin@testhost" ]
}

@test "remote command includes this machine's own private-repo URL" {
  default_stubs ""
  private_repo_with_remote git@git.example.com:kevin/dotfiles.git
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"--private-repo 'git@git.example.com:kevin/dotfiles.git'"* ]]
}

# ---------- age-key push (replaces an --sops round trip) ----------------

@test "no local age key exits 1 before touching the target" {
  rm -f "$XDG_CONFIG_HOME/sops/age/keys.txt"
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 1 ]
  [[ "$output" =~ "no age key at" ]]
  ! stub_called scp
}

@test "pushes the local age key to a /tmp path on the target via scp" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  grep -q "^scp -q -o StrictHostKeyChecking=accept-new .*sops/age/keys.txt testhost:/tmp/dj-setup-agekey-" "$SANDBOX/stub.log"
}

@test "remote command exports DOTFILES_ACCEPT_NEW_HOSTS for install.sh's own private-repo clone" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == "export DOTFILES_ACCEPT_NEW_HOSTS=1;"* ]]
}

@test "pushes the git-host deploy key too, and points install.sh at it" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  printf 'FAKE-DEPLOY-KEY\n' > "$HOME/.ssh/id_githost"

  run sh "$SETUP" testhost --system-type server < /dev/null
  [ "$status" -eq 0 ]
  grep -q "^scp -q -o StrictHostKeyChecking=accept-new .*id_githost testhost:/tmp/dj-setup-gitkey-" "$SANDBOX/stub.log"
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"--git-key '/tmp/dj-setup-gitkey-"* ]]
  [[ "$remote_cmd" == *"shred -u '/tmp/dj-setup-gitkey-"* ]]
}

@test "no local deploy key: nothing pushed, no --git-key, install still proceeds" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  rm -f "$HOME/.ssh/id_githost"

  run sh "$SETUP" testhost --system-type server < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "rely on the forwarded agent" ]]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" != *"--git-key"* ]]
  [[ "$remote_cmd" != *"deploykey"* ]]
}

@test "remote command uses --age-key with the pushed temp path, not --sops" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"--age-key '/tmp/dj-setup-agekey-"* ]]
  [[ "$remote_cmd" != *"--sops"* ]]
}

@test "remote command cleans up the temp key afterward and preserves install.sh's exit status" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")
  [[ "$remote_cmd" == *"shred -u '/tmp/dj-setup-agekey-"* ]]
  [[ "$remote_cmd" == *"rm -f '/tmp/dj-setup-agekey-"* ]]
  [[ "$remote_cmd" == *'exit $rc'* ]]

  # Prove the exit-status preservation for real: run the captured
  # command with a stubbed inner pipeline that exits 7, and confirm
  # that status -- not the cleanup command's -- is what comes back.
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
cat <<'SCRIPT'
#!/bin/sh
exit 7
SCRIPT
EOF
  chmod +x "$STUB_BIN/curl"
  run sh -c "$remote_cmd"
  [ "$status" -eq 7 ]
}

# ---------- curl-ensure: install it on the target if missing ------------

@test "ensure-curl skips the package manager entirely when curl is already present" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")

  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
printf 'curl-called\n' >> "$SANDBOX/stub.log"
cat <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
EOF
  chmod +x "$STUB_BIN/curl"
  cat > "$STUB_BIN/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get should NOT have been called\n' >> "$SANDBOX/stub.log"
exit 1
EOF
  chmod +x "$STUB_BIN/apt-get"

  run sh -c "$remote_cmd"
  [ "$status" -eq 0 ]
  ! grep -q "should NOT have been called" "$SANDBOX/stub.log"
}

@test "ensure-curl installs curl via apt-get when it's missing" {
  default_stubs ""
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  stub_sudo_passthrough

  run sh "$SETUP" testhost
  [ "$status" -eq 0 ]
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")

  # No curl on PATH yet. apt-get "installs" one as a side effect, same
  # as a real apt install would put a working binary on PATH.
  cat > "$STUB_BIN/apt-get" <<EOF
#!/bin/sh
printf 'apt-get %s\n' "\$*" >> "$SANDBOX/stub.log"
case "\$*" in
  *"install -y curl"*)
    cat > "$STUB_BIN/curl" <<'CURLEOF'
#!/bin/sh
cat <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
CURLEOF
    chmod +x "$STUB_BIN/curl"
    ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/apt-get"
  # The reconstructed command's `| sh -s --` stage needs `sh` on PATH
  # too, and `sudo env VAR=val apt-get ...` needs a real `env` binary
  # (not a shell builtin) -- both must survive PATH being restricted
  # below.
  ln -sf "$(command -v sh)" "$STUB_BIN/sh"
  ln -sf "$(command -v env)" "$STUB_BIN/env"

  # Restrict PATH to just $STUB_BIN for this re-execution -- otherwise
  # the real system curl would still resolve and `command -v curl`
  # would short-circuit before ever exercising the install path. The
  # outer invocation still uses /bin/sh by absolute path (bats' own
  # PATH, unrestricted) to launch it.
  PATH="$STUB_BIN" run /bin/sh -c "$remote_cmd"
  [ "$status" -eq 0 ]
  grep -q "apt-get update" "$SANDBOX/stub.log"
  grep -q "install -y curl" "$SANDBOX/stub.log"
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
  remote_cmd=$(cat "$SANDBOX/ssh_argv_6")

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
