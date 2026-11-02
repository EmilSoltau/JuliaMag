# Core support for a UI: the change counter, the warnings reader and the
# closed state of a session.

using Test
using JuliaMagCore
isdefined(@__MODULE__, :fresh_session) || include(joinpath(@__DIR__, "support", "synthetic.jl"))
isdefined(@__MODULE__, :add_test_grid!) || include(joinpath(@__DIR__, "support", "grids.jl"))

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
        r4 = revision(s)
        job = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = "MAG2 = MAG * 2",
                       lines = "all")
        wait_job(job)
        # One bump when the job starts, one when it leaves JOB_RUNNING.
        @test revision(s) >= r4 + 2
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
            while !gate[]
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
        # The close waits for the running job, so it is still open.
        @test s.state[] == 1
        @test !istaskdone(closer)
        @test_throws SessionClosedError start_job!(s, "test.slow", Dict{String,Any}(), slow; undoable = false)
        gate[] = true
        wait(closer)
        @test s.state[] == 2
        @test all(j -> status(j) != JOB_RUNNING, jobs(s))
        @test length(jobs(s)) == 1 && status(j1) != JOB_RUNNING
    end

    @testset "an edit that waits for the lock is refused when the session closes meanwhile" begin
        s = fresh_session()
        id = make_test_database!(s)
        before = length(s.undo_stack)
        held = Base.Event()
        release = Base.Event()
        holder = Threads.@spawn lock(s.lock) do
            notify(held)
            wait(release)
        end
        wait(held)
        edit = Threads.@spawn try
            rename_item!(s, id, "late")
            nothing
        catch e
            e
        end
        # The edit passes the first check at once, then waits for the lock the holder keeps.
        # Only public task state shows this: it has started and cannot finish. The short
        # wait gives it time to reach the lock; if it is slower, the edit is refused by the
        # first check instead and the test is weaker, but it does not fail.
        @test timedwait(() -> istaskstarted(edit), 20; pollint = 0.005) === :ok
        @test timedwait(() -> istaskdone(edit), 0.2; pollint = 0.005) === :timed_out
        @test islocked(s.lock)
        s.state[] = 1                   # the close has started
        notify(release)
        wait(holder)
        @test fetch(edit) isa SessionClosedError
        @test length(s.undo_stack) == before
        @test item(s.project, id).name != "late"
        s.state[] = 0
        close_session!(s)
    end
end

