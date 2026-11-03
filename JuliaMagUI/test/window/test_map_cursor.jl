using Test
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Camera, THEME_LIGHT, THEME_DARK, LIGHT, DARK

const CURSOR_SHOTS = joinpath(@__DIR__, "..", "shots")

# Six lines of 60 rows, 50 m apart, over a grid "TMI" on one map; and a database that is on no map.
function cursor_project()
    s = fresh_session()
    db = survey_database!(s; lines = 6, rows = 60)
    A = Float32[100sin(i / 7) * cos(j / 5) for i in 1:60, j in 1:26]
    g = add_test_grid!(s, A; name = "TMI")
    m = Core.new_map!(s; name = "Survey")
    Core.add_layer!(s, m, g)
    Core.add_layer!(s, m, db)
    other = survey_database!(s; lines = 2, x0 = 600_000.0)
    return s, (; m, db, g, other)
end

# Show map `m` and wait until its layers are loaded and drawn.
function cursor_map_shown!(ctx, app, m)
    ctx.on_render(w -> (app.ui.current_map = m))
    ms = app.map
    ctx.wait_until(; timeout = 20) do
        r = ms.renderer
        ms.plan_map == m && r.image.map == m && r.image.key == ms.scene.key && !isempty(ms.plan) &&
            all(p -> p.entry !== nothing && p.entry.data !== nothing && !p.entry.loading, ms.plan)
    end
    ctx.frames(2)
    return nothing
end

# The window point (device px) of world point `p` on the shown map.
function cursor_screen(app, p)
    st = app.map.views[app.ui.current_map]
    sx, sy = UI.world_to_screen(st.camera, st.size..., p...)
    return (app.map.view.x0 + sx, app.map.view.y0 + sy)
end

# A left click at window point `pos`.
function click_at(ctx, pos)
    ctx.mouse_to(pos)
    te.MouseDown(0)
    te.MouseUp(0)
    ctx.frames(2)
    return nothing
end

const CURSOR_LINE = Core.LineId(Core.LINE, 1002, 0)

