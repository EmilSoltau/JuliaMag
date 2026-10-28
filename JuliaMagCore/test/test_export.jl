using Test, JuliaMagCore, Parquet2, Printf, Tables

# ---- helpers ---------------------------------------------------------------

"Every channel of every line of `a` equals the same in `b` (with `isequal`, so NaN matches NaN)."
function same_data(a::LineDatabase, b::LineDatabase; names = [c.name for c in a.channels])
    [l.id for l in a.lines] == [l.id for l in b.lines] || return false
    for l in a.lines, n in names
        isequal(collect(read_channel(a, l.id, n)), collect(read_channel(b, l.id, n))) || return false
    end
    return true
end

"The bytes of every file in a folder, by relative path."
function folder_bytes(folder::String)::Dict{String,Vector{UInt8}}
    out = Dict{String,Vector{UInt8}}()
    for (root, _, files) in walkdir(folder), f in files
        p = joinpath(root, f)
        out[relpath(p, folder)] = read(p)
    end
    return out
end

"A session with an imported synthetic XYZ, an appended second flight, and some odd values."
function synthetic_session()
    s = fresh_session()
    dir = mktempdir()
    a = joinpath(dir, "a.xyz")
    write_synthetic_xyz(a; lines = 3, ties = 1, rows_per_line = 300)
    r = import_xyz(s, a; name = "survey")
    id = r.item.id
    b = joinpath(dir, "b.xyz")
    write_synthetic_xyz(b; lines = 2, ties = 0, rows_per_line = 200, seed = 2)
    write(b, replace(read(b, String), "//Flight 7" => "//Flight 8", "2024/05/01" => "2024/05/02"))
    import_xyz(s, b; mode = :append, target = id)
    db = database(s.project, id)
    L = db.lines[1].id
    for (row, x) in enumerate([Inf, -Inf, -0.0, 1.0e-300, 5.0e-324, 0.1 + 0.2, 1.0e22, 123456.789012345678])
        write_value!(db, L, "MAG", row, x)
    end
    return s, id, dir
end

"The folder of a project item."
item_path_of(s::Session, id::String) = joinpath(s.project.folder, s.project.items[findfirst(i -> i.id == id, s.project.items)].path)

"True when a temp file of an export to `path` is left next to it."
left_temp(path::String) = any(f -> startswith(f, basename(path) * ".tmp"), readdir(dirname(path)))

const CANCELLED = Progress(_ -> nothing, () -> true)

# ---- registry --------------------------------------------------------------

@testset "export registry" begin
    @test [e.id for e in exporters(ITEM_DATABASE)] == ["export.geosoft_xyz", "export.csv", "export.parquet"]
    @test isempty(exporters(ITEM_GRID))
    @test exporter_for("out/x.CSV").id == "export.csv"
    @test exporter_for("x.parquet").id == "export.parquet"
    @test exporter_for("export.geosoft_xyz").extension == ".xyz"
    @test exporter_for("x.grd") === nothing
    @test default_settings(exporter_for("x.csv")) ==
          Dict{String,Any}("lines" => "all", "channels" => String[], "delimiter" => ",", "decimal" => ".")
end

# ---- round trips (spec 14) -------------------------------------------------

@testset "export round trip XYZ and CSV" begin
    s, id, dir = synthetic_session()
    src = database(s.project, id)
    @test [line_name(l.id) for l in src.lines] == ["L1001", "L1002", "L1003", "T901", "L1001.1", "L1002.1"]
    before = folder_bytes(item_path_of(s, id))

    xyz = joinpath(dir, "out.xyz")
    r = export_xyz(s, id, xyz)
    @test r.rows == 4 * 300 + 2 * 200 && r.lines == 6 && r.path == xyz
    @test !left_temp(xyz)
    back = database_of(s, import_xyz(s, xyz))
    @test same_data(src, back)
    @test [(l.flight, l.date) for l in back.lines] == [(l.flight, l.date) for l in src.lines]
    @test [(l.fid_start, l.fid_step) for l in back.lines] == [(l.fid_start, l.fid_step) for l in src.lines]

    csv = joinpath(dir, "out.csv")
    export_csv(s, id, csv)
    back = database_of(s, import_csv(s, csv, sniff_csv(csv)))
    @test same_data(src, back)

    # Decimal comma with a semicolon (ruling R10).
    csv2 = joinpath(dir, "comma.csv")
    export_csv(s, id, csv2; delimiter = ';', decimal = ',')
    @test occursin("0,30000000000000004", read(csv2, String))
    layout = sniff_csv(csv2)
    @test layout.delimiter == ';' && layout.decimal == ','
    @test same_data(src, database_of(s, import_csv(s, csv2, layout)))

    # Exports read the database and change nothing in it.
    @test folder_bytes(item_path_of(s, id)) == before
