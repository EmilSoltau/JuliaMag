using Test
using Base.CoreLogging: with_logger, NullLogger   # Logging is not a test dependency
import CImGui as ig
import PNGFiles
import ModernGL as GL
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK, px, draw_icon, ICON_ATLASES

const HARNESS_SHOTS = joinpath(@__DIR__, "..", "shots")


# Every icon at `size` logical px in rows, with `gap` px between them.
function draw_icon_grid(w; size = 32, gap = 16, left = 24, top = 24, style = :normal)
    names = UI.ICON_ATLASES[w.ctx].names
    step = size + gap
    per_row = 24
    dl = ig.GetForegroundDrawList()   # over the app
    for (i, name) in enumerate(names)
        row, col = divrem(i - 1, per_row)
        draw_icon(dl, name, (px(w, left + col * step), px(w, top + row * step)), size; style)
    end
    return nothing
end

@testset "key chords" begin
    @test key_chord("Ctrl+K") == Int(ig.ImGuiMod_Ctrl) | Int(ig.lib.ImGuiKey_K)
    @test key_chord("Ctrl+Shift+z") ==
          Int(ig.ImGuiMod_Ctrl) | Int(ig.ImGuiMod_Shift) | Int(ig.lib.ImGuiKey_Z)
    @test key_chord("Alt+LeftArrow") == Int(ig.ImGuiMod_Alt) | Int(ig.lib.ImGuiKey_LeftArrow)
    @test key_chord("Alt+Left") == key_chord("Alt+LeftArrow")
    @test key_chord("Esc") == Int(ig.lib.ImGuiKey_Escape)
    @test key_chord("F1") == Int(ig.lib.ImGuiKey_F1)
    @test_throws ArgumentError key_chord("Hyper+K")
    @test_throws ArgumentError key_chord("Ctrl+Nope")
end

@testset "ref_part: an id made from a path stays one id, backslashes and all" begin
    # The id ImGui makes for `text` pushed under the id "recent", as the recent rows do.
    imgui_id(text) = ig.lib.igImHashStr(text, 0, ig.lib.igImHashStr("recent", 0, 0))
    ref_id(text) = te.ImHashDecoratedPath("recent/" * ref_part(text))
    for path in ("C:\\Users\\me", "/tmp/a b/c", "\\\\server\\share/x", "Geosoft or Surfer grid...")
        @test ref_id(path) == imgui_id(path)
    end
    # Without the escape, the engine drops the backslashes: two paths would be one.
    @test ref_part("C:\\Users\\me") == "C:\\\\Users\\\\me"
    @test te.ImHashDecoratedPath("recent/" * ref_part("C:\\Users\\me")) !=
          te.ImHashDecoratedPath("recent/C:Usersme")
    @test te.ImHashDecoratedPath("recent/C:\\Users\\me") == te.ImHashDecoratedPath("recent/C:Usersme")
end

