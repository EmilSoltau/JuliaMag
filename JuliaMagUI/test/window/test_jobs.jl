using Test
import CImGui as ig
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK, ToolDialog, ResultDialog, job_summary

const JOB_SHOTS = joinpath(@__DIR__, "..", "shots")
const JOB_DLG = "//###dialog1/"

# The test engine reference of a part of a job card.
job_ref(id, part) = "JuliaMag/left/jobs/$id/$part"

# The pixel at device point (x, y) of a PNG, as 0-255 RGB.
job_pixel(img, x, y) = rgb255(img[round(Int, y)+1, round(Int, x)+1])

# How many pixels of a job's bar are `col`, along its middle row.
bar_fill(img, b::UI.Box, col) =
    count(x -> near(job_pixel(img, x, (b.y0 + b.y1) / 2 - 0.5), col; tol = 10), floor(Int, b.x0):ceil(Int, b.x1)-1)

# The box of an item in device pixels, read through the test engine.
function item_box_of(ref)
    r = te.ItemInfo(ref).RectFull
    return UI.Box(r.Min.x, r.Min.y, r.Max.x, r.Max.y)
end

jobs_dialog(app) = isempty(app.ui.dialogs) ? nothing : last(app.ui.dialogs)

# The snapshot row of `job` once it shows status `st`.
function wait_row(ctx, app, job, st; timeout = 20)
    ctx.wait_until(() -> app.snap !== nothing && any(r -> r.job === job && r.status == st, app.snap.jobs); timeout)
    ctx.frames(2)
    return only(filter(r -> r.job === job, app.snap.jobs))
end

