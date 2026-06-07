#!/bin/sh
# Fresh-machine bootstrap for the dotfiles repo.
#
# Usage:
#   sh install.sh [--system-type {desktop|server}] [--repo URL] [--private-repo URL]
#
# Or, when curl-piped from a fresh machine:
#   curl -fsSL <raw-install.sh> | sh
#   curl -fsSL <raw-install.sh> | sh -s -- --system-type desktop
#
# Idempotent: re-running on an installed machine converges rather than
# replaces. Package installs are skipped when the binary is already on
# PATH. The `dot checkout` step backs up any colliding files in $HOME
# to ~/.dotfiles-backup/<utc-timestamp>/ before overwriting.
#
# Two repos get bootstrapped here:
#   ~/.dotfiles/    public tooling repo -- plain `git clone` (or used
#                   in place if install.sh is already running from one)
#   ~/.config.git/  private bare repo, work-tree $HOME -- personal
#                   config + secrets. Cloned bare from --private-repo
#                   if given and reachable, else initialized empty
#                   (wire up a remote later once you have git access).

set -eu

REPO_URL=
REPO_URL_DEFAULT=${DOTFILES_REPO_URL:-https://github.com/endotronic/dj.git}
PRIVATE_REPO_URL=${DOTFILES_PRIVATE_REPO_URL:-}
DOTFILES_DIR=$HOME/.dotfiles
DOT_DIR=$HOME/.config.git
PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
BACKUP_DIR=$HOME/.dotfiles-backup/$(date -u +%Y%m%dT%H%M%SZ)
TIER_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/system-type

SYSTEM_TYPE=
CONFLICT_MODE=ask
REMOVE_SOURCE=ask
AGE_KEY_SRC=
while [ $# -gt 0 ]; do
  case "$1" in
    --system-type)    shift; SYSTEM_TYPE=${1:-} ;;
    --system-type=*)  SYSTEM_TYPE=${1#*=} ;;
    --repo)           shift; REPO_URL=${1:-} ;;
    --repo=*)         REPO_URL=${1#*=} ;;
    --private-repo)   shift; PRIVATE_REPO_URL=${1:-} ;;
    --private-repo=*) PRIVATE_REPO_URL=${1#*=} ;;
    --on-conflict)    shift; CONFLICT_MODE=${1:-} ;;
    --on-conflict=*)  CONFLICT_MODE=${1#*=} ;;
    --remove-source)   shift; REMOVE_SOURCE=${1:-} ;;
    --remove-source=*) REMOVE_SOURCE=${1#*=} ;;
    --age-key)        shift; AGE_KEY_SRC=${1:-} ;;
    --age-key=*)      AGE_KEY_SRC=${1#*=} ;;
    -h|--help)
      cat <<EOF
Usage: install.sh [OPTIONS]

Bootstrap the dotfiles repo on this machine. Idempotent.

Options:
  --system-type {desktop|server}
        Pick a package tier; persists to ~/.config/dotfiles/system-type.
        Omit for the common-only set. Re-runs without the flag keep the
        existing tier.
  --repo URL
        Source for the public tooling repo (~/.dotfiles/). Resolution
        order:
          1. --repo (this flag), highest priority
          2. Auto-detected: if install.sh lives inside a clone of
             this repo (heuristic: install.sh + scripts/os-detect.sh
             at the toplevel), that clone is used in place
          3. \$DOTFILES_REPO_URL env var
          4. Built-in default (the public GitHub URL)
  --private-repo URL
        Source for your private bare repo (~/.config.git -- personal
        config + encrypted secrets, work-tree \$HOME). Optional: if
        omitted, or if the clone fails, an empty bare repo is
        initialized instead (wire up a remote later with
        'dot remote add origin <url>' once you have git access, then
        'dj sync'). For http(s):// URLs you'll be prompted
        interactively for a username and password -- never accepted
        as flags or env vars, so they stay out of argv and shell
        history. ssh:// / git@ URLs rely on key-based auth (agent or
        a pre-staged key).
  --on-conflict {ask|backup|keep|abort}
        How to handle files in \$HOME that differ in content from the
        tracked version. Default: 'ask' interactively; refuses to act
        non-interactively (curl-pipe-sh on a non-empty \$HOME must pass
        this flag explicitly). 'backup' moves your files to
        ~/.dotfiles-backup/<utc>/ and checks out the tracked versions.
        'keep' moves your files aside, checks out, then restores yours
        over the checked-out versions (tracked versions remain in the
        backup dir). 'abort' refuses to overwrite.
  --remove-source {ask|yes|no}
        When --repo points at a local directory (other than
        ~/.dotfiles itself), that clone becomes redundant once its
        content is cloned into ~/.dotfiles. 'ask' (default) prompts
        at the end of a successful install (or does nothing if
        non-interactive). 'yes' removes without prompting. 'no'
        always leaves the source intact. No-op when --repo is a
        remote URL or already points at ~/.dotfiles.
  --age-key PATH
        Path to an age private key file (keys.txt). Installs it to
        ~/.config/sops/age/keys.txt so that apply-secrets runs
        immediately during bootstrap. When omitted and the key is absent,
        an interactive install will prompt you to paste it; press Enter
        on a blank line to finish, or Enter immediately to skip.
  -h, --help
        Show this help.
