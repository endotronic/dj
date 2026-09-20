#!/usr/bin/env bats
#
# Coverage for scripts/migrate.sh -- the detect/repair mechanism for
# machine state that newer code expects but an older bootstrap never
# created (CLAUDE.md §9 requires a bats file per scripts/ script).
#
# Every test points DOTFILES_REPO_ROOT at a throwaway dir inside the
# sandbox, so the migrations that shell out to sibling scripts
# (pending-packages, postinstall-hooks, agy-installed) find nothing and
# report N/A. That isolates each test to the one migration it exercises.

load test_helper

MIGRATE="$DOTFILES_REPO_ROOT/scripts/migrate.sh"

setup() {
  sandbox_setup
  stub_dir_setup
  FAKE_ROOT="$SANDBOX/repo"
  mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/packages/postinstall"
  export DOTFILES_REPO_ROOT="$FAKE_ROOT"
  export DOT_DIR="$HOME/.config.git"
  export DOTFILES_BACKUP_DIR="$SANDBOX/backup"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
}

teardown() {
  sandbox_teardown
}

# A `tmux` whose -V reports the given version string.
stub_tmux_version() {
  printf '#!/bin/sh\ncase "$1" in\n  -V) echo "tmux %s" ;;\n  *) exit 0 ;;\nesac\n' \
    "$1" > "$STUB_BIN/tmux"
  chmod +x "$STUB_BIN/tmux"
}

# A `bats` whose --version reports the given version string.
stub_bats_version() {
  printf '#!/bin/sh\ncase "$1" in\n  --version) echo "Bats %s" ;;\n  *) exit 0 ;;\nesac\n' \
    "$1" > "$STUB_BIN/bats"
  chmod +x "$STUB_BIN/bats"
}

# Replace PATH with a farm of symlinks to just the binaries
# migrate.sh actually calls, deliberately omitting `tmux`. The sandbox
# only PREPENDS $STUB_BIN, so the host's own tmux is otherwise always
# reachable and "tmux is not installed" cannot be expressed.
path_without_tmux() {
  local farm="$SANDBOX/minbin" c src
  mkdir -p "$farm"
  for c in sh awk chmod date git grep head hostname id mkdir mv rm sed ssh-keygen; do
    src="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$src" ] && ln -sf "$src" "$farm/$c"
  done
  export PATH="$STUB_BIN:$farm"
}

# The farm above carries neither `tmux` nor `bats`, so the same trick
# expresses "bats is not installed" -- needed because the host running
# these tests has its own (too old) bats on PATH by definition.
path_without_bats() { path_without_tmux; }

# A bare private repo at $DOT_DIR with an origin pointing at a real
# upstream, mimicking what `git clone --bare` leaves behind: no
# remote.origin.fetch, no branch tracking.
make_bare_with_origin() {
  local up="$SANDBOX/upstream"
  git init -q "$up"
  ( cd "$up" && git config user.email t@e.com && git config user.name t \
      && git config commit.gpgsign false \
      && echo hi > f && git add f && git commit -q -m init )
  git clone -q --bare "$up" "$DOT_DIR"
  # a bare clone DOES get a fetch refspec from `git clone`; strip it so
  # we reproduce the state install.sh's own `git clone --bare` leaves.
  git --git-dir="$DOT_DIR" config --unset-all remote.origin.fetch 2>/dev/null || true
  git --git-dir="$DOT_DIR" config --unset branch.master.remote 2>/dev/null || true
  git --git-dir="$DOT_DIR" config --unset branch.master.merge 2>/dev/null || true
  git --git-dir="$DOT_DIR" for-each-ref --format='%(refname)' refs/remotes \
    | while read -r r; do git --git-dir="$DOT_DIR" update-ref -d "$r"; done
}

# --- argument handling ------------------------------------------------------

@test "migrate: --list names every migration with an auto/manual tag" {
  run sh "$MIGRATE" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"git-refspec"*"auto"* ]]
  [[ "$output" == *"ssh-machine-identity"*"manual"* ]]
  [[ "$output" == *"postinstall-hooks"*"manual"* ]]
  [[ "$output" == *"tmux-version"* ]]
}

