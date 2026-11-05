using Test, JuliaMagCore, JSON3
using JuliaMagCore: with_gdb, blob_offset, read_blob_header, ImportCancelled, Progress, meta_path, channel

"A Progress that asks to stop at its second check, so the first blob is read."
gdb_cancel_later() = (n = Ref(0); Progress(_ -> nothing, () -> (n[] += 1) >= 2))

"The temp folders an import left in the project."
importing_folders(s) = (d = joinpath(s.project.folder, "databases");
                        isdir(d) ? filter(startswith(".importing-"), readdir(d)) : String[])

"""
A survey database: lines L10 and L20 with `rows` rows, channels X, Y (Float64),
Mag (Float32) and FltNo (Int32). Line `k` (0-based) holds X = 1000k + row,
Y = 2000 + row, Mag = 50000 + row / 4 and FltNo = 7.
"""
function survey_gdb(path; rows = 20, pack = :zlib, types = (5, 5, 4, 3), names = ("X", "Y", "Mag", "FltNo"), kw...)
    chans = [TestChannel(name = n, type = t) for (n, t) in zip(names, types)]
    vals(l, c) = c == 0 ? [1000.0 * l + r for r in 1:rows] : c == 1 ? [2000.0 + r for r in 1:rows] :
                 c == 2 ? [50000 + r / 4 for r in 1:rows] : fill(7, rows)
    write_test_gdb(path; channels = chans,
                   lines = [TestLine(name = "L10", number = 10), TestLine(name = "L20", number = 20)],
                   blob = (l, c) -> TestBlob(values = vals(l, c), pack = pack), kw...)
end

"Import `path` through a job and wait for it."
gdb_job(s, path; kw...) = wait_job(import_file(s, path; kw...))

"The database the job made."
job_db(s, j) = database(s.project, only(j.outputs))

