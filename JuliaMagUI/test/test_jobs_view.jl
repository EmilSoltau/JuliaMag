using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: job_title, job_target, job_summary, ResultDialog, ToolDialog

# The jobs of the snapshot, after a refresh, by id.
row_of(app, job) = only(filter(r -> r.job === job, app.snap.jobs))

# Refresh, then look for jobs that left running, as one frame does.
watch_now!(app) = (refresh_now!(app); UI.watch_jobs!(app); nothing)

@testset "jobs view" begin
    @testset "job_summary for each status" begin
        names = Dict("db-1" => "Kangaroo Hills", "db-2" => "B", "db-3" => "C")
        run = fake_job_row(status = Core.JOB_RUNNING, progress = 0.4)
        @test job_summary(run) == "40 %"
        done = fake_job_row(outputs = ["db-1"], names = names)
        @test job_summary(done) == "Done in 2.1 s. Made Kangaroo Hills."
        @test job_summary(fake_job_row()) == "Done in 2.1 s."
        @test job_summary(fake_job_row(outputs = ["db-1", "db-2", "db-3"], names = names)) ==
              "Done in 2.1 s. Made Kangaroo Hills, B and C."
        @test job_summary(fake_job_row(outputs = ["db-1", "db-9"], names = names)) ==
              "Done in 2.1 s. Made Kangaroo Hills and db-9."   # an output out of the project
        @test job_summary(fake_job_row(finished = "2026-10-30T10:44:07.500+1000")) == "Done in 1 min 5 s."
        # Records from before job times had milliseconds.
        @test job_summary(fake_job_row(started = "2026-10-30T10:43:02+1000",
            finished = "2026-10-30T10:43:04+1000")) == "Done in 2.0 s."
        @test job_summary(fake_job_row(started = "", finished = "")) == "Done."
        cancelled = fake_job_row(status = Core.JOB_CANCELLED, progress = 0.4, error = "the job was cancelled")
        @test job_summary(cancelled) == "Cancelled at 40 %. Nothing was written."
        failed = fake_job_row(status = Core.JOB_FAILED, error = "the file is bad")
        @test job_summary(failed) == "the file is bad"
        @test job_summary(fake_job_row(status = Core.JOB_UNDONE, outputs = ["db-1"], names = names)) == "Undone."
    end

    @testset "job times: the new UTC form and every older form" begin
        z = UI.job_time("2026-10-31T09:15:02.123Z")
        @test z.zoned && z.seconds ≈ UI.job_time("2026-10-31T19:15:02.123+1000").seconds
        @test UI.job_time("2026-10-31T19:15:02.123+10:00").seconds ≈ z.seconds
        @test UI.job_time("2026-10-31T04:15:02.123-0500").seconds ≈ z.seconds
        @test UI.job_time("2026-10-31T09:15:02Z").seconds ≈ z.seconds - 0.123
        @test UI.job_time("2026-03-01T00:00:00+0000").seconds - UI.job_time("2026-02-28T23:59:59+0000").seconds == 1
        # Windows wrote the zone's name for %z: the clock fields are local time.
        w = UI.job_time("2026-10-30T10:43:02AUS Eastern Standard Time")
        @test w !== nothing && !w.zoned
        @test UI.job_time("") === nothing && UI.job_time("yesterday") === nothing
        # What the core writes now reads back.
        @test UI.job_time(Core.job_time_text(1_761_902_102.123)).seconds ≈ 1_761_902_102.123 atol = 1e-3
        # How long a job took, in any form; a mix of zoned and unzoned times is unknown.
        @test UI.elapsed("2026-10-31T09:15:02.100Z", "2026-10-31T09:15:04.200Z") ≈ 2.1 atol = 1e-3
        @test UI.elapsed("2026-10-30T10:43:02.100+1000", "2026-10-30T10:43:04.200+1000") ≈ 2.1 atol = 1e-3
        @test UI.elapsed("2026-10-30T10:43:02Mitteleuropäische Zeit", "2026-10-30T10:44:05Mitteleuropäische Zeit") == 63
        @test isnan(UI.elapsed("2026-10-30T10:43:02Z", "2026-10-30T10:44:05AUS Eastern Standard Time"))
        @test isnan(UI.elapsed("", "2026-10-30T10:44:05Z"))
        # The card shows local HH:MM; the offset is given here, so no test depends on the machine.
        @test UI.clock_text("2026-10-31T09:15:02.123Z", 36000) == "19:15"
        @test UI.clock_text("2026-10-31T09:15:02.123Z", -5 * 3600) == "04:15"
        @test UI.clock_text("2026-10-31T23:30:00Z", 3600) == "00:30"
        @test UI.clock_text("2026-10-30T10:43:02+1000", 0) == "00:43"
        @test UI.clock_text("2026-10-30T10:43:02AUS Eastern Standard Time", 3600) == "10:43"
        @test UI.clock_text("", 0) == "" && UI.clock_text("yesterday", 0) == ""
        o = UI.local_offset(1_761_902_102.0)
        @test o % 900 == 0 && abs(o) <= 14 * 3600
        # The offset from the C library's local time, here a fixed one, so no test depends on
        # the machine's zone. Sydney ends summer time at 2026-04-05 03:00 local (16:00 UTC).
        sydney(t) = t < UI.job_time("2026-04-04T16:00:00Z").seconds ? 11 * 3600 : 10 * 3600
        fake(off) = t -> begin   # what TmStruct holds: years from 1900, months from 0
            m = match(r"(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)", UI.utc_text(t + off(t)))
            v = parse.(Int, m.captures)
            (year = v[1] - 1900, month = v[2] - 1, mday = v[3], hour = v[4], min = v[5], sec = v[6])
        end
        before, after = UI.job_time("2026-04-04T15:59:59Z").seconds, UI.job_time("2026-04-04T16:00:00Z").seconds
        @test UI.local_offset(before, fake(sydney)) == 11 * 3600
        @test UI.local_offset(after, fake(sydney)) == 10 * 3600
        @test UI.clock_text("2026-04-04T15:59:59Z", UI.local_offset(before, fake(sydney))) == "02:59"
        @test UI.clock_text("2026-04-04T16:00:00Z", UI.local_offset(after, fake(sydney))) == "02:00"
        newyork(t) = -4 * 3600
        @test UI.local_offset(after, fake(newyork)) == -4 * 3600
        @test UI.local_offset(after, fake(t -> 5 * 3600 + 45 * 60)) == 5 * 3600 + 45 * 60   # Nepal
        # Before 1970, not a number, or a local time that makes no sense: UTC.
        @test UI.local_offset(-86400.0, fake(sydney)) == 0
        @test UI.local_offset(NaN) == 0 && UI.local_offset(Inf) == 0
        @test UI.local_offset(after, t -> (year = 0, month = 0, mday = 0, hour = 0, min = 0, sec = 0)) == 0
        @test UI.local_offset(after, t -> error("no local time")) == 0
        @test UI.clock_text("1969-12-31T23:30:00Z") == "23:30"
        @test UI.utc_text(0.0) == "1970-01-01T00:00:00" && UI.utc_text(1_761_902_102.9) == "2025-10-31T09:15:02"
        @test UI.clock_text("2026-10-31T09:15:02.123Z") == UI.clock_text("2026-10-31T09:15:02.123Z",
            UI.local_offset(UI.job_time("2026-10-31T09:15:02.123Z").seconds))
        @test UI.duration_text(0.43) == "0.4 s" && UI.duration_text(59.94) == "59.9 s"
        @test UI.duration_text(0.04) == "under 0.1 s" && UI.duration_text(59.96) == "1 min 0 s"
        @test UI.duration_text(65.4) == "1 min 5 s" && UI.duration_text(3725) == "62 min 5 s"
        @test UI.percent_text(0.404) == "40 %" && UI.percent_text(1.2) == "100 %" && UI.percent_text(NaN) == "0 %"
        @test job_summary(fake_job_row(started = "2026-10-31T09:15:02.100Z", finished = "2026-10-31T09:15:04.200Z")) ==
              "Done in 2.1 s."
    end

    @testset "a card shows at most 3 warnings" begin
        @test UI.card_warnings(["a", "b"]) == ["a", "b"]
        @test UI.card_warnings(["a", "b", "c"]) == ["a", "b", "c"]
        @test UI.card_warnings(["a", "b", "c", "d"]) == ["a", "b", "c", "And 1 more warning. See Report."]
        @test UI.card_warnings(["w$k" for k in 1:200])[end] == "And 197 more warnings. See Report."
    end

    @testset "Cancel says Cancelling... once asked" begin
        r = fake_job_row(status = Core.JOB_RUNNING)
        @test UI.cancel_label(r) == "Cancel"
        Core.cancel!(r.job)
        @test UI.cancel_label(r) == "Cancelling..."
    end

    @testset "job_target" begin
        names = Dict("db-1" => "Kangaroo Hills", "gr-1" => "Grid A")
        xyz = joinpath("data", "small.xyz")
        imp(args; kw...) = fake_job_row(; kind = :import, command = "import.geosoft_xyz",
            title = "Import Geosoft XYZ", args = merge(Dict{String,Any}("path" => xyz), args), names, kw...)
        @test job_target(imp(Dict("mode" => "new", "name" => ""); status = Core.JOB_RUNNING)) == "small.xyz -> small"
        @test job_target(imp(Dict("mode" => "new", "name" => "Survey"); status = Core.JOB_RUNNING)) == "small.xyz -> Survey"
        @test job_target(imp(Dict("mode" => "append", "target" => "db-1"))) == "small.xyz -> Kangaroo Hills"
        @test job_target(imp(Dict("mode" => "new", "name" => ""); outputs = ["db-1"])) == "small.xyz -> Kangaroo Hills"
        exp = fake_job_row(kind = :export, args = Dict("item" => "db-1", "path" => joinpath("out", "kh.csv")), names = names)
        @test job_target(exp) == "Kangaroo Hills -> kh.csv"
        cm = fake_job_row(expression = "C3 = C1 * 2", args = Dict("expr" => "C3 = C1 * 2",
            "inputs" => Dict("database" => "db-1")), names = names)
        @test job_target(cm) == "C3 = C1 * 2"
        tool = fake_job_row(args = Dict("inputs" => Dict("grid" => "gr-1", "database" => "db-1")), names = names)
        @test job_target(tool) == "Kangaroo Hills, Grid A"
        @test job_target(fake_job_row(kind = :other, args = Dict("item" => "db-1"), names = names)) == "Kangaroo Hills"
        @test job_target(fake_job_row(kind = :other, args = Dict("path" => xyz))) == "small.xyz"
        @test job_target(fake_job_row(kind = :other)) == ""
    end

    @testset "rows from a real snapshot: an XYZ import and Channel Math" begin
        with_app(app_with_database()) do app
            s = app.session
            db = app.ui.current_db
            Core.rename_item!(s, db, "Survey")
            job = Core.import_file(s, small_xyz())
            Core.wait_job(job)
            cm = Core.run_tool(s, "database.channel_math"; inputs = Dict("database" => db), expr = "C3 = MAG * 2")
            Core.wait_job(cm)
            refresh_now!(app)
            r = row_of(app, job)
            @test r.kind == :import && job_title(r) == "Import Geosoft XYZ"
            @test job_target(r) == "small.xyz -> small"
            @test startswith(job_summary(r), "Done in ") && endswith(job_summary(r), " s. Made small.")
            c = row_of(app, cm)
            @test c.kind == :tool && job_title(c) == "Channel Math" && job_target(c) == "C3 = MAG * 2"
            @test UI.made_by_text(app.snap, job.id) == "Import Geosoft XYZ, small.xyz -> small ($(job.id))"
        end
    end

    @testset "the top bar's text" begin
        @test UI.jobs_bar_text(1, 3) == "1 running, 2 finished"
        @test UI.jobs_bar_text(0, 3) == "3 finished"
        @test UI.jobs_bar_text(0, 0) == "0 finished"
        @test UI.JOBS_EMPTY == "No jobs yet. Imports and long tools run here."
    end

    @testset "a toast when a job leaves running, once per job" begin
        gate = Channel{Int}(10)
        with_tools([gate_tool(gate), fail_tool()]) do
            s = fresh_session()
            before = Core.run_tool(s, "test.fail")   # ended before the app saw the project
            Core.wait_job(before)
            with_app(test_app_state(s)) do app
                watch_now!(app)
                @test isempty(app.toasts)            # old jobs make no toasts

                job = Core.run_tool(s, "test.gate")
                watch_now!(app)
                @test isempty(app.toasts)
                put!(gate, 10)
                Core.wait_job(job)
                watch_now!(app)
                @test [(t.kind, t.text, t.sub) for t in app.toasts] == [(:ok, "Gate done.", "Made Gate output.")]
                watch_now!(app)
                UI.watch_jobs!(app)
                @test length(app.toasts) == 1        # once

                # A job that started and ended between two snapshots.
                bad = Core.run_tool(s, "test.fail")
                Core.wait_job(bad)
                watch_now!(app)
                t = app.toasts[end]
                @test t.kind == :error && t.text == "Fail failed." && t.ms == UI.TOAST_JOB_FAILED_MS
                @test occursin("the input file is bad", t.sub)
                @test first.(t.actions) == ["Report", "Run Again..."]

                stopped = Core.run_tool(s, "test.gate")
                watch_now!(app)
                Core.cancel!(stopped)
                Core.wait_job(stopped)
                watch_now!(app)
                @test (app.toasts[end].kind, app.toasts[end].text, app.toasts[end].sub) ==
                      (:info, "Gate cancelled.", "Nothing was written.")

                n = length(app.toasts)
                @test Core.undo!(s)                  # the done job becomes undone: no toast
                watch_now!(app)
                @test length(app.toasts) == n

                # Another project: its finished jobs make no toasts.
                s2 = fresh_session()
                done2 = Core.run_tool(s2, "test.fail")
                Core.wait_job(done2)
                UI.set_session!(app, s2)
                watch_now!(app)
                @test length(app.toasts) == n
                Core.close_session!(s2)
            end
        end
    end

    @testset "the failed toast's actions open the report and the dialog" begin
        with_tools([fail_tool()]) do
            with_app(test_app_state(fresh_session())) do app
                watch_now!(app)
                bad = Core.run_tool(app.session, "test.fail")
                Core.wait_job(bad)
                watch_now!(app)
                t = app.toasts[end]
                last(t.actions[1])(app)                # Report
                wait_drained(app)
                d = last(app.ui.dialogs)
                @test d isa ResultDialog && d.title == "Job Report: Fail" && occursin("Reading the input file", d.text)
                empty!(app.ui.dialogs)
                last(t.actions[2])(app)                # Run Again...
                wait_drained(app)
                d = last(app.ui.dialogs)
                @test d isa ToolDialog && d.form.rerun_of === bad && d.form.source == :rerun
            end
        end
    end

    @testset "the Report dialog: report, warnings and settings" begin
        r = fake_job_row(title = "Gate", args = Dict("steps" => 10, "inputs" => Dict("database" => "db-1"),
            "name" => "Survey"))
        d = UI.job_report_dialog(r, "Step 1 of 10\nWarning: line 3 is short\n", ["line 3 is short", "no CRS"])
        @test d isa ResultDialog && d.title == "Job Report: Gate"
        @test d.lines == ["Step 1 of 10", "Warning: line 3 is short", "", "Warnings:", "  no CRS", "",
            "Settings:", "  inputs = {\"database\": \"db-1\"}", "  name = \"Survey\"", "  steps = 10"]
        @test d.kinds[2] == :warn && d.kinds[5] == :warn && d.kinds[1] == :text && d.kinds[7] == :dim
        @test d.text == join(d.lines, '\n')
        # No warnings beyond the report's own: no Warnings section.
        d = UI.job_report_dialog(r, "Warning: line 3 is short", ["line 3 is short"])
        @test !("Warnings:" in d.lines) && d.lines[1] == "Warning: line 3 is short"
        # Inputs and items show their names, with the id; Inf and NaN settings work.
        r = fake_job_row(title = "Gate", names = Dict("db-1" => "Kangaroo Hills"),
            args = Dict("inputs" => Dict("database" => "db-1", "grid" => "gr-9"), "item" => "db-1",
                "max" => Inf, "min" => -Inf, "dummy" => NaN))
        d = UI.job_report_dialog(r, "", String[])
        @test "  inputs = {\"database\": \"Kangaroo Hills (db-1)\", \"grid\": \"gr-9\"}" in d.lines
        @test "  item = \"Kangaroo Hills (db-1)\"" in d.lines
        @test "  max = Infinity" in d.lines && "  min = -Infinity" in d.lines && "  dummy = NaN" in d.lines
        # An empty report says so.
        d = UI.job_report_dialog(fake_job_row(), "", String[])
        @test d.lines[1] == "The job wrote no report."
    end

    @testset "Report, Cancel and Run Again go through the worker" begin
        gate = Channel{Int}(10)
        with_tools([gate_tool(gate)]) do
            with_app(test_app_state(fresh_session())) do app
                s = app.session
                job = Core.run_tool(s, "test.gate")
                put!(gate, 3)
                @test timedwait(() -> job.progress[] >= 0.3, 10) === :ok
                refresh_now!(app)
                r = row_of(app, job)
                UI.show_report!(app, r)
                wait_drained(app)
                d = last(app.ui.dialogs)
                @test d isa ResultDialog && occursin("Step 3 of 10", d.text) && occursin("  steps = 10", d.text)
                UI.cancel_job!(app, r)
                wait_drained(app)
                @test job.cancel[]
                Core.wait_job(job)
                @test Core.status(job) == Core.JOB_CANCELLED

                # Run Again on a cancelled job: it made nothing, so there is nothing to replace.
                refresh_now!(app)
                empty!(app.ui.dialogs)
                UI.run_again!(app, row_of(app, job))
                wait_drained(app)
                d = last(app.ui.dialogs)
                @test d isa ToolDialog && d.form.rerun_of === job && d.form.values["steps"] == 10
                @test !UI.offers_replace(app, d.form)

                # A done job made an item: Run Again offers to replace it.
                done = Core.run_tool(s, "test.gate")
                put!(gate, 10)
                Core.wait_job(done)
                refresh_now!(app)
                empty!(app.ui.dialogs)
                UI.run_again!(app, row_of(app, done))
                wait_drained(app)
                @test UI.offers_replace(app, last(app.ui.dialogs).form)

                # Undone, its output is out of the project: nothing to replace.
                @test Core.undo!(s)
                refresh_now!(app)
                empty!(app.ui.dialogs)
                UI.run_again!(app, row_of(app, done))
                wait_drained(app)
                @test !UI.offers_replace(app, last(app.ui.dialogs).form)

                # A command that is not registered cannot run again.
                @test UI.job_owner("test.gone") === nothing
                @test UI.job_owner("test.gate") isa Core.ToolSpec
                @test UI.job_owner("import.geosoft_xyz") isa Core.ImporterSpec
                @test UI.job_owner("export.csv") isa Core.ExporterSpec
            end
        end
    end
end
