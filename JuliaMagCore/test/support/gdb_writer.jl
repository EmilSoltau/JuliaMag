# A writer of small Geosoft databases (`.gdb`) for tests and the bench.
# It follows the byte layout of `docs/research/geosoft-gdb-format.md`,
# sections 3 to 6. JuliaMag itself never writes a `.gdb` file.

using CodecZlib: ZlibCompressor, transcode

"""
One channel record of a test database. `type` is a Geosoft `GS_*` code, or minus the width of a string.
`deleted` sets bit 0 of the flags. A non-empty `name_bytes` is stored as the name instead of `name`,
so a test can write a name that is not UTF-8.
"""
Base.@kwdef struct TestChannel
    name::String
    type::Int = 5
    arraylen::Int = 1
    format::Int = 0
    width::Int = 10
    decimals::Int = 2
    flags::Int = 2
    deleted::Bool = false
    name_bytes::Vector{UInt8} = UInt8[]
end

"""
One line record of a test database. `type` is the Geosoft line type code (0 `L` ... 6 `D`).
A non-empty `name_bytes` is stored as the name instead of `name`.
"""
Base.@kwdef struct TestLine
    name::String
    number::Int = 0
    type::Int = 0
    version::Int = 0
    flight::Int = 0
    date::Float64 = 0.0
    category::Int = 100
    name_bytes::Vector{UInt8} = UInt8[]
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
"Store a record name: `raw` when it is not empty, else the UTF-8 bytes of `s`."
put_name!(b::Vector{UInt8}, off::Int, s::AbstractString, raw::Vector{UInt8}) =
    isempty(raw) ? put_name!(b, off, s) : put_bytes!(b, off, raw)

"""
    test_gdb_garbage(n, seed)

`n` bytes that look like garbage (binary, mostly not printable). The same
`seed` always gives the same bytes, so the tests do not depend on luck.
"""
function test_gdb_garbage(n::Int, seed::Int)::Vector{UInt8}
    x = UInt64(0x9e3779b97f4a7c15) * UInt64(seed + 1)
    out = Vector{UInt8}(undef, n)
    for k in 1:n
        x ⊻= x << 13; x ⊻= x >> 7; x ⊻= x << 17
        out[k] = UInt8(x & 0xff)
    end
    return out
end

"""
    lzrw1_compress(data)

An LZRW1 stream (no 4-byte flag prefix) for `data`, the inverse of
`lzrw1_decode!`. Greedy, as in Ross Williams' algorithm: a 4096-entry hash
table of 3-byte prefixes, copy lengths 3 to 16, offsets 1 to 4095.
Items come in groups of 16 behind a 16-bit little-endian control word, read
least significant bit first; a set bit is a copy item. Tests only.
"""
function lzrw1_compress(data::AbstractVector{UInt8})::Vector{UInt8}
    n = length(data)
    table = zeros(Int, 4096)
    z = UInt8[]
    p = 1
    while p <= n
        ctrl_at = length(z) + 1
        append!(z, (0x00, 0x00))
        ctrl = 0x0000
        item = 0
        while item < 16 && p <= n
            len, off = 0, 0
            if p + 2 <= n
                key = (UInt32(data[p]) << 8) ⊻ (UInt32(data[p + 1]) << 4) ⊻ UInt32(data[p + 2])
                h = ((40543 * key) >> 4) & 0x0fff
                cand = table[h + 1]
                table[h + 1] = p
                off = p - cand
                if cand > 0 && off <= 4095
                    while len < 16 && p + len <= n && data[cand + len] == data[p + len]
                        len += 1
                    end
                end
            end
            if len >= 3
                push!(z, UInt8(((off >> 4) & 0xf0) | (len - 1)), UInt8(off & 0xff))
                ctrl |= 0x0001 << item
                p += len
            else
                push!(z, data[p])
                p += 1
            end
            item += 1
        end
        z[ctrl_at] = UInt8(ctrl & 0xff)
        z[ctrl_at + 1] = UInt8(ctrl >> 8)
    end
    return z
end

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

