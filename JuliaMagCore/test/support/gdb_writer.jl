# A writer of small Geosoft databases (`.gdb`) for tests and the bench.
# It follows the byte layout of `docs/research/geosoft-gdb-format.md`,
# sections 3 to 6. JuliaMag itself never writes a `.gdb` file.

using CodecZlib: ZlibCompressor, transcode

"One channel record of a test database. `type` is a Geosoft `GS_*` code, or minus the width of a string."
Base.@kwdef struct TestChannel
    name::String
    type::Int = 5
    arraylen::Int = 1
    format::Int = 0
    width::Int = 10
    decimals::Int = 2
    flags::Int = 2
    deleted::Bool = false
end

"One line record of a test database. `type` is the Geosoft line type code (0 `L` ... 6 `D`)."
Base.@kwdef struct TestLine
    name::String
    number::Int = 0
    type::Int = 0
    version::Int = 0
    flight::Int = 0
    date::Float64 = 0.0
    category::Int = 100
end

"The data of one channel on one line. `pack` is `:none`, `:zlib`, `:lzrw1` or `:lzrw1_stored`."
Base.@kwdef struct TestBlob
    values::AbstractVector
    fid_start::Float64 = 0.0
    fid_step::Float64 = 1.0
    pack::Symbol = :none
end

"The Julia type that a Geosoft type code stores."
function test_gdb_eltype(code::Int)::DataType
    code < 0 && return String
    return (Int8, UInt16, Int16, Int32, Float32, Float64, UInt8, UInt32, Int64, UInt64)[code + 1]
end

"The stored bytes of `values` for the Geosoft type `code`."
function test_gdb_value_bytes(values::AbstractVector, code::Int)::Vector{UInt8}
    if code < 0
        w = -code
        out = zeros(UInt8, w * length(values))
        for (k, v) in enumerate(values)
            b = v isa AbstractVector{UInt8} ? v : Vector{UInt8}(codeunits(String(v)))
            out[(k - 1) * w + 1:(k - 1) * w + min(w, length(b))] = b[1:min(w, length(b))]
        end
        return out
    end
    T = test_gdb_eltype(code)
    return Vector{UInt8}(reinterpret(UInt8, htol.(T.(values))))
end

put_i32!(b::Vector{UInt8}, off::Int, v::Integer) = (b[off + 1:off + 4] = reinterpret(UInt8, [htol(Int32(v))]); b)
put_u32!(b::Vector{UInt8}, off::Int, v::Integer) = (b[off + 1:off + 4] = reinterpret(UInt8, [htol(UInt32(v))]); b)
put_i16!(b::Vector{UInt8}, off::Int, v::Integer) = (b[off + 1:off + 2] = reinterpret(UInt8, [htol(Int16(v))]); b)
put_u16!(b::Vector{UInt8}, off::Int, v::Integer) = (b[off + 1:off + 2] = reinterpret(UInt8, [htol(UInt16(v))]); b)
put_f64!(b::Vector{UInt8}, off::Int, v::Real) = (b[off + 1:off + 8] = reinterpret(UInt8, [htol(Float64(v))]); b)
put_bytes!(b::Vector{UInt8}, off::Int, x::AbstractVector{UInt8}) = (b[off + 1:off + length(x)] = x; b)
put_name!(b::Vector{UInt8}, off::Int, s::AbstractString) = put_bytes!(b, off, Vector{UInt8}(codeunits(s)))

"The chunk magic that starts the payload part of a packed blob header."
const TEST_GDB_CHUNK_MAGIC = UInt8[0x0f, 0x0e, 0xff, 0xfe, 0x12, 0x34, 0x56, 0x78]

"The bytes of a data blob (without page padding) for `b` with Geosoft type `code`."
function test_gdb_blob_bytes(b::TestBlob, code::Int, index::Int)::Vector{UInt8}
    raw = test_gdb_value_bytes(b.values, code)
    count = code < 0 ? length(b.values) : length(raw) ÷ sizeof(test_gdb_eltype(code))
    if b.pack == :none
        h = zeros(UInt8, 48)
        put_i32!(h, 20, 200)
        put_f64!(h, 24, b.fid_start)
        put_f64!(h, 32, b.fid_step)
        put_i32!(h, 40, count)
        put_i32!(h, 44, code)
        return vcat(h, raw)
    end
    if b.pack == :zlib
        stream, subtype, reserved = transcode(ZlibCompressor, raw), 2, 1
    else
        stream, subtype, reserved = test_gdb_lzrw1_chunks(raw, b.pack), 1, 0
    end
    h = zeros(UInt8, 72)
    put_i32!(h, 20, 202)
    put_i32!(h, 24, length(raw))
    put_i32!(h, 28, length(stream) + 16)
    put_f64!(h, 32, b.fid_start)
    put_f64!(h, 40, b.fid_step)
    put_i32!(h, 48, count)
    put_i32!(h, 52, code)
    put_bytes!(h, 56, TEST_GDB_CHUNK_MAGIC)
    put_i32!(h, 64, subtype)
    put_i32!(h, 68, reserved)
    return vcat(h, stream)
end

test_gdb_lzrw1_chunks(raw, pack) = error("LZRW1 packing is added with the LZRW1 compressor")

"Fill in the common blob header (magic, pages twice, index, unset time) and pad `body` to whole pages."
function test_gdb_page_blob(body::Vector{UInt8}, index::Int, page_size::Int)::Vector{UInt8}
    pages = max(1, cld(length(body), page_size))
    out = zeros(UInt8, pages * page_size)
    put_bytes!(out, 0, body)
    put_bytes!(out, 0, UInt8[0xcc, 0xcc, 0x00, 0xff])
    put_i32!(out, 4, pages)
    put_i32!(out, 8, pages)
    put_i32!(out, 12, index)
    put_u32!(out, 16, 0x80000000)
    return out
