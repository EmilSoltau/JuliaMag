using Test
import CImGui as ig
import ImGuiTestEngine as te
import GLFW
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: THEME_LIGHT, THEME_DARK, ToolDialog, ResultDialog

# A user's first day, in one window session: a new project, an import, two tools, undo
# and redo, a grid, line selection, the dark theme, an export from search, closing and
# opening the project again, and closing the window. Every step goes through the window
# as a user does it: clicks, menus, typed text and key chords. Only the native file and
# folder dialogs are replaced (`app.pick_file`), and the quit goes to the quit hook.

const E2E_SHOTS = joinpath(@__DIR__, "..", "shots")

e2e_dialog(app) = isempty(app.ui.dialogs) ? nothing : last(app.ui.dialogs)
e2e_tool_dialog(app) = (d = e2e_dialog(app); d isa ToolDialog ? d : nothing)

# Click a text field, select its text and type `text`.
e2e_fill(ref, text) = (te.ItemClick(ref); te.KeyCharsReplace(text); nothing)

# Open a tree row's chevron when the row is not open yet.
function e2e_expand(ctx, app, key)
    key in app.ui.expanded && return nothing
    ctx.click(tree_ref(key, "chevron"))
    ctx.wait_until(() -> key in app.ui.expanded)
    ctx.frames(2)
    return nothing
end

# Right click a tree row and click `label` in its menu.
function e2e_tree_menu(ctx, key, label)
    right_click(tree_ref(key))
    ctx.frames(2)
    ctx.click("//###menu/" * label)
    return nothing
end

# Wait for the one job that is not done yet to end, and return it.
function e2e_wait_job(ctx, app, n)
    ctx.wait_until(() -> length(Core.jobs(app.session)) == n; timeout = 10)
    job = first(Core.jobs(app.session))   # the newest first
    ctx.wait_until(() -> Core.status(job) != Core.JOB_RUNNING; timeout = 60)
    @test Core.status(job) == Core.JOB_DONE
    ctx.wait_until(() -> app.snap !== nothing && app.snap.revision == Core.revision(app.session); timeout = 10)
    return job
end

has_channel(app, db, name) = any(c -> c.name == name, app.snap.databases[db].channels)

# A Geosoft XYZ file with 4 lines of 50 rows and a MAG channel.
function e2e_xyz()
    path = joinpath(mktempdir(), "small.xyz")
    write_synthetic_xyz(path; lines = 4, ties = 0, rows_per_line = 50)
    return path
end

const E2E_GRID = joinpath(@__DIR__, "..", "..", "..", "JuliaMagCore", "test", "data", "grids", "om_float.grd")

