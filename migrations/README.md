# Migrations

A migration repairs machine state that newer dj code expects but that an
older bootstrap never created: a git config, a derived file, a renamed
path. `scripts/migrate.sh` runs them; `dj doctor` and `dj migrate` report
them, and `dj migrate --fix` applies them.

Each one is a POSIX sh script named `NN-<id>.sh`. `NN` only orders them;
`<id>` is what `--only` takes. The script sources the helper library and
defines three functions:

```sh
#!/bin/sh
# Migration: example
# (dj-migration: manual, on a line of its own, marks it MANUAL)

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc()  { echo "one line saying what 'satisfied' means"; }
check() { ...; }   # 0 satisfied, 1 pending, 2 not applicable here
fix()   { ...; }   # the repair; for MANUAL, print what to run by hand

migration_main "$@"
```

Rules:

- **check is a predicate on live state**, never a stored version number,
  so it's right on a machine that was half-repaired by hand.
- **N/A is silent.** Return 2 when the migration doesn't apply here (wrong
  OS, tool absent), so a server never reports desktop-only state.
- **fix is idempotent** and does nothing on a machine that never had the
  problem.
- **MANUAL** when the repair rotates a credential, removes software, or
  needs a judgement call. `--fix` never applies it; the runner prints its
  `fix` output as instructions.

The library (`scripts/lib/migration.sh`) provides `log`, `dot`,
`backup_dir`, `on_nixos`, `this_host` and `ssh_fp`, and the variables
`DOT_DIR` (the private bare repo) and `REPO_ROOT` (this repo).