@testset "gdb import" begin
    @testset "the XYZ comparison" begin
        (; s, id, L) = make_db_with(A = [1.25, NaN], B = [12.5, 1.5 / 3600], C = [2024 + 60 / 366, 2024 + 365 / 366],
                                    D = [1500.0, 0.02])
        db = database(s.project, id)
        xyz = joinpath(mktempdir(), "t.XYZ")
        write(xyz, "/ A B C D\nLine 1001\n1.25 12:30:00.0 2024/03/01 1.5e+03\n* 00:00:01.5 2024/12/31 2.0E-2\n")
        @test compare_gdb_xyz(db, xyz) == (8, String[])
        write(xyz, "/ A B C D\nLine 1001\n1.30 12:30:00.0 2024/03/02 1.5e+03\n* 00:00:01.5 2024/12/31 2.0E-2\n")
        n, bad = compare_gdb_xyz(db, xyz)
        @test n == 8 && length(bad) == 2 && occursin("column A", bad[1]) && occursin("column C", bad[2])
        # A rename, and a block with too few rows.
        write(xyz, "/ AA B C D\nLine 1001\n1.25 12:30:00.0 2024/03/01 1.5e+03\n")
        n, bad = compare_gdb_xyz(db, xyz; rename = Dict("AA" => "A"))
        @test n == 4 && only(bad) == "line L1001: the database has 1 more rows than the XYZ block"
        # Oasis keyword lines (`//flight=`, `//date=`) do not name columns, as in 7042_106_wform.xyz;
        # a `//` line with names does, as in fortymile.
        write(xyz, "/Volt\n//date=October 25, 2007\n//flight=106\nLine 106\n 3.9\n")
        @test xyz_column_names(xyz) == ["Volt"]
        write(xyz, "/ Flight: 12\n// Date 2007/10/25\n/ A\nLine 106\n 3.9\n")
        @test xyz_column_names(xyz) == ["A"]
        write(xyz, "//   A   B   C   D\n LINE 1001\n1.25 12:30:00.0 2024/03/01 1.5e+03\n* 00:00:01.5 2024/12/31 2.0E-2\n")
        @test xyz_column_names(xyz) == ["A", "B", "C", "D"]
        @test compare_gdb_xyz(db, xyz) == (8, String[])
        # An export with no names line needs the names from a reference, as long_valley_ed.XYZ does.
        write(xyz, "Line 1001\n1.25 12:30:00.0 2024/03/01 1.5e+03\n* 00:00:01.5 2024/12/31 2.0E-2\n")
        @test_throws ErrorException compare_gdb_xyz(db, xyz)
        @test compare_gdb_xyz(db, xyz; names = ["A", "BB", "C", "D"], rename = Dict("BB" => "B")) == (8, String[])
        @test_throws ErrorException compare_gdb_xyz(db, xyz; names = ["A", "B", "C"])
        close_session!(s)

        # Blocks match lines by their header, not by their order (long_valley_ed lists its lines
        # in another order than its slots). A header that is not a line name needs `lines`.
        s = fresh_session()
        dir = mktempdir()
        db = database_of(s, import_gdb(s, survey_gdb(joinpath(dir, "s.gdb"); rows = 2); crs = "EPSG:32755"))
        write(xyz, "/ X Y\nLine 20\n1001 2001\n1002 2002\nLine 10\n1 2001\n2 2002\n")
        @test compare_gdb_xyz(db, xyz) == (8, String[])
        write(xyz, "/ X Y\nLine 20\n1001 2001\n1002 2002\nLine 10_a\n1 2001\n2 2002\n")
        @test compare_gdb_xyz(db, xyz; lines = Dict("Line 10_a" => "L10")) == (8, String[])
        n, bad = compare_gdb_xyz(db, xyz)
        @test n == 4 && bad == ["XYZ block \"Line 10_a\" names no line of the database",
                                "line L10 has no block in the XYZ"]
        close_session!(s)
    end

    @testset "afgrav" begin
        s = fresh_session()
        job = wait_job(import_file(s, testdata("gdb/afgrav.gdb")))
        @test status(job) == JOB_DONE
        db = database(s.project, only(job.outputs))
        @test length(db.lines) == 1 && line_name(db.lines[1].id) == "D0"
        @test length(db.channels) == 10 && all(c.protected for c in db.channels)
        n, bad = compare_gdb_xyz(db, testdata("gdb/afgrav.XYZ"))
        @test isempty(bad) && n == 16_450                               # research 13
        @test s.history[end].command == "import.geosoft_gdb"
        @test s.history[end].args["path"] == testdata("gdb/afgrav.gdb")
        # Channels, labels and display settings from the plans (Task 7).
        @test [c.name for c in db.channels] == ["xTM", "yTM", "longitude", "latitude", "obs_grav", "elev",
                                                "dod_grav_libno", "dod_rbs_no", "faa", "ba"]
        @test channel(db, "faa").label == "mgals" && channel(db, "ba").label == "ba"
        @test channel(db, "xTM").units == "m" && channel(db, "xTM").width == 11 && channel(db, "xTM").decimals == 2
        @test channel(db, "xTM").role == ROLE_X && channel(db, "longitude").role == ROLE_LON
        @test [(p.x, p.y, p.crs) for p in db.pairs] == [("xTM", "yTM", ""), ("longitude", "latitude", "EPSG:4326")]
        @test db.current_pair == 1
        @test db.lines[1].date == "2005-10-25" && db.lines[1].nrows == 1645
        # The custom system of xTM, yTM is an item warning on the job card.
        @test length(job_warnings(job)) == 1 && occursin("custom", only(job_warnings(job)))
        # The crs setting fills the current pair.
        job = gdb_job(s, testdata("gdb/afgrav.gdb"); crs = "EPSG:32642")
        @test status(job) == JOB_DONE && isempty(job_warnings(job))
        @test job_db(s, job).pairs[1].crs == "EPSG:32642"
        close_session!(s)
    end

    @testset "every value type" begin
        mktempdir() do dir
            types = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, -8]
            names = ["t$c" for c in 0:9]
            push!(names, "txt")
            vals = Any[Int8[1, -127, -128], [1, 65535, 7], [1, -32767, 3], [1, -2147483647, 3],
                       [1.5, -1e32, 2.5], [1.5, -1e32, 2.5], [1, 255, 3], [1, 0xffffffff, 3],
                       [1, typemin(Int64), 3], [1, typemax(UInt64), 3], ["ab", "", "xyz"]]
            chans = [TestChannel(name = n, type = t, format = n == "t5" ? 1 : 0, width = n == "t5" ? 12 : 10,
                                 decimals = n == "t5" ? 3 : 2) for (n, t) in zip(names, types)]
            path = write_test_gdb(joinpath(dir, "types.gdb"); channels = chans, chans_max = 12,
                                  lines = [TestLine(name = "L10", number = 10)],
                                  blob = (l, c) -> TestBlob(values = vals[c + 1]))
            s = new_session(joinpath(dir, "p"), "p")
            j = gdb_job(s, path)
            @test status(j) == JOB_DONE
            db = job_db(s, j)
            L = db.lines[1].id
            @test [c.eltype for c in db.channels] ==
                  [Int8, Int32, Int16, Int32, Float32, Float64, UInt8, Float64, Float64, Float64, String]
            rd(n) = collect(read_channel(db, L, n))
            @test rd("t0") == Int8[1, typemin(Int8), typemin(Int8)]
            @test rd("t1") == Int32[1, typemin(Int32), 7]
            @test rd("t2") == Int16[1, typemin(Int16), 3]
            @test rd("t3") == Int32[1, typemin(Int32), 3]
            @test isequal(rd("t4"), Float32[1.5, NaN, 2.5]) && isequal(rd("t5"), [1.5, NaN, 2.5])
            @test rd("t6") == UInt8[1, 255, 3]
            @test all(n -> isequal(rd(n), [1.0, NaN, 3.0]), ["t7", "t8", "t9"])
            @test rd("txt") == ["ab", "", "xyz"]
            t5 = channel(db, "t5")
            @test t5.format == :exponential && t5.width == 12 && t5.decimals == 3
            @test job_warnings(j) == ["channel t0: 1 value equals JuliaMag's missing marker and reads as missing"]
            close_session!(s)
        end
    end

    @testset "sampling: resampled, padded and missing channels" begin
        mktempdir() do dir
            chans = [TestChannel(name = n) for n in ("A", "B", "C", "D")]
            lines = [TestLine(name = "L10", number = 10), TestLine(name = "L20", number = 20),
                     TestLine(name = "L30", number = 30)]
            function blob(l, c)
                l == 2 && return nothing                                   # L30 has no data
                if l == 0                                                  # Review Focus 2
                    c == 1 && return TestBlob(values = [10.0 * k for k in 0:9], fid_start = 0.5)
                    c == 2 && return TestBlob(values = [100.0 * k for k in 0:4], fid_step = 2.0)
                    return TestBlob(values = collect(0.0:9.0))
                end
                c == 1 && return nothing                                   # B has no data on L20
                c == 2 && return TestBlob(values = collect(1.0:10.0), fid_start = 5.0, fid_step = 0.5)  # 10 rows short
                return TestBlob(values = collect(1.0:20.0), fid_start = 5.0, fid_step = 0.5)
            end
            path = write_test_gdb(joinpath(dir, "fid.gdb"); channels = chans, lines = lines, blob = blob)
            s = new_session(joinpath(dir, "p"), "p")
            j = gdb_job(s, path)
            @test status(j) == JOB_DONE
            db = job_db(s, j)
            @test [line_name(l.id) for l in db.lines] == ["L10", "L20"]
            l10, l20 = db.lines
            @test l10.nrows == 10 && l10.fid_start == 0.0 && l10.fid_step == 1.0
            @test l20.nrows == 20 && l20.fid_start == 5.0 && l20.fid_step == 0.5
            rd(l, n) = collect(read_channel(db, l.id, n))
            @test rd(l10, "A") == collect(0.0:9.0)
            @test isequal(rd(l10, "B"), [NaN; [10.0 * k + 5 for k in 0:8]])
            @test isequal(rd(l10, "C"), [0.0, 50, 100, 150, 200, 250, 300, 350, 400, NaN])
            @test all(isnan, rd(l20, "B"))
            @test isequal(rd(l20, "C"), [collect(1.0:10.0); fill(NaN, 10)])
            @test db.rows_written == 30
            w = job_warnings(j)
            @test w == ["line L10: channels B, C have another fiducial start or step than the line " *
                        "(start 0.0, step 1.0); they were resampled onto it",
                        "line L20: channel C has fewer rows than the line; the rest are missing",
                        "line L20: channel B has no data on this line; it is missing",
                        "line L30 has no data; skipped"]
            close_session!(s)
        end
    end

    @testset "line warnings go on the job card once" begin
        mktempdir() do dir
            lines = [TestLine(name = "L10", number = 10), TestLine(name = "L28_29", number = -2147483647),
                     TestLine(name = "G1", category = 200)]
            path = write_test_gdb(joinpath(dir, "lines.gdb"); channels = [TestChannel(name = "Mag")], lines = lines,
                                  blob = (l, c) -> TestBlob(values = [1.0, 2.0]))
            s = new_session(joinpath(dir, "p"), "p")
            j = gdb_job(s, path)
            @test status(j) == JOB_DONE
            @test [line_name(l.id) for l in job_db(s, j).lines] == ["L10", "L11"]
            a = "line L28_29 has a name that is not a number; it was imported as L11"
            b = "group line G1 was skipped; JuliaMag has no group lines"
            @test count(==(a), job_warnings(j)) == 1 && count(==(b), job_warnings(j)) == 1
            @test count(a, report_text(j)) == 1 && count(b, report_text(j)) == 1
            close_session!(s)
        end
    end

    @testset "a damaged blob fails the job and leaves nothing" begin       # Review Focus 3
        mktempdir() do dir
            s = new_session(joinpath(dir, "p"), "p")
            path = survey_gdb(joinpath(dir, "bad.gdb"))
            # Change the last byte of the zlib stream of Mag on L20 (blob 1 * chans_max + 2).
            bytes = read(path)
            at = with_gdb(path) do g
                h = read_blob_header(g, something(blob_offset(g, g.header.chans_max + 2)))
                h.payload + h.packed_bytes - 16
            end
            bytes[at] ⊻= 0xff
            write(path, bytes)
            j = gdb_job(s, path)
            @test status(j) == JOB_FAILED
            @test startswith(j.error, "line L20, channel Mag: blob ")
            @test isempty(s.project.items) && isempty(importing_folders(s))
            # A live slot that misses its blob.
            path = survey_gdb(joinpath(dir, "misdirect.gdb"); misdirect = [4 + 1])
            j = gdb_job(s, path)
            @test status(j) == JOB_FAILED
            @test j.error == "line L20, channel Y: the directory entry of blob 5 does not point at its data"
            @test isempty(s.project.items) && isempty(importing_folders(s))
            close_session!(s)
        end
    end

    @testset "Windows-1252 text gives one warning" begin
        mktempdir() do dir
            chans = [TestChannel(name = "cafe", name_bytes = UInt8[0x63, 0x61, 0x66, 0xe9]),
                     TestChannel(name = "note", type = -4)]
            vals(c) = c == 0 ? [1.0, 2.0] : Any[UInt8[0x80, 0x41], "ok"]
            path = write_test_gdb(joinpath(dir, "cp.gdb"); channels = chans,
                                  lines = [TestLine(name = "L10", number = 10)], blob = (l, c) -> TestBlob(values = vals(c)))
            s = new_session(joinpath(dir, "p"), "p")
            j = gdb_job(s, path)
            @test status(j) == JOB_DONE
            db = job_db(s, j)
            @test [c.name for c in db.channels] == ["café", "note"]
            @test collect(read_channel(db, db.lines[1].id, "note")) == ["€A", "ok"]
            @test job_warnings(j) == ["some names or text values are not valid UTF-8; they were read as Windows-1252"]
            j = gdb_job(s, survey_gdb(joinpath(dir, "ascii.gdb")); crs = "EPSG:32755")
            @test status(j) == JOB_DONE && isempty(job_warnings(j))
            close_session!(s)
        end
    end

    @testset "cancel after the first blob leaves no trace" begin
        mktempdir() do dir
            s = new_session(joinpath(dir, "p"), "p")
            path = survey_gdb(joinpath(dir, "c.gdb"))
            @test_throws ImportCancelled import_gdb(s, path; progress = gdb_cancel_later())
            @test isempty(s.project.items) && isempty(importing_folders(s))
            # Progress goes from 0 to 1 over the 8 blobs.
            seen = Float64[]
            r = import_gdb(s, path; crs = "EPSG:32755", progress = Progress(f -> push!(seen, f), () -> false))
            @test r.rows == 40 && r.lines == 2 && isempty(r.warnings)
            @test first(seen) == 0.0 && last(seen) == 1.0 && issorted(seen) && length(seen) == 9
            close_session!(s)
        end
    end

    @testset "64-bit values that Float64 rounds" begin
        mktempdir() do dir
            chans = [TestChannel(name = "big", type = 8), TestChannel(name = "fine", type = 8)]
            vals(c) = c == 0 ? [2^60 + 1, 3] : [5, 2^60]
            path = write_test_gdb(joinpath(dir, "l64.gdb"); channels = chans,
                                  lines = [TestLine(name = "L10", number = 10)], blob = (l, c) -> TestBlob(values = vals(c)))
            s = new_session(joinpath(dir, "p"), "p")
            j = gdb_job(s, path)
            @test status(j) == JOB_DONE
            @test job_warnings(j) == ["channel big: 1 64-bit value cannot be stored exactly as Float64 and was rounded"]
            @test collect(read_channel(job_db(s, j), LineId(LINE, 10, 0), "fine")) == [5.0, 2.0^60]
            close_session!(s)
        end
    end

    @testset "append" begin                                                # Review Focus 5
        mktempdir() do dir
            s = new_session(joinpath(dir, "p"), "p")
            path = survey_gdb(joinpath(dir, "a.gdb"))
            j = gdb_job(s, path)
            id = only(j.outputs)
            j = gdb_job(s, path; mode = "append", target = id)
            @test status(j) == JOB_DONE
            db = database(s.project, id)
            @test [line_name(l.id) for l in db.lines] == ["L10", "L20", "L10.1", "L20.1"]
            @test db.rows_written == 80 && length(db.channels) == 4
            @test read_channel(db, LineId(LINE, 20, 1), "X") == read_channel(db, LineId(LINE, 20, 0), "X")
            @test eltype(read_channel(db, LineId(LINE, 10, 1), "FltNo")) === Int32

            # Names match the target's channels, ignoring case.
            t = add_test_database!(s, ["x" => [1.0, 2.0], "y" => [3.0, 4.0], "mag" => [5.0, 6.0]])
            f = survey_gdb(joinpath(dir, "f.gdb"); names = ("X", "Y", "Mag"), types = (5, 5, 5))
            j = gdb_job(s, f; mode = "append", target = t)
            @test status(j) == JOB_DONE
            db = database(s.project, t)
            @test [c.name for c in db.channels] == ["x", "y", "mag"]
            @test collect(read_channel(db, LineId(LINE, 20, 0), "mag")) == [50000 + r / 4 for r in 1:20]
            @test [(p.x, p.y) for p in db.pairs] == [("x", "y")] && db.current_pair == 1

            # A channel type that differs fails, and the target stays as it was.
            t = add_test_database!(s, ["FltNo" => [1.0, 2.0]])
            before = read(meta_path(database(s.project, t)))
            j = gdb_job(s, path; mode = "append", target = t)
            @test status(j) == JOB_FAILED && occursin("FltNo", j.error)
            @test read(meta_path(database(s.project, t))) == before
            close_session!(s)
        end
    end

    @testset "undo and redo of the import" begin
        mktempdir() do dir
            s = new_session(joinpath(dir, "p"), "p")
            j = gdb_job(s, survey_gdb(joinpath(dir, "u.gdb")))
            id = only(j.outputs)
            @test undo!(s)
            @test !any(i -> i.id == id, s.project.items)
            @test redo!(s)
            @test any(i -> i.id == id, s.project.items)
            close_session!(s)
        end
    end

    @testset "an ArcGIS folder and the registry" begin
        mktempdir() do dir
            s = new_session(joinpath(dir, "p"), "p")
            esri = joinpath(dir, "roads.gdb")
            mkpath(esri)
            write(joinpath(esri, "gdb"), "x")
            j = gdb_job(s, esri)
            @test status(j) == JOB_FAILED && occursin("ArcGIS file geodatabase", j.error)
            @test isempty(s.project.items)
            @test_throws GdbError import_gdb(s, esri)
            close_session!(s)
        end
        @test any(i -> i.id == "import.geosoft_gdb", importers())
        spec = importer_for("x.GDB")
        @test spec !== nothing && spec.id == "import.geosoft_gdb" && spec.name == "Geosoft database"
        @test [x.key for x in spec.settings] == ["mode", "name", "target", "crs"]
    end
end