@test "migrate: --help prints usage without running checks" {
  run sh "$MIGRATE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--fix"* ]]
}

@test "migrate: rejects an unknown argument" {
  run sh "$MIGRATE" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "migrate: a clean machine exits 0 and says so" {
  stub_tmux_version 3.4
  stub_bats_version 1.11.1
  run sh "$MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

# --- git-refspec ------------------------------------------------------------

@test "git-refspec: N/A when there is no private repo" {
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 0 ]
  [[ "$output" != *"origin/* refs"* ]]
}

@test "git-refspec: N/A when the private repo has no origin" {
  git init --bare -q "$DOT_DIR"
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 0 ]
}

@test "git-refspec: pending when the bare clone has no fetch refspec" {
  make_bare_with_origin
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
  [[ "$output" == *"origin/* refs"* ]]
}

@test "git-refspec: --fix sets the refspec, tracking, and fetches" {
  make_bare_with_origin
  run sh "$MIGRATE" --fix --only git-refspec
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$DOT_DIR" config --get remote.origin.fetch)" = \
    '+refs/heads/*:refs/remotes/origin/*' ]
  [ "$(git --git-dir="$DOT_DIR" config --get branch.master.remote)" = origin ]
  [ "$(git --git-dir="$DOT_DIR" config --get branch.master.merge)" = refs/heads/master ]
  git --git-dir="$DOT_DIR" rev-parse --verify refs/remotes/origin/master
}

@test "git-refspec: --fix is idempotent and the second run reports ok" {
  make_bare_with_origin
  sh "$MIGRATE" --fix --only git-refspec >/dev/null
  run sh "$MIGRATE" --fix --only git-refspec
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [ "$(git --git-dir="$DOT_DIR" config --get-all remote.origin.fetch | wc -l)" -eq 1 ]
}

@test "git-refspec: missing branch tracking alone is enough to be pending" {
  make_bare_with_origin
  git --git-dir="$DOT_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

# --- dotfiles-origin-ssh ----------------------------------------------------

setup_public_repo() {
  mkdir -p "$FAKE_ROOT"
  git init -q "$FAKE_ROOT"
  git -C "$FAKE_ROOT" remote add origin "$1"
}

@test "dotfiles-origin-ssh: N/A without a git-host key" {
  setup_public_repo https://github.com/u/r.git
  run sh "$MIGRATE" --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
}

@test "dotfiles-origin-ssh: pending when https and the key exists" {
  setup_public_repo https://github.com/u/r.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --only dotfiles-origin-ssh
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "dotfiles-origin-ssh: --fix rewrites https to the scp-style ssh form" {
  setup_public_repo https://github.com/u/r.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --fix --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
  [ "$(git -C "$FAKE_ROOT" remote get-url origin)" = 'git@github.com:u/r.git' ]
}

@test "dotfiles-origin-ssh: works for a self-hosted forge, not just github" {
  setup_public_repo https://git.example.com/kevin/dotfiles.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --fix --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
  [ "$(git -C "$FAKE_ROOT" remote get-url origin)" = \
    'git@git.example.com:kevin/dotfiles.git' ]
}

@test "dotfiles-origin-ssh: ok when origin is already ssh" {
  setup_public_repo git@github.com:u/r.git
  : > "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --only dotfiles-origin-ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- ssh-pubkey -------------------------------------------------------------

@test "ssh-pubkey: N/A when there is no private key" {
  run sh "$MIGRATE" --only ssh-pubkey
  [ "$status" -eq 0 ]
  [[ "$output" != *"public key"* ]]
}

@test "ssh-pubkey: --fix derives the public half from the private key" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C test@host
  rm -f "$HOME/.ssh/id_ed25519.pub"
  run sh "$MIGRATE" --fix --only ssh-pubkey
  [ "$status" -eq 0 ]
  [ -f "$HOME/.ssh/id_ed25519.pub" ]
  [ "$(stat -c '%a' "$HOME/.ssh/id_ed25519.pub")" = 644 ]
  # the derived key must match the private key it came from
  [ "$(ssh-keygen -lf "$HOME/.ssh/id_ed25519" | awk '{print $2}')" = \
    "$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" | awk '{print $2}')" ]
}

@test "ssh-pubkey: ok when the public key already exists" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C test@host
  run sh "$MIGRATE" --only ssh-pubkey
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- ssh-machine-identity (manual) -----------------------------------------

@test "ssh-machine-identity: ok when the two keys differ" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C machine
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_githost"  -C forge
  run sh "$MIGRATE" --only ssh-machine-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "ssh-machine-identity: flagged MANUAL when machine key == git-host key" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C shared
  cp "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --only ssh-machine-identity
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"ssh-keygen"* ]]
}

