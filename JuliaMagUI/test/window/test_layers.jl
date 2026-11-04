using Test
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: THEME_LIGHT, THEME_DARK, LIGHT, DARK

const LAYERS_SHOTS = joinpath(@__DIR__, "..", "shots")

# The prototype's Map 1: "Kangaroo Hills 2024" coloured by MAG over the grid "KH2024_MAG_IGRF" at
# 85 %. A second map "Checks" has a layer of each state: lines, a hidden grid, a database that was
# removed, a database whose folder is gone and one whose colour channel was deleted. A third map
# is empty. Returns the session and the ids.
function layers_project()
    s = fresh_session()
    db = survey_database!(s; lines = 20, rows = 100)
    Core.rename_item!(s, db, "Kangaroo Hills 2024")
    A = Float32[100sin(i / 17) * cos(j / 23) + 0.5i for i in 1:100, j in 1:196]
    g = add_test_grid!(s, A; name = "KH2024_MAG_IGRF")
    m = Core.new_map!(s; name = "Map 1")
    lg = Core.add_layer!(s, m, g)
    ld = Core.add_layer!(s, m, db)
    Core.set_layer!(s, m, lg; opacity = 0.85)
    gone = survey_database!(s); Core.rename_item!(s, gone, "Removed survey")
    lost = survey_database!(s); Core.rename_item!(s, lost, "Lost folder")
    broken = survey_database!(s); Core.rename_item!(s, broken, "North block")
    c = Core.new_map!(s; name = "Checks")
    cg = Core.add_layer!(s, c, g)
    Core.set_layer!(s, c, cg; visible = false)
    cgone = Core.add_layer!(s, c, gone); clost = Core.add_layer!(s, c, lost); cbroken = Core.add_layer!(s, c, broken)
    cd = Core.add_layer!(s, c, db)
    Core.remove_item!(s, gone)
    rm(joinpath(s.project.folder, "databases", lost); recursive = true)
    Core.delete_channel!(s, broken, "MAG")
    e = Core.new_map!(s; name = "Empty")
    return s, (; db, g, m, lg, ld, c, cg, cgone, clost, cbroken, cd, e)
end

layers_ref(parts...) = join(("JuliaMag/left/layers", parts...), "/")
layer_order(app, m) = [l.id for l in app.snap.maps[m].layers]
undo_depth(s) = lock(() -> length(s.undo_stack), s.lock)

# The pixels of box `b` (device px) of a shot, as RGB triples.
function shot_pixels(path, b::UI.Box)
    img = PNGFiles.load(path)
    rows = round(Int, b.y0)+1:round(Int, b.y1)
    cols = round(Int, b.x0)+1:round(Int, b.x1)
    return [(Float32(c.r), Float32(c.g), Float32(c.b)) for c in img[rows, cols]]
end