window_testset("harness") do
    mkpath(HARNESS_SHOTS)

    @testset "with_test_app, shot and a 32 px icon" begin
        path = joinpath(HARNESS_SHOTS, "harness-database.png")
        icon_at = (600, 300)   # over the empty central area, which has the canvas colour
        seen = Ref{Any}(nothing)
        app = Ref{Any}(nothing)
        draw = w -> draw_icon(ig.GetForegroundDrawList(), "database", icon_at, 32)
        with_test_app(; theme = THEME_LIGHT, extra_ui = draw) do ctx
            seen[] = ctx.window
            app[] = ctx.app_state()
            @test app[].window === ctx.window && app[].session === nothing
            ctx.frames(2)
            @test ctx.shot(path) == path
        end
        @test seen[] isa UI.Window
        # The app closed: its window is gone and its worker has ended.
        @test app[] isa UI.AppState && app[].window === nothing && istaskdone(app[].queue.task)
        @test isfile(path)
        img = PNGFiles.load(path)
        @test size(img) == (920, 1480)
        icon = [rgb255(img[y, x]) for y in icon_at[2]+1:icon_at[2]+32, x in icon_at[1]+1:icon_at[1]+32]
        # Ink strokes in the icon colour.
        @test any(p -> near(p, rgb255(LIGHT.icon)), icon)
        # The accent fill of the top ellipse: the accent at 22 % over the canvas.
        tint = rgb255(0.22f0 .* LIGHT.accent .+ 0.78f0 .* LIGHT.canvas)
        @test any(p -> near(p, tint), icon)
        # Outside the icon there is only the canvas.
        @test near(rgb255(img[icon_at[2]+40, icon_at[1]+16]), rgb255(LIGHT.canvas); tol = 1)
        # The window is closed and its icon texture is gone.
        @test isempty(ICON_ATLASES)
    end

    @testset "theme change rebuilds the icons and frees the old texture" begin
        result = with_test_app(; theme = THEME_LIGHT,
                extra_ui = w -> draw_icon(ig.GetBackgroundDrawList(), "tool", (8, 8), 16)) do ctx
            old = Ref{UInt32}(0)
            ctx.on_render(w -> (old[] = ICON_ATLASES[w.ctx].texture))
            ctx.on_render(w -> UI.set_theme!(w, DARK))
            ctx.frames(1)
            state = Ref{Any}(nothing)
            ctx.on_render(w -> begin
                atlas = ICON_ATLASES[w.ctx]
                state[] = (; tokens = atlas.tokens, old = old[], texture = atlas.texture,
                    old_alive = GL.glIsTexture(old[]) == GL.GL_TRUE)
            end)
            state[]
        end
        @test result.tokens == DARK
        # The new atlas is uploaded before the old one is freed, so the names differ.
        @test result.texture != result.old
        @test !result.old_alive
    end

    @testset "a failed icon build keeps the old atlas and the app running" begin
        result = try
        with_test_app(; theme = THEME_LIGHT) do ctx
            state = Ref{Any}(nothing)
            ctx.on_render(w -> begin
                old = ICON_ATLASES[w.ctx].texture
                UI.ICON_SVGS[] = ["broken" => "<svg"]   # Rsvg cannot read this
                UI.set_theme!(w, DARK)
                with_logger(NullLogger()) do
                    UI.update_icons!(w)
                end
                state[] = (; old, failed = get(UI.ICON_FAILURES, w.ctx, nothing))
            end)
            ctx.frames(3)   # the loop does not try again, so it logs nothing more
            ctx.on_render(w -> begin
                atlas = ICON_ATLASES[w.ctx]
                state[] = (; state[]..., texture = atlas.texture, tokens = atlas.tokens)
                # Back to working icons: the next build succeeds.
                UI.ICON_SVGS[] = nothing
                UI.set_theme!(w, LIGHT)
            end)
            ctx.frames(1)
            ctx.on_render(w -> (state[] = (; state[]...,
                after = haskey(UI.ICON_FAILURES, w.ctx))))
            # The theme that failed builds once the icons are readable again.
            ctx.on_render(w -> UI.set_theme!(w, DARK))
            ctx.frames(1)
            ctx.on_render(w -> (state[] = (; state[]..., retried = ICON_ATLASES[w.ctx].tokens)))
            state[]
        end
        finally
            UI.ICON_SVGS[] = nothing   # also when the test failed, so later tests get the real icons
        end
        @test result.failed == (DARK, 1f0)
        @test result.texture == result.old && result.tokens == LIGHT
        @test !result.after
        @test result.retried == DARK
    end

    @testset "a failed body leaves no pushed item width or text wrap behind (T9-P2)" begin
        r = with_test_app(; draw_errors_ok = true) do ctx
            app = ctx.app_state()
            out = Ref{Any}(nothing)
            ctx.on_render(w -> begin
                ig.Begin("stacks test")
                win = ig.lib.igGetCurrentWindowRead()
                sizes() = UI.window_stack_sizes(win)
                before = sizes()
                failed = with_logger(NullLogger()) do
                    UI.run_body(() -> (ig.PushItemWidth(10); ig.PushTextWrapPos(5); error("the body broke")), app)
                end
                out[] = (; failed, before, after = sizes())
                ig.End()
            end)
            ctx.frames(2)
            (; out[]..., errors = length(app.draw_errors))
        end
        @test r.failed && r.after == r.before && r.errors == 1
    end

    @testset "an atlas the card does not take: no texture, an error, the app runs on" begin
        result = with_test_app() do ctx
            r = Ref{Any}(nothing)
            ctx.on_render(w -> begin
                big = UI.build_icon_atlas(LIGHT, 1f0)
                logger = Test.TestLogger()
                too_big = with_logger(() -> UI.upload!(big; max_size = 16), logger)
                # A size OpenGL refuses gives an OpenGL error, which is reported too.
                bad = UI.build_icon_atlas(LIGHT, 1f0)
                bad.width = -1
                gl_error = with_logger(() -> UI.upload!(bad), logger)
                r[] = (; too_big, gl_error, big = big.texture, bad = bad.texture,
                    messages = [l.message for l in logger.logs])
            end)
            r[]
        end
        @test !result.too_big && !result.gl_error && result.big == 0 && result.bad == 0
        @test occursin("allows at most 16", result.messages[1])
        @test occursin("OpenGL error 0x501", result.messages[2])   # GL_INVALID_VALUE
    end

    @testset "the overall timeout ends a test that hangs" begin
        t0 = time()
        err = try
            with_test_app(ctx -> ctx.wait_until(() -> false; timeout = 60); timeout = 2)
            nothing
        catch e
            e
        end
        @test err isa CapturedException && err.ex isa TestTimeout
        @test time() - t0 < 30
        @test isempty(ICON_ATLASES)
    end

    @testset "a test stuck outside the harness: the watchdog stops it" begin
        # The real `stop` ends the process; this one only notes the call.
        stopped = Threads.Atomic{Bool}(false)
        finished = Threads.Atomic{Bool}(false)
        out = Pipe()
        redirect_stderr(out) do
            watch_hang(finished, 0.2; grace = 0.3, stop = () -> (stopped[] = true))
            @test timedwait(() -> stopped[], 10) === :ok
        end
        close(out.in)
        @test occursin("stuck outside the test harness", read(out, String))
        # A test that ends in time is left alone.
        stopped[] = false
        watch_hang(finished, 0.2; grace = 0.3, stop = () -> (stopped[] = true))
        finished[] = true
        sleep(1.5)
        @test !stopped[]
    end

    @testset "errors in the test function reach the caller" begin
        @test_throws CapturedException with_test_app(ctx -> error("boom"))
        err = try
            with_test_app(ctx -> ctx.wait_until(() -> false; timeout = 0.2))
            nothing
        catch e
            e
        end
        @test err isa CapturedException && occursin("did not hold", sprint(showerror, err.ex))
        err = try
            with_test_app(ctx -> ctx.click("No such window/No such button"))
            nothing
        catch e
            e
        end
        @test err isa CapturedException && occursin("no item", sprint(showerror, err.ex))
        @test isempty(ICON_ATLASES)
    end

    # All icons at 32 px, light and dark, for comparing with the prototype by eye.
    @testset "icon grid shots" begin
        for (theme, tokens, name) in ((THEME_LIGHT, LIGHT, "icons-32-light.png"),
                (THEME_DARK, DARK, "icons-32-dark.png"))
            path = joinpath(HARNESS_SHOTS, name)
            with_test_app(; theme, extra_ui = draw_icon_grid) do ctx
                ctx.frames(1)
                ctx.shot(path)
            end
            img = PNGFiles.load(path)
            grid = [rgb255(img[y, x]) for y in 24:24+5*48, x in 24:24+24*48]
            @test any(p -> near(p, rgb255(tokens.icon)), grid)
        end
    end
