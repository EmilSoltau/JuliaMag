using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: layer_rows, drop_position, LayerRow, commands, open_map!, settle_previews!,
    commit_opacity!, Camera, MapViewState, shown_opacity, layers_cache, view_reason

layer_cmd(app, id) = only(filter(c -> c.id == id, commands(app)))
layer_reason(app, id) = layer_cmd(app, id).enabled(app)

# Where a layer goes when the rows are dropped as `drop_position` says: rows top first.
function dropped(order::Vector{Int}, from::Int, to_row::Int)
    rows = reverse(order)                       # top first
    moved = rows[from]
    pos = drop_position(from, to_row, length(order))
    out = filter(!=(moved), order)              # bottom first, as `move_layer!` counts
    insert!(out, pos, moved)
    return out
end

@testset "layers tab" begin
    @testset "the brief" begin
        s = fresh_session(); db = survey_database!(s); g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10])
        m = Core.new_map!(s); Core.add_layer!(s, m, db); Core.add_layer!(s, m, g)   # the grid goes below the lines
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            snap, entries = app.snap, app.map.entries
            rows = layer_rows(snap, m, entries, "geosoft")      # a map with a grid layer below a line layer
            @test [r.icon for r in rows] == ["lines", "grid"] && rows[1].sub == "MAG" && rows[2].sub == "Grid colours"
            @test rows[2].method == "hist. eq." && rows[1].opacity_text == ""
            @test drop_position(1, 3, 2) == 1 && drop_position(2, 1, 2) == 2
        end
    end

    @testset "rows: names, colours, methods, opacity and state" begin
        s = fresh_session(); db = survey_database!(s); db2 = survey_database!(s)
        Core.rename_item!(s, db, "Kangaroo Hills 2024")
        g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10]; name = "KH2024_MAG_IGRF")
        g2 = add_test_grid!(s, Float32[i * j for i in 1:20, j in 1:10]; name = "Own")
        m = Core.new_map!(s)
        ld = Core.add_layer!(s, m, db); lg = Core.add_layer!(s, m, g); lg2 = Core.add_layer!(s, m, g2)
        ld2 = Core.add_layer!(s, m, db2)
        Core.set_layer!(s, m, lg; opacity = 0.5, visible = false)
        Core.set_layer!(s, m, lg2; own_style = true, style = Core.LayerStyle(colours = "grey", stretch = :clip))
        Core.set_layer!(s, m, ld2; channel = "", opacity = 0.996)
        Core.set_layer!(s, m, ld; style = Core.LayerStyle(stretch = :linear))
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            rows = layer_rows(app.snap, m, app.map.entries, "rainbow")
            # Top first: the lines added last, then the first lines, then the grids, top grid first.
            @test [r.id for r in rows] == [ld2, ld, lg2, lg]
            r1, r2, r3, r4 = rows
            @test r2.name == "Kangaroo Hills 2024" && r4.name == "KH2024_MAG_IGRF"
            @test (r1.sub, r1.colours, r1.method) == ("One colour", "", "")   # one plain colour: no ramp
            @test r1.opacity_text == "99 %"                                   # never "100 %" below 100 %
            @test (r2.sub, r2.colours, r2.method) == ("MAG", "geosoft", "linear")
            @test (r3.sub, r3.colours, r3.method) == ("Own colours", "grey", "clip")
            @test (r4.sub, r4.colours, r4.method) == ("Grid colours", "rainbow", "hist. eq.")  # the app's grid colours
            @test r4.opacity_text == "50 %" && !r4.visible && r2.visible
            @test all(r -> !r.missing && r.error == "", rows)
            # Before the loader ran, a visible layer is loading; a hidden one never is.
            @test r1.loading && r2.loading && r3.loading && !r4.loading
            app.ui.current_map = m
            wait_layers(app)
            rows = layer_rows(app.snap, m, app.map.entries, "rainbow")
            @test !any(r -> r.loading, rows)
            @test isempty(layer_rows(app.snap, "map-none", app.map.entries, "rainbow"))
        end
    end

    @testset "rows: a missing item, a removed item and a load error" begin
        s = fresh_session(); db1 = survey_database!(s); db2 = survey_database!(s); db3 = survey_database!(s)
        Core.rename_item!(s, db1, "Gone folder"); Core.rename_item!(s, db3, "North block")
        g = add_test_grid!(s, Float32[1 2 3; 4 5 6]; crs = "EPSG:28355", name = "Other")
        m = Core.new_map!(s)
        l1 = Core.add_layer!(s, m, db1); l2 = Core.add_layer!(s, m, db2); l3 = Core.add_layer!(s, m, db3)
        lg = Core.add_layer!(s, m, g)
        rm(joinpath(s.project.folder, "databases", db1); recursive = true)
        Core.remove_item!(s, db2)
        Core.delete_channel!(s, db3, "MAG")
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            byid = Dict(r.id => r for r in layer_rows(app.snap, m, app.map.entries, "geosoft"))
            r1, r2, r3, rg = byid[l1], byid[l2], byid[l3], byid[lg]
            @test r1.missing && r1.name == "Gone folder" && !r1.loading
            @test r1.error == "The folder of Gone folder is missing."
            @test r2.missing && r2.name == "Removed item" && r2.error == "The layer's item is not in the project."
            @test !r3.missing && r3.error == "Channel MAG is not in North block." && !r3.loading
            # A note on data that draws is shown as well.
            @test !rg.missing && rg.error == "This grid is in EPSG:28355, not in the map's EPSG:32755. " *
                                             "It is drawn without reprojection."
        end
    end

    @testset "drop_position: rows top first, positions bottom first" begin
        @test drop_position(1, 1, 3) == 3 && drop_position(1, 2, 3) == 3   # no move
        @test drop_position(1, 4, 3) == 1                                   # to the bottom
        @test drop_position(3, 1, 3) == 3                                   # to the top
        @test drop_position(2, 4, 3) == 1 && drop_position(3, 2, 3) == 2
        # Every drop puts the row where it was dropped.
        for n in 1:5, from in 1:n, to_row in 1:n+1
            order = collect(1:n)                    # layer k is at position k
            rows = reverse(order)
            want = copy(rows)
            moved = popat!(want, from)
            insert!(want, to_row > from ? to_row - 1 : to_row, moved)
            @test reverse(dropped(order, from, to_row)) == want
        end
    end

    @testset "Move Up and Move Down" begin
        s = fresh_session(); db = survey_database!(s); g = add_test_grid!(s, Float32[1 2; 3 4])
        m = Core.new_map!(s); ld = Core.add_layer!(s, m, db); lg = Core.add_layer!(s, m, g)
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            for (id, name, icon) in (("map.move_up", "Move Up", "up"), ("map.move_down", "Move Down", "down"))
                c = layer_cmd(app, id)
                @test (c.name, c.icon, c.where) == (name, icon, "Layers") && isempty(c.places)
                @test layer_reason(app, id) == "Open a map first."
            end
            app.ui.current_map = m
            @test layer_reason(app, "map.move_up") == "Select a layer first."
            app.ui.layer_selected = ld   # the top layer
            @test layer_reason(app, "map.move_up") == "The layer is at the top."
            @test layer_reason(app, "map.move_down") === nothing
            layer_cmd(app, "map.move_down").run(app)
            wait_drained(app); refresh_now!(app)
            @test [l.id for l in app.snap.maps[m].layers] == [ld, lg]   # bottom first: the lines at the bottom
            @test layer_reason(app, "map.move_down") == "The layer is at the bottom."
            layer_cmd(app, "map.move_up").run(app)
            wait_drained(app); refresh_now!(app)
            @test [l.id for l in app.snap.maps[m].layers] == [lg, ld]
            @test Core.can_undo(s)
            Core.undo!(s); refresh_now!(app)
            @test [l.id for l in app.snap.maps[m].layers] == [ld, lg]   # one undo step per move
        end
    end

    @testset "a map whose layers all fail, or all hidden, says so (T12 deferred)" begin
        s = fresh_session(); db = survey_database!(s); db2 = survey_database!(s)
        m = Core.new_map!(s); l1 = Core.add_layer!(s, m, db); l2 = Core.add_layer!(s, m, db2)
        rm(joinpath(s.project.folder, "databases", db); recursive = true)
        Core.delete_channel!(s, db2, "MAG")
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            for id in ("map.full_extent", "map.zoom_in", "map.zoom_out")
                @test layer_reason(app, id) == "The map is still loading."   # nothing came back yet
            end
            wait_layers(app)
            for id in ("map.full_extent", "map.zoom_in", "map.zoom_out")
                @test layer_reason(app, id) == "The map's layers could not be loaded."
            end
            app.ui.layer_selected = l1
            @test layer_reason(app, "map.zoom_layer") == "The folder of $db is missing."   # the layer's own reason
            Core.set_layer!(s, m, l1; visible = false); Core.set_layer!(s, m, l2; visible = false)
            refresh_now!(app)
            @test layer_reason(app, "map.full_extent") == "Every layer of the map is hidden."
        end
        # Lines that loaded but have no position to place: nothing to fit.
        s = fresh_session(); db = survey_database!(s; lines = 1, nan_line = 1)
        m = Core.new_map!(s); Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            @test layer_reason(app, "map.full_extent") == "The map's layers have nothing to draw."
        end
    end

    @testset "the opacity preview: kept until the edit is in, cleared on a map switch" begin
        s = fresh_session(); db = survey_database!(s)
        m = Core.new_map!(s); l = Core.add_layer!(s, m, db); m2 = Core.new_map!(s)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m; app.ui.layer_selected = l
            app.ui.opacity_preview = (l, 0.4)
            settle_previews!(app)
            @test app.ui.opacity_preview === nothing          # no drag and no edit: a stale preview goes
            app.ui.opacity_preview = (l, 0.4)
            commit_opacity!(app, m, l, 0.4)
            settle_previews!(app)
            @test app.ui.opacity_preview == (l, 0.4)          # the edit is on its way: the map keeps the new look
            wait_drained(app)
            settle_previews!(app)
            @test app.ui.opacity_preview == (l, 0.4)          # the snapshot is still the old one
            refresh_now!(app)
            settle_previews!(app)
            @test app.ui.opacity_preview === nothing && app.snap.maps[m].layers[1].opacity == 0.4
            Core.undo!(s); refresh_now!(app)
            @test app.snap.maps[m].layers[1].opacity == 1.0   # one undo step
            # A failed edit still ends the preview.
            app.ui.opacity_preview = ("layer-9", 0.3)
            commit_opacity!(app, m, "layer-9", 0.3)
            wait_drained(app); refresh_now!(app)
            settle_previews!(app)
            @test app.ui.opacity_preview === nothing
            @test length(app.toasts) == 1 && app.toasts[1].kind == :error && isempty(app.draw_errors)
            # Another map: the preview goes.
            app.ui.opacity_preview = (l, 0.2)
            open_map!(app, m2)
            @test app.ui.opacity_preview === nothing && app.ui.layer_selected == ""
        end
    end

    @testset "Zoom to Layer says why a layer cannot be zoomed to (T13 review)" begin
        s = fresh_session(); ok = survey_database!(s); gone = survey_database!(s); bad = survey_database!(s)
        Core.rename_item!(s, bad, "North block")
        empty_db = survey_database!(s; lines = 1, nan_line = 1)
        m = Core.new_map!(s)
        lok = Core.add_layer!(s, m, ok); lgone = Core.add_layer!(s, m, gone); lbad = Core.add_layer!(s, m, bad)
        lnan = Core.add_layer!(s, m, empty_db); lhid = Core.add_layer!(s, m, ok)
        Core.set_layer!(s, m, lhid; visible = false)
        Core.remove_item!(s, gone)
        Core.delete_channel!(s, bad, "MAG")
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            give(id) = (app.ui.layer_selected = id; layer_reason(app, "map.zoom_layer"))
            @test give(lgone) == "The layer's item is not in the project."
            @test give(lbad) == "Channel MAG is not in North block."
            @test give(lnan) == "The layer has nothing to draw."
            @test give(lhid) == "The layer is hidden."
            @test give(lok) == "The map is still loading."   # no camera: the view has not drawn
            # The loader's own text for a removed item names no id (T13 review).
            e = only(e for e in values(app.map.entries) if e.key.item == gone)
            @test e.error == "The layer's item is not in the project."
        end
    end

    @testset "a map that cannot be read gives its own error as the reason" begin
        s = fresh_session(); m = Core.new_map!(s)
        write(joinpath(s.project.folder, "maps", m, "map.json"), "{ not json")
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            err = app.snap.maps[m].error
            @test !isempty(err) && view_reason(app) == err
        end
    end

    @testset "opacity edits: each release has its own token; the slider shows the pending value" begin
        s = fresh_session(); db = survey_database!(s)
        m = Core.new_map!(s); l = Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m; app.ui.layer_selected = l
            mv = app.snap.maps[m]
            @test shown_opacity(app, mv, l) == 1.0
            commit_opacity!(app, m, l, 0.4)
            commit_opacity!(app, m, l, 0.3)                   # a second release before the first is in
            @test app.ui.opacity_preview == (l, 0.3) && shown_opacity(app, mv, l) == 0.3
            wait_drained(app)
            @test app.ui.opacity_edit.token == 2 && app.ui.opacity_edit.revision == Core.revision(s)
            settle_previews!(app)
            @test app.ui.opacity_preview == (l, 0.3)          # the snapshot is still the old one
            refresh_now!(app); settle_previews!(app)
            @test app.ui.opacity_preview === nothing && app.ui.opacity_edit === nothing
            @test app.snap.maps[m].layers[1].opacity == 0.3
        end
    end

    @testset "the rows are cached until the snapshot or a load changes" begin
        s = fresh_session(); db = survey_database!(s); m = Core.new_map!(s); Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            mv = app.snap.maps[m]
            c1 = layers_cache(app, mv)
            @test layers_cache(app, mv).rows === c1.rows && only(c1.rows).loading
            @test (@allocated layers_cache(app, mv)) == 0
            wait_layers(app)
            c2 = layers_cache(app, mv)
            @test !only(c2.rows).loading                      # a load came back: built again
        end
    end
end
