#!/bin/sh
# Install tree-sitter-cli via npm when it is not available in the distro's
# package repository (Debian/Ubuntu apt only ships a stale version, if any;
# pacman and brew ship a current one directly). Requires npm (a core
# dependency of this dotfiles setup, see common.txt).
set -eu
command -v tree-sitter >/dev/null 2>&1 && exit 0

printf '[tree-sitter] installing via npm\n'
sudo npm install -g tree-sitter-cli
