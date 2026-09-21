#!/bin/sh
# Fast-forward the public tooling repo (~/.dotfiles) from its upstream.
#
# `dj sync` pulls the private config repo, but the personal lists in it
# name things that live HERE: a post-install hook with no script yet, a
# logical package name with no rename. Pulling only the private side
# leaves the lists ahead of the code that interprets them, so sync
# brings both -- this one first, so the scripts sync goes on to run
# (rebuild-secrets, authorized-keys, migrate) are the freshly pulled ones.
#
# Never fatal. This checkout is also where tooling gets edited, so
# "diverged", "local changes in the way", "offline" and "no upstream" are
# all normal states, not errors: each prints a warning with the manual
# fix and the script still exits 0, leaving the private-repo pull (the
# part sync cannot do without) to proceed. Fast-forward only -- this
# never merges, rebases, or discards anything of yours; uncommitted
# changes are left as they are unless the pull itself would overwrite
# them, in which case git refuses and we warn.
#
# DOTFILES_REPO_ROOT is overridable for tests.

set -eu

REPO_ROOT=${DOTFILES_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}

log()  { printf '[sync-public] %s\n' "$*"; }
warn() { printf '[sync-public] warning: %s\n' "$*" >&2; }

git_repo() { git -C "$REPO_ROOT" "$@"; }

# Everything lives in a function so the whole body is parsed before any
# of it runs: the pull below may replace this very file, and a shell
# reading a script incrementally must not see it change underneath it.
main() {
  # `.git` (dir, or file for a linked worktree) rather than rev-parse,
  # which would happily find an enclosing repo above an unpacked copy.
  if [ ! -e "$REPO_ROOT/.git" ]; then
    log "$REPO_ROOT is not a git checkout; skipping"
    return 0
  fi

  if ! _branch=$(git_repo symbolic-ref --short -q HEAD); then
    warn "$REPO_ROOT is on a detached HEAD; skipping"
    return 0
  fi

  if ! git_repo rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    warn "branch '$_branch' in $REPO_ROOT has no upstream; skipping"
    return 0
  fi

  _before=$(git_repo rev-parse HEAD)

  # GIT_TERMINAL_PROMPT=0: an https origin with no credentials must fail
  # fast rather than sit waiting for a username in the middle of a sync.
  if ! _out=$(GIT_TERMINAL_PROMPT=0 git_repo pull --ff-only 2>&1); then
    warn "could not fast-forward $REPO_ROOT; continuing with what is checked out"
    printf '%s\n' "$_out" | sed 's/^/    /' >&2
    warn "to resolve by hand: cd $REPO_ROOT && git pull --rebase"
    return 0
  fi

  _after=$(git_repo rev-parse HEAD)
  if [ "$_before" = "$_after" ]; then
    log "public repo already up to date"
    return 0
  fi

  _n=$(git_repo rev-list --count "$_before..$_after")
  log "public repo updated: $_n new commit(s)"
  git_repo log --format='    %h %s' --max-count=10 "$_before..$_after"
  if [ "$_n" -gt 10 ]; then
    log "    ... and $((_n - 10)) more"
  fi
  return 0
}

main "$@"
exit 0
