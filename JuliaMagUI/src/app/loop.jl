# The app window and its render loop.
# The loop is a copy of the CImGui.jl GLFW and OpenGL 3 extension loop
# (ext/GlfwOpenGLBackend.jl), changed so that it idles, scales with the screen and takes screenshots.
# It runs on thread 1. Start Julia with `-t auto,1` so jobs run on other threads.

const IDLE_TIMEOUT = 0.1        # s; an idle loop still lets libuv run this often
const BUSY_FRAME_TIME = 1 / 120 # s; the shortest frame while animating, when vsync does not hold
const INPUT_FRAMES = 3         # frames drawn after input, so ImGui can settle its state
const APP_NAME = "JuliaMag"

"""
    Window

The app window.

- `handle`: the GLFW window.
- `ctx`: the ImGui context.
- `tokens`: the colours in use.
- `scale`: the content scale (DPI). Layout sizes go through `px`.
- `frame`: the number of frames drawn so far.
- `wake`: set by `wake!` from any thread; the loop then draws a frame at once.
- `animating_until`: the loop polls instead of waiting until this `time()`.
- `input_frames`: frames still to draw without waiting, after input.
- `renderer`: the OpenGL `GL_RENDERER` text, such as `"llvmpipe (LLVM 17.0.6, 256 bits)"`.

The other fields are for the loop itself.
"""
mutable struct Window
    handle::GLFW.Window
    ctx::Ptr{ig.lib.ImGuiContext}
    tokens::Tokens
    scale::Float32
    fixed_scale::Bool
    monitor_scale::Float32
    min_size::Tuple{Int,Int}
    frame::Int
    wake::Threads.Atomic{Bool}
    animating_until::Float64
    input_frames::Int
    quit::Bool
    capture_path::Union{Nothing,String}
    renderer::String
end

"""
    px(w, x)

`x` logical pixels as device pixels, rounded; a half rounds up, as a browser snaps
(3 px at scale 1.5 is 5). Every layout size goes through it.
"""
px(scale::Real, x::Real) = round(Float32(x) * Float32(scale), RoundNearestTiesUp)
px(w::Window, x::Real) = px(w.scale, x)

"""
    request_frames!(w, seconds = 0.25)

Keep drawing for `seconds` more. Hover effects, tooltips, toasts and progress bars call it.
"""
function request_frames!(w::Window, seconds::Real = 0.25)
    w.animating_until = max(w.animating_until, time() + seconds)
    return nothing
end

"""
    wake!(w)

Make the loop draw a frame soon. Safe to call from any thread; worker results call it.
"""
function wake!(w::Window)
    w.wake[] = true
    GLFW.PostEmptyEvent()
    return nothing
end

"""
    set_theme!(w, tokens)

Draw with `tokens` from now on. The icons follow on the next frame.
"""
function set_theme!(w::Window, tokens::Tokens)
    w.tokens = tokens
    apply_style!(tokens, w.scale)
    return nothing
end

"""
    set_scale!(w, scale)

Draw at content `scale` from now on, whatever the monitor's scale is.
"""
function set_scale!(w::Window, scale::Real)
    w.scale = Float32(scale)
    w.fixed_scale = true
    apply_style!(w.tokens, w.scale)
    return nothing
end

"""
    quit!(w)

End the loop after this frame. It does not ask `on_close`.
"""
quit!(w::Window) = (w.quit = true; nothing)

"""
    capture_png(w, path)

Save this frame as a PNG at `path`, at the framebuffer size.
The loop reads the back buffer after the frame is drawn and before it is shown,
so the file exists once the current frame ends.
"""
function capture_png(w::Window, path::AbstractString)
    w.capture_path = String(path)
    return path
end

# Read the back buffer and write it as an RGB PNG, top row first.
function write_back_buffer(path::AbstractString, width::Integer, height::Integer)
    buf = Vector{UInt8}(undef, 4 * width * height)
    GL.glReadBuffer(GL.GL_BACK)
    GL.glPixelStorei(GL.GL_PACK_ALIGNMENT, 1)
    GL.glReadPixels(0, 0, width, height, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, buf)
    img = Array{UInt8}(undef, height, width, 3)
    for y in 1:height, x in 1:width
        i = 4 * ((height - y) * width + (x - 1))   # OpenGL rows start at the bottom
        for c in 1:3
            img[y, x, c] = buf[i+c]
        end
    end
    mkpath(dirname(abspath(path)))
    PNGFiles.save(path, img)
    return nothing
end

