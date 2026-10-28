using JuliaMagCore

@testset "session" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        id = make_test_database!(s)
        L = LineId(LINE, 1001, 0)
        set_cell!(s, id, L, "MAG", 2, 99.0)
        @test read_channel(database(s.project, id), L, "MAG")[2] == 99.0
        @test undo!(s) && read_channel(database(s.project, id), L, "MAG")[2] != 99.0
        @test redo!(s) && read_channel(database(s.project, id), L, "MAG")[2] == 99.0
        @test_throws ProtectedError set_cell!(s, id, L, "MAGP", 1, 1.0)
        @test occursin("database.set_cell", script_text(s))
        @test Meta.parseall(script_text(s)) isa Expr
    end

    @testset "details" begin
        (; s, id, L) = make_db_with(MAG = [1.0, 2.0, 3.0])
        mag() = collect(read_channel(database(s.project, id), L, "MAG"))
        @test !can_undo(s) && !can_redo(s) && !undo!(s) && !redo!(s)
        set_cell!(s, id, L, "MAG", 1, NaN)
        set_cell!(s, id, L, "MAG", 3, 0.1 + 0.2)
        @test isnan(mag()[1]) && mag()[3] == 0.1 + 0.2
        @test undo!(s) && undo!(s) && !undo!(s)
        @test mag() == [1.0, 2.0, 3.0]
        @test can_redo(s)
        set_cell!(s, id, L, "MAG", 2, 5.0)      # a new edit clears redo
        @test !can_redo(s)
        @test mag() == [1.0, 5.0, 3.0]
    end

    @testset "protected channel writes nothing" begin
        s = fresh_session()
        id = make_test_database!(s)
        L = LineId(LINE, 1001, 0)
        n = length(s.history)
        @test_throws ProtectedError set_cell!(s, id, L, "MAGP", 1, 1.0)
        @test length(s.history) == n && !can_undo(s)
        @test read_channel(database(s.project, id), L, "MAGP")[1] == 10.0
        @test occursin("MAGP", sprint(showerror, ProtectedError("MAGP")))
    end

    @testset "line selection, cursor" begin
        s = fresh_session()
        id = make_test_database!(s)
        L = LineId(LINE, 1001, 0)
        sel() = line(database(s.project, id), L).selected
        @test sel()
        set_line_selected!(s, id, L, false)
        @test !sel()
        @test undo!(s) && sel()
        @test redo!(s) && !sel()
        n = length(s.history)
        c = Cursor(id, L, 3)
        set_cursor!(s, c)
        @test s.cursor === c && length(s.history) == n && !isempty(s.undo_stack)
    end

    @testset "history file and script" begin
        mktempdir() do dir
            folder = joinpath(dir, "my \"p\" \$x")
            s = new_session(folder, "p")
            id = make_test_database!(s)
            L = LineId(LINE, 1001, 0)
            set_cell!(s, id, L, "MAG", 2, 0.1 + 0.2)
            set_cell!(s, id, L, "MAG", 3, NaN)
            set_line_selected!(s, id, L, false)
            undo!(s)
            record!(s, "tool.demo", Dict("name" => "a\"b", "n" => 3, "list" => [1, 2], "bad key" => 1.5); job = "job-1")
            @test countlines(joinpath(folder, "jobs", "history.jsonl")) == length(s.history) == 5
            s2 = open_session(folder)             # history is loaded, undo stack is not
            @test [e.command for e in s2.history] == [e.command for e in s.history]
            @test s2.history[1].args["value"] == 0.1 + 0.2 && isnan(s2.history[2].args["value"])
            @test s2.history[end].job == "job-1" && !can_undo(s2)
            txt = script_text(s2)
            @test startswith(txt, "using JuliaMagCore\ns = open_session(")
            @test occursin("set_cell!(s, \"$id\", LineId(LINE, 1001, 0), \"MAG\", 2, 0.30000000000000004)", txt)
            @test occursin("run_tool(s, \"tool.demo\"; var\"bad key\" = 1.5, list = Any[1, 2], n = 3, name = \"a\\\"b\")", txt)
            @test Meta.parseall(txt) isa Expr
            # run the script (without run_tool) on a copy: same data as the original
            copy_dir = joinpath(dir, "copy")
            cp(folder, copy_dir)
            lines = split(txt, '\n')
            body = join(filter(l -> !startswith(l, "run_tool") && !startswith(l, "s = open_session"), lines), "\n")
            s3 = open_session(copy_dir)
            # restore the original values first
            write_value!(database(s3.project, id), L, "MAG", 2, 2.0)
            write_value!(database(s3.project, id), L, "MAG", 3, 3.0)
            line(let d = database(s3.project, id); d end, L)   # database opens
            ex = Meta.parseall(body)
            Core.eval(@__MODULE__, :(s = $s3))
            Core.eval(@__MODULE__, ex)
            @test collect(read_channel(database(s3.project, id), L, "MAG")) |> x -> (x[2] == 0.1 + 0.2 && isnan(x[3]))
            # a damaged last line without newline is skipped; a damaged middle line is an error
            write(joinpath(folder, "jobs", "history.jsonl"), read(joinpath(folder, "jobs", "history.jsonl"), String) * "{\"time\":")
            @test length(open_session(folder).history) == 5
            write(joinpath(folder, "jobs", "history.jsonl"), "{oops}\n" * read(joinpath(folder, "jobs", "history.jsonl"), String))
            @test_throws ProjectError open_session(folder)
        end
    end
end
