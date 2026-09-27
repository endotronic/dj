#!/bin/sh
# claude-local [claude args...]: run Claude Code through the shared
# LiteLLM proxy, so one session can use both a self-hosted model and
# Anthropic's models (switch with `/model`).
#
# The proxy is the `litellm` service in ruby's ~/services (containerized
# LiteLLM), routing by model name per the master proxy's own
# ~/.config/claude-local/litellm.yaml on ruby. This script spawns
# nothing: no uvx, no per-session proxy -- it only sets Claude Code's
# env and execs it. Claude Code keeps using your normal Claude login:
# the proxy is authenticated by a shared master key in the
# x-litellm-api-key header, which is what lets LiteLLM pass your OAuth
# Authorization header through to Anthropic for claude-* models.
#
# Settings (private repo): ~/.config/claude-local/env (default model,
# context window, proxy URL). The master key is LITELLM_MASTER_KEY, a
# SOPS secret materialized to ~/.secrets/litellm.env (§5.1) and exported
# by shell/secrets.sh — ruby's container reads the same file.
# Plain `claude` is untouched.
set -eu

CONF_DIR=${CLAUDE_LOCAL_CONF_DIR:-$HOME/.config/claude-local}
ENV_FILE=$CONF_DIR/env

die() { printf 'claude-local: %s\n' "$*" >&2; exit 1; }

if [ -r "$ENV_FILE" ]; then
  . "$ENV_FILE"
fi
[ -n "${CLAUDE_LOCAL_MODEL:-}" ] || die "CLAUDE_LOCAL_MODEL not set (see $ENV_FILE)"
[ -n "${CLAUDE_LOCAL_PROXY_URL:-}" ] || die "CLAUDE_LOCAL_PROXY_URL not set (see $ENV_FILE)"
command -v claude >/dev/null || die "claude not found"
[ -n "${LITELLM_MASTER_KEY:-}" ] \
  || die "LITELLM_MASTER_KEY unset (dj apply-secrets?)"

status=0
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  ANTHROPIC_BASE_URL="$CLAUDE_LOCAL_PROXY_URL" \
  ANTHROPIC_CUSTOM_HEADERS="x-litellm-api-key: Bearer $LITELLM_MASTER_KEY" \
  ANTHROPIC_MODEL="$CLAUDE_LOCAL_MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$CLAUDE_LOCAL_MODEL" \
  ${CLAUDE_LOCAL_CONTEXT:+CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDE_LOCAL_CONTEXT"} \
  claude "$@" || status=$?
exit "$status"
