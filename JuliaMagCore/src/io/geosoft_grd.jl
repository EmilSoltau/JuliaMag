# Geosoft Oasis montaj grids (`.grd`, version 2).
#
# The byte layout is in `docs/research/geosoft-grd-format.md`, sections 1 to 3.
# A file is a 512-byte little-endian header and then NV vectors of NE values.
# With KX = 1 a vector is a row going east, and the first vector is the south
# row. With KX = -1 a vector is a column going north, and the first vector is
# the west column. Either way the first value sits at (X0, Y0).
#
# Real value = stored / ZMULT + ZBASE. A dummy is masked before the scaling.
# Compressed grids (ES > 1024) are read by `read_geosoft_grd_compressed`.

"The 512-byte header of a Geosoft grid. `es` keeps the compression flag (1024, bit 0x400)."
struct GrdHeader
    es::Int
    sf::Int
    ne::Int
    nv::Int
    kx::Int
    de::Float64
    dv::Float64
    x0::Float64
    y0::Float64
    rot::Float64
    zbase::Float64
    zmult::Float64
    label::String
    compressed::Bool
end

const GRD_HEADER_BYTES = 512
const GRD_COMPRESSED = 1024

"The element type of size `es` (1, 2, 4 or 8) and sign flag `sf`, or `nothing` when the format has none."
function grd_type(es::Int, sf::Int)::Union{Nothing,DataType}
    sf == 0 && return es == 1 ? UInt8 : es == 2 ? UInt16 : es == 4 ? UInt32 : nothing
    sf == 1 && return es == 1 ? Int8 : es == 2 ? Int16 : es == 4 ? Int32 : nothing
    sf == 2 && return es == 4 ? Float32 : es == 8 ? Float64 : nothing
    return nothing
end

"The stored element type of a grid, from `ES` and `SF`."
grd_eltype(h::GrdHeader)::DataType = grd_type(h.es & ~GRD_COMPRESSED, h.sf)::DataType

"""
    grd_dummy(T)

The value that marks a cell with no value in a Geosoft grid of type `T`.
A float value at or below the dummy is a dummy too.
"""
grd_dummy(::Type{Int8}) = Int8(-127)
grd_dummy(::Type{UInt8}) = UInt8(255)
grd_dummy(::Type{Int16}) = Int16(-32767)
grd_dummy(::Type{UInt16}) = UInt16(65535)
grd_dummy(::Type{Int32}) = Int32(-2147483647)
grd_dummy(::Type{UInt32}) = UInt32(4294967295)
grd_dummy(::Type{Float32}) = Float32(-1.0e32)
grd_dummy(::Type{Float64}) = -1.0e32

"True when `v` is the dummy of its type."
is_grd_dummy(v::Integer) = v == grd_dummy(typeof(v))
is_grd_dummy(v::AbstractFloat) = v <= grd_dummy(typeof(v))

"A little-endian value of type `T` at byte `off` (from 0) of `b`."
grd_field(::Type{T}, b::Vector{UInt8}, off::Int) where {T} =
    ltoh(only(reinterpret(T, b[off + 1:off + sizeof(T)])))

"The text of a header field: up to the first zero byte, without trailing spaces."
function grd_text(b::AbstractVector{UInt8})::String
    k = findfirst(==(0x00), b)
    bytes = k === nothing ? b : b[1:k - 1]
    s = String(copy(bytes))
    isvalid(s) || (s = String(map(Char, bytes)))   # Latin-1 text
    return String(strip(s))
end

"""
    read_grd_header(io)::GrdHeader

Read the 512-byte header of a Geosoft grid from `io`. Throws `GridError` with a
plain message when the header is not one JuliaMag can read. The statistics
fields (`IZMIN` and the others, `ZVAR`, `NVPTS`) are not read: real files often
hold wrong values there.
"""
function read_grd_header(io::IO)::GrdHeader
    b = read(io, GRD_HEADER_BYTES)
    n = length(b)
    n == GRD_HEADER_BYTES ||
        throw(GridError("the file is $n bytes, shorter than the 512-byte header of a Geosoft grid"))
    i32(off) = Int(grd_field(Int32, b, off))
    f64(off) = grd_field(Float64, b, off)
    es, sf, ne, nv, kx = i32(0), i32(4), i32(8), i32(12), i32(16)
    de, dv, x0, y0, rot, zbase, zmult = f64(20), f64(28), f64(36), f64(44), f64(52), f64(60), f64(68)
    compressed = es & GRD_COMPRESSED != 0
    bytes = es & ~GRD_COMPRESSED
    es in (1, 2, 4, 8, 1025, 1026, 1028, 1032) ||
        throw(GridError("the header gives an element size of ES = $es; a Geosoft grid uses 1, 2, 4 or 8 (plus 1024 when compressed)"))
    sf == 3 && throw(GridError("this Geosoft grid is a colour grid (SF = 3). A colour grid holds colours, not values."))
    grd_type(bytes, sf) === nothing &&
        throw(GridError("$bytes-byte values with sign flag SF = $sf are not a Geosoft grid type"))
    kx in (1, -1) ||
        throw(GridError("the grid stores its values in order KX = $kx. Only KX = 1 (by rows) and KX = -1 (by columns) are used by Geosoft."))
    ne >= 1 || throw(GridError("the header gives NE = $ne values per vector; it must be at least 1"))
    nv >= 1 || throw(GridError("the header gives NV = $nv vectors; it must be at least 1"))
    de > 0 || throw(GridError("the header gives a spacing DE = $de; it must be above 0"))
    dv > 0 || throw(GridError("the header gives a spacing DV = $dv; it must be above 0"))
    # The values, and the grid JuliaMag stores (up to 8 bytes a cell), must fit
    # a file size. Computed in Int128, so a huge header cannot wrap around.
    Int128(ne) * nv * max(bytes, 8) + GRD_HEADER_BYTES <= typemax(Int) ||
        throw(GridError("the header gives $ne by $nv cells, more than any file can hold"))
    zmult == 0 && throw(GridError("the header gives ZMULT = 0, so the values cannot be scaled"))
    all(isfinite, (de, dv, x0, y0, rot, zbase, zmult)) ||
        throw(GridError("the header gives a spacing, position, rotation or scaling that is not a finite number"))
    label = grd_text(view(b, 77:124))
    return GrdHeader(es, sf, ne, nv, kx, de, dv, x0, y0, rot, zbase, zmult, label, compressed)
