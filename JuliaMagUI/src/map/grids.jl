# Data of a grid layer for the map: the grid cut into bordered Float32 tiles at every
# coarser level, a value histogram and the mean gradient. No window, no GL.
# Every level is cut from the whole level, so the 1-cell border of a tile holds the real
# neighbour at that level and hillshade and bilinear sampling have no seams.

"The georeference of a grid. `x0, y0` is the centre of the lower left cell, `rotation` is in degrees, counter-clockwise."
struct GridGeo
    nx::Int
    ny::Int
    x0::Float64
    y0::Float64
    dx::Float64
    dy::Float64
    rotation::Float64
end

GridGeo(g::Core.Grid) = GridGeo(g.nx, g.ny, g.x0, g.y0, g.dx, g.dy, g.rotation)

"""
One level of a grid: `nx` by `ny` cells (halves of the level below, rounded up). Tile
`(ti, tj)` is `(tile + 2)` by `(tile + 2)` values: its cells with a 1-cell border from the
neighbours at the same level, `NaN` outside the grid.
"""
mutable struct GridLevel
    k::Int
    nx::Int
    ny::Int
    tiles::Matrix{Matrix{Float32}}
end

"""
The data of one grid layer. Level 0 is the grid, the last level is 1 by 1. `count` is the
number of cells that are not `NaN`. `mean_gradient` is in value units per world unit (`NaN`
when no cell has four good neighbours). `extent` is `(xmin, ymin, xmax, ymax)` of the
corners. `version` counts the builds.
"""
mutable struct GridLayerData
    geo::GridGeo
    tile::Int
    levels::Vector{GridLevel}
    hist::Core.ValueHistogram
    count::Int
    mean_gradient::Float64
    extent::NTuple{4,Float64}
    version::Int
    bands::Vector{Matrix{Float32}}   # scratch: the band buffers, one per row count
    tcount::Vector{Int}              # scratch: per tile
    tlo::Vector{Float32}
    thi::Vector{Float32}
    tsum::Vector{Float64}
end

GridLayerData() = GridLayerData(GridGeo(0, 0, 0.0, 0.0, 1.0, 1.0, 0.0), 0, GridLevel[], Core.ValueHistogram(),
                                0, NaN, (NaN, NaN, NaN, NaN), 0, Matrix{Float32}[], Int[], Float32[], Float32[], Float64[])

# --- Build ---

"The extent of the four corners of the cells' outer edges."
function grid_extent(geo::GridGeo)::NTuple{4,Float64}
    c = cosd(geo.rotation)
    s = sind(geo.rotation)
    u0, u1 = -geo.dx / 2, (geo.nx - 0.5) * geo.dx
    v0, v1 = -geo.dy / 2, (geo.ny - 0.5) * geo.dy
    xs = (geo.x0 + u0 * c - v0 * s, geo.x0 + u1 * c - v0 * s, geo.x0 + u1 * c - v1 * s, geo.x0 + u0 * c - v1 * s)
    ys = (geo.y0 + u0 * s + v0 * c, geo.y0 + u1 * s + v0 * c, geo.y0 + u1 * s + v1 * c, geo.y0 + u0 * s + v1 * c)
    return (minimum(xs), minimum(ys), maximum(xs), maximum(ys))
end

# The tile matrix of a level, reusing the old tiles when the sizes fit.
function level_tiles(old::Union{Nothing,GridLevel}, nti::Int, ntj::Int, tile::Int)::Matrix{Matrix{Float32}}
    size_ok = old !== nothing && size(old.tiles) == (nti, ntj) && all(t -> size(t) == (tile + 2, tile + 2), old.tiles)
    size_ok && return old.tiles
    return [Matrix{Float32}(undef, tile + 2, tile + 2) for _ in 1:nti, _ in 1:ntj]
end

# The band buffer with `n` rows: one of the kept buffers, or a new one added to them.
function band_buffer!(bands::Vector{Matrix{Float32}}, nx::Int, n::Int)::Matrix{Float32}
    for b in bands
        size(b, 2) == n && return b
    end
    b = Matrix{Float32}(undef, nx, n)
    push!(bands, b)
    return b
