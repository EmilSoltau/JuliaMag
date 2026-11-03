# The CPU renderer: draws a `Scene` into a matrix of packed pixels. It is the fallback when
# GL is not there and the reference image for the GL tests. The GL shaders follow the same rules.
# Pixels are RGBA8 packed little-endian (R in the low byte); `img[x, y]`, row 1 at the top.
# Nothing here allocates except the tasks that split the rows of a grid.

@inline pack_rgba(r::UInt8, g::UInt8, b::UInt8, a::UInt8)::UInt32 =
    UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24

# One channel: `src * opacity + dst * (1 - opacity)`, rounded.
@inline blend_channel(src::UInt8, dst::UInt8, op::Float32)::UInt8 = round(UInt8, Float32(src) * op + Float32(dst) * (1f0 - op))

@inline function blend_pixel(dst::UInt32, r::UInt8, g::UInt8, b::UInt8, a::UInt8, op::Float32)::UInt32
    return pack_rgba(blend_channel(r, dst % UInt8, op), blend_channel(g, (dst >> 8) % UInt8, op),
                     blend_channel(b, (dst >> 16) % UInt8, op), blend_channel(a, (dst >> 24) % UInt8, op))
end

# The look-up entry of a colour position `t` (not NaN): `round(t * 255) + 1`.
@inline lut_entry(t::Float32)::Int = round(Int, t * 255f0) + 1

"""
    render_cpu!(img, sc)

Draw the scene `sc` into `img` (`width` by `height`, packed RGBA8). The layers go over the
background in order. Rows of a grid are split over `threads` tasks (the keyword is for tests).
A line layer or a grid with no levels, or with a level it does not have, is skipped.
"""
function render_cpu!(img::Matrix{UInt32}, sc::Scene; threads::Int = Threads.nthreads(:default))::Matrix{UInt32}
    size(img) == (sc.width, sc.height) ||
        throw(ArgumentError("the image is $(size(img)), the scene is $((sc.width, sc.height))"))
    bg = sc.background
    fill!(img, pack_rgba(bg[1], bg[2], bg[3], bg[4]))
    for layer in sc.layers
        draw_layer!(img, sc, layer, threads)
    end
    return img
end

# --- Grids ---

function draw_layer!(img::Matrix{UInt32}, sc::Scene, g::GridDraw, threads::Int)
    d = g.data
    (0 <= g.level < length(d.levels) && length(g.lut) >= 1024) || return nothing
    h = sc.height
    n = clamp(threads, 1, h)
    if n == 1
        draw_grid_rows!(img, sc, g, 1, h)
    else
        @sync for t in 1:n
            r1 = (t - 1) * h ÷ n + 1
            r2 = t * h ÷ n
            Threads.@spawn draw_grid_rows!(img, sc, g, r1, r2)
        end
    end
    return nothing
end

# Rows `r1` to `r2` of the picture, for one grid layer. Each row is independent of the others.
function draw_grid_rows!(img::Matrix{UInt32}, sc::Scene, g::GridDraw, r1::Int, r2::Int)
    d = g.data
    geo = d.geo
    lv = d.levels[g.level+1]
    tiles, nx, ny, tile = lv.tiles, lv.nx, lv.ny, d.tile
    cam = sc.camera
    w, h = sc.width, sc.height
    c, s, f = cosd(geo.rotation), sind(geo.rotation), 2.0^g.level
    cw, ch = geo.dx * f, geo.dy * f   # the size of a cell at this level
    op = clamp(g.opacity, 0f0, 1f0)
    @inbounds for py in r1:r2, px in 1:w
        x, y = screen_to_world(cam, w, h, px - 0.5, py - 0.5)
        fi, fj = cell_position(geo, c, s, f, x, y)
        v = if g.nearest
            grid_nearest(tiles, nx, ny, tile, fi, fj)
        else
            grid_bilinear(tiles, nx, ny, tile, fi, fj)
        end
        isnan(v) && continue
        t = Core.colour_position(v, g.lo, g.hi, g.table)
        isnan(t) && continue
        k = 4 * (lut_entry(t) - 1)
        r, gr, b, a = g.lut[k+1], g.lut[k+2], g.lut[k+3], g.lut[k+4]
        if g.shade
            m = g.nearest ? shade_nearest(tiles, nx, ny, tile, fi, fj, cw, ch, c, s, g) :
                shade_bilinear(tiles, nx, ny, tile, fi, fj, cw, ch, c, s, g)
            r, gr, b = round(UInt8, Float32(r) * m), round(UInt8, Float32(gr) * m), round(UInt8, Float32(b) * m)
        end
        img[px, py] = blend_pixel(img[px, py], r, gr, b, a, op)
    end
    return nothing
end

# The fractional position as cell numbers, kept in a range that `floor(Int, ...)` can take.
@inline cell_floor(x::Float64)::Int = floor(Int, clamp(x, -1e9, 1e9))

