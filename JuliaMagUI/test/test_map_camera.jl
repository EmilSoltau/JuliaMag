using Test
import JuliaMagUI as UI
using JuliaMagUI: Camera, world_to_screen, screen_to_world, wheel_factor, zoom_at, pan_px, pan_to,
    fit_extent, union_extent, gl_transform, ExtentHistory, record_extent!, previous_extent!,
    next_extent!, nice_step, scale_bar, tick_values!, coord_text

@testset "map camera" begin
    c = Camera(500_000.0, 7_000_000.0, 10.0)
    @testset "view transform" begin
        @test world_to_screen(c, 800, 600, 500_000.0, 7_000_000.0) == (400.0, 300.0)
        @test world_to_screen(c, 800, 600, 500_010.0, 7_000_010.0) == (401.0, 299.0)
        @test all(isapprox.(screen_to_world(c, 800, 600, 401.0, 299.0), (500_010.0, 7_000_010.0)))
    end
    @testset "zoom and pan" begin
        z = zoom_at(c, wheel_factor(1), 0, 0, 800, 600)
        @test isapprox(z.res, 8.693582; rtol = 1e-6)
        @test all(isapprox.(screen_to_world(z, 800, 600, 0, 0), screen_to_world(c, 800, 600, 0, 0); atol = 1e-6))
        @test pan_px(c, 10, -20) == Camera(499_900.0, 6_999_800.0, 10.0)
        grab = screen_to_world(c, 800, 600, 100.0, 50.0)
        q = pan_to(c, grab, 300.0, 200.0, 1000, 700)
        @test q.res == c.res
        @test all(isapprox.(screen_to_world(q, 1000, 700, 300.0, 200.0), grab; atol = 1e-6))
    end
    @testset "res is clamped" begin
        @test Camera(0, 0, 1e-9).res == UI.MIN_RES
        @test Camera(0, 0, 1e12).res == UI.MAX_RES
        @test zoom_at(Camera(0, 0, UI.MIN_RES), 10.0, 5, 5, 800, 600).res == UI.MIN_RES
        @test fit_extent((5.0, 5.0, 5.0, 5.0), 800, 600).res == UI.MIN_RES
    end
    @testset "fit and union" begin
        f = fit_extent((0.0, 0.0, 1000.0, 500.0), 800, 600)
        @test f.res == 1.4 && (f.cx, f.cy) == (500.0, 250.0)
        p = fit_extent((5.0, 5.0, 5.0, 5.0), 800, 600); @test p.cx == 5.0 && isfinite(p.res) && p.res > 0
        e = (NaN, NaN, NaN, NaN)
        @test union_extent((0.0, 1.0, 2.0, 3.0), (1.0, -1.0, 5.0, 2.0)) == (0.0, -1.0, 5.0, 3.0)
        @test union_extent(e, (1.0, 2.0, 3.0, 4.0)) == (1.0, 2.0, 3.0, 4.0)
        @test union_extent((1.0, 2.0, 3.0, 4.0), e) == (1.0, 2.0, 3.0, 4.0)
        @test union_extent(e, e) === nothing
    end
    @testset "history" begin
        h = ExtentHistory(); a = Camera(0, 0, 1); b = Camera(1, 1, 1); now = Camera(2, 2, 1)
        record_extent!(h, a); record_extent!(h, b); record_extent!(h, b)
        @test length(h.past) == 2 && previous_extent!(h, now) == b && previous_extent!(h, b) == a
        @test previous_extent!(h, a) === nothing && next_extent!(h, a) == b
        @test (record_extent!(h, now); isempty(h.future))
        @test next_extent!(h, now) === nothing
        h2 = ExtentHistory()
        for i in 1:80
            record_extent!(h2, Camera(i, 0, 1))
        end
        @test length(h2.past) == 50 && h2.past[1] == Camera(31, 0, 1) && h2.past[end] == Camera(80, 0, 1)
    end
    @testset "scale bar and ticks" begin
        @test nice_step(1300.0) == 2000.0 && nice_step(0.034) == 0.05
        @test nice_step(1000.0) == 1000.0 && nice_step(0.0) == 1.0
        @test scale_bar(10.0, 130, "m") == (world = 1000.0, px = 100.0, label = "1 km")
        @test scale_bar(1.0, 600, "m").label == "500 m"
        @test scale_bar(100.0, 200, "m").label == "20 km"
        @test scale_bar(0.001, 60, "deg").label == "0.05 deg"
        @test scale_bar(1.0, 30, "").label == "20"
        out = Float64[]; @test tick_values!(out, 500_000.0, 508_000.0, 90, 10.0) == 1000.0 && length(out) == 9
        @test out[1] == 500_000.0 && out[end] == 508_000.0
        @test (@allocated tick_values!(out, 500_000.0, 508_000.0, 90, 10.0)) == 0
        @test coord_text(501_000.0, 1000.0) == "501,000" && coord_text(12.25, 0.05) == "12.25"
    end
    @testset "gl transform matches world_to_screen" begin
        origin = (512_000.0, 7_012_000.0)
        w, h = 1584, 955
        for (res, off) in ((1000.0, 200_000.0), (1.0, 100_000.0), (0.01, 1_000.0))
            cam = Camera(origin[1] + off, origin[2] + off, res)
            cx, cy, sx, sy = gl_transform(cam, origin, w, h)
            worst = 0.0
            for i in 0:999
                px = (i * 0.618033988749895 % 1) * w
                py = (i * 0.754877666246693 % 1) * h
                wx, wy = screen_to_world(cam, w, h, px, py)
                ox, oy = Float32(wx - origin[1]), Float32(wy - origin[2])
                nx, ny = (ox - cx) * sx, (oy - cy) * sy
                gx, gy = (Float64(nx) + 1) / 2 * w, (1 - Float64(ny)) / 2 * h
                rx, ry = world_to_screen(cam, w, h, wx, wy)
                worst = max(worst, abs(gx - rx), abs(gy - ry))
            end
            @test worst < 0.01
        end
    end
end
