# Geosoft Oasis montaj databases (`.gdb`): telling the file apart, the header
# and its layout checks.
#
# The byte layout is in `docs/research/geosoft-gdb-format.md`, sections 1 to 5.
# A `.gdb` is a paged file: a 256-byte header, a blob directory from byte 280,
# symbol tables for blobs, lines, channels and users, then a chain of blobs.
# All numbers are little-endian. Byte offsets count from 0.
#
# JuliaMag only reads these files. The reader checks every layout rule it
# knows and refuses a file when one fails; it never guesses.

"A problem with a Geosoft database. The message is plain text for the user."
struct GdbError <: Exception
    msg::String
end
Base.showerror(io::IO, e::GdbError) = print(io, e.msg)

"The 4 bytes every Geosoft database starts with."
const GDB_MAGIC = UInt8['!', 'C', 'B', 'D']
"The size of the file header."
const GDB_HEADER_BYTES = 256
"The byte where the blob directory starts."
const GDB_DIR_START = 280
"The size of one directory slot."
const GDB_SLOT_BYTES = 6
"The size of one record in a symbol table."
const GDB_RECORD_BYTES = 128
"The version words at bytes 8 and 12, the same in every known file."
const GDB_VERSION_WORDS = (0x10020000, 264)

"""
    gdb_kind(path)

`:esri_folder` for a directory (an ArcGIS file geodatabase), `:geosoft` for a
regular file that starts with `!CBD`, and `:unknown` otherwise, also for a
missing file or one shorter than 4 bytes.
"""
function gdb_kind(path::AbstractString)::Symbol
    isdir(path) && return :esri_folder
    isfile(path) || return :unknown
    head = open(io -> read(io, 4), path)
    return head == GDB_MAGIC ? :geosoft : :unknown
end

"""
    gdb_refusal(path)

`nothing` when `path` is a Geosoft database, else the plain message that says
why JuliaMag does not read it.
"""
function gdb_refusal(path::AbstractString)::Union{Nothing,String}
    kind = gdb_kind(path)
    kind == :geosoft && return nothing
    name = basename(rstrip(path, ('/', '\\')))
    kind == :esri_folder && return "$name is an ArcGIS file geodatabase (a folder), not a Geosoft database. " *
                                   "JuliaMag reads only Geosoft .gdb files."
    isfile(path) || return "no file at $path"
    head = open(io -> read(io, 4), path)
    start = length(head) < 4 ? "fewer than 4 bytes" : join((string(b; base = 16, pad = 2) for b in head), " ")
    return "$name is not a Geosoft database: it starts with $start, not !CBD."
end

"""
The header of a Geosoft database (research section 3). Counts and capacities
come from header words; `blob_table`, `line_table`, `chan_table` and
`user_table` are the byte offsets where the symbol tables start.
"""
struct GdbHeader
    chans_max::Int
    blobs_max::Int
    cache::Int
    lines_max::Int
    users_max::Int
    dir_slots::Int
    first_admin::Int
    page_size::Int
    index_size::Int
    blob_start_page::Int
    n_pages::Int
    comp_level::Int
    line_handle0::Int
    chan_handle0::Int
    user_handle0::Int
    blob_table::Int
    line_table::Int
    chan_table::Int
    user_table::Int
end

"One slot of the blob directory: live or not, the start page and the page count."
struct GdbSlot
    live::Bool
    page::Int
    pages::Int
end

"The little-endian number of type `T` at byte `off` of `b`."
gdb_num(::Type{T}, b::AbstractVector{UInt8}, off::Int) where {T} = ltoh(reinterpret(T, view(b, off + 1:off + sizeof(T)))[1])

"The int32 word at byte `off` of `b`."
gdb_word(b::AbstractVector{UInt8}, off::Int)::Int = Int(gdb_num(Int32, b, off))

