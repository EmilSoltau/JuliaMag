using Test, JuliaMagCore

# Brief examples. `database_of` takes the session too (ruling R2b).
@testset "csv brief" begin
    @test sniff_csv(testdata("semicolon.csv")).delimiter == ';'
    s = fresh_session()
    r = import_csv(s, testdata("lines.csv"), sniff_csv(testdata("lines.csv")); name = "c")
    @test [line_name(l.id) for l in database_of(s, r).lines] == ["L1001", "T2001"]
end

@testset "csv semicolons and quotes" begin
    # X;Y;MAG;NOTE, then rows with a quoted number, "a; b", "say ""hi""" and a `*`.
    layout = sniff_csv(testdata("semicolon.csv"))
    @test layout.heading_row == 1 && layout.units_row == 0 && layout.first_data_row == 2
    @test [c.name for c in layout.columns] == ["X", "Y", "MAG", "NOTE"]
    @test [c.eltype for c in layout.columns] == [Float64, Float64, Float64, String]
    @test all(c.role == :data for c in layout.columns)
    @test layout.x == "X" && layout.y == "Y" && layout.line_column == ""
    s = fresh_session()
    r = import_csv(s, testdata("semicolon.csv"), layout)
    db = database_of(s, r)
    @test r.rows == 3 && r.lines == 1 && isempty(r.warnings)
    @test r.item.name == "semicolon"
    L = only(db.lines).id
    @test L == LineId(RANDOM, 0, 0)
    @test read_channel(db, L, "NOTE") == ["a; b", "say \"hi\"", "plain"]
    @test collect(read_channel(db, L, "X")) == [500000.0, 500010.0, 500020.0]
    mag = read_channel(db, L, "MAG")
    @test mag[1:2] == [50000.1, 50000.2] && isnan(mag[3])
    @test channel(db, "NOTE").eltype === String
    @test channel(db, "X").role == ROLE_X && channel(db, "Y").role == ROLE_Y
    @test length(db.pairs) == 1
    @test all(c.protected && c.decimals == -1 for c in db.channels)
    @test s.history[end].command == "import.csv"
end

@testset "csv units row and fiducial" begin
    layout = sniff_csv(testdata("units.csv"))
    @test layout.delimiter == ',' && layout.heading_row == 1 && layout.units_row == 2 && layout.first_data_row == 3
    @test [c.units for c in layout.columns] == ["s", "m", "m", "nT"]
    @test [c.role for c in layout.columns] == [:fiducial, :data, :data, :data]
    @test layout.x == "EASTING" && layout.y == "NORTHING"
    s = fresh_session()
    r = import_csv(s, testdata("units.csv"), layout; name = "u")
    db = database_of(s, r)
    @test r.rows == 4 && isempty(r.warnings)
    @test channel(db, "TMI").units == "nT" && channel(db, "FIDUCIAL").units == "s"
    l = only(db.lines)
    @test l.fid_start == 10.0 && l.fid_step == 0.5
    @test collect(read_channel(db, l.id, "FIDUCIAL")) == [10.0, 10.5, 11.0, 11.5]
    @test isnan(read_channel(db, l.id, "TMI")[3])
    @test channel(db, "EASTING").role == ROLE_X && db.pairs[1].x == "EASTING"
end

@testset "csv line column" begin
    layout = sniff_csv(testdata("lines.csv"))
    @test layout.line_column == "LINE" && layout.columns[1].role == :line
    s = fresh_session()
    r = import_csv(s, testdata("lines.csv"), layout)
    db = database_of(s, r)
    @test r.lines == 2 && r.rows == 3
    @test !any(c -> c.name == "LINE", db.channels)            # the line column is not a channel
    @test collect(read_channel(db, LineId(LINE, 1001, 0), "MAG")) == [3.0, 6.0]
    @test collect(read_channel(db, LineId(TIE, 2001, 0), "MAG")) == [9.0]

    # Plain numbers are LINE lines; ".2" is a version; a bad value is a warning and
    # the row goes to the current line; a line that comes back gets a new version.
    s2 = fresh_session()
    r2 = import_csv(s2, testdata("line_values.csv"), sniff_csv(testdata("line_values.csv")))
    db2 = database_of(s2, r2)
    @test [line_name(l.id) for l in db2.lines] == ["L1001", "L1001.2", "T5", "L1001.3"]
    @test collect(read_channel(db2, LineId(LINE, 1001, 2), "MAG")) == [12.0, 13.0]
    @test length(r2.warnings) == 1 && r2.warnings[1].file_line == 5
    @test occursin("bad?", r2.warnings[1].message) && occursin("L1001.2", r2.warnings[1].message)
