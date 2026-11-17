# dj

**dj** is short for **dotfiles jockey**. It bootstraps and maintains all
your machines from two git repos: this one, the engine, and a private one
of your own that tracks your dotfiles in place in `$HOME`, your package
lists, and SOPS-encrypted secrets.

```sh
curl -fsSL https://raw.githubusercontent.com/endotronic/dj/main/install.sh \
  | sh -s -- --private-repo git@github.com:you/dotfiles.git --system-type laptop
```

Linux (apt, pacman), NixOS, macOS (brew) and WSL. POSIX sh throughout.

## What you get

- **Your `$HOME` is the work tree.** Config files are tracked where they
  live, in a bare repo; `dot` is git for it. No templates, no apply step.
- **Package lists** per machine type and per host, resolved through
  per-package-manager renames, with fallback installers for tools no
  package manager ships.
- **Secrets** encrypted with SOPS + age in your repo, decrypted to where
  they belong on every machine. The age key is the one thing you carry.
- **Per-machine SSH keys** with shared trust: every machine's public key
  is in your repo, so they can all reach each other, and none of them
  shares a private key.
- **Migrations** that catch an already-set-up machine up to newer dj, so
  old machines don't quietly miss what new ones get.
- **`dj doctor`**, **`dj sync`**, **`dj upgrade`** for daily use.
- **Opt-in modules**: Claude Code integration, opencode, fleet bootstrap
  over SSH, a shared git-host key, a per-machine tmux accent color.

## Starting out (no private repo yet)

```sh
curl -fsSL https://raw.githubusercontent.com/endotronic/dj/main/install.sh | sh
. ~/.bashrc
dj init --remote git@github.com:you/dotfiles.git --commit
dot push -u origin HEAD
dj migrate --fix
```

`install.sh` without `--private-repo` leaves an empty private repo. `dj
init` lays out `~/.config/dj/` (package lists, hook lists, modules.txt) and
the SOPS config, then stages them with your shell config. **Back up
`~/.config/sops/age/keys.txt`**: without it your secrets can't be
decrypted.

## Another machine

On the new machine:

```sh
curl -fsSL https://raw.githubusercontent.com/endotronic/dj/main/install.sh \
  | sh -s -- --private-repo git@github.com:you/dotfiles.git \
             --system-type server --sops you@first-machine
```

`--sops user@host` fetches the age key over scp (or pass `--age-key PATH`,
or paste it when asked).

Or, from a machine that's already set up, without logging in to the new
one first (fleet module: `dj module enable fleet`):

```sh
dj setup alice@host1 --system-type server
```

`dj setup` connects over SSH, hands the new machine your age key (and
private-repo clone key, if you use one) through a temp file it removes
afterwards, forwards your SSH agent for the private clone, and runs
install.sh there with your `--private-repo` filled in. Extra arguments go
to install.sh; with no `--system-type` it asks, listing your types. It
then offers to add the new machine to your `~/.ssh/config`. For a machine
where you only have root, `dj setup-root host` creates your account first.
See [modules/fleet](modules/fleet/README.md).

## Daily

| | |
|---|---|
| `dj sync` | pull dj and your repo, apply secrets, refresh SSH trust, report stale state |
| `dj upgrade` | sync, then install newly listed packages and run post-install hooks |
| `dj doctor` | sanity checks and pending migrations (`--fix` applies them) |
| `dj add PATH` | track a file (`dot commit`, `dot push` as with any repo) |
| `dj secret-add PATH` | encrypt a file into your secrets and register where it goes |
| `dj secret-edit NAME` | edit one in place through sops |
| `dj system-type TYPE` | change which type lists apply here (asks first for a type no list has) |
| `dj module list` | see and enable optional modules |

Your configuration lives in your repo under `~/.config/dj/`:

```
packages/common.txt  types/<type>.txt  hosts/<host>.txt   what to install
packages/renames/<mgr>.txt  packages/scripts/<name>.sh   your own mappings and installers
postinstall/common.txt ...  postinstall/<name>.sh        system follow-ups (sudo)
migrations/NN-<id>.sh                                     your own catch-up repairs
modules.txt                                               enabled modules
AGENTS.md                                                 notes for coding agents (claude module)
```