"Throw the layout error that names the rule `check`."
gdb_layout_error(check::AbstractString) =
    throw(GdbError("the file is damaged or uses a Geosoft database layout JuliaMag does not know ($check). " *
                   "It was not imported."))

"""
    read_gdb_header(io, file_size)

Read the 256-byte header from the start of `io` and check its layout rules.
Throws `GdbError` that names the first rule that fails.
"""
function read_gdb_header(io::IO, file_size::Integer)::GdbHeader
    seekstart(io)
    b = read(io, GDB_HEADER_BYTES)
    length(b) >= 4 && b[1:4] == GDB_MAGIC || gdb_layout_error("the file does not start with !CBD")
    length(b) == GDB_HEADER_BYTES || gdb_layout_error("the file is shorter than its 256-byte header")
    w(off) = gdb_word(b, off)
    check(ok::Bool, rule::AbstractString) = ok || gdb_layout_error(rule)
    check((w(8), w(12)) == GDB_VERSION_WORDS, "the version words at bytes 8 and 12")
    chans, blobs, cache, lines, users = w(24), w(28), w(32), w(36), w(40)
    page = w(100)
    check(chans > 0 && blobs > 0 && lines > 0 && users > 0, "the table capacities must be above 0")
    check(cache >= 0, "the directory cache must not be negative")
    check(page > 0, "the page size must be above 0")
    check(w(44) == w(60) + cache, "the directory size in word 44")
    check(w(48) == lines * chans, "the first admin blob in word 48")
    check(w(52) == w(48) + blobs, "the last admin blob in word 52")
    check(w(56) == w(60) == w(52) + users, "the symbol counts in words 56 and 60")
    check(w(64) == blobs + lines + chans + users, "the symbol total in word 64")
    check(w(72) == blobs && w(76) == w(72) + lines && w(80) == w(76) + chans, "the symbol handles in words 72 to 80")
    check((w(84), w(88), w(92), w(96)) == (blobs, lines, chans, users), "the table capacities in words 84 to 96")
    index_size = w(104)
    chan_table = index_size - (chans + users) * GDB_RECORD_BYTES
    line_table = chan_table - lines * GDB_RECORD_BYTES
    blob_table = GDB_DIR_START + w(44) * GDB_SLOT_BYTES
    check(blob_table + blobs * GDB_RECORD_BYTES == line_table, "the symbol table starts")
    start_page, n_pages = w(108), w(112)
    check(start_page >= 0 && n_pages >= 0 && start_page * page >= index_size, "the first blob page in word 108")
    check((start_page + n_pages) * page == file_size, "the file size and the page count in word 112")
    check(w(120) in 0:2, "the compression level in word 120")
    return GdbHeader(chans, blobs, cache, lines, users, w(44), w(48), page, index_size, start_page, n_pages,
                     w(120), w(72), w(76), w(80), blob_table, line_table, chan_table,
                     chan_table + chans * GDB_RECORD_BYTES)
end

"""
An open Geosoft database. `dir` holds the directory slots, one per blob index
(slot `i + 1` for blob `i`); `cp1252` is set when any name was read with the
Windows-1252 fallback (see `gdb_text`).
"""
mutable struct GdbFile
    path::String
    io::IOStream
    size::Int
    header::GdbHeader
    dir::Vector{GdbSlot}
    cp1252::Bool
end

"""
    read_gdb_dir(io, h)

Read the `h.dir_slots` slots of the blob directory (research section 4). Each
slot is a uint32 (bit 31 = live, low 30 bits = start page, counted from
`blob_start_page`) and a uint16 page count.
"""
function read_gdb_dir(io::IO, h::GdbHeader)::Vector{GdbSlot}
    seek(io, GDB_DIR_START)
    b = read(io, h.dir_slots * GDB_SLOT_BYTES)
    length(b) == h.dir_slots * GDB_SLOT_BYTES || gdb_layout_error("the blob directory")
    return map(0:h.dir_slots - 1) do i
        w = gdb_num(UInt32, b, i * GDB_SLOT_BYTES)
        GdbSlot(w & 0x80000000 != 0, Int(w & 0x3FFFFFFF), Int(gdb_num(UInt16, b, i * GDB_SLOT_BYTES + 4)))
    end
