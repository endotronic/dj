# Launch opencode in this repo -- the opencode counterpart of the claude
# module's `dj claude`, same cwd and arg conventions. opencode reads
# AGENTS.md, and .claude/skills/ as a fallback, so it gets the same
# project context. Args become a one-shot query via `opencode run`
# (streams its own output, so no spinner); no args -> TUI.
# Pass -y or --yolo (anywhere in args) to add --auto. -r/--resume maps
# to opencode's --continue; -c/--continue and -s/--session pass through.
# Any of those skips `run` (resume implies an interactive session).
# $DJ_OPENCODE_LAUNCHER or ~/.config/dj/opencode/launcher, when executable,
# runs in place of opencode with the same arguments.
alias o := opencode

opencode *ARGS:
    #!/bin/sh
    set -eu
    sh "{{SCRIPTS}}/module.sh" enabled opencode || { echo "the 'opencode' module is not enabled here; enable it with: dj module enable opencode" >&2; exit 2; }
    command -v opencode >/dev/null 2>&1 || { echo "opencode not on PATH; install opencode first" >&2; exit 127; }
    auto_flag=""
    resuming=0
    # Counted rotation, as in the claude recipe: "$@" holds the caller's
    # words with their boundaries (set positional-arguments), and every
    # word that is not this recipe's own flag goes back on the end of it,
    # still one argument per word -- never collected into a string and
    # expanded unquoted, which would split a value with a space in it
    # (-s "my session") and glob-expand anything with a * or ?.
    n=$#
    while [ "$n" -gt 0 ]; do
      arg=$1
      shift
      n=$((n - 1))
      case "$arg" in
        -y|--yolo)              auto_flag="--auto" ;;
        -r|--resume)            resuming=1; set -- "$@" --continue ;;
        -c|--continue|-s|--session) resuming=1; set -- "$@" "$arg" ;;
        *)                      set -- "$@" "$arg" ;;
      esac
    done
    # Your own launcher, if you have one, runs in place of opencode (to
    # export the one secret your opencode.json reads, say).
    launcher=${DJ_OPENCODE_LAUNCHER:-{{DJ_DIR}}/opencode/launcher}
    [ -x "$launcher" ] || launcher=opencode
    cd "{{justfile_directory()}}"
    if [ "$resuming" -eq 1 ] || [ "$#" -eq 0 ]; then
      exec "$launcher" "$@" ${auto_flag:+"$auto_flag"}
    else
      # A bare prompt: all the words, joined by single spaces, as one argument.
      exec "$launcher" run ${auto_flag:+"$auto_flag"} "$*"
    fi
