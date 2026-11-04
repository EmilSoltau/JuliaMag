# Data of a line layer for the map: thinned levels that keep spikes, culling by part
# box, and a point index for picking. No window, no GL.
# Positions are Float32 offsets from `points.origin`; world coordinates are Float64.

"""
One thinned copy of the line points. Part `k` holds points `first[k] + 1` to
`first[k] + count[k]`. `bucket` is the number of base points each bucket stood for.
"""
struct LineLevel
    bucket::Int
    x::Vector{Float32}
    y::Vector{Float32}
    v::Vector{Float32}
    first::Vector{Int32}
    count::Vector{Int32}
end

LineLevel(bucket::Int) = LineLevel(bucket, Float32[], Float32[], Float32[], Int32[], Int32[])

"A uniform grid over the base points, about `POINTS_PER_CELL` points per cell."
mutable struct PointIndex
    x0::Float64          # lower left corner, in offsets from the origin
    y0::Float64
    cell::Float64
    nx::Int
    ny::Int
    start::Vector{Int32} # cell c holds ids[start[c]:start[c+1]-1], c = iy * nx + ix + 1
    ids::Vector{Int32}   # 1-based point numbers, sorted by cell
    cell_of::Vector{Int32}
end

PointIndex() = PointIndex(0.0, 0.0, 1.0, 0, 0, Int32[1], Int32[], Int32[])

const POINTS_PER_CELL = 8
const LEVEL_SHRINK = 0.75   # a level must keep under this share of the points of the one before

"""
The data of one line layer: the points, their levels, the box of each part, the value
histogram, the pick index and the extent of the good points (`nothing` for none).
`version` is new for each build (`next_data_version`).
"""
mutable struct LineLayerData
    points::Core.LinePoints
    levels::Vector{LineLevel}
    part_box::Vector{NTuple{4,Float32}}
    hist::Core.ValueHistogram
    index::PointIndex
    extent::Union{Nothing,NTuple{4,Float64}}
    version::Int
    part_key::Vector{UInt8}   # what a part thins by: 0 value, 1 x, 2 y
end

LineLayerData() = LineLayerData(Core.LinePoints(), LineLevel[], NTuple{4,Float32}[], Core.ValueHistogram(),
                                PointIndex(), nothing, 0, UInt8[])

const DATA_VERSION = Threads.Atomic{Int}(0)

"""
    next_data_version() -> Int

A version no layer data of this process had before. Each build and each swap into a layer
takes one, so a version alone tells two builds apart: the scene key needs no object address,
which a new object may reuse after a collection. Any thread may call it.
"""
next_data_version()::Int = Threads.atomic_add!(DATA_VERSION, 1) + 1

"""
    NearPoint

A picked point: the index of its line, its row, its world position, its value and its
distance from the query.
"""
struct NearPoint
    line::Int
    row::Int
    x::Float64
    y::Float64
    value::Float32
    dist::Float64
end

# --- Build ---

"""
    build_line_layer!(d, pts) -> d

Fill `d` from `pts` in place, reusing its arrays. Level `k` keeps, per bucket of `bucket`
points of a part, the points with the lowest and the highest value in their order, and the
first and last point of the part. A part with no values uses the coordinate across its
longer side. Levels go up by `LOD_FACTOR` while a level has under 75 % of the points of
the one before and the bucket is at most the longest part (and at most `LOD_FACTOR^(LINE_LEVELS - 1)`).
"""
function build_line_layer!(d::LineLayerData, pts::Core.LinePoints)::LineLayerData
    d.points = pts
    d.version = next_data_version()
    fill_boxes!(d.part_box, d.part_key, pts.x, pts.y, pts.value, pts.part_first, pts.part_count)
    d.extent = lines_extent(pts.extents)
    fill_histogram!(d.hist, pts.value)
    build_levels!(d, pts)
    build_index!(d.index, pts.x, pts.y)
    return d
end