end

@testset "export XYZ text" begin
    s, id, dir = synthetic_session()
    path = joinpath(dir, "t.xyz")
    export_xyz(s, id, path; channels = ["X", "MAG"])
    text = split(read(path, String), '\n')
    @test split(text[1]) == ["/", "X", "MAG"]
    @test text[2:4] == ["//Flight 7", "//Date 2024/05/01", "Line 1001"]
    # Columns line up with the names.
    @test length(text[5]) == length(text[1])
    @test count(==("//Flight 8"), text) == 1 && count(==("//Date 2024/05/02"), text) == 1
    @test "Tie 901" in text && "Line 1001.1" in text && "Line 1002.1" in text
    @test any(t -> endswith(t, " *"), text)
    @test findfirst(==("//Flight 8"), text) == findfirst(==("Line 1001.1"), text) - 2
end

@testset "export selected lines and channels" begin
    s, id, dir = synthetic_session()
    set_line_selected!(s, id, LineId(LINE, 1002, 0), false)
    set_line_selected!(s, id, LineId(TIE, 901, 0), false)
    csv = joinpath(dir, "sel.csv")
    r = export_csv(s, id, csv; lines = "selected", channels = ["MAG", "X"])
    @test r.lines == 4
    back = database_of(s, import_csv(s, csv, sniff_csv(csv)))
    @test [line_name(l.id) for l in back.lines] == ["L1001", "L1003", "L1001.1", "L1002.1"]
    @test [c.name for c in back.channels] == ["MAG", "X"]
    src = database(s.project, id)
    @test all(isequal(collect(read_channel(src, l.id, "MAG")), collect(read_channel(back, l.id, "MAG"))) for l in back.lines)

    # The current line.
    set_cursor!(s, Cursor(id, LineId(TIE, 901, 0), 1))
    @test export_xyz(s, id, joinpath(dir, "cur.xyz"); lines = "current").lines == 1
    set_cursor!(s, Cursor("db-99", LineId(TIE, 901, 0), 1))
    @test_throws ToolError export_xyz(s, id, joinpath(dir, "cur.xyz"); lines = "current")
end

@testset "export refuses bad settings and leaves the target alone" begin
    s, id, dir = synthetic_session()
    path = joinpath(dir, "keep.csv")
    write(path, "old")
    e = try
        export_csv(s, id, path; channels = ["MAG", "NOPE", "ALSO_NOT"])
        nothing
    catch err
        err
    end
    @test e isa ToolError && occursin("NOPE", e.msg) && occursin("ALSO_NOT", e.msg)
    e = try
        export_csv(s, id, path; decimal = ',')
        nothing
    catch err
        err
    end
    @test e isa ToolError && occursin("comma cannot be both", e.msg)
    @test_throws ToolError export_csv(s, id, path; delimiter = 'x')
    @test_throws ToolError export_xyz(s, id, path; lines = "some")
    @test_throws ToolError export_xyz(s, id, dir)          # a folder, not a file
    # Cancel: the temp file is removed and the target is not touched.
    @test_throws JuliaMagCore.ExportCancelled export_xyz(s, id, path; progress = CANCELLED)
    @test_throws JuliaMagCore.ExportCancelled export_parquet(s, id, path; progress = CANCELLED)
    @test read(path, String) == "old" && !left_temp(path)
end

@testset "shortest exact numbers" begin
    pd = JuliaMagCore.plain_decimal
    @test pd(string(7000100.0)) == "7000100.0" && pd(string(1.0e-5)) == "0.00001"
    @test pd(string(-1.5e15)) == "-1500000000000000.0" && pd(string(1.0e16)) == "1.0e16"
    @test pd(string(1.234e-8)) == "1.234e-8" && pd("Inf") == "Inf" && pd("-0.0") == "-0.0"
    for x in (7000100.0, 1.0e-5, 1.0e-7, 0.1 + 0.2, 123456.78901234567, 5.0e-324, 1.0e22, 2.5e-8, 9.0e15)
        @test parse(Float64, pd(string(x))) === x
    end
