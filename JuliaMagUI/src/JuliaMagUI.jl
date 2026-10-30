module JuliaMagUI

import JuliaMagCore as Core
import CImGui as ig
import CImGui.lib as lib
import GLFW
import ModernGL as GL
import PNGFiles
import Cairo
import Rsvg
import NativeFileDialog
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
include("dialogs/form.jl")
include("dialogs/widgets.jl")
include("dialogs/tool_dialog.jl")
include("panes/jobs.jl")

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
    settle_draw_errors!(app)
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

const MAX_DRAW_ERRORS = 100   # different error sources kept; more are only logged at debug level
const DRAW_ERROR_QUIET = 3.0  # s without the error before its sticky toast goes

"""
    note_draw_error!(app, e, backtrace; now = time())

Note an error that cut a frame short. Errors are told apart by their type and the place
in JuliaMagUI they came from (`draw_error_key`), not by their message, so a message that
changes in every frame is still one error.

The first time, the error is logged with its backtrace and shown as a sticky error toast.
While it keeps coming it is only counted and its toast stays. When it has not come for
$(DRAW_ERROR_QUIET) s, `settle_draw_errors!` takes the toast away; if it comes back after
that, it is logged and shown again.
"""
function note_draw_error!(app, @nospecialize(e), bt; now::Real = time())
    key = draw_error_key(e, bt)
    k = findfirst(d -> d.key == key, app.draw_errors)
    if k === nothing
        if length(app.draw_errors) >= MAX_DRAW_ERRORS
            @debug "Another error while drawing" key
            return nothing
        end
        push!(app.draw_errors, DrawError(key, "", 0, 0, now, nothing))
        k = length(app.draw_errors)
    end
    d = app.draw_errors[k]
    d.count += 1
    d.last_seen = Float64(now)
    d.toast === nothing || return nothing   # still being reported
    d.text = draw_error_text(e)
    d.reports += 1
    @error "An error cut a frame short; the app goes on" exception = (e, bt)
    d.toast = toast!(app, :error, d.text; ms = typemax(Int))
    return nothing
end

"""
    settle_draw_errors!(app; now = time())

Take away the sticky toast of each draw error that has not come for $(DRAW_ERROR_QUIET) s.
Call it once per frame, before drawing.
"""
function settle_draw_errors!(app; now::Real = time())
    for d in app.draw_errors
        t = d.toast
        (t === nothing || now - d.last_seen < DRAW_ERROR_QUIET) && continue
        filter!(x -> x !== t, app.toasts)
        d.toast = nothing
    end
    return nothing
end

"""
    draw_error_key(e, backtrace) -> String

The exception type and the first place of the backtrace in JuliaMagUI's source, such as
`"ArgumentError at tokens.jl:13"`. Without such a place, the first place of all.
"""
function draw_error_key(@nospecialize(e), bt)::String
    place = "unknown place"
    try
        frames = stacktrace(bt)
        src = SOURCE_DIR
        k = findfirst(f -> startswith(String(f.file), src), frames)
        k === nothing && !isempty(frames) && (k = 1)
        k === nothing || (place = string(basename(String(frames[k].file)), ":", frames[k].line))
    catch
    end
    return string(typeof(e), " at ", place)
end

const SOURCE_DIR = @__DIR__

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
