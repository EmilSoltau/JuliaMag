using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: style_edit, style_fields, colour_channels, sig_num, auto_scale_hint, settle_previews!, commands,
    open_map!, apply_style_edit!, grid_layer_style, style_message, style_cache, build_scene!, Scene, LineDraw,
    MapViewState, full_extent!, Camera, commit_opacity!

style_cmd(app, id) = only(filter(c -> c.id == id, commands(app)))

@testset "layer style pane" begin
    @testset "the brief" begin
        L = Core.MapLayer("layer-1", "db-1", :lines, "MAG", true, 1.0, true, true, Core.LayerStyle())
        @test style_edit(L, :colours, "viridis").style.colours == "viridis"
        @test style_edit(L, :clip_low, 70.0).style.clip_low == 49.0
        @test style_edit(L, :inclination, -5.0).style.inclination == 0.0
        @test style_edit(L, :channel, "").channel == ""
        G = Core.MapLayer("layer-2", "grid-1", :grid, "", true, 1.0, false, false, Core.LayerStyle())
        @test_throws ArgumentError style_edit(G, :colours, "turbo")
        @test style_edit(G, :own_style, true).own_style
    end

    @testset "style_edit: one field, the rest kept, the layer untouched" begin
        L = Core.MapLayer("layer-1", "db-1", :lines, "MAG", true, 1.0, true, true, Core.LayerStyle(colours = "grey"))
        e = style_edit(L, :stretch, :linear)
        @test keys(e) == (:style,) && e.style.colours == "grey" && e.style.stretch == :linear
        @test L.style.stretch == :histeq && e.style !== L.style
        @test style_edit(L, :clip_high, -3.0).style.clip_high == 0.0
        @test style_edit(L, :inclination, 120.0).style.inclination == 90.0
        @test style_edit(L, :declination, 400.0).style.declination == 360.0
        @test style_edit(L, :reverse, true).style.reverse
        @test isnan(style_edit(L, :min, NaN).style.min) && style_edit(L, :max, 9.5).style.max == 9.5
        @test isnan(style_edit(L, :zfactor, NaN).style.zfactor) && style_edit(L, :zfactor, 2.0).style.zfactor == 2.0
        @test_throws ArgumentError style_edit(L, :min, Inf)
        @test_throws ArgumentError style_edit(L, :zfactor, 0.0)
        @test_throws ArgumentError style_edit(L, :inclination, NaN)
        @test_throws ArgumentError style_edit(L, :colours, "nope")
        @test_throws ArgumentError style_edit(L, :stretch, :normal)
        @test_throws ArgumentError style_edit(L, :own_style, false)   # a line layer always has its own colours
        @test_throws ArgumentError style_edit(L, :bogus, 1)
        @test style_edit(L, :labels, false) == (; labels = false)
        @test style_edit(L, :opacity, 1.5) == (; opacity = 1.0)
        # A grid layer's shading and cells are its own: they never touch `own_style`.
        G = Core.MapLayer("layer-2", "grid-1", :grid, "", true, 1.0, false, false, Core.LayerStyle())
        e = style_edit(G, :shade, true)
        @test keys(e) == (:style,) && e.style.shade
        @test style_edit(G, :resample, :nearest).style.resample == :nearest
        @test_throws ArgumentError style_edit(G, :resample, :cubic)
        @test_throws ArgumentError style_edit(G, :channel, "MAG")
        @test_throws ArgumentError style_edit(G, :reverse, true)
        @test_throws ArgumentError style_edit(G, :stretch, :linear)
        # Unticking "Use the grid's default colours" starts from the style the layer shows: the
        # app's "Grid colours" for a grid with the stock table, so the colours do not jump. The
        # layer keeps its own shading.
        gs = Core.GridStyle("geosoft", :linear, 1.0, 9.0, true, false, 45.0, 45.0, 1.0)
        Gs = Core.MapLayer("layer-3", "grid-1", :grid, "", true, 1.0, false, false,
                           Core.LayerStyle(shade = true, inclination = 30.0))
        e = style_edit(Gs, :own_style, true; grid = gs, app_colours = "turbo")
        @test e.own_style && e.style.colours == "turbo" && e.style.stretch == :linear
        @test e.style == Core.effective_style(Gs, gs, "turbo")
        @test e.style.min == 1.0 && e.style.max == 9.0 && e.style.reverse
        @test e.style.shade && e.style.inclination == 30.0
        own_table = Core.GridStyle("viridis", :histeq, NaN, NaN, false, false, 45.0, 45.0, 1.0)
        @test style_edit(Gs, :own_style, true; grid = own_table, app_colours = "turbo").style.colours == "viridis"
        @test style_edit(Gs, :own_style, false) == (; own_style = false)
        own = Core.MapLayer("layer-4", "grid-1", :grid, "", true, 1.0, false, true, Core.LayerStyle())
        @test style_edit(own, :colours, "turbo").style.colours == "turbo"   # its own colours can change
    end

    @testset "the fields that apply" begin
        lines(st; ch = "MAG") = Core.MapLayer("layer-1", "db-1", :lines, ch, true, 1.0, true, true, st)
        grid(st; own = false) = Core.MapLayer("layer-2", "grid-1", :grid, "", true, 1.0, false, own, st)
        f(l) = style_fields(l, l.style)
        @test f(lines(Core.LayerStyle(stretch = :linear))) ==
              [:channel, :colours, :reverse, :stretch, :min, :max, :labels, :opacity]
        @test f(lines(Core.LayerStyle(stretch = :clip))) ==
              [:channel, :colours, :reverse, :stretch, :clip_low, :clip_high, :labels, :opacity]
        @test f(lines(Core.LayerStyle())) == [:channel, :colours, :reverse, :stretch, :labels, :opacity]
        @test f(lines(Core.LayerStyle(); ch = "")) == [:channel, :labels, :opacity]
        @test f(grid(Core.LayerStyle())) == [:own_style, :colours, :reverse, :stretch, :shade, :resample, :opacity]
        @test f(grid(Core.LayerStyle(shade = true, stretch = :clip); own = true)) ==
              [:own_style, :colours, :reverse, :stretch, :clip_low, :clip_high, :shade, :inclination,
               :declination, :zfactor, :resample, :opacity]
    end

    @testset "Colour by lists the numeric channels that are not arrays" begin
        ch(name, eltype, n = 1) = UI.ChannelRow(name, name, "", Core.ROLE_NONE, eltype, false, n, 2, :normal, 10)
        v = UI.DatabaseView("db-1", UI.LineRow[],
            [ch("X", "Float64"), ch("MAG", "Float32"), ch("LINE", "String"), ch("SPEC", "Float32", 8), ch("FLAG", "UInt8")],
            Core.PositionPair[], 0, 0, "")
        @test colour_channels(v) == ["X", "MAG", "FLAG"]
    end

    @testset "numbers: 3 significant digits, and the vertical scale's hint" begin
        @test sig_num(12.345) == "12.3" && sig_num(1.0) == "1" && sig_num(0.0123456) == "0.0123"
        @test sig_num(2.5 / 0.00123) == "2,030" && sig_num(123456.0) == "123,000"
        @test auto_scale_hint(0.00123) == "Auto: 2.5 over the mean gradient = 2,030"
        @test auto_scale_hint(0.4) == "Auto: 2.5 over the mean gradient = 6.25"
        @test auto_scale_hint(NaN) == "Auto: 1, as the grid is flat."
        @test auto_scale_hint(nothing) == "Auto: 2.5 over the mean gradient."
    end

    @testset "Hillshade on and off keeps the layer on its grid's colours (T12 review)" begin
        s = fresh_session(); g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10])
        m = Core.new_map!(s); lg = Core.add_layer!(s, m, g)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m; app.ui.layer_selected = lg
            layer() = only(app.snap.maps[m].layers)
            ribbon!() = (style_cmd(app, "map.hillshade").run(app); wait_drained(app); refresh_now!(app); settle_previews!(app))
            n = length(s.undo_stack)
            ribbon!()
            @test layer().style.shade && !layer().own_style && style_cmd(app, "map.hillshade").checked(app)
            @test app.ui.style_preview === nothing
            ribbon!()
            @test !layer().style.shade && !layer().own_style && length(s.undo_stack) == n + 2
            # The app's "Grid colours" setting still reaches the layer, and so does the grid's style.
            app.config.grid_colours = "viridis"
            @test grid_layer_style(app, layer()).colours == "viridis"
            Core.set_grid_style!(s, g, Core.GridStyle("turbo", :linear, NaN, NaN, false, false, 45.0, 45.0, 1.0))
            refresh_now!(app)
            st = grid_layer_style(app, layer())
            @test st.colours == "turbo" && st.stretch == :linear && !st.shade
            # The pane's Hillshade takes the same path: one step, and the layer still follows its grid.
            apply_style_edit!(app, app.snap.maps[m], layer(), :shade, true)
            wait_drained(app); refresh_now!(app)
            @test layer().style.shade && !layer().own_style && grid_layer_style(app, layer()).colours == "turbo"
            @test s.history[end].command == "map.set_layer"
        end
    end

    @testset "the style preview: kept until the edit is in, ended by a failed edit and a map switch" begin
        s = fresh_session(); db = survey_database!(s)
        m = Core.new_map!(s); l = Core.add_layer!(s, m, db); m2 = Core.new_map!(s)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m; app.ui.layer_selected = l
            layer() = only(app.snap.maps[m].layers)
            app.ui.style_preview = (l, Core.LayerStyle(colours = "grey"))
            settle_previews!(app)
            @test app.ui.style_preview === nothing            # no drag and no edit: a stale preview goes
            n = length(s.undo_stack)
            apply_style_edit!(app, app.snap.maps[m], layer(), :colours, "viridis")
            settle_previews!(app)
            @test app.ui.style_preview[1] == l && app.ui.style_preview[2].colours == "viridis"
            wait_drained(app); settle_previews!(app)
            @test app.ui.style_preview !== nothing            # the snapshot is still the old one
            refresh_now!(app); settle_previews!(app)
            @test app.ui.style_preview === nothing && layer().style.colours == "viridis"
            @test length(s.undo_stack) == n + 1 && s.history[end].command == "map.set_layer"
            # Opacity and style edits share the tokens: an older edit never ends a newer preview.
            commit_opacity!(app, m, l, 0.5)
            apply_style_edit!(app, app.snap.maps[m], layer(), :reverse, true)
            @test app.ui.opacity_edit.token < app.ui.style_pending.token
            wait_drained(app); refresh_now!(app); settle_previews!(app)
            @test app.ui.opacity_preview === nothing && app.ui.style_preview === nothing
            # A failed edit still ends the preview.
            gone = Core.MapLayer("layer-9", db, :lines, "MAG", true, 1.0, true, true, Core.LayerStyle())
            apply_style_edit!(app, app.snap.maps[m], gone, :colours, "turbo")
            wait_drained(app); refresh_now!(app); settle_previews!(app)
            @test app.ui.style_preview === nothing && app.ui.style_pending === nothing
            @test length(app.toasts) == 1 && app.toasts[1].kind == :error && isempty(app.draw_errors)
            # Another map, or another project: the preview goes.
            app.ui.style_preview = (l, Core.LayerStyle())
            open_map!(app, m2)
            @test app.ui.style_preview === nothing
            app.ui.style_preview = (l, Core.LayerStyle())
            UI.set_session!(app, s)
            @test app.ui.style_preview === nothing && app.ui.style_pending === nothing
        end
    end

    @testset "edits build on a pending one; checkboxes read it; a no-op makes no step (T14 review)" begin
        s = fresh_session(); g = add_test_grid!(s, Float32[i + j for i in 1:20, j in 1:10]); db = survey_database!(s)
        m = Core.new_map!(s); lg = Core.add_layer!(s, m, g); ld = Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            app.config.grid_colours = "turbo"
            refresh_now!(app); app.ui.current_map = m; app.ui.layer_selected = lg
            layer(id) = only(l for l in app.snap.maps[m].layers if l.id == id)
            n = length(s.undo_stack)
            # Untick, then the ribbon's Hillshade before the snapshot has the untick.
            apply_style_edit!(app, app.snap.maps[m], layer(lg), :own_style, true)
            @test UI.pending_layer(app, layer(lg)).own_style            # read from the edit on its way
            style_cmd(app, "map.hillshade").run(app)
            wait_drained(app); refresh_now!(app); settle_previews!(app)
            l = layer(lg)
            @test l.own_style && l.style.shade && l.style.colours == "turbo" && length(s.undo_stack) == n + 2
            # A second quick click of Line labels sends the other value, not the same one again.
            app.ui.layer_selected = ld
            apply_style_edit!(app, app.snap.maps[m], layer(ld), :labels, false)
            @test !UI.pending_layer(app, layer(ld)).labels
            apply_style_edit!(app, app.snap.maps[m], layer(ld), :labels, !UI.pending_layer(app, layer(ld)).labels)
            wait_drained(app); refresh_now!(app); settle_previews!(app)
            @test layer(ld).labels && length(s.undo_stack) == n + 4
            # An edit to the value the layer has makes no step and no live style.
            apply_style_edit!(app, app.snap.maps[m], layer(ld), :labels, true)
            apply_style_edit!(app, app.snap.maps[m], layer(ld), :colours, layer(ld).style.colours)
            apply_style_edit!(app, app.snap.maps[m], layer(ld), :min, NaN)
            @test app.ui.style_pending === nothing && app.ui.style_preview === nothing
            wait_drained(app); refresh_now!(app)
            @test length(s.undo_stack) == n + 4
        end
    end

    @testset "the map draws a live style; its key changes; no allocation while it holds" begin
        s = fresh_session(); db = survey_database!(s; lines = 4)
        g = add_test_grid!(s, Float32[i + 10j for i in 1:30, j in 1:20])
        m = Core.new_map!(s); lg = Core.add_layer!(s, m, g); ld = Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            mv = app.snap.maps[m]
            st = MapViewState(nothing)
            full_extent!(st, (500_000.0, 7_000_000.0, 500_300.0, 7_000_200.0), 800, 600)
            sc = Scene(st.camera, 1, 1, (0x00, 0x00, 0x00, 0xff), LineDraw[], 0)
            build_scene!(sc, app, mv, st, 800, 600)
            key = sc.key
            gd = sc.layers[1]
            @test gd.lut == UI.lut_rgba!(UInt8[], "geosoft", false) && !gd.shade
            live = copy(grid_layer_style(app, mv.layers[1]))
            live.colours = "viridis"; live.shade = true; live.inclination = 20.0; live.resample = :nearest
            app.ui.style_preview = (lg, live)
            build_scene!(sc, app, mv, st, 800, 600)
            @test sc.key != key && gd.lut == UI.lut_rgba!(UInt8[], "viridis", false)
            @test gd.shade && gd.nearest && gd.sun == Float32.(Core.sun_vector(20, 45))
            build_scene!(sc, app, mv, st, 800, 600)
            @test (@allocated build_scene!(sc, app, mv, st, 800, 600)) == 0
            live2 = copy(live); live2.inclination = 60.0
            app.ui.style_preview = (lg, live2)                  # a drag moves on: the key moves too
            k2 = sc.key
            build_scene!(sc, app, mv, st, 800, 600)
            @test sc.key != k2 && gd.sun == Float32.(Core.sun_vector(60, 45))
            # The preview ends without an edit (Esc): the map goes back to the layer's own style.
            app.ui.style_preview = nothing
            build_scene!(sc, app, mv, st, 800, 600)
            @test sc.key == key && gd.lut == UI.lut_rgba!(UInt8[], "geosoft", false)
        end
    end

    @testset "what the pane says with no layer, a missing item and a map that cannot be read" begin
        s = fresh_session(); db = survey_database!(s); gone = survey_database!(s)
        m = Core.new_map!(s); l = Core.add_layer!(s, m, db); lgone = Core.add_layer!(s, m, gone)
        m2 = Core.new_map!(s); m3 = Core.new_map!(s)
        write(joinpath(s.project.folder, "maps", m3, "map.json"), "{ not json")
        Core.remove_item!(s, gone)
        with_app(test_app_state(s)) do app
            @test style_message(app) == "No map is open."
            refresh_now!(app)
            @test style_message(app) == "No map is open."
            app.ui.current_map = m
            @test style_message(app) == "Select a layer in the Layers tab to change its style."
            app.ui.layer_selected = lgone
            @test style_message(app) == "The layer's item is not in the project."
            app.ui.layer_selected = l
            @test style_message(app) === nothing
            open_map!(app, m2)
            @test style_message(app) == "Select a layer in the Layers tab to change its style."
            open_map!(app, m3)
            @test style_message(app) == app.snap.maps[m3].error && !isempty(app.snap.maps[m3].error)
        end
    end

    @testset "the pane's numbers are cached: no work and no allocation per frame" begin
        s = fresh_session(); g = add_test_grid!(s, Float32[i * j for i in 1:30, j in 1:20])
        m = Core.new_map!(s); lg = Core.add_layer!(s, m, g)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m; app.ui.layer_selected = lg
            wait_layers(app)
            mv = app.snap.maps[m]
            c = style_cache(app, mv, only(mv.layers))
            d = only(e.data for e in values(app.map.entries))
            @test c.zhint == auto_scale_hint(d.mean_gradient)
            lo, hi = Core.stretch_range(c.style, d.hist)
            @test c.legend == (UI.legend_number(lo), UI.legend_number(hi))
            @test style_cache(app, mv, only(mv.layers)) === c
            @test (@allocated style_cache(app, mv, only(mv.layers))) == 0
            app.config.grid_colours = "turbo"                   # a new key: built again
            @test style_cache(app, mv, only(mv.layers)).style.colours == "turbo"
        end
    end
end