# Boxes of the parts, and what each part thins by.
function fill_boxes!(boxes::Vector{NTuple{4,Float32}}, keys::Vector{UInt8}, x::Vector{Float32}, y::Vector{Float32},
                     v::Vector{Float32}, firsts::Vector{Int32}, counts::Vector{Int32})
    np = length(firsts)
    resize!(boxes, np)
    resize!(keys, np)
    @inbounds for k in 1:np
        a = Int(firsts[k]) + 1
        z = a + Int(counts[k]) - 1
        x0 = y0 = Inf32
        x1 = y1 = -Inf32
        has_value = false
        for i in a:z
            xi, yi = x[i], y[i]
            x0 = min(x0, xi); x1 = max(x1, xi)
            y0 = min(y0, yi); y1 = max(y1, yi)
            has_value |= !isnan(v[i])
        end
        boxes[k] = (x0, y0, x1, y1)
        keys[k] = has_value ? 0x00 : (x1 - x0 >= y1 - y0 ? 0x01 : 0x02)
    end
    return nothing
end

# The union of the line extents that are not empty.
function lines_extent(ext::Vector{NTuple{4,Float64}})::Union{Nothing,NTuple{4,Float64}}
    x0 = y0 = Inf
    x1 = y1 = -Inf
    any_good = false
    for e in ext
        any(isnan, e) && continue
        any_good = true
        x0 = min(x0, e[1]); y0 = min(y0, e[2])
        x1 = max(x1, e[3]); y1 = max(y1, e[4])
    end
    return any_good ? (x0, y0, x1, y1) : nothing
end

function fill_histogram!(h::Core.ValueHistogram, v::Vector{Float32})
    lo = Inf32
    hi = -Inf32
    @inbounds for x in v
        isnan(x) && continue
        lo = min(lo, x); hi = max(hi, x)
    end
    if lo > hi
        Core.reset!(h, NaN, NaN)
    else
        Core.reset!(h, lo, hi)
        Core.add_values!(h, v)
    end
    return nothing
end

function base_level(d::LineLayerData, pts::Core.LinePoints)::LineLevel
    isempty(d.levels) && return LineLevel(1, pts.x, pts.y, pts.value, pts.part_first, pts.part_count)
    l = d.levels[1]
    (l.x === pts.x && l.y === pts.y && l.v === pts.value && l.first === pts.part_first && l.count === pts.part_count) &&
        return l
    return LineLevel(1, pts.x, pts.y, pts.value, pts.part_first, pts.part_count)
end

function build_levels!(d::LineLayerData, pts::Core.LinePoints)
    levels = d.levels
    isempty(levels) ? push!(levels, base_level(d, pts)) : (levels[1] = base_level(d, pts))
    longest = Int(maximum(pts.part_count; init = Int32(0)))
    nkeep = 1
    bucket = 1
    while bucket * LOD_FACTOR <= min(longest, LOD_FACTOR^(LINE_LEVELS - 1))
        bucket *= LOD_FACTOR
        k = nkeep + 1
        if k > length(levels) || levels[k].bucket != bucket
            k > length(levels) ? push!(levels, LineLevel(bucket)) : (levels[k] = LineLevel(bucket))
        end
        lv = levels[k]
        thin_level!(lv, pts.x, pts.y, pts.value, pts.part_first, pts.part_count, d.part_key, bucket)
        length(lv.x) < LEVEL_SHRINK * length(levels[nkeep].x) || break
        nkeep = k
    end
    resize!(levels, nkeep)
    return nothing
end

# One level: per bucket of `b` points of a part keep the points with the lowest and the
# highest key, in order, plus the first and last point of the part.
function thin_level!(lv::LineLevel, x::Vector{Float32}, y::Vector{Float32}, v::Vector{Float32},
                     firsts::Vector{Int32}, counts::Vector{Int32}, keys::Vector{UInt8}, b::Int)
    foreach(empty!, (lv.x, lv.y, lv.v, lv.first, lv.count))
    @inbounds for p in eachindex(firsts)
        key = keys[p] == 0x00 ? v : keys[p] == 0x01 ? x : y
        a = Int(firsts[p]) + 1
        z = a + Int(counts[p]) - 1
        start = length(lv.x)
        push!(lv.first, Int32(start))
        put_point!(lv, x, y, v, a)
        s = a + 1
        while s < z
            e = min(s + b - 1, z - 1)
            imin = imax = s
            kmin = kmax = NaN32
            for i in s:e
                ki = key[i]
                isnan(ki) && continue
                if isnan(kmin)
                    imin = imax = i
                    kmin = kmax = ki
                else
                    ki < kmin && (imin = i; kmin = ki)
                    ki > kmax && (imax = i; kmax = ki)
                end
            end
            lo, hi = minmax(imin, imax)
            put_point!(lv, x, y, v, lo)
            lo != hi && put_point!(lv, x, y, v, hi)
            s = e + 1
        end
        z > a && put_point!(lv, x, y, v, z)
        push!(lv.count, Int32(length(lv.x) - start))
    end
    return nothing
