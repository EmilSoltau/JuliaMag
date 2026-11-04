#!/usr/bin/env bash
# Run the JuliaMagUI tests on a virtual display, so no window opens on the desktop.
# Usage, from anywhere: bin/test-headless.sh [extra arguments for julia]
#
# It needs xvfb-run (Linux). Set JULIA to use another Julia than ~/.juliaup/bin/julia
# or the one on the PATH.
#
# It draws with Mesa's software renderer, so test timing does not depend on the GPU driver.
# Under WSL the GPU path can stall a frame for half a second, which fails the loop timing
# tests. Set JULIAMAG_TEST_GPU=1 to draw on the GPU instead.
set -euo pipefail
unset CDPATH

self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
repo="$(dirname "$(cd -P "$(dirname "$self")" && pwd)")"

if ! command -v xvfb-run > /dev/null 2>&1; then
    echo "bin/test-headless.sh needs xvfb-run, which is not installed." >&2
    echo "Install it with: sudo apt-get install -y xvfb" >&2
    exit 1
fi

if [ -n "${JULIA:-}" ]; then
    julia="$JULIA"
elif [ -x "$HOME/.juliaup/bin/julia" ]; then
    julia="$HOME/.juliaup/bin/julia"
else
    julia="julia"
fi

software=1
[ "${JULIAMAG_TEST_GPU:-0}" = "1" ] && software=0

cd "$repo"
# WAYLAND_DISPLAY is unset so GLFW uses the virtual X display, not the desktop.
exec xvfb-run -a -s "-screen 0 1920x1080x24" env -u WAYLAND_DISPLAY \
    LIBGL_ALWAYS_SOFTWARE="$software" "$julia" -t auto,1 --project=JuliaMagUI "$@" -e 'using Pkg; Pkg.test()'
