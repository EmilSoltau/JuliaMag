using Test, JuliaMagCore

@testset "xyz import" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "a.xyz"); write_synthetic_xyz(f; lines = 3, ties = 1, rows_per_line = 50)
        r = import_xyz(s, f; crs = "EPSG:7855")
        db = database(s.project, r.item.id)
        @test r.lines == 4 && r.rows == 200 && isempty(r.warnings)
        @test [line_name(l.id) for l in db.lines][1:2] == ["L1001", "L1002"]
        @test db.pairs[db.current_pair].crs == "EPSG:7855"
        @test all(c.protected for c in db.channels)
        @test db.lines[1].fid_step ≈ 1.0

        # More detail on the same import.
        @test line_name(db.lines[4].id) == "T901"
        @test [c.name for c in db.channels] == ["X", "Y", "FIDUCIAL", "MAG", "ALT"]
        @test all(c.eltype === Float64 && c.decimals == -1 for c in db.channels)
        @test channel(db, "X").role == ROLE_X && channel(db, "Y").role == ROLE_Y
        @test db.pairs[db.current_pair].x == "X" && db.pairs[db.current_pair].y == "Y"
        @test all(l.flight == 7 && l.date == "2024-05-01" && l.fid_start == 0.0 for l in db.lines)
        @test collect(read_channel(db, db.lines[2].id, "FIDUCIAL")) == 0.0:49.0
        @test any(isnan, read_channel(db, db.lines[1].id, "MAG"))
        @test r.item.name == "a" && r.item.path == "databases/a"
        @test s.history[end].command == "import.geosoft_xyz"
        @test s.history[end].args["crs"] == "EPSG:7855"
        @test readdir(joinpath(s.project.folder, "databases")) == ["a"]
        @test any(i -> i.id == r.item.id, open_project(s.project.folder).items)

        # A second import with the same name gets a numbered folder and a new id.
        r2 = import_xyz(s, f)
        @test r2.item.path == "databases/a-2" && r2.item.id != r.item.id
        @test isempty(database(s.project, r2.item.id).pairs[1].crs)
    end
end

@testset "xyz windows files" begin            # Review Focus 1
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "lf.xyz");   write_synthetic_xyz(a)
        b = joinpath(dir, "crlf.xyz"); write_synthetic_xyz(b; crlf = true, bom = true)
        da = database(s.project, import_xyz(s, a).item.id)
        db = database(s.project, import_xyz(s, b).item.id)
        L = da.lines[1].id
        @test [c.name for c in da.channels] == [c.name for c in db.channels]
        @test isequal(collect(read_channel(da, L, "MAG")), collect(read_channel(db, L, "MAG")))
        # Every line and channel is the same, not only the first.
        @test [l.id for l in da.lines] == [l.id for l in db.lines]
        @test all(isequal(collect(read_channel(da, l.id, c.name)), collect(read_channel(db, l.id, c.name)))
                  for l in da.lines for c in da.channels)
    end
end

@testset "xyz bad rows" begin                 # Review Focus 4
    # test/data/bad_rows.xyz: header X Y MAG, line L10, rows: "1 2 3", "4 5", "6 7 8 9", "10 11 12"
    r = import_xyz(fresh_session(), testdata("bad_rows.xyz"))
    @test r.rows == 2
    @test [w.file_line for w in r.warnings] == [5, 6]
    @test all(occursin("expected 3 values", w.message) for w in r.warnings)
end

@testset "xyz repeated line" begin            # Review Focus 5
    # test/data/repeat_line.xyz: "Line 10" block, "Line 20" block, "Line 10" block again
    s = fresh_session()
    db = database_of(s, import_xyz(s, testdata("repeat_line.xyz")))
    @test [line_name(l.id) for l in db.lines] == ["L10", "L20", "L10.1"]
    @test collect(read_channel(db, LineId(LINE, 10, 1), "MAG")) == [6.0, 7.0]
end

@testset "xyz flight and date" begin
    s = fresh_session()
    db = database_of(s, import_xyz(s, testdata("flight_date.xyz")))
    @test [line_name(l.id) for l in db.lines] == ["L10", "T20", "L30.2"]
    @test [l.flight for l in db.lines] == [3, 4, 4]
    @test [l.date for l in db.lines] == ["2024-05-01", "2024-05-02", "2024-05-02"]
end