"The most bytes one LZRW1 chunk unpacks to (research section 6.3)."
const TEST_GDB_LZRW1_CHUNK = 16_368

"""
    test_gdb_lzrw1_chunks(raw, pack)

The LZRW1 chunks for `raw`, back to back, each of at most 16,368 raw bytes.
Each chunk has a 12-byte header: int32 raw length, int32 chunk length (with
the header) and a uint32 marker. `:lzrw1` packs each chunk with
`lzrw1_compress` (marker `0xF4E5D6C7`); `:lzrw1_stored` stores the bytes as
they are (marker `0xF0E1D2C3`).
"""
function test_gdb_lzrw1_chunks(raw::Vector{UInt8}, pack::Symbol)::Vector{UInt8}
    pack in (:lzrw1, :lzrw1_stored) || error("unknown packing $pack")
    out = UInt8[]
    for a in 1:TEST_GDB_LZRW1_CHUNK:length(raw)
        part = raw[a:min(a + TEST_GDB_LZRW1_CHUNK - 1, length(raw))]
        body, marker = pack == :lzrw1 ? (lzrw1_compress(part), 0xF4E5D6C7) : (part, 0xF0E1D2C3)
        h = zeros(UInt8, 12)
        put_i32!(h, 0, length(part))
        put_i32!(h, 4, 12 + length(body))
        put_u32!(h, 8, marker)
        append!(out, h, body)
    end
    return out
end

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

Damage and history, by blob index (`line_slot * chans_max + chan_slot`, or an admin index):
- `garbage_channels`: that many channel slots after the real ones hold garbage bytes with bit 0
  of the flags set, as in `7042_106_wform`.
- `stale`: a second, later copy of those blobs, with other values, that the directory does not
  point at (as the `__552` registry in AirMag).
- `dead`: those blobs are written, but their slots are not live.
- `misdirect`: those live slots point one page past their blob.
"""
function write_test_gdb(path::AbstractString; channels::Vector{TestChannel}, lines::Vector{TestLine},
                        blob = (line_slot, chan_slot) -> nothing, garbage_channels::Int = 0,
                        chans_max::Int = max(4, length(channels) + garbage_channels), lines_max::Int = max(4, length(lines)),
                        blobs_max::Int = 16, users_max::Int = 2, cache::Int = 8, page_size::Int = 1024,
                        comp_level::Int = 0, admin = Pair{String,Vector{UInt8}}[], tweak = h -> h,
                        stale::Vector{Int} = Int[], dead::Vector{Int} = Int[],
                        misdirect::Vector{Int} = Int[])
    chans_max >= length(channels) + garbage_channels || error("chans_max is too small for the garbage channels")
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
        stale_bodies = Dict{Int,Vector{UInt8}}()
        function put_blob(index::Int, body::Vector{UInt8}; in_dir::Bool = true)
            bytes = test_gdb_page_blob(body, index, page_size)
            pages = length(bytes) ÷ page_size
            write(io, bytes)
            if in_dir
                slot = index in misdirect ? page + 1 : page
                put_u32!(dir, index * 6, index in dead ? UInt32(slot) : UInt32(slot) | 0x80000000)
                put_u16!(dir, index * 6 + 4, pages)
            end
            page += pages
        end
        for (ls, _) in enumerate(lines), (cs, c) in enumerate(channels)
            b = blob(ls - 1, cs - 1)
            b === nothing && continue
            index = (ls - 1) * chans_max + (cs - 1)
            put_blob(index, test_gdb_blob_bytes(b, c.type, index))
            if index in stale
                other = c.type < 0 ? reverse(b.values) : b.values .+ 1
                stale_bodies[index] = test_gdb_blob_bytes(TestBlob(values = other, fid_start = b.fid_start,
                                                                   fid_step = b.fid_step, pack = b.pack),
                                                          c.type, index)
            end
        end
        for (k, (_, bytes)) in enumerate(admin)
            body = copy(bytes)
            length(body) < 24 && append!(body, zeros(UInt8, 24 - length(body)))
            put_i32!(body, 20, 100)
            put_blob(first_admin + k - 1, body)
            first_admin + k - 1 in stale && (stale_bodies[first_admin + k - 1] = vcat(body, UInt8[0x01]))
        end
        for index in sort!(collect(keys(stale_bodies)))
            put_blob(index, stale_bodies[index]; in_dir = false)
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
            put_name!(tables, r, l.name, l.name_bytes)
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
            put_name!(tables, r, c.name, c.name_bytes)
            put_i16!(tables, r + 76, c.type)
            put_i16!(tables, r + 78, c.deleted ? c.flags | 1 : c.flags)
            put_i16!(tables, r + 84, c.format)
            put_i16!(tables, r + 86, c.width)
            put_i32!(tables, r + 88, c.decimals)
            put_f64!(tables, r + 100, 1.0)
            put_i16!(tables, r + 108, 5)
            put_i16!(tables, r + 110, c.arraylen)
        end
        for k in 1:garbage_channels
            r = c0 + (length(channels) + k - 1) * 128
            put_bytes!(tables, r, test_gdb_garbage(128, k))
            tables[r + 79] |= 0x01          # the low byte of the int16 flags at +78
        end
        put_name!(tables, c0 + chans_max * 128, "SUPER")
        seekstart(io)
        write(io, tweak(h))
        write(io, zeros(UInt8, 24))
        write(io, dir)
        write(io, tables)
        # A file with no blobs ends at the first blob page, as the header says.
        truncate(io, (start_page + page) * page_size)
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

"""
    test_gdb_object(class, code, body)

