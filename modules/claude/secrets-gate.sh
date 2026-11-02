#!/bin/sh
# secrets-gate.sh -- a Claude Code PreToolUse hook (claude module).
#
# Receives one tool-call JSON on stdin; prints a "deny" decision when the
# command would pull materialized plaintext secrets into the session's
# context, and stays silent otherwise. It exists because Claude Code's
# permission deny rules gate the Read/Edit tools by path but cannot say
# "no Bash command may read these paths" -- and the Bash tool runs any-
# thing. Install/update the registration via `dj migrate --fix --only
# claude-secrets-rules`; the rules themselves live here, not in
# settings.json, so they travel with the repo.
#
# Three deny shapes:
#   1. A reader (cat/head/tail/grep/sed/python/...) or `cp`, naming a
#      plaintext secret path anchored to the real home (~, $HOME, the
#      absolute path): ~/.secrets/**, ~/.private/** minus *.enc/*.pub/
#      .sops.yaml (ciphertext and recipient config are not secrets), the
#      age key, Claude Code's own credential, ~/.gnupg/**, ~/.netrc,
#      ~/.aws/credentials, ~/.ssh/*id_* private keys (*.pub is fine),
#      and any extra home-relative path listed in
#      ~/.config/dj/claude/secret-paths.txt (one per line, * and **
#      globs, # comments) -- for plaintext an app keeps elsewhere.
#      Inert verbs (ls, stat, wc, ssh-keygen) and paths anchored
#      somewhere else (a bats fixture under $SANDBOX/...) pass.
#   2. A decryptor run as the tool call itself: `sops`/`age -d` pointed at
#      the secrets dirs streams plaintext to stdout even though the path
#      named is only ciphertext. doctor's canary (`sops --decrypt
#      ~/.private/.sops.yaml`) names no secret path and stays allowed;
#      hooks, dj recipes and apply-secrets decrypt inside their own
#      processes, which a tool-call gate never sees.
#   3. An environment dump: env/printenv/set/export/declare -x at the start
#      of any command segment, alongside a credential-shaped name. (A bare
#      dump naming nothing credential-shaped is NOT denied -- blocking
#      every `env` would break routine PATH debugging; what keeps a bare
#      one harmless is that nothing is exported.) shell/secrets.sh
#      keeps values unexported precisely so this shows nothing;
#      the rule is the backstop for shells where they leaked back in.
#
# Deliberate non-denials: commands that never name a secret path. The
# launchers that read a secret for a tool, dj recipes and
# apply-secrets read the files inside processes whose stdout never becomes
# context. Reading a secret to USE it stays possible; pulling one INTO
# context is what this blocks. Registering one (`dj secret-add`) is
# allowlisted up front. Commit/PR message bodies (the quoted string
# after -m/-am/--message/--body/--title) are blanked before every check:
# they flow into git, not into new context -- and without this the gate
# denies itself just for documenting the gate, as its first live run
# proved.
#
# Honest residual: indirection (a variable holding the path, a wildcard,
# a generated script, a sandbox copy, a heredoc-fed commit message, or a
# $(substitution) inside a stripped message) defeats a textual scan --
# and a secret smuggled through such a substitution leaks to the repo,
# not to context. This gate aims at incidental exposure by a reasonably-
# behaved model, not at an adversary holding the machine's keys.
#
# Known false positive, kept deliberately: an interpreter fed a heredoc
# (python3 - <<'EOF' ...) whose body merely MENTIONS a secret path as text
# -- editing docs or tests about this gate, say -- is denied, because
# textually it is indistinguishable from one that opens the file. The
# workaround is to write the script to a file and run that.
set -eu

input=$(cat)

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

h=${HOME:-}
[ -n "$h" ] || exit 0 # no home to anchor to -- stay permissive

# --- what gets scanned: the DECODED command text ------------------------------
# Every rule below wants the command's own syntax -- real separators,
# quotes, newlines -- not those characters JSON-escaped inside a string.
# Grepping raw JSON is what made early versions misfire: "env needs
# command position" inside a commit message read as a separator-led env
# dump. jq decodes .tool_input.command exactly (jq is required by the
# secrets-rules migration, so it is present wherever the hook is
# registered); without it or without a command field, fall back to the
# raw JSON, which still catches absolute-path readers.
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
target=$input
[ -n "$cmd" ] && target=$cmd

# `dj secret-add` encrypts a file: routine config work that names a
# plaintext path on purpose and never prints contents. Exempt only when the
# decoded command IS that invocation -- one line, no chaining, no command
# substitution -- so mentioning the word elsewhere ("... ; # secret-add",
# `grep secret-add ~/.secrets/x`) buys nothing.
if [ -n "$cmd" ] \
   && printf '%s' "$cmd" | grep -Eq '^[[:space:]]*((dj|just)[[:space:]]+secret-add|(sh[[:space:]]+)?[^[:space:];&|]*secret-add\.sh)([[:space:]]|$)' \
   && ! printf '%s' "$cmd" | grep -Eq '[;&|`]|\$\(' \
   && [ "$(printf '%s' "$cmd" | wc -l)" -eq 0 ]; then
  exit 0
