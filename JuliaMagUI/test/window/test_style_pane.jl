using Test
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: THEME_LIGHT, THEME_DARK, LIGHT, DARK

const STYLE_SHOTS = joinpath(@__DIR__, "..", "shots")

# The prototype's Map 1: "Kangaroo Hills 2024" coloured by MAG over the grid "KH2024_MAG_IGRF".
# A second map holds a layer whose database was removed. Returns the session and the ids.
function style_project()
    s = fresh_session()
    db = survey_database!(s; lines = 20, rows = 100)
    Core.rename_item!(s, db, "Kangaroo Hills 2024")
    A = Float32[100sin(i / 17) * cos(j / 23) + 0.5i for i in 1:100, j in 1:196]
    g = add_test_grid!(s, A; name = "KH2024_MAG_IGRF")
    m = Core.new_map!(s; name = "Map 1")
    lg = Core.add_layer!(s, m, g)
    ld = Core.add_layer!(s, m, db)
    gone = survey_database!(s); Core.rename_item!(s, gone, "Removed survey")
    c = Core.new_map!(s; name = "Checks")
    cgone = Core.add_layer!(s, c, gone)
    Core.remove_item!(s, gone)
    return s, (; db, g, m, lg, ld, c, cgone)
end

style_ref(parts...) = join(("JuliaMag/right/style", parts...), "/")
style_layer(app, m, id) = only(l for l in app.snap.maps[m].layers if l.id == id)
style_undo_depth(s) = lock(() -> length(s.undo_stack), s.lock)
map_loaded(app) = !isempty(app.map.plan) && all(p -> p.entry !== nothing && p.entry.data !== nothing, app.map.plan)
style_grid_draw(app) = only(d for d in app.map.scene.layers if d isa UI.GridDraw)
style_line_draw(app) = only(d for d in app.map.scene.layers if d isa UI.LineDraw)

# The number of pixel columns of box `b` of a shot where a pixel differs from its left
# neighbour in some row. Square cells change only at their edges, so few columns do.
function edge_columns(path, b::UI.Box)
    img = PNGFiles.load(path)
    rows = round(Int, b.y0)+1:round(Int, b.y1)
    cols = round(Int, b.x0)+2:round(Int, b.x1)
    diff(p, q) = abs(Float32(p.r) - Float32(q.r)) + abs(Float32(p.g) - Float32(q.g)) + abs(Float32(p.b) - Float32(q.b))
    return count(x -> any(y -> diff(img[y, x], img[y, x-1]) > 0.02f0, rows), cols)
end

