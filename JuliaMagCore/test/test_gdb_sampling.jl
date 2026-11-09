using Test, JuliaMagCore
using JuliaMagCore: Sampling, same_sampling, main_sampling, resample!

"`resample!` into a new vector of `rows * width` values."
function resampled(src::Vector{T}, from, to, rows; width = 1) where {T}
    out = Vector{T}(undef, rows * width)
    @test resample!(out, src, from, to, rows, width) === out
    return out
end

@testset "gdb sampling" begin
    @testset "same sampling" begin
        @test same_sampling(Sampling(33727.0, 1.0), Sampling(33727.0 + 1e-9, 1.0))
        @test same_sampling(Sampling(0.0, 0.1), Sampling(0.0, 0.1 * (1 + 5e-10)))
        @test !same_sampling(Sampling(0.0, 0.1), Sampling(0.0, 0.1 * (1 + 5e-9)))
        @test same_sampling(Sampling(10.0, 0.1), Sampling(10.0 + 0.9e-7, 0.1))
        @test !same_sampling(Sampling(10.0, 0.1), Sampling(10.0 + 2e-7, 0.1))
        @test !same_sampling(Sampling(0.0, 1.0), Sampling(0.5, 1.0))
        @test same_sampling(Sampling(0.0, 1.0), Sampling(0.0, 1.0))
    end

    @testset "main sampling" begin
        s = [Sampling(0.0, 1.0), Sampling(0.5, 1.0), Sampling(0.0, 1.0), Sampling(0.5, 1.0)]
        @test main_sampling(s) == Sampling(0.0, 1.0)                       # tie: first in order
        @test main_sampling(reverse(s)) == Sampling(0.5, 1.0)
        @test main_sampling([Sampling(3.0, 0.1), Sampling(0.0, 1.0), Sampling(0.0, 1.0)]) == Sampling(0.0, 1.0)
        @test main_sampling([Sampling(3.0, 0.1)]) == Sampling(3.0, 0.1)
        # Nearly equal samplings count as one; the first of them is returned.
        @test main_sampling([Sampling(5.0, 2.0), Sampling(1.0, 1.0), Sampling(1.0 + 1e-9, 1.0)]) ==
              Sampling(1.0, 1.0)
        @test_throws ArgumentError main_sampling(Sampling[])
    end

    @testset "floats" begin
        out = Vector{Float64}(undef, 5)
        resample!(out, [10.0, 20.0, NaN, 40.0], Sampling(0.5, 1.0), Sampling(0.0, 1.0), 5, 1)
        @test isequal(out, [NaN, 15.0, NaN, NaN, NaN])                       # missing not crossed, out of range missing
        resample!(out, [1.0, 2.0, 3.0], Sampling(0.0, 2.0), Sampling(0.0, 1.0), 5, 1)
        @test out == [1.0, 1.5, 2.0, 2.5, 3.0]
        # An exact hit on a missing row stays missing; a hit within 1e-6 of a row takes it.
        @test isequal(resampled([1.0, NaN, 3.0], Sampling(0.0, 1.0), Sampling(1.0, 1.0), 2), [NaN, 3.0])
        @test resampled([1.0, 2.0, 3.0], Sampling(0.0, 1.0), Sampling(2.0 + 1e-7, 1.0), 1) == [3.0]
        @test isequal(resampled([1.0, 2.0, 3.0], Sampling(0.0, 1.0), Sampling(2.0 + 1e-3, 1.0), 1), [NaN])
        @test resampled([1.0, 2.0, 3.0], Sampling(0.0, 1.0), Sampling(-1e-7, 1.0), 1) == [1.0]
        # A shorter step and an earlier start.
        @test isequal(resampled([0.0, 10.0], Sampling(1.0, 1.0), Sampling(0.0, 0.25), 9),
                      [NaN, NaN, NaN, NaN, 0.0, 2.5, 5.0, 7.5, 10.0])
        # Float32 interpolates and stays Float32.
        out32 = resampled(Float32[1, 2], Sampling(0.0, 1.0), Sampling(0.5, 1.0), 2)
        @test eltype(out32) === Float32 && isequal(out32, Float32[1.5, NaN])
        # Steps that are zero or not finite give missing values, not an error.
        @test all(isnan, resampled([1.0, 2.0], Sampling(0.0, 0.0), Sampling(0.0, 1.0), 3))
        @test all(isnan, resampled([1.0, 2.0], Sampling(0.0, Inf), Sampling(0.5, 1.0), 3))
        @test all(isnan, resampled([1.0, 2.0], Sampling(NaN, 1.0), Sampling(0.0, 1.0), 3))
        # A source position far outside the source.
        @test all(isnan, resampled([1.0, 2.0], Sampling(0.0, 1e-300), Sampling(1e300, 1.0), 2))
        # Nothing to read and nothing to write.
        @test all(isnan, resampled(Float64[], Sampling(0.0, 1.0), Sampling(0.0, 1.0), 2))
        @test isempty(resampled([1.0], Sampling(0.0, 1.0), Sampling(0.0, 1.0), 0))
    end

    @testset "integers" begin
        @test resampled(Int32[0, 3], Sampling(0.0, 2.0), Sampling(0.0, 1.0), 3) == Int32[0, 2, 3]
        @test resampled(Int32[0, 5], Sampling(0.0, 2.0), Sampling(0.0, 1.0), 3) == Int32[0, 3, 5]  # 2.5 -> 3
        @test resampled(Int32[0, -5], Sampling(0.0, 2.0), Sampling(0.0, 1.0), 3) == Int32[0, -3, -5]
        # A neighbour at the missing marker gives missing.
        @test resampled(Int16[1, typemin(Int16), 5], Sampling(0.0, 1.0), Sampling(0.5, 1.0), 2) ==
              Int16[typemin(Int16), typemin(Int16)]
        @test resampled(UInt8[1, 255, 5], Sampling(0.0, 1.0), Sampling(0.5, 1.0), 2) == UInt8[255, 255]
        @test resampled(UInt8[1, 4], Sampling(0.0, 1.0), Sampling(0.0, 0.5), 4) == UInt8[1, 3, 4, 255]
        # A result is never the missing marker: it is clamped to the type's range without it.
        @test resampled(Int8[-127, -127], Sampling(0.0, 1.0), Sampling(0.5, 1.0), 1) == Int8[-127]
        @test resampled(Int64[typemin(Int64) + 1, typemin(Int64) + 3], Sampling(0.0, 1.0), Sampling(0.5, 1.0),
                        1) == [typemin(Int64) + 1]
        @test resampled(Int64[typemax(Int64) - 2, typemax(Int64)], Sampling(0.0, 1.0), Sampling(0.5, 1.0), 1) ==
              [typemax(Int64)]
        @test resampled(UInt8[254, 254], Sampling(0.0, 1.0), Sampling(0.5, 1.0), 1) == UInt8[254]
    end

    @testset "text" begin
        src = ["a", "b", "c"]
        @test resampled(src, Sampling(0.0, 1.0), Sampling(0.0, 0.25), 9) ==
              ["a", "a", "a", "b", "b", "b", "b", "c", "c"]          # the earlier row at 0.5
        @test resampled(src, Sampling(0.0, 1.0), Sampling(0.6, 1.0), 3) == ["b", "c", ""]
        @test resampled(["a", "", "c"], Sampling(0.0, 1.0), Sampling(0.25, 1.0), 2) == ["", ""]
    end

    @testset "arrays" begin
        # Two values per row, rows stored one after the other: (1, 10), (3, 30), (NaN, 50).
        src = [1.0, 10.0, 3.0, 30.0, NaN, 50.0]
        out = resampled(src, Sampling(0.0, 1.0), Sampling(0.5, 1.0), 3; width = 2)
        @test isequal(out, [2.0, 20.0, NaN, 40.0, NaN, NaN])
        out = resampled(Int16[0, 10, 4, 20], Sampling(0.0, 2.0), Sampling(0.0, 1.0), 3; width = 2)
        @test out == Int16[0, 10, 2, 15, 4, 20]
    end

    @testset "argument checks" begin
        @test_throws ArgumentError resample!(zeros(4), [1.0, 2.0], Sampling(0.0, 1.0), Sampling(0.0, 1.0), 5, 1)
        @test_throws ArgumentError resample!(zeros(4), [1.0, 2.0, 3.0], Sampling(0.0, 1.0), Sampling(0.0, 1.0), 2, 2)
        @test_throws ArgumentError resample!(zeros(0), Float64[], Sampling(0.0, 1.0), Sampling(0.0, 1.0), 0, 0)
    end

    @testset "allocation" begin
        out, src = zeros(1000), collect(1.0:1000.0)
        resample!(out, src, Sampling(0.5, 1.0), Sampling(0.0, 1.0), 1000, 1)
        @test (@allocated resample!(out, src, Sampling(0.5, 1.0), Sampling(0.0, 1.0), 1000, 1)) == 0
    end
end