@testset "UI support: settings that depend on other settings" begin
    small = joinpath(mktempdir(), "small.xyz")
    write_synthetic_xyz(small; lines = 2, ties = 0, rows_per_line = 20)
    s = fresh_session()
    spec = importer_for("a.xyz")
    target = only(filter(st -> st.key == "target", spec.settings))

    @testset "is_active and setting_problems" begin
        @test target.when == ("mode" => ["append"])
        @test is_active(spec.settings, target, Dict("mode" => "new")) == false
        @test is_active(spec.settings, target, Dict("mode" => "append")) == true
        @test is_active(spec.settings, target, Dict{String,Any}()) == false          # mode defaults to new
        @test is_active(spec.settings, spec.settings[1], Dict("mode" => "new"))      # no condition
        @test isempty(setting_problems(spec, Dict("mode" => "new", "target" => "db-99"); session = s))
        @test setting_problems(spec, Dict("mode" => "append", "target" => "db-99"); session = s) ==
              ["target" => "Append to: there is no item db-99 in the project."]
        @test validate(spec, Dict("mode" => "append", "target" => "db-99"); session = s) ==
              ["Append to: there is no item db-99 in the project."]
        # An unknown key is reported under its own key; the pairs follow the setting order.
        @test setting_problems(spec, Dict("mode" => "bad", "zzz" => 1)) ==
              ["mode" => "Import into must be one of: new, append.", "zzz" => "$(spec.name) has no setting \"zzz\"."]
        # The UI writes its script calls through it, so it is public.
        @test Base.ispublic(JuliaMagCore, :deactivate_settings)
        d = JuliaMagCore.deactivate_settings(spec.settings, Dict("mode" => "new", "target" => "db-1", "path" => "a.xyz"))
        @test d["target"] == "" && d["path"] == "a.xyz" && d["mode"] == "new"
    end

    @testset "Bool controls, chains and bad conditions" begin
        list = SettingSpec[BoolSetting("on", "On"; default = false),
                           NumberSetting("n", "N"; default = 1, when = "on" => ["true"]),
                           ChoiceSetting("c", "C", ["x", "y"]; when = "on" => ["true"]),
                           NumberSetting("m", "M"; default = 1, when = "c" => ["x"])]
        @test !is_active(list, list[2], Dict("on" => false))
        @test is_active(list, list[2], Dict("on" => true))
        @test is_active(list, list[4], Dict("on" => true, "c" => "x"))
        @test !is_active(list, list[4], Dict("on" => true, "c" => "y"))
        @test !is_active(list, list[4], Dict("on" => false, "c" => "x"))   # its control is not used
        t = ToolSpec("t.when", "When", "", "", Place[], Pair{String,ItemKind}[], list, :quick, (a...) -> nothing)
        @test setting_problems(t, Dict("on" => false, "n" => "x")) == Pair{String,String}[]
        @test setting_problems(t, Dict("on" => true, "n" => "x")) == ["n" => "N must be a number."]
        # Inputs that are not a table: said so, not "has no setting".
        @test setting_problems(t, Dict("on" => false, "inputs" => 3)) ==
              ["inputs" => "The inputs of When must be a table of input name => item id."]
        @test validate(t, Dict("on" => true, "n" => "x")) == ["N must be a number."]
        # Input problems come first and use the input name as key.
        t2 = ToolSpec("t.when2", "When2", "", "", Place[], ["database" => ITEM_DATABASE], list, :quick, (a...) -> nothing)
        @test setting_problems(t2, Dict("on" => true, "n" => "x"); inputs = Dict{String,String}()) ==
              ["database" => "When2 needs a database as input \"database\".", "n" => "N must be a number."]
        @test setting_problems(t2, Dict("inputs" => Dict("database" => "db-1"), "on" => false)) == Pair{String,String}[]

        bad(settings) = ToolSpec("t.bad", "Bad", "", "", Place[], Pair{String,ItemKind}[], settings, :quick, (a...) -> nothing)
        @test_throws ArgumentError bad(SettingSpec[NumberSetting("n", "N"; default = 1, when = "nope" => ["x"])])
        @test_throws ArgumentError bad(SettingSpec[NumberSetting("a", "A"; default = 1),
                                                   NumberSetting("n", "N"; default = 1, when = "a" => ["1"])])
        @test_throws ArgumentError bad(SettingSpec[ChoiceSetting("c", "C", ["x", "y"]; when = "c" => ["x"])])
        @test_throws ArgumentError bad(SettingSpec[ChoiceSetting("c", "C", ["x", "y"]; when = "d" => ["x"]),
                                                   ChoiceSetting("d", "D", ["x", "y"]; when = "c" => ["x"])])
        @test_throws ArgumentError bad(SettingSpec[ChoiceSetting("c", "C", ["x", "y"]),
                                                   NumberSetting("n", "N"; default = 1, when = "c" => ["z"])])
        @test_throws ArgumentError NumberSetting("n", "N"; default = 1, when = "c" => String[])
        @test_throws ArgumentError ImporterSpec("i.bad", "Bad", [".bad"], ITEM_DATABASE,
            SettingSpec[NumberSetting("n", "N"; default = 1, when = "nope" => ["x"])], (a...) -> nothing)
        @test_throws ArgumentError ExporterSpec("e.bad", "Bad", ".bad", ITEM_DATABASE,
            SettingSpec[NumberSetting("n", "N"; default = 1, when = "nope" => ["x"])], (a...) -> nothing)
    end

    @testset "an unused setting is recorded as its default" begin
        job = wait_job(import_file(s, small; mode = "new", target = "db-99"))
        @test status(job) == JOB_DONE
        @test job.args["target"] == "" && s.history[end].args["target"] == ""
        # An import that runs again keeps the default too.
        job2 = wait_job(rerun!(s, job; args = merge(job.args, Dict("target" => "db-77"))))
        @test job2.args["target"] == "" && s.history[end].args["target"] == ""
        # A used setting is kept.
        id = only(job.outputs)
        job3 = wait_job(import_file(s, small; mode = "append", target = id))
        @test job3.args["target"] == id

        # A tool: the remembered settings hold the default too.
        register_tool!(ToolSpec("t.when_run", "When run", "", "", Place[], Pair{String,ItemKind}[],
            SettingSpec[BoolSetting("on", "On"), NumberSetting("n", "N"; default = 1, when = "on" => ["true"])],
            :quick, (a...) -> nothing))
        try
            ok, _, _ = run_tool(s, "t.when_run"; on = false, n = "junk")
            @test ok
            @test s.history[end].args["n"] == 1
            @test last_settings(s, "t.when_run")["n"] == 1
        finally
            unregister_tool!("t.when_run")
        end
    end

    @testset "ribbon places" begin
        @test Place("Database", "Import").size == :big
        @test Place("Database", "Import").order == 0
        @test Place("Database", "Import"; size = :small, order = 3).size == :small
        @test_throws ArgumentError Place("a", "b"; size = :huge)
        small_ids = ["coordinates.set_current", "coordinates.guess_utm"]
        # The built-in tools only: a tool another test leaves registered must not count.
        builtin = filter(t -> parentmodule(t.run) === JuliaMagCore, tools())
        @test length(builtin) >= 8
        for t in builtin, p in t.places
            @test p.size == (t.id in small_ids && p.tab == "Coordinates" ? :small : :big)
        end
    end

    @testset "script_call" begin
        @test script_call("database.statistics", Dict{String,Any}("inputs" => Dict("database" => "db-1"), "channel" => "MAG")) ==
              "run_tool(s, \"database.statistics\"; channel = \"MAG\", inputs = Dict(\"database\" => \"db-1\"))"
        @test script_call("database.statistics", Dict{String,Any}()) == "run_tool(s, \"database.statistics\")"
        @test script_call("import.geosoft_xyz", Dict{String,Any}("path" => "a.xyz", "mode" => "new")) ==
              "import_file(s, \"a.xyz\"; mode = \"new\")"
        @test script_call("session.undo", Dict{String,Any}()) == "undo!(s)"
        # The text of script_text is this call, wrapped.
        job = wait_job(import_file(s, small; mode = "new"))
        text = script_text(s)
        @test occursin("wait_job(" * script_call(job.command, job.args) * "; check = true)", text)
    end
    close_session!(s)
