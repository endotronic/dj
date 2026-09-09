# Touch stops registering in tmux over mosh (Termux)

## Summary

Tapping window titles in tmux's status bar (or anywhere else mouse-driven)
over `mosh` on Termux works fine for a few taps, then consistently stops
doing anything. No error, no message — taps just silently do nothing until
something resets the terminal.

The fix: send the raw VT100 sequence to disable every mouse-tracking
submode directly on the client tty:

```
printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'
```

This is now bound in tmux as `prefix M` (`scripts/reset-mouse-mode.sh`, see
`tmux.conf`).

## Background: tmux's mouse mode isn't static

With `set -g mouse on`, tmux doesn't hold one fixed mouse-reporting mode.
It normally reports clicks via X10/normal tracking (`\e[?1000h`) with
SGR extended coordinates (`\e[?1006h`), but **upgrades** to any-motion
tracking (`\e[?1003h`) whenever it needs continuous position updates —
dragging a pane border, drag-selecting in copy-mode, or hovering to
highlight the selected item in an open `display-menu` (the SSH-menu
button added to this config uses exactly this: `display-menu -O` stays
open and highlights entries as the pointer moves over them). tmux
downgrades back to 1000 once the drag/hover ends.

## Why mosh loses that downgrade

mosh doesn't forward raw bytes end to end. Its client-side
`Terminal::Emulator` keeps its own model of terminal state (screen
contents, cursor, and modes including mouse tracking) and only re-emits
escape sequences for whatever it thinks changed since the last frame it
sent to the real terminal. This is the same architecture that caused the
OSC 52 clipboard relay to silently vanish in this stack — see
[tmux-clipboard.md](tmux-clipboard.md).

If a dropped/coalesced update, a network blip, or Termux backgrounding at
the wrong instant causes the "downgrade back to 1000" sequence to get
lost from mosh's model, mosh believes the client's mouse mode is already
correct and never re-sends anything to fix it — while the real terminal
(Termux) is actually still latched in any-motion mode 1003, continuously
emitting motion reports for every touch instead of clean click reports.
That mismatch persists indefinitely; nothing in the normal flow triggers
a resync.

"Works 2-3 times, then nothing" matches this: each successful tap is a
clean 1000/1006 report. The wedge happens the moment something (a menu
hover, a border-adjacent touch, a stray drag) triggers the 1003 upgrade
and mosh drops the matching downgrade.

## The fix

Bypass mosh's relay entirely and write the disable sequence straight to
the attached client's tty, the same approach already used for OSC 52 in
`scripts/osc52-copy.sh`:

```sh
printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l' > "$tty"
```

Octal escapes (`\033`) are used instead of `\e` since the script is
`#!/bin/sh` (POSIX `printf` doesn't guarantee `\e`).

Bound as `prefix M` in `tmux.conf` (`scripts/reset-mouse-mode.sh`), so a
wedge is one keystroke to clear rather than requiring a manual `printf`
from a shell prompt.

## Non-fixes

There's no tmux option to stop the automatic 1000→1003 upgrade — it's
intrinsic to how tmux implements border-drag and menu-hover highlighting,
not something exposed as a setting. Turning off `-O` on the SSH menu
(so it closes immediately on click-release instead of staying open for
hover-highlighting) would reduce *exposure* to the upgrade window, but
the same class of wedge was already happening from plain window-title
clicks before that menu existed, so it isn't the root cause and wasn't
worth trading away the better click UX for.
