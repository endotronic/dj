# fleet module

Bootstrap your other machines from one you've already set up. Enable with
`dj module enable fleet`.

## `dj setup [user@]host [install.sh args...]`

From a bootstrapped machine, set up a brand-new one over SSH:

1. Starts (or reuses) an ssh-agent with this machine's `~/.ssh/id_ed25519`.
2. Pushes this machine's age key to a temp path on the target with one
   `scp` (removed afterwards, success or failure), plus
   `~/.ssh/id_githost` if you use a private-repo clone key.
3. Installs `curl` on the target if it's missing.
4. Runs install.sh there over `ssh -A -t` with this machine's
   `--private-repo` and the pushed keys filled in. The forwarded agent
   covers the private clone.

Every connection is multiplexed over one OpenSSH ControlMaster, so a
password-only target asks for its password once. Extra arguments
(`--system-type`, `--on-conflict`, `--module`, ...) reach install.sh with
their quoting intact. With no `--system-type`, it asks, listing the
types in your own `~/.config/dj/packages/types/`.

Afterwards it offers to register the new machine in this machine's
`~/.ssh/config` (below).

## `dj setup-root host [install.sh args...]`

For a machine you have root on but no account: connects as root, creates
an account named like yours (`useradd --skel /dev/null`, admin group per
distro) or reuses an existing one, prompts for a password if the account
has none, grants a temporary NOPASSWD sudoers entry for the bootstrap
(removed at the end), and runs install.sh as that user via `su -`. No agent
forwarding: the age key and clone key are copied into the account directly.

## `dj ssh-register`

Adds a `Host` entry to `~/.ssh/config` under a `# Section` comment named by
system type, so machines are grouped and reachable by alias. Titles come
from `~/.config/dj/ssh-menu-sections.txt` (`vm VMs`, one per line); an
unmapped type becomes `Ucfirst(type)s`. install.sh's interactive run
offers to register the machine it's on (when this module is enabled), and
`dj setup` registers the target on the source machine.
