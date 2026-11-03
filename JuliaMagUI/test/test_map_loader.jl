using Test
import JuliaMagCore as Core
using JuliaMagUI: LayerKey, LayerEntry, LineLayerData, GridLayerData, GlMap, submit!, set_session!,
    update_layers!, queue_all_uploads!, spare_free, gpu_uses, gl_layer, free_previous!

# Run `f(s)` on the worker and wait for it and for the next snapshot.
function edit_now!(app, f)
    submit!(app, "edit", f)
    wait_drained(app)
    refresh_now!(app)
    return nothing
end

# Add a Float64 grid item that holds `A` (`A[i, j]` is column `i`, row `j`).
function add_f64_grid!(s, A::Matrix{Float64}; name = "F64")
    p = s.project
    id = Core.new_item_id(p, Core.ITEM_GRID)
    g = Core.create_grid(joinpath(p.folder, "grids", id), name, Float64, size(A)...; dx = 10.0, dy = 10.0,
        x0 = 500_000.0, y0 = 7_000_000.0, crs = "EPSG:32755")
    Core.write_rows!(g, 1, A)
    g.count, g.vmin, g.vmax = length(A), minimum(A), maximum(A)
    Core.save_grid_meta(g)
    Core.add_item!(p, Core.ProjectItem(id, Core.ITEM_GRID, name, "grids/$id", "", ""))
    Core.save_project(p)
    return id
end

# The entry of the layer of item `id`.
entry_of(app, id) = only(e for e in values(app.map.entries) if e.key.item == id)