content_scale(handle::GLFW.Window) = Float32(GLFW.GetWindowContentScale(handle)[1])

"""
    min_size_limit(min_size, monitor_scale, window_width, framebuffer_width) -> (w, h)

The minimum window size in GLFW screen coordinates.
`min_size` is in logical pixels and grows with the monitor's real content scale.
On Windows and X11 screen coordinates are device pixels; on macOS and Wayland they are
already logical, which the window to framebuffer ratio tells apart.
A scale forced on `run_window` changes only the drawing, never this limit.
"""
function min_size_limit(min_size::NTuple{2,Int}, monitor_scale::Real, window_width::Integer,
        framebuffer_width::Integer)::NTuple{2,Int}
    f = (window_width > 0 && framebuffer_width > 0) ?
        Float32(monitor_scale) * window_width / framebuffer_width : 1f0
    return (round(Int, min_size[1] * f), round(Int, min_size[2] * f))
end

# The limit for this window, from the monitor it is on now.
function min_size_limit(w::Window)::NTuple{2,Int}
    return min_size_limit(w.min_size, content_scale(w.handle),
        GLFW.GetWindowSize(w.handle)[1], GLFW.GetFramebufferSize(w.handle)[1])
end

function set_min_size!(w::Window)
    limit = min_size_limit(w)
    GLFW.SetWindowSizeLimits(w.handle, limit..., GLFW.DONT_CARE, GLFW.DONT_CARE)
    return nothing
end

# Follow a change of the monitor scale (no GLFW callback; checked each frame).
# A forced scale keeps the drawing scale, but the size limit still follows the monitor.
function update_scale!(w::Window)
    s = content_scale(w.handle)
    s == w.monitor_scale && return nothing
    w.monitor_scale = s
    if !w.fixed_scale
        w.scale = s
        apply_style!(w.tokens, s)
    end
    set_min_size!(w)
    return nothing
end

# Did the GLFW callbacks of the ImGui backend queue any input since the last frame?
input_queued(ctx::Ptr{ig.lib.ImGuiContext}) = unsafe_load(ctx.InputEventsQueue).Size > 0

# GLFW calls that block, made GC-safe so the GC of worker threads does not wait for them.
# The CImGui loop wraps them in jl_gc_safe_enter/leave; Julia 1.12 `gc_safe = true` does the same.
# They run no Julia code, as long as no Julia GLFW callbacks are set (see `wait_or_poll`).
glfw_wait_gc_safe(timeout::Float64) =
    @ccall gc_safe = true GLFW.libglfw.glfwWaitEventsTimeout(timeout::Cdouble)::Cvoid
glfw_poll_gc_safe() = @ccall gc_safe = true GLFW.libglfw.glfwPollEvents()::Cvoid
glfw_swap_gc_safe(handle::GLFW.Window) =
    @ccall gc_safe = true GLFW.libglfw.glfwSwapBuffers(handle::GLFW.Window)::Cvoid

# Wait for events (idle) or only collect them (busy).
function wait_or_poll(handle::GLFW.Window, idle::Bool)
    if any(!isnothing, GLFW.callbacks(handle))
        # Julia callbacks run inside the wait, so it must not be GC-safe.
        idle ? GLFW.WaitEvents(IDLE_TIMEOUT) : GLFW.PollEvents()
    else
        idle ? glfw_wait_gc_safe(IDLE_TIMEOUT) : glfw_poll_gc_safe()
    end
    return nothing
end

# Call a test engine hook of CImGui. ImGuiTestEngine.jl adds the methods when it loads,
# so the call is made at run time.
engine_call(f, args...) = Base.invokelatest(f, args...)

"""
    stop_test_engine(engine)

Stop a test engine before its ImGui context is destroyed.
CImGui has no hook for this, so the test harness (test/support/app.jl) adds the method.
"""
function stop_test_engine end

