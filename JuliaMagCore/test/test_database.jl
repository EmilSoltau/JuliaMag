using JuliaMagCore

chan(name, T; arraylen = 1) =
    ChannelInfo(name, name, T, "", ROLE_NONE, :normal, 10, -1, false, arraylen)
lineinfo(n, nrows) = LineInfo(LineId(LINE, n, 0), 1, "2024-05-01", 0.0, 0.1, nrows, 0, true)

@testset "database" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "kh"), "Kangaroo Hills")
        add_channel!(db, ChannelInfo("MAG", "MAG", Float64, "nT", ROLE_NONE, :normal, 10, 2, true, 1))
        add_line!(db, LineInfo(LineId(LINE,1001,0), 1, "2024-05-01", 0.0, 0.1, 3, 0, true))
        apps = open_appenders(db, ["MAG"])
        foreach(x -> append_value!(apps["MAG"], x), (1.0, NaN, 3.0))
        close_appenders!(apps); save_meta(db)
        db2 = open_database(joinpath(dir, "kh"))
        v = read_channel(db2, LineId(LINE,1001,0), "MAG")
        @test length(v) == 3 && v[1] == 1.0 && isnan(v[2])
        @test write_value!(db2, LineId(LINE,1001,0), "MAG", 3, 9.0) == 3.0
        @test read_channel(open_database(joinpath(dir, "kh")), LineId(LINE,1001,0), "MAG")[3] == 9.0
        @test_throws DatabaseError open_database(joinpath(dir, "nope"))
    end
end

@testset "database: channel added after lines" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_line!(db, lineinfo(1, 4))
        add_line!(db, lineinfo(2, 2))
        @test total_rows(db) == 6
        @test line(db, LineId(LINE, 2, 0)).offset == 4
        add_channel!(db, chan("ALT", Float32))
        add_channel!(db, chan("FLAG", Int16))
        add_channel!(db, chan("Q", UInt8))
        add_channel!(db, chan("NOTE", String))
        save_meta(db)
        db = open_database(joinpath(dir, "d"))
        for n in (1, 2)
            id = LineId(LINE, n, 0)
            @test all(isnan, read_channel(db, id, "ALT"))
            @test all(==(typemin(Int16)), read_channel(db, id, "FLAG"))
            @test all(==(typemax(UInt8)), read_channel(db, id, "Q"))
            @test read_channel(db, id, "NOTE") == fill("", line(db, id).nrows)
        end
        @test length(read_channel(db, LineId(LINE, 1, 0), "ALT")) == 4
        @test eltype(read_channel(db, LineId(LINE, 1, 0), "ALT")) == Float32
    end
end

@testset "database: appenders keep channels aligned" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_channel!(db, chan("MAG", Float64))
        add_channel!(db, chan("ALT", Float64))
        add_line!(db, lineinfo(1, 3))
        apps = open_appenders(db, ["MAG"])
        foreach(x -> append_value!(apps["MAG"], x), (1.0, 2.0, 3.0))
        close_appenders!(apps)
        # ALT had no appender, so it must be padded with missing values.
        @test all(isnan, read_channel(db, LineId(LINE, 1, 0), "ALT"))
        @test filesize(joinpath(dir, "d", "channels", "ALT.f64")) == 3 * 8

        # A second line, read before and after the files grow.
        @test collect(read_channel(db, LineId(LINE, 1, 0), "MAG")) == [1.0, 2.0, 3.0]
        add_line!(db, lineinfo(2, 2))
        apps = open_appenders(db, ["ALT"])
        append_value!(apps["ALT"], 7.0); append_value!(apps["ALT"], 8)
        close_appenders!(apps)
        save_meta(db)
        db = open_database(joinpath(dir, "d"))
        @test collect(read_channel(db, LineId(LINE, 2, 0), "ALT")) == [7.0, 8.0]
        @test all(isnan, read_channel(db, LineId(LINE, 2, 0), "MAG"))
        @test collect(read_channel(db, LineId(LINE, 1, 0), "MAG")) == [1.0, 2.0, 3.0]

        # More values than rows is an error.
        apps = open_appenders(db, ["MAG"])
        append_value!(apps["MAG"], 1.0)
        @test_throws DatabaseError close_appenders!(apps)
    end
end