@test "ssh-machine-identity: --fix never rotates the key on its own" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C shared
  cp "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_githost"
  before="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519" | awk '{print $2}')"
  run sh "$MIGRATE" --fix --only ssh-machine-identity
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [ "$(ssh-keygen -lf "$HOME/.ssh/id_ed25519" | awk '{print $2}')" = "$before" ]
}

# --- legacy-tmux-conf -------------------------------------------------------

@test "legacy-tmux-conf: N/A when no tracked tmux.conf is deployed" {
  : > "$HOME/.tmux.conf"
  run sh "$MIGRATE" --only legacy-tmux-conf
  [ "$status" -eq 0 ]
}

@test "legacy-tmux-conf: --fix moves every ~/.tmux.conf* aside" {
  mkdir -p "$HOME/.config/tmux"
  echo tracked > "$HOME/.config/tmux/tmux.conf"
  echo legacy   > "$HOME/.tmux.conf"
  echo tmpl     > "$HOME/.tmux.conf.template"
  run sh "$MIGRATE" --fix --only legacy-tmux-conf
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.tmux.conf" ]
  [ ! -e "$HOME/.tmux.conf.template" ]
  [ "$(cat "$DOTFILES_BACKUP_DIR/.tmux.conf")" = legacy ]
  [ "$(cat "$DOTFILES_BACKUP_DIR/.tmux.conf.template")" = tmpl ]
  # the tracked config is untouched
  [ "$(cat "$HOME/.config/tmux/tmux.conf")" = tracked ]
}

@test "legacy-tmux-conf: ok once nothing shadows the tracked config" {
  mkdir -p "$HOME/.config/tmux"
  : > "$HOME/.config/tmux/tmux.conf"
  run sh "$MIGRATE" --only legacy-tmux-conf
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- tmux-version -----------------------------------------------------------

@test "tmux-version: N/A when tmux is not installed" {
  path_without_tmux
  run sh "$MIGRATE" --only tmux-version
  [ "$status" -eq 0 ]
  [[ "$output" != *"clickable"* ]]
}

@test "tmux-version: ok at exactly the 3.4 minimum" {
  stub_tmux_version 3.4
  run sh "$MIGRATE" --only tmux-version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "tmux-version: ok above the minimum" {
  stub_tmux_version 3.5a
  run sh "$MIGRATE" --only tmux-version
  [ "$status" -eq 0 ]
}

@test "tmux-version: ok for a next- prerelease above the minimum" {
  stub_tmux_version next-3.6
  run sh "$MIGRATE" --only tmux-version
  [ "$status" -eq 0 ]
}

@test "tmux-version: pending on 3.2a (the Ubuntu jammy version)" {
  stub_tmux_version 3.2a
  run sh "$MIGRATE" --only tmux-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "tmux-version: pending across a major boundary (2.9 < 3.4)" {
  stub_tmux_version 2.9
  run sh "$MIGRATE" --only tmux-version
  [ "$status" -eq 1 ]
}

@test "tmux-version: --fix reports honestly when no upgrade path exists" {
  stub_tmux_version 3.2a
  # a hook that cannot help (mimics the Debian-only tmux-backports.sh
  # skipping on Ubuntu): exits 0 without changing anything
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/packages/postinstall/tmux-backports.sh"
  chmod +x "$FAKE_ROOT/packages/postinstall/tmux-backports.sh"
  run sh "$MIGRATE" --fix --only tmux-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"no apt/pacman/brew upgrade path"* ]]
  [[ "$output" == *"could not be completed"* ]]
}

@test "tmux-version: --fix succeeds when the hook actually upgrades tmux" {
  stub_tmux_version 3.2a
  cat > "$FAKE_ROOT/packages/postinstall/tmux-backports.sh" <<HOOK
#!/bin/sh
printf '#!/bin/sh\ncase "\$1" in -V) echo "tmux 3.4" ;; *) exit 0 ;; esac\n' \
  > "$STUB_BIN/tmux"
chmod +x "$STUB_BIN/tmux"
HOOK
  chmod +x "$FAKE_ROOT/packages/postinstall/tmux-backports.sh"
  run sh "$MIGRATE" --fix --only tmux-version
  [ "$status" -eq 0 ]
  [[ "$output" == *"upgraded to 3.4"* ]]
}

# --- bats-version -----------------------------------------------------------

@test "bats-version: N/A when bats is not installed" {
  path_without_bats
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 0 ]
  [[ "$output" != *"test suite"* ]]
}

