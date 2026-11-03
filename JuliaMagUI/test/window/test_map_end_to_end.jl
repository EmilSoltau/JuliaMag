using Test
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: THEME_LIGHT, THEME_DARK, LIGHT, DARK, ToolDialog

# A user's first map, in one window session: a new project, a line import and a grid import,
# Show on Map for both, the view moved and walked back, a Layer Style for each layer with undo
# and redo, a click that moves the cursor, the Map Drawing setting, and the project closed and
# opened again. Light first, dark from the Settings step on. Steps 2, 6 and 7 are also shot in
# the other theme, so each theme has shots of every kind of picture. Every step goes through the
# window as a user does it; only the native file and folder dialogs are replaced.

const MAP_E2E_SHOTS = joinpath(@__DIR__, "..", "shots")
const MAP_E2E_GRID = joinpath(@__DIR__, "..", "..", "..", "JuliaMagCore", "test", "data", "grids", "mag_4126.grd")

# A Geosoft XYZ file of 12 east-west lines of 80 points, 200 m apart, over the grid
# `mag_4126.grd` (85 by 160 cells of 200 m from 140 400, -4 400), with a MAG channel.
function map_e2e_xyz()
    path = joinpath(mktempdir(), "small.xyz")
    open(path, "w") do io
        println(io, "/ X Y FIDUCIAL MAG")
        for l in 1:12
            println(io, "Line ", 1000 + l)
            y = -2000.0 + 2500.0 * (l - 1)
            for r in 1:80
                x = 141_000.0 + 200.0 * (r - 1)
                mag = 50_000.0 + 100sin(x / 3000) * cos(y / 5000) + 0.1r
                println(io, x, " ", y, " ", r - 1, " ", round(mag; digits = 2))
            end
        end
    end
    return path
end

map_e2e_dialog(app) = (d = isempty(app.ui.dialogs) ? nothing : last(app.ui.dialogs); d isa ToolDialog ? d : nothing)

# Import `path` from the Import split button of ribbon tab `tab`, with the menu row `format`,
# and wait for the job to end and its item to be in the snapshot.
function map_e2e_import(ctx, app, picked, tab, format, path, kind)
    ctx.click("JuliaMag/tabs/" * tab)
    ctx.frames(2)
    picked[] = path
    ctx.click("JuliaMag/ribbon/More import formats")
    ctx.frames(1)
    ctx.click("//###menu/" * format)
    ctx.wait_until(() -> map_e2e_dialog(app) !== nothing; timeout = 10)
    ctx.click("//###dialog1/Import")
    ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
    ctx.wait_until(() -> any(it -> it.kind == kind, app.snap.items); timeout = 60)
    return first(it.id for it in app.snap.items if it.kind == kind)
end

# Right click the Data tree row of `item` and run Show on Map.
function map_e2e_show(ctx, app, item)
    ctx.click("JuliaMag/left/Data")
    ctx.frames(1)
    for folder in ("databases", "grids")
        folder in app.ui.expanded || ctx.click(tree_ref(folder, "chevron"))
        ctx.frames(1)
    end
    right_click(tree_ref(item))
    ctx.frames(2)
    ctx.click("//###menu/Show on Map")
    return nothing
end

# Is map `m` shown with every layer loaded and drawn in the current picture, by `mode`?
function map_e2e_drawn(app, m, mode = app.map.renderer.mode)
    ms = app.map
    r = ms.renderer
    return ms.plan_map == m && !isempty(ms.plan) && r.mode == mode &&
           all(p -> p.entry !== nothing && p.entry.data !== nothing && !p.entry.loading, ms.plan) &&
           (mode == UI.MAP_CPU || (r.gl !== nothing && isempty(r.gl.pending))) &&
           r.image.map == m && r.image.key == ms.scene.key
end

map_e2e_wait(ctx, app, m; mode = app.map.renderer.mode) =
    (ctx.wait_until(() -> map_e2e_drawn(app, m, mode); timeout = 30); ctx.frames(2); nothing)

map_e2e_full(app, m) = (st = app.map.views[m];
    UI.view_camera(app, app.snap.maps[m], UI.map_extent(app, app.snap.maps[m]), st.size...))

# The window point (device px) of world point `p` on the shown map.
function map_e2e_screen(app, p)
    st = app.map.views[app.ui.current_map]
    sx, sy = UI.world_to_screen(st.camera, st.size..., p...)
    return (app.map.view.x0 + sx, app.map.view.y0 + sy)
end

map_e2e_layer(app, m, kind) = only(l for l in app.snap.maps[m].layers if l.kind == kind)

