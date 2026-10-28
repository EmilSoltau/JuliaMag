using JSON3

@testset "jobs" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "a.xyz"); write_synthetic_xyz(f; rows_per_line = 20_000)
        j = import_file(s, f); wait_job(j)
        @test status(j) == JOB_DONE && length(s.project.items) == 1
        @test undo!(s) && isempty(s.project.items) && status(j) == JOB_UNDONE

        j2 = import_file(s, f); cancel!(j2); wait_job(j2)               # Review Focus 3
        @test status(j2) == JOB_CANCELLED
        @test isempty(s.project.items)
        @test !any(startswith(".importing-"), readdir(joinpath(s.project.folder, "databases")))

        j3 = start_job!(s, "test.fail", Dict{String,Any}(), (p, r) -> error("disk full"))
        wait_job(j3)                                                     # Review Focus 3
        @test status(j3) == JOB_FAILED && occursin("disk full", j3.error)
        @test length(jobs(open_session(s.project.folder))) == 3
    end
end

@testset "job records, ids and history" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "a.xyz"); write_synthetic_xyz(f; lines = 2, ties = 0, rows_per_line = 50)
        j = import_file(s, f; crs = "EPSG:7855"); wait_job(j)
        @test j.id == "job-1" && status(j) == JOB_DONE && j.progress[] == 1.0
        @test !isempty(j.started) && !isempty(j.finished) && isempty(j.error)
        it = only(s.project.items)
        @test j.outputs == [it.id] && it.made_by == j.id
        @test occursin("100 rows", String(take!(copy(j.report))))
        # Recorded once, with the job id.
        @test count(e -> e.command == "import.geosoft_xyz", s.history) == 1
        e = s.history[end]
        @test e.command == "import.geosoft_xyz" && e.job == j.id
        @test e.args["path"] == f && e.args["crs"] == "EPSG:7855"

        # Undo and redo change the item list and the saved record.
        record(j) = JSON3.read(read(joinpath(s.project.folder, "jobs", "$(j.id).json"), String))
        @test record(j).status == "JOB_DONE"
        @test undo!(s) && status(j) == JOB_UNDONE && record(j).status == "JOB_UNDONE"
        @test isdir(joinpath(s.project.folder, it.path))        # files are kept
        @test redo!(s) && status(j) == JOB_DONE && only(s.project.items).id == it.id
        @test record(j).status == "JOB_DONE"
        @test only(open_project(s.project.folder).items).id == it.id

        # Ids are never used twice, also in a new session.
        j2 = start_job!(s, "test.ok", Dict{String,Any}(), (p, r) -> ProjectItem[]); wait_job(j2)
        @test j2.id == "job-2" && status(j2) == JOB_DONE
        rm(joinpath(s.project.folder, "jobs", "job-2.json"))
        s2 = open_session(s.project.folder)
        @test [x.id for x in jobs(s2)] == ["job-1"]
        @test status(only(jobs(s2))) == JOB_DONE
        @test occursin("100 rows", String(take!(copy(only(jobs(s2)).report))))
        j3 = start_job!(s2, "test.ok", Dict{String,Any}(), (p, r) -> ProjectItem[]); wait_job(j3)
        @test j3.id == "job-3"
        @test [x.id for x in jobs(s2)] == ["job-3", "job-1"]       # newest first
    end
end

