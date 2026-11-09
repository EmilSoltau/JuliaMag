using Test, JuliaMagCore
using JuliaMagCore: lzrw1_decode!

"Decode the whole of `z` into a fresh vector of `n` bytes."
lzrw1(z::Vector{UInt8}, n::Int) = (out = zeros(UInt8, n); lzrw1_decode!(out, 1, z, 1, length(z), n); out)

"The message of the `GdbError` that `f()` throws, or `nothing` when it throws none."
lzrw1_error(f) = try
    f()
    nothing
catch e
    e isa GdbError ? e.msg : rethrow()
end

@testset "LZRW1 decoder" begin
    @testset "round trip through the test compressor" begin
        for data in (UInt8[], UInt8[7], rand(UInt8, 1000), repeat(UInt8[1, 2, 3], 5000), zeros(UInt8, 16368))
            z = lzrw1_compress(data)
            out = Vector{UInt8}(undef, length(data))
            @test lzrw1_decode!(out, 1, z, 1, length(z), length(data)) == length(data) && out == data
        end
        # The compressor really uses copy items on repeated data.
        @test length(lzrw1_compress(zeros(UInt8, 16368))) < 16368 ÷ 4
    end

    @testset "an overlapping copy repeats the last bytes" begin
        # Control word 0b100: two literals, then a copy of offset 2, length 6.
        @test lzrw1(UInt8[0x04, 0x00, 'a', 'b', 0x05, 0x02], 8) == Vector{UInt8}("abababab")
    end

    @testset "a 12-bit offset and the longest copy" begin
        data = rand(UInt8, 4095)
        # 4095 literals take 256 groups; the copy is item 16 of the last group.
        z = UInt8[]
        for i in 1:4095
            (i - 1) % 16 == 0 && append!(z, i == 4081 ? UInt8[0x00, 0x80] : UInt8[0x00, 0x00])
            push!(z, data[i])
        end
        # offset 4095 = 0xFFF, length 16: b0 = 0xF0 | 15, b1 = 0xFF
        append!(z, UInt8[0xff, 0xff])
        @test lzrw1(z, 4095 + 16) == vcat(data, data[1:16])
    end

    @testset "17 literals need two control words" begin
        z = vcat(UInt8[0x00, 0x00], UInt8.(1:16), UInt8[0x00, 0x00], UInt8[17])
        @test lzrw1(z, 17) == UInt8.(1:17)
    end

    @testset "decoding stops mid-group when n bytes are out" begin
        # The group would hold 16 items; the stream has 3 and then unrelated bytes.
        z = UInt8[0x00, 0x00, 'x', 'y', 'z', 0xaa, 0xbb]
        @test lzrw1(z, 3) == Vector{UInt8}("xyz")
    end

    @testset "decodes a sub-range into the middle of a buffer" begin
        z = lzrw1_compress(repeat(Vector{UInt8}("geosoft"), 40))
        src = vcat(UInt8[0xde, 0xad], z, UInt8[0xbe, 0xef])
        out = fill(0x11, 300)
        @test lzrw1_decode!(out, 21, src, 3, 2 + length(z), 280) == 280
        @test out[21:300] == repeat(Vector{UInt8}("geosoft"), 40)
        @test all(==(0x11), out[1:20])
    end

    @testset "bad streams throw GdbError" begin
        # A copy with offset 0.
        @test occursin("offset 0", lzrw1_error(() -> lzrw1(UInt8[0x01, 0x00, 0x05, 0x00], 6)))
        # A copy of offset 2 when only one byte is out.
        @test occursin("before the start", lzrw1_error(() -> lzrw1(UInt8[0x02, 0x00, 'a', 0x01, 0x02], 3)))
        # A copy that would reach into the buffer before `o`.
        out = fill(0x11, 10)
        msg = lzrw1_error(() -> lzrw1_decode!(out, 5, UInt8[0x02, 0x00, 'a', 0x00, 0x02], 1, 5, 2))
        @test occursin("before the start", msg)
        @test out[1:4] == fill(0x11, 4)
        # A copy that would write past `n`.
        @test occursin("more than", lzrw1_error(() -> lzrw1(UInt8[0x04, 0x00, 'a', 'b', 0x05, 0x02], 4)))
        # The input ends before n bytes are out: at a control word, a literal, or inside a copy item.
        @test occursin("ends", lzrw1_error(() -> lzrw1(UInt8[0x00, 0x00, 'a'], 3)))
        @test occursin("ends", lzrw1_error(() -> lzrw1(UInt8[], 1)))
        @test occursin("ends", lzrw1_error(() -> lzrw1(UInt8[0x00], 1)))
        @test occursin("ends", lzrw1_error(() -> lzrw1(UInt8[0x02, 0x00, 'a', 0x00], 4)))
        # The range `a:b` is what bounds the input, not the vector.
        src = UInt8[0x00, 0x00, 'a', 'b', 'c']
        @test occursin("ends", lzrw1_error(() -> lzrw1_decode!(zeros(UInt8, 3), 1, src, 1, 4, 3)))
        # n = 0 reads nothing and returns 0.
        @test lzrw1_decode!(UInt8[], 1, UInt8[], 1, 0, 0) == 0
    end
end