end

"""
    write_test_gdb(path; channels, lines, blob, ...)

Write a Geosoft database to `path` and return `path`. `blob(line_slot, chan_slot)`
returns a `TestBlob` or `nothing` (no directory entry). `admin` adds named admin
objects: the bytes of the whole blob, whose first 24 bytes the writer fills in.
`tweak(bytes)` gets the 256 header bytes before they are written.
The writer streams: it writes the blobs first, then seeks back for the tables.
"""
function write_test_gdb(path::AbstractString; channels::Vector{TestChannel}, lines::Vector{TestLine},
                        blob = (line_slot, chan_slot) -> nothing,
                        chans_max::Int = max(4, length(channels)), lines_max::Int = max(4, length(lines)),
                        blobs_max::Int = 16, users_max::Int = 2, cache::Int = 8, page_size::Int = 1024,
                        comp_level::Int = 0, admin = Pair{String,Vector{UInt8}}[], tweak = h -> h)
    first_admin = lines_max * chans_max
    w60 = first_admin + blobs_max + users_max
    dir_slots = w60 + cache
    blob_table = 280 + dir_slots * 6
    index_size = blob_table + (blobs_max + lines_max + chans_max + users_max) * 128
    start_page = cld(index_size, page_size)
    dir = zeros(UInt8, dir_slots * 6)
    page = 0
    open(path, "w") do io
        seek(io, start_page * page_size)
        function put_blob(index::Int, body::Vector{UInt8})
            bytes = test_gdb_page_blob(body, index, page_size)
            pages = length(bytes) ÷ page_size
            write(io, bytes)
            put_u32!(dir, index * 6, UInt32(page) | 0x80000000)
            put_u16!(dir, index * 6 + 4, pages)
            page += pages
        end
        for (ls, _) in enumerate(lines), (cs, c) in enumerate(channels)
            b = blob(ls - 1, cs - 1)
            b === nothing && continue
            index = (ls - 1) * chans_max + (cs - 1)
            put_blob(index, test_gdb_blob_bytes(b, c.type, index))
        end
        for (k, (_, bytes)) in enumerate(admin)
            body = copy(bytes)
            length(body) < 24 && append!(body, zeros(UInt8, 24 - length(body)))
            put_i32!(body, 20, 100)
            put_blob(first_admin + k - 1, body)
        end
        h = zeros(UInt8, 256)
        put_name!(h, 0, "!CBD")
        put_u32!(h, 8, 0x10020000)
        put_i32!(h, 12, 264)
        for (off, v) in ((24, chans_max), (28, blobs_max), (32, cache), (36, lines_max), (40, users_max),
                         (44, dir_slots), (48, first_admin), (52, first_admin + blobs_max), (56, w60), (60, w60),
                         (64, blobs_max + lines_max + chans_max + users_max),
                         (72, blobs_max), (76, blobs_max + lines_max), (80, blobs_max + lines_max + chans_max),
                         (84, blobs_max), (88, lines_max), (92, chans_max), (96, users_max),
                         (100, page_size), (104, index_size), (108, start_page), (112, page), (120, comp_level))
            put_i32!(h, off, v)
        end
        tables = zeros(UInt8, (blobs_max + lines_max + chans_max + users_max) * 128)
        for (k, (name, _)) in enumerate(admin)
            put_name!(tables, (k - 1) * 128, name)
        end
        l0 = blobs_max * 128
        for (k, l) in enumerate(lines)
            r = l0 + (k - 1) * 128
            put_name!(tables, r, l.name)
            put_i32!(tables, r + 76, l.category)
            put_f64!(tables, r + 84, l.date)
            put_i32!(tables, r + 92, l.number)
            put_i32!(tables, r + 96, l.type)
            put_i32!(tables, r + 100, l.flight)
            put_i32!(tables, r + 124, l.version)
        end
        c0 = l0 + lines_max * 128
        for (k, c) in enumerate(channels)
            r = c0 + (k - 1) * 128
            put_name!(tables, r, c.name)
            put_i16!(tables, r + 76, c.type)
            put_i16!(tables, r + 78, c.deleted ? c.flags | 1 : c.flags)
            put_i16!(tables, r + 84, c.format)
            put_i16!(tables, r + 86, c.width)
            put_i32!(tables, r + 88, c.decimals)
            put_f64!(tables, r + 100, 1.0)
            put_i16!(tables, r + 108, 5)
            put_i16!(tables, r + 110, c.arraylen)
        end
        put_name!(tables, c0 + chans_max * 128, "SUPER")
        seekstart(io)
        write(io, tweak(h))
        write(io, zeros(UInt8, 24))
        write(io, dir)
        write(io, tables)
    end
    return path
end

"""
    xyz_column_names(path)

The channel names of an Oasis XYZ export: the names on the last `/` comment line
before the first data row that has as many names as that row has columns.
"""
function xyz_column_names(path::AbstractString)::Vector{String}
    candidates = Vector{String}[]
    for line in eachline(path)
        s = strip(line)
        isempty(s) && continue
        if startswith(s, "/")
            names = split(lstrip(s, '/'))
            # Skip rule lines such as `/=== ===`, which have one token per column too.
            all(t -> all(in(('=', '-')), t), names) || push!(candidates, names)
            continue
        end
        first(split(s)) in ("Line", "Tie", "Base", "Test", "Trend", "Random", "L", "T", "B", "S", "R", "P", "D") &&
            length(split(s)) <= 2 && continue
        n = length(split(s))
        k = findlast(c -> length(c) == n, candidates)
        k === nothing && error("no comment line in $path names the $n columns of its first data row")
        return candidates[k]
    end
    error("$path has no data rows")
end