end

include(joinpath(@__DIR__, "..", "..", "tools", "shot.jl"))

@testset "shot script" begin
    mktempdir() do dir
        script = joinpath(dir, "s.jsonl")
        write(script, "# comment\n\n{\"theme\": \"dark\"}\n{\"wait\": 2}\n")
        @test read_script(script) == [3 => ("theme" => "dark"), 4 => ("wait" => 2)]
        write(script, "{\"theme\": \"dark\", \"wait\": 2}\n")
        @test_throws "line 1: expected an object with one action" read_script(script)
        write(script, "{nope\n")
        @test_throws "line 1: not valid JSON" read_script(script)
    end
end

window_testset("shot tool") do
    mktempdir() do dir
        script = joinpath(dir, "s.jsonl")
        out = joinpath(dir, "out")
        write(script, """
            {"theme": "dark"}
            {"size": [1200, 800]}
            {"shot": "dark"}
            {"open": "/no/such/project"}
            {"shot": "never"}
            """)
        status = redirect_stdio(stdout = devnull, stderr = devnull) do
            shot_main([script, out])
        end
        @test status == 1   # "open" is not built yet
        img = PNGFiles.load(joinpath(out, "dark.png"))
        @test size(img) == (800, 1200)
        @test near(rgb255(img[10, 300]), rgb255(DARK.header); tol = 1)
        @test near(rgb255(img[300, 400]), rgb255(DARK.canvas); tol = 1)
        @test !isfile(joinpath(out, "never.png"))
        @test redirect_stdio(() -> shot_main(["only-one-argument"]); stderr = devnull) == 2
        @test redirect_stdio(() -> shot_main(["--timeout=soon", script, out]); stderr = devnull) == 2
        # A long review gets more time; the run of this script is short.
        write(script, "{\"shot\": \"timed\"}\n")
        status = redirect_stdio(stdout = devnull, stderr = devnull) do
            shot_main(["--timeout=600", script, out])
        end
        @test status == 0 && isfile(joinpath(out, "timed.png")) && TEST_TIMEOUT[] == 600
    end
end
