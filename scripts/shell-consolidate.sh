#!/bin/sh
# Consolidate shell config into the shared POSIX layer.
#
# Usage: shell-consolidate.sh [--yes | --no]
#
# Two modes:
#   migrate  .bashrc/.zshrc exists but isn't a thin loader — original
#            content is preserved to .config/{bash,zsh}/init.sh
#   create   no .bashrc/.zshrc — a fresh structured config is written
#
# In either case the shared POSIX layer (~/.config/shell/) is created
# and everything is staged in the private bare repo.
#
# Fails BEFORE making any changes if any output file already exists.

set -eu

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
CONSOLIDATE=ask

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) CONSOLIDATE=yes ;;
    --no)  CONSOLIDATE=no ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

log() { printf '[shell-consolidate] %s\n' "$*"; }
dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

# True if we can prompt the user, even when stdin is consumed by a
# pipe (curl | sh): requires stdout to be a terminal and /dev/tty to
# be openable for reading. Reads in the calling block should
# redirect from `/dev/tty` directly (a regular builtin like `read`,
# so a redirection failure there is a normal nonzero exit -- unlike
# `exec`, which would abort the whole script under `set -e`).
can_prompt() {
  [ -t 1 ] && true 2>/dev/null </dev/tty
}

is_thin_loader() {
  grep -q '\.config/shell/init\.sh' "$1" 2>/dev/null
}

# ---------- Detect what needs doing ----------

needs_bash_migrate=
needs_bash_create=
needs_zsh_migrate=
needs_zsh_create=

if command -v bash >/dev/null 2>&1; then
  if [ -f "$HOME/.bashrc" ]; then
    is_thin_loader "$HOME/.bashrc" || needs_bash_migrate=1
  else
    needs_bash_create=1
  fi
fi

if command -v zsh >/dev/null 2>&1; then
  if [ -f "$HOME/.zshrc" ]; then
    is_thin_loader "$HOME/.zshrc" || needs_zsh_migrate=1
  else
    needs_zsh_create=1
  fi
fi

[ -z "$needs_bash_migrate" ] && [ -z "$needs_bash_create" ] && \
[ -z "$needs_zsh_migrate"  ] && [ -z "$needs_zsh_create"  ] && exit 0

# Bare repo must exist for staging.
if [ ! -d "$DOT_DIR" ]; then
  log "no bare repo at $DOT_DIR; skipping"
  exit 0
fi

[ "$CONSOLIDATE" = no ] && exit 0

if [ "$CONSOLIDATE" = ask ]; then
  if can_prompt; then
    printf '\n[shell-consolidate] Shell config to set up:\n'
    [ -n "$needs_bash_migrate" ] && \
      printf '  bash: .bashrc exists — migrate to .config/bash/init.sh\n'
    [ -n "$needs_bash_create"  ] && \
      printf '  bash: no .bashrc — create fresh structured config\n'
    [ -n "$needs_zsh_migrate"  ] && \
      printf '  zsh:  .zshrc exists — migrate to .config/zsh/init.sh\n'
    [ -n "$needs_zsh_create"   ] && \
      printf '  zsh:  no .zshrc — create fresh structured config\n'
    printf '[shell-consolidate] Set up ~/.config/{shell,bash,zsh}/? [Y/n]: '
    read -r _ans </dev/tty || _ans=y
    case "${_ans:-y}" in
      y|Y|yes|YES) ;;
      *) log "skipped"; exit 0 ;;
    esac
  else
    log "non-interactive; skipping (pass --yes to consolidate without a prompt)"
    exit 0
  fi
fi

# ---------- Conflict check: fail before touching anything ----------

shell_dir="$HOME/.config/shell"
bash_dir="$HOME/.config/bash"
zsh_dir="$HOME/.config/zsh"

_conflicts=
_chk() { [ -e "$1" ] && _conflicts="${_conflicts} $1" || true; }

# Shared layer (always created)
_chk "$shell_dir/init.sh"
_chk "$shell_dir/env.sh"
_chk "$shell_dir/aliases.sh"
_chk "$shell_dir/functions.sh"
_chk "$shell_dir/secrets.sh"
_chk "$shell_dir/os/linux.sh"
_chk "$shell_dir/os/darwin.sh"
_chk "$shell_dir/os/wsl.sh"

