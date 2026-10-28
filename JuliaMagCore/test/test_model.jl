using JuliaMagCore

@testset "model" begin
    @test [line_letter(t) for t in instances(LineType)] == ['L','T','B','S','R','P','D']
    @test line_type('T') == TIE
    @test line_type('t') == TIE
    @test_throws ArgumentError line_type('X')
    @test line_name(LineId(LINE, 1001, 0)) == "L1001"
    @test line_name(LineId(TIE, 2001, 1)) == "T2001.1"
    @test LineId(LINE, 1, 0) == LineId(LINE, 1, 0)
    @test hash(LineId(LINE, 1, 0)) == hash(LineId(LINE, 1, 0))
    @test LineId(LINE, 1, 0) != LineId(LINE, 1, 1)
    @test isnan(missing_value(Float64)) && missing_value(Int32) == typemin(Int32)
    @test missing_value(String) == ""
    @test missing_value(UInt8) == typemax(UInt8)
    @test ismissingvalue(NaN32) && ismissingvalue(typemin(Int16)) && !ismissingvalue(0.0)
    @test ismissingvalue(NaN) && !ismissingvalue(0.0f0)
    @test ismissingvalue(typemax(UInt8)) && !ismissingvalue(UInt8(0))
    @test ismissingvalue("") && !ismissingvalue("a")
    @test !ismissingvalue(typemin(Int64) + 1)
    p = PositionPair("x", "y", "")
    @test p.crs == ""
    c = ChannelInfo("mag", "Mag", Float64, "nT", ROLE_NONE, :normal, 10, -1, false, 1)
    @test c.decimals == -1
end
