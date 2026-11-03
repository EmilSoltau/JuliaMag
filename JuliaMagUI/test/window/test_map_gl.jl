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

function grid_layer(d::GridLayerData, cam, w, h; nearest, shade, level = grid_level(d, cam.res))
    table = Core.equalize_table(d.hist)
    sun = Float32.(Core.sun_vector(45, 45))
    z = Float32(Core.auto_zfactor(d.mean_gradient))
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

        @testset "parity with the CPU renderer: $name" for (name, res, nearest, shade) in (
                ("bilinear-shade", 52.0, false, true), ("nearest", 52.0, true, false), ("level-2", 104.0, false, true))
            w, h = 300, 200
            cam = Camera(500_000.0 + 7500.0 + 13.7, 7_000_000.0 + 5000.0 - 9.1, res)
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
                           gl_int(GL.GL_CURRENT_PROGRAM), gl_int(GL.GL_VERTEX_ARRAY_BINDING))
            end)
            @test thrown[] && !r.throw_in_draw
            @test state[][1] == 0 && state[][2] == state[][3] && state[][4] == 0 && state[][5] == 0
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
    end
end