if [ -n "$needs_bash_migrate" ] || [ -n "$needs_bash_create" ]; then
  _chk "$bash_dir/init.sh"
fi
if [ -n "$needs_bash_create" ]; then
  _chk "$HOME/.bashrc"
  _chk "$bash_dir/completion.sh"
  _chk "$bash_dir/prompt.sh"
  _chk "$bash_dir/functions.sh"
fi

if [ -n "$needs_zsh_migrate" ] || [ -n "$needs_zsh_create" ]; then
  _chk "$zsh_dir/init.sh"
fi
if [ -n "$needs_zsh_create" ]; then
  _chk "$HOME/.zshrc"
  _chk "$zsh_dir/completion.zsh"
  _chk "$zsh_dir/prompt.zsh"
  _chk "$zsh_dir/functions.zsh"
fi

if [ -n "$_conflicts" ]; then
  printf '[shell-consolidate] error: these files already exist — no changes made:\n'
  for _f in $_conflicts; do
    printf '  %s\n' "$_f"
  done
  printf '[shell-consolidate] Remove or back them up and try again.\n'
  exit 1
fi

# ---------- Shared POSIX layer ----------

mkdir -p "$shell_dir/os" "$shell_dir/host"

cat > "$shell_dir/init.sh" << 'INIT_SH'
# Shared POSIX shell init. Sourced by both .bashrc and .zshrc before
# each shell's own init. Must remain POSIX: no [[, local, arrays,
# or function name() syntax.

if [ -r "$HOME/.dotfiles/scripts/os-detect.sh" ]; then
  . "$HOME/.dotfiles/scripts/os-detect.sh"
fi

_dotfiles_shell_dir="$HOME/.config/shell"

for _dotfiles_f in \
  "$_dotfiles_shell_dir/env.sh" \
  "$_dotfiles_shell_dir/aliases.sh" \
  "$_dotfiles_shell_dir/functions.sh" \
  "$_dotfiles_shell_dir/os/${DOTFILES_OS:-unknown}.sh" \
  "$_dotfiles_shell_dir/host/$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo unknown).sh" \
  "$_dotfiles_shell_dir/secrets.sh"
do
  [ -r "$_dotfiles_f" ] && . "$_dotfiles_f"
done

unset _dotfiles_shell_dir _dotfiles_f
INIT_SH

cat > "$shell_dir/env.sh" << 'ENV_SH'
# Environment exports. POSIX only -- no bashisms/zshisms.

_dotfiles_prepend_path() {
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}
_dotfiles_prepend_path "$HOME/.local/bin"
_dotfiles_prepend_path "$HOME/.dotfiles/scripts"
unset -f _dotfiles_prepend_path 2>/dev/null || true
export PATH

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
ENV_SH

cat > "$shell_dir/aliases.sh" << 'ALIASES_SH'
# Shared aliases. POSIX only -- no bashisms/zshisms.

# `dot`: operate on the private bare dotfiles repo (work-tree $HOME).
# `dot status` is intentionally blind to untracked files
# (status.showUntrackedFiles=no) -- use dot_add/dot-add to discover and
# stage new files.
alias dot='git --git-dir="$HOME/.config.git" --work-tree="$HOME"'
ALIASES_SH

cat > "$shell_dir/functions.sh" << 'FUNCTIONS_SH'
# Shared functions. POSIX only -- no bashisms/zshisms.