# One frame. Returns false when the loop should end.
function draw_frame!(w::Window, @nospecialize(ui), @nospecialize(on_close),
        @nospecialize(engine))::Bool
    if GLFW.WindowShouldClose(w.handle)
        on_close() && return false
        GLFW.SetWindowShouldClose(w.handle, false)
    end
    update_scale!(w)
    update_icons!(w)
    log_x_errors()
    log_glfw_errors()

    lib.ImGui_ImplOpenGL3_NewFrame()
    lib.ImGui_ImplGlfw_NewFrame()
    ig.NewFrame()
    ui(w)
    if engine !== nothing
        engine.show_test_window && engine_call(ig._show_test_window, engine)
        engine.exit_on_completion && !engine_call(ig._test_engine_is_running, engine) &&
            quit!(w)
    end
    ig.Render()

    fb_w, fb_h = GLFW.GetFramebufferSize(w.handle)
    GL.glViewport(0, 0, fb_w, fb_h)
    GL.glClearColor(w.tokens.canvas...)
    GL.glClear(GL.GL_COLOR_BUFFER_BIT)
    lib.ImGui_ImplOpenGL3_RenderDrawData(Ptr{Cint}(ig.GetDrawData()))
    path = w.capture_path
    if path !== nothing
        w.capture_path = nothing
        write_back_buffer(path, fb_w, fb_h)
    end
    glfw_swap_gc_safe(w.handle)
    engine !== nothing && engine_call(ig._post_swap, engine)
    w.frame += 1
    return !w.quit
end

# The OpenGL renderer of the current context, or "" when OpenGL does not say.
function gl_renderer()::String
    p = GL.glGetString(GL.GL_RENDERER)
    return p == C_NULL ? "" : unsafe_string(p)
end

"""
    software_renderer(name) -> Bool

Is the OpenGL renderer `name` (`GL_RENDERER`) a software one, such as Mesa's `llvmpipe`?
"""
software_renderer(name::AbstractString)::Bool =
    any(k -> occursin(k, name), ("llvmpipe", "softpipe", "Software"))

const MOUSE_PASSTHROUGH = 0x0002000D   # GLFW 3.4; GLFW.jl has no name for it

function create_glfw_window(title::AbstractString, size::Tuple{Int,Int}, passive::Bool)::GLFW.Window
    GLFW.WindowHint(GLFW.VISIBLE, true)
    GLFW.WindowHint(GLFW.DECORATED, true)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 3)
    GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE)
    GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, true)
    GLFW.WindowHint(GLFW.SCALE_TO_MONITOR, true)
    GLFW.WindowHint(GLFW.FOCUS_ON_SHOW, !passive)
    GLFW.WindowHint(GLFW.FOCUSED, !passive)
    GLFW.WindowHint(MOUSE_PASSTHROUGH, passive)
    # Not `GLFW.CreateWindow`: on a failure it passes the NULL window on to GLFW.
    before = GLFW_ERRORS[]
    handle = ccall((:glfwCreateWindow, GLFW.libglfw), GLFW.Window,
        (Cint, Cint, Cstring, GLFW.Monitor, GLFW.Window),
        size[1], size[2], title, GLFW.Monitor(C_NULL), GLFW.Window(C_NULL))
    handle.handle == C_NULL &&
        throw(glfw_failure("could not open a window with OpenGL 3.3", before))
    # What `GLFW.CreateWindow` does after a window opens, so GLFW.jl's window
    # callbacks and `GLFW.DestroyWindow` work as usual.
    callbacks = Ref{Vector{GLFW.Callback}}(fill(nothing, GLFW._window_callback_num[]))
    GLFW._window_callbacks[handle] = callbacks
    ccall((:glfwSetWindowUserPointer, GLFW.libglfw), Cvoid,
        (GLFW.Window, Ref{Vector{GLFW.Callback}}), handle, callbacks)
    return handle
end

"""
    run_window(ui; title = "JuliaMag", size = (1480, 920), min_size = (900, 560),
               scale = nothing, fonts = :system, on_close = () -> true,
               engine = nothing, tokens = LIGHT, passive = false)

Open the window and run the render loop on thread 1 until the window closes.
`ui(w::Window)` draws one frame.

- Idle: with nothing to animate, the loop waits for events for at most 0.1 s,
  so the CPU rests and Julia's libuv loop still runs.
  It draws without waiting while `time() < w.animating_until`, after input, and after `wake!`.
- `scale`: the content scale; `nothing` follows the monitor.
  A forced scale changes only the drawing; the window size and its minimum follow the monitor.
- `fonts`: `:system` or `:bundled`, see `font_paths`.
- `on_close()`: asked when the user closes the window; `false` keeps it open.
- `engine`: an ImGuiTestEngine engine, or `nothing`.
- `passive`: the window takes no mouse input and no focus. Tests use it,
  so a user working on the same desktop does not change what they measure.
"""
function run_window(ui; title::AbstractString = APP_NAME,
        size::Tuple{Integer,Integer} = (1480, 920),
        min_size::Tuple{Integer,Integer} = (900, 560),
        scale::Union{Nothing,Real} = nothing, fonts::Symbol = :system,
        on_close = () -> true, engine = nothing, tokens::Tokens = LIGHT,
        passive::Bool = false)
    Threads.threadid() == 1 ||
        throw(ArgumentError("run_window must run on thread 1, not thread $(Threads.threadid())"))
    font_paths(fonts)   # fail on a bad source before a window opens
    open_and_run(ui, String(title), (Int(size[1]), Int(size[2])),
        (Int(min_size[1]), Int(min_size[2])), scale === nothing ? 0f0 : Float32(scale),
        fonts, on_close, engine, tokens, passive)
    return nothing
