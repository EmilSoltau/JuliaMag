using Test
import JuliaMagCore as Core
using JuliaMagUI: Camera, MapViewState, MapInput, step_view!, screen_to_world, world_to_screen, fit_extent,
    full_extent!, zoom_layer!, previous!, next!, zoom_by!, wheel_factor, build_scene!, Scene, LineDraw,
    GridDraw, scene_key, grid_extent, submit!, SETTLE

# An input with the mouse away from the map and no buttons or wheel, at time `t`.
idle_input(t; size = (800, 600)) = MapInput((0f0, 0f0), false, false, false, false, 0f0, size, Float64(t))

# The input of `press` with its buttons up, the mouse at `pos`, a frame later.
release_at(press::MapInput, pos) =
    MapInput(pos, true, false, false, press.shift, 0f0, press.size, press.now + 0.016)

# A left drag frame: the mouse at `pos`, the window `size`, at time `t`.
drag_input(pos, size, t) = MapInput(Float32.(pos), true, true, false, false, 0f0, size, Float64(t))

# The bytes `build_scene!` allocates, measured inside a function after a warm-up call.
function scene_alloc(sc, app, mv, st)
    build_scene!(sc, app, mv, st, 800, 600)
    return @allocated build_scene!(sc, app, mv, st, 800, 600)
end

