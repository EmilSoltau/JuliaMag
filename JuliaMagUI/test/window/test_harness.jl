using Test
using Base.CoreLogging: with_logger, NullLogger   # Logging is not a test dependency
import CImGui as ig
import PNGFiles
import ModernGL as GL
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK, px, draw_icon, ICON_ATLASES

const HARNESS_SHOTS = joinpath(@__DIR__, "..", "shots")

# A pixel of a loaded PNG as 0-255 RGB.
rgb255(p) = (round(Int, 255 * Float32(p.r)), round(Int, 255 * Float32(p.g)),
    round(Int, 255 * Float32(p.b)))
rgb255(c::NTuple{4,Float32}) = (round(Int, 255 * c[1]), round(Int, 255 * c[2]),
    round(Int, 255 * c[3]))
near(a, b; tol = 3) = all(abs(a[i] - b[i]) <= tol for i in 1:3)

# Every icon at `size` logical px in rows, with `gap` px between them.
function draw_icon_grid(w; size = 32, gap = 16, left = 24, top = 24, style = :normal)
    names = UI.ICON_ATLASES[w.ctx].names
    step = size + gap
    per_row = 24
    dl = ig.GetBackgroundDrawList()
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

window_testset("harness") do
    mkpath(HARNESS_SHOTS)

    @testset "with_test_app, shot and a 32 px icon" begin
        path = joinpath(HARNESS_SHOTS, "harness-database.png")
        icon_at = (40, 40)
        seen = Ref{Any}(nothing)
        draw = w -> draw_icon(ig.GetBackgroundDrawList(), "database", icon_at, 32)
        with_test_app(; theme = THEME_LIGHT, extra_ui = draw) do ctx
            seen[] = ctx.window
            ctx.frames(2)
            @test ctx.shot(path) == path
        end
        @test seen[] isa UI.Window
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
        result = with_test_app(; theme = THEME_LIGHT) do ctx
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
        @test result.failed == (DARK, 1f0)
        @test result.texture == result.old && result.tokens == LIGHT
        @test !result.after
        @test result.retried == DARK
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
        @test near(rgb255(img[10, 10]), rgb255(DARK.canvas); tol = 1)
        @test !isfile(joinpath(out, "never.png"))
        @test redirect_stdio(() -> shot_main(["only-one-argument"]); stderr = devnull) == 2
    end
end
