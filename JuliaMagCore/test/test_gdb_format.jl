using Test, JuliaMagCore
using JuliaMagCore: gdb_kind, gdb_refusal, open_gdb, with_gdb, read_gdb_header, GdbHeader

"The message of the `GdbError` that `f()` throws, or `nothing` when it throws none."
gdb_error(f) = try
    f()
    nothing
catch e
    e isa GdbError ? e.msg : rethrow()
end

"A small synthetic database with one channel and one line, in a fresh folder."
function one_channel_gdb(; kw...)
    path = joinpath(mktempdir(), "one.gdb")
    write_test_gdb(path; channels = [TestChannel(name = "Mag")], lines = [TestLine(name = "L10", number = 10)],
                   blob = (l, c) -> TestBlob(values = collect(1.0:10.0)), kw...)
end

"`tweak` that sets the int32 word at byte `off` to `v`."
set_word(off, v) = h -> (h[off + 1:off + 4] = reinterpret(UInt8, [htol(Int32(v))]); h)
word(h, off) = Int(ltoh(only(reinterpret(Int32, h[off + 1:off + 4]))))

@testset "gdb format: header and layout checks" begin
    @testset "afgrav" begin
        g = open_gdb(testdata("gdb/afgrav.gdb"))
        h = g.header
        @test h.page_size > 0 && (h.blob_start_page + h.n_pages) * h.page_size == filesize(g.path)
        @test h.comp_level == 1 && h.blob_table + h.blobs_max * 128 == h.line_table
        close(g)
        @test gdb_kind(testdata("gdb/afgrav.gdb")) == :geosoft
        @test gdb_refusal(testdata("gdb/afgrav.gdb")) === nothing
    end

    @testset "Esri folder" begin
        esri = mkpath(joinpath(mktempdir(), "roads.gdb"))
        @test gdb_kind(esri) == :esri_folder
        @test occursin("ArcGIS file geodatabase", gdb_refusal(esri))
        @test occursin("roads.gdb", gdb_refusal(esri))
        @test gdb_error(() -> open_gdb(esri)) == gdb_refusal(esri)
    end

    @testset "synthetic header fields" begin
        path = one_channel_gdb(chans_max = 6, lines_max = 5, blobs_max = 12, users_max = 3, cache = 7,
                               page_size = 512, comp_level = 2)
        raw = read(path)[1:256]
        with_gdb(path) do g
            h = g.header
            @test (h.chans_max, h.lines_max, h.blobs_max, h.users_max, h.cache) == (6, 5, 12, 3, 7)
            @test h.page_size == 512 && h.comp_level == 2
            @test h.first_admin == 30 && h.dir_slots == 30 + 12 + 3 + 7
            @test (h.line_handle0, h.chan_handle0, h.user_handle0) == (12, 17, 23)
            @test h.blob_table == 280 + h.dir_slots * 6
            @test h.line_table == h.blob_table + 12 * 128
            @test h.chan_table == h.line_table + 5 * 128
            @test h.user_table == h.chan_table + 6 * 128
            @test h.index_size == word(raw, 104) && h.blob_start_page == word(raw, 108)
            @test h.n_pages == word(raw, 112) && (h.blob_start_page + h.n_pages) * 512 == filesize(path)
            @test isempty(g.dir) && !g.cp1252
        end
    end

    @testset "bytes 4 to 7 are not checked" begin
        path = one_channel_gdb(tweak = h -> (h[5:8] .= 0xf0; h))
        @test with_gdb(g -> g.header.chans_max, path) == 4
    end

    @testset "layout checks name their rule" begin
        m = gdb_error(() -> open_gdb(one_channel_gdb(tweak = set_word(12, 265))))
        @test occursin("layout JuliaMag does not know", m) && occursin("version", m)
        @test occursin("It was not imported.", m)
        m = gdb_error(() -> open_gdb(one_channel_gdb(tweak = set_word(8, 0x10030000))))
        @test occursin("version", m)
        m = gdb_error(() -> open_gdb(one_channel_gdb(tweak = h -> set_word(48, word(h, 48) + 1)(h))))
        @test occursin("layout JuliaMag does not know", m) && occursin("first admin blob", m)
        m = gdb_error(() -> open_gdb(one_channel_gdb(tweak = h -> set_word(104, word(h, 104) - 128)(h))))
        @test occursin("layout JuliaMag does not know", m) && occursin("table", m)
        m = gdb_error(() -> open_gdb(one_channel_gdb(tweak = set_word(120, 3))))
        @test occursin("compression", m)
        m = gdb_error(() -> open_gdb(one_channel_gdb(tweak = set_word(24, 0))))
        @test occursin("capacit", m)
        path = one_channel_gdb()
        open(io -> truncate(io, filesize(path) - 1024), path, "r+")
        m = gdb_error(() -> open_gdb(path))
        @test occursin("layout JuliaMag does not know", m) && occursin("file size", m)
        short = joinpath(mktempdir(), "short.gdb")
        write(short, UInt8['!', 'C', 'B', 'D', 0, 0])
        @test gdb_kind(short) == :geosoft
        @test occursin("256", gdb_error(() -> open_gdb(short)))
    end

    @testset "a header check closes the file" begin
        path = one_channel_gdb(tweak = set_word(12, 265))
        holds(p) = any(f -> try readlink(joinpath("/proc/self/fd", f)) == p catch; false end,
                       readdir("/proc/self/fd"))
        @test gdb_error(() -> open_gdb(path)) !== nothing
        @test !Sys.islinux() || !holds(realpath(path))
    end

    @testset "not a Geosoft file" begin
        x = joinpath(mktempdir(), "x.gdb")
        bytes = rand(UInt8, 600)
        bytes[1:4] = UInt8[0x6a, 0x3f, 0x00, 0x11]
        write(x, bytes)
        @test gdb_kind(x) == :unknown
        m = gdb_refusal(x)
        @test occursin("6a 3f 00 11", m) && occursin("!CBD", m) && occursin("x.gdb", m)
        @test gdb_error(() -> open_gdb(x)) == m
        two = joinpath(mktempdir(), "two.gdb")
        write(two, UInt8[1, 2])
        @test gdb_kind(two) == :unknown
        @test occursin("fewer than 4 bytes", gdb_refusal(two))
        missing_path = joinpath(mktempdir(), "none.gdb")
        @test gdb_kind(missing_path) == :unknown
        @test gdb_refusal(missing_path) == "no file at $missing_path"
    end

    @testset "with_gdb closes on error" begin
        path = one_channel_gdb()
        stream = Ref{Any}(nothing)
        @test_throws ErrorException with_gdb(path) do g
            stream[] = g.io
            error("boom")
        end
        @test !isopen(stream[])
    end

    @testset "GdbError prints its message only" begin
        @test sprint(showerror, GdbError("plain words")) == "plain words"
    end

    @testset "xyz_column_names" begin
        names = xyz_column_names(testdata("gdb/afgrav.XYZ"))
        @test length(names) == 10 && names[1] == "longitude" && names[end] == "dod_rbs_no"
    end
end
