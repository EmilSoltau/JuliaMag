# Bulk line positions and the change counters of items.

@testset "line points: the brief" begin
    s = fresh_session(); id = survey_database!(s; nan_line = 2)
    db = database(s.project, id)
    p = read_line_points(db, "X", "Y", "MAG")
    @test p.origin == (500_000.0, 7_000_000.0) && length(p.x) == 10
    @test p.part_line == Int32[1, 3] && p.part_row == Int32[1, 1] && p.part_count == Int32[5, 5]
    @test p.part_first == Int32[0, 5] && length(p.lines) == 3
    @test p.x[1:5] == Float32[0, 10, 20, 30, 40] && p.y[6] == 100f0 && p.value[1:5] == Float32[101, 102, 103, 104, 105]
    @test all(isnan, p.extents[2]) && p.extents[1] == (500_000.0, 7_000_000.0, 500_040.0, 7_000_000.0)
    L = LineId(LINE, 1001, 0)
    set_cell!(s, id, L, "X", 3, NaN); set_cell!(s, id, L, "MAG", 1, NaN)
    q = read_line_points(database(s.project, id), "X", "Y", "MAG"; into = p)
    @test q === p && q.part_row[1:2] == Int32[1, 4] && q.part_count[1:2] == Int32[2, 2] && isnan(q.value[1])
    @test all(isnan, read_line_points(database(s.project, id), "X", "Y").value)
    @test_throws ArgumentError read_line_points(database(s.project, id), "X", "Y", "NOPE")
    r0 = item_revision(s, id)
    set_cell!(s, id, L, "MAG", 2, 7.0); @test item_revision(s, id) == r0 + 1
    undo!(s); @test item_revision(s, id) == r0 + 2 && item_revisions(s)[id] == r0 + 2
    redo!(s); @test item_revision(s, id) == r0 + 3
    @test item_revision(s, "db-99") == 0
end

@testset "data revisions: every write says whether it changes data" begin
    s = fresh_session(); id = survey_database!(s)
    g = add_test_grid!(s, Float32[i + j for i in 1:4, j in 1:3])
    L = LineId(LINE, 1001, 0)
    m, lid = Ref(""), Ref("")
    # How much `f()`, its undo and its redo change `item_revision` and `data_revision` of `item[]`.
    function counts(f, item)
        step(act) = (i = item_revision(s, item[]); d = data_revision(s, item[]); act();
                     (item_revision(s, item[]) - i, data_revision(s, item[]) - d))
        return (step(f), step(() -> undo!(s)), step(() -> redo!(s)))
    end
    yes, no = ((1, 1), (1, 1), (1, 1)), ((1, 0), (1, 0), (1, 0))
    ins = Dict("database" => id)
    writes = [
        ("set_cell!", yes, Ref(id), () -> set_cell!(s, id, L, "MAG", 2, 7.0)),
        ("set_line_selected!", no, Ref(id), () -> set_line_selected!(s, id, L, false)),
        ("set_lines_selected!", no, Ref(id), () -> set_lines_selected!(s, id, [L], true)),
        ("rename_item!", no, Ref(id), () -> rename_item!(s, id, "Survey")),
        ("set_channel_protected!", no, Ref(id), () -> set_channel_protected!(s, id, "X", true)),
        ("set_channel_info!", no, Ref(id), () -> set_channel_info!(s, id, "X"; units = "km")),
        ("add_pair!", yes, Ref(id), () -> add_pair!(s, id, "MAG", "Y")),
        ("coordinates.set_current", yes, Ref(id),
         () -> run_tool(s, "coordinates.set_current"; inputs = ins, pair = "MAG,Y")),
        ("coordinates.set_crs", yes, Ref(id),
         () -> run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "X,Y", crs = "EPSG:7855")),
        ("remove_pair!", yes, Ref(id), () -> remove_pair!(s, id, "MAG", "Y")),
        ("coordinates.reproject", yes, Ref(id),
         () -> wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "X,Y", crs = "EPSG:32755"))),
        ("database.channel_math", yes, Ref(id),
         () -> wait_job(run_tool(s, "database.channel_math"; inputs = ins, expr = "M2 = MAG + 1", lines = "all"))),
        ("rename_channel!", yes, Ref(id), () -> rename_channel!(s, id, "M2", "M3")),
        ("delete_channel!", yes, Ref(id), () -> delete_channel!(s, id, "M3")),
        ("set_grid_crs!", yes, Ref(g), () -> set_grid_crs!(s, g, "EPSG:7855")),
        ("set_grid_georef!", yes, Ref(g), () -> set_grid_georef!(s, g; x0 = 1.0)),
        ("set_grid_style!", no, Ref(g),
         () -> set_grid_style!(s, g, GridStyle("grey", :linear, NaN, NaN, false, false, 45.0, 45.0, 1.0))),
        ("new_map!", no, m, () -> (m[] = new_map!(s; name = "M"))),
        ("add_layer!", no, m, () -> (lid[] = add_layer!(s, m[], g))),
        ("set_layer!", no, m, () -> set_layer!(s, m[], lid[]; opacity = 0.5)),
        ("add_layer! again", no, m, () -> add_layer!(s, m[], g)),
        ("move_layer!", no, m, () -> move_layer!(s, m[], lid[], 2)),
        ("remove_layer!", no, m, () -> remove_layer!(s, m[], lid[])),
        ("remove_item!", yes, Ref(g), () -> remove_item!(s, g)),
    ]
    for (name, want, item, f) in writes
        @test (name, counts(f, item)) == (name, want)
    end
    @test data_revision(s, m[]) == 0
    # The cursor is no undo step: neither number moves.
    i, d = item_revision(s, id), data_revision(s, id)
    set_cursor!(s, Cursor(id, L, 1))
    @test (item_revision(s, id), data_revision(s, id)) == (i, d)
    # A new item from an import starts with one data change.
    mktempdir() do dir
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 2, ties = 0, rows_per_line = 5)
        out = only(wait_job(import_file(s, a)).outputs)
        @test data_revision(s, out) == 1 && data_revisions(s)[out] == 1
    end
    # A failed job takes back what it noted: a map may have read the half-written item.
    i, d = item_revision(s, id), data_revision(s, id)
    j = wait_job(start_job!(s, "test.fails", Dict{String,Any}(), (p, io) -> begin
        JuliaMagCore.note_job_undo!(() -> nothing, () -> nothing, () -> nothing; items = [id])
        error("the work failed")
    end))
    @test status(j) == JOB_FAILED
    @test (item_revision(s, id), data_revision(s, id)) == (i, d + 1)