window_testset("jobs tab") do
    mkpath(JOB_SHOTS)

    @testset "a slow job: the badge, a growing bar, Cancel" begin
        gate = Channel{Int}(10)
        with_tools([gate_tool(gate)]) do
            with_project_app(kangaroo()) do ctx, app
                UI.request!(app, UI.OpenToolDialog("test.gate"))
                ctx.wait_until(() -> jobs_dialog(app) isa ToolDialog; timeout = 5)
                ctx.frames(2)
                ctx.click(JOB_DLG * "Run")
                ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
                @test app.ui.left_tab == :jobs
                job = only(Core.jobs(app.session))
                wait_row(ctx, app, job, Core.JOB_RUNNING)
                @test UI.running_jobs(app.snap) == 1

                put!(gate, 2)
                ctx.wait_until(() -> job.progress[] >= 0.2; timeout = 10)
                ctx.frames(2)
                first_shot = ctx.shot(joinpath(JOB_SHOTS, "jobs-bar-1-light.png"))
                put!(gate, 6)
                ctx.wait_until(() -> job.progress[] >= 0.6; timeout = 10)
                ctx.frames(2)
                second_shot = ctx.shot(joinpath(JOB_SHOTS, "jobs-bar-2-light.png"))
                b = app.ui.job_bars[job.id]
                img1, img2 = PNGFiles.load(first_shot), PNGFiles.load(second_shot)
                w1, w2 = bar_fill(img1, b, rgb255(LIGHT.accent)), bar_fill(img2, b, rgb255(LIGHT.accent))
                @test abs(w1 - 0.2 * UI.width(b)) <= 3 && abs(w2 - 0.6 * UI.width(b)) <= 3 && w2 > w1
                # The rest of the bar is the well.
                @test bar_fill(img2, b, rgb255(LIGHT.well)) >= 0.4 * UI.width(b) - 4
                # The badge: an accent pill right of "Jobs", in the middle of the header band.
                tab = item_box_of("JuliaMag/left/Jobs")
                mid = round(Int, (tab.y0 + tab.y1) / 2)
                @test count(x -> near(job_pixel(img1, x, mid), rgb255(LIGHT.accent); tol = 10),
                    floor(Int, tab.x0):ceil(Int, tab.x1)-1) >= 4

                ctx.click(job_ref(job.id, "Cancel"))
                r = wait_row(ctx, app, job, Core.JOB_CANCELLED)
                @test job_summary(r) == "Cancelled at 60 %. Nothing was written."
                @test count(it -> it.kind == Core.ITEM_DATABASE, app.snap.items) == 1
                @test UI.running_jobs(app.snap) == 0
                @test !haskey(app.ui.job_bars, job.id)
                @test any(t -> t.text == "Gate cancelled." && t.sub == "Nothing was written.", app.toasts)
                ctx.frames(2)
                @test te.ItemExists(job_ref(job.id, "Run Again..."))
                @test !te.ItemExists(job_ref(job.id, "Cancel"))
            end
        end
    end

    @testset "Run Again with replace off makes a second item; Report shows the report" begin
        gate = Channel{Int}(10)
        with_tools([gate_tool(gate)]) do
            with_project_app(kangaroo()) do ctx, app
                app.ui.left_tab = :jobs
                job = Core.run_tool(app.session, "test.gate")   # as a script would
                put!(gate, 10)
                r = wait_row(ctx, app, job, Core.JOB_DONE)
                @test any(t -> t.kind == :ok && t.text == "Gate done." && t.sub == "Made Gate output.", app.toasts)
                @test startswith(job_summary(r), "Done in ") && endswith(job_summary(r), "Made Gate output.")

                ctx.click(job_ref(job.id, "Run Again..."))
                ctx.wait_until(() -> jobs_dialog(app) isa ToolDialog; timeout = 5)
                d = jobs_dialog(app)
                @test d.form.rerun_of === job && d.form.source == :rerun && !d.form.replace
                ctx.frames(2)
                @test te.ItemExists(JOB_DLG * "replace")
                ctx.click(JOB_DLG * "Run")
                ctx.wait_until(() -> isempty(app.ui.dialogs) && length(Core.jobs(app.session)) == 2; timeout = 10)
                again = first(Core.jobs(app.session))
                put!(gate, 10)
                wait_row(ctx, app, again, Core.JOB_DONE)
                ctx.wait_until(() -> app.snap.revision == Core.revision(app.session); timeout = 10)
                @test count(it -> it.name == "Gate output", app.snap.items) == 2

                ctx.click(job_ref(job.id, "Report"))
                ctx.wait_until(() -> jobs_dialog(app) isa ResultDialog; timeout = 5)
                d = jobs_dialog(app)
                @test d.title == "Job Report: Gate" && occursin("Step 10 of 10", d.text) && occursin("  steps = 10", d.text)
                ctx.frames(2)
                ctx.click(JOB_DLG * "Close")
                ctx.frames(2)
                @test isempty(app.ui.dialogs)
            end
        end
    end

    @testset "a failing job from a script: the failed toast with Report and Run Again" begin
        with_tools([fail_tool()]) do
            with_project_app(kangaroo()) do ctx, app
                bad = Core.run_tool(app.session, "test.fail")
                ctx.wait_until(() -> any(t -> t.text == "Fail failed.", app.toasts); timeout = 20)
                t = only(filter(t -> t.text == "Fail failed.", app.toasts))
                @test t.kind == :error && t.ms == 12000 && first.(t.actions) == ["Report", "Run Again..."]
                @test count(t -> occursin("Fail", t.text), app.toasts) == 1
                ctx.frames(2)
                ctx.click(UI.toast_ref(t) * "/Report##action1")
                ctx.wait_until(() -> jobs_dialog(app) isa ResultDialog; timeout = 5)
                @test occursin("Reading the input file", jobs_dialog(app).text)
                ctx.frames(2)
                ctx.key("Escape")
                ctx.frames(2)
                @test isempty(app.ui.dialogs)
                # The card: red error text and the amber warning.
                app.ui.left_tab = :jobs
                ctx.frames(3)
                r = only(app.snap.jobs)
                @test r.job === bad && r.warnings == ["check the input file"]
                @test te.ItemExists(job_ref(bad.id, "Run Again..."))
                ctx.click(job_ref(bad.id, "Run Again..."))
                ctx.wait_until(() -> jobs_dialog(app) isa ToolDialog; timeout = 5)
                @test jobs_dialog(app).form.rerun_of === bad
                ctx.frames(2)
                @test !te.ItemExists(JOB_DLG * "replace")   # the failed job made nothing
            end
        end
    end

    @testset "2,000 jobs: only cards in view are measured, frames stay fast" begin
        with_project_app(kangaroo()) do ctx, app
            s = app.session
            add_finished_jobs!(s, 2000)
            app.ui.left_tab = :jobs
            ctx.wait_until(() -> length(app.snap.jobs) == 2000; timeout = 20)
            ctx.frames(5)   # warm-up
            v = app.ui.jobs_cache
            @test v isa UI.JobsView && v.bar && length(v.tops) == 2000
            @test te.ItemExists("JuliaMag/left/jobs/scrollbar")
            @test 0 < v.drawn <= 12
            @test v.measured <= v.drawn + 2          # only the cards in view were measured
            # The next frames measure nothing new and stay fast.
            m = v.measured
            times = Int[]
            for _ in 1:10
                ctx.frames(1)
                push!(times, app.draw_ns)
            end
            @test app.ui.jobs_cache.measured == m
            @test maximum(times) < 16_000_000
            newest, oldest = app.snap.jobs[1].id, app.snap.jobs[end].id
            @test te.ItemExists(job_ref(newest, "Report")) && !te.ItemExists(job_ref(oldest, "Report"))
            # Scrolled to the middle: only the cards now in view are measured.
            app.ui.jobs_scroll = v.tops[1000]
            ctx.frames(3)
            v = app.ui.jobs_cache
            @test v.measured - m <= v.drawn + 2
            @test te.ItemExists(job_ref(app.snap.jobs[1000].id, "Report"))
            # Past the end: clamped, the oldest card shows.
            app.ui.jobs_scroll = 1f9
            ctx.frames(3)
            @test 0 < app.ui.jobs_scroll < app.ui.jobs_cache.total
            @test te.ItemExists(job_ref(oldest, "Report"))
            ctx.frames(2)
            @test !te.ItemExists(job_ref(newest, "Report"))
        end
    end

    # Shots for the pixel review: every card state, light and dark, at scale 1 and 1.5.
    for (theme, tokens, name) in ((THEME_LIGHT, LIGHT, "light"), (THEME_DARK, DARK, "dark")),
            (scale, sfx) in ((1f0, ""), (1.5f0, "-1.5x"))
        @testset "shots: $name$sfx" begin
            gate = Channel{Int}(10)
            with_tools([gate_tool(gate), fail_tool(; name = "Import ER Mapper Grid")]) do
                with_project_app(kangaroo(); theme, scale) do ctx, app
                    app.ui.left_tab = :jobs
                    ctx.frames(3)
                    ctx.shot(joinpath(JOB_SHOTS, "jobs-empty-$name$sfx.png"))
                    s = app.session
                    done = Core.import_file(s, small_xyz())
                    Core.wait_job(done)
                    bad = Core.run_tool(s, "test.fail")
                    Core.wait_job(bad)
                    stopped = Core.run_tool(s, "test.gate")
                    put!(gate, 4)
                    ctx.wait_until(() -> stopped.progress[] >= 0.4; timeout = 10)
                    Core.cancel!(stopped)
                    Core.wait_job(stopped)
                    running = Core.run_tool(s, "test.gate")
                    put!(gate, 3)
                    ctx.wait_until(() -> running.progress[] >= 0.3; timeout = 10)
                    wait_row(ctx, app, running, Core.JOB_RUNNING)
                    empty!(app.toasts)
                    ctx.frames(3)
                    ctx.shot(joinpath(JOB_SHOTS, "jobs-cards-$name$sfx.png"))
                    if scale == 1
                        ctx.click(job_ref(done.id, "Report"))
                        ctx.wait_until(() -> jobs_dialog(app) isa ResultDialog; timeout = 5)
                        ctx.frames(4)
                        ctx.shot(joinpath(JOB_SHOTS, "jobs-report-$name.png"))
                        ctx.key("Escape")
                    end
                    Core.cancel!(running)
                    Core.wait_job(running)
                end
            end
        end
    end
end