end

# Put level `k` (1-based) in the list, reusing its object when there is one.
function set_level!(levels::Vector{GridLevel}, k::Int, nx::Int, ny::Int, tiles::Matrix{Matrix{Float32}})
    if k <= length(levels)
        l = levels[k]
        l.nx, l.ny, l.tiles = nx, ny, tiles
    else
        push!(levels, GridLevel(k - 1, nx, ny, tiles))
    end
    return levels
end

# Cut the tiles of tile row `tj` of level 0 from `band`, which holds grid rows `r1` on.
function cut_band!(tiles::Matrix{Matrix{Float32}}, tj::Int, band::Matrix{Float32}, r1::Int, nx::Int, ny::Int, tile::Int)
    nti = size(tiles, 1)
    n = size(band, 2)
    Threads.@threads for ti in 1:nti
        t = tiles[ti, tj]
        @inbounds for b in 1:tile+2
            j = (tj - 1) * tile + b - 1
            row = j - r1 + 1
            rowok = 1 <= j <= ny && 1 <= row <= n
            for a in 1:tile+2
                i = (ti - 1) * tile + a - 1
                t[a, b] = rowok && 1 <= i <= nx ? band[i, row] : NaN32
            end
        end
    end
    return tiles
end

# The cell (i, j) of a level, NaN outside it.
@inline function level_value(tiles::Matrix{Matrix{Float32}}, nx::Int, ny::Int, tile::Int, i::Int, j::Int)::Float32
    (1 <= i <= nx && 1 <= j <= ny) || return NaN32
    @inbounds return tiles[(i-1)÷tile+1, (j-1)÷tile+1][(i-1)%tile+2, (j-1)%tile+2]
end

# NaN-aware mean of a 2 by 2 block: the sum in order, divided by the number of good cells.
@inline function mean4(a::Float32, b::Float32, c::Float32, d::Float32)::Float32
    s = 0f0
    n = 0
    isnan(a) || (s += a; n += 1)
    isnan(b) || (s += b; n += 1)
    isnan(c) || (s += c; n += 1)
    isnan(d) || (s += d; n += 1)
    return n == 0 ? NaN32 : s / n
end

# Cut level `lv` from the level `below`: every tile cell, border included, is the mean of its block.
function cut_level!(lv::Matrix{Matrix{Float32}}, nx::Int, ny::Int, below::GridLevel, tile::Int)
    bt, bnx, bny = below.tiles, below.nx, below.ny
    nti, ntj = size(lv)
    Threads.@threads for idx in 1:nti*ntj
        ti = (idx - 1) % nti + 1
        tj = (idx - 1) ÷ nti + 1
        t = lv[ti, tj]
        @inbounds for b in 1:tile+2
            j = (tj - 1) * tile + b - 1
            for a in 1:tile+2
                i = (ti - 1) * tile + a - 1
                if 1 <= i <= nx && 1 <= j <= ny
                    i2, j2 = 2i - 1, 2j - 1
                    t[a, b] = mean4(level_value(bt, bnx, bny, tile, i2, j2), level_value(bt, bnx, bny, tile, i2 + 1, j2),
                                    level_value(bt, bnx, bny, tile, i2, j2 + 1), level_value(bt, bnx, bny, tile, i2 + 1, j2 + 1))
                else
                    t[a, b] = NaN32
                end
            end
        end
    end
    return lv
end

# Count, minimum and maximum of the cells of each tile (borders left out).
function tile_stats!(cnt::Vector{Int}, lo::Vector{Float32}, hi::Vector{Float32}, tiles::Matrix{Matrix{Float32}},
                     nx::Int, ny::Int, tile::Int)
    nti = size(tiles, 1)
    Threads.@threads for idx in eachindex(tiles)
        ti = (idx - 1) % nti + 1
        tj = (idx - 1) ÷ nti + 1
        t = tiles[idx]
        a2 = min(tile, nx - (ti - 1) * tile) + 1
        b2 = min(tile, ny - (tj - 1) * tile) + 1
        c = 0
        l, h = Inf32, -Inf32
        @inbounds for b in 2:b2, a in 2:a2
            v = t[a, b]
            isnan(v) && continue
            c += 1
            l = min(l, v)
            h = max(h, v)
        end
        cnt[idx] = c
        lo[idx] = l
        hi[idx] = h
    end
    return nothing
