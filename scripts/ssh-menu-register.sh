#!/bin/sh
# Offer to add a machine's SSH connection info to ~/.ssh/config, grouped
# into a section by system type, so it shows up in the tmux "NEW" popup
# menu on every machine that has this one in its ~/.ssh/config (see
# ~/.config/tmux/scripts/gen-ssh-menu.sh, which treats full-line
# comments in ~/.ssh/config as section headers and groups the Host
# entries below them).
#
# Usage:
#   ssh-menu-register.sh [--yes|--no] [--type TYPE] [--alias NAME]
#                         [--hostname HOST] [--user USER]
#
# --type omitted falls back to the persisted
# ~/.config/dotfiles/system-type -- correct when this script runs on
# the machine being registered (install.sh's own use). A caller
# registering some *other* machine (dj-setup.sh, registering the
# target it just bootstrapped) must pass --type explicitly -- the
# local system-type here would be the wrong (calling) machine's.
#
# The section title shown for a type is looked up in
# ~/.config/dj/ssh-menu-sections.txt (private repo, alongside the
# personal package/postinstall lists) -- one "type Title Words" line
# per type, e.g. "vm VMs". A type with no entry there falls back to
# Ucfirst(type) + "s" (e.g. "laptop" -> "Laptops"); that naive
# pluralization is exactly why acronym-shaped types (vm -> "VMs", not
# "Vms") are worth an explicit line in the sections file rather than
# relying on the default every time.
#
# --yes accepts without the interactive confirmation prompt (still
# prompts for any of alias/hostname/user left unspecified, unless
# stdin isn't a tty -- see can_prompt). --no is a no-op, useful for
# callers that want to pass this flag unconditionally rather than
# branch. Default (no flag) is 'ask': skipped entirely when not
# attached to a terminal.
#
# Idempotent: does nothing if a Host with this alias already appears
# anywhere in ~/.ssh/config. Stages the file with `dot add` when the
# private repo is present -- committing/pushing (and 'dj sync' on
# other machines to pick it up) is left to the caller, same as every
# other script here.

set -eu

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
SSH_CONFIG=$HOME/.ssh/config
SECTIONS_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/dj/ssh-menu-sections.txt
TIER_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/system-type

MODE=ask
TYPE=
TYPE_GIVEN=0
ALIAS=
TARGET_HOST=
TARGET_USER=

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) MODE=yes ;;
    --no)  MODE=no ;;
    --type)       shift; TYPE=${1:-}; TYPE_GIVEN=1 ;;
    --type=*)     TYPE=${1#*=}; TYPE_GIVEN=1 ;;
    --alias)      shift; ALIAS=${1:-} ;;
    --alias=*)    ALIAS=${1#*=} ;;
    --hostname)   shift; TARGET_HOST=${1:-} ;;
    --hostname=*) TARGET_HOST=${1#*=} ;;
    --user)       shift; TARGET_USER=${1:-} ;;
    --user=*)     TARGET_USER=${1#*=} ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

log() { printf '[ssh-menu-register] %s\n' "$*"; }
dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

# True if we can prompt the user, even when stdin is consumed by a
# pipe (curl | sh): requires stdout to be a terminal and /dev/tty to
# be openable for reading.
can_prompt() {
  [ -t 1 ] && true 2>/dev/null </dev/tty
}

[ "$MODE" = no ] && exit 0

# Only consult the local system-type when --type was never passed at
# all -- an explicit "--type ''" (dj-setup.sh registering a target it
# just set up with no --system-type, i.e. common-only) must NOT fall
# back to reading *this* machine's own type instead.
[ "$TYPE_GIVEN" -eq 1 ] || TYPE=$(cat "$TIER_FILE" 2>/dev/null || true)

if [ "$MODE" = ask ]; then
  can_prompt || exit 0
  printf '\n[ssh-menu-register] Add this machine to ~/.ssh/config so it shows up in the tmux NEW menu on your other machines? [y/N]: '
  read -r _confirm_ans </dev/tty || _confirm_ans=
  case "$_confirm_ans" in
    y|Y|yes) ;;
    *) log "skipped"; exit 0 ;;
  esac
fi

# ---------- Resolve alias / hostname / user, prompting for anything missing --

