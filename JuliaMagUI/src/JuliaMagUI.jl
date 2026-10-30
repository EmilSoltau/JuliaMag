module JuliaMagUI

import JuliaMagCore as Core
import CImGui as ig
import CImGui.lib as lib
import GLFW
import ModernGL as GL
import PNGFiles
import Cairo
import Rsvg
using JSON3
using PrecompileTools: @setup_workload, @compile_workload

include("theme/tokens.jl")
include("theme/fonts.jl")
include("app/config.jl")
include("app/x11.jl")
include("app/glfw_errors.jl")
include("app/loop.jl")
include("theme/icons.jl")
include("app/toasts.jl")
include("app/worker.jl")
include("app/state.jl")
include("commands/commands.jl")
include("commands/keys.jl")

"""
    main(; project = nothing, config_dir = config_dir(), extra_ui = nothing, on_app = nothing,
         size = (1480, 920), scale = nothing, fonts = :system, engine = nothing,
         passive = false)

Start the app. Today it opens the empty window; later tasks fill it and open `project`.
The theme comes from the settings in `config_dir`.
It makes the `AppState` and its worker, and stops the worker when the window closes.

The other keywords are for tests, screenshots and benchmarks:
`extra_ui(w)` is drawn after the app in every frame, `on_app(app)` gets the `AppState`
before the window opens, and `size`, `scale`, `fonts`, `engine` and `passive` go to
`run_window`.
"""
function main(; project::Union{Nothing,AbstractString} = nothing,
        config_dir::AbstractString = JuliaMagUI.config_dir(), extra_ui = nothing,
        on_app = nothing, size::Tuple{Integer,Integer} = (1480, 920),
        scale::Union{Nothing,Real} = nothing, fonts::Symbol = :system, engine = nothing,
        passive::Bool = false)
    project === nothing || @debug "Opening a project is not built yet" project
    config, _ = load_config(config_dir)   # a broken settings file gives the defaults
    dark = config.theme == THEME_SYSTEM ? system_dark() : false
    tokens = tokens_for(config.theme, dark)
    app = AppState(config, tokens; config_dir)
    try
        on_app === nothing || on_app(app)
        run_window(AppFrame(app, extra_ui); tokens, size, scale, fonts, engine, passive)
    finally
        app.window = nothing
        stop_worker!(app.queue)
    end
    return nothing
end

# One frame of the app, plus the optional test hook.
struct AppFrame
    app::AppState
    extra_ui::Any
end

function (a::AppFrame)(w::Window)
    app = a.app
    app.window = w
    drain!(app)
    refresh!(app)
    draw_empty(w)
    a.extra_ui === nothing || a.extra_ui(w)
    return nothing
end

include("app/precompile.jl")

function __init__()
    ICON_SVGS[] = nothing   # read the icon files again, not the copy from precompiling
    return nothing
end

end