@testset "job failures never escape" begin
    s = fresh_session()
    # No importer for the file type: a failed job, not an exception.
    j = import_file(s, joinpath(s.project.folder, "a.unknown")); wait_job(j)
    @test status(j) == JOB_FAILED && occursin("no importer", j.error)
    # A missing file.
    j = import_file(s, joinpath(s.project.folder, "missing.xyz")); wait_job(j)
    @test status(j) == JOB_FAILED && isempty(s.project.items)
    # Work that returns the wrong thing.
    j = start_job!(s, "test.bad", Dict{String,Any}(), (p, r) -> 42); wait_job(j)
    @test status(j) == JOB_FAILED && occursin("ProjectItem", j.error)
    # A failed job removes the temp folder it made, and no item is added.
    j = start_job!(s, "test.tmp", Dict{String,Any}(), (p, r) -> begin
        tmp = joinpath(s.project.folder, "databases", ".importing-test")
        mkpath(tmp)
        JuliaMagCore.note_job_folder!(tmp)
        error("stopped")
    end)
    wait_job(j)
    @test status(j) == JOB_FAILED
    @test !isdir(joinpath(s.project.folder, "databases", ".importing-test"))
    # Cancel turns any exception into JOB_CANCELLED.
    started = Threads.Atomic{Bool}(false)
    j = start_job!(s, "test.cancel", Dict{String,Any}(), (p, r) -> begin
        started[] = true
        while !is_cancelled(p)
            Base.yield()
        end
        error("saw the cancel")
    end)
    while !started[]
        Base.yield()
    end
    cancel!(j); wait_job(j)
    @test status(j) == JOB_CANCELLED
    # Failed and cancelled jobs are not recorded and have no undo step.
    @test !any(e -> e.command in ("test.bad", "test.tmp", "test.cancel"), s.history)
    @test !can_undo(s)
    # A long report is cut when saved.
    j = start_job!(s, "test.report", Dict{String,Any}(), (p, r) -> (write(r, repeat("x", 2 << 20)); ProjectItem[]))
    wait_job(j)
    saved = JSON3.read(read(joinpath(s.project.folder, "jobs", "$(j.id).json"), String))
    @test sizeof(saved.report) < (1 << 20) + 200 && occursin("cut", saved.report)
end

@testset "run a job again" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "a.xyz"); write_synthetic_xyz(f; lines = 2, ties = 0, rows_per_line = 50)
        j = import_file(s, f; name = "first"); wait_job(j)
        old = only(s.project.items)
        # Run again with other args: a second item.
        j2 = rerun!(s, j; args = merge(j.args, Dict{String,Any}("name" => "second"))); wait_job(j2)
        @test status(j2) == JOB_DONE && j2.command == j.command
        @test [i.name for i in s.project.items] == ["first", "second"]
        # Run again and replace: the old outputs go once the new job is done.
        j3 = rerun!(s, j2; replace = true); wait_job(j3)
        @test status(j3) == JOB_DONE
        @test [i.name for i in s.project.items] == ["first", "second"]
        @test !any(i -> i.id in j2.outputs, s.project.items)
        @test status(j2) == JOB_UNDONE
        @test undo!(s)                       # undo the replace: j2's item is back
        @test any(i -> i.id in j2.outputs, s.project.items) && !any(i -> i.id in j3.outputs, s.project.items)
        @test status(j2) == JOB_DONE && status(j3) == JOB_UNDONE
        @test old in s.project.items
        # A command that cannot run again gives a failed job.
        jf = start_job!(s, "test.once", Dict{String,Any}(), (p, r) -> ProjectItem[]); wait_job(jf)
        jr = rerun!(s, jf); wait_job(jr)
        @test status(jr) == JOB_FAILED && occursin("test.once", jr.error)
    end
end

@testset "import_xyz records when called directly" begin
    s = fresh_session()
    f = joinpath(s.project.folder, "a.xyz"); write_synthetic_xyz(f; lines = 1, ties = 0, rows_per_line = 10)
    import_xyz(s, f)
    @test count(e -> e.command == "import.geosoft_xyz", s.history) == 1
    @test s.history[end].job == ""
end

