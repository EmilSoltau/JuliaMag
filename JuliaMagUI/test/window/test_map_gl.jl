using Test
import ModernGL as GL
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Camera, Scene, LineDraw, GridDraw, GlMap, GridGeo, GridLayerData, LineLayerData, build_grid_layer!,
    build_line_layer!, lut_rgba!, render_cpu!, choose_level, grid_level, probe_gl!, gl_draw!, queue_uploads!, upload_step!,
    free_layer!, free_all!, read_texture, UPLOAD_BYTES

# A GL pass for the tests: what Task 10's `gl_pass` does for the app frame. It runs inside
# `run_gl_pass`, the same `try ... finally` that `draw_frame!` uses.
struct TestPass
    f::Function
end
UI.gl_pass(p::TestPass, w::UI.Window) = p.f(w)

framebuffer_size(w) = UI.GLFW.GetFramebufferSize(w.handle)

# Run `f(w)` as the GL pass of the next frame, on the render thread.
function gl_run(f, ctx)
    ctx.on_render(w -> UI.run_gl_pass(TestPass(f), w, framebuffer_size(w)...))
    return nothing
end

gl_int(e) = (r = GL.GLint[0]; GL.glGetIntegerv(e, r); r[1])
gl_viewport() = (r = zeros(GL.GLint, 4); GL.glGetIntegerv(GL.GL_VIEWPORT, r); Tuple(r))

draw_allocated(r, sc) = @allocated gl_draw!(r, sc)

px_rgb(u::UInt32) = (Int(u % UInt8), Int((u >> 8) % UInt8), Int((u >> 16) % UInt8))

"""
    parity(cpu, gpu) -> (mean, outliers)

The mean absolute RGB error in 0-255 units, and the structural outliers: pixels at least
1 px from the edge that differ by more than 64 in a channel and whose colour is not
within 64 of any pixel within 1 px in the other image. Both images are checked.
"""
function parity(cpu::Matrix{UInt32}, gpu::Matrix{UInt32})
    w, h = size(cpu)
    total = 0
    close(a, b) = all(abs.(a .- b) .<= 64)
    outliers = 0
    for y in 1:h, x in 1:w
        a, b = px_rgb(cpu[x, y]), px_rgb(gpu[x, y])
        total += sum(abs.(a .- b))
        (close(a, b) || x == 1 || y == 1 || x == w || y == h) && continue
        for (p, other) in ((a, gpu), (b, cpu))
            any(close(p, px_rgb(other[x+i, y+j])) for i in -1:1, j in -1:1) || (outliers += 1)
        end
    end
    return total / (3w * h), outliers
end

function dump_png(path, img::Matrix{UInt32})
    w, h = size(img)
    out = Array{UInt8}(undef, h, w, 3)
    for y in 1:h, x in 1:w, c in 1:3
        out[y, x, c] = (img[x, y] >> (8 * (c - 1))) % UInt8
    end
    PNGFiles.save(path, out)
    return nothing
end

# `PARITY_DUMP=<dir>` writes `cpu.png`, `gpu.png` and `diff.png` (the difference times 4)
# of each case into `<dir>/<case>`.
function dump_parity(name, cpu, gpu)
    root = get(ENV, "PARITY_DUMP", "")
    isempty(root) && return nothing
    dir = mkpath(joinpath(root, name))
    dump_png(joinpath(dir, "cpu.png"), cpu)
    dump_png(joinpath(dir, "gpu.png"), gpu)
    diff = map(cpu, gpu) do a, b
        d = min.(4 .* abs.(px_rgb(a) .- px_rgb(b)), 255)
        UInt32(d[1]) | UInt32(d[2]) << 8 | UInt32(d[3]) << 16 | 0xff000000
    end
    dump_png(joinpath(dir, "diff.png"), diff)
    return nothing
end

# A 600 by 400 grid of 25 m cells at UTM-like coordinates: a plane and a sine pattern,
# with about 2 % NaN cells.
function parity_grid(; rotation = 0.0, tile = 128)
    nx, ny = 600, 400
    A = Float32[0.02i + 0.03j + 5sin(i / 23) * cos(j / 17) for i in 1:nx, j in 1:ny]
    for j in 1:ny, i in 1:nx
        mod(sin(12.9898i + 78.233j) * 43758.5453, 1.0) < 0.02 && (A[i, j] = NaN32)
    end
    geo = GridGeo(nx, ny, 500_000.0, 7_000_000.0, 25.0, 25.0, rotation)
    return build_grid_layer!(GridLayerData(), (buf, j1) -> (buf .= view(A, :, j1:j1+size(buf, 2)-1); buf), geo; tile)
