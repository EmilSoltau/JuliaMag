try
@testset "tools" begin
    spec = ToolSpec("test.scale", "Scale", "Multiply a channel.", "math",
        [Place("Database Tools", "Channels"), Place("Magnetics", "Corrections")],
        ["database" => ITEM_DATABASE],
        [ChannelSetting("in", "Input"), NumberSetting("factor", "Factor"; default = 2.0, min = 0.0),
         NumberSetting("cell", "Cell size"; default = nothing, auto = true)],
        :quick, (s, i, st, p, r) -> nothing)
    register_tool!(spec)
    @test tool("test.scale").places[2].tab == "Magnetics"
    @test "Magnetics" in tabs()
    @test validate(spec, Dict("in" => "MAG", "factor" => -1.0, "cell" => nothing)) == ["Factor must be at least 0."]
    s = fresh_session()
    run_tool(s, "test.scale"; inputs = Dict("database" => "db-1"), in = "MAG", factor = 3.0)
    @test last_settings(s, "test.scale")["factor"] == 3.0
    reset_settings!(s, "test.scale"); @test last_settings(s, "test.scale")["factor"] == 2.0
    register_tool!(ToolSpec("test.boom", "Boom", "", "", Place[], Pair{String,ItemKind}[], SettingSpec[], :quick,
        (s, i, st, p, r) -> error("x")))
    ok, msg, _ = run_tool(s, "test.boom")
    @test !ok && msg == "Tool failed: x"
    @test occursin("run_tool(s, \"test.scale\"", script_text(s))
end
finally
    # Keep the registry as other test files expect it.
    unregister_tool!("test.scale"); unregister_tool!("test.boom")
end

# A quick tool that changes data: it scales a channel on every line and pushes its own undo step.
function scale_channel_tool(s, i, st, p, r)
    id = i["database"]
    ch = st["in"]
    f = st["factor"]
    db = database(s.project, id)
    any(c -> c.name == ch, db.channels) || throw(ToolError("There is no channel $ch."))
    old = Dict(l.id => collect(read_channel(db, l.id, ch)) for l in db.lines)
    put(scale) = () -> begin
        d = database(s.project, id)
        foreach(l -> write_channel!(d, l, ch, old[l] .* scale), keys(old))
        nothing
    end
    lock(s.lock) do
        check_not_busy(s, id)
        put(f)()
        push_undo!(s, UndoStep("scale $ch", put(1.0), put(f), () -> nothing, [id]))
    end
    println(r, "Scaled $ch by $f.")
    return nothing
end

