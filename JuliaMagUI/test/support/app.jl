# The window test harness: run the real app in a window and drive it with ImGuiTestEngine.
# Tests include this file; so does tools/shot.jl.
#
# ImGuiTestEngine runs the test function as a coroutine on another thread, one frame at
# a time: the render loop waits while the test function runs, and the test function
# waits while the loop draws a frame. So the test function may read and change app state,
# but GLFW and OpenGL calls must go through `on_render`, which runs them on the render thread.

using Test
import ImGuiTestEngine as te
import CImGui as ig
import JuliaMagUI as UI

# The loop stops the engine before it destroys the ImGui context.
UI.stop_test_engine(engine::te.Engine) = te.Stop(engine)

# A pixel of a loaded PNG, or a token colour, as 0-255 RGB.
rgb255(p) = (round(Int, 255 * Float32(p.r)), round(Int, 255 * Float32(p.g)),
    round(Int, 255 * Float32(p.b)))
rgb255(c::NTuple{4,Float32}) = (round(Int, 255 * c[1]), round(Int, 255 * c[2]),
    round(Int, 255 * c[3]))
"Are two 0-255 RGB colours within `tol` in every channel?"
near(a, b; tol = 3) = all(abs(a[i] - b[i]) <= tol for i in 1:3)

# Can a window open here? See `JuliaMagUI.has_display`.
has_display() = UI.has_display()

const NO_DISPLAY_NOTED = Ref(false)

"""
    window_testset(f, name)

Run `f()` inside `@testset name` when there is a display. Without one, the test set holds
one skipped test, and the reason is printed once.
"""
function window_testset(f, name::AbstractString)
    if has_display()
        @testset "$name" begin
            f()
        end
    else
        if !NO_DISPLAY_NOTED[]
            NO_DISPLAY_NOTED[] = true
            @info "Window tests skipped: no display (DISPLAY and WAYLAND_DISPLAY are not set)."
        end
        @testset "$name" begin
            @test_skip "no display"
        end
    end
    return nothing
end

"""
    TestContext

What a test function of `with_test_app` gets. Each action is a field you call:

- `ctx.click(ref)`: click the item `ref` (an ImGuiTestEngine reference such as `"Window/Button"`).
- `ctx.type(ref, text)`: put `text` into the input `ref`; `ctx.type(text)` types into the
  focused input.
- `ctx.key(chord)`: press a key chord such as `"Ctrl+K"`, `"Alt+Left"` or `"Escape"`.
- `ctx.frames(n)`: let the app draw `n` frames.
- `ctx.shot(path)`: save the next frame as a PNG.
- `ctx.wait_until(pred; timeout = 10)`: draw frames until `pred()`; an error after `timeout` s.
- `ctx.on_render(f)`: run `f(window)` on the render thread in the next frame, and wait for it.
- `ctx.window`: the app's `Window`.
- `ctx.app_state()`: the app's `AppState`. Read and change it only in the test function or
  in `on_render`, which both run while the render loop waits.

Each action is also a function that takes the context first, such as `click(ctx, ref)`.
"""
struct TestContext
    window::UI.Window
    app::UI.AppState
    render_queue::Vector{Any}
    deadline::Float64   # `time()` when the whole test runs out of time
end

"""
    TestTimeout(seconds)

Thrown when a `with_test_app` test runs longer than its `timeout`.
"""
struct TestTimeout <: Exception
    seconds::Float64
end

Base.showerror(io::IO, e::TestTimeout) =
    print(io, "TestTimeout: the app test did not finish within $(e.seconds) s")

# Every action checks the overall time limit first.
function check_time(ctx::TestContext)
    deadline = getfield(ctx, :deadline)
    time() > deadline && throw(TestTimeout(TEST_TIMEOUT[]))
    return nothing
end

const TEST_TIMEOUT = Ref(0.0)   # the `timeout` of the running `with_test_app`

# One frame, after checking the time limit.
next_frame(ctx::TestContext, n::Integer = 1) = (check_time(ctx); te.Yield(n); nothing)

const TEST_ACTIONS = (:click, :type, :key, :frames, :shot, :wait_until, :on_render, :app_state)

function Base.getproperty(ctx::TestContext, name::Symbol)
    name in TEST_ACTIONS || return getfield(ctx, name)
    f = getfield(@__MODULE__, name)
    return (args...; kwargs...) -> f(ctx, args...; kwargs...)
end

Base.propertynames(::TestContext) = (fieldnames(TestContext)..., TEST_ACTIONS...)

function click(ctx::TestContext, ref::AbstractString)
    check_time(ctx)
    te.ItemExists(String(ref)) || error("there is no item \"$ref\" to click")
    te.ItemClick(String(ref))
    return nothing
