# The data blobs of Geosoft databases (`.gdb`): plain, zlib and LZRW1.
#
# The byte layout is in `docs/research/geosoft-gdb-format.md`, sections 6.1 to
# 6.4 and 8. A data blob holds the values of one channel on one line:
# - A plain blob (class 200) has a 48-byte header, then the values.
# - A packed blob (class 202) has a 56-byte header and a 16-byte chunk magic
#   part, then one zlib stream (subtype 2) or a run of LZRW1 chunks (subtype 1).
#
# The file is not trusted. Every size is checked against the blob's pages
# before a buffer is sized, and every blob must unpack to exactly the bytes its
# header gives. A bad blob throws `GdbError` that names the blob index.

using CodecZlib: ZlibDecompressorStream, ZlibError

"The 8 bytes at +56 of a packed data blob."
const GDB_CHUNK_MAGIC = UInt8[0x0f, 0x0e, 0xff, 0xfe, 0x12, 0x34, 0x56, 0x78]
"The size of the header of a plain data blob."
const GDB_PLAIN_HEADER_BYTES = 48
"The size of the header of a packed data blob, with its chunk magic part."
const GDB_PACKED_HEADER_BYTES = 72
"zlib expands data at most about 1032 times (the bound of `read_grd_block_table`)."
const GDB_ZLIB_MAX_RATIO = 1032
"A group of LZRW1 items takes at least 34 bytes and gives at most 256, so under 8 times."
const GDB_LZRW1_MAX_RATIO = 8
"The size of the header of one LZRW1 chunk: raw length, chunk length, marker."
const GDB_LZRW1_CHUNK_HEADER = 12
"The marker of an LZRW1 chunk that holds packed data."
const GDB_LZRW1_PACKED = 0xF4E5D6C7
"The marker of an LZRW1 chunk that holds the bytes as they are."
const GDB_LZRW1_STORED = 0xF0E1D2C3

"""
The header of one data blob (research sections 6.2 and 6.3). `packing` is
`:none`, `:zlib` or `:lzrw1`. `payload` is the byte offset of the values
(plain) or of the packed stream. `count` is the number of values (rows times
the array width). For a plain blob `raw_bytes` and `packed_bytes` are -1,
because its header has no such fields. `packed_bytes` is kept as read: the
stream is `packed_bytes - 16` bytes.
"""
struct GdbBlobHeader
    index::Int
    class::Int
    pages::Int
    packing::Symbol
    fid_start::Float64
    fid_step::Float64
    count::Int
    type::Int
    raw_bytes::Int
    packed_bytes::Int
    payload::Int
end

"The byte offset just past the last page of the blob `h`."
function gdb_blob_end(g::GdbFile, h::GdbBlobHeader)::Int
    start = h.payload - (h.packing == :none ? GDB_PLAIN_HEADER_BYTES : GDB_PACKED_HEADER_BYTES)
    return start + h.pages * g.header.page_size
end

"""
    read_blob_header(g, offset)

Read and check the header of the data blob at byte `offset`, as `blob_offset`
gives it. Throws `GdbError("blob <index> ...")` when the class and the chunk
magic disagree, for another class or packing subtype, a negative count, a
packed stream that runs past the blob's pages, a packed blob that claims more
raw bytes than its stream can give, or a fiducial step that is not a finite
number above 0. Nothing here sizes a buffer from the header.
"""
function read_blob_header(g::GdbFile, offset::Int)::GdbBlobHeader
    seek(g.io, offset)
    b = read(g.io, GDB_PACKED_HEADER_BYTES)
    length(b) >= 24 || throw(GdbError("the file ends inside the header of the blob at byte $offset"))
    w(off) = gdb_word(b, off)
    f(off) = gdb_num(Float64, b, off)
    index, pages, class = w(12), w(4), w(20)
    err(what) = throw(GdbError("blob $index $what"))
    blob_bytes = pages * g.header.page_size
    blob_bytes >= GDB_PLAIN_HEADER_BYTES && length(b) >= GDB_PLAIN_HEADER_BYTES ||
        err("is shorter than its header")
    # Only look for the magic inside the blob's own pages.
    packed = blob_bytes >= GDB_PACKED_HEADER_BYTES && length(b) == GDB_PACKED_HEADER_BYTES &&
             view(b, 57:64) == GDB_CHUNK_MAGIC
    class in (200, 202) || err("has the class $class, not 200 (plain data) or 202 (packed data)")
    class == 202 && !packed && err("has the class 202 (packed data) but not the chunk magic of packed data")
    class == 200 && packed && err("has the class 200 (plain data) but holds the chunk magic of packed data")
    if !packed
        fid_start, fid_step, count, type = f(24), f(32), w(40), w(44)
        packing, raw, pk, payload = :none, -1, -1, offset + GDB_PLAIN_HEADER_BYTES
    else
        raw, pk = w(24), w(28)
        fid_start, fid_step, count, type = f(32), f(40), w(48), w(52)
        subtype = w(64)
        subtype in (1, 2) || err("has the packing subtype $subtype, not 1 (LZRW1) or 2 (zlib)")
        packing = subtype == 2 ? :zlib : :lzrw1
        payload = offset + GDB_PACKED_HEADER_BYTES
        raw >= 0 || err("claims $raw raw bytes")
        pk >= 16 || err("gives a packed length of $pk, less than 16")
        stream = pk - 16
        payload + stream <= offset + blob_bytes || err("has a packed stream of $stream bytes that runs past its pages")
        ratio = packing == :zlib ? GDB_ZLIB_MAX_RATIO : GDB_LZRW1_MAX_RATIO
        raw <= ratio * stream || err("claims $raw bytes from $stream packed bytes")
    end
    count >= 0 || err("has a negative value count ($count)")
    isfinite(fid_step) && fid_step > 0 || err("has a fiducial step of $fid_step")
    return GdbBlobHeader(index, class, pages, packing, fid_start, fid_step, count, type, raw, pk, payload)