if can_prompt; then
  if [ -z "$ALIAS" ]; then
    _default_alias=${TARGET_HOST%%.*}
    [ -n "$_default_alias" ] || _default_alias=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo host)
    printf '[ssh-menu-register] alias (short name for the menu and `ssh <alias>`) [%s]: ' "$_default_alias"
    read -r _in </dev/tty || _in=
    ALIAS=${_in:-$_default_alias}
  fi
  if [ -z "$TARGET_HOST" ]; then
    printf '[ssh-menu-register] hostname/IP other machines should use to reach this one: '
    read -r _in </dev/tty || _in=
    TARGET_HOST=$_in
  fi
  if [ -z "$TARGET_USER" ]; then
    _default_user=$(id -un 2>/dev/null || whoami 2>/dev/null || echo "${USER:-}")
    printf '[ssh-menu-register] ssh user [%s]: ' "$_default_user"
    read -r _in </dev/tty || _in=
    TARGET_USER=${_in:-$_default_user}
  fi
else
  [ -n "$ALIAS" ] || ALIAS=${TARGET_HOST%%.*}
fi

if [ -z "$ALIAS" ] || [ -z "$TARGET_HOST" ]; then
  log "no alias/hostname available (non-interactive and not passed); skipping"
  exit 0
fi

case "$ALIAS" in
  *[!A-Za-z0-9_.-]*)
    log "warn: alias must contain only letters, digits, . _ and - (got: $ALIAS); skipping"
    exit 0 ;;
esac

# ---------- Idempotency: skip if this alias already appears in ~/.ssh/config --
#
# Same "Host" line shape gen-ssh-menu.sh parses: any of the
# space-separated targets on a Host line, exact match.

if [ -f "$SSH_CONFIG" ] && awk -v h="$ALIAS" '
    tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == h) { found = 1; exit } }
    END { exit(found ? 0 : 1) }
  ' "$SSH_CONFIG"; then
  log "Host $ALIAS is already in $SSH_CONFIG; leaving it alone"
  exit 0
fi

# ---------- Section title for this type ----------

resolve_title() {
  [ -n "$TYPE" ] || return 0
  if [ -r "$SECTIONS_FILE" ]; then
    _t=$(awk -v k="$TYPE" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$SECTIONS_FILE")
    if [ -n "$_t" ]; then
      printf '%s' "$_t"
      return 0
    fi
  fi
  printf '%s' "$TYPE" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) "s" }'
}

TITLE=$(resolve_title)
[ -n "$TITLE" ] || TITLE="Other"

# ---------- Build the new Host block ----------

BLOCK=$(mktemp)
trap 'rm -f "$BLOCK"' EXIT INT TERM
{
  printf 'Host %s\n' "$ALIAS"
  printf '    HostName %s\n' "$TARGET_HOST"
  [ -n "$TARGET_USER" ] && printf '    User %s\n' "$TARGET_USER"
  printf '\n'
} > "$BLOCK"

# ---------- Insert under the matching section header, appending a new --
# ---------- section at EOF if no header with this title exists yet -----
#
# Single pass: track whether we're currently inside the target
# section (its full-line-comment header text matched $TITLE), and
# flush the new block right before whatever ends that section -- the
# next header, or EOF if the file has no headers after it.

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
TMP=$(mktemp)

in_target=0
inserted=0
if [ -f "$SSH_CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$stripped" in
      '#'*)
        if [ "$in_target" -eq 1 ] && [ "$inserted" -eq 0 ]; then
          cat "$BLOCK" >> "$TMP"
          inserted=1
        fi
        hdr=$(printf '%s' "$stripped" | sed 's/^#\+[[:space:]]*//')
        if [ "$hdr" = "$TITLE" ]; then in_target=1; else in_target=0; fi
        ;;
    esac
    printf '%s\n' "$line" >> "$TMP"
  done < "$SSH_CONFIG"
fi
if [ "$in_target" -eq 1 ] && [ "$inserted" -eq 0 ]; then
  cat "$BLOCK" >> "$TMP"
  inserted=1
fi
if [ "$inserted" -eq 0 ]; then
  [ -s "$TMP" ] && printf '\n' >> "$TMP"
  printf '# %s\n\n' "$TITLE" >> "$TMP"
  cat "$BLOCK" >> "$TMP"
fi

mv "$TMP" "$SSH_CONFIG"
log "added Host $ALIAS ($TARGET_HOST) under '# $TITLE' in $SSH_CONFIG"

if [ -d "$DOT_DIR" ]; then
  dot add "$SSH_CONFIG" 2>/dev/null \
    && log "staged $SSH_CONFIG -- commit and push, then 'dj sync' elsewhere to pick it up" \
    || log "warn: could not stage $SSH_CONFIG (is the private repo set up?)"
fi
