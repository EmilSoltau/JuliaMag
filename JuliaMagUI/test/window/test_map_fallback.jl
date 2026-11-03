using Test
import ModernGL as GL
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: MAP_GL, MAP_CPU, THEME_LIGHT, THEME_DARK, LIGHT, DARK

const FRAME_SHOTS = joinpath(@__DIR__, "..", "shots")

# A project with 40 lines over a grid on one map. Returns the session and the map id.
function frame_project()
    s = fresh_session()
    db = survey_database!(s; lines = 40, rows = 200)
    A = Float32[100sin(i / 17) * cos(j / 23) + 0.5i for i in 1:200, j in 1:196]
    g = add_test_grid!(s, A; name = "TMI")
    m = Core.new_map!(s; name = "Survey")
    Core.add_layer!(s, m, g)
    Core.add_layer!(s, m, db)
    return s, m
end

# Show map `m` and wait for a full picture of its current scene drawn in `mode`, with every
# layer loaded (and, for GL, uploaded).
function wait_picture(ctx, app, m, mode; timeout = 10)
    ctx.on_render(w -> (app.ui.current_map = m))
    ms = app.map
    r = ms.renderer
    ctx.wait_until(; timeout) do
        r.mode == mode && ms.plan_map == m && !isempty(ms.plan) &&
            all(p -> p.entry !== nothing && p.entry.data !== nothing && !p.entry.loading, ms.plan) &&
            (mode == MAP_CPU || (r.gl !== nothing && isempty(r.gl.pending))) &&
            r.cpu_task === nothing && r.done === nothing && r.ready === nothing && r.image.map == m && r.image.key == ms.scene.key
    end
    ctx.frames(2)
    return nothing
end

# The map image as `render_cpu!` lays out a picture.
function map_image(ctx, app)
    got = Ref{Any}(nothing)
    ctx.on_render(w -> (got[] = UI.read_image(app.map.renderer)))
    return got[]
end

view_pixels(v) = (round(Int, UI.width(v)), round(Int, UI.height(v)))
# `pred()` in the next frame, before its map pass: what the passes so far left. (A test
# action may return between the view and the map pass of a frame.)
function seen_after_pass(ctx, pred)
    got = Ref(false)
    ctx.on_render(w -> (got[] = pred()))
    return got[]
end

# The bytes one map pass allocates, after a warm-up pass.
# The bytes placing the map image allocates (`draw_map_image`, the view's part), after a warm-up.
function image_allocated(app)
    r, b = app.map.renderer, app.map.view
    st = app.map.views[app.ui.current_map]
    dl = ig.GetForegroundDrawList()
    args = (r, dl, b, st, view_pixels(b)..., app.ui.current_map)
    UI.draw_map_image(args...)
    return @allocated UI.draw_map_image(args...)
end

# The Warn and Error entries of a test logger.
log_count(logger, level) = count(e -> e.level == level, logger.logs)

pass_allocated(app, w) = (UI.map_gl_pass!(app, w); @allocated UI.map_gl_pass!(app, w))
gl_get(e) = (b = GL.GLint[-1]; GL.glGetIntegerv(e, b); b[1])
framebuffer_binding() = (b = GL.GLint[-1]; GL.glGetIntegerv(GL.GL_FRAMEBUFFER_BINDING, b); b[1])
view_centre(app) = ((app.map.view.x0 + app.map.view.x1) / 2, (app.map.view.y0 + app.map.view.y1) / 2)

# The mean and the largest RGB difference (0-255) of two shots inside the map view, and the
# share of pixels that differ by more than 64 in a channel.
function shot_diff(a_path, b_path, v)
    a, b = PNGFiles.load(a_path), PNGFiles.load(b_path)
    total, big, n = 0, 0, 0
    for y in round(Int, v.y0):round(Int, v.y1)-1, x in round(Int, v.x0):round(Int, v.x1)-1
        d = abs.(rgb255(a[y+1, x+1]) .- rgb255(b[y+1, x+1]))
        total += sum(d)
        big += maximum(d) > 64
        n += 1
    end
    return total / 3n, big / n
end