end

@testset "export decimals" begin
    s, id, dir = synthetic_session()
    db = database(s.project, id)
    channel(db, "MAG").decimals = 2
    channel(db, "ALT").decimals = 1
    channel(db, "ALT").format = :exponential
    save_meta(db)
    src = database(s.project, id)
    path = joinpath(dir, "d.xyz")
    export_xyz(s, id, path)
    rows = filter(t -> startswith(t, "  "), split(read(path, String), '\n'))
    f = split(rows[100])
    @test occursin(r"^\d+\.\d\d$", f[4]) && occursin(r"^\d\.\de\+\d\d$", f[5])
    back = database_of(s, import_xyz(s, path))
    for l in src.lines[2:end]
        a, b = read_channel(src, l.id, "MAG"), read_channel(back, l.id, "MAG")
        # Printf rounds the exact binary value, as the export does.
        @test isequal([isnan(x) ? NaN : parse(Float64, @sprintf("%.2f", x)) for x in a], collect(b))
        @test isequal(collect(read_channel(src, l.id, "X")), collect(read_channel(back, l.id, "X")))
    end
    csv = joinpath(dir, "d.csv")
    export_csv(s, id, csv; delimiter = '\t', decimal = ',')
    @test occursin(r"\t\d+,\d\d\t", read(csv, String))
end

# A database with an array channel, a text channel and a whole number channel.
function mixed_session()
    s = fresh_session()
    p = s.project
    id = new_item_id(p, ITEM_DATABASE)
    db = create_database(joinpath(p.folder, "databases", id), "mixed")
    add_channel!(db, ChannelInfo("MAG", "MAG", Float64, "nT", ROLE_NONE, :normal, 10, -1, false, 1))
    add_channel!(db, ChannelInfo("SPEC", "SPEC", Float64, "", ROLE_NONE, :normal, 10, -1, false, 3))
    add_channel!(db, ChannelInfo("NOTE", "NOTE", String, "", ROLE_NONE, :normal, 10, -1, false, 1))
    add_channel!(db, ChannelInfo("COUNT", "COUNT", Int32, "", ROLE_NONE, :normal, 10, -1, false, 1))
    notes = ["a, b", "say \"hi\"", "", "plain", "two  words"]
    for (k, id_) in enumerate([LineId(LINE, 10, 0), LineId(TIE, 20, 1)])
        add_line!(db, LineInfo(id_, 0, "", 0.0, 1.0, 5, 0, true))
        apps = open_appenders(db, ["MAG", "SPEC", "NOTE", "COUNT"])
        for r in 1:5
            append_value!(apps["MAG"], r == 3 ? NaN : 100.0 * k + r / 8)
            append_value!(apps["SPEC"], [r, r == 2 ? NaN : 2r, 3r + k])
            append_value!(apps["NOTE"], notes[r])
            append_value!(apps["COUNT"], r == 4 ? typemin(Int32) : Int32(r * k))
        end
        close_appenders!(apps)
    end
    save_meta(db)
    add_item!(p, ProjectItem(id, ITEM_DATABASE, "mixed", "databases/$id", "", ""))
    save_project(p)
    return s, id
end

@testset "export arrays, text and whole numbers" begin
    s, id = mixed_session()
    src = database(s.project, id)
    dir = mktempdir()
    csv = joinpath(dir, "m.csv")
    export_csv(s, id, csv)
    text = read(csv, String)
    @test startswith(text, "LINE,MAG,SPEC[0],SPEC[1],SPEC[2],NOTE,COUNT\nL10,")
    @test occursin("\"a, b\"", text) && occursin("\"say \"\"hi\"\"\"", text) && occursin("\nT20.1,", text)
    back = database_of(s, import_csv(s, csv, sniff_csv(csv)))
    @test channel(back, "SPEC").arraylen == 3 && channel(back, "NOTE").eltype === String
    @test same_data(src, back; names = ["MAG", "SPEC", "NOTE"])
    for l in src.lines
        c = read_channel(src, l.id, "COUNT")
        @test isequal(read_channel(back, l.id, "COUNT"), [ismissingvalue(x) ? NaN : Float64(x) for x in c])
    end

    xyz = joinpath(dir, "m.xyz")
    r = export_xyz(s, id, xyz)
    lines = split(read(xyz, String), '\n')
    @test split(lines[1]) == ["/", "MAG", "SPEC[0]", "SPEC[1]", "SPEC[2]", "NOTE", "COUNT"]
    @test lines[2] == "Line 10" && "Tie 20.1" in lines
    rows = filter(t -> startswith(t, "  "), lines)
    @test split(rows[1])[end-1] == "a,_b"
    @test split(rows[3])[1] == "*" && split(rows[3])[end-1] == "*"     # missing MAG and empty text
    @test split(rows[4])[end] == "*"                                    # missing whole number
    @test split(rows[5])[end-1] == "two__words"
    @test any(n -> occursin("blank", n), r.notes)
