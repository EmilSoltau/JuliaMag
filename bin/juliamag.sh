#!/usr/bin/env bash
# Start JuliaMag from this repo: bin/juliamag.sh [project folder]
#
# The optional argument is a project folder to open.
# Set JULIA to use another Julia than the one on the PATH.
# Until the app is packaged (plan 5), this is how to start it.
set -euo pipefail

bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$bin_dir")"

exec "${JULIA:-julia}" -t auto,1 --project="$repo/JuliaMagUI" \
    -e 'using JuliaMagUI; JuliaMagUI.main(ARGS)' "$@"