end

# Sum and number of the gradient magnitudes of the cells of each tile.
function tile_gradients!(sums::Vector{Float64}, cnt::Vector{Int}, tiles::Matrix{Matrix{Float32}},
                         nx::Int, ny::Int, tile::Int, dx::Float64, dy::Float64)
    nti = size(tiles, 1)
    Threads.@threads for idx in eachindex(tiles)
        ti = (idx - 1) % nti + 1
        tj = (idx - 1) ÷ nti + 1
        t = tiles[idx]
        a2 = min(tile, nx - (ti - 1) * tile) + 1
        b2 = min(tile, ny - (tj - 1) * tile) + 1
        s = 0.0
        c = 0
        @inbounds for b in 2:b2, a in 2:a2
            l, r, dn, up = t[a-1, b], t[a+1, b], t[a, b-1], t[a, b+1]
            (isnan(l) || isnan(r) || isnan(dn) || isnan(up)) && continue
            gx = (Float64(r) - Float64(l)) / (2dx)
            gy = (Float64(up) - Float64(dn)) / (2dy)
            s += hypot(gx, gy)
            c += 1
        end
        sums[idx] = s
        cnt[idx] = c
    end
    return nothing
end

# Add the cells of every tile to the histogram, a column at a time.
function fill_histogram!(h::Core.ValueHistogram, tiles::Matrix{Matrix{Float32}}, nx::Int, ny::Int, tile::Int)
    nti = size(tiles, 1)
    for idx in eachindex(tiles)
        ti = (idx - 1) % nti + 1
        tj = (idx - 1) ÷ nti + 1
        t = tiles[idx]
        a2 = min(tile, nx - (ti - 1) * tile) + 1
        b2 = min(tile, ny - (tj - 1) * tile) + 1
        for b in 2:b2
            Core.add_values!(h, view(t, 2:a2, b))
        end
    end
    return h
end

"""
    build_grid_layer!(d, read_band!, geo; tile = TILE) -> d

Fill `d` in place, reusing its tile arrays. `read_band!(buf, j1)` fills `buf` (`nx` by `n`,
`Float32`) with the rows `j1` on. The grid is read in bands of `tile` rows plus a border row
on each side, so the memory stays at one band. Each level above is the NaN-aware 2 by 2 mean
of the level below (a block of all `NaN` gives `NaN`) and is cut into tiles from that same
level. The histogram runs from the lowest to the highest good value.

Build only into data that no other thread reads: the tiles are rewritten in place, and
after a throw the data is not usable. The loader builds into a spare and swaps.
"""
function build_grid_layer!(d::GridLayerData, read_band!::F, geo::GridGeo; tile::Int = TILE)::GridLayerData where {F}
    tile > 0 || throw(ArgumentError("tile must be positive, not $tile"))
    (geo.nx > 0 && geo.ny > 0) || throw(ArgumentError("a grid needs at least one cell in each direction"))
    d.tile != tile && (empty!(d.levels); empty!(d.bands))
    nx, ny = geo.nx, geo.ny
    nti, ntj = cld(nx, tile), cld(ny, tile)
    isempty(d.bands) || size(d.bands[1], 1) == nx || empty!(d.bands)
    levels = d.levels
    tiles = level_tiles(isempty(levels) ? nothing : levels[1], nti, ntj, tile)
    for tj in 1:ntj
        r1 = max(1, (tj - 1) * tile)
        r2 = min(ny, tj * tile + 1)
        band = band_buffer!(d.bands, nx, r2 - r1 + 1)
        read_band!(band, r1)
        cut_band!(tiles, tj, band, r1, nx, ny, tile)
    end
    set_level!(levels, 1, nx, ny, tiles)
    nlev = 1
    while nx > 1 || ny > 1
        k = nlev
        nx, ny = cld(nx, 2), cld(ny, 2)
        nti, ntj = cld(nx, tile), cld(ny, tile)
        lv = level_tiles(length(levels) > k ? levels[k+1] : nothing, nti, ntj, tile)
        cut_level!(lv, nx, ny, levels[k], tile)
        set_level!(levels, k + 1, nx, ny, lv)
        nlev += 1
    end
    resize!(levels, nlev)

    t0 = levels[1].tiles
    cnt = resize!(d.tcount, length(t0))
    lo = resize!(d.tlo, length(t0))
    hi = resize!(d.thi, length(t0))
    tile_stats!(cnt, lo, hi, t0, geo.nx, geo.ny, tile)
    total = sum(cnt)
    vmin, vmax = minimum(lo), maximum(hi)
    total == 0 ? Core.reset!(d.hist, NaN, NaN) : Core.reset!(d.hist, vmin, vmax)
    fill_histogram!(d.hist, t0, geo.nx, geo.ny, tile)

    gs = resize!(d.tsum, length(t0))
    tile_gradients!(gs, cnt, t0, geo.nx, geo.ny, tile, geo.dx, geo.dy)
    n = sum(cnt)
    d.mean_gradient = n == 0 ? NaN : sum(gs) / n

    d.geo = geo
    d.tile = tile
    d.count = total
    d.extent = grid_extent(geo)
    d.version += 1
    return d