window_testset("map cursor") do
    s, ids = cursor_project()
    with_project_app(s; timeout = 300) do ctx, app
        cursor_map_shown!(ctx, app, ids.m)
        st = app.map.views[ids.m]
        w, h = st.size

        @testset "the status bar reads the values under the pointer" begin
            @test UI.map_status(app)[2:3] == ("X -  Y -", "")
            # Row 3 of L1002 is at (500 020, 7 000 050); the pointer 2 px off it.
            ctx.mouse_to(cursor_screen(app, (500_020.0, 7_000_050.0)) .+ (2, 0))
            ctx.frames(2)
            t = UI.map_status(app)
            hv = app.ui.hover
            # The test engine moves the mouse to whole pixels: the point is within a pixel.
            @test abs(hv.x - (500_020.0 + 2st.camera.res)) <= st.camera.res && abs(hv.y - 7_000_050.0) <= st.camera.res
            @test t[2] == UI.pointer_text(hv.x, hv.y, "m")
            @test startswith(t[3], "TMI ") && endswith(t[3], "  L1002 fid 0.2 MAG 203.00")
            # The texts follow the mouse.
            ctx.mouse_to(cursor_screen(app, (500_400.0, 7_000_150.0)))
            ctx.frames(2)
            t = UI.map_status(app)
            @test abs(app.ui.hover.x - 500_400.0) <= st.camera.res && t[2] == UI.pointer_text(app.ui.hover.x, app.ui.hover.y, "m")
            @test endswith(t[3], "  L1004 fid 4.0 MAG 441.00")
            ctx.shot(joinpath(CURSOR_SHOTS, "map-readout-light.png"))
        end

        @testset "a steady status bar allocates nothing" begin
            bytes = Int[]
            for _ in 1:3
                ctx.on_render(win -> begin
                    b = app.ui.status_cache.box
                    dl = UI.ig.GetForegroundDrawList()
                    UI.draw_status_bar(app, dl, b)
                    push!(bytes, @allocated UI.draw_status_bar(app, dl, b))
                end)
            end
            @test bytes == [0, 0, 0]
        end

        @testset "a click near a line moves the cursor there" begin
            p = (500_020.0, 7_000_050.0)
            click_at(ctx, cursor_screen(app, p) .+ (3, 2))
            ctx.wait_until(() -> app.snap.cursor !== nothing)
            c = app.snap.cursor
            @test c.item == ids.db && c.line == CURSOR_LINE && c.row == 3
            @test UI.cursor_target(app, app.snap.maps[ids.m]) == p
            ctx.mouse_to(cursor_screen(app, (500_300.0, 7_000_225.0)))   # off the marker
            ctx.frames(2)
            path = joinpath(CURSOR_SHOTS, "map-cursor-light.png")
            ctx.shot(path)
            # The ring: `accent` 5 px from the centre, the line's colour inside it.
            img = PNGFiles.load(path)
            cx, cy = round.(Int, cursor_screen(app, p))
            @test near(rgb255(img[cy+1, cx+5+1]), rgb255(LIGHT.accent); tol = 12)
            @test near(rgb255(img[cy-5+1, cx+1]), rgb255(LIGHT.accent); tol = 12)
            @test isempty(app.draw_errors)
        end

        @testset "a click far from every line leaves the cursor" begin
            c = app.snap.cursor
            click_at(ctx, cursor_screen(app, (500_300.0, 7_000_075.0)))   # 25 m from two lines
            ctx.frames(3)
            @test app.queue.pending == 0 && app.snap.cursor == c
            # Nor does a drag that ends on a line.
            from = cursor_screen(app, (500_300.0, 7_000_075.0))
            ctx.drag(from, cursor_screen(app, (500_030.0, 7_000_100.0)))
            ctx.frames(3)
            @test app.queue.pending == 0 && app.snap.cursor == c
        end

        @testset "Go To Cursor centres the camera on it" begin
            ctx.click("JuliaMag/mapnav/zoom_in")
            ctx.click("JuliaMag/mapnav/zoom_in")
            vc = (app.map.view.x0 + w / 2, app.map.view.y0 + h / 2)
            ctx.drag(vc, vc .+ (-150, 90))
            ctx.frames(2)
            ctx.wait_until(() -> st.before === nothing)
            p = UI.cursor_target(app, app.snap.maps[ids.m])
            ctx.click("JuliaMag/mapnav/go_cursor")
            ctx.frames(2)
            sx, sy = UI.world_to_screen(st.camera, w, h, p...)
            @test abs(sx - w / 2) <= 0.5 && abs(sy - h / 2) <= 0.5
            ctx.mouse_to(cursor_screen(app, p) .+ (40, 40))
            ctx.frames(2)
            ctx.shot(joinpath(CURSOR_SHOTS, "map-cursor-centred-light.png"))
        end

        @testset "a cursor on a database that is not on the map" begin
            ctx.on_render(win -> UI.submit!(app, "cursor",
                s -> Core.set_cursor!(s, Core.Cursor(ids.other, Core.LineId(Core.LINE, 1001, 0), 1))))
            ctx.wait_until(() -> app.snap.cursor !== nothing && app.snap.cursor.item == ids.other)
            ctx.frames(2)
            go = only(c for c in UI.commands(app) if c.id == "map.go_cursor")
            @test go.enabled(app) == "The current point is not on this map."
            cam = st.camera
            ctx.click("JuliaMag/mapnav/go_cursor")
            ctx.frames(2)
            @test st.camera == cam
            @test isempty(app.draw_errors)
        end
    end

    # The status bar and the marker in both themes, at scale 1 and 1.5.
    for (theme, name) in ((THEME_LIGHT, "light"), (THEME_DARK, "dark")), scale in (1f0, 1.5f0)
        (name == "light" && scale == 1) && continue
        s2, ids2 = cursor_project()
        Core.set_cursor!(s2, Core.Cursor(ids2.db, CURSOR_LINE, 3))
        with_project_app(s2; theme, scale, timeout = 120) do ctx, app
            cursor_map_shown!(ctx, app, ids2.m)
            ctx.mouse_to(cursor_screen(app, (500_400.0, 7_000_150.0)))
            ctx.frames(2)
            @test endswith(UI.map_status(app)[3], "  L1004 fid 4.0 MAG 441.00")
            ctx.shot(joinpath(CURSOR_SHOTS, "map-readout-$name" * (scale == 1 ? "" : "-1.5x") * ".png"))
            @test isempty(app.draw_errors)
        end
    end
end