@testset "open_database during an append keeps the data (R8)" begin
    s = fresh_session()
    dir = joinpath(s.project.folder, "databases", "r8")
    db = create_database(dir, "r8")
    add_channel!(db, ChannelInfo("MAG", "MAG", Float64, "nT", ROLE_NONE, :normal, 10, -1, false, 1))
    save_meta(db)
    apps = open_appenders(db, ["MAG"])
    add_line!(db, LineInfo(LineId(LINE, 1, 0), 1, "", 0.0, 1.0, 3, 0, true))
    foreach(x -> append_value!(apps["MAG"], x), [1.0, 2.0, 3.0])
    # Ends line 1: its rows are written and committed. Line 2 is still open.
    add_line!(db, LineInfo(LineId(LINE, 2, 0), 1, "", 0.0, 1.0, 2, 0, true))
    append_value!(apps["MAG"], 4.0)
    save_meta(db)                     # lists line 2, which is still open
    view = open_database(dir)         # must not cut the live files
    @test view.rows_written == 3 && [l.id.number for l in view.lines] == [1]
    @test collect(read_channel(view, LineId(LINE, 1, 0), "MAG")) == [1.0, 2.0, 3.0]
    @test JuliaMagCore.values_in_file(view, channel(view, "MAG")) == 3
    append_value!(apps["MAG"], 5.0)
    close_appenders!(apps)
    save_meta(db)
    db2 = open_database(dir)
    @test collect(read_channel(db2, LineId(LINE, 1, 0), "MAG")) == [1.0, 2.0, 3.0]
    @test collect(read_channel(db2, LineId(LINE, 2, 0), "MAG")) == [4.0, 5.0]
    # After closing, open_database cuts uncommitted rows again.
    apps = open_appenders(db2, ["MAG"])
    add_line!(db2, LineInfo(LineId(LINE, 3, 0), 1, "", 0.0, 1.0, 1, 0, true))
    append_value!(apps["MAG"], 6.0)
    close_appenders!(apps)            # file has 6 rows, database.json says 5
    db3 = open_database(dir)
    @test db3.rows_written == 5
    @test JuliaMagCore.values_in_file(db3, channel(db3, "MAG")) == 5
    @test isempty(JuliaMagCore.APPENDING)
end

# ---- fix round 1 -------------------------------------------------------------

"Byte size of each file in the channels folder of a database."
channel_sizes(db) = Dict(f => filesize(joinpath(db.folder, "channels", f)) for f in readdir(joinpath(db.folder, "channels")))

@testset "undo and redo of an append job" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 2, ties = 0, rows_per_line = 50)
        b = joinpath(dir, "b.xyz")
        write_synthetic_xyz(b; lines = 3, ties = 1, rows_per_line = 40, seed = 5,
                            channels = ["X", "Y", "FIDUCIAL", "MAG", "ALT", "GRAD"])
        j1 = import_file(s, a); wait_job(j1)
        id = only(j1.outputs)
        db0 = database(s.project, id)
        meta0 = read(joinpath(db0.folder, "database.json"), String)
        sizes0 = channel_sizes(db0)
        j2 = import_file(s, b; mode = "append", target = id); wait_job(j2)
        @test status(j2) == JOB_DONE && isempty(j2.outputs)
        db1 = database(s.project, id)
        @test length(db1.lines) == 6 && any(c -> c.name == "GRAD", db1.channels)
        meta1 = read(joinpath(db1.folder, "database.json"), String)
        sizes1 = channel_sizes(db1)
        mag1 = collect(read_channel(db1, db1.lines[end].id, "MAG"))
        # Undo puts the database back exactly.
        @test undo!(s) && status(j2) == JOB_UNDONE
        @test read(joinpath(db0.folder, "database.json"), String) == meta0
        @test channel_sizes(database(s.project, id)) == sizes0
        @test length(database(s.project, id).lines) == 2
        # Redo brings the appended lines back.
        @test redo!(s) && status(j2) == JOB_DONE
        @test read(joinpath(db0.folder, "database.json"), String) == meta1
        db2 = database(s.project, id)
        @test channel_sizes(db2) == sizes1
        @test collect(read_channel(db2, db2.lines[end].id, "MAG")) == mag1
        @test !any(startswith(".undo-"), readdir(db0.folder))
        # Undo again, then a new action drops the redo: the side copy is removed.
        @test undo!(s)
        @test any(startswith(".undo-"), readdir(db0.folder))
        set_line_selected!(s, id, db0.lines[1].id, false)
        @test !any(startswith(".undo-"), readdir(db0.folder))
        @test channel_sizes(database(s.project, id)) == sizes0
    end