@inline function grid_nearest(tiles, nx::Int, ny::Int, tile::Int, fi::Float64, fj::Float64)::Float32
    (isnan(fi) || isnan(fj)) && return NaN32
    return level_value(tiles, nx, ny, tile, cell_floor(fi + 0.5), cell_floor(fj + 0.5))
end

# The strict rule of `grid_value`: all four cells are read, a cell outside the grid counts as NaN
# and the result is NaN if any of them is, whatever the weights.
@inline function grid_bilinear(tiles, nx::Int, ny::Int, tile::Int, fi::Float64, fj::Float64)::Float32
    (isnan(fi) || isnan(fj)) && return NaN32
    i0, j0 = cell_floor(fi), cell_floor(fj)
    tx, ty = fi - i0, fj - j0
    v00 = level_value(tiles, nx, ny, tile, i0, j0)
    v10 = level_value(tiles, nx, ny, tile, i0 + 1, j0)
    v01 = level_value(tiles, nx, ny, tile, i0, j0 + 1)
    v11 = level_value(tiles, nx, ny, tile, i0 + 1, j0 + 1)
    (isnan(v00) || isnan(v10) || isnan(v01) || isnan(v11)) && return NaN32
    acc = (1 - tx) * (1 - ty) * v00 + (1 - tx) * ty * v01 + tx * (1 - ty) * v10 + tx * ty * v11
    return Float32(acc)
end

# The slope of cell `(i, j)` along the grid axes: right minus left and up minus down, not yet
# divided by two cell sizes. The rule next to blanks: a neighbour that is NaN or outside the
# level counts as the cell itself, so the difference there is one-sided at half weight.
@inline function cell_slope(tiles, nx::Int, ny::Int, tile::Int, i::Int, j::Int)::NTuple{2,Float64}
    centre = level_value(tiles, nx, ny, tile, i, j)
    l = neighbour(level_value(tiles, nx, ny, tile, i - 1, j), centre)
    r = neighbour(level_value(tiles, nx, ny, tile, i + 1, j), centre)
    dn = neighbour(level_value(tiles, nx, ny, tile, i, j - 1), centre)
    up = neighbour(level_value(tiles, nx, ny, tile, i, j + 1), centre)
    return (Float64(r) - Float64(l), Float64(up) - Float64(dn))
end

@inline neighbour(v::Float32, centre::Float32)::Float32 = isnan(v) ? centre : v

# Nearest cells: the shade of the nearest cell's slope, one shade per cell.
@inline function shade_nearest(tiles, nx::Int, ny::Int, tile::Int, fi::Float64, fj::Float64,
                               cw::Float64, ch::Float64, c::Float64, s::Float64, g::GridDraw)::Float32
    du, dv = cell_slope(tiles, nx, ny, tile, cell_floor(fi + 0.5), cell_floor(fj + 0.5))
    return shade_of_slope(du, dv, cw, ch, c, s, g)
end

# Bilinear cells: the slopes of the four corner cells blended with the weights of the value,
# so the shade is as smooth as the value. Called only for a drawn pixel, so no corner is NaN
# and cell `(i0, j0)` is in the level. Its tile then holds the 12 cells the slopes need (the 4
# by 4 block around the corners, without the block's corners): the border is `TILE_BORDER` = 2
# cells. Each is read once, straight from the tile, as the shader reads them.
@inline function shade_bilinear(tiles, nx::Int, ny::Int, tile::Int, fi::Float64, fj::Float64,
                                cw::Float64, ch::Float64, c::Float64, s::Float64, g::GridDraw)::Float32
    i0, j0 = cell_floor(fi), cell_floor(fj)
    (1 <= i0 < nx && 1 <= j0 < ny) || return 1f0
    tx, ty = fi - i0, fj - j0
    @inbounds t = tiles[(i0-1)÷tile+1, (j0-1)÷tile+1]
    a, b = (i0 - 1) % tile + 1 + TILE_BORDER, (j0 - 1) % tile + 1 + TILE_BORDER
    @inbounds begin
        v00, v10, v01, v11 = t[a, b], t[a+1, b], t[a, b+1], t[a+1, b+1]   # the corners
        l0, l1, r0, r1 = t[a-1, b], t[a-1, b+1], t[a+2, b], t[a+2, b+1]   # left and right of them
        d0, d1, u0, u1 = t[a, b-1], t[a+1, b-1], t[a, b+2], t[a+1, b+2]   # below and above them
    end
    u00, w00 = corner_slope(v00, l0, v10, d0, v01)
    u01, w01 = corner_slope(v01, l1, v11, v00, u0)
    u10, w10 = corner_slope(v10, v00, r0, d1, v11)
    u11, w11 = corner_slope(v11, v01, r1, v10, u1)
    du = (1 - tx) * (1 - ty) * u00 + (1 - tx) * ty * u01 + tx * (1 - ty) * u10 + tx * ty * u11
    dv = (1 - tx) * (1 - ty) * w00 + (1 - tx) * ty * w01 + tx * (1 - ty) * w10 + tx * ty * w11
    return shade_of_slope(du, dv, cw, ch, c, s, g)