end

# The body of `run_window`, with plain argument types so that one compiled copy serves
# every caller (see the precompile workload). A `scale` of 0 follows the monitor.
function open_and_run(@nospecialize(ui), title::String, size::NTuple{2,Int},
        min_size::NTuple{2,Int}, scale::Float32, fonts::Symbol, @nospecialize(on_close),
        @nospecialize(engine), tokens::Tokens, passive::Bool)
    ig.set_backend(:GlfwOpenGL3)
    install_glfw_error_callback()
    GLFW.is_initialized() || throw(ErrorException("GLFW did not start, so no window can open"))
    handle = create_glfw_window(title, size, passive)
    install_x_error_handler()
    ctx = Ptr{ig.lib.ImGuiContext}(C_NULL)
    glfw_ready = gl_ready = engine_started = false
    try
        before = GLFW_ERRORS[]
        GLFW.MakeContextCurrent(handle)
        current = ccall((:glfwGetCurrentContext, GLFW.libglfw), Ptr{Cvoid}, ())
        current == handle.handle ||
            throw(glfw_failure("could not use the window's OpenGL context", before))
        GLFW.SwapInterval(1)
        ctx = ig.CreateContext()
        io = ig.GetIO()
        io.IniFilename = C_NULL   # the app keeps its own settings
        if engine !== nothing
            engine_call(ig._start_test_engine, engine, ctx)
            engine_started = true
        end
        glfw_ready = lib.ImGui_ImplGlfw_InitForOpenGL(Ptr{lib.GLFWwindow}(handle.handle), true)
        gl_ready = lib.ImGui_ImplOpenGL3_Init("#version 330")
        (glfw_ready && gl_ready) || error("could not start the ImGui GLFW and OpenGL 3 backends")

        fixed = scale > 0
        monitor = content_scale(handle)
        s = fixed ? scale : monitor
        w = Window(handle, ctx, tokens, s, fixed, monitor, min_size, 0,
            Threads.Atomic{Bool}(false), 0.0, 0, false, nothing, gl_renderer())
        apply_style!(tokens, s)
        load_fonts!(w, fonts)
        set_min_size!(w)
        run_loop!(w, ui, on_close, engine)
    finally
        for f in ig._exit_handlers
            try
                f()
            catch e
                @error "Error in a CImGui exit handler" exception = (e, catch_backtrace())
            end
        end
        if engine_started
            try
                engine_call(stop_test_engine, engine)
            catch e
                @error "Could not stop the test engine" exception = (e, catch_backtrace())
            end
        end
        ctx != C_NULL && forget_icons!(ctx)   # while the OpenGL context is still current
        gl_ready && lib.ImGui_ImplOpenGL3_Shutdown()
        glfw_ready && lib.ImGui_ImplGlfw_Shutdown()
        if ctx != C_NULL
            forget_fonts!(ctx)
            ig.DestroyContext(ctx)
        end
        GLFW.DestroyWindow(handle)
    end
    return nothing
end

function run_loop!(w::Window, @nospecialize(ui), @nospecialize(on_close),
        @nospecialize(engine))
    while true
        frame_start = time()
        # A test engine drives the app frame by frame, so the loop never waits for it.
        idle = !w.wake[] && frame_start >= w.animating_until && w.input_frames == 0 &&
               engine === nothing
        wait_or_poll(w.handle, idle)
        w.wake[] = false
        w.input_frames = input_queued(w.ctx) ? INPUT_FRAMES : max(w.input_frames - 1, 0)
        draw_frame!(w, ui, on_close, engine) || break
        # Without vsync a busy loop would spin; keep at most 120 frames per second.
        rest = BUSY_FRAME_TIME - (time() - frame_start)
        rest > 0.001 && sleep(rest)
        # Run due libuv timers and IO now. With yield alone they ran one idle wait late.
        Base.process_events()
        yield()
    end
    return nothing
end
