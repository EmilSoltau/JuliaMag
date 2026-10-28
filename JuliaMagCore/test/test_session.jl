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
        end
    end

    @testset "torn and broken history lines" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "p")
            id = make_test_database!(s)
            L = LineId(LINE, 1001, 0)
            set_cell!(s, id, L, "MAG", 1, 7.0)
            set_cell!(s, id, L, "MAG", 2, 8.0)
            hp = joinpath(folder, "jobs", "history.jsonl")
            good = read(hp, String)
            # torn last line: repaired on open, later records still load
            write(hp, good * "{\"time\":")
            s2 = open_session(folder)
            @test length(s2.history) == 2 && length(s2.warnings) == 1
            @test endswith(read(hp, String), "\n")
            set_cell!(s2, id, L, "MAG", 3, 9.0)
            s3 = open_session(folder)
            @test length(s3.history) == 3 && isempty(s3.warnings)
            @test s3.history[3].args["value"] == 9.0
            # a whole file that is one torn line
            write(hp, "{\"tim")
            @test isempty(open_session(folder).history)
            # bad middle line: skipped with a warning, the others stay
            lines = split(good, '\n'; keepempty = false)
            write(hp, lines[1] * "\n{oops}\n" * lines[2] * "\n")
            s4 = open_session(folder)
            @test length(s4.history) == 2 && length(s4.warnings) == 1
            @test occursin("line 2", s4.warnings[1])
            @test [e.args["row"] for e in s4.history] == [1, 2]
        end
    end

    @testset "undo chain and script round trip with TIE v1" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "p")
            id = make_test_database!(s)
            L = LineId(LINE, 1001, 0)
            T = LineId(TIE, 5, 1)
            db = database(s.project, id)
            add_line!(db, LineInfo(T, 1, "2024-05-01", 0.0, 0.1, 2, 0, true))
            apps = open_appenders(db, ["MAG", "MAGP"])
            for c in ("MAG", "MAGP"), x in (1.0, 2.0)
                append_value!(apps[c], x)
            end
            close_appenders!(apps)
            save_meta(db)
            mag() = collect(read_channel(database(s.project, id), L, "MAG"))
            sel(l) = line(database(s.project, id), l).selected
            set_cell!(s, id, L, "MAG", 1, 11.0)
            set_line_selected!(s, id, T, false)
            set_cell!(s, id, L, "MAG", 2, 22.0)
            @test undo!(s) && undo!(s)
            @test sel(T) && mag()[2] == 2.0 && mag()[1] == 11.0
            @test redo!(s)
            @test !sel(T)
            @test undo!(s) && sel(T)
            @test mag() == [11.0, 2.0, 3.0, 4.0, 5.0]
            @test can_redo(s) && can_undo(s)
            # replay the script on a copy that starts from the original data
            txt = script_text(s)
            @test occursin("LineId(TIE, 5, 1)", txt)
            copy_dir = joinpath(dir, "copy")
            cp(folder, copy_dir)
            c = open_session(copy_dir)
            cdb = database(c.project, id)
            write_value!(cdb, L, "MAG", 1, 1.0)
            line(cdb, T).selected = true
            save_meta(cdb)
            body = join(filter(l -> !startswith(l, "s = open_session"), split(txt, '\n')), "\n")
            Core.eval(@__MODULE__, :(s = $c))
            Core.eval(@__MODULE__, Meta.parseall(body))
            @test collect(read_channel(database(c.project, id), L, "MAG")) == mag()
            @test line(database(c.project, id), T).selected == sel(T)
        end
    end
end
