# UI idle CPU benchmark (docs/bench.md, "UI idle CPU").
#
# Usage, from the repo root (needs a display, Linux):
#   julia bench/ui_idle.jl [SECONDS]
#
# It starts a fresh process `julia -t auto,1 --project=JuliaMagUI` that runs `main()` with
# no project. After the first 5 s (the start, and the burst of events when the window
# shows), it reads the process's CPU time, waits SECONDS (default 20) with no input, and
# reads it again. It prints the CPU use while idle, in % of one core, and the frames drawn.
# The CPU time comes from /proc/self/stat, so it runs on Linux only.

const ROOT = dirname(@__DIR__)
const JULIA = joinpath(Sys.BINDIR, Base.julia_exename())

const CHILD = """
using JuliaMagUI
const TICKS = 100   # clock ticks per second of /proc (USER_HZ)
cpu() = sum(parse.(Int, split(read("/proc/self/stat", String))[14:15])) / TICKS
seconds = parse(Float64, ARGS[1])
t0 = time()
start = Ref((0.0, 0.0, 0))   # wall, CPU, frame at the start of the idle time
JuliaMagUI.main(extra_ui = w -> begin
    now = time()
    if start[][1] == 0 && now - t0 > 5
        start[] = (now, cpu(), w.frame)
    elseif start[][1] > 0 && now - start[][1] >= seconds
        wall, c, f = now - start[][1], cpu() - start[][2], w.frame - start[][3]
        println("IDLE ", wall, " ", c, " ", f)
        flush(stdout)
        JuliaMagUI.quit!(w)
    end
    nothing
end)
"""

function main(seconds::Float64)
    Sys.islinux() || error("bench/ui_idle.jl reads /proc and runs on Linux only")
    run(`$JULIA --project=$(joinpath(ROOT, "JuliaMagUI")) -e "using JuliaMagUI"`)   # precompile, not timed
    out = mktempdir() do config_dir
        cmd = addenv(`$JULIA -t auto,1 --project=$(joinpath(ROOT, "JuliaMagUI")) -e $CHILD $seconds`,
            "JULIAMAG_CONFIG_DIR" => config_dir)
        read(cmd, String)
    end
    m = match(r"IDLE (\S+) (\S+) (\S+)", out)
    m === nothing && error("the child process printed no result:\n$out")
    wall, cpu, frames = parse(Float64, m[1]), parse(Float64, m[2]), parse(Int, m[3])
    println("idle for ", round(wall; digits = 1), " s: CPU ", round(100 * cpu / wall; digits = 1),
        " % of one core, ", frames, " frames (", round(frames / wall; digits = 1), " per second)")
    return nothing
end

main(isempty(ARGS) ? 20.0 : parse(Float64, ARGS[1]))