end

"""
    read_blob_bytes!(buf, scratch, g, h, elsize)

Fill `buf` (resized) with the `h.count * elsize` value bytes of the blob `h`
and return it. `scratch` holds the packed bytes. Both are reused across blobs,
so memory stays at one blob. Throws `GdbError("blob <index> ...")` when the
values run past the blob's pages, or when a packed blob does not unpack to
exactly `h.count * elsize` bytes.
"""
function read_blob_bytes!(buf::Vector{UInt8}, scratch::Vector{UInt8}, g::GdbFile, h::GdbBlobHeader,
                          elsize::Int)::Vector{UInt8}
    want = h.count * elsize
    err(what) = throw(GdbError("blob $(h.index) $what"))
    if h.packing == :none
        h.payload + want <= gdb_blob_end(g, h) || err("runs past its pages")
        resize!(buf, want)
        seek(g.io, h.payload)
        readbytes!(g.io, buf, want) == want || err("runs past the end of the file")
        return buf
    end
    h.raw_bytes == want || err("unpacks to $(h.raw_bytes) of $want bytes")
    stream = h.packed_bytes - 16
    resize!(scratch, stream)
    seek(g.io, h.payload)
    readbytes!(g.io, scratch, stream) == stream || err("runs past the end of the file")
    resize!(buf, want)
    h.packing == :zlib ? gdb_inflate!(buf, scratch, h) : gdb_unchunk!(buf, scratch, h)
    return buf
end

"""
Inflate the zlib stream in `scratch` into all of `buf`. The stream must give
exactly `length(buf)` bytes and end there; the end also checks its checksum.
"""
function gdb_inflate!(buf::Vector{UInt8}, scratch::Vector{UInt8}, h::GdbBlobHeader)
    n = length(buf)
    err(what) = throw(GdbError("blob $(h.index) $what"))
    z = ZlibDecompressorStream(IOBuffer(scratch); stop_on_end = true)
    try
        got = readbytes!(z, buf, n)
        got == n || err("unpacks to $got of $n bytes")
        eof(z) || err("unpacks to more than its $n bytes")
    catch e
        e isa ZlibError || rethrow()
        err("is damaged: its zlib data cannot be inflated")
    finally
        close(z)
    end
    return buf
end

"""
Unpack the LZRW1 chunks in `scratch` into all of `buf`. Each chunk has a
12-byte header: int32 raw length, int32 chunk length (with the header) and a
uint32 marker (research section 6.3). The walk stops when the raw lengths add
up to `length(buf)`. Each chunk is a stream of its own, so a copy never
reaches into the chunk before it.
"""
function gdb_unchunk!(buf::Vector{UInt8}, scratch::Vector{UInt8}, h::GdbBlobHeader)
    n, len = length(buf), length(scratch)
    err(what) = throw(GdbError("blob $(h.index) $what"))
    p, q = 1, 0                     # p: the next chunk in scratch; q: the bytes out so far
    while q < n
        p + GDB_LZRW1_CHUNK_HEADER - 1 <= len || err("unpacks to $q of $n bytes")
        raw, size = gdb_word(scratch, p - 1), gdb_word(scratch, p + 3)
        marker = gdb_num(UInt32, scratch, p + 7)
        size >= GDB_LZRW1_CHUNK_HEADER ||
            err("has an LZRW1 chunk of $size bytes, less than its $GDB_LZRW1_CHUNK_HEADER-byte header")
        p + size - 1 <= len || err("has an LZRW1 chunk that runs past its packed stream")
        raw >= 0 || err("has an LZRW1 chunk of $raw raw bytes")
        q + raw <= n || err("unpacks to more than its $n bytes")
        a, b = p + GDB_LZRW1_CHUNK_HEADER, p + size - 1
        if marker == GDB_LZRW1_PACKED
            try
                lzrw1_decode!(buf, q + 1, scratch, a, b, raw)
            catch e
                e isa GdbError || rethrow()
                throw(GdbError("blob $(h.index): $(e.msg)"))
            end
        elseif marker == GDB_LZRW1_STORED
            b - a + 1 == raw || err("has a stored LZRW1 chunk of $(b - a + 1) bytes that should hold $raw")
            copyto!(buf, q + 1, scratch, a, raw)
        else
            err("has an LZRW1 chunk with the unknown marker 0x$(string(marker; base = 16, pad = 8))")
        end
        q += raw
        p += size
    end
    return buf
end