@testset "xyz without line headers" begin
    s = fresh_session()
    r = import_xyz(s, testdata("no_header.xyz"))
    db = database_of(s, r)
    @test [line_name(l.id) for l in db.lines] == ["D0"] && r.rows == 2 && isempty(r.warnings)
    @test collect(read_channel(db, LineId(RANDOM, 0, 0), "MAG")) == [3.0, 6.0]
    # No FIDUCIAL column: start 0, step 1.
    @test db.lines[1].fid_start == 0.0 && db.lines[1].fid_step == 1.0
end

@testset "xyz without channel names" begin
    s = fresh_session()
    r = import_xyz(s, testdata("no_names.xyz"))
    @test [c.name for c in database_of(s, r).channels] == ["C1", "C2", "C3"]
    @test length(r.warnings) == 1 && r.warnings[1].file_line == 2
end

@testset "xyz values that are not numbers" begin
    # Line 1 has two bad values in column Y, line 2 has one: one warning per column per line.
    s = fresh_session()
    r = import_xyz(s, testdata("bad_values.xyz"))
    db = database_of(s, r)
    @test r.rows == 4
    @test [w.file_line for w in r.warnings] == [3, 7]
    @test all(occursin("column Y", w.message) for w in r.warnings)
    y = collect(read_channel(db, LineId(LINE, 1, 0), "Y"))
    @test isnan(y[1]) && isnan(y[2]) && y[3] == 8.0
    @test isnan(read_channel(db, LineId(LINE, 1, 0), "MAG")[3])
end

@testset "xyz longitude, latitude and fiducials" begin
    s = fresh_session()
    r = import_xyz(s, testdata("lonlat.xyz"); crs = "EPSG:28355")
    db = database_of(s, r)
    # The last "/" line with 4 names wins, also over the units line before it.
    @test [c.name for c in db.channels] == ["FIDUCIAL", "LONGITUDE", "LATITUDE", "TMI"]
    @test channel(db, "LONGITUDE").role == ROLE_LON && channel(db, "LATITUDE").role == ROLE_LAT
    @test length(db.pairs) == 1 && db.pairs[1].crs == "EPSG:4326" && db.current_pair == 1
    @test [line_name(l.id) for l in db.lines] == ["L5", "T7.1"]
    @test db.lines[1].fid_start == 10.0 && db.lines[1].fid_step == 0.5
    @test db.lines[2].fid_start == 20.0 && db.lines[2].fid_step == 1.0
    # "Base 3" has no rows: it is skipped with a warning.
    @test length(r.warnings) == 1 && r.warnings[1].file_line == 12
    @test occursin("B3", r.warnings[1].message)
end

@testset "xyz empty file fails and cleans up" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "empty.xyz"); write(f, "/ X Y\n")
        @test_throws ArgumentError import_xyz(s, f)
        @test isempty(s.project.items)
        @test isempty(readdir(joinpath(s.project.folder, "databases")))
    end
end

# Cancel on the second chunk, so some rows are written before the import stops.
cancel_later() = (n = Ref(0); Progress(_ -> nothing, () -> (n[] += 1) >= 2))

@testset "xyz append" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        a = joinpath(dir, "a.xyz"); write_synthetic_xyz(a; lines = 2, ties = 0, rows_per_line = 10)
        b = joinpath(dir, "b.xyz")
        write_synthetic_xyz(b; lines = 3, ties = 0, rows_per_line = 5, channels = ["X", "Y", "FIDUCIAL", "MAG", "GPSALT"])
        id = import_xyz(s, a).item.id
        n_items = length(s.project.items)
        r = import_xyz(s, b; mode = :append, target = id)
        @test r.item.id == id && length(s.project.items) == n_items
        @test r.lines == 3 && r.rows == 15
        db = database(s.project, id)
        @test [line_name(l.id) for l in db.lines] == ["L1001", "L1002", "L1001.1", "L1002.1", "L1003"]
        @test [c.name for c in db.channels] == ["X", "Y", "FIDUCIAL", "MAG", "ALT", "GPSALT"]
        @test all(isnan, read_channel(db, LineId(LINE, 1001, 1), "ALT"))
        @test all(isnan, read_channel(db, LineId(LINE, 1001, 0), "GPSALT"))
        @test collect(read_channel(db, LineId(LINE, 1003, 0), "FIDUCIAL")) == 0.0:4.0
        @test length(db.pairs) == 1
        @test s.history[end].args["mode"] == "append"

        # Append again: versions go up once more.
        import_xyz(s, b; mode = :append, target = id)
        @test line_name(database(s.project, id).lines[6].id) == "L1001.2"

        @test_throws ArgumentError import_xyz(s, b; mode = :append, target = "")
        @test_throws ArgumentError import_xyz(s, b; mode = :merge)
    end