end

function type(ctx::TestContext, ref::AbstractString, text::AbstractString)
    check_time(ctx)
    te.ItemExists(String(ref)) || error("there is no input \"$ref\" to type into")
    te.ItemInputValue(String(ref), String(text))
    return nothing
end

type(ctx::TestContext, text::AbstractString) = (check_time(ctx); te.KeyChars(String(text)); nothing)

key(ctx::TestContext, chord::AbstractString) =
    (check_time(ctx); te.KeyPress(key_chord(chord)); nothing)

frames(ctx::TestContext, n::Integer = 1) = next_frame(ctx, n)

app_state(ctx::TestContext) = getfield(ctx, :app)

function shot(ctx::TestContext, path::AbstractString)
    rm(path; force = true)
    UI.capture_png(ctx.window, path)
    next_frame(ctx)   # the loop writes the file at the end of the frame
    isfile(path) || error("the screenshot $path was not written")
    return path
end

function wait_until(ctx::TestContext, pred; timeout::Real = 10)
    deadline = time() + timeout
    while !pred()
        time() > deadline && error("wait_until: the condition did not hold within $timeout s")
        next_frame(ctx)
    end
    return nothing
end

function on_render(ctx::TestContext, f)
    done = Ref(false)
    push!(ctx.render_queue, w -> (f(w); done[] = true))
    wait_until(ctx, () -> done[]; timeout = 10)
    return nothing
end

const KEY_MODS = Dict(
    "ctrl" => ig.ImGuiMod_Ctrl, "shift" => ig.ImGuiMod_Shift,
    "alt" => ig.ImGuiMod_Alt, "super" => ig.ImGuiMod_Super,
)

# Short key names, as the prototype writes them, and their ImGuiKey names.
const KEY_ALIASES = Dict("Left" => "LeftArrow", "Right" => "RightArrow", "Up" => "UpArrow",
    "Down" => "DownArrow", "Esc" => "Escape", "Del" => "Delete")

"""
    key_chord(s) -> Int

An ImGui key chord from text such as `"Ctrl+Shift+Z"`, `"Alt+Left"` or `"F1"`.
A key name is a letter, a digit, an `ImGuiKey_` name without the prefix, or one of
`KEY_ALIASES` such as `"Left"`.
"""
function key_chord(s::AbstractString)::Int
    parts = split(s, '+')
    chord = 0
    for m in parts[1:end-1]
        mod = get(KEY_MODS, lowercase(m), nothing)
        mod === nothing && throw(ArgumentError("unknown key modifier \"$m\" in \"$s\""))
        chord |= Int(mod)
    end
    name = parts[end]
    length(name) == 1 && (name = uppercase(name))
    name = get(KEY_ALIASES, name, name)
    sym = Symbol("ImGuiKey_", name)
    isdefined(ig.lib, sym) || throw(ArgumentError("unknown key \"$name\" in \"$s\""))
    return chord | Int(getfield(ig.lib, sym))
end

