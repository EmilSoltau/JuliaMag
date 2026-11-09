using Test, JuliaMagCore
using JuliaMagCore: gdb_kind, gdb_refusal, open_gdb, with_gdb, read_gdb_header, GdbHeader
using JuliaMagCore: blob_offset, read_gdb_channels, read_gdb_lines, read_gdb_blob_symbols, gdb_text,
                    GdbChannelRecord, GdbLineRecord

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
            @test length(g.dir) == h.dir_slots && !g.cp1252
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

"""
The byte offsets of every copy of blob `index` in the chain of `path`, in chain order.
The chain walk is independent of the directory, so the tests can tell the copies apart.
"""
function chain_copies(path::AbstractString, index::Int)::Vector{Int}
    bytes = read(path)
    page_size, start = word(bytes, 100), word(bytes, 108)
    offs, off = Int[], start * page_size
    while off < length(bytes)
        @assert bytes[off + 1:off + 4] == UInt8[0xcc, 0xcc, 0x00, 0xff]
        word(bytes, off + 12) == index && push!(offs, off)
        off += word(bytes, off + 4) * page_size
    end
    return offs
end

"A database with 2 lines and 3 channels, each (line, channel) with its own blob."
function grid_gdb(; channels = [TestChannel(name = "X"), TestChannel(name = "Y"), TestChannel(name = "Mag")], kw...)
    path = joinpath(mktempdir(), "grid.gdb")
    write_test_gdb(path; channels, lines = [TestLine(name = "L10", number = 10), TestLine(name = "L20", number = 20)],
                   blob = (l, c) -> TestBlob(values = collect(1.0:10.0) .+ 100l .+ 10c), kw...)
end