end

"""
    open_gdb(path)

Open a Geosoft database for reading, check its header and read the blob
directory. Throws `GdbError` with the refusal text for anything that is not a
Geosoft database, and closes the file when a check fails.
"""
function open_gdb(path::AbstractString)::GdbFile
    why = gdb_refusal(path)
    why === nothing || throw(GdbError(why))
    io = open(path, "r")
    try
        size = Int(filesize(io))
        h = read_gdb_header(io, size)
        return GdbFile(String(path), io, size, h, read_gdb_dir(io, h), false)
    catch
        close(io)
        rethrow()
    end
end

Base.close(g::GdbFile) = close(g.io)

"Open the database at `path`, return `f(g)` and close it again, also on error."
function with_gdb(f, path::AbstractString)
    g = open_gdb(path)
    try
        return f(g)
    finally
        close(g)
    end
end

"The 4 bytes every blob in the chain starts with (research section 6.1)."
const GDB_BLOB_MAGIC = UInt8[0xcc, 0xcc, 0x00, 0xff]

"""
    blob_offset(g, index)

The byte offset of blob `index` (0-based), as the directory gives it, or
`nothing` when its slot is not live (no data). Throws `GdbError` when a live
slot does not land on a blob with this index and page count, or runs past the
end of the file. The reader does not search the chain for another copy,
because the last copy can be stale (research section 4, AirMag `__552`).
"""
function blob_offset(g::GdbFile, index::Int)::Union{Nothing,Int}
    slot = g.dir[index + 1]
    slot.live || return nothing
    h = g.header
    off = (h.blob_start_page + slot.page) * h.page_size
    ok = slot.pages >= 1 && off + slot.pages * h.page_size <= g.size
    if ok
        seek(g.io, off)
        b = read(g.io, 16)
        ok = length(b) == 16 && b[1:4] == GDB_BLOB_MAGIC && gdb_word(b, 4) == slot.pages &&
             gdb_word(b, 12) == index
    end
    ok || throw(GdbError("the directory entry of blob $index does not point at its data"))
    return off
end

"""
Windows-1252 for bytes 0x80 to 0x9F. The 5 bytes Windows-1252 leaves undefined
(0x81, 0x8D, 0x8F, 0x90, 0x9D) keep their own code point, as in the WHATWG
encoding standard. Bytes 0xA0 to 0xFF are the same as Latin-1.
"""
const GDB_CP1252_HIGH = Char[
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178]

"""
    gdb_text(bytes)

The text in `bytes` up to the first NUL, and whether it needed the fallback:
UTF-8 when the bytes are valid UTF-8 (`false`), else Windows-1252 (`true`).
"""
function gdb_text(bytes::AbstractVector{UInt8})::Tuple{String,Bool}
    n = findfirst(iszero, bytes)
    b = n === nothing ? bytes : view(bytes, 1:n - 1)
    s = String(collect(b))
    isvalid(s) && return (s, false)
    return (String([0x80 <= c <= 0x9f ? GDB_CP1252_HIGH[c - 0x7f] : Char(c) for c in b]), true)
end

"The `n` 128-byte records of a symbol table that starts at byte `start`."
function read_gdb_table(g::GdbFile, start::Int, n::Int)::Vector{UInt8}
    seek(g.io, start)
    b = read(g.io, n * GDB_RECORD_BYTES)
    length(b) == n * GDB_RECORD_BYTES || gdb_layout_error("the symbol tables")
    return b
end

"Record `k` (0-based) of a symbol table read by `read_gdb_table`."
gdb_record(b::Vector{UInt8}, k::Int) = view(b, k * GDB_RECORD_BYTES + 1:(k + 1) * GDB_RECORD_BYTES)