end

@testset "csv fixed width" begin
    cols = [CsvColumn("LINE", :line, String, ""), CsvColumn("X", :data, Float64, "m"),
            CsvColumn("MAG", :data, Float64, "nT")]
    layout = CsvLayout(; fixed_widths = [6, 10, 8], heading_row = 1, first_data_row = 2,
                       columns = cols, line_column = "LINE")
    s = fresh_session()
    r = import_csv(s, testdata("fixed.dat"), layout; name = "f")
    db = database_of(s, r)
    @test [line_name(l.id) for l in db.lines] == ["L10", "L20"]
    @test r.rows == 3
    x = read_channel(db, LineId(LINE, 10, 0), "X")
    @test collect(x) == [500000.0, 500010.0]
    @test isnan(read_channel(db, LineId(LINE, 10, 0), "MAG")[2])
    @test collect(read_channel(db, LineId(LINE, 20, 0), "MAG")) == [50000.3]
    # The last row ends inside the X column: too few values.
    @test [w.file_line for w in r.warnings] == [5]
    @test occursin("expected 3 values, found 2", r.warnings[1].message)
    # sniff with the widths finds the names and types.
    g = sniff_csv(testdata("fixed.dat"); fixed_widths = [6, 10, 8])
    @test g.fixed_widths == [6, 10, 8] && g.heading_row == 1 && g.first_data_row == 2
    @test [c.name for c in g.columns] == ["LINE", "X", "MAG"] && g.line_column == "LINE"
    @test preview_rows(testdata("fixed.dat"), layout; rows = 2) == [["LINE", "X", "MAG"], ["L10", "500000.0", "50000.1"]]
end

@testset "csv windows files" begin               # Review Focus 1
    mktempdir() do dir
        text = read(testdata("units.csv"), String)
        crlf = joinpath(dir, "crlf.csv")
        write(crlf, "\xef\xbb\xbf" * replace(text, "\n" => "\r\n"))
        a, b = sniff_csv(testdata("units.csv")), sniff_csv(crlf)
        @test a == b
        s = fresh_session()
        da = database_of(s, import_csv(s, testdata("units.csv"), a))
        db = database_of(s, import_csv(s, crlf, b))
        @test [c.name for c in da.channels] == [c.name for c in db.channels] == ["FIDUCIAL", "EASTING", "NORTHING", "TMI"]
        @test [c.units for c in da.channels] == [c.units for c in db.channels]
        @test [(l.id, l.nrows, l.fid_start, l.fid_step) for l in da.lines] ==
              [(l.id, l.nrows, l.fid_start, l.fid_step) for l in db.lines]
        @test all(isequal(collect(read_channel(da, l.id, c.name)), collect(read_channel(db, l.id, c.name)))
                  for l in da.lines for c in da.channels)
        # A quoted text value at the end of a CRLF line keeps no "\r".
        q = joinpath(dir, "q.csv")
        write(q, "\xef\xbb\xbfA,B\r\n1,\"x\"\r\n2,y\r\n")
        dq = database_of(s, import_csv(s, q, sniff_csv(q)))
        @test read_channel(dq, dq.lines[1].id, "B") == ["x", "y"]
        @test sniff_csv(q).columns[1].name == "A"           # the byte order mark is not part of the name
    end
end

@testset "csv rows with the wrong number of values" begin   # Review Focus 4
    # A,B,C; then "1,2,3", "4,5", "6,7,8", "9,10,11,12", ",,", "13,14,15,"
    s = fresh_session()
    r = import_csv(s, testdata("short_rows.csv"), sniff_csv(testdata("short_rows.csv")))
    @test r.rows == 3
    @test [w.file_line for w in r.warnings] == [3, 5]
    @test occursin("expected 3 values, found 2", r.warnings[1].message)
    @test occursin("expected 3 values, found 4", r.warnings[2].message)
    db = database_of(s, r)
    @test collect(read_channel(db, db.lines[1].id, "C")) == [3.0, 8.0, 15.0]
