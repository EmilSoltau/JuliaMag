using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Camera, MapViewState, MapInput, step_view!, map_hover, map_status, clear_hover!, pick_cursor!,
    pointer_text, PICK_RADIUS, submit!

# Give map `m` a view with camera `cam`, as the map view would after a frame.
function readout_view!(app, m, cam; size = (800, 600))
    st = get!(MapViewState, app.map.views, m)
    st.camera = cam
    st.size = size
    return st
end

# The bytes `map_hover` allocates for points `a` and `b` in turn, after a warm-up of each:
# the mouse moving.
function hover_alloc(app, a, b)
    map_hover(app, a...); map_hover(app, b...)
    return @allocated begin
        map_hover(app, a...)
        map_hover(app, b...)
    end
end

# The bytes `map_status` allocates when nothing changed since the last call.
status_alloc(app) = (map_status(app); @allocated map_status(app))

# A map of `survey_database!(s; lines = 3)` over a 10 by 10 grid of 12.345 named "TMI" in nT.
function readout_project()
    s = fresh_session()
    db = survey_database!(s; lines = 3)
    g = add_test_grid!(s, fill(12.345f0, 10, 10); name = "TMI", units = "nT")
    m = Core.new_map!(s)
    lg = Core.add_layer!(s, m, g)
    ld = Core.add_layer!(s, m, db)
    return s, (; db, g, m, lg, ld)
end

