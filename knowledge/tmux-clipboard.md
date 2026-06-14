# Clipboard copy through Alacritty → mosh → tmux

## Summary

Copying text from a remote tmux session (reached over `mosh` from
Alacritty) to the local system clipboard did not work, despite tmux being
configured with the textbook `set-clipboard on` + `Ms` terminal-override
incantation that's commonly recommended for tmux+mosh setups.

The root cause turned out to be that **tmux's own `set-clipboard`/`Ms` OSC
52 relay never reaches the outer terminal at all in this stack** — it
resolves correctly (`tmux show -g terminal-overrides`, `client_termfeatures`
all look right) but produces no bytes on the wire. Meanwhile, a *raw* OSC 52
sequence written directly to the attached client's tty works perfectly
through both `mosh` and plain `ssh`.

The fix: stop relying on tmux's relay entirely. Bind copy-mode actions to
pipe the selection through a tiny script that writes the OSC 52 sequence
directly to `#{client_tty}`.

## Background: what OSC 52 is and the stack involved

OSC 52 (`ESC ] 52 ; <selector> ; <base64-data> <terminator>`) is a terminal
escape sequence that lets a program running *inside* a terminal — possibly
on a remote machine, possibly inside a multiplexer — ask the terminal
emulator to put data on the system clipboard. `<selector>` is one or more
of `c` (CLIPBOARD), `p` (PRIMARY), `s`, `q`; `<terminator>` is either BEL
(`\007`) or ST (`\033\\`).

The stack in question:

```
Alacritty (local, Wayland/Hyprland, Omarchy)
  -> mosh (1.4.0, both ends)
    -> tmux (3.6b) session on the remote host
      -> shell / programs
```

For OSC 52 to land in the local clipboard, the sequence has to survive
every hop: the program that emits it, tmux's terminal parser (if
`set-clipboard` is involved), mosh's `Terminal::Emulator` state-diffing
on both ends, and finally Alacritty's own OSC 52 handling.

## Symptom

Mouse-selecting text inside tmux (with `mouse on` and `set-clipboard on`)
did not update the system clipboard. `wl-paste` showed stale/no content
after a selection that should have triggered an OSC 52 clipboard-set.

The starting tmux config already had two commonly-recommended mitigations
in place:

```tmux
set -g set-clipboard on
set -as terminal-overrides ',*:Ms=\E]52;%p1%s;%p2%s\007'
```

## Investigation

### 1. mosh requires an explicit `c;` selector

mosh's OSC 52 support (added in 1.4.0) only recognizes sequences of the
exact form `\033]52;c;<data>\007` — it pattern-matches on `52;c;` literally.
tmux's `Ms` capability, when driven by `%p1` (the selection parameter tmux
was asked to set), often emits an **empty** selector — `\033]52;;<data>\007`
— which mosh silently ignores.

Fix applied: hardcode the selector to `c` instead of passing through `%p1`:

```tmux
set -as terminal-overrides ',*:Ms=\E]52;c;%p2%s\007'
```

This is necessary but, as it turned out, not sufficient.

### 2. Confirming the rest of the stack supports OSC 52

Before digging further into tmux, we ruled out the other hops:

- **mosh binaries**: `strings /usr/bin/mosh-server /usr/bin/mosh-client`
  both contain the literal `]52;c;` pattern — OSC 52 clipboard support is
  compiled in on both ends (Arch package `mosh 1.4.0-30`).
- **Alacritty config**: `terminal.osc52 = "CopyPaste"` was already set
  explicitly in `alacritty.toml` (Alacritty ≥0.13 defaults to `OnlyCopy`,
  which would also have been sufficient). Alacritty version 0.17.0.
- **tmux's resolved capabilities for the actual client**:

  ```
  $ tmux show -g terminal-overrides
  terminal-overrides[2] "*:Ms=\\E]52;c;%p2%s\\007"

  $ tmux display-message -p "term=#{client_termname} termfeatures=#{client_termfeatures}"
  term=xterm-256color termfeatures=bpaste,ccolour,clipboard,cstyle,focus,RGB,title

  $ tmux server-info | grep -A1 ' Ms:'
   193: Ms: (string) \033]52;c;%p2%s\a
  ```

  Everything tmux *thinks* it knows is correct: `Ms` resolves to the
  hardcoded-`c` form, and the client is recognized as supporting the
  `clipboard` feature (via the built-in `xterm*:clipboard` terminal-features
  default — `client_termname` is `xterm-256color` because Alacritty sets
  `TERM=xterm-256color` in its config).

### 3. Raw OSC 52 works fine — through both mosh and plain ssh

To isolate "does *anything* in this path get OSC 52 to the clipboard",
we bypassed tmux completely:

```bash
# over plain ssh, no tmux
printf '\033]52;c;%s\033\\' "$(printf 'raw-osc52-st' | base64)"
# -> wl-paste locally shows "raw-osc52-st"

# same, with a BEL terminator instead of ST
printf '\033]52;c;%s\007' "$(printf 'raw-osc52-bel' | base64)"
# -> wl-paste locally shows "raw-osc52-bel"

# same, over a fresh mosh connection (no tmux attached)
# -> also works
```

So: Alacritty, mosh, and a plain remote shell are all completely fine with
OSC 52, in either terminator style, in either selector style we cared about.
The problem is specifically in the tmux hop.

### 4. tmux's `set-clipboard`/`Ms` relay produces nothing

