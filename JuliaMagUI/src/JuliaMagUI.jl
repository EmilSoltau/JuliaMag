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
import Logging
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
include("commands/search.jl")
include("app/modal.jl")
include("app/projects.jl")
include("panes/panes.jl")
include("shell/shell.jl")
include("shell/menu.jl")
include("shell/ribbon.jl")
include("shell/header.jl")
include("shell/tabs.jl")
include("shell/statusbar.jl")
include("shell/central.jl")
include("panes/data.jl")
include("map/constants.jl")
include("map/camera.jl")
include("dialogs/item_dialogs.jl")
include("dialogs/form.jl")
include("dialogs/widgets.jl")
include("dialogs/tool_dialog.jl")
include("panes/jobs.jl")
include("panes/tools.jl")
include("backstage/backstage.jl")
include("ribbon_tabs/settings_tab.jl")

const ONE_THREAD_TEXT = "JuliaMag runs with one worker thread. Start it with -t auto for faster jobs."

"""
    main(; project = nothing, config_dir = config_dir(), extra_ui = nothing, on_app = nothing,
         size = (1480, 920), scale = nothing, fonts = :system, engine = nothing,
         passive = false, threads = Threads.nthreads(:default))

Start the app: the window with the shell (`draw_app`). It opens `project` when one is
given, else the last project when the setting "Open Last Project" is on (`open_last!`).
The theme and the other settings come from `config_dir`, and so does the log file:
warnings and errors also go to `juliamag.log` there (`with_app_log`).
The Software Rendering setting is applied before the window opens (`rendering_env`).
With fewer than 2 `threads` in Julia's default pool, where jobs run, a toast says to start
with `-t auto` (`warn_threads!`).
It makes the `AppState` and its worker, and stops the worker when the window closes.

Closing the window closes the project first (`request_quit!`): it asks when jobs run and
shows the warnings of the close. Then `app.quit_hook` ends the loop. A project that is
still open when the loop ends another way (a test, an error) is closed here.

The other keywords are for tests, screenshots and benchmarks:
`extra_ui(w)` is drawn after the app in every frame, `on_app(app)` gets the `AppState`
before the window opens, and `size`, `scale`, `fonts`, `engine` and `passive` go to
`run_window`. `threads` is there so a test can see the warning.
"""
function main(; project::Union{Nothing,AbstractString} = nothing,
        config_dir::AbstractString = JuliaMagUI.config_dir(), extra_ui = nothing,
        on_app = nothing, size::Tuple{Integer,Integer} = (1480, 920),
        scale::Union{Nothing,Real} = nothing, fonts::Symbol = :system, engine = nothing,
        passive::Bool = false, threads::Integer = Threads.nthreads(:default))
    with_app_log(config_dir) do
        run_app(project, String(config_dir), extra_ui, on_app, size, scale, fonts, engine,
            passive, threads)
    end
    return nothing
end

"""
    main(args::AbstractVector{<:AbstractString}; kwargs...)

Start the app from the command line, as `bin/juliamag.sh` and `bin/juliamag.cmd` do with
`JuliaMagUI.main(ARGS)`. The one optional argument is a project folder to open.
A command line the app cannot use (`command_line`) never stops it: the app starts with no
project, and an error toast and the log say what was wrong.
"""
function main(args::AbstractVector{<:AbstractString}; on_app = nothing, kwargs...)
    project, problem = command_line(args)
    note = app -> begin
        if problem !== nothing
            @warn problem
            toast!(app, :error, problem)
        end
        on_app === nothing || on_app(app)
        return nothing
    end
    return main(; project, on_app = note, kwargs...)
end

"""
    command_line(args) -> (project, problem)

The project folder of the command line `args` as a full path, or `nothing` when there is
none, and what is wrong with `args` as a plain sentence, or `nothing`. Only one argument
is used: with more, there is no project and the problem says so (a folder name with
spaces that was not quoted is the usual cause).
"""
function command_line(args::AbstractVector{<:AbstractString})
    n = length(args)
    if n > 1
        return nothing, "JuliaMag takes one project folder, but it got $n arguments. " *
                        "Put quotes around a folder name with spaces."
    end
    (n == 0 || isempty(strip(args[1]))) && return nothing, nothing
    return abspath(expanduser(args[1])), nothing
end

"""
    warn_threads!(app, threads)

Warn when Julia's default thread pool, where jobs run, has fewer than 2 threads: the app
was started without `-t auto`. The warning is a toast and a line in the log.
"""
function warn_threads!(app, threads::Integer)
    threads < 2 || return nothing
    @warn ONE_THREAD_TEXT threads
    toast!(app, :warn, ONE_THREAD_TEXT)
    return nothing
end

function run_app(project, config_dir::String, extra_ui, on_app, size, scale, fonts, engine,
        passive, threads)
    config, problem = load_config(config_dir)   # a broken settings file gives the defaults
    problem === nothing || @warn problem
    for (key, value) in rendering_env(config)
        haskey(ENV, key) || (ENV[key] = value)   # before the window and its OpenGL driver
    end
    dark = config.theme == THEME_SYSTEM ? system_dark() : false
    tokens = tokens_for(config.theme, dark)
    app = AppState(config, tokens; config_dir)
    warn_threads!(app, threads)
    try
        on_app === nothing || on_app(app)
        project === nothing ? open_last!(app) : open_project!(app, project)
        run_window(AppFrame(app, extra_ui); tokens, size, scale, fonts, engine, passive,
            on_close = () -> request_quit!(app))
    catch e
        e isa InterruptException || @error "JuliaMag stopped with an error" exception = (e, catch_backtrace())
        rethrow()
    finally
        app.window = nothing
        stop_worker!(app.queue)
        close_left_project(app)
    end
    return nothing
