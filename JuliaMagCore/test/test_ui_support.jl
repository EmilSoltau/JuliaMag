# Core support for a UI: the change counter, the warnings reader and the
# closed state of a session.

using Test
using JuliaMagCore
isdefined(@__MODULE__, :fresh_session) || include(joinpath(@__DIR__, "support", "synthetic.jl"))

@testset "UI support: revision, warnings and closed sessions" begin
    small = joinpath(mktempdir(), "small.xyz")
    write_synthetic_xyz(small; lines = 2, ties = 0, rows_per_line = 20)

    @testset "revision, warnings, isopen and closed errors" begin
        s = fresh_session()
        r0 = revision(s)
        id = make_test_database!(s)
        # `make_test_database!` uses `add_item!`, which is not a session change.
        rename_item!(s, id, "renamed")
        @test revision(s) > r0
        r1 = revision(s)
        set_line_selected!(s, id, first(database(s.project, id).lines).id, false)
        @test revision(s) > r1
        r2 = revision(s)
        undo!(s)
        @test revision(s) > r2
        r2b = revision(s)
        redo!(s)
        @test revision(s) > r2b
        r2c = revision(s)
        set_cursor!(s, Cursor(id, first(database(s.project, id).lines).id, 1))
        @test revision(s) > r2c
        r2d = revision(s)
        set_marked!(s, (1, 2))
        @test revision(s) > r2d
        r3 = revision(s)
        JuliaMagCore.session_warning!(s, "w1")
        @test revision(s) > r3 && warnings(s)[end] == "w1"
        # The copy is not the session's own vector.
        push!(warnings(s), "x")
        @test warnings(s)[end] == "w1"
        job = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = "MAG2 = MAG * 2",
                       lines = "all")
        r4 = revision(s)
        wait_job(job)
        @test revision(s) > r4
        @test isopen(s)
        close_session!(s)
        @test !isopen(s)
        @test_throws SessionClosedError rename_item!(s, id, "x")
        @test_throws SessionClosedError undo!(s)
        @test_throws SessionClosedError redo!(s)
        @test_throws SessionClosedError import_file(s, small)
        @test_throws SessionClosedError set_grid_crs!(s, "grid-1", "")
        err = try
            undo!(s)
        catch e
            e
        end
        @test sprint(showerror, err) == "The project $(s.project.folder) is closed."
        ok, msg, _ = run_tool(s, "database.statistics"; inputs = Dict("database" => id), channel = "MAG")
        @test !ok && occursin("is closed", msg)
        ok2, msg2, _ = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = "A = MAG",
                                lines = "all")
        @test !ok2 && occursin("is closed", msg2)
        @test warnings(s) isa Vector{String}
    end

    @testset "an import bumps the revision" begin
        s = fresh_session()
        r0 = revision(s)
        wait_job(import_file(s, small); check = true)
        @test revision(s) > r0
        close_session!(s)
    end

    @testset "a job cannot start while the session closes" begin
        s = fresh_session()
        gate = Threads.Atomic{Bool}(false)
        slow = (p, r) -> begin
            while !gate[] && !is_cancelled(p)
                sleep(0.001)
            end
            return ProjectItem[]
        end
        j1 = start_job!(s, "test.slow", Dict{String,Any}(), slow; undoable = false)
        closer = Threads.@spawn close_session!(s)
        t0 = time()
        while isopen(s) && time() - t0 < 30
            sleep(0.001)
        end
        @test !isopen(s)
        @test_throws SessionClosedError start_job!(s, "test.slow", Dict{String,Any}(), slow; undoable = false)
        gate[] = true
        wait(closer)
        @test all(j -> status(j) != JOB_RUNNING, jobs(s))
        @test length(jobs(s)) == 1 && status(j1) != JOB_RUNNING
    end
end