end

# --- Sampling ---

"The level of a grid for `res` world units per device pixel: the coarsest level whose cells are not bigger than that."
grid_level(d::GridLayerData, res::Real)::Int =
    clamp(floor(Int, log2(res / min(d.geo.dx, d.geo.dy))), 0, length(d.levels) - 1)

"""
    level_cell(d, k, x, y) -> (i, j)

The fractional cell position at level `k` of the world point `(x, y)`, with rotation. The
centre of cell `(i, j)` is at position `(i, j)`; a cell of level `k` is `2^k` cells wide.
"""
function level_cell(d::GridLayerData, k::Int, x::Real, y::Real)::NTuple{2,Float64}
    g = d.geo
    c = cosd(g.rotation)
    s = sind(g.rotation)
    px, py = x - g.x0, y - g.y0
    u = (px * c + py * s) / g.dx   # cells of level 0 from the centre of cell (1, 1)
    v = (-px * s + py * c) / g.dy
    f = 2.0^k
    return ((u + 0.5) / f + 0.5, (v + 0.5) / f + 0.5)
end

"The value of cell `(i, j)` at level `k`, read from the tile that holds it. `NaN` outside the level."
function cell_value(d::GridLayerData, k::Int, i::Int, j::Int)::Float32
    l = d.levels[k+1]
    return level_value(l.tiles, l.nx, l.ny, d.tile, i, j)
end

"""
    grid_value(d, x, y; nearest) -> Float32

The value at level 0 at the world point `(x, y)`: the nearest cell, or the bilinear value
of the four cells around it. Rule: `NaN` when any of the four cells is `NaN` or outside the grid, whatever the weights.
"""
function grid_value(d::GridLayerData, x::Real, y::Real; nearest::Bool)::Float32
    fi, fj = level_cell(d, 0, x, y)
    (isnan(fi) || isnan(fj)) && return NaN32
    if nearest
        return cell_value(d, 0, floor(Int, fi + 0.5), floor(Int, fj + 0.5))
    end
    i0, j0 = floor(Int, fi), floor(Int, fj)
    tx, ty = fi - i0, fj - j0
    acc = 0.0
    for (di, wx) in ((0, 1 - tx), (1, tx)), (dj, wy) in ((0, 1 - ty), (1, ty))
        w = wx * wy
        v = cell_value(d, 0, i0 + di, j0 + dj)
        isnan(v) && return NaN32
        acc += w * v
    end
    return Float32(acc)
end

"Level `k` stitched from its tiles, for tests."
function level_matrix(d::GridLayerData, k::Int)::Matrix{Float32}
    l = d.levels[k+1]
    M = Matrix{Float32}(undef, l.nx, l.ny)
    for j in 1:l.ny, i in 1:l.nx
        M[i, j] = cell_value(d, k, i, j)
    end
    return M
end