end

# `cell_slope` from the values already read: the cell and its left, right, lower and upper neighbours.
@inline function corner_slope(centre::Float32, l::Float32, r::Float32, dn::Float32, up::Float32)::NTuple{2,Float64}
    return (Float64(neighbour(r, centre)) - Float64(neighbour(l, centre)),
            Float64(neighbour(up, centre)) - Float64(neighbour(dn, centre)))
end

# `0.25 + 0.75 h` for a slope from `cell_slope`: divided by two cell sizes, times the vertical
# scale. The slope is along the grid axes; it is turned by the grid rotation to meet the sun,
# which is given as east, north, up.
@inline function shade_of_slope(du::Float64, dv::Float64, cw::Float64, ch::Float64, c::Float64, s::Float64,
                                g::GridDraw)::Float32
    z = Float64(g.zfactor)
    gu = du / (2cw) * z
    gv = dv / (2ch) * z
    gx = gu * c - gv * s
    gy = gu * s + gv * c
    inv = 1 / sqrt(gx * gx + gy * gy + 1)
    sun = g.sun
    hh = max((-gx * sun[1] - gy * sun[2] + sun[3]) * inv, 0.0)
    return Float32(0.25 + 0.75 * hh)
end

# --- Lines ---

function draw_layer!(img::Matrix{UInt32}, sc::Scene, l::LineDraw, ::Int)
    d = l.data
    (1 <= l.level <= length(d.levels) && length(l.lut) >= 1024) || return nothing
    w, h = sc.width, sc.height
    cam = sc.camera
    draw_list!(sc.firsts, sc.counts, d, l.level, cam, w, h)
    draw_line_parts!(img, sc, l, d.levels[l.level], d.points.origin)
    return nothing
end

function draw_line_parts!(img::Matrix{UInt32}, sc::Scene, l::LineDraw, lv::LineLevel, origin::NTuple{2,Float64})
    cam = sc.camera
    w, h = sc.width, sc.height
    ox, oy = origin
    firsts, counts = sc.firsts, sc.counts
    @inbounds for p in eachindex(firsts)
        a = Int(firsts[p]) + 1
        z = a + Int(counts[p]) - 1
        a < z || continue
        sx0, sy0 = world_to_screen(cam, w, h, ox + lv.x[a], oy + lv.y[a])
        for i in a:z-1
            sx1, sy1 = world_to_screen(cam, w, h, ox + lv.x[i+1], oy + lv.y[i+1])
            draw_segment!(img, w, h, l, sx0, sy0, sx1, sy1, lv.v[i], lv.v[i+1], i == z - 1)
            sx0, sy0 = sx1, sy1
        end
    end
    return nothing
end

# One segment in screen coordinates (pixel `p` covers `p - 1` to `p`, its centre is `p - 0.5`).
# The pixels whose centres lie on the segment along the longer axis; the value is interpolated.
# The end is left to the next segment, unless this one `closes` its part, so a joint draws once.
function draw_segment!(img::Matrix{UInt32}, w::Int, h::Int, l::LineDraw, ax::Float64, ay::Float64,
                       bx::Float64, by::Float64, va::Float32, vb::Float32, closes::Bool)
    dx, dy = bx - ax, by - ay
    (isfinite(dx) && isfinite(dy) && (dx != 0 || dy != 0)) || return nothing
    if abs(dx) >= abs(dy)
        lo, hi = minmax(ax, bx)
        p1 = max(ceil(lo + 0.5), 1.0)
        p2 = min(floor(hi + 0.5), Float64(w))
        for pm in Int(p1):Int(p2)
            t = (pm - 0.5 - ax) / dx
            (t >= 1 && !closes) && continue
            y = ay + t * dy
            (0.0 <= y < h) || continue
            put_line_pixel!(img, l, pm, floor(Int, y) + 1, va + (vb - va) * Float32(t))
        end
    else
        lo, hi = minmax(ay, by)
        p1 = max(ceil(lo + 0.5), 1.0)
        p2 = min(floor(hi + 0.5), Float64(h))
        for pm in Int(p1):Int(p2)
            t = (pm - 0.5 - ay) / dy
            (t >= 1 && !closes) && continue
            x = ax + t * dx
            (0.0 <= x < w) || continue
            put_line_pixel!(img, l, floor(Int, x) + 1, pm, va + (vb - va) * Float32(t))
        end
    end
    return nothing
end

@inline function put_line_pixel!(img::Matrix{UInt32}, l::LineDraw, px::Int, py::Int, v::Float32)
    t = Core.colour_position(v, l.lo, l.hi, l.table)
    @inbounds if isnan(t)
        r, g, b, a = l.plain
    else
        k = 4 * (lut_entry(t) - 1)
        r, g, b, a = l.lut[k+1], l.lut[k+2], l.lut[k+3], l.lut[k+4]
    end
    @inbounds img[px, py] = blend_pixel(img[px, py], r, g, b, a, clamp(l.opacity, 0f0, 1f0))
    return nothing
end
