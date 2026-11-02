using JuliaMagCore

include("support/grids.jl")

@testset "grid storage" begin
    mktempdir() do tmp
        g = create_grid(joinpath(tmp, "my grid (1)"), "Mag", Float32, 3, 2; dx = 10.0, dy = 20.0, x0 = 100.0, y0 = 200.0)
        write_rows!(g, 1, Float32[1 4; 2 5; 3 6])      # row 1 = 1 2 3, row 2 = 4 5 6
        g2 = open_grid(g.folder)
        @test read_rows(g2, 2, 1) == reshape(Float32[4, 5, 6], 3, 1)
        # `read_rows!` fills a matrix the caller made, with as many rows as it has.
        buf = fill(NaN32, 3, 2)
        @test JuliaMagCore.read_rows!(buf, g2, 1) === buf && buf == Float32[1 4; 2 5; 3 6]
        @test_throws ArgumentError JuliaMagCore.read_rows!(Matrix{Float32}(undef, 3, 3), g2, 1)
        @test_throws ArgumentError JuliaMagCore.read_rows!(Matrix{Float32}(undef, 2, 1), g2, 1)
        @test_throws ArgumentError JuliaMagCore.read_rows!(Matrix{Float64}(undef, 3, 1), g2, 1)
        @test filesize(values_path(g2)) == 6 * sizeof(Float32)
        @test basename(values_path(g2)) == "values.f32"
        with_grid_values(A -> @test(A[3, 2] == 6f0), g2)
        @test cell_centre(g2, 1, 1) == (100.0, 200.0)
        @test grid_corners(g2)[1] == (95.0, 190.0)
        @test grid_corners(g2)[3] == (125.0, 230.0)
        @test block_rows(g2) == 16 * 1024 * 1024 ÷ (3 * 4)
        @test block_rows(create_grid(joinpath(tmp, "wide"), "W", Float64, 3_000_000, 1; dx = 1.0, dy = 1.0, x0 = 0.0, y0 = 0.0)) == 1

        r = create_grid(joinpath(tmp, "rot"), "R", Float64, 2, 2; dx = 10.0, dy = 10.0, x0 = 0.0, y0 = 0.0, rotation = 90.0)
        @test all(isapprox.(cell_centre(r, 2, 1), (0.0, 10.0); atol = 1e-9))
        @test basename(values_path(r)) == "values.f64"
    end

    @testset "writes through a map" begin
        mktempdir() do tmp
            g = small_grid(joinpath(tmp, "g"))
            with_grid_values(g; write = true) do A
                A[1, 1] = 42f0
            end
            @test read_rows(open_grid(g.folder), 1, 1)[1, 1] == 42f0
            @test_throws ErrorException with_grid_values(A -> error("boom"), g)
        end
    end

    @testset "metadata survives" begin
        mktempdir() do tmp
            g = small_grid(joinpath(tmp, "g"))
            g.style = GridStyle("grey", :linear, 1.0, 9.0, true, true, 10.0, 20.0, 2.0)
            g.source = GridSource("a.grd", "geosoft", "float32", "none")
            g.trend = [1.0, 2.0, 3.0]
            g.vmin = 1.0; g.vmax = 6.0; g.count = 6
            g.crs = "EPSG:32633"; g.units = "nT"
            save_grid_meta(g)
            h = open_grid(g.folder)
            @test h.style.colours == "grey" && h.style.method === :linear
            @test h.style.min == 1.0 && h.style.max == 9.0 && h.style.reverse && h.style.shade
            @test (h.style.azimuth, h.style.altitude, h.style.zfactor) == (10.0, 20.0, 2.0)
            @test h.source.file == "a.grd" && h.source.format == "geosoft"
            @test h.source.eltype == "float32" && h.source.compression == "none"
            @test h.trend == [1.0, 2.0, 3.0]
            @test (h.vmin, h.vmax, h.count) == (1.0, 6.0, 6)
            @test h.eltype === Float32 && h.crs == "EPSG:32633" && h.units == "nT"
            @test (h.nx, h.ny, h.dx, h.dy, h.x0, h.y0, h.rotation) == (3, 2, 10.0, 20.0, 100.0, 200.0, 0.0)
            d = GridStyle()
            @test d.colours == "rainbow" && d.method === :histeq && isnan(d.min) && isnan(d.max)
            @test !d.reverse && !d.shade
            @test (d.azimuth, d.altitude, d.zfactor) == (45.0, 45.0, 1.0)
            @test first(first(colour_tables())) == d.colours
            @test allunique(first.(colour_tables())) && "grey" in first.(colour_tables())
            @test all(p -> !isempty(last(p)), colour_tables())
            s = GridSource()
            @test (s.file, s.format, s.eltype, s.compression) == ("", "", "", "")
            f = open_grid(small_grid(joinpath(tmp, "n")).folder)
            @test isnan(f.style.min) && isnan(f.vmin) && f.count == 0
        end
    end

    @testset "broken grids" begin
        mktempdir() do tmp
            g = small_grid(joinpath(tmp, "g"))
            vp = values_path(g)
            open(vp, "r+") do io
                truncate(io, filesize(vp) - 1)
            end
            err = try open_grid(g.folder); nothing catch e e end
            @test err isa GridError && occursin("values.f32", err.msg)
            @test_throws GridError open_grid(joinpath(tmp, "none"))
            h = small_grid(joinpath(tmp, "h"))
            write(joinpath(h.folder, "grid.json"), "{ not json")
            @test_throws GridError open_grid(h.folder)
        end
    end

    @testset "project access" begin
        mktempdir() do tmp
            p = create_project(joinpath(tmp, "p"), "P")
            create_database(joinpath(p.folder, "databases", "d"), "d")
            add_item!(p, ProjectItem("db-1", ITEM_DATABASE, "d", "databases/d", "", ""))
            @test_throws ProjectError grid(p, "db-1")
            @test_throws ProjectError grid(p, "grid-9")
            add_item!(p, ProjectItem("grid-1", ITEM_GRID, "g", "grids/g", "", ""))
            @test_throws ProjectError grid(p, "grid-1")   # folder missing
            small_grid(joinpath(p.folder, "grids", "g"))
            @test grid(p, "grid-1") isa Grid
        end
    end
end