end

@testset "csv values that are not numbers" begin
    mktempdir() do dir
        f = joinpath(dir, "v.csv")
        write(f, "LINE,A,B\nL1,1,2\nL1,x,3\nL1,y,4\nL2,z,5\n")
        layout = sniff_csv(f)
        # Sniffing sees "x" and makes A a text column; force it to numbers.
        @test layout.columns[2].eltype === String
        cols = copy(layout.columns)
        cols[2] = CsvColumn("A", :data, Float64, "")
        s = fresh_session()
        r = import_csv(s, f, CsvLayout(layout; columns = cols))
        @test [w.file_line for w in r.warnings] == [3, 5]       # once per column per line
        @test all(occursin("column A", w.message) for w in r.warnings)
        db = database_of(s, r)
        a = read_channel(db, LineId(LINE, 1, 0), "A")
        @test a[1] == 1.0 && isnan(a[2]) && isnan(a[3])
    end
end

@testset "csv arrays" begin
    layout = sniff_csv(testdata("arrays.csv"))
    @test [c.role for c in layout.columns] == [:fiducial, :array, :array, :array, :data]
    s = fresh_session()
    r = import_csv(s, testdata("arrays.csv"), layout)
    db = database_of(s, r)
    @test [c.name for c in db.channels] == ["FID", "SPEC", "MAG"]
    @test channel(db, "SPEC").arraylen == 3
    @test collect(read_channel(db, db.lines[1].id, "SPEC")) == [10.0 20.0; 11.0 21.0; 12.0 22.0]
    @test collect(read_channel(db, db.lines[1].id, "MAG")) == [50.0, 51.0]
    # The SPEC_0 form, set by the user; two groups side by side.
    mktempdir() do dir
        f = joinpath(dir, "u.csv")
        write(f, "A_0,A_1,B_0,B_1\n1,2,3,4\n")
        cols = [CsvColumn(n, :array, Float64, "") for n in ("A_0", "A_1", "B_0", "B_1")]
        r2 = import_csv(s, f, CsvLayout(; heading_row = 1, first_data_row = 2, columns = cols))
        d2 = database_of(s, r2)
        @test [(c.name, c.arraylen) for c in d2.channels] == [("A", 2), ("B", 2)]
        @test vec(collect(read_channel(d2, d2.lines[1].id, "B"))) == [3.0, 4.0]
    end
end

@testset "csv white space and preview" begin
    # A title line, a blank line, then names and rows split by spaces.
    layout = sniff_csv(testdata("spaces.txt"))
    @test layout.delimiter == ' ' && layout.heading_row == 3 && layout.first_data_row == 4
    @test [c.name for c in layout.columns] == ["TIME", "X", "Y", "MAG"]
    s = fresh_session()
    r = import_csv(s, testdata("spaces.txt"), layout)
    @test r.rows == 2 && isempty(r.warnings)
    p = preview_rows(testdata("spaces.txt"), layout)
    @test p == [["Survey", "export"], String[], ["TIME", "X", "Y", "MAG"], ["0.0", "10", "20", "30"], ["0.1", "11", "21", "31"]]
    @test preview_rows(testdata("semicolon.csv"), sniff_csv(testdata("semicolon.csv")); rows = 3)[3] ==
          ["500010.0", "7000000.0", "50000.2", "say \"hi\""]
end

