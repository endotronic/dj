#!/bin/sh
# Migration: claude-statusline
#
# The status line script (~/.claude/statusline-command.sh) is tracked, but
# the setting that turns it on lives in ~/.claude/settings.json -- which
# Claude Code rewrites itself and which carries machine-specific state
# (autoMode environment, permissions), so it can't be tracked whole. This
# merges just the `statusLine` key, leaving the rest alone. The command
# embeds $HOME because Claude Code doesn't expand it, and it differs
# between Linux and macOS.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "Claude Code's settings.json points at the tracked status line script"; }

claude_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

statusline_cmd() { printf 'bash %s/statusline-command.sh' "$(claude_dir)"; }

check() {
  [ -r "$(claude_dir)/statusline-command.sh" ] || return 2
  _sf="$(claude_dir)/settings.json"
  [ -r "$_sf" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    [ "$(jq -r '.statusLine.command // empty' "$_sf" 2>/dev/null)" = "$(statusline_cmd)" ] || return 1
  else
    grep -qF "\"command\": \"$(statusline_cmd)\"" "$_sf" || return 1
  fi
  return 0
}

fix() {
  _sd=$(claude_dir)
  _sf="$_sd/settings.json"
  _cmd=$(statusline_cmd)
  if [ ! -s "$_sf" ]; then
    printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "%s"\n  }\n}\n' "$_cmd" > "$_sf"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "claude-statusline: jq is required to merge into an existing $_sf" >&2
    return 1
  fi
  _tmp="$_sf.statusline.$$"
  if jq --arg c "$_cmd" '.statusLine = {type: "command", command: $c}' "$_sf" > "$_tmp"; then
    mv "$_tmp" "$_sf"
  else
    rm -f "$_tmp"
    return 1
  fi
}

migration_main "$@"
