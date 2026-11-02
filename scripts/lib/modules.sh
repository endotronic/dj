# Opt-in modules: which are enabled, and where they live. Sourced (POSIX).
#
# A module is a directory modules/<name>/ in this repo holding optional
# features: just recipes (<name>.just), migrations (migrations/*.sh) and
# bootstrap hooks (hooks/<phase>.sh). It does nothing until enabled.
#
# Enabled = listed in ~/.config/dj/modules.txt (private repo, one name per
# line, # comments) or named in $DJ_MODULES (space- or comma-separated;
# install.sh sets it from its flags, before the private repo is cloned).

# Callers set DJ_LIB_DIR (this file's directory) before sourcing.
DJ_MODULES_DIR=${DJ_MODULES_DIR:-$(CDPATH= cd -- "${DJ_LIB_DIR:?}/../.." && pwd)/modules}

dj_modules_file() {
  printf '%s' "${DOTFILES_DJ_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dj}/modules.txt"
}

# Every enabled module name, once each, one per line.
dj_enabled_modules() {
  {
    printf '%s\n' "${DJ_MODULES:-}" | tr ', ' '\n\n'
    _mf=$(dj_modules_file)
    [ -f "$_mf" ] && awk 'NF && $1 !~ /^#/ { print $1 }' "$_mf"
  } | awk 'NF && !seen[$0]++'
}

dj_module_enabled() {
  dj_enabled_modules | grep -Fxq -- "$1"
}

dj_module_exists() {
  [ -f "$DJ_MODULES_DIR/$1/MODULE" ]
}
