@testset "display" begin
    @testset "colour tables" begin
        @test first.(colour_tables()) == ["geosoft", "viridis", "turbo", "rainbow", "blue-red", "grey"]
        @test GridStyle().colours == "geosoft"
        g = colour_table("geosoft")
        @test length(g) == 256 && g[1] == (0x00, 0x00, 0xa0) && g[129] == (62, 220, 59) && g[256] == (230, 0, 160)
        @test colour_table("viridis")[1] == (68, 1, 84) && colour_table("viridis")[256] == (253, 231, 37)
        @test colour_table("turbo")[1] == (48, 18, 59) && colour_table("turbo")[256] == (122, 4, 3)
        # Mid-table spot checks, so a typo inside a table shows: matplotlib's viridis(0.25) and
        # viridis(0.5) are #3b528b and #21918c; Google's turbo at 64 and 128 is #28bceb and #a4fc3c.
        @test colour_table("viridis")[65] == (0x3b, 0x52, 0x8b) && colour_table("viridis")[129] == (0x21, 0x91, 0x8c)
        @test colour_table("turbo")[65] == (0x28, 0xbc, 0xeb) && colour_table("turbo")[129] == (0xa4, 0xfc, 0x3c)
        @test colour_table("rainbow")[1] == (0, 0, 255) && colour_table("rainbow")[256] == (255, 0, 0)
        @test colour_table("grey")[256] == (255, 255, 255) && colour_table("blue-red")[129][3] > 0xf0
        for (name, _) in colour_tables()
            @test length(colour_table(name)) == 256
        end
        @test_throws ArgumentError colour_table("nope")
    end

    @testset "histogram and stretches" begin
        h = ValueHistogram(0.0, 100.0)
        add_values!(h, collect(0.01:0.01:100.0))
        add_values!(h, [NaN])
        @test h.total == 10_000 && length(h.counts) == 4096
        @test isapprox(quantile_value(h, 0.005), 0.5; atol = 0.05) && isapprox(quantile_value(h, 0.995), 99.5; atol = 0.05)
        lo, hi = stretch_range(LayerStyle(stretch = :clip), h)
        @test isapprox(lo, 0.5; atol = 0.05) && isapprox(hi, 99.5; atol = 0.05)
        @test stretch_range(LayerStyle(stretch = :linear), h) == (0.0, 100.0)
        @test stretch_range(LayerStyle(stretch = :linear, min = 10.0, max = 20.0), h) == (10.0, 20.0)
        @test stretch_range(LayerStyle(stretch = :histeq), h) == (0.0, 100.0)
        t = equalize_table(h)
        @test length(t) == 1024 && issorted(t) && t[end] == 1f0
        @test maximum(abs.(t .- range(0, 1; length = 1024))) < 0.01
        k = ValueHistogram(0.0, 100.0)
        add_values!(k, vcat(zeros(1000), fill(100.0, 10)))
        @test isapprox(equalize_table(k)[512], 1000 / 1010; atol = 0.002)
        @test isnan(quantile_value(ValueHistogram(0.0, 1.0), 0.5))
        @test isnan(ValueHistogram().lo)
        # Missing integers are skipped, a value at the top goes in the last bin.
        m = ValueHistogram(0.0, 10.0)
        add_values!(m, Int32[1, 5, 10, missing_value(Int32)])
        @test m.total == 3 && m.counts[end] == 1
        # Warm up, then check that nothing is allocated.
        reset!(h, 0.0, 1.0)
        t2 = Vector{Float32}(undef, 1024)
        equalize_table!(t2, k)
        @test (@allocated reset!(h, 0.0, 1.0)) == 0
        @test (@allocated equalize_table!(t2, k)) == 0
    end

    @testset "colour position" begin
        @test colour_position(50.0, 0.0, 100.0, nothing) == 0.5f0 && colour_position(150.0, 0.0, 100.0, nothing) == 1f0
        @test isnan(colour_position(NaN, 0.0, 1.0, nothing)) && colour_position(3.0, 3.0, 3.0, nothing) == 0.5f0
        @test colour_position(1.0, NaN, 3.0, nothing) == 0.5f0
        tab = Float32[0, 0.5, 1]
        @test colour_position(0.25, 0.0, 1.0, tab) == 0.25f0 && colour_position(1.0, 0.0, 1.0, tab) == 1f0
        tab2 = Float32[0, 0.9, 1]
        @test isapprox(colour_position(0.25, 0.0, 1.0, tab2), 0.45f0)
        # Limits that are not finite give the middle, with a table too; a value past them is clamped.
        for t in (nothing, tab)
            @test colour_position(1.0, -Inf, Inf, t) == 0.5f0 && colour_position(1.0, 0.0, Inf, t) == 0.5f0
            @test colour_position(1.0, NaN, 3.0, t) == 0.5f0
            @test colour_position(Inf, 0.0, 1.0, t) == 1f0 && colour_position(-Inf, 0.0, 1.0, t) == 0f0
        end
        # A table of one entry is that entry; an empty one is a linear stretch.
        @test colour_position(0.3, 0.0, 1.0, Float32[0.7]) == 0.7f0
        @test colour_position(0.3, 0.0, 1.0, Float32[]) == 0.3f0
    end

    @testset "effective style" begin
        ly = MapLayer("layer-1", "grid-1", :grid, "", true, 1.0, false, false, LayerStyle())
        gs = GridStyle("viridis", :linear, 1.0, 9.0, true, true, 300.0, 30.0, 2.0)
        e = effective_style(ly, gs, "geosoft")
        @test (e.colours, e.stretch, e.min, e.max, e.reverse) == ("viridis", :linear, 1.0, 9.0, true)
        # The shading is the layer's own: a grid layer that follows its grid's colours keeps it.
        @test !e.shade && e.inclination == 45.0 && e.declination == 45.0 && isnan(e.zfactor)
        lit = MapLayer("layer-4", "grid-1", :grid, "", true, 1.0, false, false,
                       LayerStyle(colours = "grey", shade = true, inclination = 30.0, declination = 300.0, zfactor = 2.0))
        e3 = effective_style(lit, gs, "geosoft")
        @test (e3.colours, e3.shade, e3.inclination, e3.declination, e3.zfactor) == ("viridis", true, 30.0, 300.0, 2.0)
        @test effective_style(lit, GridStyle(), "turbo").colours == "turbo"   # the app's colours still reach it
        e2 = effective_style(ly, GridStyle(), "turbo")
        @test e2.colours == "turbo" && e2.stretch == :histeq && isnan(e2.zfactor)
        @test effective_style(ly, nothing, "turbo") === ly.style
        own = MapLayer("layer-2", "grid-1", :grid, "", true, 1.0, false, true, LayerStyle(colours = "grey"))
        @test effective_style(own, GridStyle(), "turbo") === own.style
        nearest = MapLayer("layer-3", "grid-1", :grid, "", true, 1.0, false, false, LayerStyle(resample = :nearest))
        @test effective_style(nearest, GridStyle(), "turbo").resample == :nearest
    end

    @testset "relief" begin
        @test auto_zfactor(4.0) == 0.625 && auto_zfactor(0.0) == 1.0 && auto_zfactor(NaN) == 1.0
        @test all(isapprox.(sun_vector(45, 45), (0.5, 0.5, sqrt(0.5)); atol = 1e-12))
    end
end