The bytes of a framed admin object (research section 9) for the `admin` option
of `write_test_gdb`: the payload length at +24, the object frame at +28, the
class name at +44, the member frame at +60, the member tag and the 4-character
`code` at +92, then `body` from +124. The writer fills in the first 24 bytes.
"""
function test_gdb_object(class::String, code::String, body::Vector{UInt8})::Vector{UInt8}
    b = zeros(UInt8, 124 + length(body))
    put_i32!(b, 24, length(b) - 28)
    put_bytes!(b, 28, UInt8[0xff, 0x00, 0xf0, 0x0f])
    put_i32!(b, 32, length(b) - 60)
    put_i32!(b, 40, 1)
    put_name!(b, 44, class)
    put_bytes!(b, 60, UInt8[0xff, 0x00, 0xe1, 0x1e])
    put_i32!(b, 64, length(b) - 92)
    put_bytes!(b, 92, UInt8[0x00, 0x1a, 0xcc, 0xff])
    put_name!(b, 96, code)
    put_bytes!(b, 124, body)
    return b
end

"""
    test_registry(pairs)

A `REG` object with one 256-byte slot `KEY\\0value\\0` per pair, in order, then a
count of 0 nested objects (research section 9.1). A value may be raw bytes, so
a test can store text that is not UTF-8.
"""
function test_registry(pairs)::Vector{UInt8}
    pairs = collect(pairs)
    body = zeros(UInt8, 4 + 256 * length(pairs) + 4)
    put_i32!(body, 0, length(pairs))
    for (k, (key, value)) in enumerate(pairs)
        v = value isa AbstractVector{UInt8} ? value : Vector{UInt8}(codeunits(value))
        slot = vcat(Vector{UInt8}(codeunits(key)), 0x00, v)
        length(slot) < 256 || error("the registry entry $key does not fit in its 256-byte slot")
        put_bytes!(body, 4 + 256 * (k - 1), slot)
    end
    return test_gdb_object("REG", "REG ", body)
end

"""
    test_ipj(; name, method, datum, units)

An `IPJ` object of 776 bytes, as in afgrav, with the name at +104, the method
at +168, the datum at +180 and the units at +452 (research section 10).
"""
function test_ipj(; name::String, method::Int = 11, datum::String = "WGS 84", units::String = "m")::Vector{UInt8}
    b = test_gdb_object("IPJ", " JPI", zeros(UInt8, 776 - 124))
    put_name!(b, 104, name)
    put_i32!(b, 168, method)
    put_name!(b, 180, datum)
    put_name!(b, 452, units)
    return b
end