@testset "map readout" begin
    @testset "the brief" begin
        s, ids = readout_project()
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = ids.m
            wait_layers(app)
            readout_view!(app, ids.m, Camera(500_020.0, 7_000_050.0, 1.0))
            h = map_hover(app, 500_010.0, 7_000_050.0)
            @test h.grids == [("TMI", 12.345f0, "nT")] && h.near.line == 2 && h.near.row == 2
            @test h.near_item == ids.db && h.near_channel == "MAG"
            @test app.ui.hover === h
            @test map_status(app)[2] == "X 500,010.0  Y 7,000,050.0"
            @test map_status(app)[3] == "TMI 12.35 nT  L1002 fid 0.1 MAG 202.00"
        end
    end

    @testset "the parts of the status" begin
        s, ids = readout_project()
        g2 = add_test_grid!(s, fill(-3.0f0, 10, 10); name = "Second", units = "")
        lg2 = Core.add_layer!(s, ids.m, g2)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = ids.m
            wait_layers(app)
            mv = app.snap.maps[ids.m]
            @test map_status(app)[1] == app.snap.crs[mv.crs].name && !isempty(map_status(app)[1])
            # Off the map: no pointer and no readout.
            @test map_status(app)[2:3] == ("X -  Y -", "")
            readout_view!(app, ids.m, Camera(500_020.0, 7_000_050.0, 1.0))
            # The top grid first; a grid without units has none; no line point 25 m away.
            map_hover(app, 500_010.0, 7_000_025.0)
            @test map_status(app)[3] == "Second -3.00  TMI 12.35 nT"
            # The half cell at the edge of a bilinear grid reads nothing; Nearest reads the cell.
            map_hover(app, 499_998.0, 7_000_025.0)
            @test map_status(app)[3] == "Second -  TMI -"
            submit!(app, "nearest", s -> Core.set_layer!(s, ids.m, ids.lg; style = Core.LayerStyle(resample = :nearest)))
            wait_drained(app); refresh_now!(app)
            map_hover(app, 499_998.0, 7_000_025.0)
            @test map_status(app)[3] == "Second -  TMI 12.35 nT"
            # A hidden grid is left out.
            submit!(app, "hide", s -> Core.set_layer!(s, ids.m, lg2; visible = false))
            wait_drained(app); refresh_now!(app)
            map_hover(app, 500_010.0, 7_000_025.0)
            @test map_status(app)[3] == "TMI 12.35 nT"
            # The point radius is 20 px: 20 m at 1 m per pixel, 40 m at 2.
            map_hover(app, 500_010.0, 7_000_071.0)
            @test map_status(app)[3] == "TMI 12.35 nT"
            readout_view!(app, ids.m, Camera(500_020.0, 7_000_050.0, 2.0))
            map_hover(app, 500_010.0, 7_000_071.0)
            @test map_status(app)[3] == "TMI 12.35 nT  L1002 fid 0.1 MAG 202.00"
            @test map_status(app)[2] == "X 500,010.0  Y 7,000,071.0"
            # Off the map again.
            clear_hover!(app)
            @test app.ui.hover === nothing && map_status(app)[2:3] == ("X -  Y -", "")
        end
    end

    @testset "the pointer text" begin
        @test pointer_text(500_123.44, 7_000_056.06, "m") == "X 500,123.4  Y 7,000,056.1"
        @test pointer_text(150.1234567, -20.5, "deg") == "X 150.123457  Y -20.500000"
        @test pointer_text(1.0, 2.0, "") == "X 1.0  Y 2.0"
    end

    @testset "a map in degrees, and a map with no coordinate system" begin
        s = fresh_session()
        db = survey_database!(s; lines = 2, x0 = 150.0, y0 = -20.0, dx = 0.001, dy = 0.01, crs = "EPSG:4326")
        m = Core.new_map!(s)
        Core.add_layer!(s, m, db)
        plain = survey_database!(s; lines = 2, crs = "")
        m2 = Core.new_map!(s)
        Core.add_layer!(s, m2, plain)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            readout_view!(app, m, Camera(150.002, -19.995, 1e-5))
            map_hover(app, 150.001, -19.99)
            @test map_status(app)[2] == "X 150.001000  Y -19.990000"
            @test map_status(app)[3] == "L1002 fid 0.1 MAG 202.00"
            app.ui.current_map = m2
            wait_layers(app)
            clear_hover!(app)
            @test map_status(app)[1] == "No coordinate system"
        end
    end

    @testset "a line layer's channel decimals" begin
        s, ids = readout_project()
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = ids.m
            wait_layers(app)
            submit!(app, "decimals", s -> Core.set_channel_info!(s, ids.db, "MAG"; decimals = 1))
            wait_drained(app); refresh_now!(app); wait_layers(app)
            readout_view!(app, ids.m, Camera(500_020.0, 7_000_050.0, 1.0))
            map_hover(app, 500_030.0, 7_000_100.0)
            @test map_status(app)[3] == "TMI -  L1003 fid 0.3 MAG 304.0"   # past the grid's last half cell
        end
    end

    @testset "steady frames allocate nothing" begin
        s, ids = readout_project()
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = ids.m
            wait_layers(app)
            readout_view!(app, ids.m, Camera(500_020.0, 7_000_050.0, 1.0))
            # The mouse moving over grid cells and line points.
            @test hover_alloc(app, (500_010.0, 7_000_050.0), (500_031.0, 7_000_041.0)) == 0
            # The texts are made again only when the hover changes.
            map_hover(app, 500_010.0, 7_000_050.0)
            a = map_status(app)
            @test status_alloc(app) == 0 && map_status(app) === a
            map_hover(app, 500_010.0, 7_000_050.0)
            @test map_status(app) === a
            map_hover(app, 500_011.0, 7_000_050.0)
            @test map_status(app) !== a && map_status(app)[2] == "X 500,011.0  Y 7,000,050.0"
            clear_hover!(app)
            @test status_alloc(app) == 0
        end
    end

    @testset "a pick moves the shared cursor" begin
        s, ids = readout_project()
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = ids.m
            wait_layers(app)
            mv = app.snap.maps[ids.m]
            readout_view!(app, ids.m, Camera(500_020.0, 7_000_050.0, 1.0))
            undo = app.snap.undo_label
            @test pick_cursor!(app, mv, 500_021.0, 7_000_053.0)
            wait_drained(app); refresh_now!(app)
            c = app.snap.cursor
            @test c.item == ids.db && c.line == Core.LineId(Core.LINE, 1002, 0) && c.row == 3
            @test app.snap.undo_label == undo   # the cursor is view state of the session: no undo step
            # Nothing within 20 px: the cursor stays, and nothing goes to the worker.
            @test !pick_cursor!(app, mv, 500_021.0, 7_000_075.0)
            @test app.queue.pending == 0
            wait_drained(app); refresh_now!(app)
            @test app.snap.cursor == c
            # The marker goes where the cursor is.
            @test UI.cursor_target(app, mv) == (500_020.0, 7_000_050.0)
        end
    end

    @testset "a click is a pick; a pan or a box zoom is not" begin
        cam = Camera(0.0, 0.0, 1.0)
        at(pos, t; left = true, shift = false) = MapInput(Float32.(pos), true, left, false, shift, 0f0, (800, 600), Float64(t))
        # A click that moves under 3 px.
        st = MapViewState(cam)
        step_view!(st, at((100, 100), 0.0))
        @test step_view!(st, at((102, 101), 0.02; left = false))[1] == :pick
        # A pan that comes back to where it started.
        st = MapViewState(cam)
        step_view!(st, at((100, 100), 0.0))
        step_view!(st, at((140, 100), 0.02))
        step_view!(st, at((100, 100), 0.04))
        @test step_view!(st, at((100, 100), 0.06; left = false)) === nothing
        # A box zoom.
        st = MapViewState(cam)
        step_view!(st, at((100, 100), 0.0; shift = true))
        step_view!(st, at((200, 180), 0.02; shift = true))
        @test step_view!(st, at((200, 180), 0.04; left = false, shift = true)) === nothing
        # A middle click.
        st = MapViewState(cam)
        step_view!(st, MapInput((100f0, 100f0), true, false, true, false, 0f0, (800, 600), 0.0))
        @test step_view!(st, MapInput((100f0, 100f0), true, false, false, false, 0f0, (800, 600), 0.02)) === nothing
    end

    @testset "Go To Cursor follows a map switch at once" begin
        s, ids = readout_project()
        m2 = Core.new_map!(s)
        Core.add_layer!(s, m2, ids.g)
        Core.set_cursor!(s, Core.Cursor(ids.db, Core.LineId(Core.LINE, 1002, 0), 3))
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m2
            wait_layers(app)
            go = only(c for c in UI.commands(app) if c.id == "map.go_cursor")
            @test go.enabled(app) == "The current point is not on this map."
            # The map view has not drawn the other map yet.
            app.ui.current_map = ids.m
            wait_layers(app)
            @test go.enabled(app) === nothing
        end
    end
end
