# Plan 1 follow-ups that plan 2 fixes: undo outside the session lock, the sweep
# of leftover side folders, settings that a failed quick tool keeps, job reports
# that are read while a job writes them, and job warnings.
# It runs alone too, with several threads:
#   julia --project=JuliaMagCore -t 4 JuliaMagCore/test/test_followups.jl

using Test
using JSON3
using JuliaMagCore
isdefined(@__MODULE__, :fresh_session) || include(joinpath(@__DIR__, "support", "synthetic.jl"))

# Wait until `f()` is true, at most `timeout` seconds. True when it became true.
await(f::Function, timeout::Real = 30.0) = timedwait(f, Float64(timeout); pollint = 0.001) === :ok

# An undo step on item `item` that logs to `log`. Its undo (or redo, with
# `on = :redo`) puts `true` in `started` and then blocks until something is put
# in `release`, so a test decides how long it runs. `release` is never left
# waiting for long: the test always fills it, and a bug times out after 30 s.
function blocking_step(label, item, log; started = Channel{Bool}(1), release = Channel{Bool}(1), on = :undo,
                       dropped = Ref(false))
    note(what) = lock(() -> push!(log[1], what), log[2])
    run = () -> begin
        note("$label start")
        put!(started, true)
        await(() -> isready(release)) || error("the test never released $label")
        take!(release)
        note("$label end")
        nothing
    end
    plain = () -> (note("$label plain"); nothing)
    step = on == :undo ? UndoStep(label, run, plain, () -> (dropped[] = true; nothing), [item]) :
                         UndoStep(label, plain, run, () -> (dropped[] = true; nothing), [item])
    return step, started, release
end

new_log() = (String[], ReentrantLock())

