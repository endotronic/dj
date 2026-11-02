# tmux-theme module

A per-machine accent color, so you can tell at a glance which machine a
terminal is on. Enable with `dj module enable tmux-theme`, or pass
`install.sh --theme '#rrggbb'`, which enables it.

- **The color is host-local state** at `~/.config/dotfiles/tmux-theme-color`,
  never tracked: `install.sh --theme COLOR` writes it, or write it by hand.
- **Your tmux.conf reads it.** dj ships no tmux config; read the file in
  yours and fall back to a default when it's absent, for example:

  ```tmux
  set -g @theme_color "#2596be"
  if-shell 'test -r ~/.config/dotfiles/tmux-theme-color' \
    'run-shell "tmux set -g @theme_color $(cat ~/.config/dotfiles/tmux-theme-color)"'
  set -gF status-style "bg=#{@theme_color}"
  ```

- **`dj setup` picks one** for a target that wasn't given `--theme` (needs
  the fleet module too): it asks `claude -p` for a color evocative of the
  host name, bounded by a 20 s timeout, and falls back to a random color,
  so every machine gets its own rather than all sharing a default.