end

@testset "line points: edge cases" begin
    s = fresh_session(); id = survey_database!(s; lines = 2, nan_line = 1)
    set_cell!(s, id, LineId(LINE, 1002, 0), "X", 1, NaN)
    for r in 2:5
        set_cell!(s, id, LineId(LINE, 1002, 0), "Y", r, NaN)
    end
    p = read_line_points(database(s.project, id), "X", "Y", "MAG")
    @test isempty(p.x) && isempty(p.part_first) && length(p.extents) == 2 && all(e -> all(isnan, e), p.extents)
    @test isempty(LinePoints().x)

    # a reprojected read
    s2 = fresh_session()
    id2 = survey_database!(s2; x0 = 147.0, y0 = -42.0, dx = 0.001, dy = 0.01, crs = "EPSG:4326")
    db2 = database(s2.project, id2)
    r = JuliaMagCore.Reprojector("EPSG:4326", "EPSG:32755")
    q = read_line_points(db2, "X", "Y"; reproject = r)
    close(r)
    xs = [147.0 + (k - 1) * 0.001 for l in 1:3 for k in 1:5]
    ys = [-42.0 + (l - 1) * 0.01 for l in 1:3 for k in 1:5]
    ex, ey = reproject_xy(xs, ys, "EPSG:4326", "EPSG:32755")
    @test length(q.x) == 15
    @test all(abs.(q.origin[1] .+ Float64.(q.x) .- ex) .< 1e-3)
    @test all(abs.(q.origin[2] .+ Float64.(q.y) .- ey) .< 1e-3)
    @test q.origin == (floor(ex[1]), floor(ey[1]))
end

@testset "line points: no new arrays on a second read" begin
    s = fresh_session(); id = survey_database!(s; lines = 4, rows = 50_000)
    db = database(s.project, id)
    p = read_line_points(db, "X", "Y", "MAG")
    @test length(p.x) == 200_000
    read_line_points(db, "X", "Y", "MAG"; into = p)
    @test (@allocated read_line_points(db, "X", "Y", "MAG"; into = p)) < 100_000
end

# A database with line 1001 written (3 rows) and an open line 1002 (2 rows, not appended yet).
function open_line_database(dir)
    db = create_database(joinpath(dir, "d"), "d")
    for (name, role) in (("X", ROLE_X), ("Y", ROLE_Y))
        add_channel!(db, ChannelInfo(name, name, Float64, "m", role, :normal, 10, -1, false, 1))
    end
    add_line!(db, LineInfo(LineId(LINE, 1001, 0), 1, "2024-05-01", 0.0, 0.1, 3, 0, true))
    apps = open_appenders(db, ["X", "Y"])
    for r in 1:3
        append_value!(apps["X"], 100.0 + r); append_value!(apps["Y"], 200.0 + r)
    end
    close_appenders!(apps)
    add_line!(db, LineInfo(LineId(LINE, 1002, 0), 1, "2024-05-01", 0.0, 0.1, 2, 0, true))
    return db
end

@testset "line points: a line still being appended is skipped" begin
    mktempdir() do dir
        db = open_line_database(dir)
        p = read_line_points(db, "X", "Y")
        @test length(p.x) == 3 && p.part_line == Int32[1] && length(p.lines) == 2
        @test all(isnan, p.extents[2]) && p.extents[1] == (101.0, 201.0, 103.0, 203.0)
    end
end

@testset "line points: the read follows one snapshot of the lines" begin
    mktempdir() do dir
        db = open_line_database(dir)
        snap = JuliaMagCore.line_snapshot(db)
        # The open line ends and another line is added after the snapshot.
        end_line!(db)
        add_line!(db, LineInfo(LineId(LINE, 1003, 0), 1, "2024-05-01", 0.0, 0.1, 4, 0, true))
        end_line!(db)
        p = JuliaMagCore.read_snapshot!(LinePoints(), db, snap, "X", "Y", nothing, nothing)
        @test length(p.x) == 3 && length(p.lines) == 2 && length(p.extents) == 2
        @test all(isnan, p.extents[2])
        # A new read sees all lines.
        @test length(read_line_points(db, "X", "Y").lines) == 3
    end
end
