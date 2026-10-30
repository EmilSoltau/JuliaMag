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
include("shell/draw.jl")
include("app/toasts.jl")
include("app/worker.jl")
include("app/state.jl")
include("commands/commands.jl")
include("commands/keys.jl")
include("app/modal.jl")
include("panes/panes.jl")
include("shell/shell.jl")
include("shell/menu.jl")
include("shell/ribbon.jl")
include("shell/header.jl")
include("shell/tabs.jl")
include("shell/statusbar.jl")
include("shell/central.jl")
include("panes/data.jl")
include("dialogs/item_dialogs.jl")

"""
    main(; project = nothing, config_dir = config_dir(), extra_ui = nothing, on_app = nothing,
         size = (1480, 920), scale = nothing, fonts = :system, engine = nothing,
         passive = false)

Start the app: the window with the shell (`draw_app`). Opening `project` comes in a later
task. The theme comes from the settings in `config_dir`.
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
    guarded_frame(app) do
        t = time_ns()
        draw_app(app)
        app.draw_ns = Int(time_ns() - t)
        a.extra_ui === nothing || a.extra_ui(w)
    end
    return nothing
end

"""
    guarded_frame(f, app)

Draw a frame with `f()`. An error in it never ends the app: ImGui's stacks (windows, ids,
fonts, styles) go back to how they were before `f`, so the frame ends cleanly, and the
error is noted with `note_draw_error!`.
"""
function guarded_frame(f, app)
    state = Ref{lib.ImGuiErrorRecoveryState}()
    lib.igErrorRecoveryStoreState(state)
    try
        f()
    catch e
        e isa InterruptException && rethrow()
        bt = catch_backtrace()
        recover_imgui_state(state)
        note_draw_error!(app, e, bt)
    end
    return nothing
end

const MAX_DRAW_ERRORS = 100   # different errors kept; more are only logged at debug level

"""
    note_draw_error!(app, e, backtrace)

Note an error that cut a frame short. The first time an error comes (by type and
message) it is logged with its backtrace and shown as an error toast; after that it is
only counted, so an error in every frame gives one toast and one log entry.
"""
function note_draw_error!(app, @nospecialize(e), bt)
    key = draw_error_key(e)
    k = findfirst(d -> d.key == key, app.draw_errors)
    if k !== nothing
        app.draw_errors[k].count += 1
        return nothing
    end
    if length(app.draw_errors) >= MAX_DRAW_ERRORS
        @debug "Another error while drawing" key
        return nothing
    end
    text = draw_error_text(e)
    push!(app.draw_errors, DrawError(key, text, 1))
    @error "An error cut a frame short; the app goes on" exception = (e, bt)
    toast!(app, :error, text)
    return nothing
end

function draw_error_key(@nospecialize(e))::String
    try
        return string(typeof(e), ": ", sprint(showerror, e))
    catch
        return string(typeof(e))
    end
end

# The toast text of a draw error, as `user_message` gives it but without logging.
function draw_error_text(@nospecialize(e))::String
    try
        e isa USER_ERRORS && return plain_message(e)
        return "Something went wrong: " * sprint(showerror, e)
    catch
        return "Something went wrong."
    end
end

include("app/precompile.jl")

function __init__()
    ICON_SVGS[] = nothing   # read the icon files again, not the copy from precompiling
    return nothing
end

end