end

@testset "a running append does not block the session" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 1, ties = 0, rows_per_line = 10)
        j1 = import_file(s, a); wait_job(j1)
        id = only(j1.outputs)
        L = database(s.project, id).lines[1].id
        entered = Threads.Atomic{Bool}(false)
        gate = Threads.Atomic{Bool}(false)
        # The import stops at its first cancel check until the gate opens.
        slow = (p, r) -> begin
            held = Progress(x -> report(p, x), () -> begin
                entered[] = true
                while !gate[]
                    sleep(0.001)
                end
                is_cancelled(p)
            end)
            import_xyz(s, a; mode = :append, target = id, progress = held, record = false)
            ProjectItem[]
        end
        j2 = start_job!(s, "test.slow_append", Dict{String,Any}(), slow)
        # A watchdog, so a blocking session makes the test fail instead of hang.
        Threads.@spawn (sleep(10); gate[] = true)
        while !entered[]
            sleep(0.001)
        end
        t = @elapsed begin
            @test length(jobs(s)) == 2
            j3 = start_job!(s, "test.ok", Dict{String,Any}(), (p, r) -> ProjectItem[]); wait_job(j3)
            @test status(j3) == JOB_DONE
            @test can_undo(s)
            @test length(database(s.project, id).lines) == 1      # the committed view
        end
        @test t < 5
        @test status(j2) == JOB_RUNNING
        err = try
            set_cell!(s, id, L, "MAG", 1, 1.0); nothing
        catch e
            e
        end
        @test err isa ItemBusyError && occursin("$id is busy: an import is running", sprint(showerror, err))
        @test_throws ItemBusyError set_line_selected!(s, id, L, false)
        @test_throws ItemBusyError import_xyz(s, a; mode = :append, target = id)
        gate[] = true
        wait_job(j2)
        @test status(j2) == JOB_DONE
        @test length(database(s.project, id).lines) == 2
        set_line_selected!(s, id, L, false)                       # free again
        @test !line(database(s.project, id), L).selected
        @test_throws ProtectedError set_cell!(s, id, L, "MAG", 1, 1.0)   # imported channels are protected
    end
end

@testset "cancel in the middle of an import" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "big.xyz"); write_synthetic_xyz(f; lines = 12, ties = 0, rows_per_line = 50_000)
        j = import_file(s, f)
        while j.progress[] == 0 && status(j) == JOB_RUNNING
            Base.yield()
        end
        cancel!(j); wait_job(j)
        @test status(j) == JOB_CANCELLED
        @test isempty(s.project.items)
        @test !any(startswith(".importing-"), readdir(joinpath(s.project.folder, "databases")))
    end
end

@testset "a failed job removes the items its work added" begin
    s = fresh_session()
    j = start_job!(s, "test.half", Dict{String,Any}(), (p, r) -> begin
        add_item!(s.project, ProjectItem(new_item_id(s.project, ITEM_GRID), ITEM_GRID, "half", "grids/half", "", ""))
        mkpath(joinpath(s.project.folder, "grids", "half"))
        error("stopped after adding an item")
    end)
    wait_job(j)
    @test status(j) == JOB_FAILED
    @test isempty(s.project.items)
    @test isempty(open_project(s.project.folder).items)
    @test !isdir(joinpath(s.project.folder, "grids", "half"))
end

@testset "a cancelled job keeps the real error" begin
    s = fresh_session()
    started = Threads.Atomic{Bool}(false)
    j = start_job!(s, "test.cancel", Dict{String,Any}(), (p, r) -> begin
        started[] = true
        while !is_cancelled(p)
            Base.yield()
        end
        error("disk full while stopping")
    end)
    while !started[]
        Base.yield()
    end
    cancel!(j); wait_job(j)
    @test status(j) == JOB_CANCELLED && occursin("disk full while stopping", j.error)