# `dot_add <path>`: stage a file from $HOME into the private bare repo.
# Necessary because `dot status` is intentionally blind to untracked
# files, so you can't discover what's not yet tracked.
dot_add() {
  if [ $# -eq 0 ]; then
    printf 'usage: dot_add <path> [<path> ...]\n' >&2
    return 2
  fi
  git --git-dir="$HOME/.config.git" --work-tree="$HOME" add "$@" \
    && git --git-dir="$HOME/.config.git" --work-tree="$HOME" status
}
# Convenience: an alias-friendly hyphenated name.
alias dot-add='dot_add'

# `mkcd <dir>`: mkdir -p and cd into it.
mkcd() {
  [ $# -eq 1 ] || { printf 'usage: mkcd <dir>\n' >&2; return 2; }
  mkdir -p -- "$1" && cd -- "$1"
}

# `dj [args...]`: run `just` against the dotfiles Justfile from anywhere.
dj() {
  JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just "$@"
}
FUNCTIONS_SH
printf '# Sourced last; load decrypted secrets into the environment here.\n' \
  > "$shell_dir/secrets.sh"

for _os in linux darwin wsl; do
  printf '# OS-specific init for %s. POSIX only.\n' "$_os" \
    > "$shell_dir/os/$_os.sh"
done
unset _os

touch "$shell_dir/host/.gitkeep"
log "created shared POSIX layer at $shell_dir/"

# ---------- Bash ----------

if [ -n "$needs_bash_migrate" ] || [ -n "$needs_bash_create" ]; then
  mkdir -p "$bash_dir"

  if [ -n "$needs_bash_migrate" ]; then
    # Preserve existing .bashrc content in the bash-specific init.
    cp "$HOME/.bashrc" "$bash_dir/init.sh"
    log "preserved .bashrc → $bash_dir/init.sh"
  else
cat > "$bash_dir/init.sh" << 'BASH_INIT'
# Bash-only init. Sourced from ~/.bashrc after the shared layer.
# Bashisms are fine here.

HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT='%F %T '
shopt -s histappend checkwinsize
shopt -s globstar   2>/dev/null || true
shopt -s nocaseglob 2>/dev/null || true

_bash_dir="$HOME/.config/bash"
for f in "$_bash_dir/completion.sh" "$_bash_dir/functions.sh" \
         "$_bash_dir/prompt.sh"; do
  [ -r "$f" ] && . "$f"
done
unset _bash_dir f
BASH_INIT

cat > "$bash_dir/completion.sh" << 'BASH_COMP'
# Bash completion. Sourced from ~/.config/bash/init.sh.

for f in \
  /usr/share/bash-completion/bash_completion \
  /etc/bash_completion \
  /opt/homebrew/etc/profile.d/bash_completion.sh \
  /usr/local/etc/profile.d/bash_completion.sh
do
  if [ -r "$f" ]; then . "$f"; break; fi
done
unset f

if command -v fzf >/dev/null 2>&1; then
  if command -v fzf-share >/dev/null 2>&1; then
    . "$(fzf-share)/key-bindings.bash" 2>/dev/null || true
    . "$(fzf-share)/completion.bash"   2>/dev/null || true
  else
    for f in \
      /usr/share/fzf/key-bindings.bash \
      /usr/share/doc/fzf/examples/key-bindings.bash \
      /opt/homebrew/opt/fzf/shell/key-bindings.bash
    do
      [ -r "$f" ] && . "$f" && break
    done
    for f in \
      /usr/share/fzf/completion.bash \
      /usr/share/doc/fzf/examples/completion.bash \
      /opt/homebrew/opt/fzf/shell/completion.bash
    do
      [ -r "$f" ] && . "$f" && break
    done
    unset f
  fi
fi
BASH_COMP

cat > "$bash_dir/prompt.sh" << 'BASH_PROMPT'
# Bash prompt. Uses starship if installed; otherwise a minimal PS1.
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
else
  PS1='\[\e[32m\]\u@\h\[\e[0m\] \[\e[34m\]\w\[\e[0m\] \$ '
fi
BASH_PROMPT

    printf '# Bash-specific functions. Bashisms welcome.\n' > "$bash_dir/functions.sh"
    log "created fresh bash config at $bash_dir/"
  fi

cat > "$HOME/.bashrc" << 'BASHRC'
# Interactive bash. Tiny loader -- real config lives in
# ~/.config/shell/ (shared with zsh) and ~/.config/bash/ (bash-only).

# Only run interactive bits when interactive.
case $- in *i*) ;; *) return ;; esac

[ -r "$HOME/.config/shell/init.sh" ] && . "$HOME/.config/shell/init.sh"
[ -r "$HOME/.config/bash/init.sh"  ] && . "$HOME/.config/bash/init.sh"
BASHRC

  if [ ! -f "$HOME/.bash_profile" ] || \
     ! grep -q '\.bashrc' "$HOME/.bash_profile" 2>/dev/null; then
cat > "$HOME/.bash_profile" << 'BASH_PROFILE'
# Login shells don't read .bashrc by default. Source it here.
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
BASH_PROFILE
  fi

  dot add "$HOME/.bashrc" "$HOME/.bash_profile" "$bash_dir/"
  log "consolidated bash config"