end

@testset "xyz cancel leaves no trace" begin       # cancel within a chunk
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        big = joinpath(dir, "big.xyz")
        write_synthetic_xyz(big; lines = 6, ties = 0, rows_per_line = 20_000,
                            channels = ["X", "Y", "FIDUCIAL", "MAG", "ALT", "EXTRA"])
        @test filesize(big) > (4 << 20)
        dbs = joinpath(s.project.folder, "databases")

        # New mode: the temp folder is removed and no item is added.
        @test_throws JuliaMagCore.ImportCancelled import_xyz(s, big; progress = cancel_later())
        @test isempty(s.project.items) && isempty(readdir(dbs))

        # Append mode: the target stays as it was, also on disk.
        small = joinpath(dir, "small.xyz"); write_synthetic_xyz(small; lines = 1, ties = 0, rows_per_line = 10)
        id = import_xyz(s, small).item.id
        folder = joinpath(dbs, only(readdir(dbs)))
        files() = Dict(f => filesize(joinpath(folder, "channels", f)) for f in readdir(joinpath(folder, "channels")))
        before = files()
        meta = read(joinpath(folder, "database.json"), String)
        @test_throws JuliaMagCore.ImportCancelled import_xyz(s, big; mode = :append, target = id,
                                                             progress = cancel_later())
        @test files() == before
        @test read(joinpath(folder, "database.json"), String) == meta
        db = database(s.project, id)
        @test length(db.lines) == 1 && !any(c -> c.name == "EXTRA", db.channels)
    end
end

@testset "xyz progress" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        f = joinpath(dir, "a.xyz"); write_synthetic_xyz(f; lines = 2, ties = 0, rows_per_line = 100)
        seen = Float64[]
        import_xyz(s, f; progress = Progress(x -> push!(seen, x), () -> false))
        @test !isempty(seen) && issorted(seen) && last(seen) == 1.0 && all(0 .<= seen .<= 1)
        @test !is_cancelled(NO_PROGRESS)
        @test report(NO_PROGRESS, 0.5) === nothing
    end
end

@testset "eachfileline" begin
    mktempdir() do dir
        f = joinpath(dir, "t.txt")
        # BOM, CRLF, an empty line, a line longer than the chunk, no newline at the end.
        long = repeat("x", 25)
        write(f, "\xef\xbb\xbfab\r\n\r\n$long\ncd\r\nlast")
        got = Tuple{Int,String}[]
        bytes = Int[]
        eachfileline(f; chunk = 7) do n, line, b
            push!(got, (n, String(line)))
            push!(bytes, b)
        end
        @test got == [(1, "ab"), (2, ""), (3, long), (4, "cd"), (5, "last")]
        @test issorted(bytes) && last(bytes) == filesize(f)

        # A line split across chunk edges at every position comes out whole.
        text = join(("line $k with some text" for k in 1:50), "\n") * "\n"
        write(f, text)
        for chunk in (1, 2, 3, 5, 8, 13, 64, 1 << 20)
            lines = String[]
            eachfileline((n, l, b) -> push!(lines, String(l)), f; chunk)
            @test lines == split(chomp(text), '\n')
        end

        # Multi-byte characters across a chunk edge.
        write(f, "på å\nö\n")
        lines = String[]
        eachfileline((n, l, b) -> push!(lines, String(l)), f; chunk = 2)
        @test lines == ["på å", "ö"]

        write(f, "")
        n = Ref(0)
        eachfileline((_...) -> (n[] += 1), f)
        @test n[] == 0
    end
end

@testset "importer registry" begin
    spec = importer_for("C:\\data\\Survey.XYZ")
    @test spec !== nothing && spec.id == "import.geosoft_xyz" && spec.kind == ITEM_DATABASE
    @test importer_for("a.unknown") === nothing
    @test any(i -> i.id == "import.geosoft_xyz", importers())
    s = fresh_session()
    r = spec.run(s, testdata("no_header.xyz"), Dict{String,Any}("name" => "nh", "crs" => "EPSG:7855"), NO_PROGRESS)
    @test r isa ImportResult && r.item.name == "nh"
    @test database_of(s, r).pairs[1].crs == "EPSG:7855"
end