end

# ---- fix round 2 -------------------------------------------------------------

"""
Start an append of `file` into item `id` as a job that waits at its first cancel
check until `gate` opens. Returns the job once the append holds the item.
A watchdog opens the gate after 10 s, so a blocked test fails instead of hanging.
"""
function gated_append(s, file, id, gate)
    entered = Threads.Atomic{Bool}(false)
    work = (p, r) -> begin
        held = Progress(x -> report(p, x), () -> begin
            entered[] = true
            while !gate[]
                sleep(0.001)
            end
            is_cancelled(p)
        end)
        import_xyz(s, file; mode = :append, target = id, progress = held, record = false)
        ProjectItem[]
    end
    j = start_job!(s, "test.gated_append", Dict{String,Any}(), work)
    Threads.@spawn (sleep(10); gate[] = true)
    while !entered[]
        sleep(0.001)
    end
    return j
end

@testset "undo and redo wait for a busy item" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 1, ties = 0, rows_per_line = 10)
        j1 = import_file(s, a); wait_job(j1)
        id = only(j1.outputs)
        L = database(s.project, id).lines[1].id
        selected() = line(database(s.project, id), L).selected
        set_line_selected!(s, id, L, false)
        set_line_selected!(s, id, L, true)
        @test undo!(s) && !selected()          # one step to undo, one to redo
        gate = Threads.Atomic{Bool}(false)
        j2 = gated_append(s, a, id, gate)
        @test_throws ItemBusyError undo!(s)
        @test_throws ItemBusyError redo!(s)
        @test !selected() && can_undo(s) && can_redo(s)
        gate[] = true
        wait_job(j2)
        @test status(j2) == JOB_DONE
        @test !selected()                      # the append's commit kept the state
        @test !can_redo(s)                     # the finished job is a new step
        @test undo!(s) && length(database(s.project, id).lines) == 1   # the append
        @test undo!(s) && selected()           # the first deselect
        @test redo!(s) && !selected()
    end
end

@testset "undo of an append refuses a changed database" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 1, ties = 0, rows_per_line = 10)
        j1 = import_file(s, a); wait_job(j1)
        id = only(j1.outputs)
        j2 = import_file(s, a; mode = "append", target = id); wait_job(j2)
        db = database(s.project, id)
        db.description = "changed outside the session"
        save_meta(db)
        meta = read(joinpath(db.folder, "database.json"), String)
        @test_throws DatabaseError undo!(s)
        @test can_undo(s) && status(j2) == JOB_DONE
        @test read(joinpath(db.folder, "database.json"), String) == meta
        @test length(database(s.project, id).lines) == 2
        @test !any(startswith(".undo-"), readdir(db.folder))
    end
end

@testset "replace keeps an old output that is busy" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 1, ties = 0, rows_per_line = 10)
        j1 = import_file(s, a); wait_job(j1)
        id = only(j1.outputs)
        gate = Threads.Atomic{Bool}(false)
        j2 = gated_append(s, a, id, gate)
        j3 = rerun!(s, j1; replace = true); wait_job(j3)
        @test status(j3) == JOB_DONE
        @test any(i -> i.id == id, s.project.items)               # kept
        @test occursin("$id is busy", String(take!(copy(j3.report))))
        @test status(j1) == JOB_DONE
        gate[] = true
        wait_job(j2)
        @test status(j2) == JOB_DONE
        @test length(database(s.project, id).lines) == 2
    end
end

# ---- final review fixes ------------------------------------------------------