@testset "csv templates" begin
    s = fresh_session()
    layout = sniff_csv(testdata("units.csv"))
    layout = CsvLayout(layout; crs = "EPSG:7855")
    save_template(s, "Survey 2024 / A", layout)
    @test isfile(joinpath(s.project.folder, "templates", "survey-2024-a.json"))
    @test load_template(s, "Survey 2024 / A") == layout
    @test list_templates(s) == ["Survey 2024 / A"]
    # The template is plain JSON that a new session reads too.
    @test load_template(open_session(s.project.folder), "Survey 2024 / A") == layout
    e = try
        load_template(s, "nope"); nothing
    catch err
        err
    end
    @test e isa ToolError && occursin("nope", e.msg)
    @test_throws ToolError save_template(s, "///", layout)
    # Another name with the same file name is refused; the same name replaces.
    e2 = try
        save_template(s, "survey 2024 a", layout); nothing
    catch err
        err
    end
    @test e2 isa ToolError && occursin("Survey 2024 / A", e2.msg)
    save_template(s, "Survey 2024 / A", CsvLayout(layout; crs = "EPSG:28355"))
    @test load_template(s, "Survey 2024 / A").crs == "EPSG:28355"
    @test_throws ToolError load_template(s, "survey 2024 a")
    # A template file with a bad layout is refused when it is loaded.
    t = JuliaMagCore.layout_dict(CsvLayout(layout; x = "NOPE"))
    JuliaMagCore.write_json_atomic(joinpath(s.project.folder, "templates", "badx.json"),
                                   Dict("version" => 1, "name" => "badx", "layout" => t))
    e3 = try
        load_template(s, "badx"); nothing
    catch err
        err
    end
    @test e3 isa ToolError && occursin("x column NOPE", e3.msg)
    # A template from before the decimal field reads as '.'.
    delete!(t, "decimal"); t["x"] = layout.x
    JuliaMagCore.write_json_atomic(joinpath(s.project.folder, "templates", "old.json"),
                                   Dict("version" => 1, "name" => "old", "layout" => t))
    @test load_template(s, "old").decimal == '.'
    # A broken template file is a plain error too.
    write(joinpath(s.project.folder, "templates", "bad.json"), "{ not json")
    @test_throws ToolError load_template(s, "bad")
end

@testset "csv layout checks" begin
    s = fresh_session()
    f = testdata("lines.csv")
    base = sniff_csv(f)
    bad(l) = try
        import_csv(s, f, l); ""
    catch e
        e isa ToolError ? e.msg : "not a ToolError: $e"
    end
    @test occursin("x column NOPE", bad(CsvLayout(base; x = "NOPE")))
    @test occursin("line column", bad(CsvLayout(base; line_column = "")))
    @test occursin("delimiter", bad(CsvLayout(base; delimiter = '"')))
    @test occursin("first data row", bad(CsvLayout(base; first_data_row = 1)))
    @test occursin("columns", bad(CsvLayout(base; fixed_widths = [3, 4])))
    @test occursin("decimal", bad(CsvLayout(base; decimal = ',')))
    @test occursin("decimal", bad(CsvLayout(base; delimiter = ';', decimal = 'x')))
    @test isempty(s.project.items)
    @test isempty(readdir(joinpath(s.project.folder, "databases")))
    @test_throws ToolError sniff_csv(joinpath(mktempdir(), "missing.csv"))
end

