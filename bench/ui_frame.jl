# UI frame time with a big database (docs/bench.md, "UI frame time with a big database").
#
# Usage, from the repo root (needs a display):
#   julia --project=JuliaMagUI/tools -e 'using Pkg; Pkg.instantiate()'   # once
#   julia -t auto,1 --project=JuliaMagUI bench/ui_frame.jl [FRAMES]
#
# It opens the app in a window with a project of one database of 5,000 lines and 300
# channels, opens its Lines and Channels folders in the Data tree, and draws FRAMES frames
# (default 200) with the tree still, then FRAMES frames scrolled to a new place each time.
# It does this at scale 1 and at scale 1.5, and prints the draw time (`draw_app` on the
# CPU), its 95th percentile, the time from frame to frame and the tree rows drawn.
# It uses the window test harness, so ImGuiTestEngine comes from JuliaMagUI/tools.

Base.find_package("ImGuiTestEngine") === nothing &&
    push!(LOAD_PATH, joinpath(dirname(@__DIR__), "JuliaMagUI", "tools"))

module UIFrameBench

using Statistics: median
const TEST = joinpath(dirname(@__DIR__), "JuliaMagUI", "test")
include(joinpath(TEST, "support", "app.jl"))
include(joinpath(TEST, "support", "state.jl"))

function measure(scale::Float32, frames::Int)
    size = scale == 1f0 ? (1480, 920) : (round(Int, 1480 * scale), round(Int, 920 * scale))
    rows = []
    with_project_app(session_with(lines = 5_000, channels = 300); scale, size, timeout = 600) do ctx, app
        db = app.ui.current_db
        union!(app.ui.expanded, ["databases", db, "$db/lines", "$db/channels"])
        ctx.frames(20)   # warm up
        for case in ("still", "scrolling")
            draw = Int[]
            t0 = time()
            for k in 1:frames
                case == "scrolling" && (app.ui.tree_scroll = Float32(k * 600))
                ctx.frames(1)
                push!(draw, app.draw_ns)
            end
            wall = (time() - t0) / frames
            sort!(draw)
            push!(rows, (; case, median = median(draw) / 1e6,
                p95 = draw[clamp(round(Int, 0.95 * frames), 1, frames)] / 1e6,
                wall = 1000 * wall, drawn = app.ui.tree_drawn))
        end
    end
    return rows
end

function main(args)
    has_display() || (println(stderr, "ui_frame.jl: there is no display"); return 1)
    frames = isempty(args) ? 200 : parse(Int, args[1])
    println("All times in ms.")
    println("scale  case       draw median  draw p95  wall per frame  rows drawn")
    for scale in (1f0, 1.5f0)
        for r in measure(scale, frames)
            println(rpad(scale, 7), rpad(r.case, 11), rpad(round(r.median; digits = 2), 13),
                rpad(round(r.p95; digits = 2), 10), rpad(round(r.wall; digits = 1), 16), r.drawn)
        end
    end
    return 0
end

end

exit(UIFrameBench.main(ARGS))
