using Test
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Camera, THEME_LIGHT, THEME_DARK, LIGHT, DARK

const MAP_TAB_SHOTS = joinpath(@__DIR__, "..", "shots")

# The full extent camera of the shown map: inside the coordinate bands, clear of the legends.
function shown_full_camera(app)
    st = app.map.views[app.ui.current_map]
    mv = app.snap.maps[app.ui.current_map]
    return UI.view_camera(app, mv, UI.map_extent(app, mv), st.size...)
end

window_testset("map commands") do
    s = fresh_session()
    db = survey_database!(s; lines = 20, rows = 100)
    with_project_app(s; timeout = 300) do ctx, app
        @testset "the Map tab shows its three groups" begin
            ctx.click("JuliaMag/tabs/Map")
            te.MouseMoveToPos((700f0, 600f0))
            ctx.frames(2)
            @test app.ui.tab == "Map"
            @test [g.name for g in app.ui.ribbon_cache.groups] == ["Map", "Navigate", "Display"]
            for name in ("New Map", "Add Item to Map", "Remove Layer", "Full Extent", "Zoom In", "Zoom Out",
                    "Zoom to Layer", "Previous Extent", "Next Extent", "Go To Cursor", "Layer Style", "Hillshade",
                    "Colour Bars", "Line Labels")
                @test te.ItemExists("JuliaMag/ribbon/" * name)
            end
            ctx.shot(joinpath(MAP_TAB_SHOTS, "ribbon-map-no-map-light.png"))
        end

        @testset "New Map makes Map 1 and shows the empty map" begin
            ctx.click("JuliaMag/ribbon/New Map")
            ctx.wait_until(() -> haskey(app.snap.maps, app.ui.current_map))
            mv = app.snap.maps[app.ui.current_map]
            @test mv.name == "Map 1" && isempty(mv.layers)
            ctx.frames(2)
            @test UI.shown_map(app) === mv && !haskey(app.map.views, mv.id)   # the empty map, no camera
            ctx.shot(joinpath(MAP_TAB_SHOTS, "map-new-empty-light.png"))
        end
        m = app.ui.current_map

        @testset "Show on Map from a database row's menu adds a layer, and the map shows it" begin
            ctx.click("JuliaMag/left/Data")
            push!(app.ui.expanded, "databases")
            ctx.frames(1)
            right_click(tree_ref(db))
            ctx.click("//###menu/Show on Map")
            ctx.wait_until(() -> length(app.snap.maps[m].layers) == 1; timeout = 20)
            ctx.wait_until(() -> (st = get(app.map.views, m, nothing); st !== nothing && st.camera !== nothing); timeout = 20)
            ctx.frames(2)
            @test app.ui.current_map == m && app.ui.layer_selected == only(app.snap.maps[m].layers).id
            st = app.map.views[m]
            @test st.camera == shown_full_camera(app)   # the first layer fits once its data is in
            @test isempty(st.history.past)
        end

        @testset "Home fits the extent; Previous and Next Extent walk the history" begin
            st = app.map.views[m]
            full = st.camera
            te.MouseMoveToPos((700f0, 600f0))
            ctx.click("JuliaMag/ribbon/Zoom In")
            ctx.frames(1)
            zoomed = st.camera
            @test zoomed.res ≈ full.res / 2 && st.history.past == [full]
            # One press of Home: one fit and one history entry (the key is the command's only).
            ctx.key("Home")
            ctx.frames(2)
            @test st.camera == full && st.history.past == [full, zoomed]
            ctx.click("JuliaMag/ribbon/Previous Extent")
            @test st.camera == zoomed
            ctx.click("JuliaMag/ribbon/Previous Extent")
            @test st.camera == full && isempty(st.history.past)
            @test UI.find_command(app, "map.prev_extent").enabled(app) == "There is no earlier extent."
            ctx.click("JuliaMag/ribbon/Next Extent")
            @test st.camera == zoomed
            ctx.click("JuliaMag/ribbon/Next Extent")
            @test st.camera == full && isempty(st.history.future)
        end

        @testset "Add Item opens a menu of the project's items" begin
            ctx.click("JuliaMag/ribbon/Add Item to Map")
            ctx.frames(1)
            @test te.ItemExists("//###menu/" * ref_part(UI.item_name(app.snap, db)))
            te.MouseMove("//###menu/" * ref_part(UI.item_name(app.snap, db)))
            ctx.frames(1)
            ctx.shot(joinpath(MAP_TAB_SHOTS, "ribbon-map-menu-light.png"))
            # Home moves the menu's highlight only: no fit and no history entry (T12 review).
            st = app.map.views[m]
            st.camera = Camera(st.camera.cx, st.camera.cy, st.camera.res / 4)
            cam, n = st.camera, length(st.history.past)
            ctx.key("Home")
            ctx.frames(1)
            @test app.ui.menu isa UI.OpenMenu && st.camera == cam && length(st.history.past) == n
            ctx.key("Escape")
            ctx.frames(1)
            @test app.ui.menu === nothing
            # Run from the command search (or any other tab), it shows the Map tab and opens
            # the menu at its button.
            ctx.click("JuliaMag/tabs/Database")
            ctx.on_render(w -> UI.run_command!(app, "map.add_item"))
            ctx.frames(2)
            @test app.ui.tab == "Map" && app.ui.menu isa UI.OpenMenu && app.ui.menu.owner == "map.add_item"
            ctx.key("Escape")
        end

        @testset "Ctrl+Z after Show on Map takes the layer out" begin
            te.MouseMoveToPos((700f0, 600f0))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> isempty(app.snap.maps[m].layers))
            @test haskey(app.snap.maps, m)   # the map stays; one more Ctrl+Z takes it out
            @test isempty(app.draw_errors)
        end
    end

    # The Map tab in both themes at scale 1 and 1.5, with a map shown, for the pixel review
    # against the prototype (proto-ribbon-map-<theme>.png).
    for (theme, name) in ((THEME_LIGHT, "light"), (THEME_DARK, "dark")), scale in (1f0, 1.5f0)
        sfx = scale == 1 ? "" : "-1.5x"
        s2 = fresh_session()
        db2 = survey_database!(s2; lines = 20, rows = 100)
        m2 = Core.new_map!(s2)
        Core.add_layer!(s2, m2, db2)
        with_project_app(s2; theme, scale) do ctx, app
            @test app.ui.current_map == m2   # opening a project shows its first map
            ctx.click("JuliaMag/tabs/Map")
            te.MouseMoveToPos((700f0, 600f0))
            ctx.frames(2)
            ctx.shot(joinpath(MAP_TAB_SHOTS, "ribbon-map-$name$sfx.png"))
        end
    end
end