@testset "csv append, jobs and undo" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        j1 = import_file(s, testdata("lines.csv")); wait_job(j1)
        @test status(j1) == JOB_DONE
        id = only(j1.outputs)
        @test s.history[end].command == "import.csv"
        save_template(s, "lines", sniff_csv(testdata("lines.csv")))
        j2 = import_file(s, testdata("lines.csv"); mode = "append", target = id, template = "lines")
        wait_job(j2)
        @test status(j2) == JOB_DONE
        # The job records the layout it used, so a rerun does not depend on the template.
        @test j2.args["layout"] == layout_json(sniff_csv(testdata("lines.csv")))
        @test s.history[end].args["layout"] == j2.args["layout"]
        db = database(s.project, id)
        @test [line_name(l.id) for l in db.lines] == ["L1001", "T2001", "L1001.1", "T2001.1"]
        @test undo!(s)
        @test [line_name(l.id) for l in database(s.project, id).lines] == ["L1001", "T2001"]
        @test redo!(s)
        @test length(database(s.project, id).lines) == 4
        # A text column cannot go into a number channel: the job fails, the database is kept.
        f = joinpath(dir, "t.csv"); write(f, "LINE,MAG\nL5,abc\n")
        j3 = import_file(s, f; mode = "append", target = id); wait_job(j3)
        @test status(j3) == JOB_FAILED && occursin("MAG", j3.error)
        @test length(database(s.project, id).lines) == 4
        # A template that is not there fails the job with a plain message.
        j4 = import_file(s, testdata("lines.csv"); template = "gone"); wait_job(j4)
        @test status(j4) == JOB_FAILED && occursin("gone", j4.error)
        # The layout as JSON text, as the import dialog passes it, and a crs.
        txt = layout_json(sniff_csv(testdata("units.csv")))
        j5 = import_file(s, testdata("units.csv"); layout = txt, crs = "EPSG:7855", name = "u"); wait_job(j5)
        @test status(j5) == JOB_DONE
        du = database(s.project, only(j5.outputs))
        @test du.pairs[1].crs == "EPSG:7855" && channel(du, "TMI").units == "nT"
        # A direct import records its layout, so the script can run it again.
        r = import_csv(s, testdata("units.csv"), sniff_csv(testdata("units.csv")); name = "direct")
        @test haskey(s.history[end].args, "layout")
        @test occursin("import_file(s, $(repr(testdata("units.csv"))); layout = ", script_text(s))
        j6 = rerun!(s, j5); wait_job(j6)
        @test status(j6) == JOB_DONE
        rm(joinpath(s.project.folder, "templates", "lines.json"))
        j7 = rerun!(s, j2; args = merge(j2.args, Dict("mode" => "new"))); wait_job(j7)
        @test status(j7) == JOB_DONE
        @test importer_for("a.TSV").id == "import.csv" && importer_for("b.dat").id == "import.csv"
        @test [st.key for st in importer_for("a.csv").settings] == ["mode", "name", "target", "template", "layout", "crs"]
    end
end

# Cancel on the second chunk, so some rows are written before the import stops.
csv_cancel_later() = (n = Ref(0); Progress(_ -> nothing, () -> (n[] += 1) >= 2))

@testset "csv cancel leaves no trace" begin
    mktempdir() do dir
        s = new_session(joinpath(dir, "p"), "p")
        big = joinpath(dir, "big.csv")
        open(big, "w") do io
            println(io, "LINE,X,Y,MAG,NOTE")
            for k in 1:150_000
                println(io, "L", 1000 + k ÷ 30_000, ",", 500000 + k, ",7000000,", 50000 + k / 1000, ",\"n, $k\"")
            end
        end
        @test filesize(big) > (4 << 20)
        dbs = joinpath(s.project.folder, "databases")
        layout = sniff_csv(big)
        @test_throws JuliaMagCore.ImportCancelled import_csv(s, big, layout; progress = csv_cancel_later())
        @test isempty(s.project.items) && isempty(readdir(dbs))
        r = import_csv(s, big, layout)
        @test r.rows == 150_000 && r.lines == 6 && isempty(r.warnings)
        db = database_of(s, r)
        @test read_channel(db, db.lines[end].id, "NOTE")[end] == "n, 150000"
        folder = joinpath(dbs, only(readdir(dbs)))
        meta = read(joinpath(folder, "database.json"), String)
        @test_throws JuliaMagCore.ImportCancelled import_csv(s, big, layout; mode = :append, target = r.item.id,
                                                             progress = csv_cancel_later())
        @test read(joinpath(folder, "database.json"), String) == meta
        @test length(database(s.project, r.item.id).lines) == 6
    end
end

@testset "csv scanner does not allocate for numbers" begin
    sp = JuliaMagCore.FieldSplitter(sniff_csv(testdata("lines.csv")), 8)
    s = "L1001,500000.5,7000000.25,-12.5e3,\"4.5\""
    f() = (n = JuliaMagCore.split_fields!(sp, s, 1, ncodeunits(s));
           t = 0.0; for k in 2:n; t += something(JuliaMagCore.field_number(sp, s, k), 0.0); end; t)
    @test f() ≈ 500000.5 + 7000000.25 - 12500 + 4.5
    @test (@allocated f()) == 0
    # The decimal comma path.
    cp = JuliaMagCore.FieldSplitter(CsvLayout(; delimiter = ';', decimal = ','), 8)
    c = "L1001;500000,5;7000000,25;-12,5e3;\"4,5\""
    g() = (n = JuliaMagCore.split_fields!(cp, c, 1, ncodeunits(c));
           t = 0.0; for k in 2:n; t += something(JuliaMagCore.field_number(cp, c, k), 0.0); end; t)
    @test g() ≈ 500000.5 + 7000000.25 - 12500 + 4.5
    @test (@allocated g()) == 0
    # With a decimal comma, a point or a second comma is not a number.
    for bad in ("1.5", "1,5,3", "1,5x", "")
        t = "A;$bad"
        JuliaMagCore.split_fields!(cp, t, 1, ncodeunits(t))
        @test JuliaMagCore.field_number(cp, t, 2) === nothing
    end