@testset "database: large append crosses the buffer" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_channel!(db, chan("X", Float64))
        add_channel!(db, chan("N", Int32))
        n = 300_000          # more than one 1 MiB buffer of Float64
        add_line!(db, lineinfo(1, n))
        apps = open_appenders(db, ["X", "N"])
        for i in 1:n
            append_value!(apps["X"], i / 2)
            append_value!(apps["N"], i)
        end
        close_appenders!(apps)
        x = read_channel(db, LineId(LINE, 1, 0), "X")
        @test length(x) == n && x[1] == 0.5 && x[end] == n / 2
        @test read_channel(db, LineId(LINE, 1, 0), "N")[n] == n
    end
end

@testset "database: reads are memory-mapped views" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_channel!(db, chan("MAG", Float64))
        add_line!(db, lineinfo(1, 2))
        add_line!(db, lineinfo(2, 3))
        save_meta(db)
        v = read_channel(db, LineId(LINE, 2, 0), "MAG")
        @test v isa SubArray
        @test parent(v) === parent(read_channel(db, LineId(LINE, 1, 0), "MAG"))
        @test length(parent(v)) == 5
    end
end

@testset "database: writes return old values" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_channel!(db, chan("MAG", Float64))
        add_channel!(db, chan("FLAG", Int16))
        add_line!(db, lineinfo(1, 2))
        add_line!(db, lineinfo(2, 3))
        L2 = LineId(LINE, 2, 0)
        old = write_channel!(db, L2, "MAG", [1.0, 2.0, 3.0])
        @test all(isnan, old) && old isa Vector{Float64}
        old2 = write_channel!(db, L2, "MAG", [4.0, 5.0, 6.0])
        @test old2 == [1.0, 2.0, 3.0]            # a copy, not a view
        @test all(isnan, read_channel(db, LineId(LINE, 1, 0), "MAG"))
        @test_throws DatabaseError write_channel!(db, L2, "MAG", [1.0, 2.0])
        @test_throws DatabaseError write_value!(db, L2, "MAG", 4, 1.0)
        @test_throws DatabaseError write_value!(db, L2, "FLAG", 1, 1.5)
        @test write_value!(db, L2, "FLAG", 1, 7) == typemin(Int16)
        @test write_value!(db, L2, "FLAG", 1, NaN) == 7      # NaN means missing
        @test read_channel(db, L2, "FLAG")[1] == typemin(Int16)
        # Undo by writing the old value back.
        write_channel!(db, L2, "MAG", old2)
        @test collect(read_channel(db, L2, "MAG")) == [1.0, 2.0, 3.0]
        # Writes reach the file.
        save_meta(db)
        @test collect(read_channel(open_database(joinpath(dir, "d")), L2, "MAG")) == [1.0, 2.0, 3.0]
    end
end

@testset "database: array channels" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_channel!(db, chan("SPEC", Float32; arraylen = 3))
        add_line!(db, lineinfo(1, 1))
        add_line!(db, lineinfo(2, 2))
        apps = open_appenders(db, ["SPEC"])
        append_value!(apps["SPEC"], [1, 2, 3])
        append_value!(apps["SPEC"], [4, 5, 6])
        append_value!(apps["SPEC"], [7, 8, 9])
        close_appenders!(apps)
        save_meta(db)
        db = open_database(joinpath(dir, "d"))
        L2 = LineId(LINE, 2, 0)
        m = read_channel(db, L2, "SPEC")
        @test size(m) == (3, 2) && m[:, 1] == [4, 5, 6] && m[:, 2] == [7, 8, 9]
        @test write_value!(db, L2, "SPEC", 2, [0, 0, 1]) == Float32[7, 8, 9]
        @test read_channel(db, L2, "SPEC")[:, 2] == [0, 0, 1]
        old = write_channel!(db, L2, "SPEC", Float32[1 2; 1 2; 1 2])
        @test old == Float32[4 0; 5 0; 6 1]
        @test_throws DatabaseError write_channel!(db, L2, "SPEC", ones(Float32, 3, 3))
        @test_throws DatabaseError write_value!(db, L2, "SPEC", 1, [1, 2])
        @test read_channel(db, LineId(LINE, 1, 0), "SPEC")[:, 1] == [1, 2, 3]
    end
end