@testset "a reader at the end of an append does not cut it (C1)" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 3, ties = 0, rows_per_line = 1000)
        b = joinpath(dir, "b.xyz"); write_synthetic_xyz(b; lines = 3, ties = 0, rows_per_line = 1000, seed = 2)
        id = import_xyz(s, a; record = false).item.id
        # A reader, such as an export in another job, opens the database when the
        # import says 100 %. The rows are in the files then, but not committed.
        seen = Int[]
        reader = Progress(f -> (f == 1.0 && push!(seen, total_rows(database(s.project, id)))), () -> false)
        r = import_xyz(s, b; mode = :append, target = id, progress = reader, record = false)
        @test r.rows == 3000 && !isempty(seen) && all(==(3000), seen)
        db = database(s.project, id)
        @test db.rows_written == 6000 && length(db.lines) == 6
        ref = database_of(s, import_xyz(s, b; record = false))
        for (l, k) in zip(db.lines[4:6], ref.lines), c in ("X", "MAG", "ALT")
            @test isequal(collect(read_channel(db, l.id, c)), collect(read_channel(ref, k.id, c)))
        end
        @test isempty(JuliaMagCore.APPENDING)
    end
end

@testset "a job keeps its items busy until its undo step is in place (I1)" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 1, ties = 0, rows_per_line = 10)
        id = only(wait_job(import_file(s, a)).outputs)
        L = database(s.project, id).lines[1].id
        selected() = line(database(s.project, id), L).selected
        # An edit after the append is done, but before the job has pushed its undo step.
        in_window = Ref{Any}(nothing)
        j = start_job!(s, "test.append_then_edit", Dict{String,Any}(), (p, r) -> begin
            import_xyz(s, a; mode = :append, target = id, record = false)
            in_window[] = try
                set_line_selected!(s, id, L, false); nothing
            catch e
                e
            end
            ProjectItem[]
        end)
        wait_job(j)
        @test status(j) == JOB_DONE && isempty(s.busy)
        @test in_window[] isa ItemBusyError && selected()
        set_line_selected!(s, id, L, false)
        @test undo!(s) && selected()                                     # the edit
        @test undo!(s) && length(database(s.project, id).lines) == 1     # the append
        @test redo!(s) && redo!(s) && !selected() && length(database(s.project, id).lines) == 2
    end

    # Channel Math overwrites a channel in place. An edit in the same window
    # would land below the job's undo step.
    (; s, id, L) = make_db_with(MAG = [1.0, 2.0, 3.0], B = [10.0, 20.0, 30.0])
    spec = JuliaMagCore.tool("database.channel_math")
    st = merge(default_settings(spec), Dict{String,Any}("expr" => "MAG = MAG * 2"))
    in_window = Ref{Any}(nothing)
    j = start_job!(s, "test.channel_math_then_edit", Dict{String,Any}(), (p, r) -> begin
        spec.run(s, Dict("database" => id), copy(st), p, r)
        in_window[] = try
            set_cell!(s, id, L, "MAG", 1, 100.0); nothing
        catch e
            e
        end
        ProjectItem[]
    end)
    wait_job(j)
    mag() = collect(read_channel(database(s.project, id), L, "MAG"))
    @test status(j) == JOB_DONE && isempty(s.busy)
    @test in_window[] isa ItemBusyError && mag() == [2.0, 4.0, 6.0]
    set_cell!(s, id, L, "MAG", 1, 100.0)
    @test mag() == [100.0, 4.0, 6.0]
    @test undo!(s) && mag() == [2.0, 4.0, 6.0]
    @test undo!(s) && mag() == [1.0, 2.0, 3.0]
end

@testset "a failed job ends its busy marks too (I1)" begin
    (; s, id) = make_db_with(MAG = [1.0, 2.0, 3.0])
    spec = JuliaMagCore.tool("database.channel_math")
    st = merge(default_settings(spec), Dict{String,Any}("expr" => "MAG = MAG + 1"))
    j = start_job!(s, "test.fail_after_tool", Dict{String,Any}(), (p, r) -> begin
        spec.run(s, Dict("database" => id), copy(st), p, r)
        error("stopped after the tool")
    end)
    wait_job(j)
    @test status(j) == JOB_FAILED && isempty(s.busy)
    @test collect(read_channel(database(s.project, id), LineId(LINE, 1001, 0), "MAG")) == [1.0, 2.0, 3.0]