@test "bats-version: ok at exactly the 1.5 minimum" {
  stub_bats_version 1.5.0
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "bats-version: ok above the minimum" {
  stub_bats_version 1.11.1
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 0 ]
}

@test "bats-version: pending on 1.2.1 (the Debian/Ubuntu version)" {
  stub_bats_version 1.2.1
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "bats-version: pending across a major boundary (0.4 < 1.5)" {
  stub_bats_version 0.4.0
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 1 ]
}

@test "bats-version: --fix runs the fallback installer and re-checks" {
  stub_bats_version 1.2.1
  mkdir -p "$FAKE_ROOT/packages/scripts"
  # Stand in for packages/scripts/bats.sh: leaves a marker and
  # "upgrades" the stub it is checked against.
  cat > "$FAKE_ROOT/packages/scripts/bats.sh" <<EOF
#!/bin/sh
touch "$SANDBOX/installer-ran"
printf '#!/bin/sh\ncase "\$1" in\n  --version) echo "Bats 1.11.1" ;;\n  *) exit 0 ;;\nesac\n' > "$STUB_BIN/bats"
chmod +x "$STUB_BIN/bats"
EOF
  chmod +x "$FAKE_ROOT/packages/scripts/bats.sh"

  run sh "$MIGRATE" --fix --only bats-version
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/installer-ran" ]
  [[ "$output" == *"upgraded to 1.11.1"* ]]
}

@test "bats-version: --fix reports honestly when the installer does not help" {
  stub_bats_version 1.2.1
  mkdir -p "$FAKE_ROOT/packages/scripts"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/packages/scripts/bats.sh"
  chmod +x "$FAKE_ROOT/packages/scripts/bats.sh"

  run sh "$MIGRATE" --fix --only bats-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"still 1.2.1"* ]]
}

@test "bats-version: --fix warns when the fallback installer is missing" {
  stub_bats_version 1.2.1
  run sh "$MIGRATE" --fix --only bats-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot upgrade bats"* ]]
}

# --- legacy-home-git --------------------------------------------------------

@test "legacy-home-git: ok when \$HOME is not a git work tree" {
  run sh "$MIGRATE" --only legacy-home-git
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "legacy-home-git: MANUAL when ~/.git exists" {
  git init -q "$HOME"
  run sh "$MIGRATE" --only legacy-home-git
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"$HOME/.git"* ]]
}

@test "legacy-home-git: MANUAL for a leftover ~/.gitignore alone" {
  # The ignore file is half the trap on its own: it is read
  # work-tree-relative, so it silently governs the private bare repo.
  printf '.ssh\n' > "$HOME/.gitignore"
  run sh "$MIGRATE" --only legacy-home-git
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"$HOME/.gitignore"* ]]
}

@test "legacy-home-git: --fix never removes the repo on its own" {
  git init -q "$HOME"
  printf '.ssh\n' > "$HOME/.gitignore"
  run sh "$MIGRATE" --fix --only legacy-home-git
  [ "$status" -eq 1 ]
  [ -d "$HOME/.git" ]
  [ -f "$HOME/.gitignore" ]
  [[ "$output" == *"mv ~/.git"* ]]
}