fi

# ---------- Zsh ----------

if [ -n "$needs_zsh_migrate" ] || [ -n "$needs_zsh_create" ]; then
  mkdir -p "$zsh_dir"

  if [ -n "$needs_zsh_migrate" ]; then
    cp "$HOME/.zshrc" "$zsh_dir/init.sh"
    log "preserved .zshrc → $zsh_dir/init.sh"
  else
cat > "$zsh_dir/init.sh" << 'ZSH_INIT'
# Zsh-only init. Sourced from ~/.zshrc after the shared layer.
# Zshisms are fine here.

HISTSIZE=100000
SAVEHIST=200000
HISTFILE="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history"
mkdir -p "$(dirname "$HISTFILE")"

setopt APPEND_HISTORY INC_APPEND_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS \
       HIST_IGNORE_SPACE HIST_REDUCE_BLANKS SHARE_HISTORY EXTENDED_HISTORY \
       INTERACTIVE_COMMENTS NO_BEEP AUTO_CD EXTENDED_GLOB

_zsh_dir="$HOME/.config/zsh"
for f in "$_zsh_dir/completion.zsh" "$_zsh_dir/functions.zsh" \
         "$_zsh_dir/prompt.zsh"; do
  [ -r "$f" ] && . "$f"
done
unset _zsh_dir f
ZSH_INIT

cat > "$zsh_dir/completion.zsh" << 'ZSH_COMP'
# Zsh completion. Sourced from ~/.config/zsh/init.sh.

autoload -Uz compinit
_compdump="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/zcompdump"
mkdir -p "$(dirname "$_compdump")"
compinit -d "$_compdump"
unset _compdump

zstyle ':completion:*' matcher-list \
  'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' menu select

if command -v fzf >/dev/null 2>&1; then
  if command -v fzf-share >/dev/null 2>&1; then
    . "$(fzf-share)/key-bindings.zsh" 2>/dev/null || true
    . "$(fzf-share)/completion.zsh"   2>/dev/null || true
  else
    for f in \
      /usr/share/fzf/key-bindings.zsh \
      /usr/share/doc/fzf/examples/key-bindings.zsh \
      /opt/homebrew/opt/fzf/shell/key-bindings.zsh
    do
      [ -r "$f" ] && . "$f" && break
    done
    for f in \
      /usr/share/fzf/completion.zsh \
      /usr/share/doc/fzf/examples/completion.zsh \
      /opt/homebrew/opt/fzf/shell/completion.zsh
    do
      [ -r "$f" ] && . "$f" && break
    done
    unset f
  fi
fi
ZSH_COMP

cat > "$zsh_dir/prompt.zsh" << 'ZSH_PROMPT'
# Zsh prompt. Uses starship if installed; otherwise a minimal PROMPT.
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
else
  autoload -Uz colors && colors
  PROMPT='%F{green}%n@%m%f %F{blue}%~%f %# '
fi
ZSH_PROMPT

    printf '# Zsh-specific functions. Zshisms welcome.\n' > "$zsh_dir/functions.zsh"
    log "created fresh zsh config at $zsh_dir/"
  fi

cat > "$HOME/.zshrc" << 'ZSHRC'
# Interactive zsh. Tiny loader -- real config lives in
# ~/.config/shell/ (shared with bash) and ~/.config/zsh/ (zsh-only).

[ -r "$HOME/.config/shell/init.sh" ] && . "$HOME/.config/shell/init.sh"
[ -r "$HOME/.config/zsh/init.sh"   ] && . "$HOME/.config/zsh/init.sh"
ZSHRC

  if [ ! -f "$HOME/.zprofile" ] || \
     ! grep -q '\.zshrc' "$HOME/.zprofile" 2>/dev/null; then
cat > "$HOME/.zprofile" << 'ZPROFILE'
# Login zsh. Source .zshrc so it stays the single entry point.
[ -r "$HOME/.zshrc" ] && . "$HOME/.zshrc"
ZPROFILE
  fi

  dot add "$HOME/.zshrc" "$HOME/.zprofile" "$zsh_dir/"
  log "consolidated zsh config"
fi

dot add "$shell_dir/"
log "done. Review with 'dot diff --cached', then 'dot commit'."
