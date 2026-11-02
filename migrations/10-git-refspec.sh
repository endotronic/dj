#!/bin/sh
# Migration: git-refspec
#
# `git clone --bare` deliberately writes no remote.origin.fetch and no
# branch.<b>.remote/merge: a bare repo is normally a server-side
# mirror, so git assumes you don't want a copy-of-a-copy origin/*
# namespace inside it. This project uses a bare repo as a working
# checkout of $HOME, so we do want both.
#
# Without the refspec, fetch has nowhere to record what it saw except
# FETCH_HEAD (one transient file, overwritten every fetch), so
# origin/master never exists: no ahead/behind, and no
# `origin/master..master` ranges to ask what's unpushed. `dj sync`
# still works (pull --rebase falls back to FETCH_HEAD), which is
# exactly why this stays invisible until the day you need it.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "private bare repo has origin/* refs and branch tracking"; }

check() {
  [ -d "$DOT_DIR" ] || return 2
  dot remote get-url origin >/dev/null 2>&1 || return 2
  [ -n "$(dot config --get-all remote.origin.fetch 2>/dev/null || true)" ] || return 1
  _b=$(dot symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$_b" ]; then
    [ -n "$(dot config --get "branch.$_b.remote" 2>/dev/null || true)" ] || return 1
  fi
  return 0
}

fix() {
  if [ -z "$(dot config --get-all remote.origin.fetch 2>/dev/null || true)" ]; then
    dot config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    log "set remote.origin.fetch on $DOT_DIR"
  fi
  _b=$(dot symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$_b" ]; then
    dot config "branch.$_b.remote" origin
    dot config "branch.$_b.merge" "refs/heads/$_b"
    log "set upstream tracking: $_b -> origin/$_b"
  fi
  # Populate the refs now so origin/* exists immediately; an offline
  # machine still gets the config and fills in on its next sync.
  if dot fetch origin >/dev/null 2>&1; then
    log "fetched origin"
  else
    log "warn: could not reach origin; config is set and populates on next sync"
  fi
}

migration_main "$@"