"The name at the start of record `r`; sets `g.cp1252` when it used the fallback."
function gdb_record_name!(g::GdbFile, r::AbstractVector{UInt8})::String
    name, fallback = gdb_text(view(r, 1:64))
    g.cp1252 |= fallback
    return name
end

"""
A live channel record (research section 5.1). `slot` is the 0-based slot in the
channel table. `type` is a Geosoft `GS_*` code, or minus the width of a string.
"""
struct GdbChannelRecord
    slot::Int
    name::String
    type::Int
    flags::Int
    format::Int
    width::Int
    decimals::Int
    arraylen::Int
end

"""
    read_gdb_channels(g)

The live channel records in slot order. A record is live when bit 0 of its
flags is clear, its array width is at least 1, and its name is non-empty and
printable. Unused slots can hold garbage, so the name of a record that fails
the other rules is not read. A live record may have a type code JuliaMag does
not know (10 or more); `plan_gdb_channels` skips it with a warning.
"""
function read_gdb_channels(g::GdbFile)::Vector{GdbChannelRecord}
    h = g.header
    b = read_gdb_table(g, h.chan_table, h.chans_max)
    out = GdbChannelRecord[]
    for k in 0:h.chans_max - 1
        r = gdb_record(b, k)
        type, flags = Int(gdb_num(Int16, r, 76)), Int(gdb_num(Int16, r, 78))
        arraylen = Int(gdb_num(Int16, r, 110))
        flags & 1 == 0 && arraylen >= 1 || continue
        name, fallback = gdb_text(view(r, 1:64))
        !isempty(name) && all(isprint, name) || continue
        g.cp1252 |= fallback
        push!(out, GdbChannelRecord(k, name, type, flags, Int(gdb_num(Int16, r, 84)), Int(gdb_num(Int16, r, 86)),
                                    gdb_word(r, 88), arraylen))
    end
    return out
end

"""
A line record (research section 5.2). `category` is 100 for a normal line and
200 for a group line. `date` is a decimal year; `type` the Geosoft line type
code (0 `L`, 1 `B`, 2 `T`, 3 `S`, 4 `R`, 5 `P`, 6 `D`).
"""
struct GdbLineRecord
    slot::Int
    name::String
    category::Int
    date::Float64
    number::Int
    type::Int
    flight::Int
    version::Int
end

"""
    read_gdb_lines(g)

The records with category 100 (line) or 200 (group) in slot order. Free slots
(bit `0x10000` set) and garbage with other categories are left out.
"""
function read_gdb_lines(g::GdbFile)::Vector{GdbLineRecord}
    h = g.header
    b = read_gdb_table(g, h.line_table, h.lines_max)
    out = GdbLineRecord[]
    for k in 0:h.lines_max - 1
        r = gdb_record(b, k)
        category = gdb_word(r, 76)
        category in (100, 200) || continue
        push!(out, GdbLineRecord(k, gdb_record_name!(g, r), category, gdb_num(Float64, r, 84), gdb_word(r, 92),
                                 gdb_word(r, 96), gdb_word(r, 100), gdb_word(r, 124)))
    end
    return out
end

"""
    read_gdb_blob_symbols(g)

`(k, name)` of the live blob symbols (category 0, name non-empty), in slot
order. Symbol `k` owns admin blob `first_admin + k` (research section 5.3).
"""
function read_gdb_blob_symbols(g::GdbFile)::Vector{Tuple{Int,String}}
    h = g.header
    b = read_gdb_table(g, h.blob_table, h.blobs_max)
    out = Tuple{Int,String}[]
    for k in 0:h.blobs_max - 1
        r = gdb_record(b, k)
        gdb_word(r, 76) == 0 || continue
        r[1] == 0x00 && continue
        push!(out, (k, gdb_record_name!(g, r)))
    end
    return out
end