fi

# --- strip helpers ------------------------------------------------------------
# sed is line-oriented, so a region spanning newlines (a multi-line commit
# message) can never match. Both strips therefore run on newline-flattened
# text (\001 sentinel) and restore the newlines afterwards, which keeps
# grep's line-based `^` working for shape 3's command-position test.
# One POSIX function per strip, since there are no arrays/local here.
flatten() { tr '\n' '\001'; }
unflatten() { tr '\001' '\n'; }

# The message body after a -m/-am (any short bundle ending in m) or
# --message/--body/--title flag is prose. Deliberately NOT "any flag with an
# m in it": --number/--max-count/--mode would then blank the quoted path
# after them and let `cat --number "$HOME/.secrets/x"` through.
# The opening quote may be escaped (raw-JSON fallback: every quote there
# is `\"`), and escaped quotes inside the body are stepped over as
# backslash+pairs. Single-quoted messages match as a plain region.
strip_msgs() {
  flatten | sed -E "s#([[:space:]](-[A-Za-z]*m|--(message|body|title)))(=|[[:space:]]+)(\\\\?\"[^\"\\\\]*((\\\\)[^\"\\\\]*)*\\\\?\"|'[^']*')# MSGSTRIPPED #g" | unflatten
}

# For shape 3: quoted strings anywhere are data, not syntax --
# `echo "printenv shows nothing"` is prose. Shape 1/2 must NOT use this,
# because a real command quotes real paths (cat "$HOME/.secrets/x").
strip_quotes() {
  flatten | sed -E 's#\\?"[^"\\]*(\\.[^"\\]*)*\\?"# STRSTRIPPED #g; s#'"'"'[^'"'"']*'"'"'# STRSTRIPPED #g' | unflatten
}

target=$(printf '%s' "$target" | strip_msgs)

# For shape 3 only.
syntax=$(printf '%s' "$target" | strip_quotes)

# Ciphertext and public-half references blanked: what survives is plaintext.
stripped=$(printf '%s' "$target" \
  | sed -E 's#(\.private|\.secrets)/[^"'"'"'[:space:]]*\.(enc|pub)#STRIPPED#g; s#\.private/\.sops\.yaml#STRIPPED#g; s#[^"'"'"'[:space:]]*\.ssh/[^"'"'"'[:space:]]*\.pub#STRIPPED#g')

# --- shape 1: reader + anchored plaintext path -------------------------------
# Anchors: `~`, `$HOME`/`${HOME}`, and the absolute home path (regex-
# escaped). A sandbox path like $SANDBOX/home/.secrets matches none, so
# bats fixtures run free. .ssh/*id_* is the private-key family; the
# *.pub/authorized_keys/config neighbors were blanked above.
h_esc=$(printf '%s' "$h" | sed 's/[][\.*^$]/\\&/g')
A='(\$\{?HOME\}?|~|'"${h_esc}"')'
# Extra plaintext paths the user lists, as regex alternatives (glob ->
# regex: escape dots, ** -> anything, * -> one path segment).
extra=
_paths=${DOTFILES_DJ_DIR:-${XDG_CONFIG_HOME:-$h/.config}/dj}/claude/secret-paths.txt
if [ -r "$_paths" ]; then
  extra=$(awk 'NF && $1 !~ /^#/ { print $1 }' "$_paths" \
    | sed 's#^~/##; s#[.]#\\.#g; s#[*][*]#@@#g; s#[*]#[^/]*#g; s#@@#.*#g' \
    | paste -sd'|' -)
