using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: commands, tab_order, show_on_map!, add_to_map!, tree_rows, Camera, MapViewState, MapInput,
    step_view!, full_extent!, zoom_by!, previous!, next!, ribbon_layout, RibbonGroup, BigButton, SmallColumn,
    MenuButton, SETTLE

cmd(app, id) = only(filter(c -> c.id == id, commands(app)))
reason(app, id) = cmd(app, id).enabled(app)
run!(app, id) = cmd(app, id).run(app)
settled!(app) = (wait_drained(app); refresh_now!(app))

# A wheel notch over the view at time `t`, and a frame with no input.
wheel_at(t; size = (800, 600)) = MapInput((400f0, 300f0), true, false, false, false, 1f0, size, Float64(t))
idle_at(t; size = (800, 600)) = MapInput((0f0, 0f0), false, false, false, false, 0f0, size, Float64(t))
drag_at(pos, t; size = (800, 600)) = MapInput(Float32.(pos), true, true, false, false, 0f0, size, Float64(t))

# Give map `m` a view of `size` with camera `cam`, as the map view would after a frame.
function give_view!(app, m, cam; size = (800, 600))
    st = get!(MapViewState, app.map.views, m)
    st.camera = cam
    st.size = size
    return st
end

@testset "map commands" begin
    @testset "the brief" begin
        s = fresh_session(); db = survey_database!(s)
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            ids = Set(c.id for c in commands(app))
            @test issubset(["map.new", "map.add_item", "map.full_extent", "map.prev_extent", "map.layer_style"], ids)
            @test "Map" in tab_order(commands(app), String[])
            @test only(filter(c -> c.id == "map.full_extent", commands(app))).shortcut == "Home"
            @test only(filter(c -> c.id == "map.remove_layer", commands(app))).enabled(app) == "Open a map first."
            show_on_map!(app, db); wait_drained(app); refresh_now!(app)
            m = app.ui.current_map
            @test length(app.snap.maps[m].layers) == 1
            rows = tree_rows(app.snap, Set(["maps"]), "")
            # As the Databases and Grids folders: the count at the right of the name, not in it.
            @test any(r -> r.label == "Maps" && r.right == "1", rows) && any(r -> r.label == "Map 1" && r.right == "1 layer", rows)
            show_on_map!(app, db); wait_drained(app); refresh_now!(app)
            @test length(app.snap.maps[m].layers) == 1                     # already there: no second layer
        end
    end

    @testset "names, icons and places" begin
        with_app(test_app_state(fresh_session())) do app
            refresh_now!(app)
            want = [("map.new", "New Map", "newMap", "Map", :big), ("map.add_item", "Add Item to Map", "addItem", "Map", :big),
                ("map.remove_layer", "Remove Layer", "removeLayer", "Map", :small),
                ("map.full_extent", "Full Extent", "fullExtent", "Navigate", :big),
                ("map.zoom_in", "Zoom In", "zoomIn", "Navigate", :small), ("map.zoom_out", "Zoom Out", "zoomOut", "Navigate", :small),
                ("map.zoom_layer", "Zoom to Layer", "zoomLayer", "Navigate", :small),
                ("map.prev_extent", "Previous Extent", "prevExtent", "Navigate", :small),
                ("map.next_extent", "Next Extent", "nextExtent", "Navigate", :small),
                ("map.go_cursor", "Go To Cursor", "crosshair", "Navigate", :small),
                ("map.layer_style", "Layer Style", "brush", "Display", :big),
                ("map.hillshade", "Hillshade", "hillshade", "Display", :small),
                ("map.colour_bars", "Colour Bars", "colour", "Display", :small),
                ("map.line_labels", "Line Labels", "lineType", "Display", :small)]
            for (id, name, icon, group, size) in want
                c = cmd(app, id)
                p = only(c.places)
                @test (c.name, c.icon, p.tab, p.group, p.size) == (name, icon, "Map", group, size)
            end
            groups = ribbon_layout(commands(app), "Map")
            @test groups == [
                RibbonGroup("Map", [BigButton("map.new"), MenuButton("map.add_item"), SmallColumn(["map.remove_layer"])]),
                RibbonGroup("Navigate", [BigButton("map.full_extent"), SmallColumn(["map.zoom_in", "map.zoom_out", "map.zoom_layer"]),
                    SmallColumn(["map.prev_extent", "map.next_extent", "map.go_cursor"])]),
                RibbonGroup("Display", [BigButton("map.layer_style"),
                    SmallColumn(["map.hillshade", "map.colour_bars", "map.line_labels"])])]
            @test tab_order(commands(app), String[])[end] == "Map"
        end
    end

    @testset "enabled reasons" begin
        with_app(test_app_state(nothing)) do app
            for id in ("map.new", "map.add_item", "map.full_extent", "map.colour_bars", "map.layer_style")
                @test reason(app, id) == "Open a project first."
            end
        end
        s = fresh_session(); db = survey_database!(s; lines = 4)
        g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10])
        m = Core.new_map!(s)
        lines_map = Core.new_map!(s)
        Core.add_layer!(s, lines_map, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            @test reason(app, "map.new") === nothing && reason(app, "map.add_item") === nothing
            for id in ("map.remove_layer", "map.full_extent", "map.zoom_in", "map.zoom_out", "map.zoom_layer",
                    "map.prev_extent", "map.next_extent", "map.go_cursor", "map.hillshade", "map.line_labels",
                    "map.layer_style")
                @test reason(app, id) == "Open a map first."
            end
            @test reason(app, "map.colour_bars") === nothing   # an app setting
            app.ui.current_map = m
            @test reason(app, "map.remove_layer") == "Select a layer first."
            @test reason(app, "map.zoom_layer") == "Select a layer first."
            @test reason(app, "map.layer_style") == "Select a layer first."
            @test reason(app, "map.hillshade") == "The map has no grid layer."
            @test reason(app, "map.line_labels") == "The map has no line layer."
            @test reason(app, "map.prev_extent") == "There is no earlier extent."
            @test reason(app, "map.next_extent") == "There is no later extent."
            @test reason(app, "map.go_cursor") == "The current point is not on this map."
            # An empty map has nothing to move to (T12 review).
            for id in ("map.full_extent", "map.zoom_in", "map.zoom_out")
                @test reason(app, id) == "The map has no layers."
            end
            app.ui.current_map = lines_map
            # Layers, but no camera yet: the view has not drawn its first data.
            for id in ("map.full_extent", "map.zoom_in", "map.zoom_out")
                @test reason(app, id) == "The map is still loading."
            end
            @test reason(app, "map.line_labels") === nothing && reason(app, "map.hillshade") == "The map has no grid layer."
            app.ui.layer_selected = only(app.snap.maps[lines_map].layers).id
            @test reason(app, "map.remove_layer") === nothing
            @test reason(app, "map.zoom_layer") == "The map is still loading."
            give_view!(app, lines_map, Camera(500_000.0, 7_000_000.0, 1.0))
            @test reason(app, "map.zoom_layer") === nothing && reason(app, "map.full_extent") === nothing
            @test reason(app, "map.layer_style") === nothing
            # A layer of another map is not selected on this one.
            app.ui.current_map = m
            @test reason(app, "map.remove_layer") == "Select a layer first."
            # Add Item needs a database or a grid.
            Core.remove_item!(s, db); Core.remove_item!(s, g)
            refresh_now!(app)
            @test reason(app, "map.add_item") == "Import line data or a grid first."
        end
    end

    @testset "New Map makes a map and shows it; undo takes it out" begin
        with_app(test_app_state(fresh_session())) do app
            refresh_now!(app)
            run!(app, "map.new"); settled!(app)
            m = app.ui.current_map
            @test app.snap.maps[m].name == "Map 1" && isempty(app.snap.maps[m].layers)
            run!(app, "map.new"); settled!(app)
            @test app.snap.maps[app.ui.current_map].name == "Map 2"
            UI.run_undo(app, false); settled!(app)
            @test length(app.snap.maps) == 1
        end
    end

    @testset "Show on Map and Add to Current Map" begin
        s = fresh_session(); db = survey_database!(s)
        g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10]; name = "TMI")
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            show_on_map!(app, g); settled!(app)
            m = app.ui.current_map
            layers = app.snap.maps[m].layers
            @test length(layers) == 1 && only(layers).item == g && app.ui.layer_selected == only(layers).id
            # Add to Current Map always adds: one database shows twice.
            add_to_map!(app, db); settled!(app)
            add_to_map!(app, db); settled!(app)
            layers = app.snap.maps[m].layers
            @test [l.item for l in layers] == [g, db, db] && app.ui.layer_selected == layers[3].id
            # Show on Map of an item on the map selects its layer and adds nothing.
            show_on_map!(app, g); settled!(app)
            @test length(app.snap.maps[m].layers) == 3 && app.ui.layer_selected == layers[1].id
            # Each layer is one undo step.
            UI.run_undo(app, false); settled!(app)
            @test length(app.snap.maps[m].layers) == 2
            # The Add Item menu lists the databases and grids and adds to the shown map.
            items = UI.add_item_menu(app)
            @test [it.label for it in items] == ["Databases", UI.item_name(app.snap, db), "Grids", "TMI"]
            @test [it.head for it in items] == [true, false, true, false]
            @test [it.icon for it in items[[2, 4]]] == ["database", "grid"]
            @test [it.shortcut for it in items[[2, 4]]] == ["on map", "on map"]
            items[4].action(app); settled!(app)
            @test [l.item for l in app.snap.maps[m].layers] == [g, g, db]
            # With no map shown, Add Item makes a map.
            app.ui.current_map = ""
            UI.add_item_menu(app)[2].action(app); settled!(app)
            m2 = app.ui.current_map
            @test m2 != m && [l.item for l in app.snap.maps[m2].layers] == [db]
        end
    end

    @testset "a failed add on the no-map path still shows the new map (T12 review)" begin
        s = session_with()   # its database has no current X, Y pair
        db = only(it.id for it in s.project.items)
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            show_on_map!(app, db); settled!(app)
            m = app.ui.current_map
            @test haskey(app.snap.maps, m) && isempty(app.snap.maps[m].layers) && app.ui.layer_selected == ""
            @test any(t -> occursin("no current X, Y pair", t.text * " " * t.sub), app.toasts)
            @test app.snap.undo_label == "new map Map 1"   # one step: the map
            UI.run_undo(app, false); settled!(app)
            @test isempty(app.snap.maps) && app.snap.undo_label === nothing
        end
    end

    @testset "Remove from Project of the shown map, then undo and redo (T12 review)" begin
        s = fresh_session(); db = survey_database!(s)
        with_app(test_app_state(s)) do app
            refresh_now!(app)
            show_on_map!(app, db); settled!(app)
            m, l = app.ui.current_map, app.ui.layer_selected
            rows = tree_rows(app.snap, Set(["maps"]), "")
            remove = last(UI.tree_menu(app, only(r for r in rows if r.key == m)))
            remove.action(app); settled!(app)
            # The map is out: nothing is shown and the map commands say why.
            @test !haskey(app.snap.maps, m) && UI.shown_map(app) === nothing
            @test UI.central_state(app).lines[1] == "No view is open."
            @test reason(app, "map.remove_layer") == "Open a map first."
            # Undo brings it back as it was shown, with its layer selected.
            UI.run_undo(app, false); settled!(app)
            @test app.ui.current_map == m && UI.shown_map(app) === app.snap.maps[m] && app.ui.layer_selected == l
            @test reason(app, "map.remove_layer") === nothing
            UI.run_undo(app, true); settled!(app)
            @test UI.shown_map(app) === nothing && !haskey(app.snap.maps, m)
        end
    end

    @testset "Show on Map of an item already on the map zooms to its layer" begin
        s = fresh_session(); db = survey_database!(s; lines = 4)
        g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10]; x0 = 400_000.0)
        m = Core.new_map!(s)
        Core.add_layer!(s, m, db); lg = Core.add_layer!(s, m, g)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            st = give_view!(app, m, Camera(0.0, 0.0, 1.0))
            show_on_map!(app, g)
            ext = UI.grid_extent(app.map.entries[UI.layer_key(app.snap, app.snap.maps[m], only(l for l in app.snap.maps[m].layers if l.id == lg))].data.geo)
            @test app.ui.layer_selected == lg
            @test st.camera == UI.view_camera(app, app.snap.maps[m], ext, 800, 600)
            @test st.history.past == [Camera(0.0, 0.0, 1.0)]
        end
    end

    @testset "Remove Layer, Hillshade, Line Labels and Colour Bars" begin
        s = fresh_session(); db = survey_database!(s)
        g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10])
        g2 = add_test_grid!(s, Float32[i * j for i in 1:20, j in 1:10]; name = "Second")
        m = Core.new_map!(s)
        lg = Core.add_layer!(s, m, g); lg2 = Core.add_layer!(s, m, g2); ld = Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            layer(id) = only(l for l in app.snap.maps[m].layers if l.id == id)
            # The top grid layer, as no grid layer is selected.
            @test !cmd(app, "map.hillshade").checked(app)
            run!(app, "map.hillshade"); settled!(app)
            @test !layer(lg2).own_style && layer(lg2).style.shade && !layer(lg).style.shade   # it keeps its grid's colours
            @test cmd(app, "map.hillshade").checked(app)
            # The selected grid layer.
            app.ui.layer_selected = lg
            @test !cmd(app, "map.hillshade").checked(app)
            run!(app, "map.hillshade"); settled!(app)
            @test layer(lg).style.shade
            run!(app, "map.hillshade"); settled!(app)
            @test !layer(lg).style.shade
            # Line labels: the top line layer; they start on.
            @test cmd(app, "map.line_labels").checked(app)
            run!(app, "map.line_labels"); settled!(app)
            @test !layer(ld).labels && !cmd(app, "map.line_labels").checked(app)
            UI.run_undo(app, false); settled!(app)
            @test layer(ld).labels
            # Colour Bars is an app setting.
            @test app.ui.colour_bars && cmd(app, "map.colour_bars").checked(app)
            run!(app, "map.colour_bars")
            @test !app.ui.colour_bars && !cmd(app, "map.colour_bars").checked(app)
            # Remove Layer takes the selected layer out; undo puts it back.
            app.ui.layer_selected = ld
            run!(app, "map.remove_layer"); settled!(app)
            @test [l.id for l in app.snap.maps[m].layers] == [lg, lg2] && app.ui.layer_selected == ""
            UI.run_undo(app, false); settled!(app)
            @test [l.id for l in app.snap.maps[m].layers] == [lg, lg2, ld]
        end
    end

    @testset "Layer Style selects its pane tab only once the pane exists" begin
        s = fresh_session(); db = survey_database!(s)
        m = Core.new_map!(s); ld = Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m; app.ui.layer_selected = ld
            run!(app, "map.layer_style")
            if UI.lookup_tab(:style) === nothing   # until Task 14 adds the Layer Style pane
                @test isempty(app.ui.right_tabs) && app.ui.right_active === :none
            else
                @test app.ui.right_active === :style
            end
        end
    end

    @testset "navigation" begin
        s = fresh_session(); db = survey_database!(s; lines = 4)
        m = Core.new_map!(s); ld = Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            ext = UI.map_extent(app, app.snap.maps[m])
            a = Camera(500_020.0, 7_000_075.0, 2.0)
            st = give_view!(app, m, a)
            run!(app, "map.zoom_in")
            @test st.camera == Camera(a.cx, a.cy, 1.0) && st.history.past == [a]
            run!(app, "map.zoom_out")
            @test st.camera == a && length(st.history.past) == 2
            # Full Extent fits the inner box: the view less the coordinate bands, clear of the scale bar and the legend.
            run!(app, "map.full_extent")
            full = UI.view_camera(app, app.snap.maps[m], ext, 800, 600)
            @test full == UI.fit_clear(ext, 800, 600, UI.px(1, UI.BAND), UI.overlay_corners(app, app.snap.maps[m]))
            @test st.camera == full && length(st.history.past) == 3
            @test reason(app, "map.next_extent") == "There is no later extent."
            run!(app, "map.prev_extent"); @test st.camera == a
            @test reason(app, "map.next_extent") === nothing
            run!(app, "map.next_extent"); @test st.camera == full
            # Zoom to Layer fits the selected layer.
            app.ui.layer_selected = ld
            st.camera = a
            run!(app, "map.zoom_layer"); @test st.camera == full
            # Go To Cursor centres the current point of a line of the map.
            Core.set_cursor!(s, Core.Cursor(db, Core.LineId(Core.LINE, 1002, 0), 3))
            refresh_now!(app)
            @test reason(app, "map.go_cursor") === nothing
            p = UI.cursor_target(app, app.snap.maps[m])
            @test p[2] == 7_000_050.0   # line 2
            run!(app, "map.go_cursor")
            @test (st.camera.cx, st.camera.cy) == p && st.camera.res == full.res
        end
    end

    @testset "history: a command ends a gesture that has not settled (T10 review)" begin
        a = Camera(0.0, 0.0, 1.0)
        # Previous during a wheel gesture goes back to the camera before the wheel.
        st = MapViewState(a); st.size = (800, 600)
        step_view!(st, wheel_at(0.0))
        b = st.camera
        @test st.gesture == :wheel && st.before == a
        previous!(st)
        @test st.camera == a && st.gesture == :none && st.before === nothing
        @test isempty(st.history.past) && st.history.future == [b]
        step_view!(st, idle_at(1.0)); @test isempty(st.history.past)   # nothing settles later
        next!(st); @test st.camera == b && st.history.past == [a] && isempty(st.history.future)
        # Next during a wheel gesture: the wheel ended the forward trail, so nothing is later.
        previous!(st)
        step_view!(st, wheel_at(2.0))
        c = st.camera
        next!(st)
        @test st.camera == c && st.history.past == [a] && isempty(st.history.future)
        step_view!(st, idle_at(3.0)); @test st.history.past == [a]

        # Full Extent during a held pan: the pan and the fit are one entry each, in order.
        st = MapViewState(a)
        step_view!(st, drag_at((400, 300), 0.0))
        step_view!(st, drag_at((440, 330), 0.02))
        panned = st.camera
        @test st.gesture == :pan && panned != a
        ext = (100.0, 100.0, 300.0, 200.0)
        full_extent!(st, ext, 800, 600)
        fitted = st.camera
        @test st.history.past == [a, panned] && st.gesture == :none && st.before === nothing
        # The button is still down: the drag goes on from the fitted camera, and adds one more
        # entry only when it moves.
        step_view!(st, drag_at((440, 330), 0.04))
        step_view!(st, MapInput((440f0, 330f0), true, false, false, false, 0f0, (800, 600), 0.06))
        step_view!(st, idle_at(1.0))
        @test st.camera == fitted && st.history.past == [a, panned]
        previous!(st); @test st.camera == panned
        previous!(st); @test st.camera == a

        # A command after a settled gesture adds exactly one entry.
        st = MapViewState(a)
        step_view!(st, wheel_at(0.0)); step_view!(st, idle_at(SETTLE + 0.1))
        @test length(st.history.past) == 1
        zoom_by!(st, 2.0)
        @test length(st.history.past) == 2
    end

    @testset "a project shows its first map; set_session! resets the map state" begin
        s = fresh_session(); db = survey_database!(s)
        m1 = Core.new_map!(s; name = "First"); Core.new_map!(s; name = "Second")
        with_app(test_app_state(nothing)) do app
            app.ui.colour_bars = false
            app.ui.layer_selected = "layer-9"
            UI.set_session!(app, s)
            @test app.ui.colour_bars && app.ui.layer_selected == "" && app.ui.current_map == ""
            refresh_now!(app)
            UI.sync_current_map!(app)
            @test app.ui.current_map == m1
            # Only the first snapshot of a project picks a map.
            app.ui.current_map = ""
            UI.sync_current_map!(app)
            @test app.ui.current_map == ""
        end
    end
end