@testset "follow-ups" begin
    @testset "an undo step runs without the session lock" begin
        (; s, id, L) = make_db_with(MAG = [1.0, 2.0, 3.0])
        log = new_log()
        step, started, release = blocking_step("slow", id, log)
        push_undo!(s, step)
        undoing = Threads.@spawn undo!(s)
        @test take!(started)
        # The session lock is free while the step runs: another task takes it at once.
        took = Threads.Atomic{Float64}(-1.0)
        probe = Threads.@spawn begin
            t = @elapsed lock(s.lock)
            unlock(s.lock)
            took[] = t
        end
        @test await(() -> istaskdone(probe), 10.0)
        @test 0.0 <= took[] < 0.05
        @test !istaskdone(undoing)
        # The step's item is busy while it runs.
        e = try
            set_cell!(s, id, L, "MAG", 1, 9.0)
            nothing
        catch err
            err
        end
        @test e isa ItemBusyError && e.item == id && e.reason == "undo is running"
        @test occursin("undo is running", sprint(showerror, e))
        @test can_undo(s) == false && can_redo(s) == false
        put!(release, true)
        @test fetch(undoing) === true
        @test log[1] == ["slow start", "slow end"]
        @test can_redo(s) && !can_undo(s)
        @test s.history[end].command == "session.undo"
        # The mark is gone again.
        set_cell!(s, id, L, "MAG", 1, 9.0)
        @test read_channel(database(s.project, id), L, "MAG")[1] == 9.0
        close_session!(s)
    end

    @testset "a redo step runs without the session lock" begin
        s = fresh_session()
        log = new_log()
        step, started, release = blocking_step("slow", "x-1", log; on = :redo)
        push_undo!(s, step)
        @test undo!(s)
        redoing = Threads.@spawn redo!(s)
        @test take!(started)
        probe = Threads.@spawn (lock(s.lock); unlock(s.lock); true)
        @test await(() -> istaskdone(probe), 10.0) && fetch(probe)
        e = try
            JuliaMagCore.mark_busy!(s, "x-1")
            nothing
        catch err
            err
        end
        @test e isa ItemBusyError && e.reason == "undo is running"
        @test_throws ItemBusyError JuliaMagCore.mark_reading!(s, "x-1")
        put!(release, true)
        @test fetch(redoing) === true
        @test can_undo(s) && !can_redo(s)
        @test s.history[end].command == "session.redo"
        JuliaMagCore.mark_busy!(s, "x-1"); JuliaMagCore.unmark_busy!(s, "x-1")
        close_session!(s)
    end

    @testset "two undo calls from two tasks undo two steps, in order" begin
        s = fresh_session()
        log = new_log()
        a, a_started, a_release = blocking_step("a", "x-1", log)
        b, b_started, b_release = blocking_step("b", "x-2", log)
        push_undo!(s, a)
        push_undo!(s, b)
        first_undo = Threads.@spawn undo!(s)
        @test take!(b_started)
        second_undo = Threads.@spawn undo!(s)
        # The second undo waits for the first: step a does not start while b runs.
        @test !await(() -> isready(a_started), 0.3)
        put!(b_release, true)
        @test take!(a_started)
        put!(a_release, true)
        @test fetch(first_undo) === true && fetch(second_undo) === true
        @test log[1] == ["b start", "b end", "a start", "a end"]
        @test isempty(s.undo_stack) && [x.label for x in s.redo_stack] == ["b", "a"]
        @test [h.command for h in s.history[end-1:end]] == ["session.undo", "session.undo"]
        close_session!(s)
    end

    @testset "a failed step stays where it was and its marks end" begin
        s = fresh_session()
        tries = Ref(0)
        flaky = () -> (tries[] += 1; tries[] == 1 && error("disk full"); nothing)
        push_undo!(s, UndoStep("first", () -> nothing, () -> nothing, () -> nothing, ["x-1"]))
        step = UndoStep("flaky", flaky, flaky, () -> nothing, ["x-1", "x-2"])
        push_undo!(s, step)
        n = length(s.history)
        @test_throws ErrorException undo!(s)
        @test s.undo_stack[end] === step && length(s.undo_stack) == 2 && isempty(s.redo_stack)
        @test isempty(s.busy) && length(s.history) == n
        @test undo!(s)                                  # retry works
        @test s.redo_stack == [step] && length(s.undo_stack) == 1
        tries[] = 0
        @test_throws ErrorException redo!(s)
        @test s.redo_stack == [step] && length(s.undo_stack) == 1 && isempty(s.busy)
        @test redo!(s) && s.undo_stack[end] === step
        # A busy item refuses the step before it runs, and changes nothing.
        JuliaMagCore.mark_reading!(s, "x-2")
        @test_throws ItemBusyError undo!(s)
        @test s.undo_stack[end] === step && s.busy["x-2"].reading == 1
        JuliaMagCore.unmark_reading!(s, "x-2")
        @test isempty(s.busy)
        close_session!(s)
    end

    @testset "an edit made while an undo runs comes after it" begin
        (; s, id, L) = make_db_with(MAG = [1.0, 2.0, 3.0])
        log = new_log()
        dropped = Ref(false)
        step, started, release = blocking_step("slow", "x-1", log; dropped)
        push_undo!(s, step)
        undoing = Threads.@spawn undo!(s)
        @test take!(started)
        set_cell!(s, id, L, "MAG", 2, 7.0)              # another item: not busy
        @test read_channel(database(s.project, id), L, "MAG")[2] == 7.0
        put!(release, true)
        @test fetch(undoing) === true
        # In the history and on the stacks, the edit follows the undo. So the
        # edit cleared the redo stack, and a script repeats both in that order.
        @test [h.command for h in s.history[end-1:end]] == ["session.undo", "database.set_cell"]
        @test length(s.undo_stack) == 1 && startswith(s.undo_stack[1].label, "set MAG")
        @test isempty(s.redo_stack) && dropped[]
        lines = readlines(joinpath(s.project.folder, "jobs", "history.jsonl"))
        @test [JSON3.read(l)["command"] for l in lines[end-1:end]] == ["session.undo", "database.set_cell"]
        @test undo!(s) && read_channel(database(s.project, id), L, "MAG")[2] == 2.0
        close_session!(s)

        # When the step fails, the edit still comes after it, and the step stays.
        s = fresh_session()
        started, release = Channel{Bool}(1), Channel{Bool}(1)
        fail = () -> (put!(started, true); await(() -> isready(release)); error("no"))
        failing = UndoStep("failing", fail, () -> nothing, () -> nothing, ["x-1"])
        push_undo!(s, failing)
        other = UndoStep("other", () -> nothing, () -> nothing, () -> nothing, ["x-2"])
        undoing = Threads.@spawn try
            undo!(s)
        catch err
            err
        end
        @test take!(started)
        push_undo!(s, other)
        put!(release, true)
        @test fetch(undoing) isa ErrorException
        @test all(h -> h.command != "session.undo", s.history)
        @test [x.label for x in s.undo_stack] == ["failing", "other"] && isempty(s.busy)
        close_session!(s)
    end

    @testset "open_session sweeps leftover side folders" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            id = make_test_database!(s)
            close_session!(s)
            dbs = joinpath(folder, "databases")
            grids = joinpath(folder, "grids")
            leftovers = [joinpath(dbs, ".undo-x"), joinpath(dbs, ".importing-db-9"),
                         joinpath(dbs, id, ".undo-abc"), joinpath(grids, ".importing-grid-3"),
                         joinpath(grids, ".undo-y")]
            for d in leftovers
                mkpath(d)
                write(joinpath(d, "data.bin"), zeros(UInt8, 16))
            end
            keep = joinpath(dbs, "undo-not-hidden")
            mkpath(keep)
            s = open_session(folder)
            @test !any(ispath, leftovers)
            @test isdir(keep) && isdir(joinpath(dbs, id))
            @test length(s.warnings) == length(leftovers)
            for d in leftovers
                @test count(w -> occursin(d, w) && occursin("left after a crash", w), s.warnings) == 1
            end
            close_session!(s)
            # Nothing left: no warnings.
            s = open_session(folder)
            @test isempty(s.warnings)
            close_session!(s)
        end
    end

    @testset "the sweep keeps the bytes of a damaged database" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            id = make_test_database!(s)
            close_session!(s)
            dbfolder = joinpath(folder, "databases", id)
            side = joinpath(dbfolder, ".undo-cut")
            mkpath(side)
            chans = JuliaMagCore.channels_folder(dbfolder)
            for f in readdir(chans)
                open(io -> truncate(io, 0), joinpath(chans, f), "r+")
            end
            s = open_session(folder)
            @test isdir(side)
            @test length(s.warnings) == 1
            @test occursin(side, s.warnings[1]) && occursin("was kept", s.warnings[1])
            close_session!(s)
        end
    end

    @testset "a forced open does not sweep" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            left = joinpath(folder, "databases", ".importing-db-4")
            mkpath(left)
            write(joinpath(folder, JuliaMagCore.LOCK_FILE),
                  JSON3.write(Dict("pid" => 12345, "host" => "other-pc", "user" => "bob",
                                   "started" => "2026-10-01T08:00:00+0200")))
            s = open_session(folder; force = true)
            @test isdir(left)
            @test length(s.warnings) == 2
            @test occursin("not removed", s.warnings[2]) && occursin("force = true", s.warnings[2])
            close_session!(s)
        end
    end

    @testset "a job report can be read while the job writes it" begin
        s = fresh_session()
        go, stop = Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false)
        written = Threads.Atomic{Int}(0)
        # Short lines, at most 50,000: the report stays below the 1 MB cut.
        work = (p, io) -> begin
            await(() -> go[]) || error("the reader never started")
            for k in 1:50_000
                stop[] && break
                println(io, "line ", k)
                written[] = k
                k % 100 == 0 && yield()
            end
            ProjectItem[]
        end
        j = start_job!(s, "test.live_report", Dict{String,Any}(), work; undoable = false)
        reader = Threads.@spawn begin
            problems, reads = String[], 0
            go[] = true
            t0 = time()
            while time() - t0 < 1.0
                text = report_text(j)
                reads += 1
                # Each read holds whole lines, in order.
                (isempty(text) || endswith(text, "\n")) || push!(problems, "a cut line")
                lines = split(text, '\n'; keepempty = false)
                all(k -> lines[k] == "line $k", eachindex(lines)) || push!(problems, "lines out of order")
                yield()
            end
            stop[] = true
            (problems, reads)
        end
        found, nreads = fetch(reader)
        wait_job(j)
        @test status(j) == JOB_DONE
        @test isempty(found) && nreads > 0
        @test j.report isa JuliaMagCore.JobReport
        n = written[]
        @test n > 0 && report_text(j) == join("line $k\n" for k in 1:n)
        close_session!(s)
    end

    @testset "job warnings are kept in the job record" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            j = wait_job(start_job!(s, "test.warns", Dict{String,Any}(), (p, io) -> begin
                job_warning!("first thing to check")
                job_warning!("second thing to check")
                ProjectItem[]
            end))
            @test status(j) == JOB_DONE
            @test job_warnings(j) == ["first thing to check", "second thing to check"]
            @test occursin("first thing to check", report_text(j))
            # Outside a job it does nothing.
            @test job_warning!("nobody hears this") === nothing
            close_session!(s)
            s = open_session(folder)
            @test job_warnings(only(jobs(s))) == ["first thing to check", "second thing to check"]
            close_session!(s)
            # An older record has no warnings field: it loads with none.
            path = joinpath(folder, "jobs", "$(j.id).json")
            rec = JSON3.read(read(path, String), Dict{String,Any})
            delete!(rec, "warnings")
            write(path, JSON3.write(rec))
            s = open_session(folder)
            @test isempty(job_warnings(only(jobs(s))))
            close_session!(s)
        end
    end

    @testset "a failed append that an export blocks keeps its undo" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 2, ties = 0, rows_per_line = 50)
            b = joinpath(dir, "b.xyz"); write_synthetic_xyz(b; lines = 3, ties = 0, rows_per_line = 40, seed = 5)
            j1 = wait_job(import_file(s, a))
            id = only(j1.outputs)
            rows0 = database(s.project, id).rows_written
            # The append is done; then an export starts to read the database, and
            # then the work of the job fails.
            appended, release = Channel{Bool}(1), Channel{Bool}(1)
            j = start_job!(s, "test.failed_append", Dict{String,Any}(), (p, io) -> begin
                import_xyz(s, b; mode = :append, target = id, record = false)
                put!(appended, true)
                take!(release)
                error("the work failed after the append")
            end)
            @test take!(appended)
            JuliaMagCore.mark_reading!(s, id)
            put!(release, true)
            wait_job(j)
            text = "the rows this job appended to $id could not be removed while an export reads it; " *
                   "use Undo when the export ends"
            @test status(j) == JOB_FAILED && j.error == "the work failed after the append"
            @test job_warnings(j) == [text]
            @test occursin(text, report_text(j))
            @test database(s.project, id).rows_written == rows0 + 120
            @test s.undo_stack[end].label == "remove rows of failed $(j.id)"
            rec = JSON3.read(read(joinpath(folder, "jobs", "$(j.id).json"), String))
            @test rec["warnings"] == [text]
            # While the export reads, undo is refused; after it, undo removes the rows.
            @test_throws ItemBusyError undo!(s)
            JuliaMagCore.unmark_reading!(s, id)
            @test undo!(s)
            db = database(s.project, id)
            @test db.rows_written == rows0 && length(db.lines) == 2
            # The failed job is not in the history, so its undo is not either:
            # a script must not undo another step in its place.
            @test all(h -> !(h.command in ("session.undo", "test.failed_append")), s.history)
            @test s.undo_stack[end].label == "import.geosoft_xyz ($(j1.id))"
            close_session!(s)
        end
    end

    @testset "an append in another coordinate system warns" begin
        mktempdir() do dir
            s = new_session(joinpath(dir, "p"), "P")
            a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 2, ties = 0, rows_per_line = 20)
            b = joinpath(dir, "b.xyz"); write_synthetic_xyz(b; lines = 1, ties = 0, rows_per_line = 20, seed = 3)
            id = only(wait_job(import_file(s, a; crs = "EPSG:4283")).outputs)
            j = wait_job(import_file(s, b; mode = "append", target = id, crs = "EPSG:4326"))
            @test status(j) == JOB_DONE
            w = job_warnings(j)
            @test length(w) == 1
            @test occursin("X,Y", w[1]) && occursin("EPSG:4283", w[1]) && occursin("EPSG:4326", w[1])
            @test only(database(s.project, id).pairs).crs == "EPSG:4283"
            # The same system, or none given, does not warn.
            j = wait_job(import_file(s, b; mode = "append", target = id, crs = "EPSG:4283"))
            @test status(j) == JOB_DONE && isempty(job_warnings(j))
            j = wait_job(import_file(s, b; mode = "append", target = id))
            @test status(j) == JOB_DONE && isempty(job_warnings(j))
            close_session!(s)
        end
    end

    @testset "PROJ messages reach the caller" begin
        msgs = String[]
        @test JuliaMagCore.with_crs(_ -> true, "EPSG:999999"; messages = msgs) === nothing
        @test msgs == ["proj_create: crs not found: EPSG:999999"]
        # Each call collects its own lines, also on many threads at once.
        codes = ["EPSG:99999$k" for k in 0:7]
        tasks = [Threads.@spawn begin
                     got = String[]
                     for _ in 1:50
                         lines = String[]
                         JuliaMagCore.with_crs(_ -> true, c; messages = lines)
                         append!(got, lines)
                     end
                     got
                 end for c in codes]
        @test [fetch(t) for t in tasks] == [fill("proj_create: crs not found: $c", 50) for c in codes]
        # PROJ itself logs nothing for a ballpark transformation; the reprojector asks
        # which operation it used.
        r = JuliaMagCore.Reprojector("EPSG:4326", "EPSG:4610")
        ox, oy = zeros(2), zeros(2)
        JuliaMagCore.reproject!(r, [110.0, 110.1], [30.0, 30.1], ox, oy)
        said = JuliaMagCore.proj_messages(r)
        close(r)
        @test length(said) == 1 && occursin("Ballpark geographic offset from WGS 84 to Xian 1980", said[1])
        r = JuliaMagCore.Reprojector("EPSG:4326", "EPSG:32755")
        JuliaMagCore.reproject!(r, [147.1, 147.2], [-19.5, -19.6], ox, oy)
        @test isempty(JuliaMagCore.proj_messages(r))
        close(r)
    end

    @testset "a ballpark reprojection says so in the job report" begin
        (; s, id) = make_db_with(LON = [110.0, 110.1, 110.2], LAT = [30.0, 30.1, 30.2])
        db = database(s.project, id)
        push!(db.pairs, PositionPair("LON", "LAT", "EPSG:4326"))
        db.current_pair = 1
        save_meta(db)
        job = wait_job(run_tool(s, "coordinates.reproject"; inputs = Dict("database" => id), pair = "LON,LAT",
                                crs = "EPSG:4610"))
        @test status(job) == JOB_DONE
        @test occursin("Ballpark geographic offset from WGS 84 to Xian 1980", report_text(job))
        @test length(job_warnings(job)) == 1
        job = wait_job(run_tool(s, "coordinates.reproject"; inputs = Dict("database" => id), pair = "LON,LAT",
                                crs = "EPSG:32649"))
        @test status(job) == JOB_DONE && !occursin("allpark", report_text(job)) && isempty(job_warnings(job))
        close_session!(s)
    end

    @testset "a held history entry that cannot be saved warns its job" begin
        s = fresh_session()
        j = wait_job(start_job!(s, "test.held", Dict{String,Any}(), (p, io) -> ProjectItem[]; undoable = false))
        path = joinpath(s.project.folder, "jobs", "history.jsonl")
        rm(path; force = true)
        mkpath(path)                                     # a folder: the line cannot be written
        e = JuliaMagCore.HistoryEntry(JuliaMagCore.now_text(), "test.held", Dict{String,Any}(), j.id)
        lock(() -> JuliaMagCore.add_held!(s, e), s.lock)
        @test length(job_warnings(j)) == 1
        @test startswith(only(job_warnings(j)), "the history entry of this job could not be saved")
        @test any(w -> occursin("test.held", w), s.warnings)
        close_session!(s)
    end

    try
        register_tool!(ToolSpec("test.followups.maybe", "Maybe", "", "", Place[], Pair{String,ItemKind}[],
            [NumberSetting("factor", "Factor"; default = 1.0)], :quick,
            (s, i, st, p, r) -> st["factor"] == 5.0 ? error("five is bad") : nothing))
        @testset "a quick tool that fails keeps the remembered settings" begin
            mktempdir() do dir
                folder = joinpath(dir, "p")
                s = new_session(folder, "P")
                @test run_tool(s, "test.followups.maybe"; factor = 3.0)[1]
                @test last_settings(s, "test.followups.maybe")["factor"] == 3.0
                ok, msg, _ = run_tool(s, "test.followups.maybe"; factor = 5.0)
                @test !ok && msg == "Tool failed: five is bad"
                @test last_settings(s, "test.followups.maybe")["factor"] == 3.0
                close_session!(s)
                s = open_session(folder)
                @test last_settings(s, "test.followups.maybe")["factor"] == 3.0
                close_session!(s)
            end
        end
    finally
        unregister_tool!("test.followups.maybe")
    end
end