end

@testset "an undone import that cannot be redone leaves no folder (I5)" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 2, ties = 0, rows_per_line = 100)
        dbs = joinpath(s.project.folder, "databases")
        id = only(wait_job(import_file(s, a)).outputs)
        @test undo!(s) && readdir(dbs) == ["a"]          # redo still needs the folder
        j2 = wait_job(import_file(s, a))                 # clears the redo stack
        @test !can_redo(s) && [i.id for i in s.project.items] == j2.outputs
        @test readdir(dbs) == ["a-2"]
        # A replaced output that comes back with undo keeps its folder; the new one goes.
        j3 = wait_job(rerun!(s, j2; replace = true))
        @test status(j3) == JOB_DONE && sort(readdir(dbs)) == ["a", "a-2"]
        @test undo!(s) && [i.id for i in s.project.items] == j2.outputs
        set_line_selected!(s, only(j2.outputs), LineId(LINE, 1001, 0), false)   # drops the redo
        @test readdir(dbs) == ["a-2"]
        @test id != only(j2.outputs)
    end
end

@testset "a dropped step keeps a folder that an item still uses (I5)" begin
    s = fresh_session()
    keep = joinpath(s.project.folder, "grids", "shared")
    mkpath(keep)
    shared = ProjectItem(new_item_id(s.project, ITEM_GRID), ITEM_GRID, "shared", "grids/shared", "", "")
    j = wait_job(start_job!(s, "test.add", Dict{String,Any}(), (p, r) -> begin
        it = ProjectItem(new_item_id(s.project, ITEM_GRID), ITEM_GRID, "twin", "grids/shared", "", "")
        add_item!(s.project, it)
        ProjectItem[it]
    end))
    @test status(j) == JOB_DONE
    @test undo!(s)
    add_item!(s.project, shared); save_project(s.project)
    wait_job(start_job!(s, "test.ok", Dict{String,Any}(), (p, r) -> ProjectItem[]))   # drops the redo
    @test isdir(keep)
end

@testset "a failed undo of an append leaves the step to try again (I4)" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 2, ties = 0, rows_per_line = 50)
        b = joinpath(dir, "b.xyz")
        write_synthetic_xyz(b; lines = 1, ties = 0, rows_per_line = 40, seed = 5,
                            channels = ["X", "Y", "FIDUCIAL", "MAG", "ALT", "GRAD"])
        id = only(wait_job(import_file(s, a)).outputs)
        db0 = database(s.project, id)
        sizes0 = channel_sizes(db0)
        j2 = wait_job(import_file(s, b; mode = "append", target = id))
        @test status(j2) == JOB_DONE
        meta1 = read(joinpath(db0.folder, "database.json"), String)
        sizes1 = channel_sizes(db0)
        # The last old channel file cannot be cut, as on Windows while a stray map holds it.
        alt = joinpath(db0.folder, "channels", only(f for f in keys(sizes0) if startswith(f, "ALT")))
        chmod(alt, 0o444)
        try
            @test_throws Exception undo!(s)
        finally
            chmod(alt, 0o644)
        end
        @test read(joinpath(db0.folder, "database.json"), String) == meta1
        @test channel_sizes(db0) == sizes1                  # the cut files were put back
        @test !any(startswith(".undo-"), readdir(db0.folder))
        @test can_undo(s) && status(j2) == JOB_DONE
        @test length(database(s.project, id).lines) == 3
        @test undo!(s) && status(j2) == JOB_UNDONE           # try again
        @test channel_sizes(database(s.project, id)) == sizes0
        @test length(database(s.project, id).lines) == 2
        @test redo!(s) && channel_sizes(database(s.project, id)) == sizes1
    end
end
