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
        sleep(0.3)                      # the edit has passed the first check and waits for the lock
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
            ok, msg, _ = run_tool(s, "t.when_run"; on = false, n = "junk")
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
        for t in tools(), p in t.places
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
