# Launch Claude Code in this repo, with the project skills for operating
# your dj setup (and CLAUDE.local.md, your own notes, when you have one).
# Args become a one-shot query via `claude -p`; no args -> interactive,
# which needs a terminal (headless with no prompt explains itself rather
# than inheriting claude's confusing print-mode error). A prompt piped on
# stdin works either way.
# Pass -y or --yolo (anywhere in args) to add --dangerously-skip-permissions.
# Remote Control is OFF by default (it mirrors the session to another
# device); pass --remote-control to opt in. The --settings guard below
# keeps remoteControlAtStartup from re-arming it from a settings file.
# Always enables auto-mode. If -r/--resume is present, -p/--print is
# skipped (resume implies an interactive session).
# Runs `claude` itself, or your own launcher in its place: an executable
# at $DJ_CLAUDE_LAUNCHER, else ~/.config/dj/claude/launcher (private
# repo). A launcher gets the same arguments, plus DJ_CLAUDE_REMOTE_CONTROL
# (1 or 0) in its environment.
alias c := claude

claude *ARGS:
    #!/bin/sh
    set -eu
    sh "{{SCRIPTS}}/module.sh" enabled claude || { echo "the 'claude' module is not enabled here; enable it with: dj module enable claude" >&2; exit 2; }
    command -v claude >/dev/null 2>&1 || { echo "claude not on PATH; install Claude Code first" >&2; exit 127; }
    yolo_flag=""
    # Remote Control is off unless asked for. The --settings guard below
    # keeps a settings file's remoteControlAtStartup from arming it behind
    # this recipe's back; it's skipped when the caller passed their own
    # --settings, since only one such flag can take effect.
    rc=0
    resuming=0
    user_settings=""
    prompt=""
    # Sort the caller's arguments into three buckets: flags this recipe owns,
    # flags to hand straight to claude, and the prompt text.
    #
    # "$@" is the caller's own argv, one element per word, because of the
    # `set positional-arguments` at the top of this file. Interpolating
    # {{ARGS}} instead -- what this recipe used to do -- hands the whole line
    # to this shell to re-parse, which silently expands $HOME inside a prompt,
    # runs its backticks, and glues --settings' JSON value onto the word after
    # it. A counted rotation (POSIX has no arrays) rebuilds the pass-through
    # list with the boundaries it came in with.
    #
    # Telling a prompt from a flag's value is the one genuinely ambiguous
    # thing here: `dj claude --model opus hi` has two bare words and only one
    # is the prompt. The answer is claude's own, so this lists the flags that
    # take a value (from `claude --help`). A flag missing from the list
    # degrades to what this recipe always did -- its value read as prompt
    # text -- so staleness is a wrong prompt, never a lost one.
    n=$#
    while [ "$n" -gt 0 ]; do
      arg=$1
      shift
      n=$((n - 1))
      case "$arg" in
        -y|--yolo)
          yolo_flag="--dangerously-skip-permissions" ;;
        --remote-control)    rc=1 ;;
        --no-remote-control) rc=0 ;;
        -r|--resume)
          resuming=1 ;;
        -p|--print)
          # Added below, only when there's a prompt to go with it; -r means
          # an interactive session, where it would be wrong.
          ;;
        --settings)
          if [ "$n" -eq 0 ]; then
            echo "dj claude: --settings needs a value" >&2
            exit 2
          fi
          user_settings=$1
          shift
          n=$((n - 1))
          set -- "$@" --settings "$user_settings" ;;
        --settings=*)
          user_settings=${arg#--settings=}
          set -- "$@" --settings "$user_settings" ;;
        -*)
          # A flag this recipe doesn't know: pass it through, and if it's one
          # that takes a value, carry the value with it so the word after it
          # isn't mistaken for the prompt.
          set -- "$@" "$arg"
          case "$arg" in
            --model|--fallback-model|--agent|--agents|--effort|--name|-n|\
            --system-prompt|--append-system-prompt|--input-format|\
            --output-format|--permission-mode|--session-id|--setting-sources|\
            --debug-file|--plugin-dir|--plugin-url|--max-budget-usd|\
            --add-dir|--mcp-config|--tools|--allowedTools|--allowed-tools|\
            --disallowedTools|--disallowed-tools|--betas|--file|--json-schema)
              if [ "$n" -gt 0 ]; then
                set -- "$@" "$1"
                shift
                n=$((n - 1))
              fi ;;
          esac ;;
        *)
          prompt="$prompt $arg" ;;
      esac
    done
    prompt="${prompt# }"
    rc_settings=""
    if [ "$rc" -eq 1 ]; then
      rc_flag="--remote-control"
      if [ -z "$user_settings" ]; then
        rc_settings='{"remoteControlAtStartup":true}'
      fi
    else
      rc_flag=""
      if [ -z "$user_settings" ]; then
        rc_settings='{"remoteControlAtStartup":false}'
      fi
    fi
    DJ_CLAUDE_REMOTE_CONTROL=$rc
    export DJ_CLAUDE_REMOTE_CONTROL
    launcher=${DJ_CLAUDE_LAUNCHER:-{{DJ_DIR}}/claude/launcher}
    [ -x "$launcher" ] || launcher=$(command -v claude)
    cd "{{justfile_directory()}}"
    # "$@" now holds only the flags being passed through; put the session
    # selector in front of them, then this recipe's own flags in front of
    # that. Each `set --` keeps every word its own argument.
    if [ "$resuming" -eq 1 ]; then
      set -- -r "$@"
      [ -z "$prompt" ] || set -- "$@" "$prompt"
    elif [ -n "$prompt" ]; then
      set -- -p "$prompt" "$@"
    fi
    if [ -n "$rc_settings" ]; then
      set -- --settings "$rc_settings" "$@"
    fi
    set -- --enable-auto-mode "$@"
    [ -z "$rc_flag" ] || set -- "$rc_flag" "$@"
    [ -z "$yolo_flag" ] || set -- "$yolo_flag" "$@"
    if [ "$resuming" -eq 1 ]; then
      "$launcher" "$@"
    elif [ -z "$prompt" ]; then
      # No prompt means an interactive session, which needs a terminal.
      # Without one, claude silently switches to print mode and then fails
      # on the empty input with "Input must be provided either through
      # stdin or as a prompt argument when using --print" -- naming a flag
      # this recipe never passed. Say what is actually wrong instead.
      #
      # A pipe or a redirected file still falls through untouched: claude
      # reads the prompt from stdin, which is how `echo ... | dj claude`
      # works. Everything else -- a closed stdin, or /dev/null, which is
      # neither a terminal nor readable -- gets the explanation rather than
      # claude's message about a flag this recipe never sent.
      if [ -t 0 ] || [ -p /dev/stdin ] 2>/dev/null || [ -f /dev/stdin ] 2>/dev/null; then
        "$launcher" "$@"
      else
        echo "dj claude: no prompt given, and stdin is not a terminal to open a session in." >&2
        echo "  pass one:  dj claude \"your question\"" >&2
        echo "  or pipe it: echo \"your question\" | dj claude" >&2
        exit 2
      fi
    else
      tmpout=$(mktemp)
      tmperr=$(mktemp)
      "$launcher" "$@" >"$tmpout" 2>"$tmperr" &
      pid=$!
      i=0
      while kill -0 "$pid" 2>/dev/null; do
        case $((i % 4)) in
          0) s='-' ;; 1) s="\\" ;; 2) s='|' ;; 3) s='/' ;;
        esac
        printf '\r%s Thinking...' "$s" >&2
        sleep 0.1
        i=$((i + 1))
      done
      printf '\r                  \r' >&2
      wait "$pid" && rc=0 || rc=$?
      cat "$tmperr" >&2
      cat "$tmpout"
      rm -f "$tmpout" "$tmperr"
      exit "$rc"
    fi

# Snapshot the Claude Code login into your secrets (Linux/WSL) so other machines restore it.
claude-creds-snapshot:
    @just --justfile "{{justfile()}}" _require-module claude
    sh "{{justfile_directory()}}/modules/claude/claude-creds-snapshot.sh"