## `dot`

Your private repo is a bare git repo at `~/.config.git` whose work tree is
`$HOME` itself, so your config files are tracked exactly where they live.
`dot` is the shell alias for git pointed at it:

```sh
alias dot='git --git-dir="$HOME/.config.git" --work-tree="$HOME"'
```

Use it like git: `dot add ~/.config/foo/config`, `dot commit`, `dot push`,
`dot log`, `dot diff`. `dot status` deliberately hides untracked files
(otherwise it would list everything in your home directory), so nothing is
tracked until you add it by name. `dj add`, `dj status`, `dj diff`, `dj
commit` and `dj push` are the same operations, usable where the alias isn't
loaded. Plain `git` inside `~/.dotfiles` is the public engine; `dot` from
anywhere is your own repo.

## Migrations

install.sh converges, but only where it runs, and after a machine's first
day that's nowhere. So when a newer dj learns to set something up (a git
setting, a hook, a required tool, a renamed file), machines bootstrapped
before that would quietly go without it, and you'd find out months later
when one behaves differently from the others.

A migration is the catch-up. Each one checks the machine's live state, not
a version number, so it's right on a machine that was half-fixed by hand or
restored from a backup:

```sh
dj migrate          # what's pending here
dj migrate --fix    # apply the safe repairs
dj migrate --list   # every migration dj knows about
```

`dj sync` and `dj upgrade` end with a one-line report, so a pull that leaves
a machine behind says so right away, and `dj doctor` includes them. Repairs
are applied only when they're local, reversible and need no judgement;
anything that would rotate a credential, remove software or make a choice
for you is MANUAL: reported with the exact commands, never run by `--fix`.
The result is that your oldest machine and the one you set up this morning
end up in the same state. Modules ship their own migrations, and you can
add yours in `~/.config/dj/migrations/` (protocol:
[migrations/README.md](migrations/README.md)).

## Modules

Features that are useful but not for everyone ship as modules: part of
dj, off until you turn them on. Each one can add `dj` commands, migrations
and bootstrap steps; a disabled module's commands say how to enable it
instead of half-working.

```sh
dj module list                 # every module and whether it's on here
dj module enable fleet         # records it in ~/.config/dj/modules.txt
dot add ~/.config/dj/modules.txt && dot commit -m 'dj: enable fleet'
```

`modules.txt` is in your private repo, so a module enabled once is on for
every machine after `dj sync`. `install.sh --module NAME` enables one
during a bootstrap.

| module | what it adds |
|---|---|
| [claude](modules/claude/README.md) | `dj claude` (`dj c`): Claude Code in this repo with skills for operating dj, your own launcher in its place if you have one, your agent notes from `~/.config/dj/AGENTS.md`, and settings plus a hook that keep secrets out of a session |
| opencode | `dj opencode` (`dj o`): the same for opencode |
| [fleet](modules/fleet/README.md) | `dj setup` and `dj setup-root` to bootstrap a machine over SSH from one already set up; `dj ssh-register` to group your machines in `~/.ssh/config` by type |
| [shared-git-key](modules/shared-git-key/README.md) | one SSH key for your git host(s), restored from secrets everywhere, instead of registering every machine's own key with every forge |
| [tmux-theme](modules/tmux-theme/README.md) | a per-machine accent color (`install.sh --theme`, or picked per host by `dj setup`) for your tmux config to read |

Writing one: [modules/README.md](modules/README.md).

## Compared to chezmoi

chezmoi renders a source directory into `$HOME`, with templates; dj
tracks `$HOME` in place and branches at runtime instead. If you need
per-OS file contents, native Windows, or password-manager secret backends,
chezmoi is the better fit. dj's angle is everything around the files:
typed package lists, encrypted secrets with destinations, SSH trust across
machines, and migrations that repair old machines.

## More

- [docs/design.md](docs/design.md): the design and the reasons for it
- [modules/](modules/README.md): optional features
- [migrations/](migrations/README.md): writing a migration
- [AGENTS.md](AGENTS.md): working on dj itself

MIT licensed.
