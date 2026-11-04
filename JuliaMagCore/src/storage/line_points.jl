# Line positions in bulk, for the map.
#
# `read_line_points` reads X, Y and a value channel of every line with plain
# reads in blocks (see `block_reader`), never a memory map, so the map does not
# block an undo or an append on Windows. It runs on a background task and fills
# arrays the caller keeps, so a second read allocates next to nothing. Every
# loop over values runs in a function with concrete argument types (`pack_block!`).

"Rows read at once by `read_line_points`."
const LINE_POINTS_BLOCK = 1 << 16

"""
Positions of the good points of all lines of a database, as Float32 offsets from
`origin` (see `read_line_points`). The points of a line come in parts, one per
run of good points. Part `k` holds points `part_first[k] + 1` to
`part_first[k] + part_count[k]`.
It keeps its block buffers between reads: about 2 MB of scratch, and up to 1.5 MB of
reader buffers for Float64 channels, once a line has $(LINE_POINTS_BLOCK) rows or more.
"""
mutable struct LinePoints
    origin::NTuple{2,Float64}
    x::Vector{Float32}
    y::Vector{Float32}
    value::Vector{Float32}
    "0-based index of the first point of each part."
    part_first::Vector{Int32}
    part_count::Vector{Int32}
    "Index into `lines` of the line of each part."
    part_line::Vector{Int32}
    "Row of the first point of each part, from 1."
    part_row::Vector{Int32}
    lines::Vector{LineId}
    "`(xmin, ymin, xmax, ymax)` of the good points of each line, all NaN for none."
    extents::Vector{NTuple{4,Float64}}
    "Block buffers kept between reads, so a second read allocates next to nothing."
    scratch::Vector{Vector{Float64}}
    reader_bufs::Vector{Any}
end

LinePoints() = LinePoints((0.0, 0.0), Float32[], Float32[], Float32[], Int32[], Int32[], Int32[], Int32[],
                          LineId[], NTuple{4,Float64}[], [Float64[] for _ in 1:4], Any[nothing, nothing, nothing])

# Lend a reader the block buffer of the last read when it has the right type.
function borrow_buffer!(r::NumericBlockReader, p::LinePoints, slot::Int)
    b = p.reader_bufs[slot]
    b isa typeof(r.buf) && (r.buf = b)
    return nothing
end

function borrow_buffer!(::BlockReader, ::LinePoints, ::Int)
    return nothing
end

function return_buffers!(p::LinePoints, readers::Vector{BlockReader})
    for (k, r) in enumerate(readers)
        r isa NumericBlockReader && (p.reader_bufs[k] = r.buf)
    end
    return nothing
end

# Where the block loop is: the points so far and the run it is in.
mutable struct PackState
    n::Int                # points stored
    have_origin::Bool
    ox::Float64
    oy::Float64
    in_run::Bool          # the previous row was a good point of this line
    xmin::Float64
    ymin::Float64
    xmax::Float64
    ymax::Float64
end

# The channels are checked numeric, so this only narrows the type of a block.
numeric_block(b::AbstractVector{<:Real}) = b
numeric_block(::Any) = throw(DatabaseError("a block of rows is not a vector of numbers"))

block_float(v::AbstractFloat) = Float64(v)
block_float(v::Union{Signed,Unsigned}) = ismissingvalue(v) ? NaN : Float64(v)

"Fill `wx`, `wy` with the rows as Float64, NaN for a missing value."
function widen_block!(wx::Vector{Float64}, wy::Vector{Float64}, xs::AbstractVector, ys::AbstractVector)
    @inbounds for k in eachindex(xs, ys)
        wx[k] = block_float(xs[k])
        wy[k] = block_float(ys[k])
    end
    return nothing
end

block_value(v::AbstractFloat) = Float32(v)
block_value(v::Union{Signed,Unsigned}) = ismissingvalue(v) ? NaN32 : Float32(v)

"""
Store the good points among the first `n` world coordinates of a block that starts at
row `row0` of line `li`. `vs` is the value block or `nothing`. Allocates only when
the arrays grow.
"""
function pack_block!(p::LinePoints, st::PackState, wx::Vector{Float64}, wy::Vector{Float64},
                     vs::Union{Nothing,AbstractVector}, n::Int, li::Int, row0::Int)
    @inbounds for k in 1:n
        px, py = wx[k], wy[k]
        if !(isfinite(px) && isfinite(py))
            st.in_run = false
            continue
        end
        if !st.have_origin
            st.have_origin = true
            st.ox, st.oy = floor(px), floor(py)
            p.origin = (st.ox, st.oy)
        end
        if !st.in_run
            push!(p.part_first, Int32(st.n))
            push!(p.part_count, Int32(0))
            push!(p.part_line, Int32(li))
            push!(p.part_row, Int32(row0 + k - 1))
            st.in_run = true
        end
        p.part_count[end] += Int32(1)
        st.n += 1
        p.x[st.n] = Float32(px - st.ox)
        p.y[st.n] = Float32(py - st.oy)
        p.value[st.n] = vs === nothing ? NaN32 : block_value(vs[k])
        if isnan(st.xmin)
            st.xmin = st.xmax = px
            st.ymin = st.ymax = py
        else
            st.xmin = min(st.xmin, px); st.xmax = max(st.xmax, px)
            st.ymin = min(st.ymin, py); st.ymax = max(st.ymax, py)
        end
    end
    return nothing