window_testset("layer style pane") do
    s, ids = style_project()
    with_project_app(s; timeout = 300) do ctx, app
        @testset "a double click on a layer and its context menu open the pane" begin
            ctx.click("JuliaMag/left/Layers")
            ctx.wait_until(() -> map_loaded(app))
            ctx.frames(2)
            te.ItemDoubleClick(join(("JuliaMag/left/layers", ids.ld, "row"), "/"))
            ctx.frames(2)
            @test app.ui.right_active === :style && app.ui.layer_selected == ids.ld
            @test te.ItemExists(style_ref(ids.ld, "Colour table")) && te.ItemExists(style_ref(ids.ld, "Colour by"))
            ctx.click("JuliaMag/right/Close Layer Style")
            ctx.frames(1)
            @test app.ui.right_active === :none
            right_click(join(("JuliaMag/left/layers", ids.ld, "row"), "/"))
            ctx.frames(1)
            ctx.click("//###menu/Layer Style...")
            ctx.frames(2)
            @test app.ui.right_active === :style
        end

        @testset "choosing Viridis recolours the map in one undo step" begin
            n = style_undo_depth(s)
            ctx.click(style_ref(ids.ld, "Colour table"))
            ctx.frames(1)
            @test te.ItemExists("//###menu/Viridis")
            ctx.shot(joinpath(STYLE_SHOTS, "style-menu-light.png"))
            ctx.click("//###menu/Viridis")
            ctx.wait_until(() -> style_layer(app, ids.m, ids.ld).style.colours == "viridis" && app.ui.style_preview === nothing)
            ctx.frames(2)
            @test style_line_draw(app).lut == UI.lut_rgba!(UInt8[], "viridis", false)
            @test style_undo_depth(s) == n + 1 && lock(() -> s.history[end].command, s.lock) == "map.set_layer"
        end

        @testset "each stretch shows its own fields; a typed minimum is one step" begin
            ctx.click(style_ref(ids.ld, "Stretch", "linear"))
            ctx.wait_until(() -> style_layer(app, ids.m, ids.ld).style.stretch == :linear)
            ctx.frames(2)
            @test te.ItemExists(style_ref(ids.ld, "##min")) && te.ItemExists(style_ref(ids.ld, "##max"))
            @test !te.ItemExists(style_ref(ids.ld, "##clip_low"))
            ctx.shot(joinpath(STYLE_SHOTS, "style-linear-light.png"))
            n = style_undo_depth(s)
            ctx.type(style_ref(ids.ld, "##min"), "120")      # the engine presses Enter after it
            ctx.wait_until(() -> style_layer(app, ids.m, ids.ld).style.min == 120.0)
            ctx.frames(2)
            @test style_undo_depth(s) == n + 1 && style_line_draw(app).lo == 120f0
            ctx.click(style_ref(ids.ld, "Stretch", "clip"))
            ctx.wait_until(() -> style_layer(app, ids.m, ids.ld).style.stretch == :clip)
            ctx.frames(2)
            @test te.ItemExists(style_ref(ids.ld, "##clip_low")) && !te.ItemExists(style_ref(ids.ld, "##min"))
            ctx.shot(joinpath(STYLE_SHOTS, "style-clip-light.png"))
            ctx.type(style_ref(ids.ld, "##clip_high"), "70")      # clamped to 49
            ctx.wait_until(() -> style_layer(app, ids.m, ids.ld).style.clip_high == 49.0)
            ctx.click(style_ref(ids.ld, "Stretch", "histeq"))
            ctx.wait_until(() -> style_layer(app, ids.m, ids.ld).style.stretch == :histeq)
            ctx.frames(2)
            @test !te.ItemExists(style_ref(ids.ld, "##clip_low")) && !te.ItemExists(style_ref(ids.ld, "##min"))
            ctx.shot(joinpath(STYLE_SHOTS, "style-histeq-light.png"))
        end

        @testset "a grid layer: its grid's colours greyed; Hillshade and a live sun in one step" begin
            ctx.click(join(("JuliaMag/left/layers", ids.lg, "row"), "/"))
            ctx.frames(2)
            @test te.ItemExists(style_ref(ids.lg, "Use the grid's default colours"))
            ctx.shot(joinpath(STYLE_SHOTS, "style-grid-default-light.png"))
            @test !te.ItemExists(style_ref(ids.lg, "Sun inclination"))
            ctx.click(style_ref(ids.lg, "Hillshade"))
            ctx.wait_until(() -> style_layer(app, ids.m, ids.lg).style.shade)
            ctx.frames(2)
            @test !style_layer(app, ids.m, ids.lg).own_style && style_grid_draw(app).shade
            # A blank vertical scale: the hint gives the automatic value from the layer's data.
            d = style_grid_draw(app).data
            @test app.ui.style_pane.cache.zhint == "Auto: 2.5 over the mean gradient = " * UI.sig_num(2.5 / d.mean_gradient)
            @test haskey(app.ui.style_pane.boxes, "zfactor hint")
            # Drag the inclination: the map redraws while dragging, and the release is one step.
            n = style_undo_depth(s)
            track = app.ui.style_pane.boxes["inclination"]
            y = UI.centre_y(track)
            x45 = track.x0 + 6 + (UI.width(track) - 12) / 2
            te.MouseMoveToPos((Float32(round(x45)), y))
            te.MouseDown(0)
            keys = UInt64[]
            for x in range(x45, track.x0 + 6 + (UI.width(track) - 12) * 0.2; length = 5)
                te.MouseMoveToPos((Float32(round(x)), y))
                ctx.frames(1)
                push!(keys, app.map.scene.key)
            end
            p = app.ui.style_preview
            @test p !== nothing && p[1] == ids.lg && 10 < p[2].inclination < 30
            @test style_grid_draw(app).sun == Float32.(Core.sun_vector(p[2].inclination, 45))
            @test length(unique(keys)) >= 3                       # it drew while dragging
            @test style_undo_depth(s) == n                       # nothing is set while dragging
            ctx.shot(joinpath(STYLE_SHOTS, "style-drag-light.png"))
            te.MouseUp(0)
            ctx.wait_until(() -> app.ui.style_preview === nothing)
            @test style_layer(app, ids.m, ids.lg).style.inclination == p[2].inclination
            @test style_undo_depth(s) == n + 1 && !style_layer(app, ids.m, ids.lg).own_style
            ctx.frames(2)
            ctx.shot(joinpath(STYLE_SHOTS, "style-grid-shade-light.png"))
            # Esc during a drag sets nothing and ends the live sun.
            inc = style_layer(app, ids.m, ids.lg).style.inclination
            track = app.ui.style_pane.boxes["declination"]
            y = UI.centre_y(track)
            x = track.x0 + 6 + (UI.width(track) - 12) * 45 / 360
            te.MouseMoveToPos((Float32(round(x)), y))
            te.MouseDown(0)
            te.MouseMoveToPos((Float32(round(x + 60)), y))
            ctx.frames(2)
            @test app.ui.style_preview !== nothing && app.ui.style_preview[2].declination > 100
            ctx.key("Escape")
            te.MouseUp(0)
            ctx.frames(3)
            @test app.ui.style_preview === nothing && style_undo_depth(s) == n + 1
            @test style_layer(app, ids.m, ids.lg).style.declination == 45.0
            @test style_grid_draw(app).sun == Float32.(Core.sun_vector(inc, 45))
            # The vertical scale: a text that is not a number, or not above 0, is refused with a
            # red hint; a number is one step, and the auto hint goes.
            te.MouseMoveToPos((700f0, 600f0))
            ctx.type(style_ref(ids.lg, "##zfactor"), "steep")
            ctx.frames(2)
            @test app.ui.style_pane.errors["zfactor"] == "Enter a number." && style_undo_depth(s) == n + 1
            ctx.type(style_ref(ids.lg, "##zfactor"), "0")
            ctx.frames(2)
            @test app.ui.style_pane.errors["zfactor"] == "Enter a number above 0, or leave it blank for auto."
            ctx.shot(joinpath(STYLE_SHOTS, "style-scale-error-light.png"))
            ctx.type(style_ref(ids.lg, "##zfactor"), "12.5")
            ctx.wait_until(() -> style_layer(app, ids.m, ids.lg).style.zfactor == 12.5)
            ctx.frames(2)
            @test isempty(app.ui.style_pane.errors) && !haskey(app.ui.style_pane.boxes, "zfactor hint")
            @test style_grid_draw(app).zfactor == 12.5f0 && style_undo_depth(s) == n + 2
            ctx.type(style_ref(ids.lg, "##zfactor"), "")       # blank: auto again
            ctx.wait_until(() -> isnan(style_layer(app, ids.m, ids.lg).style.zfactor))
            ctx.frames(2)
            @test haskey(app.ui.style_pane.boxes, "zfactor hint")
        end

        @testset "own colours start from the grid's style; Nearest shows square cells" begin
            ctx.click(style_ref(ids.lg, "Use the grid's default colours"))
            ctx.wait_until(() -> style_layer(app, ids.m, ids.lg).own_style)
            l = style_layer(app, ids.m, ids.lg)
            @test l.style.colours == "geosoft" && l.style.shade
            ctx.click(style_ref(ids.lg, "Hillshade"))
            ctx.wait_until(() -> !style_layer(app, ids.m, ids.lg).style.shade)
            ctx.click(style_ref(ids.lg, "Cells", "nearest"))
            ctx.wait_until(() -> style_layer(app, ids.m, ids.lg).style.resample == :nearest)
            # Zoom in until a cell is 24 device pixels wide.
            ctx.on_render(w -> (st = app.map.views[ids.m]; st.camera = UI.Camera(st.camera.cx, st.camera.cy, 10 / 24)))
            ctx.frames(3)
            te.MouseMoveToPos((5f0, 5f0))
            ctx.frames(2)
            v = app.map.view
            box = UI.Box(((v.x0 + v.x1) / 2) - 100, UI.centre_y(v) - 100, ((v.x0 + v.x1) / 2) + 100, UI.centre_y(v) + 100)
            near_path = ctx.shot(joinpath(STYLE_SHOTS, "style-nearest-light.png"))
            ctx.click(style_ref(ids.lg, "Cells", "bilinear"))
            ctx.wait_until(() -> style_layer(app, ids.m, ids.lg).style.resample == :bilinear)
            te.MouseMoveToPos((5f0, 5f0))
            ctx.frames(3)
            smooth_path = ctx.shot(joinpath(STYLE_SHOTS, "style-bilinear-light.png"))
            @test edge_columns(near_path, box) <= 12 < edge_columns(smooth_path, box)
            ctx.on_render(w -> UI.full_extent_now!(app))
            ctx.frames(2)
        end

        @testset "no layer, a removed item and another map say so" begin
            ctx.on_render(w -> (app.ui.layer_selected = ""))
            ctx.frames(2)
            @test UI.style_message(app) == "Select a layer in the Layers tab to change its style."
            ctx.shot(joinpath(STYLE_SHOTS, "style-none-light.png"))
            ctx.on_render(w -> (UI.open_map!(app, ids.c); app.ui.layer_selected = ids.cgone))
            ctx.frames(3)
            @test UI.style_message(app) == "The layer's item is not in the project."
            ctx.shot(joinpath(STYLE_SHOTS, "style-missing-light.png"))
            @test isempty(app.draw_errors)
        end
    end

    # The pane for a line layer and a grid layer in both themes, at scale 1 and 1.5.
    for (theme, name) in ((THEME_LIGHT, "light"), (THEME_DARK, "dark")), scale in (1f0, 1.5f0)
        sfx = scale == 1 ? "" : "-1.5x"
        s2, ids2 = style_project()
        with_project_app(s2; theme, scale) do ctx, app
            ctx.click("JuliaMag/left/Layers")
            ctx.on_render(w -> (app.ui.layer_selected = ids2.ld; UI.open_layer_style!(app)))
            ctx.wait_until(() -> map_loaded(app))
            te.MouseMoveToPos((700f0, 600f0))
            ctx.frames(3)
            ctx.shot(joinpath(STYLE_SHOTS, "style-lines-$name$sfx.png"))
            ctx.on_render(w -> (app.ui.layer_selected = ids2.lg))
            ctx.frames(3)
            ctx.shot(joinpath(STYLE_SHOTS, "style-grid-$name$sfx.png"))
            @test isempty(app.draw_errors)
        end
    end
end
