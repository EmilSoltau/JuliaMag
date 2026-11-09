using Test, JuliaMagCore
using JuliaMagCore: GdbType, gdb_type, GdbValueNotes, gdb_values!

"The little-endian bytes of the values in `v`."
bytes_of(v::Vector) = Vector{UInt8}(reinterpret(UInt8, htol.(v)))

"Decode `raw` (values of the Geosoft type `code`) with fresh notes; return the values and the notes."
function decode(code, raw::Vector)
    t = gdb_type(code)
    n = GdbValueNotes(0, 0, 0)
    return gdb_values!(t.T[], bytes_of(raw), t, n), n
end

@testset "gdb values" begin
    @testset "the plan's cases" begin
        n = GdbValueNotes(0, 0, 0)
        @test gdb_values!(Int16[], bytes_of(Int16[-32767, 5, -32768]), gdb_type(2), n) == Int16[-32768, 5, -32768]
        @test n.clashes == 1
        @test isequal(gdb_values!(Float32[], bytes_of(Float32[-1f32, 2.5f0]), gdb_type(4), n), Float32[NaN, 2.5])
        @test gdb_values!(Int32[], bytes_of(UInt16[65535, 65534]), gdb_type(1), n) == Int32[typemin(Int32), 65534]
        @test gdb_values!(String[], Vector{UInt8}("2007/10/04\0ab\0\0\0\0\0\0\0\0\0"), gdb_type(-11), n) ==
              ["2007/10/04", "ab"]
        @test (n.clashes, n.inexact, n.cp1252) == (1, 0, 0)
    end

    @testset "the type table" begin
        # code, size, T, widened, lossy
        table = [(0, 1, Int8, false, false), (1, 2, Int32, true, false), (2, 2, Int16, false, false),
                 (3, 4, Int32, false, false), (4, 4, Float32, false, false), (5, 8, Float64, false, false),
                 (6, 1, UInt8, false, false), (7, 4, Float64, true, false), (8, 8, Float64, true, true),
                 (9, 8, Float64, true, true)]
        for (code, size, T, widened, lossy) in table
            @test gdb_type(code) == GdbType(code, size, T, widened, lossy)
        end
        @test gdb_type(-11) == GdbType(-11, 11, String, false, false)
        @test gdb_type(-1).size == 1
        for code in (10, 11, 255, typemax(Int32))
            e = try gdb_type(code); nothing catch x; x end
            @test e isa GdbError
            @test occursin("value type $code", e.msg)
        end
    end

    @testset "every row: its dummy and one real value" begin
        rows = [(0, Int8[-127, 7], Int8[typemin(Int8), 7]),
                (1, UInt16[65535, 40000], Int32[typemin(Int32), 40000]),
                (2, Int16[-32767, -32766], Int16[typemin(Int16), -32766]),
                (3, Int32[-2147483647, 123456], Int32[typemin(Int32), 123456]),
                (4, Float32[-1f32, -3.5f0], Float32[NaN, -3.5]),
                (5, Float64[-1e32, 1.25], Float64[NaN, 1.25]),
                (6, UInt8[255, 254], UInt8[255, 254]),
                (7, UInt32[4294967295, 4294967294], Float64[NaN, 4294967294]),
                (8, Int64[typemin(Int64), -5], Float64[NaN, -5]),
                (9, UInt64[typemax(UInt64), 5], Float64[NaN, 5])]
        for (code, raw, want) in rows
            got, n = decode(code, raw)
            @test eltype(got) == gdb_type(code).T
            @test isequal(got, want)
            @test (n.clashes, n.inexact, n.cp1252) == (0, 0, 0)
        end
        got, _ = decode(-4, UInt8[0, 0, 0, 0, 'a', 'b', 'c', 'd'])
        @test got == ["", "abcd"]
    end

    @testset "float dummies are any value at or below -1e31" begin
        got, n = decode(5, [-1e31, -1.0000001e31, -9.99e30, -Inf, 0.0, NaN])
        @test isequal(got, [NaN, NaN, -9.99e30, NaN, 0.0, NaN])
        @test n.clashes == 0
        got, _ = decode(4, Float32[-1f31, -9.9f30, floatmin(Float32)])
        @test isequal(got, Float32[NaN, -9.9f30, floatmin(Float32)])
    end

    @testset "clashes with JuliaMag's missing marker" begin
        got, n = decode(0, Int8[-128, -127, -128, 1])
        @test got == Int8[typemin(Int8), typemin(Int8), typemin(Int8), 1]
        @test n.clashes == 2
        got, n = decode(3, Int32[typemin(Int32), 0])
        @test got == Int32[typemin(Int32), 0]
        @test n.clashes == 1
        _, n = decode(6, UInt8[255, 255])
        @test n.clashes == 0
        _, n = decode(1, UInt16[0, 65534])
        @test n.clashes == 0
        # Notes add up across calls, as Task 9 keeps one per channel.
        t = gdb_type(2)
        n = GdbValueNotes(0, 0, 0)
        gdb_values!(Int16[], bytes_of(Int16[-32768]), t, n)
        gdb_values!(Int16[], bytes_of(Int16[-32768, -32768]), t, n)
        @test n.clashes == 3
    end

    @testset "widened 64-bit and 32-bit values" begin
        got, n = decode(7, UInt32[4294967294, 0])
        @test got == [4294967294.0, 0.0]
        @test n.inexact == 0
        _, n = decode(8, Int64[2^60 + 1])
        @test n.inexact == 1
        got, n = decode(8, Int64[2^60, 5, -(2^53)])
        @test got == [2.0^60, 5.0, -2.0^53]
        @test n.inexact == 0
        got, n = decode(8, [typemax(Int64)])
        @test got == [2.0^63]
        @test n.inexact == 1
        got, n = decode(8, [typemin(Int64) + 1])
        @test got == [-2.0^63]
        @test n.inexact == 1
        _, n = decode(9, [typemax(UInt64) - 1])
        @test n.inexact == 1
        _, n = decode(9, [UInt64(2)^63, UInt64(2)^53 + 1])
        @test n.inexact == 1
    end

    @testset "strings" begin
        n = GdbValueNotes(0, 0, 0)
        t = gdb_type(-3)
        @test gdb_values!(String[], UInt8[0x80, 0x31, 0x00, 'a', 'b', 'c'], t, n) == ["€1", "abc"]
        @test n.cp1252 == 1
        @test gdb_values!(String[], Vector{UInt8}("xyzab\0"), t, n) == ["xyz", "ab"]
        @test n.cp1252 == 1
        @test gdb_values!(String[], UInt8[0xc3, 0xa9, 0x00], t, n) == ["é"]
        @test n.cp1252 == 1
        @test gdb_values!(String[], UInt8[], t, n) == String[]
    end

    @testset "the output is resized and filled" begin
        t = gdb_type(5)
        n = GdbValueNotes(0, 0, 0)
        out = fill(9.0, 5)
        @test gdb_values!(out, bytes_of([1.0, 2.0]), t, n) === out
        @test out == [1.0, 2.0]
        @test gdb_values!(out, UInt8[], t, n) == Float64[]
        s = ["old", "old", "old"]
        @test gdb_values!(s, Vector{UInt8}("a\0"), gdb_type(-2), n) === s
        @test s == ["a"]
    end

    @testset "bytes that are not whole values" begin
        n = GdbValueNotes(0, 0, 0)
        @test_throws ArgumentError gdb_values!(Float64[], zeros(UInt8, 7), gdb_type(5), n)
        @test_throws ArgumentError gdb_values!(String[], zeros(UInt8, 5), gdb_type(-3), n)
        @test_throws ArgumentError gdb_values!(Float32[], zeros(UInt8, 8), gdb_type(5), n)
    end
end
