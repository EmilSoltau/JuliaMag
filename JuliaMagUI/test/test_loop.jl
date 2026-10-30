using Test
import CImGui as ig
import PNGFiles
import GLFW
using JuliaMagUI: Window, run_window, quit!, px, apply_style!, LIGHT, DARK, capture_png,
    wake!, request_frames!, with_font, FONT_REGULAR, FONT_SEMIBOLD, FONT_MONO,
    find_system_fonts, font_paths, BUNDLED_FONTS

# Window tests need a display. Task 6 turns this into test/support/app.jl.
const HAS_DISPLAY = Sys.iswindows() || haskey(ENV, "DISPLAY") || haskey(ENV, "WAYLAND_DISPLAY")
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
        @test px(1.25f0, 34) == 42f0
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
            @test vec4(ig.c_get(s.Colors, ig.ImGuiCol_ModalWindowDimBg)) == LIGHT.backdrop

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
        end
    end

    if !HAS_DISPLAY
        @info "Window tests skipped: no display (DISPLAY and WAYLAND_DISPLAY are not set)."
        @testset "window" begin
            @test_skip "needs a display"
        end
    else
        mkpath(SHOTS)

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
                    got[] = (; height, scale = w.scale, px10 = px(w, 10))
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
            # The test needs a worker thread that is not the render thread.
            @test Threads.threadid() == 1
            @test Threads.nthreads(:default) >= 1

            frame_times = Float64[]
            pending = Threads.Atomic{Float64}(0.0)   # time of a wake not yet seen
            latencies = Float64[]
            n_wakes = 9
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
            @debug "Idle loop: $idle frames in 2 s; timer late by " *
                   "$(round(Int, 1000 * (timer_fired[] - idle_from[] - 0.3))) ms; " *
                   "wake latencies (ms): $(join(round.(Int, 1000 .* latencies), ", "))"
            @test idle_from[] > 0
            # The loop waits at most 0.1 s, so about 20 frames; never a busy loop.
            @test 15 <= idle <= 25
            # It fires at the end of the next idle wait at the latest.
            @test 0 < timer_fired[] - idle_from[] - 0.3 <= 0.15
            @test length(latencies) == n_wakes
            @test all(<=(0.150), latencies)
            # A timeout frame alone would give a median of about 50 ms.
            @test length(latencies) == n_wakes && sort(latencies)[(n_wakes + 1) ÷ 2] <= 0.025
        end
    end
end
