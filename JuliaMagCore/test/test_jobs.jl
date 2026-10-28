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
