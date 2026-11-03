using Test
import JuliaMagUI as UI
import JuliaMagCore as Core
using JuliaMagUI: Camera, Scene, LineDraw, GridDraw, lut_rgba!, render_cpu!, scene_key, GridGeo, GridLayerData,
    build_grid_layer!, LineLayerData, build_line_layer!, grid_value

rgba(u::UInt32) = (u % UInt8, (u >> 8) % UInt8, (u >> 16) % UInt8, (u >> 24) % UInt8)

function grid_data(A; x0 = 0.5, y0 = 0.5, dx = 1.0, dy = dx, rotation = 0.0, tile = 2)
    geo = GridGeo(size(A, 1), size(A, 2), x0, y0, dx, dy, rotation)
    return build_grid_layer!(GridLayerData(), (buf, j1) -> (buf .= A[:, j1:j1+size(buf, 2)-1]; buf), geo; tile)
end

grey = lut_rgba!(zeros(UInt8, 1024), "grey", false)
black = (0x00, 0x00, 0x00, 0xff)
grid_draw(g; level = 0, lo = 1f0, hi = 12f0, table = nothing, opacity = 1f0, shade = false, sun = (0f0, 0f0, 1f0),
          zfactor = 1f0, nearest = true, lut = grey) =
    GridDraw(g, level, lut, lo, hi, table, opacity, shade, sun, zfactor, nearest)
line_draw(d; level = 1, lo = 0f0, hi = 1f0, table = nothing, plain = (0xff, 0x00, 0x00, 0xff), opacity = 1f0, lut = grey) =
    LineDraw(d, level, lut, lo, hi, table, plain, opacity)