end

@testset "export parquet" begin
    s, id, dir = synthetic_session()
    src = database(s.project, id)
    path = joinpath(dir, "p.parquet")
    r = export_parquet(s, id, path)
    @test !left_temp(path)
    ds = Parquet2.Dataset(path)
    @test Parquet2.nrowgroups(ds) == length(src.lines)
    t = Tables.columntable(ds)
    @test keys(t) == (:LINE, :X, :Y, :FIDUCIAL, :MAG, :ALT)
    @test length(t.LINE) == r.rows == sum(l.nrows for l in src.lines)
    @test t.LINE == reduce(vcat, [fill(line_name(l.id), l.nrows) for l in src.lines])
    @test isequal(t.MAG, reduce(vcat, [collect(read_channel(src, l.id, "MAG")) for l in src.lines]))
    @test eltype(t.MAG) == Float64
    close(ds)

    s2, id2 = mixed_session()
    p2 = joinpath(dir, "m.parquet")
    export_parquet(s2, id2, p2; lines = "all", channels = ["SPEC", "NOTE", "COUNT"])
    ds = Parquet2.Dataset(p2)
    t = Tables.columntable(ds)
    @test keys(t) == (:LINE, Symbol("SPEC[0]"), Symbol("SPEC[1]"), Symbol("SPEC[2]"), :NOTE, :COUNT)
    @test t.LINE == [fill("L10", 5); fill("T20.1", 5)]
    # Whole numbers and text use nulls for missing values; floats keep NaN.
    @test nonmissingtype(eltype(t.COUNT)) == Int32 && nonmissingtype(eltype(t.NOTE)) == String
    @test t.COUNT[4] === missing && t.COUNT[5] === Int32(5) && t.COUNT[9] === missing
    @test isequal(t.NOTE[1:4], ["a, b", "say \"hi\"", missing, "plain"])
    @test isnan(t[Symbol("SPEC[1]")][2])
    close(ds)
end

# ---- jobs, history and scripts (ruling R11) --------------------------------

@testset "export as a job" begin
    s, id, dir = synthetic_session()
    undo_depth = length(s.undo_stack)
    path = joinpath(dir, "job.csv")
    j = wait_job(export_file(s, id, path; channels = ["MAG"], delimiter = ';'))
    @test status(j) == JOB_DONE && isempty(j.outputs) && j.progress[] == 1.0
    @test j.command == "export.csv" && isfile(path) && !left_temp(path)
    @test startswith(read(path, String), "LINE;MAG\n")
    @test length(s.undo_stack) == undo_depth          # an export has no undo step
    e = s.history[end]
    @test e.command == "export.csv" && e.job == j.id
    @test e.args == Dict{String,Any}("item" => id, "path" => path, "channels" => ["MAG"], "delimiter" => ";")
    @test count(h -> h.job == j.id, s.history) == 1
    @test occursin("rows in 6 lines", String(take!(copy(j.report))))

    # The script waits for the export, and the line runs again.
    line = split(script_text(s), '\n')[end-1]
    @test line == "wait_job(export_file(s, $(repr(id)), $(repr(path)); exporter = \"export.csv\", " *
                  "channels = [\"MAG\"], delimiter = \";\"))"
    rm(path)
    m = Module()
    Core.eval(m, :(using JuliaMagCore))
    Core.eval(m, :(s = $s))
    j2 = Core.eval(m, Meta.parse(line))
    @test status(j2) == JOB_DONE && startswith(read(path, String), "LINE;MAG\n")

    # A direct call is recorded and becomes a job in the script too.
    export_xyz(s, id, joinpath(dir, "direct.xyz"); channels = ["X"])
    @test s.history[end].command == "export.geosoft_xyz" && isempty(s.history[end].job)
    @test startswith(split(script_text(s), '\n')[end-1], "wait_job(export_file(s, $(repr(id)), ")

    # Run again.
    rm(path)
    j3 = wait_job(rerun!(s, j))
    @test status(j3) == JOB_DONE && isfile(path) && length(s.undo_stack) == undo_depth

    # Picked by id, not by extension.
    p = joinpath(dir, "data.bin")
    @test status(wait_job(export_file(s, id, p; exporter = "export.parquet"))) == JOB_DONE
    ds = Parquet2.Dataset(p)
    @test Parquet2.nrowgroups(ds) == 6
    close(ds)