@testset "gdb format: directory and symbol tables" begin
    @testset "afgrav" begin
        with_gdb(testdata("gdb/afgrav.gdb")) do g
            ch = read_gdb_channels(g)
            @test length(ch) == 10                            # 28 named records, 18 deleted (research 5.1)
            @test Set(lowercase(c.name) for c in ch) ==
                  Set(lowercase.(xyz_column_names(testdata("gdb/afgrav.XYZ"))))
            @test issorted([c.slot for c in ch])
            ln = read_gdb_lines(g)
            @test length(ln) == 1 && ln[1].name == "D0" && ln[1].type == 6
            @test !g.cp1252
            # Every live data slot lands on its blob.
            h = g.header
            for i in 0:h.first_admin - 1
                g.dir[i + 1].live || continue
                @test blob_offset(g, i) isa Int
            end
        end
    end

    @testset "directory slots" begin
        path = grid_gdb(chans_max = 4)
        with_gdb(path) do g
            h = g.header
            @test length(g.dir) == h.dir_slots
            @test g.dir[1] == JuliaMagCore.GdbSlot(true, 0, 1)
            @test g.dir[2] == JuliaMagCore.GdbSlot(true, 1, 1)
            @test !g.dir[4].live                              # channel slot 3 is unused
            @test g.dir[5] == JuliaMagCore.GdbSlot(true, 3, 1)  # line 1, channel 0
            @test blob_offset(g, 0) == h.blob_start_page * h.page_size
            @test blob_offset(g, 4) == (h.blob_start_page + 3) * h.page_size
            @test blob_offset(g, 3) === nothing
            @test blob_offset(g, 4) == only(chain_copies(path, 4))
        end
    end

    @testset "channel records" begin
        channels = [TestChannel(name = "X", type = 6, format = 4, width = 12, decimals = 6),
                    TestChannel(name = "old", deleted = true),
                    TestChannel(name = "Count", type = 3, width = 8, decimals = 0, flags = 0),
                    TestChannel(name = "Bad", type = 12),
                    TestChannel(name = "Flat", arraylen = 0),
                    TestChannel(name = "Spec", type = 4, arraylen = 40),
                    TestChannel(name = "Tag", type = -12)]
        path = joinpath(mktempdir(), "ch.gdb")
        write_test_gdb(path; channels, lines = [TestLine(name = "L1", number = 1)], garbage_channels = 5)
        with_gdb(path) do g
            ch = read_gdb_channels(g)
            # "Bad" has a type code JuliaMag does not know; it is kept here, so the
            # channel plan can skip it with a warning (spec 6.3a).
            @test [c.name for c in ch] == ["X", "Count", "Bad", "Spec", "Tag"]
            @test [c.slot for c in ch] == [0, 2, 3, 5, 6]
            @test ch[1] == GdbChannelRecord(0, "X", 6, 2, 4, 12, 6, 1)
            @test ch[2] == GdbChannelRecord(2, "Count", 3, 0, 0, 8, 0, 1)
            @test ch[3].type == 12
            @test ch[4].arraylen == 40 && ch[4].type == 4
            @test ch[5].type == -12
            @test g.header.chans_max >= 12               # the 5 garbage slots were written
            @test !g.cp1252
        end
    end

    @testset "line records" begin
        lines = [TestLine(name = "L10", number = 10, type = 0, date = 2023.1616, flight = 90, version = 2),
                 TestLine(name = "Grp", category = 200),
                 TestLine(name = "free", category = 65536),
                 TestLine(name = "junk", category = 130936),
                 TestLine(name = "T5", number = 5, type = 2)]
        path = joinpath(mktempdir(), "ln.gdb")
        write_test_gdb(path; channels = [TestChannel(name = "Mag")], lines)
        with_gdb(path) do g
            ln = read_gdb_lines(g)
            @test [l.name for l in ln] == ["L10", "Grp", "T5"]
            @test [l.slot for l in ln] == [0, 1, 4]
            @test ln[1] == GdbLineRecord(0, "L10", 100, 2023.1616, 10, 0, 90, 2)
            @test ln[2].category == 200
            @test ln[3].type == 2 && ln[3].number == 5
        end
    end

    @testset "blob symbols" begin
        path = one_channel_gdb(admin = ["__dbreg" => zeros(UInt8, 40), "Display List" => zeros(UInt8, 30)])
        with_gdb(path) do g
            @test read_gdb_blob_symbols(g) == [(0, "__dbreg"), (1, "Display List")]
            h = g.header
            @test blob_offset(g, h.first_admin + 1) == only(chain_copies(path, h.first_admin + 1))
            @test blob_offset(g, h.first_admin + 2) === nothing
        end
    end

    @testset "a stale copy is not used" begin
        path = grid_gdb(stale = [1])
        copies = chain_copies(path, 1)
        @test length(copies) == 2 && copies[1] < copies[2]
        @test read(path)[copies[1] + 49:copies[1] + 56] != read(path)[copies[2] + 49:copies[2] + 56]
        with_gdb(path) do g
            @test blob_offset(g, 1) == copies[1]
        end
    end

    @testset "a misdirected slot fails and names the blob" begin
        path = grid_gdb(misdirect = [2])
        with_gdb(path) do g
            m = gdb_error(() -> blob_offset(g, 2))
            @test m !== nothing && occursin("blob 2", m)
            @test blob_offset(g, 1) isa Int
        end
        # The last blob points past the end of the file: still a GdbError, not an EOFError.
        path = grid_gdb(misdirect = [6])
        with_gdb(path) do g
            m = gdb_error(() -> blob_offset(g, 6))
            @test m !== nothing && occursin("blob 6", m)
        end
    end

    @testset "a slot with too many pages fails" begin
        path = grid_gdb()
        bytes = read(path)
        bytes[280 + 6 * 6 + 5] = 0x09                     # blob 6, the last, claims 9 pages
        write(path, bytes)
        with_gdb(path) do g
            m = gdb_error(() -> blob_offset(g, 6))
            @test m !== nothing && occursin("blob 6", m)
        end
    end

    @testset "a dead slot has no data" begin
        path = grid_gdb(dead = [5])
        @test length(chain_copies(path, 5)) == 1
        with_gdb(path) do g
            @test !g.dir[6].live
            @test blob_offset(g, 5) === nothing
        end
    end

    @testset "gdb_text" begin
        @test gdb_text(UInt8['A', 'b', 0, 'z']) == ("Ab", false)
        @test gdb_text(Vector{UInt8}(codeunits("Mag€"))) == ("Mag€", false)
        @test gdb_text(UInt8['M', 'a', 'g', 0x80]) == ("Mag€", true)
        @test gdb_text(UInt8[0x93, 'x', 0x94, 0xe9]) == ("\u201cx\u201dé", true)
        @test gdb_text(UInt8[0x81, 0x9f]) == ("\u0081Ÿ", true)
        @test gdb_text(UInt8[]) == ("", false)
        @test gdb_text(zeros(UInt8, 4)) == ("", false)
    end

    @testset "Windows-1252 names" begin
        path = joinpath(mktempdir(), "cp.gdb")
        write_test_gdb(path; channels = [TestChannel(name = "x", name_bytes = UInt8['M', 'a', 'g', 0x80])],
                       lines = [TestLine(name = "L1", number = 1)])
        with_gdb(path) do g
            @test !g.cp1252
            @test only(read_gdb_channels(g)).name == "Mag€"
            @test g.cp1252
        end
        path = joinpath(mktempdir(), "cpl.gdb")
        write_test_gdb(path; channels = [TestChannel(name = "Mag")],
                       lines = [TestLine(name = "x", number = 1, name_bytes = UInt8['L', 0xe9])])
        with_gdb(path) do g
            @test only(read_gdb_lines(g)).name == "Lé"
            @test g.cp1252
        end
        path = one_channel_gdb(admin = ["x" => zeros(UInt8, 30)])
        bytes = read(path)
        h0 = word(bytes, 44) * 6 + 280                    # the blob-symbol table
        bytes[h0 + 1:h0 + 2] = UInt8['R', 0xe9]
        write(path, bytes)
        with_gdb(path) do g
            @test read_gdb_blob_symbols(g) == [(0, "Ré")]
            @test g.cp1252
        end
        with_gdb(one_channel_gdb()) do g
            read_gdb_channels(g); read_gdb_lines(g); read_gdb_blob_symbols(g)
            @test !g.cp1252
        end
    end
end
