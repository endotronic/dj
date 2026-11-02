# Modules

Optional features, off until you enable them:

```sh
dj module list             # what exists, what's on here
dj module enable claude    # writes ~/.config/dj/modules.txt
dot add ~/.config/dj/modules.txt && dot commit -m 'dj: enable claude'
```

`modules.txt` lives in your private repo, so a module enabled once is
enabled on every machine after `dj sync`. On a fresh machine,
`install.sh --module NAME` enables it for the bootstrap itself and records
it in `modules.txt`.

A module is a directory here:

```
modules/<name>/
├── MODULE              # first line: one-sentence description
├── <name>.just         # recipes, imported by the Justfile (optional)
├── migrations/*.sh     # migrations, run only when enabled (optional)
├── hooks/<phase>.sh    # bootstrap hooks install.sh runs (optional)
└── ...                 # whatever scripts the above call
```

Bootstrap phases, in the order install.sh runs them:

| phase | when | typical use |
|---|---|---|
| `post-secrets` | after secrets are applied | register something that needs a secret |
| `finish` | last, before the summary | interactive extras |

Recipes in `<name>.just` start with `@sh "{{SCRIPTS}}/module.sh" enabled <name> || ...`
via the `_require-module` helper so a disabled module says how to enable it
instead of half-working.

Tests for a module go in `tests/<name>-*.bats` like everything else.