end

@inline function put_point!(lv::LineLevel, x, y, v, i::Int)
    @inbounds push!(lv.x, x[i]); push!(lv.y, y[i]); push!(lv.v, v[i])
    return nothing
end

# The grid over the base points, by counting sort.
function build_index!(ix::PointIndex, x::Vector{Float32}, y::Vector{Float32})
    n = length(x)
    if n == 0
        ix.nx = ix.ny = 0
        resize!(ix.start, 1); ix.start[1] = 1
        empty!(ix.ids)
        return nothing
    end
    x0, x1 = Float64(minimum(x)), Float64(maximum(x))
    y0, y1 = Float64(minimum(y)), Float64(maximum(y))
    w, h = x1 - x0, y1 - y0
    cells = max(1, n ÷ POINTS_PER_CELL)
    cell = max(sqrt(w * h / cells), max(w, h) / cells)
    cell > 0 || (cell = 1.0)
    ix.x0, ix.y0, ix.cell = x0, y0, cell
    ix.nx = floor(Int, w / cell) + 1
    ix.ny = floor(Int, h / cell) + 1
    counting_sort!(ix, x, y)
    return nothing
end

@inline cell_x(ix::PointIndex, px::Real) = clamp(floor(Int, (px - ix.x0) / ix.cell), 0, ix.nx - 1)
@inline cell_y(ix::PointIndex, py::Real) = clamp(floor(Int, (py - ix.y0) / ix.cell), 0, ix.ny - 1)

function counting_sort!(ix::PointIndex, x::Vector{Float32}, y::Vector{Float32})
    n = length(x)
    nc = ix.nx * ix.ny
    resize!(ix.start, nc + 1)
    resize!(ix.ids, n)
    resize!(ix.cell_of, n)
    fill!(ix.start, Int32(0))
    @inbounds for i in 1:n
        c = cell_y(ix, y[i]) * ix.nx + cell_x(ix, x[i]) + 1
        ix.cell_of[i] = c
        ix.start[c] += Int32(1)
    end
    pos = Int32(1)
    @inbounds for c in 1:nc
        cnt = ix.start[c]
        ix.start[c] = pos
        pos += cnt
    end
    ix.start[nc+1] = pos
    # Fill with a moving cursor per cell, then shift the starts back.
    @inbounds for i in 1:n
        c = ix.cell_of[i]
        ix.ids[ix.start[c]] = Int32(i)
        ix.start[c] += Int32(1)
    end
    @inbounds for c in nc:-1:2
        ix.start[c] = ix.start[c-1]
    end
    ix.start[1] = 1
    return nothing
end

# --- Culling and level choice ---

# The view grown by `CULL_MARGIN` of its size, in offsets from the layer origin.
@inline function cull_box(d::LineLayerData, cam::Camera, w, h)
    ox, oy = d.points.origin
    hw = w * cam.res / 2 * (1 + 2CULL_MARGIN)
    hh = h * cam.res / 2 * (1 + 2CULL_MARGIN)
    return (cam.cx - ox - hw, cam.cy - oy - hh, cam.cx - ox + hw, cam.cy - oy + hh)
end

@inline box_meets(b::NTuple{4,Float32}, v::NTuple{4,Float64}) =
    b[1] <= v[3] && b[3] >= v[1] && b[2] <= v[4] && b[4] >= v[2]

# Points of `level` in parts that meet the culled view.
function culled_count(d::LineLayerData, level::LineLevel, cam::Camera, w, h)::Int
    v = cull_box(d, cam, w, h)
    total = 0
    @inbounds for k in eachindex(level.count)
        box_meets(d.part_box[k], v) && (total += Int(level.count[k]))
    end
    return total
end

"""
    choose_level(d, cam, w, h) -> Int

The finest level whose points in view (after culling) are at most `POINT_BUDGET * w * h`,
else the coarsest.
"""
function choose_level(d::LineLayerData, cam::Camera, w, h)::Int
    budget = POINT_BUDGET * w * h
    for k in eachindex(d.levels)
        culled_count(d, d.levels[k], cam, w, h) <= budget && return k
    end
    return length(d.levels)