function first_map(; scale::Real, size, sfx::AbstractString)
    shot(ctx, name) = (ctx.frames(3); ctx.shot(joinpath(MAP_E2E_SHOTS, "e2e-map-$name$sfx.png")))
    # A shot of map `m` in the other theme, drawn again in it, then back to the theme before.
    function other_theme(ctx, app, m, name, theme)
        back = app.config.theme
        ctx.on_render(w -> UI.run_command!(app, theme == THEME_DARK ? "ui.theme.dark" : "ui.theme.light"))
        map_e2e_wait(ctx, app, m)
        shot(ctx, name)
        ctx.on_render(w -> UI.run_command!(app, back == THEME_DARK ? "ui.theme.dark" : "ui.theme.light"))
        map_e2e_wait(ctx, app, m)
        @test app.config.theme == back
        return nothing
    end
    parent = mktempdir()
    xyz = map_e2e_xyz()
    with_test_app(; theme = THEME_LIGHT, scale, size, timeout = 300) do ctx
        app = ctx.app_state()
        picked = Ref("")
        app.pick_file = (; kw...) -> picked[]

        # 1. A new project; import small.xyz and the core's small grid.
        ctx.click("JuliaMag/tabs/Project")
        ctx.frames(2)
        ctx.click("Backstage/nav/New")
        ctx.frames(2)
        picked[] = parent
        ctx.click("Backstage/body/Browse...")
        ctx.frames(2)
        te.ItemClick("Backstage/body/##name")
        te.KeyCharsReplace("First Map")
        ctx.click("Backstage/body/Create Project")
        ctx.wait_until(() -> app.session !== nothing && app.snap !== nothing; timeout = 20)
        folder = joinpath(parent, "First Map")
        db = map_e2e_import(ctx, app, picked, "Database", "Geosoft XYZ...", xyz, Core.ITEM_DATABASE)
        grid = map_e2e_import(ctx, app, picked, "Grid and Image", "Geosoft or Surfer grid...", MAP_E2E_GRID,
            Core.ITEM_GRID)

        # 2. Show on Map for the database, then for the grid: one map, two layers, the grid below.
        map_e2e_show(ctx, app, db)
        ctx.wait_until(() -> !isempty(app.ui.current_map) && haskey(app.snap.maps, app.ui.current_map); timeout = 20)
        m = app.ui.current_map
        map_e2e_show(ctx, app, grid)
        ctx.wait_until(() -> length(app.snap.maps[m].layers) == 2; timeout = 20)
        @test length(app.snap.maps) == 1
        @test [l.kind for l in app.snap.maps[m].layers] == [:grid, :lines]
        @test map_e2e_layer(app, m, :lines).channel == "MAG"   # not the FIDUCIAL before it
        map_e2e_wait(ctx, app, m)
        st = app.map.views[m]
        @test st.camera == map_e2e_full(app, m) && st.fitted == st.camera
        @test UI.header_doc(app) == app.snap.maps[m].name == "Map 1"
        shot(ctx, "01-shown-light")
        other_theme(ctx, app, m, "01-shown-dark", THEME_DARK)

        # 3. Wheel zoom, a drag, Home and Previous Extent: the camera follows each.
        ctx.click("JuliaMag/tabs/Map")
        ctx.frames(2)
        w, h = st.size
        full = st.camera
        centre = (app.map.view.x0 + w / 2, app.map.view.y0 + h / 2)
        ctx.wheel(centre, 3)
        ctx.frames(2)
        @test st.camera.res < full.res
        ctx.wait_until(() -> st.before === nothing)
        zoomed = st.camera
        ctx.drag(centre, centre .+ (90, -60))
        ctx.frames(2)
        @test st.camera.res == zoomed.res && isapprox(st.camera.cx, zoomed.cx - 90 * zoomed.res; atol = zoomed.res)
        ctx.wait_until(() -> st.before === nothing)
        moved = st.camera
        map_e2e_wait(ctx, app, m)
        shot(ctx, "02-moved-light")
        ctx.key("Home")
        ctx.frames(2)
        @test st.camera == full
        ctx.click("JuliaMag/ribbon/Previous Extent")
        ctx.frames(2)
        @test st.camera == moved
        ctx.key("Home")
        ctx.frames(2)

        # 4. Layer Style: Viridis on the lines, Hillshade on the grid; Ctrl+Z twice undoes both.
        ld, lg = map_e2e_layer(app, m, :lines).id, map_e2e_layer(app, m, :grid).id
        ctx.click("JuliaMag/left/Layers")
        ctx.frames(2)
        te.ItemDoubleClick(join(("JuliaMag/left/layers", ld, "row"), "/"))
        ctx.frames(2)
        @test app.ui.right_active === :style
        ctx.click("JuliaMag/right/style/$ld/Colour table")
        ctx.frames(1)
        ctx.click("//###menu/Viridis")
        ctx.wait_until(() -> map_e2e_layer(app, m, :lines).style.colours == "viridis"; timeout = 10)
        ctx.click(join(("JuliaMag/left/layers", lg, "row"), "/"))
        ctx.frames(2)
        ctx.click("JuliaMag/right/style/$lg/Hillshade")
        ctx.wait_until(() -> map_e2e_layer(app, m, :grid).style.shade; timeout = 10)
        map_e2e_wait(ctx, app, m)
        shot(ctx, "03-styled-light")
        te.MouseMoveToPos(Float32.(centre))
        ctx.key("Ctrl+Z")
        ctx.wait_until(() -> !map_e2e_layer(app, m, :grid).style.shade; timeout = 10)
        ctx.key("Ctrl+Z")
        ctx.wait_until(() -> map_e2e_layer(app, m, :lines).style.colours != "viridis"; timeout = 10)
        @test length(app.snap.maps[m].layers) == 2
        map_e2e_wait(ctx, app, m)
        shot(ctx, "04-undone-light")
        ctx.key("Ctrl+Y")
        ctx.key("Ctrl+Y")
        ctx.wait_until(() -> map_e2e_layer(app, m, :lines).style.colours == "viridis" &&
                             map_e2e_layer(app, m, :grid).style.shade; timeout = 10)

        # 5. A click on a line: the cursor moves there, the marker shows, the status bar reads it.
        p = (149_000.0, 3000.0)   # L1003, fiducial 40
        at = map_e2e_screen(app, p) .+ (2, 1)
        ctx.mouse_to(at)
        te.MouseDown(0)
        te.MouseUp(0)
        ctx.wait_until(() -> app.snap.cursor !== nothing; timeout = 10)
        c = app.snap.cursor
        @test c.item == db && Core.line_name(c.line) == "L1003" && c.row == 41
        @test UI.cursor_target(app, app.snap.maps[m]) == p
        ctx.mouse_to(at .+ (0, 1))
        ctx.mouse_to(at)
        ctx.frames(2)
        @test occursin("L1003 fid 40", UI.map_status(app)[3])
        path = shot(ctx, "05-cursor-light")
        img = PNGFiles.load(path)
        s = app.window.scale
        cx, cy = round.(Int, map_e2e_screen(app, p))
        ring = UI.px(s, UI.MARKER_SIZE / 2) - UI.px(s, UI.MARKER_RING) / 2
        @test near(rgb255(img[cy+1, cx+round(Int, ring)+1]), rgb255(LIGHT.accent); tol = 12)

        # 6. Dark, then Map Drawing: CPU and Auto; the map draws each time.
        ctx.click("JuliaMag/tabs/Settings")
        ctx.frames(2)
        ctx.click("JuliaMag/ribbon/Dark Theme")
        ctx.frames(2)
        @test app.config.theme == THEME_DARK
        ctx.click("JuliaMag/ribbon/Map Drawing: CPU")
        n = app.map.renderer.full_draws
        map_e2e_wait(ctx, app, m; mode = UI.MAP_CPU)
        @test app.map.renderer.full_draws > n && app.config.map_drawing == "cpu"
        shot(ctx, "06-cpu-dark")
        other_theme(ctx, app, m, "06-cpu-light", THEME_LIGHT)
        ctx.click("JuliaMag/ribbon/Map Drawing: Auto")
        n = app.map.renderer.full_draws
        map_e2e_wait(ctx, app, m; mode = UI.MAP_GL)
        @test app.map.renderer.full_draws > n
        shot(ctx, "06-auto-dark")
        other_theme(ctx, app, m, "06-auto-light", THEME_LIGHT)

        # 7. Close the project and open it again: the map, its layers and their styles are
        # there, and the map shows at full extent.
        ctx.click("JuliaMag/tabs/Project")
        ctx.frames(2)
        ctx.click("Backstage/nav/Close")
        ctx.wait_until(() -> app.session === nothing && app.switching === nothing; timeout = 30)
        ctx.frames(2)
        ref = "Backstage/body/recent/" * ref_part(realpath(folder))
        ctx.wait_until(() -> te.ItemExists(ref); timeout = 10)
        ctx.click(ref)
        ctx.wait_until(() -> app.session !== nothing && app.snap !== nothing && !isempty(app.snap.maps); timeout = 30)
        @test app.ui.current_map == m
        @test [l.kind for l in app.snap.maps[m].layers] == [:grid, :lines]
        @test map_e2e_layer(app, m, :lines).style.colours == "viridis"
        @test map_e2e_layer(app, m, :grid).style.shade
        map_e2e_wait(ctx, app, m)
        st = app.map.views[m]
        @test st.camera == map_e2e_full(app, m) && isempty(st.history.past)
        shot(ctx, "07-reopened-dark")
        other_theme(ctx, app, m, "07-reopened-light", THEME_LIGHT)
        @test isempty(app.draw_errors)
    end
    return nothing
end

window_testset("map end to end") do
    mkpath(MAP_E2E_SHOTS)
    @testset "a first map at scale 1" begin
        first_map(; scale = 1f0, size = (1480, 920), sfx = "")
    end
    @testset "a first map at scale 1.5" begin
        first_map(; scale = 1.5f0, size = (2220, 1380), sfx = "-1.5x")
    end
end
