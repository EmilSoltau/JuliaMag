using Test
using Base.CoreLogging: with_logger, NullLogger, Debug   # Logging is not a test dependency
import JuliaMagUI as UI
import CImGui as ig
import PNGFiles
import GLFW
using JuliaMagUI: Window, run_window, quit!, px, apply_style!, LIGHT, DARK, capture_png,
    wake!, request_frames!, with_font, FONT_REGULAR, FONT_SEMIBOLD, FONT_MONO,
    find_system_fonts, font_paths, BUNDLED_FONTS, min_size_limit, content_scale

# Window tests need a display; `window_testset` (test/support/app.jl) skips them without one.
const SHOTS = joinpath(@__DIR__, "shots")

style_ptr() = Ptr{ig.lib.ImGuiStyle}(ig.GetStyle())
vec2(v) = (v.x, v.y)
vec4(v) = (v.x, v.y, v.z, v.w)

# A pixel of a loaded PNG as Float32 RGB.
rgb(p) = (Float32(p.r), Float32(p.g), Float32(p.b))

@testset "loop" begin
    @testset "px" begin
        @test px(1f0, 10) == 10f0
        @test px(2f0, 6.3) == 13f0
        @test px(1.5f0, 26) == 39f0
        @test px(1.25f0, 34) == 43f0
        @test px(1.5f0, 3) == 5f0 && px(1.5f0, 5) == 8f0   # a half rounds up, as in a browser
    end

    @testset "min_size_limit" begin
        # Windows and X11: screen coordinates are device pixels.
        @test min_size_limit((900, 560), 1f0, 1480, 1480) == (900, 560)
        @test min_size_limit((900, 560), 1.5f0, 2220, 2220) == (1350, 840)
        # macOS and Wayland: screen coordinates are logical.
        @test min_size_limit((900, 560), 2f0, 1480, 2960) == (900, 560)
        # A minimised window reports 0.
        @test min_size_limit((900, 560), 2f0, 0, 0) == (900, 560)
    end

    @testset "apply_style! without a window" begin
        ctx = ig.CreateContext()
        try
            apply_style!(LIGHT, 2f0)
            s = style_ptr()
            @test vec2(unsafe_load(s.FramePadding)) == (16f0, 8f0)
            @test vec2(unsafe_load(s.ItemSpacing)) == (12f0, 10f0)
            @test unsafe_load(s.FrameRounding) == 10f0
            @test unsafe_load(s.WindowRounding) == 20f0
            @test unsafe_load(s.FontScaleDpi) == 2f0
            @test unsafe_load(s.FontSizeBase) == 12.5f0
            @test vec4(ig.c_get(s.Colors, ig.ImGuiCol_WindowBg)) == LIGHT.pane
            @test vec4(ig.c_get(s.Colors, ig.ImGuiCol_FrameBg)) == LIGHT.input
            @test vec4(ig.c_get(s.Colors, ig.ImGuiCol_Button)) == LIGHT.ribbon
            @test vec4(ig.c_get(s.Colors, ig.ImGuiCol_CheckMark)) == LIGHT.accent
            @test vec4(ig.c_get(s.Colors, ig.ImGuiCol_ModalWindowDimBg)) == (0f0, 0f0, 0f0, 0f0)   # draw_dialog draws it

            # Applying again does not scale twice.
            apply_style!(LIGHT, 2f0)
            @test vec2(unsafe_load(s.FramePadding)) == (16f0, 8f0)
            apply_style!(DARK, 1f0)
            @test vec2(unsafe_load(s.FramePadding)) == (8f0, 4f0)
            @test unsafe_load(s.ScrollbarSize) == 10f0
            @test unsafe_load(s.FrameBorderSize) == 1f0
            @test vec4(ig.c_get(s.Colors, ig.ImGuiCol_Text)) == DARK.text
        finally
            ig.DestroyContext(ctx)
        end
    end

    @testset "font files" begin
        for path in BUNDLED_FONTS
            @test isfile(path)
        end
        @test font_paths(:bundled) == BUNDLED_FONTS
        @test_throws ArgumentError font_paths(:nope)

        mktempdir() do dir
            # Nothing found: all bundled.
            @test find_system_fonts([dir]) == BUNDLED_FONTS
            mkpath(joinpath(dir, "a", "b"))
            mkpath(joinpath(dir, "c"))
            touch(joinpath(dir, "a", "b", "DejaVuSans.ttf"))
            touch(joinpath(dir, "a", "DejaVuSans-Bold.ttf"))
            touch(joinpath(dir, "c", "NotoSans-Regular.ttf"))   # no SemiBold: not used
            touch(joinpath(dir, "c", "DejaVuSansMono.ttf"))
            found = find_system_fonts([dir, joinpath(dir, "missing")])
            @test found.regular == joinpath(dir, "a", "b", "DejaVuSans.ttf")
            @test found.semibold == joinpath(dir, "a", "DejaVuSans-Bold.ttf")
            @test found.mono == joinpath(dir, "c", "DejaVuSansMono.ttf")
            # A full pair earlier in the order wins.
            touch(joinpath(dir, "NotoSans-SemiBold.ttf"))
            @test find_system_fonts([dir]).regular == joinpath(dir, "c", "NotoSans-Regular.ttf")
            # Names match without case, as Windows file names do.
            touch(joinpath(dir, "SEGOEUI.TTF")); touch(joinpath(dir, "SegUISB.ttf"))
            @test find_system_fonts([dir]).regular == joinpath(dir, "SEGOEUI.TTF")
        end
        # The user's own font folders come first.
        if Sys.islinux()
            dirs = UI.system_font_dirs(Dict("XDG_DATA_HOME" => "/xdg"), "/home/u")
            @test dirs == ["/xdg/fonts", "/home/u/.fonts", "/usr/local/share/fonts", "/usr/share/fonts"]
            @test first(UI.system_font_dirs(Dict{String,String}(), "/home/u")) == "/home/u/.local/share/fonts"
        elseif Sys.iswindows()
            dirs = UI.system_font_dirs(Dict("LOCALAPPDATA" => raw"C:\Users\u\AppData\Local", "WINDIR" => raw"C:\Windows"))
            @test dirs == [raw"C:\Users\u\AppData\Local\Microsoft\Windows\Fonts", raw"C:\Windows\Fonts"]
        end
    end

    @testset "a font file that cannot be read falls back to the bundled one" begin
        # ImGui would assert on a missing file before it returns NULL; the file is checked first.
        @test !UI.font_file_readable("/no/such/font.ttf")
        empty_file = tempname() * ".ttf"
        touch(empty_file)
        @test !UI.font_file_readable(empty_file)
        @test UI.font_file_readable(BUNDLED_FONTS.regular)
        ctx = ig.CreateContext()
        try
            atlas = unsafe_load(ig.GetIO().Fonts)
            f = @test_logs (:warn, r"Could not load the font /no/such/font.ttf") UI.add_font(atlas,
                "/no/such/font.ttf", BUNDLED_FONTS.regular)
            @test f.font != C_NULL
            f2 = @test_logs (:warn, r"Could not load the font") UI.add_font(atlas, empty_file, BUNDLED_FONTS.mono)
            @test f2.font != C_NULL
        finally
            ig.DestroyContext(ctx)
            rm(empty_file; force = true)
        end
    end

    @testset "the GLFW.jl internals that create_glfw_window copies are there" begin
        # A GLFW.jl that changes them breaks here, by name, not in a window.
        @test isdefined(GLFW, :_window_callbacks) && GLFW._window_callbacks isa AbstractDict
        @test isdefined(GLFW, :_window_callback_num) && GLFW._window_callback_num[] isa Integer
        @test isdefined(GLFW, :Callback)
        @test pkgversion(GLFW).major == 3 && pkgversion(GLFW).minor == 4
    end

    @testset "run_window refuses a task that may leave thread 1" begin
        for pool in (:interactive, :default)
            e = fetch(Threads.@spawn pool try
                run_window(w -> nothing)
            catch err
                err
            end)
            @test e isa ArgumentError && startswith(e.msg, "run_window must run on thread 1")
        end
    end

    @testset "GLFW error callback" begin
        # Logs from before this test set are not part of it.
        clear_glfw_log() = with_logger(() -> UI.log_glfw_errors(), NullLogger())
        UI.install_glfw_error_callback()
        cb = UI.GLFW_CALLBACK[]
        @test cb != C_NULL
        # It is the callback GLFW calls now (setting it again returns the current one).
        @test ccall((:glfwSetErrorCallback, GLFW.libglfw), Ptr{Cvoid}, (Ptr{Cvoid},), cb) == cb
        clear_glfw_log()
        # The WSLg monitor error: recorded, not thrown, logged as debug only.
        ccall(cb, Cvoid, (Cint, Ptr{UInt8}), Cint(GLFW.PLATFORM_ERROR),
            "X11: Failed to query video mode")
        @test UI.glfw_last_error() == (Int(GLFW.PLATFORM_ERROR), "X11: Failed to query video mode")
        @test_logs (:debug, r"Failed to query video mode") min_level = Debug UI.log_glfw_errors()
        @test_logs UI.log_glfw_errors()   # each error is logged once
        # Any other error is a warning.
        ccall(cb, Cvoid, (Cint, Ptr{UInt8}), Cint(GLFW.INVALID_ENUM), "Invalid window hint")
        @test_logs (:warn, r"Invalid window hint") UI.log_glfw_errors()
        # A platform error that only names a monitor is not taken for a monitor change.
        ccall(cb, Cvoid, (Cint, Ptr{UInt8}), Cint(GLFW.PLATFORM_ERROR), "Wayland: Failed to create monitor surface")
        @test_logs (:warn, r"monitor surface") UI.log_glfw_errors()
        @test UI.monitor_error(Int(GLFW.PLATFORM_ERROR), "X11: Failed to query video mode")
        @test !UI.monitor_error(Int(GLFW.INVALID_ENUM), "X11: Failed to query video mode")
        # A real GLFW error goes through it too and throws nothing.
        if GLFW.is_initialized()
            GLFW.WindowHint(0x7fff0000, 1)
            @test UI.glfw_last_error()[1] == Int(GLFW.INVALID_ENUM)
            @test_logs (:warn, r"GLFW error") UI.log_glfw_errors()
        end
        # A long text is cut to the buffer, with no overrun.
        ccall(cb, Cvoid, (Cint, Ptr{UInt8}), Cint(GLFW.PLATFORM_ERROR), "x"^2000)
        @test UI.glfw_last_error()[2] == "x"^(UI.GLFW_TEXT_SIZE - 1)
        clear_glfw_log()
    end

    window_testset("window") do
        mkpath(SHOTS)

        @testset "a window that cannot open raises" begin
            before = UI.GLFW_ERRORS[]
            err = try
                UI.create_glfw_window("bad", (0, 0), true)
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test startswith(err.msg, "could not open a window with OpenGL 3.3: ")
            @test UI.GLFW_ERRORS[] > before
            with_logger(() -> UI.log_glfw_errors(), NullLogger())
        end

        # Draw a few widgets, keep the loop busy, capture at frame 30 and quit.
        function capture_run(shot; scale = nothing)
            got = Ref{Any}(nothing)
            run_window(; fonts = :bundled, scale, passive = true) do w
                request_frames!(w)
                ig.SetNextWindowPos((px(w, 24), px(w, 24)))
                ig.Begin("Sample")
                ig.Text("JuliaMag sample text Hg")
                with_font(FONT_SEMIBOLD, 13) do
                    ig.Text("Semibold 13")
                end
                with_font(FONT_MONO, 12) do
                    ig.Text("mono 0123456789")
                end
                ig.Button("Button")
                ig.End()
                if w.frame == 30
                    height = ig.CalcTextSize("Hg").y
                    capture_png(w, shot)
                    real = min_size_limit((900, 560), content_scale(w.handle),
                        GLFW.GetWindowSize(w.handle)[1], GLFW.GetFramebufferSize(w.handle)[1])
                    got[] = (; height, scale = w.scale, px10 = px(w, 10),
                        limit = min_size_limit(w), real)
                    quit!(w)
                end
                return nothing
            end
            return got[]
        end

        @testset "window, capture and scale" begin
            shot1 = joinpath(SHOTS, "loop-scale1.png")
            shot2 = joinpath(SHOTS, "loop-scale2.png")
            rm(shot1; force = true)
            rm(shot2; force = true)

            r1 = capture_run(shot1; scale = 1f0)
            @test r1 !== nothing
            img = PNGFiles.load(shot1)
            @test size(img) == (920, 1480)
            centre = rgb(img[460, 740])
            @test all(abs.(centre .- LIGHT.canvas[1:3]) .<= 1 / 255 + 1f-6)
            @test r1.px10 == 10f0

            r2 = capture_run(shot2; scale = 2f0)
            img2 = PNGFiles.load(shot2)
            @test size(img2) == (920, 1480)   # still the framebuffer size
            @test r2.scale == 2f0 && r2.px10 == 20f0
            # A forced scale does not change the minimum size: it follows the monitor.
            @test r2.limit == r2.real
            @test r1.limit == r1.real
            @test abs(r2.height - 2 * r1.height) <= 1
        end

        @testset "closing" begin
            # The user closes the window twice; on_close keeps it open the first time.
            asked = Ref(0)
            frames = Ref(0)
            run_window(; fonts = :bundled, passive = true,
                    on_close = () -> (asked[] += 1; asked[] >= 2)) do w
                request_frames!(w)
                frames[] = w.frame
                w.frame in (5, 10) && GLFW.SetWindowShouldClose(w.handle, true)
                w.frame >= 100 && quit!(w)   # only if closing is broken
                return nothing
            end
            @test asked[] == 2
            @test frames[] == 10

            # An error in ui ends the loop, closes the window and reaches the caller.
            @test_throws ErrorException("boom") run_window(; fonts = :bundled, passive = true) do w
                w.frame == 2 && error("boom")
                return nothing
            end
            # A window still works after that.
            n = Ref(0)
            run_window(; fonts = :bundled, passive = true) do w
                request_frames!(w)
                n[] = w.frame
                w.frame == 3 && quit!(w)
            end
            @test n[] == 3
        end

        @testset "idle and wake" begin
            # The waker must run on a thread that is not the render thread.
            @test Threads.threadid() == 1
            n_wakes = 9
            # One run: 2 s with no input, a Julia timer, then 9 wakes from a worker thread.
            function idle_run()
                waker_thread = Threads.Atomic{Int}(0)
                frame_times = Float64[]
                pending = Threads.Atomic{Float64}(0.0)   # time of a wake not yet seen
                latencies = Float64[]
                t0 = Ref(0.0)
                idle_from = Ref(0.0)   # start of the 2 s with no input
                timer_fired = Ref(0.0)
                worker = Ref{Task}()
                run_window(; fonts = :bundled, passive = true) do w
                    now = time()
                    t0[] == 0 && (t0[] = now)
                    push!(frame_times, now)
                    p = pending[]
                    if p > 0 && now >= p
                        push!(latencies, now - p)
                        pending[] = 0.0
                    end
                    # The window gets a burst of events when it shows. Wait for it to pass.
                    if idle_from[] == 0 && now - t0[] > 1.0 && now >= w.animating_until
                        idle_from[] = now
                        # A Julia timer on thread 1 must still run while the loop idles.
                        Timer(_ -> (timer_fired[] = time()), 0.3)
                    end
                    # After the 2 s idle, a worker wakes the loop 9 times.
                    if idle_from[] > 0 && now - idle_from[] > 2.0 && !isassigned(worker)
                        worker[] = Threads.@spawn begin
                            waker_thread[] = Threads.threadid()
                            waker_thread[] == 1 && return   # checked below
                            for _ in 1:n_wakes
                                Libc.systemsleep(0.2 + 0.05 * rand())
                                pending[] = time()
                                wake!(w)
                            end
                        end
                    end
                    done = length(latencies) >= n_wakes
                    (done || now - t0[] > 20) && quit!(w)
                    return nothing
                end
                isassigned(worker) && wait(worker[])
                idle = count(t -> idle_from[] <= t < idle_from[] + 2.0, frame_times)
                return (; idle, idle_from = idle_from[], timer_late = timer_fired[] - idle_from[] - 0.3,
                    latencies, waker = waker_thread[])
            end
            # The loop waits at most 0.1 s, so about 20 frames in 2 s; never a busy loop. A
            # timer fires at the end of the next idle wait at the latest. A wake comes through
            # at once: a timeout frame alone would give a median of about 50 ms.
            timing_ok(r) = 15 <= r.idle <= 25 && 0 < r.timer_late <= 0.15 &&
                length(r.latencies) == n_wakes && all(<=(0.150), r.latencies) &&
                sort(r.latencies)[(n_wakes + 1) ÷ 2] <= 0.025
            r = idle_run()
            if r.waker > 1 && r.idle_from > 0 && !timing_ok(r)
                # Wall-clock bounds: a machine busy with other work can miss them once.
                @info "Idle and wake: the timing was off, so the run is repeated once (a busy machine?)" r.idle r.timer_late r.latencies
                r = idle_run()
            end
            @debug "Idle loop: $(r.idle) frames in 2 s; timer late by $(round(Int, 1000 * r.timer_late)) ms; " *
                   "wake latencies (ms): $(join(round.(Int, 1000 .* r.latencies), ", "))"
            r.waker == 1 && @error "The waker ran on the render thread. Run the tests with `julia -t auto,1`."
            @test r.waker > 1
            @test r.idle_from > 0
            @test 15 <= r.idle <= 25
            @test 0 < r.timer_late <= 0.15
            @test length(r.latencies) == n_wakes
            @test all(<=(0.150), r.latencies)
            @test length(r.latencies) == n_wakes && sort(r.latencies)[(n_wakes + 1) ÷ 2] <= 0.025
        end
    end