EOF
      exit 0 ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

case "$SYSTEM_TYPE" in
  ''|desktop|server) ;;
  *)
    printf 'error: --system-type must be desktop, server, or omitted (got: %s)\n' \
      "$SYSTEM_TYPE" >&2
    exit 2 ;;
esac

case "$CONFLICT_MODE" in
  ask|backup|keep|abort) ;;
  *)
    printf 'error: --on-conflict must be ask|backup|keep|abort (got: %s)\n' \
      "$CONFLICT_MODE" >&2
    exit 2 ;;
esac

case "$REMOVE_SOURCE" in
  ask|yes|no) ;;
  *)
    printf 'error: --remove-source must be ask|yes|no (got: %s)\n' \
      "$REMOVE_SOURCE" >&2
    exit 2 ;;
esac

# ---------- 1. OS / package-manager detection (inlined for bootstrap) ----------

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)
    if [ -r /proc/version ] && grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
      OS=wsl
    else
      OS=linux
    fi ;;
  *) OS=unknown ;;
esac

PKG=
case "$OS" in
  darwin)
    command -v brew >/dev/null 2>&1 && PKG=brew ;;
  linux|wsl)
    if   command -v apt    >/dev/null 2>&1; then PKG=apt
    elif command -v pacman >/dev/null 2>&1; then PKG=pacman
    fi ;;
esac

if [ -z "$PKG" ]; then
  cat >&2 <<EOF
error: no supported package manager found.
  Expected one of: apt (Debian/Ubuntu/WSL), pacman (Arch), brew (macOS).
  Install one and re-run.
EOF
  exit 1
fi

log() { printf '[install] %s\n' "$*"; }

# A directory "looks like our repo" when it has the public tooling
# repo's recognizable shape at its toplevel (install.sh alongside
# scripts/os-detect.sh).
looks_like_our_repo() {
  [ -f "$1/install.sh" ] && [ -f "$1/scripts/os-detect.sh" ]
}

# Resolve REPO_URL (CLI > auto-detect > env > built-in default).
if [ -z "$REPO_URL" ]; then
  # Auto-detect: if this script's own location is inside a git work
  # tree that looks like our repo, use that toplevel as the source
  # (and, if it's already at ~/.dotfiles, it'll be used in place).
  if [ -f "$0" ]; then
    _script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || _script_dir=
    if [ -n "$_script_dir" ]; then
      _toplevel=$(git -C "$_script_dir" rev-parse --show-toplevel 2>/dev/null || true)
      if [ -n "$_toplevel" ] && looks_like_our_repo "$_toplevel"; then
        REPO_URL=$_toplevel
        log "auto-detected source repo: $REPO_URL"
      fi
    fi
    unset _script_dir _toplevel
  fi
fi
if [ -z "$REPO_URL" ]; then
  REPO_URL=$REPO_URL_DEFAULT
fi

log "OS=$OS PKG=$PKG TIER=${SYSTEM_TYPE:-none} REPO=$REPO_URL"

# ---------- 2. Bootstrap prerequisite: git ----------
# install-packages.sh handles the full set later; here we only need
# enough to clone the repo.