end

"""
    read_geosoft_grd(s, path, settings, progress; header = open(read_grd_header, path)) -> ImportResult

Import a Geosoft grid as a grid item named after the file. Pass the job's
progress, so the import can be cancelled. An uncompressed grid is read here, a
block of whole vectors at a time. A compressed grid goes to
`read_geosoft_grd_compressed`.

The grid is `Float32` when the file holds 8 or 16 bit integers or `Float32`
values and is not scaled (`ZMULT = 1`, `ZBASE = 0`). Every other grid is
`Float64`. A file with fewer data bytes than the header says fails; a longer
file is fine.
"""
function read_geosoft_grd(s::Session, path::AbstractString, settings::AbstractDict, progress::Progress;
                          header::GrdHeader = open(read_grd_header, String(path)))::ImportResult
    path = String(path)
    header.compressed && return read_geosoft_grd_compressed(s, path, settings, progress, header)
    m = (header.es * header.ne) * header.nv
    n = filesize(path) - GRD_HEADER_BYTES
    n >= m || throw(GridError("the file ends after $(max(n, 0)) of $m data bytes"))
    return import_grd(s, path, header, "", progress) do sink, h
        open(io -> read_grd_vectors!(sink, io, h, grd_eltype(h)), path)
    end
end

"""
    read_geosoft_grd_compressed(s, path, settings, progress, header) -> ImportResult

Import a compressed Geosoft grid. Not supported yet.
"""
read_geosoft_grd_compressed(::Session, ::String, ::AbstractDict, ::Progress, ::GrdHeader)::ImportResult =
    throw(GridError("compressed Geosoft grids are not supported yet"))

"""
Import the grid of header `h` with `fill_grid!(sink, h)`, which puts every vector.
`compression` is recorded in the grid source.
"""
function import_grd(fill_grid!::F, s::Session, path::String, h::GrdHeader, compression::String,
                    progress::Progress)::ImportResult where {F}
    T = grd_eltype(h)
    O = grid_eltype(T, h.zmult != 1 || h.zbase != 0)
    rows = h.kx == 1
    nx, ny = rows ? (h.ne, h.nv) : (h.nv, h.ne)
    dx, dy = rows ? (h.de, h.dv) : (h.dv, h.de)
    source = GridSource(path, "Geosoft GRD", lowercase(string(T)), compression)
    header = GridHeader(nx, ny, dx, dy, h.x0, h.y0, h.rot, "", "", O, source)
    file = basename(path)
    name = lowercase(file_extension(file)) == ".grd" ? String(chop(file; tail = 4)) : file
    r = import_grid(sink -> fill_grid!(sink, h), s, name, header; progress)
    isempty(h.label) && return r
    return ImportResult(r.item, r.warnings, r.rows, r.lines, "$(r.summary), label \"$(h.label)\"")
end

"""
Read the `NV` vectors of an uncompressed grid from `io` (just after the header)
into the sink, a block of whole vectors at a time. `T` is the stored type.
"""
function read_grd_vectors!(sink::GridSink, io::IO, h::GrdHeader, ::Type{T}) where {T}
    seek(io, GRD_HEADER_BYTES)
    O = sink.grid.eltype
    k = max(1, GRID_BLOCK_BYTES ÷ (h.ne * max(sizeof(T), sizeof(O))))
    raw = Vector{UInt8}(undef, h.ne * min(k, h.nv) * sizeof(T))
    total = h.ne * h.nv * sizeof(T)
    v1 = 1
    while v1 <= h.nv
        nv = min(k, h.nv - v1 + 1)
        nb = h.ne * nv * sizeof(T)
        got = readbytes!(io, raw, nb)
        got == nb || throw(GridError("the file ends after $((v1 - 1) * h.ne * sizeof(T) + got) of $total data bytes"))
        stored = reinterpret(T, view(raw, 1:nb))
        out = grd_values(O, stored, h.ne, nv, h.zbase, h.zmult)
        h.kx == 1 ? put_rows!(sink, v1, out) : put_columns!(sink, v1, out)
        v1 += nv
    end
    return nothing
end

"""
The real values of `ne * nv` stored values as an `ne` by `nv` matrix of type
`O`: dummies become `NaN`, the rest are scaled.
"""
function grd_values(::Type{O}, stored::AbstractVector{T}, ne::Int, nv::Int, zbase::Float64,
                    zmult::Float64)::Matrix{O} where {O,T}
    out = Matrix{O}(undef, ne, nv)
    @inbounds for k in eachindex(out, stored)
        v = ltoh(stored[k])
        out[k] = is_grd_dummy(v) ? O(NaN) : O(Float64(v) / zmult + zbase)
    end
    return out
end
