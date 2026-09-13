#!/usr/bin/env bats
#
# Tests for scripts/dj-root-setup.sh (`dj root-setup hostname ...`). It
# connects as root@hostname over one multiplexed SSH connection,
# checks/creates a user named after this machine's own invoking user
# (`id -un`), pushes the age key (and git-host key, if present)
# directly into that user's home, and finally runs install.sh as that
# user via `su - USER -c ...`. ssh and scp are stubbed -- no real
# network, agent, or root access involved. git and the SSH/age key
# files are real (a throwaway repo/bare-repo under the sandboxed
# $HOME), since the remote-URL/branch and private-repo derivation
# logic is the part worth exercising for real.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export SETUP="$DOTFILES_REPO_ROOT/scripts/dj-root-setup.sh"
  export DOT_DIR="$HOME/.config.git"
  export DOTFILES_DIR="$HOME/.dotfiles"
  mkdir -p "$HOME/.ssh" "$XDG_CONFIG_HOME/sops/age"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  # See dj-setup.bats for why claude needs an explicit default stub:
  # without one, `command -v claude` falls through to the real binary
  # this repo is developed inside.
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUB_BIN/claude"
}

teardown() {
  sandbox_teardown
}

# ---------- fixture builders (same as dj-setup.bats) ---------------------

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

# Stub `ssh` to record each call's full argv into its own
# $SANDBOX/ssh_call_N_argv_M files (plus ssh_call_N_argc), N being a
# 0-indexed, persisted call counter -- and dispatch a canned response
# for the user-check call (identified by containing "sh -c") vs a
# no-output response for everything else (the chown call and the
# final -t bootstrap call, neither of which contains that substring).
stub_ssh_default() {
  created=${1:-1}
  home_dir=${2:-/home/testuser}
  printf '0' > "$SANDBOX/ssh_call_next"
  cat > "$STUB_BIN/ssh" <<EOF
#!/bin/sh
{ printf 'ssh'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$SANDBOX/stub.log"
for a in "\$@"; do
  [ "\$a" = "-O" ] && exit 0
done
n=\$(cat "$SANDBOX/ssh_call_next" 2>/dev/null || echo 0)
i=0
for a in "\$@"; do
  i=\$((i + 1))
  printf '%s' "\$a" > "$SANDBOX/ssh_call_\${n}_argv_\$i"
done
printf '%s' "\$i" > "$SANDBOX/ssh_call_\${n}_argc"
printf '%s' "\$((n + 1))" > "$SANDBOX/ssh_call_next"
last=""
for a in "\$@"; do last=\$a; done
case "\$last" in
  *"sh -c"*)
    printf 'CREATED=%s\nHOME_DIR=%s\n' "$created" "$home_dir"
    ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
}

# The remote-command argument of ssh call N (0-indexed) -- always its
# last argv element.
remote_cmd_of() {
  argc=$(cat "$SANDBOX/ssh_call_${1}_argc")
  cat "$SANDBOX/ssh_call_${1}_argv_$argc"
}

# The final bootstrap call is always the last one recorded.
final_remote_cmd() {
  last=$(( $(cat "$SANDBOX/ssh_call_next") - 1 ))
  remote_cmd_of "$last"
}

default_stubs() {
  stub_ssh_default "${1:-1}" "${2:-/home/testuser}"
  stub_cmd scp
}

# ---------- argument / precondition errors -------------------------------

@test "no arguments prints usage and exits 2" {
  run sh "$SETUP"
  [ "$status" -eq 2 ]
  [[ "$output" =~ usage ]]
}

@test "a non-root user@host argument is rejected with a pointer to dj setup" {
  run sh "$SETUP" kevin@testhost
  [ "$status" -eq 2 ]
  [[ "$output" =~ "always connects as root" ]]
  [[ "$output" =~ "dj setup" ]]
}

@test "root@host is accepted the same as a bare hostname" {
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" root@testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
}

@test "no local age key exits 1 before touching the target" {
  rm -f "$XDG_CONFIG_HOME/sops/age/keys.txt"
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" =~ "no age key at" ]]
  ! stub_called scp
}