end

@testset "failed and cancelled export jobs" begin
    s, id, dir = synthetic_session()
    path = joinpath(dir, "keep.xyz")
    write(path, "old")
    n = length(s.history)
    j = wait_job(export_file(s, id, path; channels = ["NOPE"]))
    @test status(j) == JOB_FAILED && occursin("NOPE", j.error)
    j = wait_job(export_file(s, id, joinpath(dir, "x.grd")))
    @test status(j) == JOB_FAILED && occursin("no exporter", j.error)
    j = wait_job(export_file(s, id, path; exporter = "export.nothing"))
    @test status(j) == JOB_FAILED && occursin("export.nothing", j.error)
    @test read(path, String) == "old" && !left_temp(path)
    @test length(s.history) == n
end

@testset "an export job cancelled while it writes" begin
    s, id, dir = synthetic_session()
    path = joinpath(dir, "keep.xyz")
    write(path, "old")
    # A test exporter that cancels its own job, then writes: the cancel is seen after the first block.
    register_exporter!(ExporterSpec("export.test_cancel", "Cancel test", ".cancel_test", ITEM_MAP, SettingSpec[],
        (s, item_id, path, settings, progress) -> begin
            cancel!(only(filter(j -> j.command == "export.test_cancel" && status(j) == JOB_RUNNING, jobs(s))))
            export_xyz(s, item_id, path; progress, record = false)
        end))
    n = length(s.history)
    j = wait_job(export_file(s, id, path; exporter = "export.test_cancel"))
    @test status(j) == JOB_CANCELLED && j.error == "the job was cancelled"
    @test read(path, String) == "old" && !left_temp(path)
    @test length(s.history) == n
end

@testset "export reads the committed rows" begin
    s, id, dir = synthetic_session()
    db = database(s.project, id)
    nlines = length(db.lines)
    # An import that is still writing: its rows are not committed yet.
    apps = open_appenders(db, ["MAG"])
    add_line!(db, LineInfo(LineId(LINE, 5000, 0), 0, "", 0.0, 1.0, 3, 0, true))
    foreach(x -> append_value!(apps["MAG"], x), [1.0, 2.0, 3.0])
    end_line!(apps)
    try
        r = export_csv(s, id, joinpath(dir, "c.csv"))
        @test r.lines == nlines
        @test !occursin("L5000", read(joinpath(dir, "c.csv"), String))
    finally
        close_appenders!(apps)
    end
end

# A session with one database whose lines have the sampling `start`, `step` and no FIDUCIAL channel.
function sampled_session(; extra = String[])
    s = fresh_session()
    p = s.project
    id = new_item_id(p, ITEM_DATABASE)
    db = create_database(joinpath(p.folder, "databases", id), "sampled")
    names = ["MAG"; extra]
    foreach(n -> add_channel!(db, ChannelInfo(n, n, Float64, "", ROLE_NONE, :normal, 10, -1, false, 1)), names)
    for (k, (start, step)) in enumerate([(100.0, 0.5), (0.0, 1.0), (-3.25, 2.0)])
        add_line!(db, LineInfo(LineId(LINE, k, 0), 0, "", start, step, 4, 0, true))
        apps = open_appenders(db, names)
        foreach(r -> foreach(n -> append_value!(apps[n], 10.0k + r), names), 1:4)
        close_appenders!(apps)
    end
    save_meta(db)
    add_item!(p, ProjectItem(id, ITEM_DATABASE, "sampled", "databases/$id", "", ""))
    save_project(p)
    return s, id
end