Two different ways of asking tmux to emit `Ms` were tested, both from
*inside* the tmux session attached over mosh:

```bash
# (a) tmux's own buffer -> OSC 52 path
tmux set-buffer -w "marker-test-string-12345"

# (b) simulate an application inside the pane emitting OSC 52,
#     which set-clipboard=on should intercept and relay via Ms
printf '\033]52;c;%s\007' "$(printf 'pane-injected-test' | base64)" > /dev/pts/1   # the pane's own tty
```

Neither produced any change in `wl-paste`. Both `set-buffer -w` (tmux's
"emit Ms for this buffer" path) and pane-output interception (the
`set-clipboard`-driven path) are silent no-ops here, despite `Ms` and the
`clipboard` terminal feature resolving correctly for the client.

We attempted to confirm this with `strace` on the tmux server process and
with tmux's `SIGUSR1` debug-logging toggle; neither was available/produced
output in this environment, so the *exact* internal reason tmux doesn't
write the bytes remains unconfirmed. What's empirically certain is that no
`52;c;` bytes reach the client tty via either tmux mechanism.

### 5. Writing directly to the client's tty works

tmux exposes the tty device of each attached client via the
`#{client_tty}` format variable (e.g. `/dev/pts/3` for the mosh-attached
client). Writing a raw OSC 52 sequence to that device directly — i.e.
*not* going through tmux's own relay at all — works exactly like the plain
ssh/mosh test in step 3:

```bash
tmux list-clients -F '#{client_tty} #{client_termname} #{session_name}'
# /dev/pts/3 xterm-256color nexus

printf '\033]52;c;%s\033\\' "$(printf 'direct-tty-test' | base64)" > /dev/pts/3
# -> wl-paste locally shows "direct-tty-test"
```

This is the key finding: the client tty *itself* has no problem receiving
and acting on OSC 52 — only tmux's internal relay mechanism fails to put
anything there.

## Solution

Bypass tmux's `set-clipboard`/`Ms` relay for the cases that matter (mouse
selection and keyboard copy in copy-mode) by piping the copied text through
a small script that writes OSC 52 straight to `#{client_tty}`.

`~/.config/tmux/scripts/osc52-copy.sh`:

```sh
#!/bin/sh
# Relay stdin to the system clipboard via OSC 52, writing directly to the
# attached client's tty. tmux's own set-clipboard/Ms relay doesn't reach
# the terminal through mosh, so bypass it and write the escape sequence
# straight to the client tty (passed as $1, e.g. #{client_tty}).
printf '\033]52;c;%s\033\\' "$(base64 | tr -d '\n')" > "$1"
```

`~/.config/tmux/tmux.conf` bindings:

```tmux
bind -T copy-mode MouseDragEnd1Pane send -X copy-pipe-and-cancel "$HOME/.config/tmux/scripts/osc52-copy.sh '#{client_tty}'"
bind -T copy-mode Enter send -X copy-pipe-and-cancel "$HOME/.config/tmux/scripts/osc52-copy.sh '#{client_tty}'"
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "$HOME/.config/tmux/scripts/osc52-copy.sh '#{client_tty}'"
bind -T copy-mode-vi Enter send -X copy-pipe-and-cancel "$HOME/.config/tmux/scripts/osc52-copy.sh '#{client_tty}'"
```

`copy-pipe-and-cancel` does three things: pipes the copy-mode selection to
the given command's stdin, *also* writes it to the tmux paste buffer (so
`prefix` + `]` still works), and exits copy-mode — so this is a strict
addition, not a replacement of tmux's internal copy/paste.

Both `copy-mode` (the default, emacs-style table) and `copy-mode-vi` are
bound, since `mouse on` drives `MouseDragEnd1Pane` in whichever table is
active for `mode-keys`, and this repo's tmux config keeps `mode-keys`
commented out (defaulting to emacs).

### What was kept from the earlier fix

The `set-clipboard on` and hardcoded-`c` `Ms` override (step 1 above) were
left in place — they're harmless, resolve correctly, and may work in other
tmux clients/transports (e.g. a local, non-mosh terminal) where the relay
isn't broken. They're just not sufficient on their own for this stack.

## Caveats / things not covered

- **Nested tmux** (tmux-in-tmux, e.g. a local tmux on the client machine
  with an inner tmux session reached via ssh) is not specifically handled.
  `#{client_tty}` for the inner tmux's client would point at a pty owned by
  the *outer* tmux's pane, which would then need its own relay to work —
  same failure mode as the one fixed here, one level up.
- The exact internal reason tmux's `set-clipboard`/`Ms` path produces no
  output was not root-caused (no `strace`, and tmux's `SIGUSR1`
  debug-logging toggle didn't produce a log file in this environment). If
  this is a known tmux bug, it may be worth searching/filing upstream.
- OSC 52 has a practical size limit (mosh in particular truncates clipboard
  data larger than roughly one UDP packet). Not an issue for typical
  terminal-selection-sized copies.

## Environment

- tmux 3.6b (Arch package `mosh 1.4.0-30` for mosh; tmux from Arch repos)
- mosh 1.4.0 (both client and server, Arch)
- Alacritty 0.17.0, `terminal.osc52 = "CopyPaste"`, `TERM=xterm-256color`
- Omarchy (Hyprland/Wayland) — `wl-paste`/`wl-copy` as the clipboard backend