fi
tok="${A}/(\.(secrets|private|gnupg)([/[:space:]\"']|$)|\.config/sops/age/keys\.txt|\.claude/\.credentials|\.aws/credentials|\.netrc([^A-Za-z0-9]|$)|\.ssh/[A-Za-z0-9_.+-]*id_[A-Za-z0-9_.+-]*${extra:+|$extra})"
# The anchored paths, plus /proc/<pid>/environ: a process's environment is
# a secret path too (reading /proc/self/environ is printenv without the word).
tok_all="($tok)|/proc/[A-Za-z0-9]+/environ"
# Content-showing readers only. Not source/curl/scp/rsync: sourcing a file
# to expand $TOKEN into an API call is the legitimate way to USE a secret,
# and sending one somewhere is not showing it to the model.
readers='(^|[^A-Za-z0-9_.-])(cat|tac|rev|head|tail|less|more|strings|od|xxd|hexdump|base64|base32|sort|uniq|cut|nl|paste|column|fold|expand|tr|comm|join|diff|cmp|awk|sed|grep|egrep|fgrep|rg|tee|dd|jq|yq|cp|bat|batcat|pbcopy|python|python3|perl|ruby|node|php|lua)([^A-Za-z0-9_-]|$)'
# One pipeline/list segment at a time (| ; & and newlines split; a trailing
# backslash joins lines first): a reader only counts when it shares a
# segment with the path. Listing names piped into grep filters names, not
# contents; a reader piped from the path has the reader beside the path.
segments=$(printf '%s' "$stripped" \
  | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' | tr '|;&' '\n\n\n')
hit=$(printf '%s\n' "$segments" | while IFS= read -r seg; do
  if printf '%s' "$seg" | grep -Eq "$tok_all" && printf '%s' "$seg" | grep -Eq "$readers"; then
    echo 1; break
  fi
done)
# xargs is the one reader that takes its operand from an earlier segment
# (a listing of the secrets dir piped into xargs cat), so it pairs with a
# path anywhere in the command.
if [ -z "$hit" ] && printf '%s' "$stripped" | grep -Eq "$tok_all" \
   && printf '%s' "$stripped" | grep -Eq '(^|[^A-Za-z0-9_.-])xargs([^A-Za-z0-9_-]|$)'; then
  hit=1
fi
if [ -n "$hit" ]; then
  deny "claude-secrets-gate: this reads materialized plaintext secrets (~/.secrets, ~/.private, the age key, Claude Code's credential, ~/.gnupg, ~/.netrc, ~/.aws/credentials, an SSH private key, or a path in secret-paths.txt) into context. To USE a secret, run the launcher/recipe that reads the file itself (dj apply-secrets, or a launcher of your own). To view or edit one, have the user run it outside this session (sops <file>, dj secret-edit)."
fi

# --- shape 2: a decryptor as the tool call ------------------------------------
# Grep $target (enc paths were blanked from $stripped). sops/age can
# appear quoted in a real command (bash -c "sops -d ..."), so this shape
# does not use $syntax -- but the decryptor must sit in command position:
# the start of the command or of a ; & | ( $( ` segment, or just inside an
# opening quote, after any sudo/env/exec/xargs-style prefix and NAME=value
# assignments. The word alone is not a decryption: `echo "... NOT
# sops-encrypted"` beside .enc paths, or `grep -q sops` over ciphertext,
# merely mentions it.
cpos='(^|[;&|(`"'"'"']|\$\()[[:space:]]*(((sudo|doas|env|exec|command|nohup|time|xargs)([[:space:]]+-[^[:space:]]*)*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*'
if printf '%s' "$target" | grep -Eq "${cpos}sops([[:space:]]|\$)"; then
  if printf '%s' "$target" | grep -Eq '\.private/secrets/|\.secrets/|\.enc'; then
    deny "claude-secrets-gate: decrypting a secrets file inside this session streams its plaintext into context. Have the user run it in their own shell: dj secret-edit <path>, or sops <file>."
  fi
fi
if printf '%s' "$target" | grep -Eq "${cpos}age([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(-d|--decrypt)([[:space:]]|\$)" \
   && printf '%s' "$target" | grep -Eq '\.enc'; then
  deny "claude-secrets-gate: decrypting with age inside this session streams plaintext into context."
fi

# --- shape 3: environment dumps -----------------------------------------------
# grep is line-based, so on decoded text ^ is true command position: the
# start of the command or of a ; / newline segment. A *dump* is printenv,
# or env/set/export with nothing following but a pipe/redirect/end, or
# declare/typeset -x/-p, compgen -e -- `env -i …`
# and `env NAME=v cmd` run programs with a modified environment and leak
# nothing, so they must not match (nor does `#!/usr/bin/env`). The dump
# and a credential-shaped name must both survive quote-stripping, which
# is what tells a real dump apart from prose that merely mentions one.
if printf '%s' "$syntax" | grep -Eq '(^|[;&|(])[[:space:]]*(printenv([[:space:]]|$)|(env|set|export)([[:space:]]*($|[|>&;]))|export[[:space:]]+-p([[:space:]]|$)|(declare|typeset)[[:space:]]+-[A-Za-z]*[xp]|compgen[[:space:]]+-e)'; then
  if printf '%s' "$syntax" | grep -Eqi '(api[_-]?key|apikey|token|secret|passw|credential|psk)'; then
    deny "claude-secrets-gate: dumping the environment hands every exported secret value to this session's model. shell/secrets.sh keeps them unexported for exactly this reason. If a tool needs one variable, name it on that tool's command line (FOO=... tool)."
  fi
fi

exit 0