end

"""
The lines of a database as they were at one moment: the line records, their
row counts, and which were still being appended. `read_line_points` sizes its
arrays and fills them from one snapshot, so a line that ends or is added while
it reads cannot make it write past the arrays.
"""
struct LineSnapshot
    lines::Vector{LineInfo}
    nrows::Vector{Int}
    open::Vector{Bool}
end

function line_snapshot(db::LineDatabase)::LineSnapshot
    lines = copy(db.lines)
    return LineSnapshot(lines, [l.nrows for l in lines], [is_open_line(db, l) for l in lines])
end

function numeric_channel(db::LineDatabase, name::AbstractString)::ChannelInfo
    channel_position(db, name) == 0 && throw(ArgumentError("there is no channel $name in database $(db.name)"))
    c = channel(db, name)
    (c.eltype <: Union{AbstractFloat,Signed,Unsigned} && c.arraylen == 1) || throw(ArgumentError(
        "channel $(c.name) must be a numeric channel with one value per row"))
    return c
end

"""
    read_line_points(db, x, y, value = nothing; into = LinePoints(), reproject = nothing)::LinePoints

Read channels `x` and `y` (and `value`, which may be missing) of every line of `db`
into `into`, which is filled and returned. A point is good when X and Y are not
missing and, after `reproject`, finite. A line still being appended is skipped.
Throws `ArgumentError` for a channel that is missing, or not numeric with one value per row.
After any throw, `into` may be half filled: read into it again before using it.
"""
function read_line_points(db::LineDatabase, x::AbstractString, y::AbstractString,
                          value::Union{Nothing,AbstractString} = nothing;
                          into::LinePoints = LinePoints(),
                          reproject::Union{Nothing,Reprojector} = nothing)::LinePoints
    foreach(c -> numeric_channel(db, c), (x, y))
    value === nothing || numeric_channel(db, value)
    return read_snapshot!(into, db, line_snapshot(db), x, y, value, reproject)
end

# Fill `p` with the lines of `snap`. After a throw, `p` may be half filled.
function read_snapshot!(p::LinePoints, db::LineDatabase, snap::LineSnapshot, x::AbstractString,
                        y::AbstractString, value::Union{Nothing,AbstractString},
                        reproject::Union{Nothing,Reprojector})::LinePoints
    lines = snap.lines
    total = sum(k -> snap.open[k] ? 0 : snap.nrows[k], eachindex(lines); init = 0)
    resize!(p.x, total); resize!(p.y, total); resize!(p.value, total)
    foreach(empty!, (p.part_first, p.part_count, p.part_line, p.part_row))
    resize!(p.lines, length(lines)); resize!(p.extents, length(lines))
    p.origin = (0.0, 0.0)
    readers = BlockReader[]
    try
        for name in (x, y, value)
            name === nothing && continue
            r = block_reader(db, name)
            push!(readers, r)
            borrow_buffer!(r, p, length(readers))
        end
        fill_line_points!(p, snap, readers, reproject)
    finally
        return_buffers!(p, readers)
        foreach(close, readers)
    end
    return p
end

function fill_line_points!(p::LinePoints, snap::LineSnapshot, readers::Vector{BlockReader},
                           reproject::Union{Nothing,Reprojector})
    st = PackState(0, false, 0.0, 0.0, false, NaN, NaN, NaN, NaN)
    nb = min(LINE_POINTS_BLOCK, maximum(snap.nrows; init = 0))
    wx, wy, rx, ry = p.scratch
    foreach(b -> length(b) < nb && resize!(b, nb), p.scratch)
    for (li, l) in enumerate(snap.lines)
        p.lines[li] = l.id
        st.in_run = false
        st.xmin = st.ymin = st.xmax = st.ymax = NaN
        if !snap.open[li]
            row = 1
            while row <= snap.nrows[li]
                rows = row:min(row + LINE_POINTS_BLOCK - 1, snap.nrows[li])
                xs = numeric_block(read_block(readers[1], l, rows))
                ys = numeric_block(read_block(readers[2], l, rows))
                vs = length(readers) > 2 ? numeric_block(read_block(readers[3], l, rows)) : nothing
                transform_block!(wx, wy, rx, ry, xs, ys, reproject)
                pack_block!(p, st, wx, wy, vs, length(rows), li, row)
                row = last(rows) + 1
            end
        end
        p.extents[li] = (st.xmin, st.ymin, st.xmax, st.ymax)
    end
    resize!(p.x, st.n); resize!(p.y, st.n); resize!(p.value, st.n)
    return nothing
end

# Barrier: the block types are concrete here.
function transform_block!(wx, wy, rx, ry, xs::AbstractVector, ys::AbstractVector, ::Nothing)
    widen_block!(wx, wy, xs, ys)
    return nothing
end

function transform_block!(wx, wy, rx, ry, xs::AbstractVector, ys::AbstractVector, r::Reprojector)
    n = length(xs)
    widen_block!(rx, ry, xs, ys)
    reproject!(r, view(rx, 1:n), view(ry, 1:n), view(wx, 1:n), view(wy, 1:n))
    return nothing
end