window_testset("layers tab") do
    s, ids = layers_project()
    with_project_app(s; timeout = 300) do ctx, app
        @testset "the Layers tab lists the shown map's layers, top first" begin
            @test app.ui.current_map == ids.m
            ctx.click("JuliaMag/left/Layers")
            ctx.wait_until(() -> !isempty(app.map.plan) && all(p -> p.entry !== nothing && p.entry.data !== nothing, app.map.plan))
            ctx.frames(2)
            @test app.ui.left_tab === :layers
            @test te.ItemExists(layers_ref(ids.ld, "row")) && te.ItemExists(layers_ref(ids.lg, "row"))
            rows = app.ui.layer_boxes
            @test rows[ids.ld].y0 < rows[ids.lg].y0               # the top layer is the first row
            ctx.click(layers_ref(ids.ld, "row"))
            @test app.ui.layer_selected == ids.ld
            @test te.ItemExists(layers_ref(ids.ld, "Opacity"))   # the selected layer's slider
            @test !te.ItemExists(layers_ref(ids.lg, "Opacity"))
        end

        @testset "unticking a layer hides it on the map; Ctrl+Z shows it again" begin
            ctx.click(layers_ref(ids.ld, "check"))
            ctx.wait_until(() -> !app.snap.maps[ids.m].layers[2].visible)
            ctx.frames(2)
            @test [p.layer.id for p in app.map.plan] == [ids.lg]
            @test app.ui.layer_selected == ids.ld               # the box does not change the selection
            te.MouseMoveToPos((700f0, 600f0))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> app.snap.maps[ids.m].layers[2].visible)
            ctx.frames(2)
            @test [p.layer.id for p in app.map.plan] == [ids.lg, ids.ld]
        end

        @testset "dragging the line layer below the grid changes the order and the map" begin
            @test layer_order(app, ids.m) == [ids.lg, ids.ld]
            from = app.ui.layer_boxes[ids.ld]
            to = app.ui.layer_boxes[ids.lg]
            n = undo_depth(s)
            # Down to the lower half of the grid's rows: the drop goes under it.
            ctx.drag((from.x0 + 120, UI.centre_y(from)), (to.x0 + 120, to.y1 + 14); steps = 8)
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.ld, ids.lg])
            ctx.frames(2)
            @test [p.layer.id for p in app.map.plan] == [ids.ld, ids.lg]   # the map draws the lines first
            @test undo_depth(s) == n + 1 && app.ui.drag === nothing
            @test app.ui.layer_boxes[ids.lg].y0 < app.ui.layer_boxes[ids.ld].y0
            # A drag that ends where it started moves nothing.
            b = app.ui.layer_boxes[ids.ld]
            ctx.drag((b.x0 + 120, UI.centre_y(b)), (b.x0 + 120, UI.centre_y(b) + 9); steps = 4)
            ctx.frames(3)
            @test undo_depth(s) == n + 1 && layer_order(app, ids.m) == [ids.ld, ids.lg]
            # Esc while dragging drops nothing.
            te.MouseMoveToPos((b.x0 + 120, UI.centre_y(b)))
            te.MouseDown(0)
            top = app.ui.layer_boxes[ids.lg]
            te.MouseMoveToPos((b.x0 + 120, UI.centre_y(b) - 20))
            te.MouseMoveToPos((top.x0 + 120, top.y0 + 4))
            ctx.frames(1)
            @test app.ui.drag isa UI.LayerDrag
            ctx.shot(joinpath(LAYERS_SHOTS, "layers-drag-light.png"))
            ctx.key("Escape")
            te.MouseUp(0)
            ctx.frames(3)
            @test undo_depth(s) == n + 1 && layer_order(app, ids.m) == [ids.ld, ids.lg]
            te.MouseMoveToPos((700f0, 600f0))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.lg, ids.ld])
        end

        @testset "an opacity drag draws live and makes exactly one undo step" begin
            ctx.click(layers_ref(ids.ld, "row"))
            ctx.frames(1)
            n = undo_depth(s)
            track = app.ui.layer_boxes["opacity"]
            y = UI.centre_y(track)
            te.MouseMoveToPos((track.x1 - 6, y))              # the thumb, at 100 %
            te.MouseDown(0)
            for x in range(track.x1 - 6, track.x0 + (UI.width(track)) / 2; length = 6)
                te.MouseMoveToPos((Float32(round(x)), y))
            end
            ctx.frames(2)
            p = app.ui.opacity_preview
            @test p !== nothing && p[1] == ids.ld && 0.4 < p[2] < 0.6
            line = only(d for d in app.map.scene.layers if d isa UI.LineDraw)
            @test line.opacity ≈ Float32(p[2])                # the map draws the dragged value
            @test undo_depth(s) == n                         # nothing is set while dragging
            te.MouseUp(0)
            ctx.wait_until(() -> app.ui.opacity_preview === nothing)
            v = app.snap.maps[ids.m].layers[2].opacity
            @test 0.4 < v < 0.6 && undo_depth(s) == n + 1
            ctx.frames(2)
            @test only(d for d in app.map.scene.layers if d isa UI.LineDraw).opacity ≈ Float32(v)
            te.MouseMoveToPos((700f0, 600f0))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> app.snap.maps[ids.m].layers[2].opacity == 1.0)
            @test undo_depth(s) == n
        end

        @testset "Remove Layer, then Ctrl+Z puts it back" begin
            ctx.click(layers_ref(ids.lg, "row"))
            ctx.click(layers_ref("Remove Layer"))
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.ld])
            ctx.frames(3)
            @test !haskey(app.ui.layer_boxes, ids.lg) && app.ui.layer_selected == ""
            te.MouseMoveToPos((700f0, 600f0))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.lg, ids.ld])
            ctx.frames(2)
            @test haskey(app.ui.layer_boxes, ids.lg) && te.ItemExists(layers_ref(ids.lg, "row"))
        end

        @testset "a drag whose row goes away ends; a drop outside the list moves nothing (T13 review)" begin
            # Remove the grid and bring it back, so Ctrl+Y takes it out again mid drag.
            ctx.click(layers_ref(ids.lg, "row"))
            ctx.click(layers_ref("Remove Layer"))
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.ld])
            te.MouseMoveToPos((700f0, 600f0))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.lg, ids.ld])
            ctx.frames(2)
            b = app.ui.layer_boxes[ids.lg]
            te.MouseMoveToPos((b.x0 + 120, UI.centre_y(b)))
            te.MouseDown(0)
            te.MouseMoveToPos((b.x0 + 120, UI.centre_y(b) + 20))
            te.MouseMoveToPos((b.x0 + 120, UI.centre_y(b) + 40))
            ctx.frames(1)
            @test app.ui.drag isa UI.LayerDrag
            ctx.key("Ctrl+Y")
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.ld])
            ctx.frames(2)
            te.MouseUp(0)
            ctx.frames(2)
            @test app.ui.drag === nothing
            # The hover fill is back on the row under the mouse.
            r = app.ui.layer_boxes[ids.ld]
            te.MouseMoveToPos((r.x0 + 150, UI.centre_y(r)))
            ctx.frames(2)
            path = ctx.shot(joinpath(LAYERS_SHOTS, "layers-hover-light.png"))
            fill = UI.Box(r.x0 + 200, r.y0 + 4, r.x0 + 230, r.y1 - 4)
            @test count(p -> near(p, LIGHT.hover; tol = 0.01), shot_pixels(path, fill)) > 100
            te.MouseMoveToPos((700f0, 600f0))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.lg, ids.ld])
            ctx.frames(2)
            # Dropped over the map: no move.
            n = undo_depth(s)
            b = app.ui.layer_boxes[ids.ld]
            ctx.drag((b.x0 + 120, UI.centre_y(b)), (700, UI.centre_y(b) + 60); steps = 8)
            ctx.frames(3)
            @test undo_depth(s) == n && layer_order(app, ids.m) == [ids.lg, ids.ld] && app.ui.drag === nothing
        end

        @testset "the slider: a press without a move changes nothing; arrow keys step 1 %" begin
            ctx.click(layers_ref(ids.ld, "row"))
            ctx.frames(1)
            n = undo_depth(s)
            track = app.ui.layer_boxes["opacity"]
            y = UI.centre_y(track)
            te.MouseMoveToPos((track.x1 - 10, y))              # on the thumb, left of its centre
            te.MouseDown(0)
            ctx.frames(2)
            te.MouseUp(0)
            ctx.frames(3)
            @test undo_depth(s) == n && app.snap.maps[ids.m].layers[2].opacity == 1.0
            @test app.ui.opacity_preview === nothing
            ctx.key("Left")
            ctx.wait_until(() -> app.snap.maps[ids.m].layers[2].opacity == 0.99)
            ctx.key("Left")
            ctx.wait_until(() -> app.snap.maps[ids.m].layers[2].opacity == 0.98)
            @test undo_depth(s) == n + 2                        # one undo step per press
            ctx.key("Right")
            ctx.wait_until(() -> app.snap.maps[ids.m].layers[2].opacity == 0.99)
            te.MouseMoveToPos((700f0, 600f0))
            for _ in 1:3
                ctx.key("Ctrl+Z")
            end
            ctx.wait_until(() -> app.snap.maps[ids.m].layers[2].opacity == 1.0)
        end

        @testset "the toolbar runs the map commands; the context menu too" begin
            ctx.click(layers_ref(ids.ld, "row"))
            ctx.click(layers_ref("Move Down"))
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.ld, ids.lg])
            right_click(layers_ref(ids.ld, "row"))
            ctx.frames(1)
            for name in ("Zoom to Layer", "Layer Style...", "Move Up", "Move Down", "Remove Layer")
                @test te.ItemExists("//###menu/" * name)
            end
            ctx.click("//###menu/Move Up")
            ctx.wait_until(() -> layer_order(app, ids.m) == [ids.lg, ids.ld])
            ctx.click(layers_ref("Add Item to Map"))
            ctx.frames(1)
            @test app.ui.menu isa UI.OpenMenu && te.ItemExists("//###menu/KH2024_MAG_IGRF")
            ctx.key("Escape")
            ctx.frames(1)
        end

        @testset "the map chooser shows another map: missing items and load errors" begin
            ctx.click(layers_ref("Map"))
            ctx.frames(1)
            ctx.click("//###menu/Checks")
            ctx.wait_until(() -> app.ui.current_map == ids.c)
            ctx.wait_until(() -> !any(r -> r.loading, UI.layer_rows(app.snap, ids.c, app.map.entries, app.config.grid_colours)))
            ctx.frames(2)
            @test app.ui.layer_selected == ""
            path = ctx.shot(joinpath(LAYERS_SHOTS, "layers-states-light.png"))
            # "not found" in `red` at the right of the row of an item that was removed.
            for id in (ids.cgone, ids.clost)
                b = app.ui.layer_boxes[id]
                right = UI.Box(b.x1 - 80, b.y0 + 5, b.x1 - 8, b.y1 - 5)
                @test count(p -> near(p, LIGHT.red; tol = 0.08), shot_pixels(path, right)) > 10
            end
            # The load error is the warning's tooltip.
            te.MouseMove(layers_ref(ids.cbroken, "warning"))
            ctx.wait_until(() -> app.ui.tip isa UI.Tip; timeout = 3)
            @test app.ui.tip.title == "Channel MAG is not in North block."
            ctx.frames(2)
            ctx.shot(joinpath(LAYERS_SHOTS, "layers-warning-light.png"))
            te.MouseMoveToPos((700f0, 600f0))
            # An empty map offers Add Item.
            ctx.click(layers_ref("Map"))
            ctx.frames(1)
            ctx.click("//###menu/Empty")
            ctx.wait_until(() -> app.ui.current_map == ids.e)
            ctx.frames(2)
            @test te.ItemExists(layers_ref("Add Item"))
            ctx.shot(joinpath(LAYERS_SHOTS, "layers-empty-light.png"))
            ctx.click(layers_ref("Add Item"))
            ctx.frames(1)
            @test app.ui.menu isa UI.OpenMenu
            ctx.key("Escape")
            @test isempty(app.draw_errors)
        end

        @testset "a layer the graphics card has no room for shows the error in its row" begin
            ctx.on_render(w -> (UI.open_map!(app, ids.m); app.ui.layer_selected = ids.lg))
            ctx.wait_until(() -> !isempty(app.map.plan) && all(p -> p.entry !== nothing && p.entry.data !== nothing, app.map.plan))
            gl = app.map.renderer.gl
            e = only(p.entry for p in app.map.plan if p.layer.id == ids.lg)
            ctx.wait_until(() -> isempty(gl.pending))
            @test UI.zoom_layer_reason(app) === nothing
            # The grid goes up again, and its first upload meets GL_OUT_OF_MEMORY.
            ctx.on_render(w -> (gl.fail_upload = UI.GL.GL_OUT_OF_MEMORY; UI.queue_uploads!(gl, e.key, e.data)))
            ctx.wait_until(() -> UI.layer_error(gl, e.key) == UI.GL_ROOM_TEXT)
            ctx.frames(2)
            @test e.error == ""   # the data is fine; the GPU is not
            row = only(r for r in UI.layers_cache(app, app.snap.maps[ids.m]).rows if r.id == ids.lg)
            @test row.error == UI.GL_ROOM_TEXT
            te.MouseMove(layers_ref(ids.lg, "warning"))
            ctx.wait_until(() -> app.ui.tip isa UI.Tip; timeout = 3)
            @test app.ui.tip.title == UI.GL_ROOM_TEXT
            ctx.frames(2)
            ctx.shot(joinpath(LAYERS_SHOTS, "layers-gpu-error-light.png"))
            te.MouseMoveToPos((700f0, 600f0))
            # Zoom to Layer says why, as for a layer whose load failed.
            @test UI.zoom_layer_reason(app) == UI.GL_ROOM_TEXT
            # Up again with room: the row's warning goes.
            ctx.on_render(w -> UI.queue_uploads!(gl, e.key, e.data))
            ctx.wait_until(() -> isempty(gl.pending))
            ctx.frames(2)
            row = only(r for r in UI.layers_cache(app, app.snap.maps[ids.m]).rows if r.id == ids.lg)
            @test row.error == "" && !te.ItemExists(layers_ref(ids.lg, "warning"))
            @test UI.zoom_layer_reason(app) === nothing
            @test isempty(app.draw_errors)
        end
    end

    # The Layers tab in both themes, at scale 1 and 1.5, for the pixel review against the
    # prototype's shots (proto-layers-<theme>.png).
    for (theme, name) in ((THEME_LIGHT, "light"), (THEME_DARK, "dark")), scale in (1f0, 1.5f0)
        sfx = scale == 1 ? "" : "-1.5x"
        s2, ids2 = layers_project()
        with_project_app(s2; theme, scale) do ctx, app
            ctx.click("JuliaMag/left/Layers")
            ctx.on_render(w -> (app.ui.layer_selected = ids2.ld))
            ctx.wait_until(() -> !isempty(app.map.plan) && all(p -> p.entry !== nothing && p.entry.data !== nothing, app.map.plan))
            te.MouseMoveToPos((700f0, 600f0))
            ctx.frames(3)
            ctx.shot(joinpath(LAYERS_SHOTS, "layers-$name$sfx.png"))
            if scale == 1
                ctx.on_render(w -> (UI.open_map!(app, ids2.c); app.ui.layer_selected = ids2.cd))
                ctx.wait_until(() -> !any(r -> r.loading, UI.layer_rows(app.snap, ids2.c, app.map.entries, app.config.grid_colours)))
                ctx.frames(3)
                ctx.shot(joinpath(LAYERS_SHOTS, "layers-states-$name.png"))
                ctx.on_render(w -> UI.open_map!(app, ids2.e))
                ctx.frames(3)
                ctx.shot(joinpath(LAYERS_SHOTS, "layers-empty-$name.png"))
            end
            @test isempty(app.draw_errors)
        end
    end
end