end

# Close a project that is still open when the app ends without the close flow. The
# worker has stopped, so this runs here; nothing draws any more.
function close_left_project(app)
    s = app.session
    (s === nothing || !isopen(s)) && return nothing
    try
        Core.close_session!(s)
    catch e
        e isa InterruptException && rethrow()
        @error "The project could not be closed" exception = (e, catch_backtrace())
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
    w.frame == 0 && restart_toast_clocks!(app.toasts)   # made before the window showed
    w.handle.handle == C_NULL || note_focus!(app, GLFW.GetWindowAttrib(w.handle, GLFW.FOCUSED) != 0)
    drain!(app)
    refresh!(app)
    settle_draw_errors!(app)
    # A bug that `user_message` meets in this frame is noted at the next `drain!`.
    with_bug_reports(app.queue.results) do
        guarded_frame(app) do
            t = time_ns()
            draw_app(app)
            app.draw_ns = Int(time_ns() - t)
            a.extra_ui === nothing || a.extra_ui(w)
        end
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
    state = store_imgui_state()
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
    note_draw_error!(app, e, backtrace; now = time(), log = "An error cut a frame short; the app goes on",
                     reported = false)

Note an unexpected error: one that cut a frame short, or a bug in a request handler, a
worker action or its `done` (`report_error!`). The tests fail on any noted error.
Errors are told apart by their type and the place in JuliaMagUI they came from
(`draw_error_key`), not by their message, so a message that changes in every frame is
still one error. A backtrace seen before reuses its key without reading the stack again.

The first time, the error is logged (with `log` and its backtrace) and shown as a sticky
error toast. While it keeps coming it is only counted and its toast stays. When it has not
come for $(DRAW_ERROR_QUIET) s, `settle_draw_errors!` takes the toast away; if it comes back after
that, it is logged and shown again. With `reported`, the caller has logged and shown the
error already, so it is only counted.
"""
function note_draw_error!(app, @nospecialize(e), bt; now::Real = time(),
        log::AbstractString = "An error cut a frame short; the app goes on", reported::Bool = false)
    trace = hash(bt, hash(typeof(e)))
    k = findfirst(d -> d.trace == trace, app.draw_errors)
    key = k === nothing ? draw_error_key(e, bt) : ""
    k === nothing && (k = findfirst(d -> d.key == key, app.draw_errors))
    if k === nothing
        if length(app.draw_errors) >= MAX_DRAW_ERRORS
            @debug "Another unexpected error" key
            return nothing
        end
        push!(app.draw_errors, DrawError(key, "", 0, 0, now, nothing, trace))
        k = length(app.draw_errors)
    end
    d = app.draw_errors[k]
    d.trace = trace
    d.count += 1
    d.last_seen = Float64(now)
    isempty(d.text) && (d.text = draw_error_text(e))
    (reported || d.toast !== nothing) && return nothing   # shown already, or still being reported
    d.text = draw_error_text(e)
    d.reports += 1
    @error log exception = (e, bt)
    d.toast = toast!(app, :error, d.text; ms = typemax(Int))
    return nothing
end

"""
    report_error!(app, e, backtrace)

Show an error from a request handler, a worker action or its `done` callback. A user
error (`is_user_error`) becomes an error toast with its message. Any other error is a
bug: it is noted with `note_draw_error!` (logged, toasted, and failed by the tests), as
an error in drawing is. Call it on the render thread.
"""
function report_error!(app, @nospecialize(e), bt)
    if is_user_error(e, bt)
        toast!(app, :error, safe_plain_message(e))
    else
        note_draw_error!(app, e, bt; log = "Unexpected error")
    end
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
        frames = stack_frames(bt)
        src = SOURCE_DIR
        k = findfirst(f -> startswith(String(f.file), src), frames)
        k === nothing && !isempty(frames) && (k = 1)
        k === nothing || (place = string(basename(String(frames[k].file)), ":", frames[k].line))
    catch
    end
    return string(typeof(e), " at ", place)
end

# The frames of a backtrace: a raw one (`catch_backtrace`), or one that
# `CapturedException` has processed already (pairs of a frame and a count).
stack_frames(::Nothing) = Base.StackTraces.StackFrame[]
function stack_frames(bt)::Vector{Base.StackTraces.StackFrame}
    isempty(bt) && return Base.StackTraces.StackFrame[]
    first(bt) isa Tuple && return Base.StackTraces.StackFrame[x[1] for x in bt]
    return stacktrace(convert(Vector{Union{Ptr{Cvoid},Base.InterpreterIP}}, bt))
end

const SOURCE_DIR = @__DIR__

# The toast text of a draw error, as `user_message` gives it but without logging.
function draw_error_text(@nospecialize(e))::String
    try
        e isa Union{CORE_ERRORS,ArgumentError} && return plain_message(e)
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
