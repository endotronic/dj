# Bootstrap another machine over SSH from this one: forwards an ssh-agent with
# this machine's key, pushes the age key (and a private-repo clone key, if you
# use one), and runs install.sh there with this machine's --private-repo.
# Extra args pass through to install.sh. Usage: dj setup [user@]host [args...]
setup HOSTSPEC *ARGS:
    @just --justfile "{{justfile()}}" _require-module fleet
    sh "{{justfile_directory()}}/modules/fleet/dj-setup.sh" "$@"

# As root on an existing machine: create (or reuse) your own account there and
# bootstrap it. Usage: dj setup-root host [install.sh args...]
setup-root HOSTSPEC *ARGS:
    @just --justfile "{{justfile()}}" _require-module fleet
    sh "{{justfile_directory()}}/modules/fleet/dj-setup-root.sh" "$@"

# Add this (or another) machine to ~/.ssh/config, grouped by system type.
ssh-register *ARGS:
    @just --justfile "{{justfile()}}" _require-module fleet
    sh "{{justfile_directory()}}/modules/fleet/ssh-menu-register.sh" "$@"
