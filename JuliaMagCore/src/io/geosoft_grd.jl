# Geosoft Oasis montaj grids (`.grd`, version 2).
#
# The byte layout is in `docs/research/geosoft-grd-format.md`, sections 1 to 3.
# A file is a 512-byte little-endian header and then NV vectors of NE values.
# With KX = 1 a vector is a row going east, and the first vector is the south
# row. With KX = -1 a vector is a column going north, and the first vector is
# the west column. Either way the first value sits at (X0, Y0).
#
# Real value = stored / ZMULT + ZBASE. A dummy is masked before the scaling.
# Compressed grids (ES > 1024) are read by `read_geosoft_grd_compressed`, from
# section 4.

using CodecZlib: ZlibDecompressorStream, ZlibError

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
    read_geosoft_grd(s, path, settings, progress; header = open(read_grd_header, path), crs = "",
                     warnings = ImportWarning[]) -> ImportResult

Import a Geosoft grid as a grid item named after the file. Pass the job's
progress, so the import can be cancelled. `crs` is the coordinate system of the
grid (the file itself has none), and `warnings` go into the job report. An
uncompressed grid is read here, a block of whole vectors at a time. A
compressed grid goes to `read_geosoft_grd_compressed`.

The grid is `Float32` when the file holds 8 or 16 bit integers or `Float32`
values and is not scaled (`ZMULT = 1`, `ZBASE = 0`). Every other grid is
`Float64`. A file with fewer data bytes than the header says fails; a longer
file is fine.
"""
function read_geosoft_grd(s::Session, path::AbstractString, settings::AbstractDict, progress::Progress;
                          header::GrdHeader = open(read_grd_header, String(path)), crs::AbstractString = "",
                          warnings::Vector{ImportWarning} = ImportWarning[])::ImportResult
    path = String(path)
    header.compressed && return read_geosoft_grd_compressed(s, path, settings, progress, header; crs, warnings)
    m = (header.es * header.ne) * header.nv
    n = filesize(path) - GRD_HEADER_BYTES
    n >= m || throw(GridError("the file ends after $(max(n, 0)) of $m data bytes"))
    return import_grd(s, path, header, "", progress; crs, warnings) do sink, h
        open(io -> read_grd_vectors!(sink, io, h, grd_eltype(h)), path)
    end
end

"The signature at the start of the compression header (bytes `c7 d8 e7 f8`)."
const GRD_SIGNATURE = 0xF8E7D8C7
"The size of the header before each compressed block."
const GRD_BLOCK_HEADER_BYTES = 16

"""
    read_geosoft_grd_compressed(s, path, settings, progress, header; crs = "", warnings = ImportWarning[]) -> ImportResult

Import a compressed Geosoft grid (research section 4). After the 512-byte header
comes a 16-byte compression header (signature, compression type, block count
`NB`, vectors per block `VPB`), then `NB` 8-byte block offsets and `NB` 4-byte
block sizes. Each block is a 16-byte block header and then its payload. Block
`k` holds vectors `(k - 1) * VPB + 1` on, and the last block may hold fewer.