@testset "database: string channels" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_channel!(db, chan("NOTE", String))
        add_channel!(db, chan("MAG", Float64))
        add_line!(db, lineinfo(1, 2))
        add_line!(db, lineinfo(2, 3))
        apps = open_appenders(db, ["NOTE"])
        foreach(s -> append_value!(apps["NOTE"], s), ("a", "", "Åsa", "dd", "e"))
        close_appenders!(apps)
        L1, L2 = LineId(LINE, 1, 0), LineId(LINE, 2, 0)
        @test read_channel(db, L1, "NOTE") == ["a", ""]
        @test read_channel(db, L2, "NOTE") == ["Åsa", "dd", "e"]
        @test write_value!(db, L2, "NOTE", 2, "longer text") == "dd"
        @test write_value!(db, L1, "NOTE", 1, "b") == "a"
        @test write_channel!(db, L1, "NOTE", ["x", "yy"]) == ["b", ""]
        save_meta(db)
        db = open_database(joinpath(dir, "d"))
        @test read_channel(db, L1, "NOTE") == ["x", "yy"]
        @test read_channel(db, L2, "NOTE") == ["Åsa", "longer text", "e"]
    end
end

@testset "database: meta round trip" begin
    mktempdir() do dir
        folder = joinpath(dir, "Mag survey Å")
        db = create_database(folder, "KH")
        db.description = "test survey"
        db.made_by = "job-7"
        add_channel!(db, ChannelInfo("X", "Easting", Float64, "m", ROLE_X, :normal, 12, 2, true, 1))
        add_channel!(db, ChannelInfo("Y", "Northing", Float64, "m", ROLE_Y, :exponential, 12, -1, false, 1))
        add_channel!(db, chan("Q", UInt8))
        add_channel!(db, chan("I8", Int8))
        add_channel!(db, chan("I32", Int32))
        push!(db.pairs, PositionPair("X", "Y", "EPSG:7855"))
        db.current_pair = 1
        add_line!(db, LineInfo(LineId(TIE, 2001, 1), 3, "2024-05-02", 100.0, 0.2, 2, 0, false))
        save_meta(db)
        @test !isfile(joinpath(folder, "database.json.tmp"))
        d = open_database(folder)
        @test d.name == "KH" && d.description == "test survey" && d.made_by == "job-7"
        @test d.current_pair == 1 && d.pairs[1].crs == "EPSG:7855" && d.pairs[1].x == "X"
        c = channel(d, "Y")
        @test c.eltype == Float64 && c.role == ROLE_Y && c.format == :exponential
        @test c.decimals == -1 && c.label == "Northing" && !c.protected
        @test channel(d, "Q").eltype == UInt8 && channel(d, "I8").eltype == Int8
        @test channel(d, "I32").eltype == Int32
        l = line(d, LineId(TIE, 2001, 1))
        @test l.flight == 3 && l.date == "2024-05-02" && l.fid_start == 100.0
        @test l.fid_step == 0.2 && l.nrows == 2 && !l.selected
        @test occursin("\"Float64\"", read(joinpath(folder, "database.json"), String))
        @test_throws DatabaseError create_database(folder, "again")
    end
end

@testset "database: errors" begin
    mktempdir() do dir
        db = create_database(joinpath(dir, "d"), "d")
        add_channel!(db, chan("MAG", Float64))
        add_line!(db, lineinfo(1, 2))
        err(f) = try f(); nothing catch e; e end
        e = err(() -> read_channel(db, LineId(LINE, 1, 0), "NOPE"))
        @test e isa DatabaseError && occursin("NOPE", e.msg)
        e = err(() -> read_channel(db, LineId(LINE, 9, 0), "MAG"))
        @test e isa DatabaseError && occursin("L9", e.msg)
        @test_throws DatabaseError channel(db, "NOPE")
        @test_throws DatabaseError line(db, LineId(TIE, 1, 0))
        @test_throws DatabaseError add_channel!(db, chan("MAG", Float64))
        @test_throws DatabaseError add_channel!(db, chan("mag", Float64))   # same file on Windows
        @test_throws DatabaseError add_channel!(db, chan("A/B", Float64))
        @test_throws DatabaseError add_channel!(db, chan("CON", Float64))
        @test_throws DatabaseError add_channel!(db, chan("I64", Int64))
        @test_throws DatabaseError add_channel!(db, chan("S", String; arraylen = 2))
        @test_throws DatabaseError add_line!(db, lineinfo(1, 5))
        @test_throws DatabaseError open_appenders(db, ["NOPE"])

        # Broken meta files.
        f = joinpath(dir, "d", "database.json")
        write(f, "{ not json")
        e = err(() -> open_database(joinpath(dir, "d")))
        @test e isa DatabaseError && occursin("database.json", e.msg)
        save_meta(db)
        write(f, replace(read(f, String), "\"Float64\"" => "\"Base.Libc.FILE\""))
        e = err(() -> open_database(joinpath(dir, "d")))
        @test e isa DatabaseError && occursin("Base.Libc.FILE", e.msg)
    end
end