@testset "setting checks" begin
    @test NumberSetting("n", "N"; default = 1).default === 1.0
    @test NumberSetting("n", "N"; default = nothing).auto == false
    @test_throws ArgumentError NumberSetting("n", "N"; default = 1, min = 2, max = 1)
    @test_throws ArgumentError ChoiceSetting("c", "C", ["a", "b"]; default = "z")
    @test ChoiceSetting("c", "C", ["a", "b"]).default == "a"
    @test_throws ArgumentError LinesSetting("l", "Lines"; default = "some")
    all_kinds = SettingSpec[
        NumberSetting("n", "Size"; default = 5.0, min = 1.0, max = 10.5),
        NumberSetting("need", "Need"; default = nothing),
        TextSetting("t", "Title"), ExprSetting("e", "Expression"; default = "A = B + 1"),
        ChoiceSetting("c", "Mode", ["new", "append"]), BoolSetting("b", "Flag"),
        FileSetting("f", "Grid file"; extensions = [".GRD", ".ers"], default = "a.grd"),
        ChannelSetting("ch", "Channel"; roles = [ROLE_X], default = "X"),
        LinesSetting("l", "Lines"), CRSSetting("crs", "CRS"), PairSetting("pair", "Pair"),
        ExtentSetting("ext", "Area"), PointSetting("pt", "Point"; default = [1, 2]),
    ]
    t = ToolSpec("test.kinds", "Kinds", "", "", Place[], ["database" => ITEM_DATABASE], all_kinds, :quick,
                 (s, i, st, p, r) -> nothing)
    d = default_settings(t)
    @test d["pt"] == [1.0, 2.0] && d["ext"] === nothing && d["l"] == "all" && d["c"] == "new"
    @test d["f"] == "a.grd" && d["b"] === false && d["need"] === nothing
    @test validate(t, Dict("need" => 1)) == String[]
    @test validate(t, Dict()) == ["Need must be set."]
    bad = Dict("n" => 0.5, "need" => "3", "t" => 3, "e" => "A = (B", "c" => "merge", "b" => "yes",
               "f" => "x.xyz", "ch" => "", "l" => "some", "crs" => :EPSG, "pair" => 1,
               "ext" => [3, 0, 1, 1], "pt" => [1, NaN], "zzz" => 1)
    problems = validate(t, bad)
    @test problems[1] == "Size must be at least 1."
    @test problems[2] == "Need must be a number."
    @test problems[3] == "Title must be text."
    @test startswith(problems[4], "Expression is not a valid Julia expression")
    @test problems[5] == "Mode must be one of: new, append."
    @test problems[6] == "Flag must be true or false."
    @test problems[7] == "Grid file must be a .grd or .ers file."
    @test problems[8] == "Channel is not set."
    @test problems[9] == "Lines must be all, selected or current."
    @test problems[10] == "Pair must be text."                    # a symbol CRS is taken as text
    @test problems[11] == "Area must have west below east and south below north."
    @test problems[12] == "Point must be two numbers: x and y."
    @test problems[13] == "Kinds has no setting \"zzz\"."
    @test length(problems) == 13
    @test validate(t, Dict("need" => 1, "n" => 11, "e" => " ", "ext" => [1, 2, 3])) ==
          ["Size must be at most 10.5.", "Expression is empty.", "Area must be four numbers: west, south, east and north."]
    # text that would overflow the parser's stack is refused before it is parsed
    @test validate(t, Dict("need" => 1, "e" => "A = " * "("^201 * "B" * ")"^201)) ==
          ["Expression has brackets nested more than 200 deep."]
    @test validate(t, Dict("need" => 1, "e" => "A = " * "-"^1001 * "B")) ==
          ["Expression has more than 1000 operator characters."]
    @test validate(t, Dict("need" => 1, "e" => "A = " * "B"^10_000)) ==
          ["Expression is too long: it has 10004 characters, and at most 10000 are allowed."]
    @test validate(t, Dict("need" => Inf, "n" => true, "f" => "B.GRD")) ==
          ["Size must be a number.", "Need must be a finite number."]
    # bad tool descriptions are refused when they are made
    @test_throws ArgumentError ToolSpec("test.x", "X", "", "", Place[], Pair{String,ItemKind}[], SettingSpec[], :slow,
                                        (s, i, st, p, r) -> nothing)
    @test_throws ArgumentError ToolSpec("test.x", "X", "", "", Place[], Pair{String,ItemKind}[],
                                        [TextSetting("a", "A"), TextSetting("a", "B")], :quick, (s, i, st, p, r) -> nothing)
    @test_throws ArgumentError ToolSpec("test.x", "X", "", "", Place[], Pair{String,ItemKind}[],
                                        [TextSetting("inputs", "A")], :quick, (s, i, st, p, r) -> nothing)
    # channel and pair settings must name an input of the tool
    @test_throws ArgumentError ToolSpec("test.x", "X", "", "", Place[], ["db" => ITEM_DATABASE],
                                        [ChannelSetting("ch", "Channel")], :quick, (s, i, st, p, r) -> nothing)
    @test_throws ArgumentError ToolSpec("test.x", "X", "", "", Place[], ["db" => ITEM_DATABASE],
                                        [PairSetting("p", "Pair")], :quick, (s, i, st, p, r) -> nothing)
    ok = ToolSpec("test.x", "X", "", "", Place[], ["db" => ITEM_DATABASE],
                  [ChannelSetting("ch", "Channel"; input = "db"), PairSetting("p", "Pair"; input = "db")], :quick,
                  (s, i, st, p, r) -> nothing)
    @test ok.settings[2].input == "db"
end