install_one() {
  pkg_bin=$1; pkg_actual=$2
  command -v "$pkg_bin" >/dev/null 2>&1 && return 0
  log "installing $pkg_actual"
  case "$PKG" in
    apt)    sudo apt-get update; sudo apt-get install -y "$pkg_actual" ;;
    pacman) sudo pacman -S --needed --noconfirm "$pkg_actual" ;;
    brew)   brew install "$pkg_actual" ;;
  esac
}

install_one git git

# ---------- 3. Persist system tier ----------

if [ -n "$SYSTEM_TYPE" ]; then
  mkdir -p "$(dirname "$TIER_FILE")"
  printf '%s\n' "$SYSTEM_TYPE" > "$TIER_FILE"
  log "persisted system-type=$SYSTEM_TYPE"
fi

# ---------- 4. Public tooling repo (~/.dotfiles/) ----------
#
# This is a normal (non-bare) clone, not the bare repo -- its files
# live at its own root (CLAUDE.md, scripts/, Justfile, ...), not
# prefixed under .dotfiles/. If install.sh is already running from a
# checkout that looks like ours, use it in place instead of cloning.

PUBLIC_LOCAL_SOURCE=
if [ -d "$REPO_URL" ]; then
  PUBLIC_LOCAL_SOURCE=$(CDPATH= cd -- "$REPO_URL" 2>/dev/null && pwd) || PUBLIC_LOCAL_SOURCE=
fi

PUBLIC_CLONED=0
if [ -d "$DOTFILES_DIR" ]; then
  log "using existing checkout at $DOTFILES_DIR"
  if ! looks_like_our_repo "$DOTFILES_DIR"; then
    log "warn: $DOTFILES_DIR doesn't look like the dotfiles repo (no install.sh / scripts/os-detect.sh)"
    log "warn: continuing anyway -- later steps that depend on it may be skipped"
  fi
  # If the resolved source IS this checkout, there's nothing to clean up.
  [ "$PUBLIC_LOCAL_SOURCE" = "$DOTFILES_DIR" ] && PUBLIC_LOCAL_SOURCE=
else
  log "cloning $REPO_URL into $DOTFILES_DIR"
  git clone "$REPO_URL" "$DOTFILES_DIR"
  PUBLIC_CLONED=1
fi

# A bare clone of a local path points its origin at that local path.
# A normal clone of a local path does the same. If the source had a
# real remote, rewire to that so future `git push` reaches the right
# place once this clone becomes the long-term checkout.
if [ "$PUBLIC_CLONED" -eq 1 ] && [ -n "$PUBLIC_LOCAL_SOURCE" ]; then
  _origin=$(git -C "$PUBLIC_LOCAL_SOURCE" remote get-url origin 2>/dev/null || true)
  if [ -n "$_origin" ]; then
    git -C "$DOTFILES_DIR" remote set-url origin "$_origin"
    log "rewired origin -> $_origin"
  fi
  unset _origin
fi

# ---------- 5. Private bare repo (~/.config.git) ----------
#
# Tracks personal config (~/.bashrc, ~/.config/**) and ~/.private/
# secrets, work-tree $HOME. It's private, so there's no public clone
# URL -- if --private-repo is given we try it (prompting for HTTP(S)
# credentials interactively, never via flags/env), and fall back to
# an empty bare repo on failure or absence. The empty repo can be
# wired up to a remote later: `dot remote add origin <url> && dj sync`.

dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

if [ -d "$DOT_DIR" ]; then
  log "using existing private repo at $DOT_DIR"
elif [ -n "$PRIVATE_REPO_URL" ]; then
  log "cloning private repo from $PRIVATE_REPO_URL into $DOT_DIR"
  case "$PRIVATE_REPO_URL" in
    http://*|https://*)
      if [ -t 0 ] && [ -t 1 ]; then
        printf '[install] private repo username: '
        read -r DOTFILES_GIT_USER
        printf '[install] private repo password: '
        stty -echo 2>/dev/null || true
        read -r DOTFILES_GIT_PASS || true
        stty echo 2>/dev/null || true
        printf '\n'

        _askpass=$(mktemp)
        # Single-quoted heredoc: $1/$DOTFILES_GIT_* stay literal
        # variable references in the file, resolved from the
        # environment at run time -- the script on disk never
        # contains the credential values themselves.
        cat > "$_askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *sername*) printf '%s' "$DOTFILES_GIT_USER" ;;
  *assword*) printf '%s' "$DOTFILES_GIT_PASS" ;;
