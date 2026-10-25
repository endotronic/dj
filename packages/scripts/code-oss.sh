#!/bin/sh
# VS Code, Open Source flavour, on the platforms that have no `code` package.
# Arch gets it from pacman (package `code`, binary code-oss), so this never
# runs there; everywhere else the stand-in is VSCodium (binary codium):
#
#   Debian/Ubuntu  VSCodium's own signed apt repo -- it is not in the distro
#                  repos, and the repo keeps it updated through apt.
#   macOS          the `vscodium` cask (install-packages only does formulae).
#
# The renames files name `codium` as the binary to look for (third column).
#
# DOTFILES_KEYRING_DIR and DOTFILES_APT_SOURCES_DIR exist for tests; a real
# run never needs to set either.
set -eu

tag='[code-oss]'
command -v codium >/dev/null 2>&1 && exit 0

keyring_dir="${DOTFILES_KEYRING_DIR:-/usr/share/keyrings}"
sources_dir="${DOTFILES_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

case "$(uname -s)" in
  Darwin)
    command -v brew >/dev/null 2>&1 || { printf '%s Homebrew not found\n' "$tag" >&2; exit 1; }
    printf '%s installing the vscodium cask\n' "$tag"
    brew install --cask vscodium
    ;;
  Linux)
    command -v apt-get >/dev/null 2>&1 || {
      printf '%s no VSCodium install path here (apt and brew only; Arch uses the `code` package)\n' "$tag" >&2
      exit 1
    }
    keyring="$keyring_dir/vscodium-archive-keyring.gpg"
    sources="$sources_dir/vscodium.sources"

    if [ ! -s "$keyring" ]; then
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT INT TERM
      # Download first, so a failed fetch can't leave an empty keyring that
      # apt would then reject (or, worse, treat as trusted-but-empty).
      curl -fsSL https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg -o "$tmp"
      [ -s "$tmp" ] || { printf '%s could not download the VSCodium repo key\n' "$tag" >&2; exit 1; }
      gpg --dearmor < "$tmp" | sudo tee "$keyring" >/dev/null
      [ -s "$keyring" ] || { printf '%s the VSCodium repo key came out empty\n' "$tag" >&2; exit 1; }
    fi

    want=$(printf 'Types: deb\nURIs: https://download.vscodium.com/debs\nSuites: vscodium\nComponents: main\nArchitectures: amd64 arm64\nSigned-By: %s\n' "$keyring")
    if [ "$(cat "$sources" 2>/dev/null || true)" != "$want" ]; then
      printf '%s\n' "$want" | sudo tee "$sources" >/dev/null
    fi

    # Tolerated like every other apt-get update in this project: an unrelated
    # repo failing (e.g. a paywalled enterprise repo) shouldn't block this.
    sudo apt-get update || true
    printf '%s installing codium\n' "$tag"
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y codium
    ;;
  *)
    printf '%s unsupported OS: %s\n' "$tag" "$(uname -s)" >&2
    exit 1
    ;;
esac
