using Test
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Camera, screen_to_world, fit_extent, grid_extent, THEME_LIGHT, THEME_DARK, LIGHT, DARK

const MAP_SHOTS = joinpath(@__DIR__, "..", "shots")

# A project with 40 lines and a grid under them on one map, the line labels on. Returns the
# session and the ids of the map, the database, the grid, an all-NaN grid on a map of its own,
# and an empty map.
function map_project()
    s = fresh_session()
    db = survey_database!(s; lines = 40, rows = 200)
    A = Float32[100sin(i / 17) * cos(j / 23) + 0.5i for i in 1:200, j in 1:196]
    g = add_test_grid!(s, A; name = "TMI")
    m = Core.new_map!(s; name = "Survey")
    Core.add_layer!(s, m, g)
    ld = Core.add_layer!(s, m, db)
    Core.set_layer!(s, m, ld; labels = true)
    dummy = add_test_grid!(s, fill(NaN32, 30, 20); name = "Dummy", x0 = 510_000.0)
    m2 = Core.new_map!(s; name = "Dummy map")
    Core.add_layer!(s, m2, dummy)
    m3 = Core.new_map!(s; name = "Empty")
    return s, (; m, db, g, dummy, m2, m3)
end

# Show map `m` and wait until its layers are loaded, uploaded and drawn.
function show_map!(ctx, app, m; timeout = 5)
    ctx.on_render(w -> (app.ui.current_map = m))
    ms = app.map
    ctx.wait_until(; timeout) do
        gl = ms.gl
        # The plan and the drawn picture of this map, not of the map shown before.
        gl !== nothing && isempty(gl.pending) && ms.plan_map == m && ms.drawn == ms.scene.key && !isempty(ms.plan) &&
            all(p -> p.entry !== nothing && p.entry.data !== nothing && !p.entry.loading, ms.plan)
    end
    ctx.frames(2)
    return nothing
end

view_state(app) = app.map.views[app.ui.current_map]
view_size(app) = (round(Int, UI.width(app.map.view)), round(Int, UI.height(app.map.view)))
view_point(app, x, y) = (app.map.view.x0 + x, app.map.view.y0 + y)   # device px of a view point

# Equal cameras, up to a thousandth of a pixel.
near_camera(a::Camera, b::Camera) =
    isapprox(a.res, b.res; rtol = 1e-9) && abs(a.cx - b.cx) <= 1e-3 * a.res && abs(a.cy - b.cy) <= 1e-3 * a.res