esac
EOF
        chmod 700 "$_askpass"
        export DOTFILES_GIT_USER DOTFILES_GIT_PASS
        if GIT_ASKPASS="$_askpass" git clone --bare "$PRIVATE_REPO_URL" "$DOT_DIR"; then
          log "cloned private repo"
        else
          rm -rf "$DOT_DIR"
          log "warn: clone of private repo failed; initializing empty instead"
        fi
        unset DOTFILES_GIT_USER DOTFILES_GIT_PASS
        rm -f "$_askpass"
        unset _askpass
      else
        log "warn: non-interactive shell; cannot prompt for git credentials"
        log "warn: skipping private-repo clone; initializing empty instead"
      fi
      ;;
    *)
      if git clone --bare "$PRIVATE_REPO_URL" "$DOT_DIR"; then
        log "cloned private repo"
      else
        rm -rf "$DOT_DIR"
        log "warn: clone of private repo failed; initializing empty instead"
      fi
      ;;
  esac
fi

if [ ! -d "$DOT_DIR" ]; then
  log "initializing empty private repo at $DOT_DIR"
  git init --bare -q "$DOT_DIR"
  log "wire it up later: dot remote add origin <url> && dj sync"
fi

dot config status.showUntrackedFiles no

# ---------- 6. Conflict-aware checkout (only if the private repo has commits) ----------
#
# Walk every tracked path. For each path that currently exists in
# $HOME, classify it:
#   - identical: content matches HEAD; safe to silently remove
#                (git will re-create with the same content)
#   - symlink:   present as a symlink at a tracked-file path;
#                always moved to the backup dir before checkout
#   - conflict:  different content; behavior controlled by
#                --on-conflict {ask|backup|keep|abort}
#
# A freshly-initialized empty bare repo has no HEAD -- nothing to
# check out yet, so skip this entirely.

if dot rev-parse --verify -q HEAD >/dev/null 2>&1; then

identical=$(mktemp)
conflicts=$(mktemp)
symlinks=$(mktemp)
trap 'rm -f "$identical" "$conflicts" "$symlinks"' EXIT INT TERM

dot ls-tree --full-tree -r --name-only HEAD 2>/dev/null | while IFS= read -r f; do
  [ -z "$f" ] && continue
  src=$HOME/$f
  [ -e "$src" ] || [ -L "$src" ] || continue
  if [ -L "$src" ]; then
    printf '%s\n' "$f" >> "$symlinks"
  elif dot show "HEAD:$f" 2>/dev/null | cmp -s - "$src" 2>/dev/null; then
    printf '%s\n' "$f" >> "$identical"
  else
    printf '%s\n' "$f" >> "$conflicts"
  fi
done

n_conflicts=$(awk 'END { print NR+0 }' "$conflicts")
n_identical=$(awk 'END { print NR+0 }' "$identical")
n_symlinks=$(awk 'END { print NR+0 }' "$symlinks")

log "checkout: identical=$n_identical conflicts=$n_conflicts symlinks=$n_symlinks"
if [ "$n_conflicts" -gt 0 ]; then
  log 'conflicting files:'
  sed 's/^/  /' < "$conflicts"
fi

# Decide on conflict handling first; if aborting, exit before any side
# effects (no removals, no moves, no checkout).
if [ "$n_conflicts" -eq 0 ]; then
  log 'no conflicts'
  decision=clean
else
  mode=$CONFLICT_MODE
  if [ "$mode" = ask ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      printf '\n[install] choose: (b)ackup-and-overwrite, (k)eep-yours, (a)bort [b]: '
      read -r ans || ans=
      case "${ans:-b}" in
        b|B|backup) mode=backup ;;
        k|K|keep)   mode=keep ;;
        *)          mode=abort ;;
      esac
    else
      cat >&2 <<EOF
[install] non-interactive shell; refusing to overwrite. Re-run with one of:
[install]   --on-conflict backup   move yours to $BACKUP_DIR, then check out
[install]   --on-conflict keep     keep yours; tracked versions go to backup
[install]   --on-conflict abort    do nothing
EOF
      exit 1
    fi
  fi
  decision=$mode

  case "$decision" in
    abort)
      log 'aborting per user request'
      exit 1 ;;
    backup|keep) ;;
    *)
      printf 'error: unexpected conflict decision: %s\n' "$decision" >&2
      exit 2 ;;
  esac
