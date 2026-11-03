# claude module

Claude Code integration. Enable with `dj module enable claude`.

Installing Claude Code itself doesn't need this module: add `claude` to a
package list and `packages/scripts/claude.sh` runs the vendor installer.

## `dj claude`

```sh
dj claude                      # interactive session in ~/.dotfiles
dj claude "add pv to my lists" # one-shot (claude -p)
echo "question" | dj claude    # prompt on stdin
```

Runs in this repo, so the project skills in `.claude/skills/` (install a
package, query config, edit config, map intent to a `dj` verb) are loaded.

- `-y` / `--yolo` adds `--dangerously-skip-permissions`; `-r` / `--resume`
  resumes instead of going one-shot; auto mode is always on.
- Remote Control is **off** unless you pass `--remote-control`, and a
  settings guard keeps a settings file from re-arming it.
- Arguments reach `claude` with their boundaries intact: a prompt with `$`
  or backticks is text, never shell.
- **Your own launcher.** If `$DJ_CLAUDE_LAUNCHER` or
  `~/.config/dj/claude/launcher` (private repo) is executable, it runs in
  place of `claude` with the same arguments and `DJ_CLAUDE_REMOTE_CONTROL`
  (1/0) in its environment. Use it to route through a proxy, set a model,
  and so on.

## Your notes: `~/.config/dj/AGENTS.md`

Context about *your* machines and decisions belongs in your private repo.
Keep it at `~/.config/dj/AGENTS.md`; the `claude-local-context` migration
links it into the dj checkout as `.claude/AGENTS.md` (gitignored), so `dj
claude` sessions see it next to dj's own `AGENTS.md`. (Not
`CLAUDE.local.md`: Claude Code skips a directory's `AGENTS.md` when that
directory has a `CLAUDE.md` or `CLAUDE.local.md`.)

## Keeping secrets out of a session

The `claude-secrets-rules` migration merges three things into
`~/.claude/settings.json` (Claude Code's own, untracked file, so only those
keys are touched):

- `permissions.deny` for Read/Edit of `~/.secrets`, `~/.private`, the age
  key, Claude Code's credential, SSH private keys, `~/.gnupg`, `~/.aws`,
  `~/.netrc`;
- a `PreToolUse` hook, `secrets-gate.sh`, that denies Bash commands which
  would read those paths, decrypt with sops/age, or dump the environment
  next to a credential-shaped name;
- `DOTFILES_SKIP_SECRETS=1`, so shells inside a session don't load secret
  values at all.

Plaintext an app keeps somewhere else? List it, one home-relative path or
glob per line, in `~/.config/dj/claude/secret-paths.txt`; both the deny
rules and the gate pick it up.

The gate reads the decoded command, after blanking commit/PR message
bodies (they flow into git, not into context). A reader only counts when it
shares a pipeline segment with the path, so `ls ~/.secrets | grep api`
passes and `cat ~/.secrets/api.env | head` does not; `xargs` pairs with a
path anywhere, and the directory itself counts (`grep -r TOKEN ~/.secrets`).
Inert verbs (`ls`, `test -r`), sourcing a file to use a value in a call, and
paths not anchored to the real home pass.

The gate aims at incidental exposure by a well-behaved model, not at an
adversary: indirection (a variable holding the path, a generated script)
gets past a textual scan.

## Status line

Track a status line script at `~/.claude/statusline-command.sh` and the
`claude-statusline` migration turns it on in `settings.json`.

## Login on Linux/WSL

`dj claude-creds-snapshot` encrypts `~/.claude/.credentials.json` into your
secrets and registers it in the manifest, so `dj sync` restores the login
on your other machines. Re-run it when the token expires. On macOS the
login lives in the Keychain; log in on each machine.