@testset "export keeps the line sampling" begin
    s, id = sampled_session()
    dir = mktempdir()
    sampling(db) = [(l.fid_start, l.fid_step) for l in db.lines]
    want = [(100.0, 0.5), (0.0, 1.0), (-3.25, 2.0)]
    xyz = joinpath(dir, "f.xyz")
    export_xyz(s, id, xyz)
    @test split(readline(xyz)) == ["/", "MAG", "FIDUCIAL"]
    @test sampling(database_of(s, import_xyz(s, xyz))) == want
    csv = joinpath(dir, "f.csv")
    export_csv(s, id, csv)
    @test readline(csv) == "LINE,MAG,FIDUCIAL"
    @test sampling(database_of(s, import_csv(s, csv, sniff_csv(csv)))) == want

    # A FIDUCIAL channel that is not exported: the added column is FIDUCIAL_.
    s, id = sampled_session(extra = ["FIDUCIAL"])
    export_xyz(s, id, xyz; channels = ["MAG"])
    @test split(readline(xyz)) == ["/", "MAG", "FIDUCIAL_"]
    @test sampling(database_of(s, import_xyz(s, xyz))) == want
    export_csv(s, id, csv; channels = ["MAG"])
    @test sampling(database_of(s, import_csv(s, csv, sniff_csv(csv)))) == want
    # An exported FIDUCIAL channel is used as it is.
    export_xyz(s, id, xyz)
    @test split(readline(xyz)) == ["/", "MAG", "FIDUCIAL"]
end

@testset "CSV and Parquet refuse a channel named LINE" begin
    s, id = sampled_session(extra = ["Line"])
    dir = mktempdir()
    for f in (export_csv, export_parquet)
        e = try
            f(s, id, joinpath(dir, "x"); channels = String[])
            nothing
        catch err
            err
        end
        @test e isa ToolError && occursin("LINE", e.msg)
    end
    @test export_csv(s, id, joinpath(dir, "ok.csv"); channels = ["MAG"]).lines == 3
    @test export_xyz(s, id, joinpath(dir, "ok.xyz")).lines == 3       # XYZ has no LINE column
end

@testset "an export marks its item busy (ruling R12)" begin
    s, id, dir = synthetic_session()
    L = LineId(LINE, 1001, 0)
    set_line_selected!(s, id, L, false)                  # something to undo
    started, release = Channel{Nothing}(1), Channel{Nothing}(1)
    first_block = Ref(true)
    gated = Progress(f -> (f > 0 && first_block[] && (first_block[] = false; put!(started, nothing); take!(release)); nothing),
                     () -> false)
    task = Threads.@spawn export_csv(s, id, joinpath(dir, "gate.csv"); progress = gated)
    @test timedwait(() -> isready(started), 30) == :ok   # no hang when the export fails early
    take!(started)
    err = try
        set_line_selected!(s, id, L, true); nothing
    catch e
        e
    end
    @test err isa ItemBusyError && sprint(showerror, err) == "ItemBusyError: $id is busy: an export is running"
    @test_throws ItemBusyError set_cell!(s, id, L, "MAG", 1, 1.0)
    @test_throws ItemBusyError undo!(s)
    a = joinpath(dir, "more.xyz")
    write_synthetic_xyz(a; lines = 1, ties = 0, rows_per_line = 10)
    @test_throws ItemBusyError import_xyz(s, a; mode = :append, target = id)
    # Another export of the same item may run at the same time.
    @test export_xyz(s, id, joinpath(dir, "second.xyz"); channels = ["MAG"]).lines == 6
    put!(release, nothing)
    @test fetch(task).lines == 6
    @test undo!(s) && line(database(s.project, id), L).selected
    @test import_xyz(s, a; mode = :append, target = id).lines == 1
    @test isempty(s.busy)

    # An export may run while an import appends: it writes the committed lines.
    entered, gate = Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false)
    held = Progress(_ -> nothing, () -> (entered[] = true; while !gate[]; sleep(0.001); end; false))
    Threads.@spawn (sleep(30); gate[] = true)          # a watchdog, so a failure does not hang
    imp = Threads.@spawn import_xyz(s, a; mode = :append, target = id, progress = held)
    @test timedwait(() -> entered[], 30) == :ok
    r = export_csv(s, id, joinpath(dir, "during.csv"))
    @test r.lines == 7
    @test_throws ItemBusyError set_line_selected!(s, id, L, false)   # the import still holds it
    gate[] = true
    @test fetch(imp).lines == 1
    @test isempty(s.busy) && length(database(s.project, id).lines) == 8
end
