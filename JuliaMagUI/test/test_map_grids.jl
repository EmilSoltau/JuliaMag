using Test
import JuliaMagUI as UI
import JuliaMagCore as Core
using JuliaMagUI: GridGeo, GridLayerData, build_grid_layer!, grid_level, level_cell, cell_value,
    grid_value, level_matrix

function band_reader(A)
    return (buf, j1) -> (buf .= A[:, j1:j1+size(buf, 2)-1]; buf)
end

# Fixed pseudo-random values in [0, 1), so the tests need no extra package.
noise(n, m, seed) = Float32[mod(sin(12.9898 * i + 78.233 * j + seed) * 43758.5453, 1.0) for i in 1:n, j in 1:m]

build(A, geo; tile) = build_grid_layer!(GridLayerData(), band_reader(A), geo; tile)

@testset "map grids" begin
    A = Float32[i + 10j for i in 1:5, j in 1:4]
    A[1, 1] = NaN32
    geo = GridGeo(5, 4, 100.0, 200.0, 10.0, 10.0, 0.0)
    d = build(A, geo; tile = 2)

    @testset "levels, tiles and counts" begin
        @test [(l.nx, l.ny) for l in d.levels] == [(5, 4), (3, 2), (2, 1), (1, 1)]
        @test isequal(level_matrix(d, 0), A)
        @test level_matrix(d, 1)[1, 1] == sum(Float32[A[2, 1], A[1, 2], A[2, 2]]) / 3
        @test isnan(d.levels[1].tiles[1, 1][2, 3]) && d.levels[1].tiles[1, 1][5, 3] == A[3, 1] && d.levels[1].tiles[1, 1][6, 3] == A[4, 1]
        @test d.count == 19 && d.hist.total == 19
        @test d.extent == (95.0, 195.0, 145.0, 235.0)
        @test d.version == 1
    end

    @testset "sampling" begin
        @test grid_value(d, 110.0, 200.0; nearest = true) == A[2, 1]
        @test grid_value(d, 115.0, 205.0; nearest = false) == sum(A[2:3, 1:2]) / 4
        @test isnan(grid_value(d, 105.0, 205.0; nearest = false))
        @test isnan(grid_value(d, 0.0, 0.0; nearest = true))
        # strict rule: a cell outside the grid counts as NaN, whatever its weight
        @test isnan(grid_value(d, 140.0, 230.0; nearest = false))
        @test isnan(grid_value(d, 110.0, 210.0; nearest = false)) == false
        B = copy(A); B[3, 2] = NaN32
        db = build(B, geo; tile = 2)
        @test isnan(grid_value(db, 110.0, 210.0; nearest = false))   # cell (2, 2) centre, NaN neighbour at weight 0
        @test grid_value(db, 110.0, 210.0; nearest = true) == B[2, 2]
        @test cell_value(d, 0, 3, 2) == A[3, 2] && isnan(cell_value(d, 0, 6, 1))
        @test grid_level(d, 10.0) == 0 && grid_level(d, 25.0) == 1 && grid_level(d, 1e6) == 3
        @test grid_level(d, 1.0) == 0
    end

    @testset "mean gradient" begin
        P = Float32[3 * 10 * (i - 1) for i in 1:50, j in 1:40]
        dp = build(P, GridGeo(50, 40, 0.0, 0.0, 10.0, 10.0, 0.0); tile = 16)
        @test isapprox(dp.mean_gradient, 3.0; rtol = 1e-6)
        @test !isnan(d.mean_gradient)
    end

    @testset "no seams between tiles" begin
        n = 37; m = 29
        R = noise(n, m, 7.0)
        R[noise(n, m, 8.0) .< 0.1f0] .= NaN32
        ds = build(R, GridGeo(n, m, 0.0, 0.0, 1.0, 1.0, 0.0); tile = 4)
        @test length(ds.levels) >= 4
        # Every value of a tile, its 2-cell border included, is the level's value there (NaN outside).
        for (k, l) in enumerate(ds.levels)
            M = level_matrix(ds, k - 1)
            at(ii, jj) = 1 <= ii <= l.nx && 1 <= jj <= l.ny ? M[ii, jj] : NaN32
            ok = true
            for tj in axes(l.tiles, 2), ti in axes(l.tiles, 1)
                t = l.tiles[ti, tj]
                ok &= size(t) == (min(4, l.nx - (ti - 1) * 4) + 4, min(4, l.ny - (tj - 1) * 4) + 4)
                for b in axes(t, 2), a in axes(t, 1)
                    ok &= isequal(t[a, b], at((ti - 1) * 4 + a - 2, (tj - 1) * 4 + b - 2))
                end
            end
            ok &= all(isequal(cell_value(ds, k - 1, i, j), M[i, j]) for i in 1:l.nx, j in 1:l.ny)
            @test ok
        end
        # a coarse cell is the NaN-aware mean of the 2 by 2 block below
        M0, M1 = level_matrix(ds, 0), level_matrix(ds, 1)
        blk = filter(!isnan, M0[5:6, 3:4])
        @test isempty(blk) ? isnan(M1[3, 2]) : M1[3, 2] ≈ sum(blk) / length(blk)
    end

    @testset "rotation" begin
        mktempdir() do dir
            g = Core.create_grid(joinpath(dir, "g"), "g", Float32, 6, 5; dx = 10.0, dy = 20.0, x0 = 1000.0,
                                 y0 = 2000.0, rotation = 30.0)
            dr = build(noise(6, 5, 2.0), GridGeo(g); tile = 4)
            @test dr.geo == GridGeo(6, 5, 1000.0, 2000.0, 10.0, 20.0, 30.0)
            for (i, j) in ((3, 2), (1, 1), (6, 5))
                x, y = Core.cell_centre(g, i, j)
                c = level_cell(dr, 0, x, y)
                @test isapprox(c[1], i; atol = 1e-9) && isapprox(c[2], j; atol = 1e-9)
            end
            @test level_cell(dr, 1, Core.cell_centre(g, 3, 2)...)[1] ≈ (3 - 0.5) / 2 + 0.5
            ext = dr.extent
            cs = Core.grid_corners(g)
            @test ext == (minimum(first, cs), minimum(last, cs), maximum(first, cs), maximum(last, cs))
        end
    end

    @testset "an all-NaN grid" begin
        N = fill(NaN32, 7, 5)
        dn = build(N, GridGeo(7, 5, 10.0, 20.0, 2.0, 2.0, 0.0); tile = 4)
        @test dn.count == 0 && dn.hist.total == 0
        @test isnan(dn.mean_gradient)
        @test isnan(grid_value(dn, 12.0, 22.0; nearest = true)) && isnan(grid_value(dn, 12.0, 22.0; nearest = false))
        @test dn.extent == (9.0, 19.0, 23.0, 29.0)
    end

    @testset "a tile holds only its cells and the border" begin
        # With the default TILE a 600 by 400 grid is one tile per level, each as small as its level.
        R = noise(600, 400, 3.0)
        dt = build_grid_layer!(GridLayerData(), band_reader(R), GridGeo(600, 400, 0.0, 0.0, 1.0, 1.0, 0.0))
        @test dt.tile == UI.TILE
        @test [size(only(l.tiles)) for l in dt.levels] == [(l.nx + 4, l.ny + 4) for l in dt.levels]
        @test size(only(dt.levels[end].tiles)) == (5, 5)
        # All levels together: the data, a third more for the coarse levels, and the borders. Bound: 1.4 times the data.
        bytes = sum(sizeof(t) for l in dt.levels for t in l.tiles)
        @test bytes < 1.4 * sizeof(R)
        @test isequal(level_matrix(dt, 0), R)
        # Edge tiles of a level with several tiles are cut to the level
        ds = build(noise(37, 29, 7.0), GridGeo(37, 29, 0.0, 0.0, 1.0, 1.0, 0.0); tile = 4)
        @test size(ds.levels[1].tiles) == (10, 8)
        @test size(ds.levels[1].tiles[1, 1]) == (8, 8) && size(ds.levels[1].tiles[10, 8]) == (5, 5)
    end

    @testset "rebuilding reuses the tiles" begin
        t = d.levels[1].tiles[1, 1]
        build_grid_layer!(d, band_reader(A), geo; tile = 2)
        @test d.levels[1].tiles[1, 1] === t && d.version == 2 && d.hist.total == 19
        # a second build of a larger grid into the same data allocates little (bound: 16 KB plus 10 KB per thread for the @threads tasks; measured 26 KB at 4 threads, 284 KB at 32. A band or tile is 79 KB or more)
        R = noise(300, 200, 1.0)
        dr = build(R, GridGeo(300, 200, 0.0, 0.0, 1.0, 1.0, 0.0); tile = 64)
        rd = (buf, j1) -> copyto!(buf, view(R, :, j1:j1+size(buf, 2)-1))   # does not allocate itself
        g = GridGeo(300, 200, 0.0, 0.0, 1.0, 1.0, 0.0)
        build_grid_layer!(dr, rd, g; tile = 64)
        # @allocated counts what finalizers allocate when a GC runs inside it. Collect first, so
        # garbage from earlier tests (sessions, files, images) is not finalized in the measurement.
        # @allocated reads process-wide counters, so another task's allocations can land in one
        # measurement; the least of three is the build's own.
        bytes = minimum(1:3) do _
            GC.gc()
            @allocated build_grid_layer!(dr, rd, g; tile = 64)
        end
        @test bytes < 16 * 1024 + 10 * 1024 * Threads.nthreads()
        @test isequal(level_matrix(dr, 0), R)
    end
end