end

"""
    draw_list!(firsts, counts, d, level, cam, w, h) -> Int

Fill `firsts` and `counts` with the parts of `level` whose box meets the view grown by
`CULL_MARGIN` of its size on each side. Returns the points listed. Does not allocate once
the vectors are big enough.
"""
function draw_list!(firsts::Vector{Int32}, counts::Vector{Int32}, d::LineLayerData, level::Int, cam::Camera, w, h)::Int
    empty!(firsts)
    empty!(counts)
    lv = d.levels[level]
    v = cull_box(d, cam, w, h)
    total = 0
    @inbounds for k in eachindex(lv.count)
        box_meets(d.part_box[k], v) || continue
        push!(firsts, lv.first[k])
        push!(counts, lv.count[k])
        total += Int(lv.count[k])
    end
    return total
end

# --- Picking ---

"""
    nearest_point(d, x, y, radius) -> Union{Nothing,NearPoint}

The base point nearest to the world position `(x, y)` within `radius` world units.
"""
function nearest_point(d::LineLayerData, x::Real, y::Real, radius::Real)::Union{Nothing,NearPoint}
    ix = d.index
    (ix.nx == 0 || !(radius >= 0)) && return nothing
    pts = d.points
    qx, qy = x - pts.origin[1], y - pts.origin[2]
    best = 0
    bd2 = Float64(radius)^2
    cx0, cx1 = cell_range(ix.x0, ix.cell, ix.nx, qx, radius)
    cy0, cy1 = cell_range(ix.y0, ix.cell, ix.ny, qy, radius)
    @inbounds for cy in cy0:cy1, cx in cx0:cx1
        c = cy * ix.nx + cx + 1
        for j in ix.start[c]:(ix.start[c+1]-1)
            i = Int(ix.ids[j])
            dx, dy = Float64(pts.x[i]) - qx, Float64(pts.y[i]) - qy
            d2 = dx * dx + dy * dy
            if d2 <= bd2
                best = i
                bd2 = d2
            end
        end
    end
    best == 0 && return nothing
    k = searchsortedlast(pts.part_first, Int32(best - 1))
    li = Int(pts.part_line[k])
    row = Int(pts.part_row[k]) + (best - 1 - Int(pts.part_first[k]))
    return NearPoint(li, row, pts.origin[1] + pts.x[best], pts.origin[2] + pts.y[best], pts.value[best], sqrt(bd2))
end

# The cells that a disc of `radius` around `q` can touch, clamped to the grid.
@inline function cell_range(lo::Float64, cell::Float64, n::Int, q::Float64, radius::Real)
    a = clamp(floor((q - radius - lo) / cell), 0.0, n - 1.0)
    b = clamp(floor((q + radius - lo) / cell), 0.0, n - 1.0)
    return Int(a), Int(b)
end

"""
    cursor_point(d, line_index, row) -> Union{Nothing,NTuple{2,Float64}}

The world position of row `row` of line `line_index`, or `nothing` when it is not a good point.
"""
function cursor_point(d::LineLayerData, line_index::Integer, row::Integer)::Union{Nothing,NTuple{2,Float64}}
    p = d.points
    k = searchsortedfirst(p.part_line, line_index)
    @inbounds while k <= length(p.part_line) && p.part_line[k] == line_index
        off = row - Int(p.part_row[k])
        if 0 <= off < p.part_count[k]
            i = Int(p.part_first[k]) + off + 1
            return (p.origin[1] + p.x[i], p.origin[2] + p.y[i])
        end
        k += 1
    end
    return nothing
end

"""
    label_points!(out, d)

Fill `out` with `(line_index, x, y)`, the first point of the first part of each line.
"""
function label_points!(out::Vector{Tuple{Int,Float64,Float64}}, d::LineLayerData)
    empty!(out)
    p = d.points
    last_line = 0
    @inbounds for k in eachindex(p.part_line)
        li = Int(p.part_line[k])
        li == last_line && continue
        last_line = li
        i = Int(p.part_first[k]) + 1
        push!(out, (li, p.origin[1] + p.x[i], p.origin[2] + p.y[i]))
    end
    return out
end