end

# GLFW's monitor query can get RANDR BadRRCrtc from the X server, and Xlib's default
# handler then exits the process. A child process makes that query with a bad CRTC:
# with the app's handler it lives on, without it (the handler kept off) it dies.
const X11_CHILD = raw"""
import JuliaMagUI, GLFW
const L = Base.Libc.Libdl
ARGS[1] == "without" && (JuliaMagUI.X_HANDLER_INSTALLED[] = true)   # keep it off
JuliaMagUI.run_window(; fonts = :bundled, passive = true) do w
    JuliaMagUI.request_frames!(w)
    if w.frame == 1
        dpy = ccall((:glfwGetX11Display, GLFW.libglfw), Ptr{Cvoid}, ())
        x11 = L.dlopen("libX11.so.6")
        xrr = L.dlopen("libXrandr.so.2")
        root = ccall(L.dlsym(x11, :XDefaultRootWindow), Culong, (Ptr{Cvoid},), dpy)
        res = ccall(L.dlsym(xrr, :XRRGetScreenResourcesCurrent), Ptr{Cvoid},
            (Ptr{Cvoid}, Culong), dpy, root)
        info = ccall(L.dlsym(xrr, :XRRGetCrtcInfo), Ptr{Cvoid},
            (Ptr{Cvoid}, Ptr{Cvoid}, Culong), dpy, res, 0x0123_4567)
        ccall(L.dlsym(xrr, :XRRFreeScreenResources), Cvoid, (Ptr{Cvoid},), res)
        println("QUERY ", info == C_NULL ? "failed" : "worked")
    elseif w.frame == 3
        println("IGNORED ", JuliaMagUI.X_IGNORED[])
        JuliaMagUI.quit!(w)
    end
    nothing
end
println("ALIVE")
"""

window_testset("X11 errors") do
    if !Sys.islinux() || GLFW.GetPlatform() != GLFW.PLATFORM_X11
        @test_skip "needs X11"
    else
        run_child(mode) = begin
            cmd = `$(Base.julia_cmd()) -t auto,1 --project=$(Base.active_project()) -e $X11_CHILD $mode`
            out, err = IOBuffer(), IOBuffer()
            ok = success(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
            (; ok, out = String(take!(out)), err = String(take!(err)))
        end
        with = run_child("with")
        @test with.ok
        @test occursin("QUERY failed", with.out)
        @test occursin("IGNORED 1", with.out)
        @test occursin("ALIVE", with.out)
        without = run_child("without")
        @test !without.ok
        @test occursin("RANDR", without.err)
        @test !occursin("ALIVE", without.out)
    end
end