function first_day(; scale::Real, size, sfx::AbstractString)
    shot(ctx, name) = (ctx.frames(3); ctx.shot(joinpath(E2E_SHOTS, "e2e-$name$sfx.png")))
    parent = mktempdir()
    xyz = e2e_xyz()
    csv = joinpath(mktempdir(), "small.csv")
    quits = Ref(0)
    with_test_app(; theme = THEME_LIGHT, scale, size, timeout = 300) do ctx
        app = ctx.app_state()
        app.quit_hook = a -> (quits[] += 1; nothing)   # the test ends the loop itself
        picked = Ref("")
        app.pick_file = (; kw...) -> picked[]

        # 1. No project. The Project button, New, Browse..., a name and Create Project.
        @test app.session === nothing
        shot(ctx, "01-empty-light")
        ctx.click("JuliaMag/tabs/Project")
        ctx.frames(2)
        ctx.click("Backstage/nav/New")
        ctx.frames(2)
        picked[] = parent
        ctx.click("Backstage/body/Browse...")
        ctx.frames(2)
        e2e_fill("Backstage/body/##name", "First Day")
        shot(ctx, "01-new-light")
        ctx.click("Backstage/body/Create Project")
        ctx.wait_until(() -> app.session !== nothing && app.snap !== nothing; timeout = 20)
        ctx.frames(2)
        @test !app.ui.backstage && app.session.project.name == "First Day"
        folder = joinpath(parent, "First Day")
        @test isdir(folder)

        # 2. Database > Import: the arrow of the split button, Geosoft XYZ..., Import.
        @test app.ui.tab == "Database"
        picked[] = xyz
        ctx.click("JuliaMag/ribbon/More import formats")
        ctx.frames(1)
        ctx.click("//###menu/Geosoft XYZ...")
        ctx.wait_until(() -> e2e_tool_dialog(app) !== nothing; timeout = 10)
        @test e2e_tool_dialog(app).form.path == xyz
        shot(ctx, "02-import-light")
        ctx.click("//###dialog1/Import")
        ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)

        # 3. The job ends; the database shows in the Data tree, and the toast says so.
        e2e_wait_job(ctx, app, 1)
        ctx.wait_until(() -> length(app.snap.databases) == 1; timeout = 10)
        ctx.wait_until(() -> any(t -> t.kind == :ok && t.text == "Import Geosoft XYZ done.", app.toasts);
            timeout = 10)
        db = only(keys(app.snap.databases))
        ctx.click("JuliaMag/left/Data")
        ctx.frames(2)
        e2e_expand(ctx, app, "databases")
        @test te.ItemExists(tree_ref(db))
        @test app.ui.current_db == db
        shot(ctx, "03-imported-light")

        # 4. Statistics on MAG from the database's context menu: the result dialog.
        e2e_tree_menu(ctx, db, "Statistics...")
        ctx.wait_until(() -> e2e_tool_dialog(app) !== nothing; timeout = 10)
        d = e2e_tool_dialog(app)
        ctx.frames(2)
        # Statistics has no preferred channel, so the first one (X) comes preselected.
        ctx.click("//###dialog1/channel")
        ctx.frames(2)
        ctx.click("//" * app.ui.menu.ref * "/MAG")
        ctx.frames(2)
        @test d.form.values["channel"] == "MAG"
        shot(ctx, "04-statistics-light")
        ctx.click("//###dialog1/Run")
        ctx.wait_until(() -> e2e_dialog(app) isa ResultDialog; timeout = 20)
        result = e2e_dialog(app)
        @test occursin("MAG", result.title * result.text)
        shot(ctx, "04-statistics-result-light")
        ctx.click("//###dialog1/Close")
        ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 5)

        # 5. Channel Math MAG2 = MAG * 2; the channel shows; Ctrl+Z removes it; Ctrl+Y.
        e2e_tree_menu(ctx, db, "Channel Math...")
        ctx.wait_until(() -> e2e_tool_dialog(app) !== nothing; timeout = 10)
        ctx.frames(2)
        e2e_fill("//###dialog1/##expr", "MAG2 = MAG * 2")
        shot(ctx, "05-channel-math-light")
        ctx.click("//###dialog1/Run")
        ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
        e2e_wait_job(ctx, app, 2)
        @test has_channel(app, db, "MAG2")
        ctx.click("JuliaMag/left/Data")
        ctx.frames(2)
        e2e_expand(ctx, app, db)
        e2e_expand(ctx, app, "$db/channels")
        @test te.ItemExists(tree_ref("$db/channels/MAG2"))
        shot(ctx, "05-channel-light")
        ctx.key("Ctrl+Z")
        ctx.wait_until(() -> !has_channel(app, db, "MAG2"); timeout = 20)
        ctx.frames(3)
        @test !te.ItemExists(tree_ref("$db/channels/MAG2"))
        ctx.key("Ctrl+Y")
        ctx.wait_until(() -> has_channel(app, db, "MAG2"); timeout = 20)
        ctx.frames(3)
        @test te.ItemExists(tree_ref("$db/channels/MAG2"))

        # 6. Grid and Image > Import: Geosoft or Surfer grid...; then its coordinate system.
        ctx.click("JuliaMag/tabs/Grid and Image")
        ctx.frames(2)
        picked[] = E2E_GRID
        ctx.click("JuliaMag/ribbon/More import formats")
        ctx.frames(1)
        ctx.click("//###menu/Geosoft or Surfer grid...")
        ctx.wait_until(() -> e2e_tool_dialog(app) !== nothing; timeout = 10)
        shot(ctx, "06-grid-import-light")
        ctx.click("//###dialog1/Import")
        ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
        e2e_wait_job(ctx, app, 3)
        ctx.wait_until(() -> length(app.snap.grids) == 1; timeout = 10)
        grid = only(keys(app.snap.grids))
        ctx.click("JuliaMag/left/Data")
        ctx.frames(2)
        e2e_expand(ctx, app, "grids")
        e2e_tree_menu(ctx, grid, "Set Coordinate System...")
        ctx.wait_until(() -> e2e_tool_dialog(app) !== nothing; timeout = 10)
        d = e2e_tool_dialog(app)
        ctx.frames(2)
        e2e_fill("//###dialog1/##crs", "EPSG:28355")
        ctx.wait_until(() -> haskey(d.crs_names, "EPSG:28355"); timeout = 10)
        ctx.frames(2)
        shot(ctx, "06-grid-crs-light")
        ctx.click("//###dialog1/Run")
        ctx.wait_until(() -> app.snap.grids[grid].crs == "EPSG:28355"; timeout = 20)
        ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)

        # 7. Untick two lines: the status bar counts the lines still selected.
        e2e_expand(ctx, app, "$db/lines")
        @test UI.status_texts(app).selected == "Selected lines: 4 of 4"
        for name in ("L1001", "L1002")
            ctx.click(tree_ref("$db/lines/$name", "check"))
            ctx.wait_until(() -> !only(l for l in app.snap.databases[db].lines if l.name == name).selected;
                timeout = 10)
        end
        @test UI.status_texts(app).selected == "Selected lines: 2 of 4"
        shot(ctx, "07-lines-light")

        # 8. Dark, then Export CSV... from the command search to a temp file.
        ctx.click("JuliaMag/tabs/Settings")
        ctx.frames(2)
        ctx.click("JuliaMag/ribbon/Dark Theme")
        ctx.frames(3)
        @test app.config.theme == THEME_DARK
        ctx.key("Ctrl+K")
        ctx.frames(2)
        ctx.type("Export CSV")
        ctx.frames(2)
        @test first(UI.search_hits!(app)).id == "export.csv"
        shot(ctx, "08-search-dark")
        ctx.key("Enter")
        ctx.wait_until(() -> e2e_tool_dialog(app) !== nothing; timeout = 10)
        picked[] = csv
        ctx.frames(2)
        ctx.click("//###dialog1/path/Browse...")
        ctx.frames(2)
        @test e2e_tool_dialog(app).form.path == csv
        shot(ctx, "08-export-dark")
        ctx.click("//###dialog1/Export")
        ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
        e2e_wait_job(ctx, app, 4)
        @test isfile(csv) && filesize(csv) > 0

        # 9. Close the project from the backstage; the Start page lists it; open it again.
        ctx.click("JuliaMag/tabs/Project")
        ctx.frames(2)
        ctx.click("Backstage/nav/Close")
        ctx.wait_until(() -> app.session === nothing && app.switching === nothing; timeout = 30)
        ctx.frames(2)
        @test app.ui.backstage && app.ui.backstage_page === :start
        real = realpath(folder)
        @test first(app.config.recent) == real
        ref = "Backstage/body/recent/" * replace(real, "/" => "\\/")
        ctx.wait_until(() -> te.ItemExists(ref); timeout = 10)
        shot(ctx, "09-closed-dark")
        ctx.click(ref)
        ctx.wait_until(() -> app.session !== nothing && app.snap !== nothing &&
                             !isempty(app.snap.databases); timeout = 30)
        ctx.frames(2)
        @test !app.ui.backstage && app.session.project.name == "First Day"
        @test has_channel(app, db, "MAG2") && app.snap.grids[grid].crs == "EPSG:28355"
        @test UI.status_texts(app).selected == "Selected lines: 2 of 4"
        @test length(Core.jobs(app.session)) == 4
        ctx.click("JuliaMag/left/Data")
        ctx.frames(2)
        e2e_expand(ctx, app, "databases")
        e2e_expand(ctx, app, db)
        e2e_expand(ctx, app, "$db/channels")
        @test te.ItemExists(tree_ref("$db/channels/MAG2"))
        shot(ctx, "09-reopened-dark")

        # 10. Close the window: the project closes, then the app quits.
        s = app.session
        ctx.on_render(w -> GLFW.SetWindowShouldClose(w.handle, true))
        ctx.wait_until(() -> quits[] == 1; timeout = 30)
        @test !isopen(s) && app.session === nothing
    end
    @test quits[] == 1
    return nothing
end

window_testset("end to end") do
    mkpath(E2E_SHOTS)
    @testset "a first day at scale 1" begin
        first_day(; scale = 1f0, size = (1480, 920), sfx = "")
    end
    @testset "a first day at scale 1.5" begin
        first_day(; scale = 1.5f0, size = (2220, 1380), sfx = "-1.5x")
    end
end
