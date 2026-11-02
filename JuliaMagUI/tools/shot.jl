# Screenshots for pixel reviews: run a script of UI actions against the real app.
#
# Usage, from the repo root (needs a display):
#   julia -t auto,1 --project=JuliaMagUI JuliaMagUI/tools/shot.jl [--timeout=SECONDS] script.jsonl out_dir
#
# The whole script has 120 s unless --timeout gives more, such as --timeout=600 for a long
# pixel review.
#
# The script has one JSON object per line, each with one action. Blank lines and lines
# that start with # are skipped. The actions run in order:
#
#   {"open": "path/to/project"}  open a project and wait until it shows
#   {"click": "Window/Button"}   click an item, by ImGuiTestEngine reference
#   {"key": "Ctrl+K"}            press a key chord
#   {"type": "text"}             type text into the focused input
#   {"theme": "dark"}            "light", "dark" or "system"
#   {"scale": 1.5}               draw at this content scale
#   {"size": [1480, 920]}        resize the window
#   {"wait": 10}                 draw this many frames
#   {"shot": "name"}             save the next frame as out_dir/name.png
#
# The app starts in the light theme at scale 1, 1480 by 920, with the bundled fonts.

# ImGuiTestEngine is not a dependency of the app; this folder's environment has it.
Base.find_package("ImGuiTestEngine") === nothing && push!(LOAD_PATH, @__DIR__)

# The tests include the harness themselves, and this file after it.
isdefined(@__MODULE__, :with_test_app) || include(joinpath(@__DIR__, "..", "test", "support", "app.jl"))

import GLFW
using JSON3

const SETTLE_FRAMES = 3   # frames drawn after a theme, scale or size change

"""
    read_script(path) -> Vector{Pair{Int,Pair{String,Any}}}

The actions of a script as `line number => (action => argument)`.
"""
function read_script(path::AbstractString)
    actions = Pair{Int,Pair{String,Any}}[]
    for (n, line) in enumerate(eachline(path))
        s = strip(line)
        (isempty(s) || startswith(s, '#')) && continue
        obj = try
            JSON3.read(s)
        catch e
            error("line $n: not valid JSON: $(sprint(showerror, e))")
        end
        obj isa JSON3.Object && length(obj) == 1 ||
            error("line $n: expected an object with one action, like {\"wait\": 3}")
        k, v = only(pairs(obj))
        push!(actions, n => (String(k) => v))
    end
    return actions
end

function theme_tokens(name::AbstractString)
    mode = UI.theme_from_name(name)
    return UI.tokens_for(mode, mode == UI.THEME_SYSTEM ? UI.system_dark() : false)
end

function set_size(ctx::TestContext, size)
    (size isa AbstractVector && length(size) == 2 && all(x -> x isa Integer && x > 0, size)) ||
        error("size must be [width, height] in pixels")
    want = (Int(size[1]), Int(size[2]))
    ctx.on_render(w -> GLFW.SetWindowSize(w.handle, want...))
    got = Ref((0, 0))
    ctx.wait_until(timeout = 5) do
        ctx.on_render(w -> (got[] = Tuple(GLFW.GetWindowSize(w.handle))))
        got[] == want
    end
    return nothing
end

function run_action(ctx::TestContext, action::String, arg, out_dir::AbstractString)
    if action == "open"
        app = ctx.app_state()
        folder = abspath(String(arg))
        UI.open_project!(app, folder)
        ctx.wait_until(timeout = 30) do
            app.switching === nothing && app.queue.pending == 0 && (app.session === nothing || app.snap !== nothing)
        end
        app.session === nothing && error("the project in $folder did not open: " *
                                         join((t.text for t in app.toasts), " "))
        ctx.frames(SETTLE_FRAMES)
    elseif action == "click"
        ctx.click(String(arg))
    elseif action == "key"
        ctx.key(String(arg))
    elseif action == "type"
        ctx.type(String(arg))
    elseif action == "theme"
        tokens = theme_tokens(String(arg))
        app = ctx.app_state()
        ctx.on_render(w -> UI.apply_tokens!(app, tokens))   # the app draws with its tokens
        ctx.frames(SETTLE_FRAMES)
    elseif action == "scale"
        (arg isa Real && 0.5 <= arg <= 4) || error("scale must be a number from 0.5 to 4")
        ctx.on_render(w -> UI.set_scale!(w, arg))
        ctx.frames(SETTLE_FRAMES)
    elseif action == "size"
        set_size(ctx, arg)
        ctx.frames(SETTLE_FRAMES)
    elseif action == "wait"
        (arg isa Integer && arg >= 0) || error("wait must be a number of frames")
        ctx.frames(arg)
    elseif action == "shot"
        name = String(arg)
        (isempty(name) || occursin(r"[/\\]", name)) && error("shot needs a file name without a folder")
        path = ctx.shot(joinpath(out_dir, name * ".png"))
        println("Wrote ", path)
        flush(stdout)
    else
        error("unknown action \"$action\"; " *
              "use open, click, key, type, theme, scale, size, wait or shot")
    end
    return nothing
end

"""
    run_script(script, out_dir; timeout = 120)

Run every action of `script` in one app window, within `timeout` seconds in all.
Throws on the first action that fails.
"""
function run_script(script::AbstractString, out_dir::AbstractString; timeout::Real = 120)
    actions = read_script(script)
    mkpath(out_dir)
    with_test_app(; timeout) do ctx
        for (n, (action, arg)) in actions
            try
                run_action(ctx, action, arg, out_dir)
            catch e
                error("line $n ($action): $(sprint(showerror, e))")
            end
        end
    end
    return nothing
end

function shot_main(args)
    args = collect(String, args)
    timeout = 120.0
    k = findfirst(a -> startswith(a, "--timeout="), args)
    if k !== nothing
        t = tryparse(Float64, args[k][length("--timeout=")+1:end])
        t === nothing || t <= 0 ? (args = String[]) : (timeout = t; deleteat!(args, k))
    end
    if length(args) != 2
        println(stderr, "usage: julia -t auto,1 --project=JuliaMagUI JuliaMagUI/tools/shot.jl ",
            "[--timeout=SECONDS] script.jsonl out_dir")
        return 2
    end
    has_display() || (println(stderr, "shot.jl: there is no display"); return 1)
    try
        run_script(args[1], args[2]; timeout)
    catch e
        msg = e isa CapturedException ? sprint(showerror, e.ex) : sprint(showerror, e)
        println(stderr, "shot.jl: ", msg)
        return 1
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(shot_main(ARGS))
end