"""
    with_test_app(f; project = nothing, theme = THEME_LIGHT, size = (1480, 920), scale = 1f0,
                  config_dir = mktempdir(), extra_ui = nothing, timeout = 120,
                  draw_errors_ok = false, threads = 2, args = nothing)

Start the real app (`JuliaMagUI.main`) with the bundled fonts and an ImGuiTestEngine
context, run `f(ctx::TestContext)` as one registered test, then close the app.
`theme` is saved in the settings of `config_dir` before the app starts.
`extra_ui(w)` is drawn after the app in every frame.
The app's `pick_file` returns `""` (a cancelled file dialog) unless the test sets another.
An error in `f` is thrown again once the window is closed. Returns what `f` returns.

An error while drawing a frame does not end the app (the frame guard turns it into a
toast). So a test cannot miss one, the run fails when the app recorded any draw error
(`app.draw_errors`), unless `draw_errors_ok` says the test expects them.

With `args`, the app starts as from the command line, `main(args)`, and `project` is not used.

`threads` goes to `main`: the size of the default thread pool the app sees. It is 2, so
the one-thread warning shows only in the test that asks for it.

The whole test, start and close included, has `timeout` seconds.
After that, the next action throws `TestTimeout`, and the test engine's watchdog stops an
action that hangs; the app then closes and the error reaches the caller.
A test that hangs outside the harness (it waits on something that never comes, and calls
no action) cannot be stopped from inside: `HANG_GRACE` (30) s after the timeout, a watchdog on
another thread says so and ends the test process, so a test run never hangs for good.
"""
function with_test_app(f; project = nothing, theme::UI.ThemeMode = UI.THEME_LIGHT,
        size::Tuple{Integer,Integer} = (1480, 920), scale::Real = 1f0,
        config_dir::AbstractString = mktempdir(), extra_ui = nothing, timeout::Real = 120,
        draw_errors_ok::Bool = false, threads::Integer = 2,
        args::Union{Nothing,AbstractVector{<:AbstractString}} = nothing)
    deadline = time() + timeout
    TEST_TIMEOUT[] = timeout
    config, _ = UI.load_config(config_dir)
    config.theme = theme
    UI.save_config(config, config_dir)

    window = Ref{Union{Nothing,UI.Window}}(nothing)
    app = Ref{Union{Nothing,UI.AppState}}(nothing)
    queue = Any[]
    function hook(w)
        window[] = w
        while !isempty(queue)
            popfirst!(queue)(w)
        end
        extra_ui === nothing || extra_ui(w)
        return nothing
    end

    result = Ref{Any}(nothing)
    failure = Ref{Any}(nothing)
    finished = Threads.Atomic{Bool}(false)
    watch_hang(finished, timeout)
    engine = te.CreateContext(; exit_on_completion = true, show_test_window = false)
    try
        io = te.GetIO(engine)
        io.ConfigVerboseLevel = te.VerboseLevel_Silent
        io.ConfigVerboseLevelOnError = te.VerboseLevel_Silent
        io.ConfigMouseDrawCursor = false   # no drawn mouse cursor in screenshots
        io.ConfigWatchdogWarning = timeout
        io.ConfigWatchdogKillTest = timeout   # stops an engine action that hangs
        test = te.@register_test(engine, "app", "with_test_app")
        test.TestFunc = () -> begin
            try
                # The test starts before the first frame reaches the hook.
                for _ in 1:100
                    window[] === nothing || break
                    te.Yield()
                end
                window[] === nothing && error("the app drew no frame")
                result[] = f(TestContext(window[], something(app[]), queue, deadline))
            catch e
                failure[] = CapturedException(e, catch_backtrace())
            end
            return nothing
        end
        # Tests never open a native file dialog: a test that needs a file sets its own picker.
        on_app = a -> (a.pick_file = (; kw...) -> ""; app[] = a)
        options = (; config_dir, extra_ui = hook, on_app, size, scale, fonts = :bundled, engine,
            passive = true, threads)
        args === nothing ? UI.main(; project, options...) : UI.main(args; options...)
        summary = te.GetResultSummary(engine)
        failure[] === nothing && time() > deadline && throw(TestTimeout(timeout))
        if failure[] === nothing && (summary.CountTested != 1 || summary.CountSuccess != 1)
            error("the test engine did not finish the test with success " *
                  "(tested $(summary.CountTested), passed $(summary.CountSuccess))")
        end
    finally
        finished[] = true
        te.DestroyContext(engine)
    end
    failure[] === nothing || throw(failure[])
    a = app[]
    if !draw_errors_ok && a !== nothing && !isempty(a.draw_errors)
        error("the app had errors while drawing: " * join((e.text for e in a.draw_errors), "; "))
    end
    return result[]
end

const HANG_GRACE = 30   # s after the timeout before the watchdog ends a hung test process

# End the process when a `with_test_app` test is still running `HANG_GRACE` s after its
# timeout. It runs on the default pool: the render thread waits for the test function then.
function watch_hang(finished::Threads.Atomic{Bool}, timeout::Real; grace::Real = HANG_GRACE,
        stop = () -> ccall(:_exit, Cvoid, (Cint,), 1))
    Threads.@spawn :default begin
        deadline = time() + timeout + grace
        while !finished[] && time() < deadline
            sleep(0.5)
        end
        if !finished[]
            println(stderr, "with_test_app: the app test is still running $(round(Int, timeout + grace)) s ",
                "after it started, stuck outside the test harness. The test process stops.")
            flush(stderr)
            stop()
        end
    end
    return nothing
end

"""
    ref_part(text) -> String

`text` as one part of a test engine reference, for an ImGui id made from any text, such
as a folder path or a label. The engine reads `\\` as an escape and `/` as the line
between ids, so both are escaped: a Windows path such as `C:\\Users\\me` keeps its
backslashes, and `a/b` stays one id.
"""
ref_part(text::AbstractString)::String = replace(String(text), "\\" => "\\\\", "/" => "\\/")

"""
    tree_ref(key, part = "row") -> String

The test engine reference of a part of a Data tree row: `"row"`, `"check"` or `"chevron"`.
The key is one id (`ref_part`).
"""
tree_ref(key::AbstractString, part::AbstractString = "row") =
    "JuliaMag/left/tree/" * ref_part(key) * "/" * part

right_click(ref) = te.ItemClick(ref, 1)
