#!/usr/bin/env bash
# Start JuliaMag from this repo: bin/juliamag.sh [project folder]
#
# The optional argument is a project folder to open.
# Set JULIA to use another Julia than the one on the PATH.
# The script may be a symlink, for example in ~/.local/bin.
# Until the app is packaged (plan 5), this is how to start it.
set -euo pipefail
unset CDPATH   # else cd may print the folder and spoil the paths below

# The real place of this script, following symlinks.
self="${BASH_SOURCE[0]}"
if resolved="$(readlink -f "$self" 2>/dev/null)" && [ -n "$resolved" ]; then
    self="$resolved"
else   # an older macOS readlink has no -f
    while [ -L "$self" ]; do
        dir="$(cd -P "$(dirname "$self")" && pwd)"
        self="$(readlink "$self")"
        case "$self" in
            /*) ;;
            *) self="$dir/$self" ;;
        esac
    done
fi
bin_dir="$(cd -P "$(dirname "$self")" && pwd)"
repo="$(dirname "$bin_dir")"

julia="${JULIA:-julia}"
if ! command -v "$julia" > /dev/null 2>&1; then
    echo "JuliaMag needs Julia 1.12 or newer." >&2
    echo "Install it from https://julialang.org/downloads/ and put it on the PATH, or set JULIA to its path." >&2
    exit 1
fi

# start.jl installs the packages on the first start, then starts the app.
exec "$julia" -t auto,1 --project="$repo/JuliaMagUI" "$repo/bin/start.jl" "$@"