end

# 50 lines across the grid, coloured by value.
function parity_lines()
    lines = [[(500_000.0 - 400 + 20s, 7_000_000.0 + 200k - 100 + 60sin(s / 37), sin(s / 50 + k))
              for s in 0:820] for k in 1:50]
    return build_line_layer!(LineLayerData(), line_points(lines))
end

const GEOSOFT = lut_rgba!(UInt8[], "geosoft", false)
const TURBO = lut_rgba!(UInt8[], "turbo", false)

function grid_layer(d::GridLayerData, cam, w, h; nearest, shade, level = grid_level(d, cam.res),
                    z = Float32(Core.auto_zfactor(d.mean_gradient)))
    table = Core.equalize_table(d.hist)
    sun = Float32.(Core.sun_vector(45, 45))
    return GridDraw(d, level, GEOSOFT, Float32(d.hist.lo), Float32(d.hist.hi), table, 1f0, shade, sun, z, nearest)
end

line_layer(d::LineLayerData, cam, w, h) =
    LineDraw(d, choose_level(d, cam, w, h), TURBO, -1f0, 1f0, nothing, (0x20, 0x20, 0x20, 0xff), 1f0)

parity_scene(cam, w, h, layers) = Scene(cam, w, h, (0x30, 0x34, 0x38, 0xff), layers, 0)

# Upload everything that is queued, one step per frame.
function upload_all!(ctx, r)
    while !isempty(r.pending)
        gl_run(w -> upload_step!(r), ctx)
    end
    return nothing
end