fi

# Past this point we're committed to checking out. Clear the work
# tree of anything that would prevent the checkout.

if [ "$n_conflicts" -gt 0 ]; then
  mkdir -p "$BACKUP_DIR"
  log "moving $n_conflicts conflict(s) to $BACKUP_DIR"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    target=$BACKUP_DIR/$f
    mkdir -p "$(dirname "$target")"
    mv "$HOME/$f" "$target"
  done < "$conflicts"
fi

if [ "$n_symlinks" -gt 0 ]; then
  mkdir -p "$BACKUP_DIR"
  log "moving $n_symlinks symlink(s) at tracked paths to $BACKUP_DIR"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    target=$BACKUP_DIR/$f
    mkdir -p "$(dirname "$target")"
    mv "$HOME/$f" "$target"
  done < "$symlinks"
fi

if [ "$n_identical" -gt 0 ]; then
  log "removing $n_identical identical file(s) (no data loss; same as HEAD)"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rm -f "$HOME/$f"
  done < "$identical"
fi

( cd "$HOME" && dot checkout HEAD -- . )

if [ "$n_conflicts" -gt 0 ] && [ "$decision" = keep ]; then
  log 'restoring your versions over the checked-out files'
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    cp -p "$BACKUP_DIR/$f" "$HOME/$f"
  done < "$conflicts"
  log "your \$HOME files unchanged; tracked versions saved in $BACKUP_DIR"
  log "'dot status' will show these as modified (expected)"
fi

else
  log "private repo has no commits yet; nothing to check out"
fi

# ---------- 7. Install pre-commit hook (if present) ----------

HOOK_SRC=$HOME/.dotfiles/scripts/pre-commit-secrets.sh
HOOK_DST=$DOT_DIR/hooks/pre-commit
if [ -f "$HOOK_SRC" ]; then
  mkdir -p "$DOT_DIR/hooks"
  ln -sf "$HOOK_SRC" "$HOOK_DST"
  chmod +x "$HOOK_SRC"
  log "linked pre-commit hook -> $HOOK_SRC"
fi

# ---------- 8. Full package install ----------

if [ -x "$HOME/.dotfiles/scripts/install-packages.sh" ]; then
  log "running install-packages.sh"
  sh "$HOME/.dotfiles/scripts/install-packages.sh"
fi

# Ensure ~/.local/bin is in PATH before calling install-claude.sh so
# the post-install verification can find the just-installed binary.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac

# Claude Code isn't shipped through apt/pacman/brew, so it has its
# own installer script (vendor curl-pipe). Idempotent: no-op if
# `claude` is already on PATH.
if [ -x "$HOME/.dotfiles/scripts/install-claude.sh" ]; then
  log "running install-claude.sh"
  sh "$HOME/.dotfiles/scripts/install-claude.sh"
fi

if [ -x "$HOME/.dotfiles/scripts/install-gemini.sh" ]; then
  log "running install-gemini.sh"
  sh "$HOME/.dotfiles/scripts/install-gemini.sh" \
    || log "warn: gemini install failed; skipping (non-fatal)"
fi

# ---------- 9. Install age key (if provided via flag or interactive paste) ---

AGE_KEY=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt

if [ ! -r "$AGE_KEY" ]; then
  if [ -n "$AGE_KEY_SRC" ]; then
    if [ ! -r "$AGE_KEY_SRC" ]; then
      log "warn: --age-key path not readable: $AGE_KEY_SRC; skipping"
    else
      mkdir -p "$(dirname "$AGE_KEY")"
      cp "$AGE_KEY_SRC" "$AGE_KEY"
      chmod 0600 "$AGE_KEY"
      log "installed age key from $AGE_KEY_SRC"
    fi
  elif [ -t 0 ] && [ -t 1 ]; then
    printf '\n[install] Age key not found at %s\n' "$AGE_KEY"
    printf '[install] Paste your age key (press Enter on a blank line when done,\n'
    printf '[install] or just press Enter to skip and apply secrets later):\n'
    key_content=
    while IFS= read -r _line; do
      [ -z "$_line" ] && break
      key_content="${key_content}${_line}