@test "legacy-home-git: reports uncommitted work so the decision is informed" {
  git init -q "$HOME"
  git --git-dir="$HOME/.git" --work-tree="$HOME" config user.email t@e.com
  git --git-dir="$HOME/.git" --work-tree="$HOME" config user.name t
  git --git-dir="$HOME/.git" --work-tree="$HOME" config commit.gpgsign false
  printf 'one\n' > "$HOME/tracked.txt"
  git --git-dir="$HOME/.git" --work-tree="$HOME" add tracked.txt
  git --git-dir="$HOME/.git" --work-tree="$HOME" commit -q -m init
  printf 'two\n' > "$HOME/tracked.txt"

  run sh "$MIGRATE" --fix --only legacy-home-git
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 tracked file(s) with uncommitted changes"* ]]
}

# --- pending-packages / postinstall-hooks / agy ----------------------------

@test "pending-packages: pending when install-packages reports work to do" {
  cat > "$FAKE_ROOT/scripts/install-packages.sh" <<'IP'
#!/bin/sh
echo "[install-packages] to install: wl-clipboard nfs-common"
IP
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" --only pending-packages
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "pending-packages: ok when nothing is outstanding" {
  cat > "$FAKE_ROOT/scripts/install-packages.sh" <<'IP'
#!/bin/sh
echo "[install-packages] already installed: git tmux"
IP
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" --only pending-packages
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "postinstall-hooks: MANUAL when a listed hook has no script" {
  cat > "$FAKE_ROOT/scripts/run-postinstall.sh" <<'RP'
#!/bin/sh
echo "[run-postinstall] WARNING: no hook script for zfs-textfile-collector" >&2
exit 1
RP
  chmod +x "$FAKE_ROOT/scripts/run-postinstall.sh"
  run sh "$MIGRATE" --fix --only postinstall-hooks
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"zfs-textfile-collector"* ]]
}

@test "postinstall-hooks: ok when every listed hook resolves" {
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/scripts/run-postinstall.sh"
  chmod +x "$FAKE_ROOT/scripts/run-postinstall.sh"
  run sh "$MIGRATE" --only postinstall-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "agy-installed: N/A when agy is not in any package list" {
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/scripts/install-antigravity.sh"
  chmod +x "$FAKE_ROOT/scripts/install-antigravity.sh"
  run sh "$MIGRATE" --only agy-installed
  [ "$status" -eq 0 ]
  [[ "$output" != *"antigravity"* ]]
}

@test "agy-installed: pending when listed but absent from PATH" {
  mkdir -p "$HOME/.config/dj/packages"
  printf 'git\nagy\ntmux\n' > "$HOME/.config/dj/packages/common.txt"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/scripts/install-antigravity.sh"
  chmod +x "$FAKE_ROOT/scripts/install-antigravity.sh"
  run sh "$MIGRATE" --only agy-installed
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "agy-installed: --fix runs the vendor installer" {
  mkdir -p "$HOME/.config/dj/packages"
  printf 'agy\n' > "$HOME/.config/dj/packages/common.txt"
  cat > "$FAKE_ROOT/scripts/install-antigravity.sh" <<INST
#!/bin/sh
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/agy"
chmod +x "$STUB_BIN/agy"
INST
  chmod +x "$FAKE_ROOT/scripts/install-antigravity.sh"
  run sh "$MIGRATE" --fix --only agy-installed
  [ "$status" -eq 0 ]
  [ -x "$STUB_BIN/agy" ]
}

# --- selection --------------------------------------------------------------

@test "migrate: --only restricts the run to the named migration" {
  make_bare_with_origin
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C shared
  cp "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_githost"
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 1 ]
  [[ "$output" != *"MANUAL"* ]]
}

@test "migrate: without --only every applicable migration is evaluated" {
  make_bare_with_origin
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C shared
  cp "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_githost"
  run sh "$MIGRATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
  [[ "$output" == *"MANUAL"* ]]
}
