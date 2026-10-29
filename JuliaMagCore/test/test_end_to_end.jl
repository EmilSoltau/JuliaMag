using Test, JuliaMagCore

# A user session from the REPL, start to end, then a replay of its script.
@testset "end to end: import, UTM, reproject, math, edit, export, replay" begin
    root = mktempdir()
    folder = joinpath(root, "Survey (sh) 2024", "my project")
    xyz = joinpath(root, "flight data.xyz")
    write_synthetic_xyz(xyz; lines = 3, ties = 1, rows_per_line = 200,
                        channels = ["LON", "LAT", "X", "Y", "FIDUCIAL", "MAG", "ALT"])

    s = new_session(folder, "Survey")
    # the empty project is copied aside, so the script can be replayed on it
    copy_folder = joinpath(root, "copy (sh)", "my project")
    mkpath(dirname(copy_folder))
    cp(folder, copy_folder)

    job = wait_job(import_file(s, xyz))
    @test status(job) == JOB_DONE
    id = only(job.outputs)
    ins = Dict("database" => id)
    db = database(s.project, id)
    @test length(db.lines) == 4

    ok, message, _ = run_tool(s, "coordinates.guess_utm"; inputs = ins)
    @test ok
    @test occursin("EPSG:32633", message)

    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT", crs = "EPSG:32633"))
    @test status(job) == JOB_DONE
    db = database(s.project, id)
    @test "X_32633" in [c.name for c in db.channels]

    job = wait_job(run_tool(s, "database.channel_math"; inputs = ins, expr = "MAG_C = MAG - 50000", lines = "all"))
    @test status(job) == JOB_DONE
    L = LineId(LINE, 1001, 0)
    db = database(s.project, id)
    mag = collect(read_channel(db, L, "MAG"))
    @test isequal(collect(read_channel(db, L, "MAG_C")), mag .- 50000)

    # edit one cell of the new channel, then undo it
    old = read_channel(db, L, "MAG_C")[5]
    set_cell!(s, id, L, "MAG_C", 5, 123.5)
    @test read_channel(database(s.project, id), L, "MAG_C")[5] == 123.5
    @test undo!(s)
    @test isequal(read_channel(database(s.project, id), L, "MAG_C")[5], old)
    @test redo!(s)
    @test read_channel(database(s.project, id), L, "MAG_C")[5] == 123.5

    csv = joinpath(root, "out file.csv")
    job = wait_job(export_file(s, id, csv))
    @test status(job) == JOB_DONE
    @test isfile(csv) && countlines(csv) > 800

    script = joinpath(root, "session script.jl")
    write(script, script_text(s))

    # a new session on the same folder still has the jobs and the history
    s2 = open_session(folder)
    @test [j.command for j in jobs(s2)] == [j.command for j in jobs(s)]
    @test all(j -> status(j) == JOB_DONE, jobs(s2))
    @test length(s2.history) == length(s.history)
    @test [e.command for e in s2.history] == [e.command for e in s.history]

    # replay the script on the copy of the empty project
    replay = replace(read(script, String), repr(folder) => repr(copy_folder))
    @test occursin(repr(copy_folder), replay)
    include_string(Module(), replay)
    a = database(open_project(folder), id)
    b = database(open_project(copy_folder), id)
    @test [c.name for c in a.channels] == [c.name for c in b.channels]
    @test [l.id for l in a.lines] == [l.id for l in b.lines]
    for l in a.lines, c in a.channels
        @test isequal(collect(read_channel(a, l.id, c.name)), collect(read_channel(b, l.id, c.name)))
    end
end
