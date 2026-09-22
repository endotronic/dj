#!/bin/sh
# claude-local [claude args...]: run Claude Code through a per-session
# LiteLLM proxy, so one session can use both a self-hosted model and
# Anthropic's models (switch with `/model`).
#
# The proxy (run via uvx, nothing installed) routes by model name per
# ~/.config/claude-local/litellm.yaml. Claude Code keeps using your normal
# Claude login: the proxy is authenticated by a random per-session key in
# the x-litellm-api-key header, which is what lets LiteLLM pass your OAuth
# Authorization header through to Anthropic for claude-* models. The
# proxy listens on 127.0.0.1 only and exits with the session.
#
# Settings (private repo): ~/.config/claude-local/{env,litellm.yaml}.
# Plain `claude` is untouched.
set -eu

CONF_DIR=${CLAUDE_LOCAL_CONF_DIR:-$HOME/.config/claude-local}
ENV_FILE=$CONF_DIR/env
CONFIG=$CONF_DIR/litellm.yaml

die() { printf 'claude-local: %s\n' "$*" >&2; exit 1; }

[ -r "$CONFIG" ] || die "missing $CONFIG"
if [ -r "$ENV_FILE" ]; then
  . "$ENV_FILE"
fi
[ -n "${CLAUDE_LOCAL_MODEL:-}" ] || die "CLAUDE_LOCAL_MODEL not set (see $ENV_FILE)"
[ -n "${CLAUDE_LOCAL_LITELLM_VERSION:-}" ] \
  || die "CLAUDE_LOCAL_LITELLM_VERSION not set (see $ENV_FILE)"
command -v uvx >/dev/null 2>&1 || die "uvx not found (install uv: dj install-packages)"
command -v claude >/dev/null 2>&1 || die "claude not found"
[ -n "${VLLM_API_KEY:-}" ] \
  || printf 'claude-local: warning: VLLM_API_KEY unset (dj sync / apply-secrets?)\n' >&2

# Free port: bind 0 and let the kernel choose.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])') \
  || die "could not pick a free port"
key="sk-$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/claude-local.XXXXXX")
log=$workdir/litellm.log

proxy_pid=
# Re-exit with the original status: dash otherwise lets the trap's last
# command (the `wait` on the killed proxy, 143) become the script's status.
cleanup() {
  rc=$?
  if [ -n "$proxy_pid" ] && kill "$proxy_pid" 2>/dev/null; then
    wait "$proxy_pid" 2>/dev/null || :
  fi
  rm -rf "$workdir"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' TERM HUP
# A handler, not an ignore: Ctrl-C belongs to Claude Code (interrupt), and
# must not tear down the proxy underneath it.
trap ':' INT

LITELLM_MASTER_KEY=$key uvx --quiet --from "litellm[proxy]==$CLAUDE_LOCAL_LITELLM_VERSION" \
  litellm --config "$CONFIG" --host 127.0.0.1 --port "$port" >"$log" 2>&1 &
proxy_pid=$!

# First run downloads LiteLLM into the uv cache, so allow a while.
tries=0
until curl -fs -o /dev/null "http://127.0.0.1:$port/health/liveliness"; do
  if ! kill -0 "$proxy_pid" 2>/dev/null; then
    tail -20 "$log" >&2
    die "LiteLLM proxy exited during startup"
  fi
  tries=$((tries + 1))
  [ "$tries" -le "${CLAUDE_LOCAL_STARTUP_TRIES:-240}" ] || { tail -20 "$log" >&2; die "LiteLLM proxy did not come up"; }
  sleep 0.5
done

status=0
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
  ANTHROPIC_CUSTOM_HEADERS="x-litellm-api-key: Bearer $key" \
  ANTHROPIC_MODEL="$CLAUDE_LOCAL_MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$CLAUDE_LOCAL_MODEL" \
  ${CLAUDE_LOCAL_CONTEXT:+CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDE_LOCAL_CONTEXT"} \
  claude "$@" || status=$?
exit "$status"