"
    done || true
    if [ -n "$key_content" ]; then
      mkdir -p "$(dirname "$AGE_KEY")"
      printf '%s' "$key_content" > "$AGE_KEY"
      chmod 0600 "$AGE_KEY"
      log "wrote age key to $AGE_KEY"
    else
      log "no age key provided; skipping secrets"
      log "transport the age key, then run: just apply-secrets"
    fi
  fi
fi

# ---------- 10. Initialize SOPS/age (generate key + .sops.yaml if absent) -----

if [ -x "$HOME/.dotfiles/scripts/sops-init.sh" ]; then
  if command -v sops >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    mkdir -p "$PRIVATE_DIR"
    PRIVATE_DIR="$PRIVATE_DIR" sh "$HOME/.dotfiles/scripts/sops-init.sh"
  else
    log "sops or age-keygen not on PATH; skipping SOPS init"
    log "install them, then run: dj sops-init"
  fi
fi

# ---------- 11. Apply secrets (only if age key is present) ----------

if [ -r "$AGE_KEY" ] && [ -x "$HOME/.dotfiles/scripts/rebuild-secrets.sh" ]; then
  log "rematerializing secrets"
  PRIVATE_DIR="$PRIVATE_DIR" sh "$HOME/.dotfiles/scripts/rebuild-secrets.sh"
elif [ ! -r "$AGE_KEY" ]; then
  log "no age key at $AGE_KEY -- skipping secrets"
  log "transport the age key, then run: dj apply-secrets"
fi

# ---------- 12. Optional cleanup of local public-repo source clone ----------

# If --repo was a local directory other than ~/.dotfiles itself, that
# source clone is now redundant -- its content lives in $DOTFILES_DIR.
# Honor --remove-source: yes deletes, no leaves alone, ask prompts.
if [ -n "$PUBLIC_LOCAL_SOURCE" ] && [ "$PUBLIC_LOCAL_SOURCE" != "$HOME" ]; then
  log "source clone at $PUBLIC_LOCAL_SOURCE is now redundant"
  log "(the checkout at $DOTFILES_DIR is your source of truth from here on)"
  remove_source_clone() {
    # If the invoking shell's cwd is inside the source clone (e.g. the
    # user ran `cd ~/temp && sh ~/.dotfiles/install.sh ...`), step out
    # *in this shell* first -- a subshell `cd` wouldn't help: removing
    # the real cwd out from under the parent shell leaves it unable to
    # getcwd() for any command it runs afterward (clone, sh, git, ...).
    case "$(pwd -P 2>/dev/null || true)" in
      "$PUBLIC_LOCAL_SOURCE"|"$PUBLIC_LOCAL_SOURCE"/*) cd "$HOME" ;;
    esac
    rm -rf "$PUBLIC_LOCAL_SOURCE" \
      && log "removed $PUBLIC_LOCAL_SOURCE" \
      || log "warn: failed to remove $PUBLIC_LOCAL_SOURCE"
  }
  case "$REMOVE_SOURCE" in
    yes) remove_source_clone ;;
    no)  log "leaving source clone in place (--remove-source no)" ;;
    ask)
      if [ -t 0 ] && [ -t 1 ]; then
        printf '\n[install] remove source clone %s? [y/N]: ' "$PUBLIC_LOCAL_SOURCE"
        read -r ans || ans=
        case "$ans" in
          y|Y|yes) remove_source_clone ;;
          *)       log "leaving source clone in place" ;;
        esac
      else
        log "non-interactive; not prompting. To clean up: rm -rf $PUBLIC_LOCAL_SOURCE"
      fi ;;
  esac
fi

# ---------- 13. Offer shell consolidation ----------

if [ -x "$HOME/.dotfiles/scripts/shell-consolidate.sh" ] && [ -d "$DOT_DIR" ]; then
  sh "$HOME/.dotfiles/scripts/shell-consolidate.sh"
fi

# ---------- 14. Git identity, SSH key, GPG key ----------

if [ -x "$HOME/.dotfiles/scripts/git-setup.sh" ]; then
  sh "$HOME/.dotfiles/scripts/git-setup.sh"
fi

# ---------- 15. Done ----------

cat <<EOF

[install] bootstrap complete.

next steps:
  1. reload your shell:  . ~/.bashrc   (or . ~/.zshrc on zsh)
  2. 'dj doctor' for sanity checks
EOF
