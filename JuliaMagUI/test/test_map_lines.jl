using Test
import JuliaMagUI as UI
using JuliaMagUI: Camera, fit_extent, LineLayerData, build_line_layer!, choose_level, draw_list!,
    nearest_point, cursor_point, label_points!

@testset "map lines" begin
    @testset "levels keep spikes and choose by budget" begin
        pts = line_points([[(500_000.0 + 10i, 7_000_000.0, i == 5001 ? 1000.0 : sin(i / 50)) for i in 1:10_000]])
        d = build_line_layer!(LineLayerData(), pts)
        @test [l.bucket for l in d.levels] == [1, 8, 64, 512, 4096]
        @test d.levels[1].x === pts.x && d.levels[1].count === pts.part_count
        @test all(l -> maximum(l.v) == 1000f0, d.levels)
        @test all(l -> l.x[1] == pts.x[1] && l.x[end] == pts.x[end], d.levels)
        @test all(l -> issorted(l.x), d.levels)
        @test d.extent == (500_010.0, 7_000_000.0, 600_000.0, 7_000_000.0)
        @test d.hist.total == 10_000 && d.hist.hi == 1000.0
        cam = fit_extent(something(d.extent), 100, 100)
        @test choose_level(d, cam, 100, 100) == 2 && choose_level(d, cam, 1000, 1000) == 1
        @test choose_level(d, Camera(550_000.0, 7_000_000.0, 1e5), 2, 2) == length(d.levels)
    end

    @testset "a part with no values thins by its longer side" begin
        d = build_line_layer!(LineLayerData(), line_points([[(Float64(i), 0.0, NaN) for i in 1:1000]]))
        @test length(d.levels) >= 2 && d.levels[2].x[1] == d.points.x[1]
        @test issorted(d.levels[2].x) && length(d.levels[2].x) < 400
    end

    @testset "culling" begin
        two = build_line_layer!(LineLayerData(), line_points([[(0.0, 0.0, 1.0), (100.0, 0.0, 2.0)], [(0.0, 1000.0, 1.0), (100.0, 1000.0, 2.0)]]))
        f, k = Int32[], Int32[]
        @test draw_list!(f, k, two, 1, Camera(50.0, 0.0, 1.0), 200, 200) == 2 && f == Int32[0]
        @test (@allocated draw_list!(f, k, two, 1, Camera(50.0, 0.0, 1.0), 200, 200)) == 0
        # The view is 200 wide. A box 0.4 widths left is listed, 0.6 widths is not.
        @test draw_list!(f, k, two, 1, Camera(100.0 + 80.0 + 100.0, 0.0, 1.0), 200, 200) == 2
        @test draw_list!(f, k, two, 1, Camera(100.0 + 120.0 + 100.0, 0.0, 1.0), 200, 200) == 0 && isempty(f)
    end

    @testset "picking" begin
        two = build_line_layer!(LineLayerData(), line_points([[(0.0, 0.0, 1.0), (100.0, 0.0, 2.0)], [(0.0, 1000.0, 1.0), (100.0, 1000.0, 2.0)]]))
        np = nearest_point(two, 98.0, 999.0, 5.0)
        @test np.line == 2 && np.row == 2 && np.value == 2f0 && np.x == 100.0 && np.y == 1000.0
        @test isapprox(np.dist, sqrt(5))
        @test nearest_point(two, 50.0, 500.0, 5.0) === nothing
        @test cursor_point(two, 2, 2) == (100.0, 1000.0)
        @test cursor_point(two, 2, 3) === nothing && cursor_point(two, 3, 1) === nothing
        out = Tuple{Int,Float64,Float64}[]
        label_points!(out, two)
        @test out == [(1, 0.0, 0.0), (2, 0.0, 1000.0)]
        one = build_line_layer!(LineLayerData(), line_points([[(5.0, 7.0, 1.0)]]))
        @test nearest_point(one, 5.0, 7.0, 1.0).dist == 0.0
    end

    @testset "missing lines" begin
        s = fresh_session()
        id = survey_database!(s; nan_line = 2)
        pts = Core.read_line_points(Core.database(s.project, id), "X", "Y", "MAG")
        d = build_line_layer!(LineLayerData(), pts)
        @test d.extent == (500_000.0, 7_000_000.0, 500_040.0, 7_000_100.0)
        @test cursor_point(d, 2, 1) === nothing && cursor_point(d, 3, 1) == (500_000.0, 7_000_100.0)
        for y in 6_999_900.0:1.0:7_000_200.0, x in (500_000.0, 500_020.0, 500_040.0)
            np = nearest_point(d, x, y, 60.0)
            np === nothing || @test np.line != 2
        end
        out = Tuple{Int,Float64,Float64}[]
        label_points!(out, d)
        @test [o[1] for o in out] == [1, 3]
        Core.close_session!(s)

        s = fresh_session()
        id = survey_database!(s; lines = 1, nan_line = 1)
        pts = Core.read_line_points(Core.database(s.project, id), "X", "Y", "MAG")
        e = build_line_layer!(LineLayerData(), pts)
        @test e.extent === nothing && all(l -> isempty(l.x), e.levels) && e.hist.total == 0
        @test nearest_point(e, 0.0, 0.0, 1e9) === nothing
        Core.close_session!(s)
    end

    @testset "rebuild reuses arrays" begin
        mk() = line_points([[(500_000.0 + 10i, 7_000_000.0, sin(i / 50)) for i in 1:10_000]])
        d = LineLayerData()
        build_line_layer!(d, mk())
        pts = mk()
        build_line_layer!(d, pts)
        @test (@allocated build_line_layer!(d, pts)) < 1024
        @test d.version == 3
    end
end