@testset "map loader" begin
    @testset "snapshot of maps, grid styles and line fids" begin
        with_test_session(fresh_session()) do s
            db = survey_database!(s)
            g = add_test_grid!(s, Float32[1 2; 3 4])
            m = Core.new_map!(s; name = "Survey map")
            Core.add_layer!(s, m, db)
            snap = UI.snapshot(s)
            mv = snap.maps[m]
            @test mv.id == m && mv.name == "Survey map" && mv.crs == "EPSG:32755" && mv.error == ""
            l = only(mv.layers)
            @test l.item == db && l.kind == :lines && l.channel == "MAG"
            @test l !== only(Core.open_map(joinpath(s.project.folder, "maps", m)).layers)
            @test snap.grids[g].style isa Core.GridStyle && snap.grids[g].style.colours == "geosoft"
            row = first(snap.databases[db].lines)
            @test row.fid_start == 0.0 && row.fid_step == 0.1
            @test snap.item_revisions[db] == 0 && snap.item_revisions[m] == 2
        end
    end

    @testset "a line layer loads, reloads after an edit, and reuses two buffers" begin
        s = fresh_session(); db = survey_database!(s); m = Core.new_map!(s); Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            @test app.map.session === s
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            e = only(values(app.map.entries))
            @test e.key == LayerKey(db, :lines, "MAG", "X", "Y", "EPSG:32755")
            @test e.data isa LineLayerData && e.error == "" && e.revision == app.snap.item_revisions[db]
            @test length(e.data.points.x) == 15 && e.data.points.value[1] == 101f0 && e.seconds >= 0
            first_x = e.data.points.x
            edit_now!(app, s -> Core.set_cell!(s, db, Core.LineId(Core.LINE, 1001, 0), "MAG", 1, 9.0))
            wait_layers(app)
            @test e.revision == app.snap.item_revisions[db] && e.data.points.value[1] == 9f0
            @test e.spare isa LineLayerData && e.spare !== e.data
            edit_now!(app, s -> Core.set_cell!(s, db, Core.LineId(Core.LINE, 1001, 0), "MAG", 2, 8.0))
            wait_layers(app)
            @test e.data.points.x === first_x                      # two buffers, swapped
            @test e.data.points.value[2] == 8f0
            @test isempty(app.draw_errors)
        end
    end

    @testset "a missing folder and a deleted channel give errors; other layers load" begin
        s = fresh_session()
        db1 = survey_database!(s); db2 = survey_database!(s); db3 = survey_database!(s)
        Core.rename_item!(s, db3, "North block")
        m = Core.new_map!(s)
        foreach(d -> Core.add_layer!(s, m, d), (db1, db2, db3))
        rm(joinpath(s.project.folder, "databases", db2); recursive = true)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            @test length(app.map.entries) == 3
            gone = entry_of(app, db2)
            @test gone.data === nothing && !isempty(gone.error) && !gone.loading
            @test entry_of(app, db1).data isa LineLayerData && entry_of(app, db1).error == ""
            @test entry_of(app, db3).data isa LineLayerData
            edit_now!(app, s -> Core.delete_channel!(s, db3, "MAG"))
            wait_layers(app)
            e3 = entry_of(app, db3)
            @test e3.error == "Channel MAG is not in North block." && e3.data === nothing
            @test e3.revision == app.snap.item_revisions[db3]
            @test entry_of(app, db1).data isa LineLayerData
            @test isempty(app.draw_errors)
        end
    end

    @testset "grid layers: all NaN, and another coordinate system" begin
        s = fresh_session()
        db = survey_database!(s)
        g1 = add_test_grid!(s, fill(NaN32, 4, 3))
        g2 = add_test_grid!(s, Float32[1 2 3; 4 5 6]; crs = "EPSG:28355", name = "Other")
        m = Core.new_map!(s)
        foreach(d -> Core.add_layer!(s, m, d), (db, g1, g2))
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            e1 = entry_of(app, g1)
            @test e1.key == LayerKey(g1, :grid, "", "", "", "EPSG:32755")
            @test e1.data isa GridLayerData && e1.data.count == 0 && e1.error == ""
            e2 = entry_of(app, g2)
            @test e2.data isa GridLayerData && e2.data.count == 6
            @test e2.error == "This grid is in EPSG:28355, not in the map's EPSG:32755. " *
                              "It is drawn without reprojection."
            @test isempty(app.draw_errors)
        end
    end

    @testset "Float64 grids load through one bounded buffer" begin
        s = fresh_session()
        A = [Float64(i + 10j) for i in 1:3, j in 1:5]
        B = [Float64(-i - 10j) for i in 1:5, j in 1:7]
        g1 = add_f64_grid!(s, A; name = "Narrow"); g2 = add_f64_grid!(s, B; name = "Wide")
        m = Core.new_map!(s)
        foreach(d -> Core.add_layer!(s, m, d), (g1, g2))
        with_app(test_app_state(s)) do app
            cb = app.queue.map_scratch
            cb.limit = 7                       # 2 rows of the narrow grid, 1 of the wide one, per read
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            e1, e2 = entry_of(app, g1), entry_of(app, g2)
            @test e1.error == "" && e1.data.count == 15 && UI.level_matrix(e1.data, 0) == Float32.(A)
            @test e2.error == "" && e2.data.count == 35 && UI.level_matrix(e2.data, 0) == Float32.(B)
            @test e1.data.hist.lo == 11 && e2.data.hist.hi == -11
            @test app.queue.map_scratch === cb && size(cb.block) in ((3, 2), (5, 1))   # one buffer, of the last width
            @test isempty(app.draw_errors)
        end
    end

    @testset "a line layer in another coordinate system is reprojected" begin
        s = fresh_session()
        db1 = survey_database!(s)
        db2 = survey_database!(s; x0 = 147.0, y0 = -19.0, dx = 0.001, dy = 0.001, crs = "EPSG:4326")
        m = Core.new_map!(s)
        foreach(d -> Core.add_layer!(s, m, d), (db1, db2))
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            e = entry_of(app, db2)
            @test e.error == "" && e.key.crs == "EPSG:32755"
            x0, y0, x1, y1 = e.data.extent
            @test 499_000 < x0 < 501_000 && 7_899_000 < y0 < 7_902_000   # 147 E is the zone's middle
            @test isempty(app.draw_errors)
        end
    end

    @testset "hidden layers do not load; unused entries are dropped and freed" begin
        s = fresh_session(); db = survey_database!(s); g = add_test_grid!(s, Float32[1 2; 3 4])
        m = Core.new_map!(s)
        ldb = Core.add_layer!(s, m, db); lg = Core.add_layer!(s, m, g)
        Core.set_layer!(s, m, lg; visible = false)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            @test only(values(app.map.entries)).key.item == db
            gl = GlMap()                       # no GL calls: nothing is uploaded here
            app.map.renderer.gl = gl
            queue_all_uploads!(app.map)
            key = only(keys(app.map.entries))
            @test gl_layer(gl, key) !== nothing
            edit_now!(app, s -> Core.remove_layer!(s, m, ldb))
            update_layers!(app)
            @test isempty(app.map.entries) && gl_layer(gl, key) === nothing
        end
    end

    @testset "a spare the GPU still draws from is not built into" begin
        s = fresh_session(); db = survey_database!(s); m = Core.new_map!(s); Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            gl = GlMap()                       # no GL calls: uploads are only queued
            app.map.renderer.gl = gl
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            e = only(values(app.map.entries))
            a = e.data
            up!(g) = (g.remaining = 0; filter!(u -> u.layer !== g, gl.pending); free_previous!(gl, g))
            up!(gl_layer(gl, e.key))           # as if every upload were done
            cell!(v) = edit_now!(app, s -> Core.set_cell!(s, db, Core.LineId(Core.LINE, 1001, 0), "MAG", 1, v))
            cell!(9.0)
            wait_layers(app)
            @test e.spare === a && gpu_uses(gl, a) && !spare_free(app.map, e)
            cell!(8.0)
            for _ in 1:5
                update_layers!(app)
            end
            @test !e.loading && e.revision < app.snap.item_revisions[db] && e.data.points.value[1] == 9f0
            up!(gl_layer(gl, e.key))           # the new build is up: the old one is freed
            @test spare_free(app.map, e)
            wait_layers(app)
            @test e.revision == app.snap.item_revisions[db] && e.data === a && e.data.points.value[1] == 8f0
        end
    end

    @testset "a load of the old session is dropped after set_session!" begin
        s1 = fresh_session(); db1 = survey_database!(s1); m1 = Core.new_map!(s1); Core.add_layer!(s1, m1, db1)
        s2 = fresh_session(); db2 = survey_database!(s2; lines = 2000, rows = 50)
        m2 = Core.new_map!(s2); Core.add_layer!(s2, m2, db2)
        app = test_app_state(s1)
        hold = nothing
        try
            refresh_now!(app); app.ui.current_map = m1
            wait_layers(app)
            old_key = only(keys(app.map.entries))
            hold = app.map.hold = Channel{Nothing}(Inf)
            edit_now!(app, s -> Core.set_cell!(s, db1, Core.LineId(Core.LINE, 1001, 0), "MAG", 1, 9.0))
            update_layers!(app)                # the old session's load waits for the hold
            @test only(values(app.map.entries)).loading
            set_session!(app, s2)
            @test isempty(app.map.entries) && app.map.session === s2
            refresh_now!(app); app.ui.current_map = m2
            update_layers!(app)                # the new load queues behind the held one
            new_key = only(keys(app.map.entries))
            put!(hold, nothing)                # the old load runs and comes back
            deadline = time() + 20
            while app.map.dropped == 0 && time() < deadline
                UI.drain!(app)
                timedwait(() -> isready(app.queue.results), 1.0; pollint = 0.002)
            end
            @test app.map.dropped == 1
            @test only(values(app.map.entries)).data === nothing && collect(keys(app.map.entries)) == [new_key]
            put!(hold, nothing)                # now the new load
            app.map.hold = nothing
            wait_layers(app)
            e = only(values(app.map.entries))
            @test length(e.data.points.x) == 2000 * 50 && e.error == "" && e.key == new_key
            @test isempty(app.draw_errors)
            @test old_key == new_key           # both databases are db-1 with X, Y: only the session tells them apart
        finally
            hold === nothing || close(hold)   # a held load ends, so the stop cannot hang
            stop_app!(app)
            isopen(s1) && Core.close_session!(s1)
        end
    end
end