@testset "whole numbers, units and choice labels" begin
    n = NumberSetting("bins", "Histogram bins"; default = 40, min = 1, integer = true, unit = "bins")
    @test n.default === 40 && n.unit == "bins" && NumberSetting("x", "X"; default = 1).unit == ""
    @test_throws ArgumentError NumberSetting("bins", "Bins"; default = 2.5, integer = true)
    t = ToolSpec("test.bins", "Bins", "", "", Place[], Pair{String,ItemKind}[], [n], :quick, (s, i, st, p, r) -> nothing)
    @test validate(t, Dict("bins" => 12.0)) == String[]
    @test validate(t, Dict("bins" => 2.5)) == ["Histogram bins must be a whole number."]
    @test validate(t, Dict("bins" => 0)) == ["Histogram bins must be at least 1."]
    try
        register_tool!(t)
        s = fresh_session()
        @test run_tool(s, "test.bins"; bins = 12.0)[1]
        @test last_settings(s, "test.bins")["bins"] === 12
        @test last_settings(open_session(s.project.folder), "test.bins")["bins"] === 12   # an Int after JSON too
        @test occursin("run_tool(s, \"test.bins\"; bins = 12)", script_text(s))
    finally
        unregister_tool!("test.bins")
    end
    c = ChoiceSetting("mode", "Mode", ["new", "append"]; labels = ["New database", "Append to existing"])
    @test c.labels == ["New database", "Append to existing"]
    @test ChoiceSetting("m", "M", ["a", "b"]).labels == ["a", "b"]
    @test_throws ArgumentError ChoiceSetting("m", "M", ["a", "b"]; labels = ["A"])
    xyz = only(filter(i -> i.id == "import.geosoft_xyz", importers()))
    @test xyz.settings[1].labels == ["New database", "Append to existing"]
end

@testset "tool registry" begin
    try
        n = length(tools())
        mk(id, places) = ToolSpec(id, id, "", "", places, Pair{String,ItemKind}[], SettingSpec[], :quick,
                                  (s, i, st, p, r) -> nothing)
        register_tool!(mk("test.reg1", [Place("Zeta Tab", "A"), Place("Alpha Tab", "B")]))
        register_tool!(mk("test.reg2", [Place("Alpha Tab", "C"), Place("Mid Tab", "D")]))
        tb = tabs()
        @test findfirst(==("Zeta Tab"), tb) < findfirst(==("Alpha Tab"), tb) < findfirst(==("Mid Tab"), tb)
        @test count(==("Alpha Tab"), tb) == 1
        # a second registration with the same id replaces the first and keeps its place
        register_tool!(mk("test.reg1", [Place("Zeta Tab", "New group")]))
        @test length(tools()) == n + 2
        @test tool("test.reg1").places == [Place("Zeta Tab", "New group")]
        @test findfirst(t -> t.id == "test.reg1", tools()) < findfirst(t -> t.id == "test.reg2", tools())
        @test_throws ArgumentError tool("test.none")
        # tools from other packages may register from any thread
        Threads.@threads for k in 1:40
            register_tool!(mk("test.thread$(k % 8)", Place[]))
        end
        @test count(t -> startswith(t.id, "test.thread"), tools()) == 8
        foreach(k -> unregister_tool!("test.thread$k"), 0:7)
        @test unregister_tool!("test.reg1") && unregister_tool!("test.reg2") && !unregister_tool!("test.reg2")
        @test !("Mid Tab" in tabs()) && length(tools()) == n
        # the XYZ importer describes its settings with setting types
        xyz = only(filter(i -> i.id == "import.geosoft_xyz", importers()))
        @test [st.key for st in xyz.settings] == ["mode", "name", "target", "crs"]
        @test default_settings(xyz)["mode"] == "new"
        @test validate(xyz, Dict("mode" => "merge")) == ["Import into must be one of: new, append."]
    finally
        foreach(unregister_tool!, ["test.reg1", "test.reg2", ("test.thread$k" for k in 0:7)...])
    end
end