window_testset("map view") do
    s, ids = map_project()
    with_project_app(s; timeout = 300) do ctx, app
        @testset "the hint while a layer loads" begin
            hold = Channel{Nothing}(8)
            app.map.hold = hold
            ctx.on_render(w -> (app.ui.current_map = ids.m2))
            ctx.wait_until(() -> any(e -> e.loading, values(app.map.entries)))
            ctx.frames(1)
            @test UI.map_hint(app, app.snap.maps[ids.m2]) == "Loading Dummy..."
            ctx.shot(joinpath(MAP_SHOTS, "map-view-loading-light.png"))
            app.map.hold = nothing
            put!(hold, nothing)
            ctx.on_render(w -> (app.ui.current_map = ""))
        end
        t0 = time()
        show_map!(ctx, app, ids.m)
        @test time() - t0 < 5
        st = view_state(app)
        w, h = view_size(app)
        @test st.camera == fit_extent(UI.map_extent(app, app.snap.maps[ids.m]), w, h)
        path = joinpath(MAP_SHOTS, "map-view-light.png")
        ctx.shot(path)
        img = PNGFiles.load(path)
        canvas = rgb255(LIGHT.canvas)
        # The grid shows in the middle of the view.
        cx, cy = round.(Int, view_point(app, w / 2, h / 2))
        @test !near(rgb255(img[cy+1, cx+1]), canvas; tol = 6)

        @testset "a drag pans by the drag times res" begin
            c0 = st.camera
            from = view_point(app, w / 2, h / 2)
            ctx.drag(from, from .+ (120, 80))
            ctx.frames(2)
            @test isapprox(st.camera.cx, c0.cx - 120 * c0.res; atol = 1e-6) &&
                  isapprox(st.camera.cy, c0.cy + 80 * c0.res; atol = 1e-6) && st.camera.res == c0.res
            ctx.wait_until(() -> st.before === nothing)
            @test last(st.history.past) == c0
        end

        @testset "the wheel zooms about the mouse" begin
            p = (Float64(w ÷ 3), Float64(h ÷ 4))   # whole pixels, as the test engine moves the mouse
            before = screen_to_world(st.camera, w, h, p...)
            res = st.camera.res
            ctx.wheel(view_point(app, p...), 2)
            ctx.frames(2)
            @test st.camera.res < res
            @test all(isapprox.(screen_to_world(st.camera, w, h, p...), before; atol = 1e-6 * res))
        end

        @testset "Home fits the full extent" begin
            ctx.key("Home")
            ctx.frames(2)
            @test st.camera == fit_extent(UI.map_extent(app, app.snap.maps[ids.m]), w, h)
        end

        @testset "Shift and a drag zoom to the box" begin
            c = st.camera
            a, b = (200.0, 150.0), (420.0, 300.0)
            p, q = screen_to_world(c, w, h, a...), screen_to_world(c, w, h, b...)
            ctx.drag(view_point(app, a...), view_point(app, b...); mods = "Shift")
            ctx.frames(2)
            want = fit_extent((min(p[1], q[1]), min(p[2], q[2]), max(p[1], q[1]), max(p[2], q[2])), w, h; pad = 0)
            @test near_camera(st.camera, want)
            @test st.box === nothing
            ctx.key("Home")
            ctx.frames(2)
        end

        @testset "the nav buttons" begin
            res = st.camera.res
            ctx.click("JuliaMag/mapnav/zoom_in")
            ctx.frames(1)
            @test st.camera.res ≈ res / 2
            ctx.click("JuliaMag/mapnav/zoom_out")
            ctx.frames(1)
            @test st.camera.res ≈ res
            ctx.click("JuliaMag/mapnav/full_extent")
            @test st.camera == fit_extent(UI.map_extent(app, app.snap.maps[ids.m]), w, h)
        end

        @testset "Review Focus 4: the window resized during a drag" begin
            c0 = st.camera
            v0 = app.map.view
            from = view_point(app, w / 2, h / 2)
            grab = screen_to_world(c0, w, h, w / 2, h / 2)
            ctx.mouse_to(from)
            te.MouseDown(0)
            pos = from
            for k in 1:6
                pos = from .+ (12k, 9k)
                ctx.mouse_to(pos)
                if k == 3
                    ctx.on_render(win -> UI.GLFW.SetWindowSize(win.handle, 1300, 820))
                    ctx.wait_until(() -> app.map.view != v0)
                end
            end
            te.MouseUp(0)
            ctx.frames(2)
            v = app.map.view
            nw, nh = view_size(app)
            @test (nw, nh) != (w, h)
            want = UI.pan_to(c0, grab, pos[1] - v.x0, pos[2] - v.y0, nw, nh)
            @test near_camera(st.camera, want)
            @test isempty(app.draw_errors)
            ctx.wait_until(() -> st.before === nothing)
            @test last(st.history.past) == c0
            ctx.on_render(win -> UI.GLFW.SetWindowSize(win.handle, 1480, 920))
            ctx.wait_until(() -> view_size(app) == (w, h))
        end

        @testset "Review Focus 2: an all-NaN grid" begin
            show_map!(ctx, app, ids.m2)
            st2 = view_state(app)
            p = only(app.map.plan)
            d = p.entry.data
            @test d isa UI.GridLayerData && d.count == 0 && d.hist.total == 0
            legend = UI.legend_of(app, p)
            @test legend !== nothing && legend[3] === d
            ctx.shot(joinpath(MAP_SHOTS, "map-view-dummy-light.png"))
            ctx.on_render(win -> UI.zoom_layer!(st2, UI.layer_extent(p.entry), w, h))
            @test st2.camera == fit_extent(grid_extent(d.geo), w, h)
            @test isempty(app.draw_errors)
        end

        @testset "the empty map" begin
            ctx.on_render(win -> (app.ui.current_map = ids.m3))
            ctx.frames(2)
            path = joinpath(MAP_SHOTS, "map-view-empty-light.png")
            ctx.shot(path)
            img = PNGFiles.load(path)
            v = app.map.view
            mid = round(Int, (v.y0 + v.y1) / 2)
            row = [rgb255(img[y+1, x+1]) for y in mid-20:mid+20 for x in round(Int, v.x0):round(Int, v.x1)-1]
            @test any(c -> near(c, rgb255(LIGHT.text_dim); tol = 30), row)          # the two lines
            @test !haskey(app.map.views, ids.m3)                                    # no camera, no gestures
        end
    end

    # Shots of the map for the pixel review, in both themes at scale 1 and 1.5.
    for (theme, name) in ((THEME_LIGHT, "light"), (THEME_DARK, "dark")),
            scale in (1f0, 1.5f0)
        (name == "light" && scale == 1) && continue
        s, ids = map_project()
        with_project_app(s; theme, scale, timeout = 120) do ctx, app
            show_map!(ctx, app, ids.m; timeout = 20)
            ctx.shot(joinpath(MAP_SHOTS, "map-view-$name" * (scale == 1 ? "" : "-1.5x") * ".png"))
        end
    end
end