@testset "map view" begin
    @testset "gestures" begin
        # MapViewState(cam) starts with no gesture
        st = MapViewState(Camera(500_000.0, 7_000_000.0, 10.0))
        @test st.gesture == :none && st.before === nothing && isempty(st.history.past)
        w0 = screen_to_world(st.camera, 800, 600, 100.0, 100.0)
        step_view!(st, MapInput((100f0, 100f0), true, false, false, false, 1f0, (800, 600), 0.0))
        @test all(isapprox.(screen_to_world(st.camera, 800, 600, 100.0, 100.0), w0; atol = 1e-6))
        @test st.camera.res < 10.0 && st.gesture == :wheel
        step_view!(st, idle_input(0.1)); @test isempty(st.history.past)            # not settled yet
        step_view!(st, idle_input(0.2)); @test length(st.history.past) == 1          # one entry per finished gesture
        @test st.history.past[1] == Camera(500_000.0, 7_000_000.0, 10.0) && st.gesture == :none
        step_view!(st, idle_input(0.5)); @test length(st.history.past) == 1          # once only
        press = MapInput((400f0, 300f0), true, true, false, false, 0f0, (800, 600), 1.0)
        cam = st.camera
        step_view!(st, press); r = step_view!(st, release_at(press, (401f0, 301f0)))
        @test r[1] == :pick && length(st.history.past) == 1
        @test all(isapprox.(r[2], screen_to_world(cam, 800, 600, 401.0, 301.0); atol = 1e-6))
        @test st.camera == cam                                                       # a click does not pan
        step_view!(st, idle_input(2.0)); @test length(st.history.past) == 1

        st2 = MapViewState(Camera(0.0, 0.0, 1.0))
        step_view!(st2, MapInput((100f0, 100f0), true, true, false, true, 0f0, (800, 600), 0.0))
        @test st2.gesture == :box
        step_view!(st2, MapInput((300f0, 250f0), true, true, false, true, 0f0, (800, 600), 0.1))
        @test st2.box == (100f0, 100f0, 300f0, 250f0) && st2.camera == Camera(0.0, 0.0, 1.0)
        step_view!(st2, MapInput((300f0, 250f0), true, false, false, true, 0f0, (800, 600), 0.2))
        @test st2.camera.res == 0.25 && (st2.camera.cx, st2.camera.cy) == (-200.0, 125.0)
        @test st2.box === nothing
        step_view!(st2, idle_input(0.4)); @test st2.history.past == [Camera(0.0, 0.0, 1.0)]

        # A box under 4 px is a pick, and the camera stays.
        st3 = MapViewState(Camera(0.0, 0.0, 1.0))
        step_view!(st3, MapInput((100f0, 100f0), true, true, false, true, 0f0, (800, 600), 0.0))
        step_view!(st3, MapInput((103f0, 102f0), true, true, false, true, 0f0, (800, 600), 0.05))
        r3 = step_view!(st3, MapInput((103f0, 102f0), true, false, false, true, 0f0, (800, 600), 0.1))
        @test r3 == (:pick, screen_to_world(Camera(0.0, 0.0, 1.0), 800, 600, 103.0, 102.0))
        @test st3.camera == Camera(0.0, 0.0, 1.0)

        # A middle drag pans and is never a pick; the grabbed point follows the mouse.
        st4 = MapViewState(Camera(0.0, 0.0, 2.0))
        grab = screen_to_world(st4.camera, 800, 600, 200.0, 200.0)
        step_view!(st4, MapInput((200f0, 200f0), true, false, true, false, 0f0, (800, 600), 0.0))
        step_view!(st4, MapInput((260f0, 170f0), true, false, true, false, 0f0, (800, 600), 0.05))
        @test st4.gesture == :pan
        @test all(isapprox.(screen_to_world(st4.camera, 800, 600, 260.0, 170.0), grab; atol = 1e-6))
        @test step_view!(st4, MapInput((260f0, 170f0), true, false, false, false, 0f0, (800, 600), 0.1)) === nothing
        @test st4.camera == Camera(-120.0, -60.0, 2.0)
        # A press away from the map starts nothing.
        st5 = MapViewState(Camera(0.0, 0.0, 1.0))
        step_view!(st5, MapInput((10f0, 10f0), false, true, false, false, 0f0, (800, 600), 0.0))
        @test st5.gesture == :none && st5.before === nothing
        # A wheel turned away from the map does not zoom.
        step_view!(st5, MapInput((10f0, 10f0), false, false, false, false, 2f0, (800, 600), 0.1))
        @test st5.camera == Camera(0.0, 0.0, 1.0)
    end

    @testset "a mouse that left the window does not move the view" begin
        far = (-floatmax(Float32), -floatmax(Float32))   # what ImGui's GLFW backend sets
        st = MapViewState(Camera(500_000.0, 7_000_000.0, 2.0))
        step_view!(st, drag_input((400, 300), (800, 600), 0.0))
        step_view!(st, drag_input((430, 320), (800, 600), 0.016))
        c = st.camera
        step_view!(st, MapInput(far, false, true, false, false, 0f0, (800, 600), 0.032))
        @test st.camera == c && all(isfinite, (st.camera.cx, st.camera.cy))
        @test step_view!(st, MapInput(far, false, false, false, false, 0f0, (800, 600), 0.048)) === nothing
        @test st.camera == c
        # A box zoom fits the box to the last good position.
        st2 = MapViewState(Camera(0.0, 0.0, 1.0))
        step_view!(st2, MapInput((100f0, 100f0), true, true, false, true, 0f0, (800, 600), 0.0))
        step_view!(st2, MapInput((300f0, 250f0), true, true, false, true, 0f0, (800, 600), 0.1))
        step_view!(st2, MapInput(far, false, true, false, true, 0f0, (800, 600), 0.15))
        @test st2.box == (100f0, 100f0, 300f0, 250f0)
        step_view!(st2, MapInput(far, false, false, false, true, 0f0, (800, 600), 0.2))
        @test st2.camera.res == 0.25 && (st2.camera.cx, st2.camera.cy) == (-200.0, 125.0)
    end

    @testset "full extent fits the box inside the coordinate bands" begin
        ext = (500_000.0, 7_000_000.0, 502_000.0, 7_001_950.0)
        w, h, inset = 1070, 600, 30
        st = MapViewState(nothing)
        full_extent!(st, ext, w, h; inset)
        for x in (ext[1], ext[3]), y in (ext[2], ext[4])
            sx, sy = world_to_screen(st.camera, w, h, x, y)
            @test inset <= sx <= w && inset <= sy <= h
        end
        cx, cy = world_to_screen(st.camera, w, h, (ext[1] + ext[3]) / 2, (ext[2] + ext[4]) / 2)
        @test cx ≈ inset + (w - inset) / 2 && cy ≈ inset + (h - inset) / 2
        zoom_layer!(st, ext, w, h; inset)
        @test st.camera == UI.fit_inner(ext, w, h, inset)
    end

    @testset "the full extent keeps clear of the scale bar and the legend cards" begin
        w, h, inset = 1000, 600, 20
        right = (248.0, 150.0)                 # the legend cards, from the right edge
        bar = (160.0, 100.0)                   # the scale bar, from the band
        legends = ((0.0, 0.0), right)
        both = (bar, right)
        inside(c, e, box) = all(box[1] - 1e-6 <= world_to_screen(c, w, h, x, y)[1] <= box[3] + 1e-6 &&
                                box[2] - 1e-6 <= world_to_screen(c, w, h, x, y)[2] <= box[4] + 1e-6
                                for x in (e[1], e[3]), y in (e[2], e[4]))
        # A wide extent would reach under the cards: it fits above them, where it shows larger
        # (1120 / 430 world units per pixel) than left of them (2240 / 732).
        wide = (0.0, 0.0, 2000.0, 1000.0)
        c = UI.fit_clear(wide, w, h, inset, legends)
        @test c.res ≈ 1120 / 430
        @test inside(c, wide, (inset, inset, w, h - right[2]))
        # A tall one fits left of them.
        tall = (0.0, 0.0, 1300.0, 900.0)
        c = UI.fit_clear(tall, w, h, inset, legends)
        @test c.res ≈ 1300 * 1.12 / (w - right[1] - inset)
        @test inside(c, tall, (inset, inset, w - right[1], h))
        # With the scale bar too, left of the cards would meet the bar, and right of the bar
        # the cards: it fits between the two (1456 / 572), larger than above both (1120 / 430).
        deep = (0.0, 0.0, 1300.0, 1000.0)
        @test UI.fit_clear(deep, w, h, inset, legends).res ≈ 1456 / 732
        c = UI.fit_clear(deep, w, h, inset, both)
        @test c.res ≈ 1456 / 572
        @test inside(c, deep, (inset + bar[1], inset, w - right[1], h))
        # One that leaves room beside the boxes, or no boxes: the plain fit.
        narrow = (0.0, 0.0, 300.0, 1000.0)
        @test UI.fit_clear(narrow, w, h, inset, both) == UI.fit_inner(narrow, w, h, inset)
        @test UI.fit_clear(wide, w, h, inset, UI.NO_CORNERS) == UI.fit_inner(wide, w, h, inset)
        # Full Extent and Zoom to Layer take the boxes; only Full Extent is followed.
        st = MapViewState(nothing)
        full_extent!(st, wide, w, h; inset, corners = both)
        @test st.camera == UI.fit_clear(wide, w, h, inset, both) && st.fitted == st.camera
        zoom_layer!(st, tall, w, h; inset, corners = both)
        @test st.camera == UI.fit_clear(tall, w, h, inset, both) && st.fitted != st.camera
    end

    @testset "Review Focus 4: a pan while the window resizes" begin
        st = MapViewState(Camera(500_000.0, 7_000_000.0, 3.0))
        step_view!(st, idle_input(0.0))
        sizes = [k < 5 ? (800, 600) : (600, 600) for k in 0:10]
        grab = screen_to_world(st.camera, 800, 600, 400.0, 300.0)
        step_view!(st, drag_input((400, 300), sizes[1], 1.0))
        for k in 1:10
            pos = (400 + 10k, 300 + 10k)
            w, h = sizes[k+1]
            step_view!(st, drag_input(pos, (w, h), 1.0 + 0.016k))
            sx, sy = world_to_screen(st.camera, w, h, grab...)
            @test abs(sx - pos[1]) < 1 && abs(sy - pos[2]) < 1
        end
        t = 1.0 + 0.016 * 11
        step_view!(st, MapInput((500f0, 400f0), true, false, false, false, 0f0, (600, 600), t))
        @test isempty(st.history.past)
        step_view!(st, idle_input(t + SETTLE / 2; size = (600, 600))); @test isempty(st.history.past)
        step_view!(st, idle_input(t + SETTLE + 0.01; size = (600, 600)))
        @test st.history.past == [Camera(500_000.0, 7_000_000.0, 3.0)]
        step_view!(st, idle_input(t + 1; size = (600, 600))); @test length(st.history.past) == 1
        # A size change with no gesture keeps the centre.
        c = st.camera
        step_view!(st, idle_input(t + 2; size = (300, 200)))
        @test st.camera == c && st.size == (300, 200)
    end

    @testset "extent commands record one extent each" begin
        st = MapViewState(nothing)
        ext = (500_000.0, 7_000_000.0, 501_000.0, 7_000_500.0)
        full_extent!(st, ext, 800, 600)
        @test st.camera == fit_extent(ext, 800, 600) && isempty(st.history.past)   # the first camera
        a = st.camera
        zoom_by!(st, 2.0)
        @test st.camera == Camera(a.cx, a.cy, a.res / 2) && st.history.past == [a]
        b = st.camera
        zoom_layer!(st, (500_000.0, 7_000_000.0, 500_100.0, 7_000_100.0), 800, 600)
        @test st.camera == fit_extent((500_000.0, 7_000_000.0, 500_100.0, 7_000_100.0), 800, 600)
        @test st.history.past == [a, b]
        c = st.camera
        full_extent!(st, ext, 800, 600)
        @test st.history.past == [a, b, c]
        previous!(st); @test st.camera == c
        previous!(st); @test st.camera == b
        next!(st); @test st.camera == c
        next!(st); @test st.camera == a
        next!(st); @test st.camera == a                                              # none left
        # A command while a wheel gesture is open ends the gesture first: the camera before the
        # wheel and the camera the command started from go into the history, in that order.
        before_wheel = st.camera
        step_view!(st, MapInput((10f0, 10f0), true, false, false, false, 1f0, (800, 600), 5.0))
        wheeled = st.camera
        n = length(st.history.past)
        zoom_by!(st, 0.5)
        @test st.history.past[n+1:end] == [before_wheel, wheeled] && st.gesture == :none && st.before === nothing
    end

    @testset "build_scene!" begin
        s = fresh_session()
        db = survey_database!(s; lines = 4)
        A = Float32[i + 10j for i in 1:30, j in 1:20]
        g = add_test_grid!(s, A; name = "TMI")
        nan_grid = add_test_grid!(s, fill(NaN32, 8, 6); name = "Dummy", x0 = 499_000.0)
        m = Core.new_map!(s)
        lg = Core.add_layer!(s, m, g)
        ld = Core.add_layer!(s, m, db)
        ln = Core.add_layer!(s, m, nan_grid)
        Core.set_layer!(s, m, lg; own_style = true, style = Core.LayerStyle(shade = true))
        Core.set_layer!(s, m, ld; opacity = 0.5)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            mv = app.snap.maps[m]
            @test [l.id for l in mv.layers] == [lg, ln, ld]
            st = MapViewState(nothing)
            full_extent!(st, (500_000.0, 7_000_000.0, 500_300.0, 7_000_200.0), 800, 600)
            sc = Scene(st.camera, 1, 1, (0x00, 0x00, 0x00, 0xff), LineDraw[], 0)
            @test build_scene!(sc, app, mv, st, 800, 600) === sc
            @test sc.width == 800 && sc.height == 600 && sc.camera == st.camera
            @test [typeof(l) for l in sc.layers] == [GridDraw, GridDraw, LineDraw]   # draw order
            gd, nd, ldr = sc.layers
            @test gd.data isa UI.GridLayerData && gd.level == UI.grid_level(gd.data, st.camera.res)
            @test gd.lo == 11f0 && gd.hi == 230f0 && gd.table isa Vector{Float32} && length(gd.table) == 1024
            @test gd.shade && gd.zfactor == Float32(Core.auto_zfactor(gd.data.mean_gradient))
            @test gd.sun == Float32.(Core.sun_vector(45, 45)) && !gd.nearest && gd.opacity == 1f0
            @test gd.lut == UI.lut_rgba!(UInt8[], "geosoft", false)
            @test nd.data.count == 0 && isnan(nd.lo) && isnan(nd.hi)                   # draws nothing
            @test ldr.level == UI.choose_level(ldr.data, st.camera, 800, 600) && ldr.opacity == 0.5f0
            @test ldr.plain == UI.rgba_bytes(app.tokens.text)
            @test sc.background == UI.rgba_bytes(app.tokens.canvas)
            @test sc.key == scene_key(sc)
            key = sc.key
            # Equal inputs, equal draws: the same objects again, and no allocation after warm-up.
            build_scene!(sc, app, mv, st, 800, 600)
            @test sc.layers[1] === gd && sc.layers[3] === ldr && sc.key == key
            @test scene_alloc(sc, app, mv, st) == 0
            # A live opacity for one layer.
            app.ui.opacity_preview = (ld, 0.25)
            build_scene!(sc, app, mv, st, 800, 600)
            @test sc.layers[3].opacity == 0.25f0 && sc.key != key
            @test scene_alloc(sc, app, mv, st) == 0
            app.ui.opacity_preview = nothing
            # A hidden layer is left out; the style follows the snapshot.
            submit!(app, "hide", s -> Core.set_layer!(s, m, ln; visible = false)); wait_drained(app); refresh_now!(app)
            submit!(app, "style", s -> Core.set_layer!(s, m, ld; style = Core.LayerStyle(colours = "turbo", reverse = true)))
            wait_drained(app); refresh_now!(app); wait_layers(app)
            mv = app.snap.maps[m]
            build_scene!(sc, app, mv, st, 800, 600)
            @test length(sc.layers) == 2 && sc.layers[2].lut == UI.lut_rgba!(UInt8[], "turbo", true)
            @test scene_alloc(sc, app, mv, st) == 0
            # A layer whose data is not loaded yet is left out.
            e = only(e for e in values(app.map.entries) if e.key.item == db)
            d = e.data; e.data = nothing
            build_scene!(sc, app, mv, st, 800, 600)
            @test length(sc.layers) == 1
            e.data = d
        end
    end
end
