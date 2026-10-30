# UI startup benchmark (docs/bench.md, "UI startup").
#
# Usage, from the repo root (needs a display):
#   julia bench/ui_startup.jl [RUNS]
#
# It starts a fresh process `julia -t auto,1 --project=JuliaMagUI` RUNS times (default 3).
# Each process times `using JuliaMagUI` and the first frame that `main()` draws, then quits.
# The script prints each run and the median.
# It precompiles first, so the numbers are for a warm package cache.

using Statistics: median

const ROOT = dirname(@__DIR__)
const JULIA = joinpath(Sys.BINDIR, Base.julia_exename())

const CHILD = """
t0 = time()
using JuliaMagUI
t1 = time()
JuliaMagUI.main(extra_ui = w -> begin
    if w.frame == 0
        println("TIMES ", t0, " ", t1, " ", time())
        flush(stdout)
        JuliaMagUI.quit!(w)
    end
    nothing
end)
"""

project_cmd(code) = `$JULIA -t auto,1 --project=$(joinpath(ROOT, "JuliaMagUI")) -e $code`

# One fresh process. Returns (process start to Julia ready, using, first frame, total) in s.
function one_run(config_dir)
    cmd = addenv(project_cmd(CHILD), "JULIAMAG_CONFIG_DIR" => config_dir)
    start = time()
    out = read(cmd, String)
    m = match(r"TIMES (\S+) (\S+) (\S+)", out)
    m === nothing && error("the child process printed no times:\n$out")
    t0, t1, t2 = parse.(Float64, m.captures)
    return (; boot = t0 - start, load = t1 - t0, frame = t2 - t1, total = t2 - start)
end

function main(runs::Int)
    run(project_cmd("using JuliaMagUI"))   # precompile, not timed
    rows = mktempdir() do config_dir
        [one_run(config_dir) for _ in 1:runs]
    end
    ms(x) = round(Int, 1000 * x)
    println("run  julia start  using  first frame  total (ms)")
    for (i, r) in enumerate(rows)
        println(i, "    ", ms(r.boot), "  ", ms(r.load), "  ", ms(r.frame), "  ", ms(r.total))
    end
    med(f) = ms(median(map(f, rows)))
    println("median  ", med(r -> r.boot), "  ", med(r -> r.load), "  ",
        med(r -> r.frame), "  ", med(r -> r.total))
    return nothing
end

main(isempty(ARGS) ? 3 : parse(Int, ARGS[1]))