end

@testset "csv fixed width with leading blanks" begin
    # Widths 6, 10, 8. The first column starts with blanks; row 3 has an empty first field.
    cols = [CsvColumn("LINE", :line, String, ""), CsvColumn("X", :data, Float64, ""),
            CsvColumn("MAG", :data, Float64, "")]
    layout = CsvLayout(; fixed_widths = [6, 10, 8], columns = cols, line_column = "LINE")
    @test preview_rows(testdata("fixed_blank.dat"), layout)[1] == ["L10", "500000.0", "50000.1"]
    s = fresh_session()
    r = import_csv(s, testdata("fixed_blank.dat"), layout)
    db = database_of(s, r)
    @test [line_name(l.id) for l in db.lines] == ["L10", "L20"]
    @test collect(read_channel(db, LineId(LINE, 10, 0), "X")) == [500000.0, 500010.0, 500020.0]
    @test collect(read_channel(db, LineId(LINE, 10, 0), "MAG")) == [50000.1, 50000.2, 50000.3]
    @test collect(read_channel(db, LineId(LINE, 20, 0), "MAG")) == [50000.4]
    # Only the empty line value of row 3 is a warning.
    @test [w.file_line for w in r.warnings] == [3]
    @test occursin("line value", r.warnings[1].message)
end

@testset "csv decimal comma" begin
    layout = sniff_csv(testdata("decimal_comma.csv"))
    @test layout.delimiter == ';' && layout.decimal == ','
    @test [c.eltype for c in layout.columns] == [Float64, Float64, Float64, String]
    @test layout.x == "X" && layout.y == "Y"
    s = fresh_session()
    r = import_csv(s, testdata("decimal_comma.csv"), layout)
    db = database_of(s, r)
    @test isempty(r.warnings) && r.rows == 3
    L = only(db.lines).id
    @test collect(read_channel(db, L, "X")) == [500000.5, 500010.5, 500020.5]
    @test collect(read_channel(db, L, "Y")) == [7000000.25, 7000000.25, 7000000.25]
    mag = read_channel(db, L, "MAG")
    @test mag[1:2] == [50000.1, -1500.0] && isnan(mag[3])
    @test db.pairs[1].x == "X" && db.pairs[1].y == "Y" && channel(db, "X").role == ROLE_X
    # Only data rows, no heading: the semicolon still wins over the comma.
    mktempdir() do dir
        f = joinpath(dir, "d.csv")
        write(f, "1,5;2,25;3,1\n4,5;5,25;6,1\n")
        g = sniff_csv(f)
        @test g.delimiter == ';' && g.decimal == ',' && all(c -> c.eltype === Float64, g.columns)
        # A file with points keeps '.'.
        write(f, "A;B\n1.5;2,5\n")
        @test sniff_csv(f).decimal == '.'
        # The template and the layout JSON keep the decimal mark.
        @test JuliaMagCore.layout_from_json(layout_json(layout), "x").decimal == ','
    end
end

@testset "csv text after a closing quote" begin
    mktempdir() do dir
        f = joinpath(dir, "q.csv")
        write(f, "A,B\n1,\"x\"\n2,\"y\"z\n3,\"w\" \n")
        s = fresh_session()
        r = import_csv(s, f, sniff_csv(f))
        db = database_of(s, r)
        @test read_channel(db, db.lines[1].id, "B") == ["x", "y", "w"]
        @test [w.file_line for w in r.warnings] == [3]
        @test occursin("closing quote", r.warnings[1].message) && occursin("column B", r.warnings[1].message)
    end
end
