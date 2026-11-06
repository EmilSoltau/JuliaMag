using Test
import ImGuiTestEngine as te
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: THEME_LIGHT, THEME_DARK

# A Geosoft database import, in one window session: a new project, the core's afgrav.gdb
# imported from the Database tab, Show on Map, and the job card with its warning. Every
# step goes through the window as a user does it; only the native file and folder dialogs
# are replaced. The helpers `map_e2e_import`, `map_e2e_show` and `map_e2e_wait` come from
# test_map_end_to_end.jl, in the same test module.

const GDB_E2E_FILE = joinpath(@__DIR__, "..", "..", "..", "JuliaMagCore", "test", "data", "gdb", "afgrav.gdb")

window_testset("gdb end to end") do
    shots = joinpath(@__DIR__, "..", "shots")
    mkpath(shots)
    shot(ctx, name) = (ctx.frames(3); ctx.shot(joinpath(shots, "e2e-gdb-$name.png")))
    theme!(ctx, app, theme) =
        (ctx.on_render(w -> UI.run_command!(app, theme == THEME_DARK ? "ui.theme.dark" : "ui.theme.light"));
         ctx.frames(2); @test app.config.theme == theme)
    parent = mktempdir()
    with_test_app(; theme = THEME_LIGHT, scale = 1f0, size = (1480, 920), timeout = 300) do ctx
        app = ctx.app_state()
        picked = Ref("")
        app.pick_file = (; kw...) -> picked[]

        # 1. A new project from the backstage.
        ctx.click("JuliaMag/tabs/Project")
        ctx.frames(2)
        ctx.click("Backstage/nav/New")
        ctx.frames(2)
        picked[] = parent
        ctx.click("Backstage/body/Browse...")
        ctx.frames(2)
        te.ItemClick("Backstage/body/##name")
        te.KeyCharsReplace("Gravity")
        ctx.click("Backstage/body/Create Project")
        ctx.wait_until(() -> app.session !== nothing && app.snap !== nothing; timeout = 20)

        # 2. Database tab, More import formats, "Geosoft database...", Import.
        db = map_e2e_import(ctx, app, picked, "Database", "Geosoft database...", GDB_E2E_FILE, Core.ITEM_DATABASE)

        # 3. The job ended done, with a warning about the custom coordinate system, and its
        # card holds that warning.
        row = only(r for r in app.snap.jobs if r.command == "import.geosoft_gdb")
        job = row.job
        @test Core.status(job) == Core.JOB_DONE && only(job.outputs) == db
        warnings = Core.job_warnings(job)
        @test any(w -> occursin("custom", w) && occursin("xTM", w), warnings)
        @test row.warnings == warnings
        @test UI.card_warnings(row) == [UI.job_text(row, w) for w in warnings]   # all of them, no "And N more"

        # 4. Show on Map: one map with the line layer, drawn.
        map_e2e_show(ctx, app, db)
        ctx.wait_until(() -> !isempty(app.ui.current_map) && haskey(app.snap.maps, app.ui.current_map); timeout = 20)
        m = app.ui.current_map
        ctx.wait_until(() -> !isempty(app.snap.maps[m].layers); timeout = 20)
        @test [l.kind for l in app.snap.maps[m].layers] == [:lines]
        map_e2e_wait(ctx, app, m)

        # 5. The map in light and in dark.
        shot(ctx, "01-map-light")
        theme!(ctx, app, THEME_DARK)
        map_e2e_wait(ctx, app, m)
        shot(ctx, "01-map-dark")

        # 6. The Jobs tab: the card shows the job and its warning, in both themes.
        theme!(ctx, app, THEME_LIGHT)
        map_e2e_wait(ctx, app, m)
        ctx.click("JuliaMag/left/Jobs")
        ctx.frames(3)
        @test app.ui.left_tab === :jobs
        card = app.ui.jobs_cache.entries[job.id]
        @test card.text !== nothing
        shown = join(card.text.warnings, " ")
        @test all(w -> occursin(join(split(UI.job_text(row, w)), " "), shown), warnings)
        shot(ctx, "02-job-light")
        theme!(ctx, app, THEME_DARK)
        shot(ctx, "02-job-dark")
        @test isempty(app.draw_errors)
    end
end