window_testset("map frames and fallback") do
    s, m = frame_project()
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    Base.CoreLogging.with_logger(logger) do
        with_project_app(s; timeout = 300) do ctx, app
            r = app.map.renderer
            wait_picture(ctx, app, m, MAP_GL)
            @test r.gl !== nothing && r.full_draws >= 1
            @test UI.status_texts(app).render == "Software"   # the tests run on llvmpipe
            gl_shot = ctx.shot(joinpath(FRAME_SHOTS, "map-gl-light.png"))
            gl_img = map_image(ctx, app)
            @test size(gl_img) == view_pixels(app.map.view)

            @testset "Map Drawing: CPU draws the next full image on the CPU; Auto brings GL back" begin
                n = r.full_draws
                UI.set_map_drawing!(app, "cpu")
                wait_picture(ctx, app, m, MAP_CPU)
                @test r.gl === nothing && r.full_draws == n + 1
                @test UI.status_texts(app).render == "CPU map"
                cpu_shot = ctx.shot(joinpath(FRAME_SHOTS, "map-cpu-light.png"))
                cpu_img = map_image(ctx, app)
                err, outliers = parity(cpu_img, gl_img)
                @test err < 1.5 && outliers == 0
                mean, big = shot_diff(gl_shot, cpu_shot, app.map.view)
                @test mean < 1.5 && big == 0
                UI.set_map_drawing!(app, "auto")
                wait_picture(ctx, app, m, MAP_GL)
                @test r.gl !== nothing && r.full_draws == n + 2
                @test parity(map_image(ctx, app), gl_img) == (0.0, 0)
                @test isempty(app.draw_errors)
            end

            @testset "a slow full picture moves the last image while the view moves" begin
                st = app.map.views[m]
                from = view_centre(app)
                r.cost_override = 0.05
                ctx.mouse_to(from)
                te.MouseDown(0)
                n = r.full_draws
                for k in 1:5
                    ctx.mouse_to(from .- (14k, 9k))
                end
                @test seen_after_pass(ctx, () -> r.full_draws == n && r.image.camera != st.camera)
                path = ctx.shot(joinpath(FRAME_SHOTS, "map-moving-light.png"))
                # The part the moved image does not cover is canvas, with no seam at its edge.
                img = PNGFiles.load(path)
                v = app.map.view
                rect = UI.image_rect(r.image, st.camera, view_pixels(v)...)
                y = round(Int, v.y0 + (v.y1 - v.y0) / 2)
                edge = round(Int, v.x0 + rect[3])                 # the first column right of the image
                @test rect[3] < UI.width(v) - 40
                # The image's own edge is background too (the extent is padded), so a seam would show.
                @test all(x -> near(rgb255(img[y+1, x+1]), rgb255(LIGHT.canvas); tol = 1), edge-3:edge+20)
                # Moving the last image allocates nothing: the map pass, and the view placing the
                # image. After the shot, as the second places one more image on top.
                # (`plan_frame!` and `image_rect` alone: test_map_frame.jl.)
                bytes = Ref(-1)
                ctx.on_render(w -> (bytes[] = pass_allocated(app, w)))
                @test bytes[] == 0
                ctx.on_render(w -> (bytes[] = image_allocated(app)))
                @test bytes[] == 0
                @test r.full_draws == n
                te.MouseUp(0)
                t0 = time()
                ctx.wait_until(() -> r.full_draws > n; timeout = 2)
                @test time() - t0 <= 0.3
                @test r.full_draws == n + 1 && r.image.camera == st.camera

                r.cost_override = 0.005
                ctx.wait_until(() -> st.before === nothing)
                ctx.mouse_to(from)
                te.MouseDown(0)
                for k in 1:5
                    ctx.mouse_to(from .+ (14k, 9k))
                    # Seen in the next frame, after this frame's pass: drawn in full in every drag frame.
                    @test seen_after_pass(ctx, () -> r.image.camera == st.camera)
                end
                te.MouseUp(0)
                r.cost_override = nothing
                ctx.wait_until(() -> st.before === nothing)
                @test isempty(app.draw_errors)
            end

            @testset "Review Focus 5: the GL pass fails mid-session" begin
                @test r.mode == MAP_GL
                # The GL pass of this frame fails. The next frame, before its own pass, sees what
                # the failing frame left: the CPU mode, no GL objects and framebuffer 0.
                t0 = time()
                ctx.on_render(w -> (r.fail_next = true))
                after = Ref{Any}(nothing)
                ctx.on_render(w -> (after[] = (r.mode, r.gl === nothing, r.fail_next, framebuffer_binding())))
                @test after[] == (MAP_CPU, true, false, 0)
                t = last(app.toasts)
                @test t.kind === :warn &&
                      t.text == "The map could not draw with the graphics card, so it draws on the CPU now." &&
                      t.sub == "The test hook made the map pass fail."
                @test r.gl_problem == "The test hook made the map pass fail."
                ctx.wait_until(; timeout = 2) do
                    r.image.key == app.map.scene.key && r.image.map == m && r.done === nothing && r.ready === nothing
                end
                @test time() - t0 < 2
                st = UI.status_texts(app)
                @test st.render == "CPU map" && occursin("The test hook made the map pass fail.", st.render_help)
                # Auto stays on the CPU now; Graphics Card says once that it cannot be had.
                UI.set_map_drawing!(app, "gpu")
                ctx.frames(4)
                @test r.mode == MAP_CPU
                gpu_text = "The graphics card cannot draw the map here, so it draws on the CPU."
                @test count(t -> t.text == gpu_text, app.toasts) == 1
                UI.set_map_drawing!(app, "auto")
                ctx.frames(1)
                @test !any(t -> t.kind === :error, app.toasts) && isempty(app.draw_errors)
            end
        end
    end
    # One log entry, the fallback's, and no warning.
    @test log_count(logger, Base.CoreLogging.Error) == 1 && log_count(logger, Base.CoreLogging.Warn) == 0

    # A GL error (not an exception) falls back too. Then a CPU picture whose upload fails is
    # noted once, its scene is not drawn again, and the GL state comes back.
    s, m = frame_project()
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    Base.CoreLogging.with_logger(logger) do
        with_project_app(s; timeout = 120, draw_errors_ok = true) do ctx, app
            r = app.map.renderer
            wait_picture(ctx, app, m, MAP_GL; timeout = 20)
            @testset "a GL error falls back to the CPU" begin
                st = app.map.views[m]
                ctx.on_render(w -> begin
                    r.gl_error_next = true
                    st.camera = UI.Camera(st.camera.cx + 3 * st.camera.res, st.camera.cy, st.camera.res)
                end)
                @test seen_after_pass(ctx, () -> r.mode == MAP_CPU && r.gl === nothing && !r.gl_error_next)
                t = last(app.toasts)
                @test t.kind === :warn && t.sub == "The map picture could not be copied: OpenGL error 0x500."
                wait_picture(ctx, app, m, MAP_CPU)
                @test isempty(app.draw_errors)
            end
            @testset "a CPU picture that cannot be uploaded" begin
                st = app.map.views[m]
                n = r.full_draws
                ctx.on_render(w -> begin
                    r.fail_upload = true
                    st.camera = UI.Camera(st.camera.cx + 3 * st.camera.res, st.camera.cy, st.camera.res)
                end)
                ctx.wait_until(() -> !isempty(app.draw_errors))
                key = app.map.scene.key
                @test r.failed_key == key && !r.fail_upload
                ctx.frames(10)
                # One report; no CPU frame started again for that scene; the old picture stays.
                e = only(app.draw_errors)
                @test e.count == 1 && endswith(e.text, "The map picture could not be shown: OpenGL error 0x505.")
                @test count(t -> t.kind === :error, app.toasts) == 1
                @test r.cpu_task === nothing && r.done === nothing && r.ready === nothing && r.full_draws == n
                @test r.image.key != key
                state = Ref{Any}(nothing)
                ctx.on_render(w -> (state[] = (framebuffer_binding(), gl_get(GL.GL_TEXTURE_BINDING_2D),
                                               gl_get(GL.GL_CURRENT_PROGRAM))))
                @test state[] == (0, 0, 0)
                # Another scene draws again.
                ctx.on_render(w -> (st.camera = UI.Camera(st.camera.cx + 3 * st.camera.res, st.camera.cy, st.camera.res)))
                wait_picture(ctx, app, m, MAP_CPU)
                @test r.full_draws == n + 1
            end
        end
    end
    # The fallback's error and the failed upload's, and no warning.
    @test log_count(logger, Base.CoreLogging.Error) == 2 && log_count(logger, Base.CoreLogging.Warn) == 0

    # Shots in the dark theme, GL and CPU.
    s, m = frame_project()
    with_project_app(s; theme = THEME_DARK, timeout = 120) do ctx, app
        wait_picture(ctx, app, m, MAP_GL; timeout = 20)
        gl_shot = ctx.shot(joinpath(FRAME_SHOTS, "map-gl-dark.png"))
        UI.set_map_drawing!(app, "cpu")
        wait_picture(ctx, app, m, MAP_CPU)
        cpu_shot = ctx.shot(joinpath(FRAME_SHOTS, "map-cpu-dark.png"))
        mean, big = shot_diff(gl_shot, cpu_shot, app.map.view)
        @test mean < 1.5 && big == 0
    end
end