The codec is picked by the payload, not by the type fields, whose labels look
swapped in real files: a payload that starts with a zlib header (`0x78`) is
inflated, any other fails. One block is read at a time, and its values are put
a block of vectors at a time. Every offset and size in the file is checked
against the file size before it is used.
"""
function read_geosoft_grd_compressed(s::Session, path::String, ::AbstractDict, progress::Progress,
                                     header::GrdHeader; crs::AbstractString = "",
                                     warnings::Vector{ImportWarning} = ImportWarning[])::ImportResult
    blocks = open(io -> read_grd_block_table(io, header, filesize(path)), path)
    return import_grd(s, path, header, "zlib", progress; crs, warnings) do sink, h
        open(io -> read_grd_blocks!(sink, io, h, grd_eltype(h), blocks), path)
    end
end

"""
Read and check the compression header and block table of the grid `h` from
`io`, a file of `fsize` bytes. Returns the `(offset, size)` of each block that
holds vectors, and the number of vectors per block.
"""
function read_grd_block_table(io::IO, h::GrdHeader, fsize::Int)::Tuple{Vector{Tuple{Int,Int}},Int}
    seek(io, GRD_HEADER_BYTES)
    b = read(io, 16)
    length(b) == 16 || throw(GridError("the file ends before the 16-byte compression header"))
    sig = grd_field(UInt32, b, 0)
    sig == GRD_SIGNATURE ||
        throw(GridError("the compressed data does not start with the Geosoft compression signature " *
                        "(found 0x$(string(sig; base = 16, pad = 8))). The file is damaged or not a Geosoft grid."))
    nb, vpb = Int(grd_field(Int32, b, 8)), Int(grd_field(Int32, b, 12))
    nb >= 1 && vpb >= 1 ||
        throw(GridError("the compression header gives NB = $nb blocks of VPB = $vpb vectors; both must be at least 1"))
    first_block = GRD_HEADER_BYTES + 16 + 12nb
    first_block <= fsize || throw(GridError("the table of $nb blocks goes past the end of the file ($fsize bytes)"))
    nb * vpb >= h.nv ||
        throw(GridError("the $nb blocks of $vpb vectors hold $(nb * vpb) vectors, fewer than the $(h.nv) of the grid"))
    t = read(io, 12nb)
    es = sizeof(grd_eltype(h))
    blocks = Tuple{Int,Int}[]
    for k in 1:cld(h.nv, vpb)              # blocks past the last vector are not read
        o = Int(grd_field(Int64, t, 8(k - 1)))
        c = Int(grd_field(Int32, t, 8nb + 4(k - 1)))
        o >= first_block ||
            throw(GridError("block $k starts at byte $o, inside the header or the block table"))
        c >= GRD_BLOCK_HEADER_BYTES ||
            throw(GridError("block $k is $c bytes, less than its $GRD_BLOCK_HEADER_BYTES-byte header"))
        c <= fsize - o ||
            throw(GridError("block $k starts at byte $o and is $c bytes long, past the end of the file ($fsize bytes)"))
        # zlib expands data at most about 1032 times, so a small block cannot
        # hold a big grid. This keeps a tiny damaged file from making a huge grid.
        n = min(vpb, h.nv - (k - 1) * vpb)
        n * h.ne * es <= 1032 * (c - GRD_BLOCK_HEADER_BYTES) ||
            throw(GridError("block $k is too small to hold $n vectors of $(h.ne) values; the file is damaged"))
        push!(blocks, (o, c))
    end
    return blocks, vpb
end

"""
Read the blocks of a compressed grid from `io` into the sink, one block at a
time. `T` is the stored type; `blocks` is from `read_grd_block_table`.
"""
function read_grd_blocks!(sink::GridSink, io::IO, h::GrdHeader, ::Type{T},
                          (blocks, vpb)::Tuple{Vector{Tuple{Int,Int}},Int}) where {T}
    payload = UInt8[]
    for (k, (o, c)) in enumerate(blocks)
        seek(io, o + GRD_BLOCK_HEADER_BYTES)
        resize!(payload, c - GRD_BLOCK_HEADER_BYTES)
        got = readbytes!(io, payload, length(payload))
        got == length(payload) || throw(GridError("the file ends inside block $k"))
        isempty(payload) && throw(GridError("block $k holds no data"))
        payload[1] == 0x78 ||
            throw(GridError("block $k uses a compression JuliaMag cannot read yet (probably LZRW1, Oasis \"COMP=SPEED\"). " *
                            "Save the grid again in Oasis with size compression or no compression."))
        v1 = (k - 1) * vpb + 1
        nv = min(vpb, h.nv - v1 + 1)
        want = nv * h.ne * sizeof(T)
        z = ZlibDecompressorStream(IOBuffer(payload); stop_on_end = true)
        try
            put_grd_vectors!(sink, z, h, T, v1, nv,
                             n -> "block $k inflates to $n of the $want bytes it must hold")
            # Read to the end of the stream, so its checksum is checked. Any
            # values after the grid's own are dummy padding, up to VPB vectors.
            pad = (vpb - nv) * h.ne * sizeof(T)
            while !eof(z)
                pad -= bytesavailable(z)
                pad >= 0 || throw(GridError("block $k inflates to more than its $vpb vectors of $(h.ne) values"))
                skip(z, bytesavailable(z))
            end
        catch e
            e isa ZlibError || rethrow()
            throw(GridError("block $k is damaged: its zlib data cannot be inflated ($(e.msg))"))
        finally
            close(z)
        end
    end
    return nothing
end

"""
Import the grid of header `h` with `fill_grid!(sink, h)`, which puts every vector.
`compression` is recorded in the grid source. `crs` is the coordinate system of
the grid, and `warnings` go into the job report.
"""
function import_grd(fill_grid!::F, s::Session, path::String, h::GrdHeader, compression::String,
                    progress::Progress; crs::AbstractString = "",
                    warnings::Vector{ImportWarning} = ImportWarning[])::ImportResult where {F}
    T = grd_eltype(h)
    O = grid_eltype(T, h.zmult != 1 || h.zbase != 0)
    rows = h.kx == 1
    nx, ny = rows ? (h.ne, h.nv) : (h.nv, h.ne)
    dx, dy = rows ? (h.de, h.dv) : (h.dv, h.de)
    source = GridSource(path, "Geosoft GRD", lowercase(string(T)), compression)
    header = GridHeader(nx, ny, dx, dy, h.x0, h.y0, h.rot, String(crs), "", O, source)
    file = basename(path)
    name = lowercase(file_extension(file)) == ".grd" ? String(chop(file; tail = 4)) : file
    r = import_grid(sink -> fill_grid!(sink, h), s, name, header; warnings, progress)
    isempty(h.label) && return r
    return ImportResult(r.item, r.warnings, r.rows, r.lines, "$(r.summary), label \"$(h.label)\"")
end

"""
Read the `NV` vectors of an uncompressed grid from `io` (just after the header)
into the sink, a block of whole vectors at a time. `T` is the stored type.
"""
function read_grd_vectors!(sink::GridSink, io::IO, h::GrdHeader, ::Type{T}) where {T}
    seek(io, GRD_HEADER_BYTES)
    total = h.ne * h.nv * sizeof(T)
    put_grd_vectors!(sink, io, h, T, 1, h.nv, n -> "the file ends after $n of $total data bytes")
    return nothing
end

"""
Read `nv` vectors of stored type `T` from `io` and put them into the sink as
vectors `v1` on, a block of whole vectors at a time. When `io` ends early, fail
with `short(n)`, the message for `n` bytes read.
"""
function put_grd_vectors!(sink::GridSink, io::IO, h::GrdHeader, ::Type{T}, v1::Int, nv::Int,
                          short::F) where {T,F}
    O = sink.grid.eltype
    k = max(1, GRID_BLOCK_BYTES ÷ (h.ne * max(sizeof(T), sizeof(O))))
    raw = Vector{UInt8}(undef, h.ne * min(k, nv) * sizeof(T))
    done = 0
    while done < nv
        n = min(k, nv - done)
        nb = h.ne * n * sizeof(T)
        got = readbytes!(io, raw, nb)
        got == nb || throw(GridError(short(done * h.ne * sizeof(T) + got)))
        out = grd_values(O, reinterpret(T, view(raw, 1:nb)), h.ne, n, h.zbase, h.zmult)
        h.kx == 1 ? put_rows!(sink, v1 + done, out) : put_columns!(sink, v1 + done, out)
        done += n
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
