using Test, JuliaMagCore
using JuliaMagCore: open_gdb, with_gdb, blob_offset, read_blob_header, read_blob_bytes!, GdbBlobHeader

"The message of the `GdbError` that `f()` throws, or `nothing` when it throws none."
blob_error(f) = try
    f()
    nothing
catch e
    e isa GdbError ? e.msg : rethrow()
end

"A ramp of `n` Float64 values with a Geosoft dummy at every 997th row."
blob_ramp(n) = [k % 997 == 0 ? -1e32 : 0.25k for k in 1:n]

"A database with one Float64 channel on one line, its blob packed with `pack`."
function one_blob_gdb(values; pack = :none, fid_start = 12.5, fid_step = 0.1, kw...)
    path = joinpath(mktempdir(), "blob_$pack.gdb")
    write_test_gdb(path; channels = [TestChannel(name = "Mag")], lines = [TestLine(name = "L10", number = 10)],
                   blob = (l, c) -> TestBlob(values = values, fid_start = fid_start, fid_step = fid_step, pack = pack),
                   kw...)
end

"The byte offset of blob 0 in the file at `path`."
blob0(path) = with_gdb(g -> blob_offset(g, 0), path)

"Change the bytes of `path` from byte `off` (0-based) to `bytes`."
patch!(path, off, bytes) = (open(io -> (seek(io, off); write(io, bytes)), path, "r+"); path)
patch_i32!(path, off, v) = patch!(path, off, reinterpret(UInt8, [htol(Int32(v))]))
patch_f64!(path, off, v) = patch!(path, off, reinterpret(UInt8, [htol(Float64(v))]))

"The values of blob 0 of the file at `path`, read as Float64."
read_blob0(path) = with_gdb(path) do g
    h = read_blob_header(g, blob_offset(g, 0))
    copy(reinterpret(Float64, read_blob_bytes!(UInt8[], UInt8[], g, h, 8)))
end

"The header of blob 0 of the file at `path`."
header0(path) = with_gdb(g -> read_blob_header(g, blob_offset(g, 0)), path)

"The offsets and markers of the LZRW1 chunks of the packed blob at `off` in `path`."
function test_chunks(path, off)
    open(path) do io
        seek(io, off + 24)
        raw = Int(ltoh(read(io, Int32)))
        p, tot, out = off + 72, 0, Tuple{Int,UInt32}[]
        while tot < raw
            seek(io, p)
            r, l, m = Int(ltoh(read(io, Int32))), Int(ltoh(read(io, Int32))), ltoh(read(io, UInt32))
            push!(out, (p, m))
            tot += r
            p += l
        end
        out
    end
end