window_testset("map GL pass") do
    with_test_app(; timeout = 300) do ctx
        r = GlMap()
        problem = Ref("?")
        gl_run(w -> (problem[] = probe_gl!(r)), ctx)
        @test problem[] == ""

        grid = parity_grid()
        lines = parity_lines()
        queue_uploads!(r, "grid", grid)
        queue_uploads!(r, "lines", lines)
        upload_all!(ctx, r)

        # The middle of the grid, and a corner of four tiles of level 0 (cell edge 128.5).
        mid = (500_000.0 + 7500.0 + 13.7, 7_000_000.0 + 5000.0 - 9.1)
        corner = (500_000.0 + 127.5 * 25 + 3.1, 7_000_000.0 + 127.5 * 25 - 2.3)
        @testset "parity with the CPU renderer: $name" for (name, at, res, nearest, shade) in (
                ("bilinear-shade", mid, 52.0, false, true), ("nearest", mid, 52.0, true, false),
                ("level-2", mid, 104.0, false, true), ("bilinear-shade-3px", corner, 25 / 3, false, true),
                ("bilinear-shade-24px", corner, 25 / 24, false, true), ("nearest-shade-24px", corner, 25 / 24, true, true))
            w, h = 300, 200
            cam = Camera(at..., res)
            sc = parity_scene(cam, w, h, [grid_layer(grid, cam, w, h; nearest, shade), line_layer(lines, cam, w, h)])
            name == "level-2" && @test sc.layers[1].level == 2
            cpu = render_cpu!(zeros(UInt32, w, h), sc)
            gpu = Ref{Matrix{UInt32}}()
            gl_run(w -> (gl_draw!(r, sc); gpu[] = read_texture(r)), ctx)
            dump_parity(name, cpu, gpu[])
            err, outliers = parity(cpu, gpu[])
            @info "Map GL parity" name mean_error = err outliers
            @test err < 1.5
            @test outliers == 0
        end

        @testset "parity on a rotated grid" begin
            rot = parity_grid(; rotation = 30.0)
            queue_uploads!(r, "rotated", rot)
            upload_all!(ctx, r)
            w, h = 300, 200
            cam = Camera(500_000.0 + 3000.0, 7_000_000.0 + 7000.0, 61.0)
            sc = parity_scene(cam, w, h, [grid_layer(rot, cam, w, h; nearest = false, shade = true)])
            cpu = render_cpu!(zeros(UInt32, w, h), sc)
            gpu = Ref{Matrix{UInt32}}()
            gl_run(w -> (gl_draw!(r, sc); gpu[] = read_texture(r)), ctx)
            dump_parity("rotated", cpu, gpu[])
            err, outliers = parity(cpu, gpu[])
            @info "Map GL parity" name = "rotated" mean_error = err outliers
            @test err < 1.5
            @test outliers == 0
            gl_run(w -> free_layer!(r, "rotated"), ctx)
        end

        # The same grid in tiles of 128 cells and in one tile per level, at a corner of the tiles of level k.
        # A moderate vertical scale: with the automatic one some of these corners are all in shadow.
        whole = parity_grid(; tile = UI.TILE)
        queue_uploads!(r, "one tile", whole)
        upload_all!(ctx, r)
        @test length(grid.levels) == 11
        @testset "bilinear hillshade has no seams between tiles: level $k, $px px per cell" for k in 0:length(grid.levels)-1,
                                                                                            px in (3, 24)
            # Cell edge 128.5 of level k each way. A level with one tile that way (from level 3 on in
            # i, level 2 on in j) has no tile edge: its middle there, and the two builds must still agree.
            f = 2.0^k
            lv = grid.levels[k+1]
            ci, cj = lv.nx > 128 ? 128 : lv.nx ÷ 2, lv.ny > 128 ? 128 : lv.ny ÷ 2
            w, h = 300, 200
            cam = Camera(500_000.0 + (ci * f - 0.5) * 25 + 3.1, 7_000_000.0 + (cj * f - 0.5) * 25 - 2.3, 25f / px)
            imgs = map((grid, whole)) do d
                sc = parity_scene(cam, w, h, [grid_layer(d, cam, w, h; nearest = false, shade = true, level = k, z = 40f0)])
                out = Ref{Matrix{UInt32}}()
                gl_run(w -> (gl_draw!(r, sc); out[] = read_texture(r)), ctx)
                out[]
            end
            dump_parity("seam-$k-$px", imgs...)
            # The tile edges cross at (ex, ey) on the screen. Within half a cell of them (3 px at
            # least) the images agree: a 1-cell border gave a line of hundreds of pixels off by 5 to
            # 11 there. Anywhere, a lone pixel may take the next colour entry on rounding (3 at most,
            # measured), as the two quads place cells apart by a rounding.
            ex, ey = w / 2 - 3.1 / cam.res, h / 2 - 2.3 / cam.res
            band = max(3, px / 2)
            off = [maximum(abs.(px_rgb(imgs[1][x, y]) .- px_rgb(imgs[2][x, y]))) for x in 1:w, y in 1:h]
            edge = [abs(x - 0.5 - ex) <= band || abs(y - 0.5 - ey) <= band for x in 1:w, y in 1:h]
            worst = maximum(off[edge])
            @info "Map GL tile seams" level = k px_per_cell = px worst at_edges = count(>(1), off[edge]) flips = count(>(1), off)
            @test count(>(1), off[edge]) <= 5   # measured 2 at most; a seam gave 318 or more
            @test maximum(off) <= 4
        end
        gl_run(w -> free_layer!(r, "one tile"), ctx)

        @testset "the GL state is restored after the pass" begin
            w, h = 300, 200
            cam = Camera(500_000.0 + 7500.0, 7_000_000.0 + 5000.0, 52.0)
            sc = parity_scene(cam, w, h, [grid_layer(grid, cam, w, h; nearest = true, shade = false)])
            state = Ref{Any}(nothing)
            ctx.on_render(win -> begin
                fb = framebuffer_size(win)
                UI.run_gl_pass(TestPass(_ -> gl_draw!(r, sc)), win, fb...)
                state[] = (gl_int(GL.GL_FRAMEBUFFER_BINDING), gl_viewport(), (0, 0, fb...))
            end)
            @test state[][1] == 0 && state[][2] == state[][3]
            r.throw_in_draw = true
            thrown = Ref(false)
            ctx.on_render(win -> begin
                fb = framebuffer_size(win)
                try
                    UI.run_gl_pass(TestPass(_ -> gl_draw!(r, sc)), win, fb...)
                catch
                    thrown[] = true
                end
                state[] = (gl_int(GL.GL_FRAMEBUFFER_BINDING), gl_viewport(), (0, 0, fb...),
                           gl_int(GL.GL_CURRENT_PROGRAM), gl_int(GL.GL_VERTEX_ARRAY_BINDING),
                           gl_int(GL.GL_ACTIVE_TEXTURE), gl_int(GL.GL_TEXTURE_BINDING_2D), gl_int(GL.GL_ARRAY_BUFFER_BINDING))
            end)
            @test thrown[] && !r.throw_in_draw
            @test state[][1] == 0 && state[][2] == state[][3] && state[][4] == 0 && state[][5] == 0
            @test state[][6] == GL.GL_TEXTURE0 && state[][7] == 0 && state[][8] == 0
        end

        @testset "no allocation while drawing, and one texture id when the size changes" begin
            w, h = 300, 200
            cam = Camera(500_000.0 + 7500.0, 7_000_000.0 + 5000.0, 52.0)
            sc = parity_scene(cam, w, h, [grid_layer(grid, cam, w, h; nearest = false, shade = true), line_layer(lines, cam, w, h)])
            bytes = Ref(-1)
            tex = Ref(UInt32(0))
            gl_run(win -> begin
                for _ in 1:3
                    tex[] = gl_draw!(r, sc)
                end
                GC.gc()   # no finalizers of earlier garbage inside the measurement
                bytes[] = draw_allocated(r, sc)
            end, ctx)
            @test bytes[] == 0
            small = parity_scene(cam, 120, 90, sc.layers)
            got = Ref{Any}(nothing)
            gl_run(win -> (got[] = (gl_draw!(r, small), size(read_texture(r)))), ctx)
            @test got[] == (tex[], (120, 90))
        end

        @testset "a level not uploaded yet draws the finest level that is" begin
            g = parity_grid()
            queue_uploads!(r, "partial", g)
            gl_run(w -> upload_step!(r), ctx)   # only the coarsest level, a 1 by 1 grid
            w, h = 60, 40
            cam = Camera(500_000.0 + 7500.0, 7_000_000.0 + 5000.0, 400.0)
            sc = parity_scene(cam, w, h, [grid_layer(g, cam, w, h; nearest = true, shade = false, level = 0)])
            img = Ref{Matrix{UInt32}}()
            gl_run(win -> (gl_draw!(r, sc); img[] = read_texture(r)), ctx)
            bg = img[][1, 1]
            centre = img[][w ÷ 2, h ÷ 2]
            @test centre != bg
            @test count(==(centre), img[]) > 100   # one big cell
            gl_run(w -> free_layer!(r, "partial"), ctx)
            @test all(u -> u.layer.key != "partial", r.pending)
        end

        @testset "uploads: one batch per frame within the budget, coarse levels first" begin
            n = 100
            big = [[(Float64(i), 100.0k, sin(i / 300 + k)) for i in 1:35_000] for k in 1:n]
            d = build_line_layer!(LineLayerData(), line_points(big))
            @test 12 * length(d.levels[1].x) >= 40 * 2^20
            queue_uploads!(r, "big", d)
            per_frame = Int[]
            first_level = Ref(0)
            while !isempty(r.pending)
                gl_run(w -> upload_step!(r), ctx)
                push!(per_frame, r.uploaded_last_frame)
                if first_level[] == 0
                    gl = UI.gl_layer(r, "big")
                    first_level[] = findfirst(l -> l.uploaded > 0, gl.lines)
                end
            end
            @test first_level[] == length(d.levels)
            @test all(<=(UPLOAD_BYTES), per_frame)
            @test count(>(0), per_frame) >= 5
            gl_run(w -> free_layer!(r, "big"), ctx)

            g = parity_grid(; tile = 128)
            queue_uploads!(r, "tiles", g)
            gl_run(w -> upload_step!(r), ctx)
            gl = UI.gl_layer(r, "tiles")
            @test [l.uploaded for l in gl.grids] == [k == length(g.levels) ? 1 : 0 for k in eachindex(g.levels)]
            gl_run(w -> free_layer!(r, "tiles"), ctx)

            # With the default TILE each level is one tile as small as the level: the coarsest
            # tile is 5 by 5 values, and all tiles together are under 1.4 times the grid's values.
            gd = parity_grid(; tile = UI.TILE)
            queue_uploads!(r, "default", gd)
            sizes = Int[]
            while !isempty(r.pending)
                gl_run(w -> upload_step!(r), ctx)
                push!(sizes, r.uploaded_last_frame)
            end
            @test first(sizes) == 5 * 5 * 4
            @test sum(sizes) == sum(sizeof(t) for l in gd.levels for t in l.tiles)
            @test sum(sizes) < 1.4 * 4 * 600 * 400
            gl_run(w -> free_layer!(r, "default"), ctx)
        end

        @testset "a new build draws the old one until it is fully up: $kind" for kind in (:grid, :lines)
            w, h = 300, 200
            cam = Camera(500_000.0 + 7500.0, 7_000_000.0 + 5000.0, 52.0)
            # A fixed style, so both builds draw with the same colours.
            draw(d::GridLayerData) = GridDraw(d, grid_level(d, cam.res), GEOSOFT, 0f0, 40f0, nothing, 1f0, true,
                                              Float32.(Core.sun_vector(45, 45)), 1f0, false)
            draw(d::LineLayerData) = LineDraw(d, choose_level(d, cam, w, h), TURBO, -1f0, 1f0, nothing, (0x20, 0x20, 0x20, 0xff), 1f0)
            if kind == :grid
                a = parity_grid()
                shifted = 20f0 .+ UI.level_matrix(a, 0)
                b = build_grid_layer!(GridLayerData(), (buf, j1) -> (buf .= view(shifted, :, j1:j1+size(buf, 2)-1); buf),
                                      a.geo; tile = a.tile)
            else
                a = parity_lines()
                b = parity_lines()
                b.points.value .*= -1f0
                build_line_layer!(b, b.points)
            end
            queue_uploads!(r, "hand", a)
            upload_all!(ctx, r)
            img_a = Ref{Matrix{UInt32}}()
            gl_run(win -> (gl_draw!(r, parity_scene(cam, w, h, [draw(a)])); img_a[] = read_texture(r)), ctx)

            queue_uploads!(r, "hand", b)
            @test UI.gpu_uses(r, a) && UI.gpu_uses(r, b)
            sc_b = parity_scene(cam, w, h, [draw(b)])
            frames = Tuple{Bool,Matrix{UInt32}}[]
            while !isempty(r.pending)
                gl_run(win -> begin
                    upload_step!(r)
                    gl_draw!(r, sc_b)
                    push!(frames, (UI.gl_layer(r, "hand").remaining == 0, read_texture(r)))
                end, ctx)
            end
            img_b = Ref{Matrix{UInt32}}()
            gl_run(win -> (gl_draw!(r, sc_b); img_b[] = read_texture(r)), ctx)
            @test img_b[] != img_a[]
            @test count(f -> !f[1], frames) >= (kind == :grid ? 5 : 1)   # frames while b goes up
            @test all(f -> f[2] == (f[1] ? img_b[] : img_a[]), frames)
            @test !UI.gpu_uses(r, a) && UI.gpu_uses(r, b)
            @test UI.gl_layer(r, "hand").previous === nothing
            gl_run(win -> free_layer!(r, "hand"), ctx)
        end

        @testset "a failed upload gives the layer an error, not an exception" begin
            g = parity_grid(; tile = 128)
            queue_uploads!(r, "oom", g)
            gl_run(w -> upload_step!(r), ctx)
            r.fail_upload = GL.GL_OUT_OF_MEMORY
            gl_run(w -> upload_step!(r), ctx)
            gl = UI.gl_layer(r, "oom")
            @test gl.error == "The graphics card has no room for this layer."
            @test all(l -> l.uploaded == 0 && all(==(0), l.textures), gl.grids)
            @test all(u -> u.layer !== gl, r.pending)
            @test r.fail_upload == 0
            gl_run(w -> free_all!(r), ctx)
            @test isempty(r.layers) && isempty(r.pending)
        end

        @testset "a map image texture that cannot be sized is deleted, not leaked" begin
            names = 1:4096
            alive() = [GL.glIsTexture(UInt32(i)) == GL.GL_TRUE for i in names]
            before, after, failed = Ref{Vector{Bool}}(), Ref{Vector{Bool}}(), Ref(false)
            gl_run(ctx) do w
                before[] = alive()
                huge = Int(gl_int(GL.GL_MAX_TEXTURE_SIZE)) + 1   # more than GL allows
                try
                    UI.sized_texture!(UInt32(0), (0, 0), huge, 4)
                catch e
                    failed[] = e isa ErrorException && occursin("could not be made", e.msg)
                end
                after[] = alive()
            end
            @test failed[] && after[] == before[]
        end
    end
end

@testset "the app frame loads the layers of the shown map" begin
    s = fresh_session(); db = survey_database!(s); m = Core.new_map!(s); Core.add_layer!(s, m, db)
    with_project_app(s) do ctx, app
        ctx.on_render(w -> (app.ui.current_map = m))
        ctx.wait_until(() -> !isempty(app.map.entries) && all(e -> e.data !== nothing && !e.loading, values(app.map.entries)))
        e = only(values(app.map.entries))
        @test e.data isa LineLayerData && e.error == "" && length(e.data.points.x) == 15
        @test isempty(app.draw_errors)
    end
end