@testset "run_tool" begin
    try
        register_tool!(ToolSpec("test.scale_data", "Scale data", "Multiply a channel in place.", "math",
            [Place("Database Tools", "Channels")], ["database" => ITEM_DATABASE],
            [ChannelSetting("in", "Input"), NumberSetting("factor", "Factor"; default = 2.0, min = 0.0)],
            :quick, scale_channel_tool))
        (; s, id, L) = make_db_with(MAG = [1.0, 2.0, 3.0])
        mag() = collect(read_channel(database(s.project, id), L, "MAG"))
        nh = length(s.history)

        # bad settings or inputs: nothing runs, nothing is remembered or recorded
        @test run_tool(s, "test.scale_data"; inputs = Dict("database" => id), in = "MAG", factor = -1) ==
              (false, "Factor must be at least 0.", nothing)
        @test run_tool(s, "test.scale_data"; in = "MAG", fctor = 3) ==
              (false, "Scale data needs a database as input \"database\". Scale data has no setting \"fctor\".", nothing)
        @test run_tool(s, "test.scale_data"; inputs = Dict("database" => id, "grid" => "grid-1"), in = "MAG") ==
              (false, "Scale data has no input \"grid\".", nothing)
        @test run_tool(s, "test.nothing_here") == (false, "There is no tool \"test.nothing_here\".", nothing)
        @test mag() == [1.0, 2.0, 3.0] && length(s.history) == nh
        @test last_settings(s, "test.scale_data") == Dict{String,Any}("in" => "", "factor" => 2.0)

        # a run that works: the data changes, undo works, the run is recorded
        ok, msg, out = run_tool(s, "test.scale_data"; inputs = Dict("database" => id), in = "MAG", factor = 3)
        @test ok && msg == "Scaled MAG by 3.0." && out == ProjectItem[]
        @test mag() == [3.0, 6.0, 9.0]
        @test undo!(s) && mag() == [1.0, 2.0, 3.0] && redo!(s) && mag() == [3.0, 6.0, 9.0]
        e = s.history[nh+1]
        @test e.command == "test.scale_data" && e.job == "" &&
              e.args == Dict{String,Any}("in" => "MAG", "factor" => 3.0, "inputs" => Dict{String,Any}("database" => id))

        # remembered settings are saved in project.jmag.json under settings.tools
        @test last_settings(s, "test.scale_data")["factor"] === 3.0
        s2 = open_session(s.project.folder)
        @test s2.project.settings["tools"]["test.scale_data"]["in"] == "MAG"
        @test last_settings(s2, "test.scale_data") == Dict{String,Any}("in" => "MAG", "factor" => 3.0)
        reset_settings!(s2, "test.scale_data")
        @test !haskey(open_session(s.project.folder).project.settings["tools"], "test.scale_data")

        # a ToolError gives its own message; a busy item gives a plain message
        ok, msg, out = run_tool(s, "test.scale_data"; inputs = Dict("database" => id), in = "NOPE")
        @test !ok && msg == "There is no channel NOPE." && out === nothing
        @test last_settings(s, "test.scale_data")["in"] == "NOPE"     # remembered, as the dialog showed it
        JuliaMagCore.mark_busy!(s, id)
        ok, msg, _ = run_tool(s, "test.scale_data"; inputs = Dict("database" => id), in = "MAG")
        @test !ok && msg == "$id is busy: an import is running."
        JuliaMagCore.unmark_busy!(s, id)
        @test count(h -> h.command == "test.scale_data", s.history) == 1

        # the script repeats the run, with its inputs
        txt = script_text(s)
        call = "run_tool(s, \"test.scale_data\"; factor = 3.0, in = \"MAG\", inputs = Dict(\"database\" => \"$id\"))"
        @test occursin(call, txt)
        @test Meta.parseall(txt) isa Expr
        m = Module()                                  # no global `s` left in Main
        Core.eval(m, :(using JuliaMagCore))
        Core.eval(m, :(s = $s))
        @test Core.eval(m, Meta.parse(call))[1]
        @test mag() == [9.0, 18.0, 27.0]

        # remembered values that no longer fit the tool fall back to the defaults
        s.remembered["test.scale_data"]["factor"] = "big"
        s.remembered["test.scale_data"]["gone"] = 1
        @test last_settings(s, "test.scale_data") == Dict{String,Any}("in" => "MAG", "factor" => 2.0)
    finally
        unregister_tool!("test.scale_data")
    end
end

@testset "bad settings.tools in the project file" begin
    s = fresh_session()
    s.project.settings["tools"] = Dict{String,Any}("a" => 1, "b" => Dict{String,Any}("x" => 1))
    save_project(s.project)
    s2 = open_session(s.project.folder)
    @test s2.remembered == Dict("b" => Dict{String,Any}("x" => 1))
    @test any(w -> occursin("settings.tools.a is not an object", w), s2.warnings)
    s.project.settings["tools"] = [1, 2]
    save_project(s.project)
    @test any(w -> occursin("settings.tools is not an object", w), open_session(s.project.folder).warnings)
end

