# Icon atlas benchmark (docs/bench.md, "Icon atlas").
#
# Usage, from the repo root:
#   julia -t auto,1 --project=JuliaMagUI bench/ui_icons.jl [RUNS]
#
# It times `build_icon_atlas` (Rsvg and Cairo, no window) at scale 1, 1.5 and 2,
# and the full rebuild in a window at scale 2 (draw and upload the texture),
# RUNS times each (default 5), after one warm-up. It prints the best and the median.
# The window part needs a display.

using JuliaMagUI
using Statistics: median
const UI = JuliaMagUI

ms(x) = round(Int, 1000 * x)

function main(runs::Int)
    UI.build_icon_atlas(UI.LIGHT, 1f0)   # warm up
    println("build_icon_atlas, no window (ms)")
    for scale in (1f0, 1.5f0, 2f0)
        times = [@elapsed(UI.build_icon_atlas(UI.LIGHT, scale)) for _ in 1:runs]
        a = UI.build_icon_atlas(UI.LIGHT, scale)
        println("  scale $scale: best $(ms(minimum(times))), median $(ms(median(times))), ",
            "atlas $(a.width) x $(a.height)")
    end

    Sys.iswindows() || haskey(ENV, "DISPLAY") || haskey(ENV, "WAYLAND_DISPLAY") || return
    times = Float64[]
    mktempdir() do config_dir
        UI.main(; config_dir, fonts = :bundled, passive = true, extra_ui = w -> begin
            UI.request_frames!(w)
            if length(times) < runs + 1
                # Switch the scale so the atlas is stale, then time the rebuild and upload.
                UI.set_scale!(w, 1f0)
                UI.update_icons!(w)
                UI.set_scale!(w, 2f0)
                push!(times, @elapsed UI.update_icons!(w))
            else
                UI.quit!(w)
            end
            nothing
        end)
    end
    times = times[2:end]   # the first one is the warm-up
    println("update_icons! in a window at scale 2, build and upload (ms)")
    println("  best $(ms(minimum(times))), median $(ms(median(times)))")
end

main(isempty(ARGS) ? 5 : parse(Int, ARGS[1]))