@testset "map cpu" begin
    A = Float32[i + 4(j - 1) for i in 1:4, j in 1:3]  # 4 by 3 cells, row 3 at the top
    g = grid_data(A)
    sc = Scene(Camera(2.0, 1.5, 1.0), 4, 3, black, [grid_draw(g)], 0)
    img = zeros(UInt32, 4, 3)

    @testset "colour tables" begin
        @test length(grey) == 1024 && grey[1:4] == [0x00, 0x00, 0x00, 0xff] && grey[end-3:end] == [0xff, 0xff, 0xff, 0xff]
        rev = lut_rgba!(zeros(UInt8, 1024), "grey", true)
        @test rev[1:4] == [0xff, 0xff, 0xff, 0xff] && rev[end-3:end] == [0x00, 0x00, 0x00, 0xff]
        v = Core.colour_table("viridis")
        @test lut_rgba!(UInt8[], "viridis", false)[5:7] == collect(v[2])
    end

    @testset "grid pixels, blending and hillshade" begin
        render_cpu!(img, sc)
        @test rgba(img[1, 1]) == (0xb9, 0xb9, 0xb9, 0xff)   # cell (1, 3), value 9: round(8 / 11 * 255) = 185
        @test rgba(img[4, 3]) == (0x46, 0x46, 0x46, 0xff)   # cell (4, 1), value 4: round(3 / 11 * 255) = 70
        flat = grid_data(fill(5f0, 4, 3))
        sh = Scene(sc.camera, 4, 3, black, [grid_draw(flat; lo = 0f0, hi = 10f0, shade = true, sun = Float32.(Core.sun_vector(45, 45)))], 0)
        render_cpu!(img, sh)
        @test rgba(img[2, 2]) == (0x64, 0x64, 0x64, 0xff)   # 128 * (0.25 + 0.75 * 0.7071) = 99.9
        half = Scene(sc.camera, 4, 3, black, [grid_draw(g; opacity = 0.5f0)], 0)
        render_cpu!(img, half)
        @test rgba(img[1, 1])[1] == 0x5c                    # 185 * 0.5 = 92.5 rounds to 92
    end

    @testset "a slope is lit by the sun on its side" begin
        # Value rises to the east. Sun in the east: the slope faces west, so it is dark; sun in the west, bright.
        R = Float32[i for i in 1:6, j in 1:6]
        gr = grid_data(R)
        cam = Camera(3.0, 3.0, 1.0)
        east = Scene(cam, 6, 6, black, [grid_draw(gr; lo = 0f0, hi = 12f0, shade = true, sun = (0.7071f0, 0f0, 0.7071f0))], 0)
        west = Scene(cam, 6, 6, black, [grid_draw(gr; lo = 0f0, hi = 12f0, shade = true, sun = (-0.7071f0, 0f0, 0.7071f0))], 0)
        a = zeros(UInt32, 6, 6); b = zeros(UInt32, 6, 6)
        render_cpu!(a, east); render_cpu!(b, west)
        @test rgba(a[3, 3])[1] < rgba(b[3, 3])[1]
    end

    @testset "NaN cells show the background" begin
        B = copy(A); B[2, 2] = NaN32
        gb = grid_data(B)
        bg = (0x10, 0x20, 0x30, 0xff)
        for nearest in (true, false)
            s = Scene(sc.camera, 4, 3, bg, [grid_draw(gb; nearest)], 0)
            render_cpu!(img, s)
            @test rgba(img[2, 2]) == bg
        end
        # Bilinear is strict: a pixel between four cells, one NaN, is the background
        fine = Scene(Camera(2.0, 1.5, 0.5), 8, 6, bg, [grid_draw(gb; nearest = false)], 0)
        big = zeros(UInt32, 8, 6)
        render_cpu!(big, fine)
        @test rgba(big[3, 4]) == bg    
    end

    @testset "bilinear and nearest follow grid_value" begin
        n, m = 23, 17
        R = Float32[mod(sin(12.9898 * i + 78.233 * j) * 43758.5453, 1.0) for i in 1:n, j in 1:m]
        R[[3, 7, 50, 120, 300]] .= NaN32
        w, h = 40, 31
        for rot in (0.0, 30.0), nearest in (true, false)
            gr = grid_data(R; x0 = 10.0, y0 = 20.0, dx = 2.0, dy = 3.0, rotation = rot, tile = 4)
            cam = Camera(20.0, 30.0, 1.3)
            s = Scene(cam, w, h, (0x00, 0x00, 0x00, 0x00), [grid_draw(gr; lo = 0f0, hi = 1f0, nearest)], 0)
            im = zeros(UInt32, w, h)
            render_cpu!(im, s)
            bad = 0
            for py in 1:h, px in 1:w
                x, y = UI.screen_to_world(cam, w, h, px - 0.5, py - 0.5)
                v = grid_value(gr, x, y; nearest)
                want = isnan(v) ? 0x00 : UInt8(grey[4round(Int, Core.colour_position(v, 0f0, 1f0, nothing) * 255)+1])
                px_a = rgba(im[px, py])[4]
                bad += (isnan(v) ? px_a != 0x00 : (rgba(im[px, py])[1] != want || px_a != 0xff))
            end
            @test bad == 0
        end
    end

    @testset "coarse levels" begin
        P = Float32[i for i in 1:8, j in 1:8]
        gp = grid_data(P; tile = 4)
        s = Scene(Camera(4.5, 4.5, 2.0), 4, 4, black, [grid_draw(gp; level = 1, lo = 1f0, hi = 8f0)], 0)
        im = zeros(UInt32, 4, 4)
        render_cpu!(im, s)
        # Level 1 cells are 2 wide: values 1.5, 3.5, 5.5, 7.5
        @test [rgba(im[i, 2])[1] for i in 1:4] == [UInt8(round(Int, (v - 1) / 7 * 255)) for v in (1.5, 3.5, 5.5, 7.5)]
    end

    @testset "lines" begin
        d = build_line_layer!(LineLayerData(), line_points([[(0.0, 1.5, 1.0), (4.0, 1.5, 1.0)]]))
        cam = Camera(2.0, 1.5, 1.0)
        s = Scene(cam, 4, 3, black, [line_draw(d; lo = 0f0, hi = 2f0)], 0)
        render_cpu!(img, s)
        lit = [(x, y) for y in 1:3, x in 1:4 if img[x, y] != UInt32(0xff000000)]
        @test sort(lit) == [(x, 2) for x in 1:4]
        @test rgba(img[1, 2]) == (0x80, 0x80, 0x80, 0xff)
        # A point with no value is drawn in the plain colour
        dn = build_line_layer!(LineLayerData(), line_points([[(0.0, 1.5, NaN), (4.0, 1.5, NaN)]]))
        render_cpu!(img, Scene(cam, 4, 3, black, [line_draw(dn)], 0))
        @test rgba(img[3, 2]) == (0xff, 0x00, 0x00, 0xff)
        # Opacity
        render_cpu!(img, Scene(cam, 4, 3, black, [line_draw(dn; opacity = 0.5f0)], 0))
        @test rgba(img[3, 2]) == (0x80, 0x00, 0x00, 0xff)   # 127.5 rounds to 128 (even)
        # A line in the other direction, and one off the screen
        dv = build_line_layer!(LineLayerData(), line_points([[(2.5, 0.0, 1.0), (2.5, 3.0, 1.0)], [(1e9, 1e9, 1.0), (-1e9, 1e9, 1.0)]]))
        render_cpu!(img, Scene(cam, 4, 3, black, [line_draw(dv)], 0))
        @test count(!=(UInt32(0xff000000)), img) == 3 && all(img[3, :] .!= UInt32(0xff000000))
    end

    @testset "a value interpolates along a segment" begin
        d = build_line_layer!(LineLayerData(), line_points([[(0.0, 0.0, 0.0), (255.0, 0.0, 1.0)]]))
        cam = Camera(128.0, 0.0, 1.0)
        s = Scene(cam, 256, 1, black, [line_draw(d)], 0)
        im = zeros(UInt32, 256, 1)
        render_cpu!(im, s)
        @test all(k -> abs(Int(rgba(im[k, 1])[1]) - (k - 1)) <= 1, 1:255)
        # A shared vertex is drawn once: two segments with opacity 0.5 give one blend at the joint
        d2 = build_line_layer!(LineLayerData(), line_points([[(0.0, 1.5, 1.0), (2.5, 1.5, 1.0), (4.0, 1.5, 1.0)]]))
        render_cpu!(img, Scene(Camera(2.0, 1.5, 1.0), 4, 3, black, [line_draw(d2; opacity = 0.5f0, lo = 0f0, hi = 1f0)], 0))
        @test [rgba(img[x, 2])[1] for x in 1:4] == fill(0x80, 4)
    end

    @testset "layers without levels are skipped" begin
        empty_line = LineLayerData()
        empty_grid = GridLayerData()
        s = Scene(sc.camera, 4, 3, (0x01, 0x02, 0x03, 0xff), [line_draw(empty_line), grid_draw(empty_grid), grid_draw(g; level = 99)], 0)
        render_cpu!(img, s)
        @test all(==(0xff030201), img)
    end

    @testset "layers draw in order" begin
        d = build_line_layer!(LineLayerData(), line_points([[(0.0, 1.5, NaN), (4.0, 1.5, NaN)]]))
        s = Scene(sc.camera, 4, 3, black, [grid_draw(g), line_draw(d)], 0)
        render_cpu!(img, s)
        @test rgba(img[1, 2]) == (0xff, 0x00, 0x00, 0xff) && rgba(img[1, 1]) == (0xb9, 0xb9, 0xb9, 0xff)
        s2 = Scene(sc.camera, 4, 3, black, [line_draw(d), grid_draw(g)], 0)
        render_cpu!(img, s2)
        @test rgba(img[1, 2])[1] == rgba(img[1, 2])[2]
    end

    @testset "threads give equal images" begin
        n, m = 60, 45
        R = Float32[mod(sin(12.9898 * i + 78.233 * j) * 43758.5453, 1.0) for i in 1:n, j in 1:m]
        gr = grid_data(R; tile = 16)
        d = build_line_layer!(LineLayerData(), line_points([[(Float64(i), 20.0 + 10sin(i / 5), sin(i / 7)) for i in 1:50]]))
        s = Scene(Camera(30.0, 22.0, 0.2), 311, 203, black,
                  [grid_draw(gr; lo = 0f0, hi = 1f0, shade = true, sun = (0.5f0, 0.5f0, 0.7071f0), nearest = false, opacity = 0.9f0),
                   line_draw(d)], 0)
        a = zeros(UInt32, 311, 203); b = zeros(UInt32, 311, 203)
        render_cpu!(a, s; threads = 1)
        render_cpu!(b, s; threads = 4)
        @test a == b && any(!=(UInt32(0xff000000)), a)
    end

    @testset "no allocation" begin
        d = build_line_layer!(LineLayerData(), line_points([[(0.0, 1.5, 0.5), (4.0, 1.5, 0.2)]]))
        s = Scene(sc.camera, 4, 3, black, [grid_draw(g; shade = true, sun = (0.5f0, 0.5f0, 0.7071f0)), line_draw(d)], 0)
        render_cpu!(img, s; threads = 1)
        @test (@allocated render_cpu!(img, s; threads = 1)) == 0
        @test (@allocated scene_key(s)) == 0
        @test_throws ArgumentError render_cpu!(zeros(UInt32, 3, 3), s)
    end

    @testset "scene key" begin
        d = build_line_layer!(LineLayerData(), line_points([[(0.0, 1.5, 0.5), (4.0, 1.5, 0.2)]]))
        mk(; cam = Camera(2.0, 1.5, 1.0), w = 4, h = 3, bg = black, gl = nothing, ll = nothing) =
            Scene(cam, w, h, bg, [something(gl, grid_draw(g)), something(ll, line_draw(d))], 0)
        base = scene_key(mk())
        @test scene_key(mk()) == base
        @test scene_key(mk(cam = Camera(2.5, 1.5, 1.0))) != base
        @test scene_key(mk(cam = Camera(2.0, 1.6, 1.0))) != base
        @test scene_key(mk(cam = Camera(2.0, 1.5, 1.1))) != base
        @test scene_key(mk(w = 5)) != base && scene_key(mk(h = 4)) != base
        @test scene_key(mk(bg = (0x00, 0x00, 0x01, 0xff))) != base
        lut2 = copy(grey); lut2[10] ⊻= 0x01
        tab = collect(range(0f0, 1f0; length = 1024))
        for gl in (grid_draw(g; level = 1), grid_draw(g; lo = 2f0), grid_draw(g; hi = 13f0), grid_draw(g; opacity = 0.9f0),
                   grid_draw(g; lut = lut2), grid_draw(g; table = tab), grid_draw(g; shade = true), grid_draw(g; sun = (1f0, 0f0, 0f0)),
                   grid_draw(g; zfactor = 2f0), grid_draw(g; nearest = false))
            @test scene_key(mk(; gl)) != base
        end
        for ll in (line_draw(d; level = 2), line_draw(d; lo = 0.1f0), line_draw(d; hi = 2f0), line_draw(d; opacity = 0.9f0),
                   line_draw(d; lut = lut2), line_draw(d; table = tab), line_draw(d; plain = (0x00, 0x00, 0x00, 0xff)))
            @test scene_key(mk(; ll)) != base
        end
        # Same style values, new copies: equal keys
        @test scene_key(mk(gl = grid_draw(g; lut = copy(grey), table = nothing))) == base
        # A new build of the data changes the key
        build_line_layer!(d, d.points)
        @test scene_key(mk()) != base
        # The stored key does not count, and the layer order does
        @test scene_key(Scene(Camera(2.0, 1.5, 1.0), 4, 3, black, [grid_draw(g), line_draw(d)], 7)) == scene_key(mk())
        @test scene_key(Scene(Camera(2.0, 1.5, 1.0), 4, 3, black, [line_draw(d), grid_draw(g)], 0)) != scene_key(mk())
    end
end