@testset "job tools" begin
    try
        made = Ref(0)
        register_tool!(ToolSpec("test.make_db", "Make database", "", "database", Place[], Pair{String,ItemKind}[],
            [TextSetting("name", "Name"; default = "made"), NumberSetting("fail", "Fail"; default = 0.0)], :job,
            (s, i, st, p, r) -> begin
                st["fail"] == 1.0 && throw(ToolError("The name is taken."))
                st["fail"] == 2.0 && error("disk full")
                made[] += 1
                id = lock(() -> JuliaMagCore.reserve_item_id!(s.project, ITEM_DATABASE), s.lock)
                create_database(joinpath(s.project.folder, "databases", id), st["name"])
                report(p, 0.5)
                println(r, "made ", st["name"])
                return [ProjectItem(id, ITEM_DATABASE, st["name"], "databases/$id", "", "")]
            end))
        s = fresh_session()
        @test run_tool(s, "test.make_db"; fail = 5.5, name = 3) == (false, "Name must be text.", nothing)
        j = run_tool(s, "test.make_db"; name = "first")
        @test j isa Job
        wait_job(j)
        @test status(j) == JOB_DONE && only(s.project.items).name == "first"
        @test count(h -> h.command == "test.make_db", s.history) == 1 && s.history[end].job == j.id
        @test occursin("run_tool(s, \"test.make_db\"; fail = 0.0, name = \"first\")", script_text(s))
        @test undo!(s) && isempty(s.project.items)
        jf = run_tool(s, "test.make_db"; fail = 1); wait_job(jf)
        @test status(jf) == JOB_FAILED && jf.error == "The name is taken."
        jf2 = run_tool(s, "test.make_db"; fail = 2); wait_job(jf2)
        @test status(jf2) == JOB_FAILED && occursin("disk full", jf2.error)
        @test isempty(s.project.items) && count(h -> h.command == "test.make_db", s.history) == 1
        # run again, with the same or new settings
        jr = rerun!(s, j; args = merge(j.args, Dict{String,Any}("name" => "second"))); wait_job(jr)
        @test status(jr) == JOB_DONE && only(s.project.items).name == "second"
        jb = rerun!(s, j; args = Dict{String,Any}("fail" => -1.0, "name" => 7)); wait_job(jb)
        @test status(jb) == JOB_FAILED && jb.error == "Name must be text."
        @test made[] == 2
    finally
        unregister_tool!("test.make_db")
    end
end

@testset "importer settings" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "a.xyz"); write_synthetic_xyz(f; lines = 1, ties = 0, rows_per_line = 10)
        j = import_file(s, f; crs = 7855); wait_job(j)
        @test status(j) == JOB_FAILED && j.error == "Coordinate system must be text."
        j = import_file(s, f; mode = :new, name = "survey"); wait_job(j)
        @test status(j) == JOB_DONE && only(s.project.items).name == "survey"
        txt = script_text(s)
        @test occursin("import_file(s, $(repr(f)); mode = \"new\", name = \"survey\")", txt)
        @test occursin("import_file(s, $(repr(f)); crs = 7855)", txt) == false   # failed jobs are not recorded
    end
end

@testset "a script waits for its jobs" begin
    mktempdir() do dir
        folder = joinpath(dir, "p")
        s = new_session(folder, "p")
        start = joinpath(dir, "start")
        cp(folder, start)                               # the project before anything ran
        f = joinpath(dir, "a.xyz"); write_synthetic_xyz(f; lines = 2, ties = 0, rows_per_line = 20_000)
        j = import_file(s, f); wait_job(j)
        id = only(s.project.items).id
        L = first(database(s.project, id).lines).id
        set_line_selected!(s, id, L, false)             # depends on the import (imported channels are protected)
        txt = script_text(s)
        @test occursin("wait_job(import_file(s, $(repr(f))))", txt)
        @test occursin("\nset_line_selected!(s, ", txt)
        # replay on a copy of the starting project, in a module of its own
        body = replace(txt, "open_session($(repr(folder)))" => "open_session($(repr(start)))")
        @test body != txt
        m = Module()
        Core.eval(m, Meta.parseall(body))
        c = open_session(start)
        @test only(c.project.items).id == id
        want = collect(read_channel(database(s.project, id), L, "MAG"))
        got = collect(read_channel(database(c.project, id), L, "MAG"))
        @test isequal(got, want) && length(got) == 20_000
        @test !line(database(c.project, id), L).selected && line(database(c.project, id), last(database(c.project, id).lines).id).selected
        @test status(only(jobs(c))) == JOB_DONE
    end
end
