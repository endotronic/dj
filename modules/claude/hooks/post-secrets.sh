#!/bin/sh
# claude module, after secrets are applied: turn on the tracked status
# line (if you track one) and the settings that keep plaintext secrets out
# of a session. Both are migrations, so `dj migrate --fix` repeats this on
# machines bootstrapped before the module was enabled.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
sh "$here/scripts/migrate.sh" --fix --only claude-statusline --only claude-secrets-rules --only claude-local-context