end

@testset "UI support: position pairs, checked cursor and marks, many lines" begin
    xyz = joinpath(mktempdir(), "small.xyz")
    write_synthetic_xyz(xyz; lines = 4, ties = 0, rows_per_line = 20)
    # An import gives several lines and the pair X,Y as the current pair.
    function pair_session()
        s = fresh_session()
        id = only(wait_job(import_file(s, xyz; mode = "new"); check = true).outputs)
        return s, id
    end
    pairs_of(s, id) = [(p.x, p.y) for p in database(s.project, id).pairs]

    @testset "add_pair! and remove_pair!" begin
        s, id = pair_session()
        @test pairs_of(s, id) == [("X", "Y")] && database(s.project, id).current_pair == 1
        r = revision(s)
        add_pair!(s, id, "MAG", "ALT"; crs = "EPSG:7855")
        @test revision(s) > r
        db = database(s.project, id)
        @test pairs_of(s, id) == [("X", "Y"), ("MAG", "ALT")] && db.current_pair == 1
        @test db.pairs[2].crs == "EPSG:7855"
        @test s.history[end].command == "database.add_pair"
        @test_throws ArgumentError add_pair!(s, id, "MAG", "ALT")          # there already
        @test_throws JuliaMagCore.DatabaseError add_pair!(s, id, "MAG", "NOPE")
        remove_pair!(s, id, "X", "Y")
        db = database(s.project, id)
        @test pairs_of(s, id) == [("MAG", "ALT")] && db.current_pair == 0
        @test s.history[end].command == "database.remove_pair"
        @test all(n -> any(c -> c.name == n, db.channels), ("X", "Y"))        # the channels stay
        undo!(s)
        @test database(s.project, id).current_pair == 1 && pairs_of(s, id) == [("X", "Y"), ("MAG", "ALT")]
        redo!(s)
        @test database(s.project, id).current_pair == 0
        undo!(s)
        # Removing another pair keeps the current pair on the same pair.
        add_pair!(s, id, "ALT", "MAG")
        d = database(s.project, id)
        d.current_pair = 2
        save_meta(d)                                    # a database is read from disk on each call
        remove_pair!(s, id, "X", "Y")
        @test database(s.project, id).current_pair == 1 && pairs_of(s, id)[1] == ("MAG", "ALT")
        @test_throws ArgumentError remove_pair!(s, id, "X", "Y")
        undo!(s)
        @test database(s.project, id).current_pair == 2
        close_session!(s)
    end

    @testset "add_pair! checks the channels and a busy database" begin
        s, id = pair_session()
        db = database(s.project, id)
        add_channel!(db, ChannelInfo("NAME", "NAME", String, "", ROLE_NONE, :normal, 10, -1, false, 1))
        add_channel!(db, ChannelInfo("ARR", "ARR", Float64, "", ROLE_NONE, :normal, 10, -1, false, 3))
        save_meta(db)
        @test_throws ArgumentError add_pair!(s, id, "MAG", "NAME")
        @test_throws ArgumentError add_pair!(s, id, "ARR", "MAG")
        @test_throws ArgumentError add_pair!(s, id, "MAG", "ARR")
        @test length(database(s.project, id).pairs) == 1
        JuliaMagCore.mark_busy!(s, id)
        @test_throws ItemBusyError add_pair!(s, id, "MAG", "ALT")
        @test_throws ItemBusyError remove_pair!(s, id, "X", "Y")
        @test_throws ItemBusyError set_lines_selected!(s, id, [first(db.lines).id], false)
        close_session!(s)
    end

    @testset "the first pair becomes current" begin
        s = fresh_session()
        id = make_test_database!(s)
        @test isempty(database(s.project, id).pairs)
        add_pair!(s, id, "MAG", "MAGP")
        @test database(s.project, id).current_pair == 1
        undo!(s)
        db = database(s.project, id)
        @test isempty(db.pairs) && db.current_pair == 0
        close_session!(s)
    end

    @testset "set_lines_selected!" begin
        s, id = pair_session()
        ls = [l.id for l in database(s.project, id).lines]
        @test length(ls) == 4
        set_lines_selected!(s, id, ls, false)
        @test !any(l.selected for l in database(s.project, id).lines)
        @test count(e -> e.command == "database.set_lines_selected", s.history) == 1
        undo!(s)                                         # one step for all lines
        @test all(l.selected for l in database(s.project, id).lines)
        redo!(s)
        @test !any(l.selected for l in database(s.project, id).lines)
        # Lines in that state already are left out; an empty change pushes nothing.
        n, r = length(s.history), revision(s)
        set_lines_selected!(s, id, ls, false)
        set_lines_selected!(s, id, LineId[], true)
        @test length(s.history) == n && revision(s) == r
        set_lines_selected!(s, id, ls[1:2], true)
        e = s.history[end]
        @test length(e.args["lines"]) == 2
        set_lines_selected!(s, id, ls, true)             # only the two that are off
        @test length(s.history[end].args["lines"]) == 2
        @test all(l.selected for l in database(s.project, id).lines)
        undo!(s)
        @test count(l -> l.selected, database(s.project, id).lines) == 2
        @test_throws JuliaMagCore.DatabaseError set_lines_selected!(s, id, [LineId(LINE, 9999, 0)], true)
        close_session!(s)
    end

    @testset "set_cursor! and set_marked! check their input" begin
        s, id = pair_session()
        ls = [l.id for l in database(s.project, id).lines]
        @test_throws ArgumentError set_cursor!(s, Cursor(id, first(ls), 0))
        @test_throws ArgumentError set_cursor!(s, Cursor(id, first(ls), 21))
        @test_throws ArgumentError set_cursor!(s, Cursor("db-99", first(ls), 1))
        @test_throws ArgumentError set_cursor!(s, Cursor(id, LineId(LINE, 9999, 0), 1))
        @test s.cursor === nothing
        @test_throws ArgumentError set_marked!(s, (1, 3))                # no cursor yet
        set_cursor!(s, Cursor(id, first(ls), 20))
        @test s.cursor.row == 20
        set_cursor!(s, Cursor(id, first(ls), 1))
        @test_throws ArgumentError set_marked!(s, (0, 3))
        @test_throws ArgumentError set_marked!(s, (1, 10^9))
        @test_throws ArgumentError set_marked!(s, (5, 3))
        set_marked!(s, (1, 20))
        @test s.marked == (1, 20)
        set_marked!(s, nothing)
        @test s.marked === nothing
        # A project item that is not a database is refused too.
        gid = add_test_grid!(s, Float32[1 2; 3 4])
        @test_throws ArgumentError set_cursor!(s, Cursor(gid, first(ls), 1))
        close_session!(s)
    end

    @testset "the cursor, the marks, pairs and line selection refuse a closed session" begin
        s, id = pair_session()
        ls = [l.id for l in database(s.project, id).lines]
        set_cursor!(s, Cursor(id, first(ls), 1))
        close_session!(s)
        @test_throws SessionClosedError set_cursor!(s, Cursor(id, first(ls), 2))
        @test_throws SessionClosedError set_marked!(s, (1, 2))
        @test_throws SessionClosedError add_pair!(s, id, "MAG", "ALT")
        @test_throws SessionClosedError remove_pair!(s, id, "X", "Y")
        @test_throws SessionClosedError set_lines_selected!(s, id, ls[1:1], false)
        @test s.cursor.row == 1 && s.marked === nothing
    end

    @testset "the three edits replay by script" begin
        s = fresh_session()
        copy_folder = joinpath(mktempdir(), "copy")       # the project before the import
        cp(s.project.folder, copy_folder)
        rm(joinpath(copy_folder, LOCK_FILE); force = true)
        id = only(wait_job(import_file(s, xyz; mode = "new"); check = true).outputs)
        ls = [l.id for l in database(s.project, id).lines]
        add_pair!(s, id, "MAG", "ALT"; crs = "EPSG:7855")
        set_lines_selected!(s, id, ls[1:2], false)
        remove_pair!(s, id, "X", "Y")
        text = replace(script_text(s), repr(s.project.folder) => repr(copy_folder))
        @test occursin("\nadd_pair!(s, db_1, \"MAG\", \"ALT\"; crs = \"EPSG:7855\")\n", text)
        @test occursin("\nset_lines_selected!(s, db_1, [LineId(LINE, 1001, 0), LineId(LINE, 1002, 0)], false)\n", text)
        @test occursin("\nremove_pair!(s, db_1, \"X\", \"Y\")\n", text)
        close_session!(s)
        # The copy was made before the import: the script imports again, then replays the three edits.
        include_string(Module(), text)
        db = database(open_project(copy_folder), "db-1")
        @test [(p.x, p.y) for p in db.pairs] == [("MAG", "ALT")] && db.current_pair == 0
        @test [l.selected for l in db.lines] == [false, false, true, true]
    end
end