@testset "gdb blobs: plain, zlib and LZRW1" begin
    values = blob_ramp(5000)
    pack_of = Dict(:none => :none, :zlib => :zlib, :lzrw1 => :lzrw1, :lzrw1_stored => :lzrw1)

    @testset "round trip, $p" for p in (:none, :zlib, :lzrw1, :lzrw1_stored)
        with_gdb(one_blob_gdb(values; pack = p)) do g
            h = read_blob_header(g, blob_offset(g, 0))
            @test h isa GdbBlobHeader
            @test h.packing == pack_of[p] && h.count == 5000 && h.fid_start == 12.5 && h.fid_step == 0.1
            @test h.index == 0 && h.type == 5
            @test h.class == (p == :none ? 200 : 202)
            if p == :none
                @test h.raw_bytes == -1 && h.packed_bytes == -1
                @test h.payload == blob_offset(g, 0) + 48
            else
                @test h.raw_bytes == 40_000 && h.packed_bytes > 16
                @test h.payload == blob_offset(g, 0) + 72
            end
            @test reinterpret(Float64, read_blob_bytes!(UInt8[], UInt8[], g, h, 8)) == values
        end
    end

    @testset "a 40,000-value LZRW1 blob in 20 chunks" begin
        big = blob_ramp(40_000)
        for p in (:lzrw1, :lzrw1_stored)
            path = one_blob_gdb(big; pack = p)
            chunks = test_chunks(path, blob0(path))
            @test length(chunks) == 20
            @test all(c -> c[2] == (p == :lzrw1 ? 0xF4E5D6C7 : 0xF0E1D2C3), chunks)
            @test read_blob0(path) == big
        end
    end

    @testset "buffers are reused" begin
        path = one_blob_gdb(values; pack = :lzrw1)
        with_gdb(path) do g
            h = read_blob_header(g, blob_offset(g, 0))
            buf, scratch = UInt8[], UInt8[]
            a = read_blob_bytes!(buf, scratch, g, h, 8)
            @test a === buf && length(buf) == 40_000
            @test reinterpret(Float64, read_blob_bytes!(buf, scratch, g, h, 8)) == values
        end
    end

    @testset "afgrav" begin
        with_gdb(testdata("gdb/afgrav.gdb")) do g
            first = findfirst(i -> blob_offset(g, i) !== nothing, 0:g.header.first_admin - 1) - 1
            h = read_blob_header(g, blob_offset(g, first))
            @test h.packing == :lzrw1 && h.class == 202
            @test length(read_blob_bytes!(UInt8[], UInt8[], g, h, 8)) == h.raw_bytes == h.count * 8
            # Every live data blob unpacks to the size its header says.
            buf, scratch, n = UInt8[], UInt8[], 0
            for i in 0:g.header.first_admin - 1
                off = blob_offset(g, i)
                off === nothing && continue
                h = read_blob_header(g, off)
                @test h.index == i && h.packing == :lzrw1 && h.type == 5
                @test h.fid_start == 0.0 && h.fid_step == 1.0
                @test length(read_blob_bytes!(buf, scratch, g, h, 8)) == h.raw_bytes
                n += 1
            end
            @test n == 10
        end
    end

    @testset "a damaged zlib blob" begin
        path = one_blob_gdb(values; pack = :zlib)
        h = header0(path)
        # The last stream byte is part of the zlib checksum.
        patch!(path, h.payload + h.packed_bytes - 16 - 1, UInt8[0x5a])
        msg = blob_error(() -> read_blob0(path))
        @test occursin("blob 0", msg) && occursin("cannot be inflated", msg)
        path = one_blob_gdb(values; pack = :zlib)
        open(path, "r+") do io
            seek(io, h.payload + 200)
            b = read(io, UInt8)
            seek(io, h.payload + 200)
            write(io, b ⊻ 0xff)
        end
        @test occursin("blob 0", blob_error(() -> read_blob0(path)))
    end

    @testset "a cut zlib stream" begin
        path = one_blob_gdb(values; pack = :zlib)
        h = header0(path)
        patch_i32!(path, blob0(path) + 28, h.packed_bytes - 40)
        @test occursin("cannot be inflated", blob_error(() -> read_blob0(path)))
    end

    @testset "a zlib stream that gives more than its raw bytes" begin
        path = one_blob_gdb(values; pack = :zlib)
        off = blob0(path)
        patch_i32!(path, off + 24, 39_992)       # one value less, in raw bytes and count
        patch_i32!(path, off + 48, 4999)
        msg = blob_error(() -> read_blob0(path))
        @test occursin("blob 0 unpacks to more than", msg)
    end

    @testset "raw bytes must match the count" begin
        for p in (:zlib, :lzrw1)
            path = one_blob_gdb(values; pack = p)
            patch_i32!(path, blob0(path) + 48, 4999)
            @test blob_error(() -> read_blob0(path)) == "blob 0 unpacks to 40000 of 39992 bytes"
        end
    end

    @testset "LZRW1 chunk damage" begin
        path = one_blob_gdb(blob_ramp(40_000); pack = :lzrw1)
        (p, _) = test_chunks(path, blob0(path))[2]
        patch!(path, p + 8, reinterpret(UInt8, [htol(0x12345678)]))
        msg = blob_error(() -> read_blob0(path))
        @test occursin("blob 0", msg) && occursin("marker", msg) && occursin("12345678", msg)

        # A chunk that says it gives fewer bytes: the chunks end before the raw bytes are out.
        # The 3 chunks then give 0 + 16,368 + 7,264 bytes.
        path = one_blob_gdb(values; pack = :lzrw1)
        patch_i32!(path, blob0(path) + 72, 0)
        @test blob_error(() -> read_blob0(path)) == "blob 0 unpacks to 23632 of 40000 bytes"
        # A smaller raw length inside a packed chunk: a copy item passes the end.
        path = one_blob_gdb(values; pack = :lzrw1)
        patch_i32!(path, blob0(path) + 72, 1000)
        msg = blob_error(() -> read_blob0(path))
        @test startswith(msg, "blob 0: an LZRW1 stream in the file is damaged")

        # A chunk that says it gives more bytes than the blob holds.
        path = one_blob_gdb(blob_ramp(40_000); pack = :lzrw1)
        patch_i32!(path, blob0(path) + 72, 330_000)
        @test occursin("blob 0 unpacks to more than", blob_error(() -> read_blob0(path)))

        # A chunk length that runs past the stream.
        path = one_blob_gdb(values; pack = :lzrw1)
        patch_i32!(path, blob0(path) + 76, 10^6)
        msg = blob_error(() -> read_blob0(path))
        @test occursin("blob 0", msg) && occursin("runs past", msg)

        # A chunk length shorter than its own header.
        path = one_blob_gdb(values; pack = :lzrw1)
        patch_i32!(path, blob0(path) + 76, 4)
        @test occursin("blob 0", blob_error(() -> read_blob0(path)))

        # A stored chunk whose length does not match its raw length.
        path = one_blob_gdb(values; pack = :lzrw1_stored)
        patch_i32!(path, blob0(path) + 76, 12 + 30_000)
        @test occursin("blob 0", blob_error(() -> read_blob0(path)))

        # A damaged LZRW1 stream names the blob: a control word of all copies
        # makes the first item a copy with nothing before it.
        path = one_blob_gdb(values; pack = :lzrw1)
        patch!(path, blob0(path) + 72 + 12, UInt8[0xff, 0xff])
        msg = blob_error(() -> read_blob0(path))
        @test msg !== nothing && startswith(msg, "blob 0: an LZRW1 stream in the file is damaged")
    end

    @testset "header checks" begin
        # Class 200 with the chunk magic, and class 202 without it.
        path = one_blob_gdb(values; pack = :zlib)
        patch_i32!(path, blob0(path) + 20, 200)
        msg = blob_error(() -> header0(path))
        @test occursin("blob 0", msg) && occursin("200", msg)
        path = one_blob_gdb(values; pack = :none)
        patch_i32!(path, blob0(path) + 20, 202)
        msg = blob_error(() -> header0(path))
        @test occursin("blob 0", msg) && occursin("202", msg)
        # Another class.
        path = one_blob_gdb(values; pack = :none)
        patch_i32!(path, blob0(path) + 20, 100)
        @test occursin("blob 0", blob_error(() -> header0(path)))
        # Another subtype.
        path = one_blob_gdb(values; pack = :zlib)
        patch_i32!(path, blob0(path) + 64, 3)
        msg = blob_error(() -> header0(path))
        @test occursin("blob 0", msg) && occursin("3", msg)
        # A negative count, plain and packed.
        for (p, at) in ((:none, 40), (:zlib, 48))
            path = one_blob_gdb(values; pack = p)
            patch_i32!(path, blob0(path) + at, -1)
            @test occursin("blob 0", blob_error(() -> header0(path)))
        end
        # Negative raw bytes, and a packed length below 16.
        for (at, v) in ((24, -8), (28, 15))
            path = one_blob_gdb(values; pack = :zlib)
            patch_i32!(path, blob0(path) + at, v)
            @test occursin("blob 0", blob_error(() -> header0(path)))
        end
        # A packed stream that runs past the blob's pages.
        path = one_blob_gdb(values; pack = :zlib)
        patch_i32!(path, blob0(path) + 28, 10^6)
        msg = blob_error(() -> header0(path))
        @test occursin("blob 0", msg) && occursin("runs past", msg)
        # A fiducial step that is 0, negative, NaN or infinite.
        for p in (:none, :zlib), step in (0.0, -1.0, NaN, Inf)
            path = one_blob_gdb(values; pack = p)
            patch_f64!(path, blob0(path) + (p == :none ? 32 : 40), step)
            @test blob_error(() -> header0(path)) == "blob 0 has a fiducial step of $step"
        end
    end

    @testset "a packed blob may not claim more than its stream can give" begin
        path = one_blob_gdb(values; pack = :zlib)
        off = blob0(path)
        patch_i32!(path, off + 24, 10^9)
        patch_i32!(path, off + 28, 116)
        msg = blob_error(() -> header0(path))
        @test msg == "blob 0 claims 1000000000 bytes from 100 packed bytes"
        with_gdb(path) do g
            claim() = blob_error(() -> read_blob_header(g, off))
            claim()
            @test @allocated(claim()) < 1_000_000
        end
        # The zlib bound is 1032 times; LZRW1 allows 8 times.
        path = one_blob_gdb(values; pack = :zlib)
        patch_i32!(path, blob0(path) + 24, 1032 * 100)
        patch_i32!(path, blob0(path) + 28, 116)
        @test blob_error(() -> header0(path)) === nothing
        patch_i32!(path, blob0(path) + 24, 1032 * 100 + 1)
        @test occursin("claims", blob_error(() -> header0(path)))
        path = one_blob_gdb(values; pack = :lzrw1)
        patch_i32!(path, blob0(path) + 24, 800)
        patch_i32!(path, blob0(path) + 28, 116)
        @test blob_error(() -> header0(path)) === nothing
        patch_i32!(path, blob0(path) + 24, 801)
        @test blob_error(() -> header0(path)) == "blob 0 claims 801 bytes from 100 packed bytes"
    end

    @testset "a plain blob that runs past its pages" begin
        path = one_blob_gdb(values; pack = :none)
        patch_i32!(path, blob0(path) + 40, 5000 + 1000)
        msg = blob_error(() -> read_blob0(path))
        @test msg == "blob 0 runs past its pages"
    end

    @testset "a file cut inside the last blob" begin
        path = one_blob_gdb(values; pack = :lzrw1)
        open(io -> truncate(io, filesize(path) - 100), path, "r+")
        msg = blob_error(() -> open_gdb(path))
        @test occursin("layout JuliaMag does not know", msg) && occursin("file size", msg)
    end
end