@test "private repo with no remote configured exits 1" {
  default_stubs
  git init --bare -q "$DOT_DIR"
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" =~ "has no remote configured" ]]
}

# ---------- system-type / theme prompts (same contract as dj-setup) -----

@test "prompts for system-type when omitted" {
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --theme '#2596be' <<< 'server'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "system type for testhost" ]]
  remote_cmd=$(final_remote_cmd)
  # The install.sh args live inside install.sh's own quoted argument to
  # `su -c`, so each of THEIR quotes is itself escaped (' -> '\'') at
  # that outer layer -- check the flag and its value show up as
  # substrings rather than assume a specific quoting style survives
  # two levels of nesting intact.
  [[ "$remote_cmd" == *"--system-type"* ]]
  [[ "$remote_cmd" == *"server"* ]]
}

@test "generates a theme when omitted (falls back to random since claude is stubbed off)" {
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" =~ --theme.*\#[0-9a-f]{6} ]]
}

# ---------- SSH invocation shape ------------------------------------------

@test "connects as root@host even when given a bare hostname" {
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  grep -q "root@testhost" "$SANDBOX/stub.log"
}

@test "the final bootstrap call uses -t, accept-new, and control multiplexing" {
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  last=$(( $(cat "$SANDBOX/ssh_call_next") - 1 ))
  argc=$(cat "$SANDBOX/ssh_call_${last}_argc")
  argv1=$(cat "$SANDBOX/ssh_call_${last}_argv_1")
  [ "$argv1" = "-t" ]
  found_accept_new=0
  found_hostspec=0
  i=1
  while [ "$i" -le "$argc" ]; do
    v=$(cat "$SANDBOX/ssh_call_${last}_argv_$i")
    [ "$v" = "StrictHostKeyChecking=accept-new" ] && found_accept_new=1
    [ "$v" = "root@testhost" ] && found_hostspec=1
    i=$((i + 1))
  done
  [ "$found_accept_new" -eq 1 ]
  [ "$found_hostspec" -eq 1 ]
}

@test "the ControlMaster socket is torn down (ssh -O exit) after the run" {
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  grep -q -- "-O exit root@testhost$" "$SANDBOX/stub.log"
}

# ---------- user check / creation ------------------------------------------

@test "the user-check command is run with this machine's own invoking user" {
  default_stubs
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  local_user=$(id -un)

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  cmd0=$(remote_cmd_of 0)
  [[ "$cmd0" == *"sh -c"* ]]
  [[ "$cmd0" == *"-- '$local_user'"* ]]
}

@test "an existing user's real home directory (from getent) is used, not an assumed /home path" {
  stub_ssh_default 0 /srv/homes/testuser
  stub_cmd scp
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already exists on testhost" ]]
  [[ "$output" =~ "/srv/homes/testuser" ]]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"/srv/homes/testuser/.dj-root-setup-agekey"* ]]
}

@test "a freshly created user is reported as such" {
  default_stubs 1 /home/newbie
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "created" ]]
  [[ "$output" =~ "/home/newbie" ]]
}

@test "no HOME_DIR in the user-check output exits 1" {
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/bin/sh
for a in "$@"; do
  [ "$a" = "-O" ] && exit 0
done
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  stub_cmd scp
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" =~ "could not determine home directory" ]]
}

# ---------- key push shape --------------------------------------------------

@test "pushes the local age key into the target user's home and chowns it" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  grep -q "^scp -q -o StrictHostKeyChecking=accept-new .*sops/age/keys.txt root@testhost:/home/testuser/.dj-root-setup-agekey" "$SANDBOX/stub.log"
  chown_cmd=$(remote_cmd_of 1)
  [[ "$chown_cmd" == *"chown"* ]]
  [[ "$chown_cmd" == *"/home/testuser/.dj-root-setup-agekey"* ]]
}

