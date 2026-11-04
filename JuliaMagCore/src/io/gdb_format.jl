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

"The int32 word at byte `off` of `b`."
gdb_word(b::AbstractVector{UInt8}, off::Int)::Int = Int(ltoh(reinterpret(Int32, view(b, off + 1:off + 4))[1]))

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
An open Geosoft database. `dir` holds the directory slots; `cp1252` is set when
any name was read with the Windows-1252 fallback (see `gdb_text`).
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
    open_gdb(path)

Open a Geosoft database for reading and check its header. Throws `GdbError`
with the refusal text for anything that is not a Geosoft database, and closes
the file when a check fails.
"""
function open_gdb(path::AbstractString)::GdbFile
    why = gdb_refusal(path)
    why === nothing || throw(GdbError(why))
    io = open(path, "r")
    try
        size = Int(filesize(io))
        h = read_gdb_header(io, size)
        return GdbFile(String(path), io, size, h, GdbSlot[], false)
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