@test "pushes the git-host deploy key too when present locally" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  printf 'FAKE-DEPLOY-KEY\n' > "$HOME/.ssh/id_githost"

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  grep -q "^scp -q -o StrictHostKeyChecking=accept-new .*id_githost root@testhost:/home/testuser/.dj-root-setup-gitkey" "$SANDBOX/stub.log"
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"--git-key"* ]]
  [[ "$remote_cmd" == *"/home/testuser/.dj-root-setup-gitkey"* ]]
}

@test "no local deploy key: nothing pushed, no --git-key, install still proceeds" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  rm -f "$HOME/.ssh/id_githost"

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "may have no credentials" ]]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" != *"--git-key"* ]]
  [[ "$remote_cmd" != *"gitkey"* ]]
}

# ---------- final su-wrapped bootstrap command ------------------------------

@test "the final command wraps install.sh in su - USER -c, not a second ssh hop" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  local_user=$(id -un)

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"su - '$local_user' -c"* ]]
  [[ "$remote_cmd" == *"--private-repo"* ]]
  [[ "$remote_cmd" == *"--age-key"* ]]
  [[ "$remote_cmd" == *"/home/testuser/.dj-root-setup-agekey"* ]]
}

@test "the final command always attempts to remove this user's sudoers drop-in" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git
  local_user=$(id -un)

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"rm -f '/etc/sudoers.d/dj-root-setup-$local_user'"* ]]
}

@test "install.sh's exit status survives the su wrapper and cleanup" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)

  # Run the captured remote command for real, replacing the su/curl
  # pipeline internals with stubs that force a specific exit code, and
  # confirm that status -- not the cleanup's -- comes back.
  cat > "$STUB_BIN/su" <<'EOF'
#!/bin/sh
exit 9
EOF
  chmod +x "$STUB_BIN/su"
  cat > "$STUB_BIN/rm" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$STUB_BIN/rm"
  PATH="$STUB_BIN:$PATH" run /bin/sh -c "$remote_cmd"
  [ "$status" -eq 9 ]
}

@test "remote command exports DOTFILES_ACCEPT_NEW_HOSTS for install.sh's own private-repo clone" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"DOTFILES_ACCEPT_NEW_HOSTS=1"* ]]
}

# ---------- raw install.sh URL derivation (same logic as dj-setup) -------

@test "derives the raw install URL from a git@github.com origin" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git main

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/someuser/somerepo/main/install.sh"* ]]
}

@test "falls back to the default raw URL for a non-github origin" {
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin https://gitlab.example.com/someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"https://raw.githubusercontent.com/endotronic/dj/master/install.sh"* ]]
}

@test "remote command includes this machine's own private-repo URL" {
  default_stubs 1 /home/testuser
  private_repo_with_remote git@git.example.com:kevin/dotfiles.git
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)
  [[ "$remote_cmd" == *"--private-repo"* ]]
  [[ "$remote_cmd" == *"git@git.example.com:kevin/dotfiles.git"* ]]
}

# ---------- quoting safety: the actual bug class this guards against ----

@test "extra args survive being re-parsed by a real shell, hex-color '#' included" {
  # Regression: naively string-joining args loses their original
  # quoting, so a `--theme '#2596be'` reconstructed unquoted would
  # have its value's '#' truncate the rest of the line as a comment.
  # This script nests quoting twice (install.sh's own args, then the
  # whole install.sh invocation again as su -c's argument), so verify
  # end-to-end: replace `su` with a stub that actually execs its -c
  # string (as real su would) and `curl`'s piped output with a stub
  # that dumps argv, then confirm '#2596be' arrives intact.
  default_stubs 1 /home/testuser
  private_repo_with_remote
  dotfiles_repo_with_origin git@github.com:someuser/somerepo.git

  run sh "$SETUP" testhost --system-type server --theme '#2596be' < /dev/null
  [ "$status" -eq 0 ]
  remote_cmd=$(final_remote_cmd)

  cat > "$STUB_BIN/su" <<'EOF'
#!/bin/sh
# su - USER -c CMD -- run CMD for real, like the genuine article would.
shift 2
sh -c "$2"
EOF
  chmod +x "$STUB_BIN/su"
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
  # The value must appear as its own line, not merged/truncated.
  printf '%s\n' "$output" | grep -qx '#2596be'
}
