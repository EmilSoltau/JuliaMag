# Raw column files. These helpers know about files and element types only.
# They know nothing about lines or databases.
#
# A numeric column is a file of raw little-endian values.
# A string column is two files: `.str` holds the bytes of all values end to end,
# and `.off` holds one Int64 per row: the byte offset where that row ends.

using Mmap

# The files are written in the native byte order of the computer.
# Every computer Julia runs on today is little-endian; this check keeps it honest.
ENDIAN_BOM == 0x04030201 || error("JuliaMagCore needs a little-endian computer")

"Size of the write buffer of one appender, in bytes."
const APPEND_BUFFER_BYTES = 1 << 20

"Element types a channel may have, by the name stored in `database.json`."
const CHANNEL_ELTYPES = Dict{String,DataType}(
    "Float64" => Float64, "Float32" => Float32,
    "Int32" => Int32, "Int16" => Int16, "Int8" => Int8, "UInt8" => UInt8,
    "String" => String,
)

"File name extension of a numeric column file."
const COLUMN_EXTENSIONS = Dict{DataType,String}(
    Float64 => ".f64", Float32 => ".f32",
    Int32 => ".i32", Int16 => ".i16", Int8 => ".i8", UInt8 => ".u8",
)

const NumericEltype = Union{Float64,Float32,Int32,Int16,Int8,UInt8}

"Return the stored name of an element type, or `nothing` when the type is not allowed."
function eltype_name(T::DataType)::Union{String,Nothing}
    for (k, v) in CHANNEL_ELTYPES
        v === T && return k
    end
    return nothing
end

# ---- numeric columns -------------------------------------------------------

"Number of values of type `T` in the file at `path`."
column_length(path::AbstractString, ::Type{T}) where {T} = filesize(path) ÷ sizeof(T)

"Append `n` copies of `value` to the open file `io`, in chunks."
function write_repeated(io::IO, value::T, n::Integer) where {T}
    chunk = fill(value, min(n, APPEND_BUFFER_BYTES ÷ sizeof(T)))
    left = n
    while left > 0
        k = min(left, length(chunk))
        write(io, view(chunk, 1:k))
        left -= k
    end
    return nothing
end

"Create a column file with `n` missing values."
function create_column(path::AbstractString, ::Type{T}, n::Integer) where {T<:NumericEltype}
    open(io -> write_repeated(io, missing_value(T), n), path, "w")
    return nothing
end

"""
Grow a column file to `n` values by appending missing values.
The caller checks that the file is not longer than `n` values, and that
no map of the file is open (see `release_map!`).
"""
function pad_column(path::AbstractString, ::Type{T}, n::Integer) where {T<:NumericEltype}
    have = column_length(path, T)
    have < n && open(io -> write_repeated(io, missing_value(T), n - have), path, "a")
    return nothing
end

"Map a whole column file into memory, for reading and writing in place."
function map_column(path::AbstractString, ::Type{T})::Vector{T} where {T}
    return open(path, "r+") do io
        Mmap.mmap(io, Vector{T}, filesize(io) ÷ sizeof(T))
    end
end

"""
Cut a column file back to `n` values. The caller makes sure no map of the file
is open (see `release_map!`).
"""
function cut_column(path::AbstractString, ::Type{T}, n::Integer) where {T}
    filesize(path) > n * sizeof(T) && open(io -> truncate(io, n * sizeof(T)), path, "r+")
    return nothing
end

# ---- string columns --------------------------------------------------------

"Create an empty string column: no bytes, and `n` rows that all end at offset 0."
function create_string_column(strpath::AbstractString, offpath::AbstractString, n::Integer)
    touch(strpath)
    open(offpath, "w") do io
        write_repeated(io, Int64(0), n)
    end
    return nothing
end

"End offset of the last row in a `.off` file, or 0 when it has no rows."
function last_offset(offpath::AbstractString)::Int64
    n = column_length(offpath, Int64)
    n == 0 && return Int64(0)
    return open(offpath, "r") do io
        seek(io, (n - 1) * 8)
        read(io, Int64)
    end
end

"""
Grow a string column to `n` rows of empty strings.
The caller checks that it is not longer than `n` rows.
"""
function pad_string_column(offpath::AbstractString, n::Integer)
    have = column_length(offpath, Int64)
    if have < n
        last = last_offset(offpath)
        open(io -> write_repeated(io, last, n - have), offpath, "a")
    end
    return nothing
end

"""
Cut a string column back to `n` rows: the `.off` file to `n` offsets,
and the `.str` file to the end of row `n`.
"""
function cut_string_column(strpath::AbstractString, offpath::AbstractString, n::Integer)
    cut_column(offpath, Int64, n)
    cut_column(strpath, UInt8, last_offset(offpath))
    return nothing
end

"Read rows `rows` of a string column. `offs` is the mapped `.off` file."
function read_strings(strpath::AbstractString, offs::AbstractVector{Int64},
                      rows::UnitRange{Int})::Vector{String}
    isempty(rows) && return String[]
    first_byte = first(rows) == 1 ? Int64(0) : offs[first(rows) - 1]
    bytes = open(strpath, "r") do io
        seek(io, first_byte)
        read(io, offs[last(rows)] - first_byte)
    end
    out = Vector{String}(undef, length(rows))
    start = first_byte
    for (k, r) in enumerate(rows)
        stop = offs[r]
        out[k] = String(bytes[(start - first_byte + 1):(stop - first_byte)])
        start = stop
    end
    return out
end

"""
Replace rows `rows` of a string column with `values`.
`offs` is the mapped `.off` file; it is updated in place.
When the byte length changes, the `.str` file is rewritten to a temporary file
in a stream and then moved over the old one. The `.str` file is never mapped,
so the move also works on Windows.
"""
function replace_strings!(strpath::AbstractString, offs::AbstractVector{Int64},
                          rows::UnitRange{Int}, values::AbstractVector{String})
    isempty(rows) && return nothing
    first_byte = first(rows) == 1 ? Int64(0) : offs[first(rows) - 1]
    old_end = offs[last(rows)]
    new_bytes = IOBuffer()
    for v in values
        write(new_bytes, v)
    end
    payload = take!(new_bytes)
    delta = Int64(length(payload)) - (old_end - first_byte)
    if delta == 0
        open(strpath, "r+") do io
            seek(io, first_byte)
            write(io, payload)
        end
    else
        tmp = strpath * ".tmp"
        open(strpath, "r") do src
            open(tmp, "w") do dst
                copy_bytes(src, dst, first_byte)
                write(dst, payload)
                seek(src, old_end)
                copy_bytes(src, dst, filesize(strpath) - old_end)
            end
        end
        mv(tmp, strpath; force = true)
    end
    pos = first_byte
    for (k, r) in enumerate(rows)
        pos += ncodeunits(values[k])
        offs[r] = pos
    end
    if delta != 0
        for r in (last(rows) + 1):length(offs)
            offs[r] += delta
        end
    end
    return nothing
end

"Copy `n` bytes from `src` to `dst` in chunks."
function copy_bytes(src::IO, dst::IO, n::Integer)
    buf = Vector{UInt8}(undef, min(n, APPEND_BUFFER_BYTES))
    left = n
    while left > 0
        k = min(left, length(buf))
        readbytes!(src, buf, k)
        write(dst, view(buf, 1:k))
        left -= k
    end
    return nothing
end

# ---- buffered writers ------------------------------------------------------

"Buffered writer that appends values of type `T` to a column file."
mutable struct NumericWriter{T<:NumericEltype}
    io::IOStream
    buf::Vector{T}
    n::Int
    written::Int
end

function NumericWriter{T}(path::AbstractString) where {T<:NumericEltype}
    return NumericWriter{T}(open(path, "a"), Vector{T}(undef, APPEND_BUFFER_BYTES ÷ sizeof(T)), 0, 0)
end

function writer_put!(w::NumericWriter{T}, x::T) where {T}
    w.n == length(w.buf) && flush_writer!(w)
    w.n += 1
    @inbounds w.buf[w.n] = x
    w.written += 1
    return nothing
end

function flush_writer!(w::NumericWriter)
    w.n > 0 && write(w.io, view(w.buf, 1:w.n))
    w.n = 0
    return nothing
end

"Buffered writer that appends strings to a string column."
mutable struct StringWriter
    strio::IOStream
    offio::IOStream
    bytes::IOBuffer
    offs::Vector{Int64}
    n::Int
    pos::Int64
    written::Int
end

function StringWriter(strpath::AbstractString, offpath::AbstractString)
    pos = last_offset(offpath)
    return StringWriter(open(strpath, "a"), open(offpath, "a"), IOBuffer(),
                        Vector{Int64}(undef, APPEND_BUFFER_BYTES ÷ 8), 0, pos, 0)
end

function writer_put!(w::StringWriter, s::AbstractString)
    (w.n == length(w.offs) || position(w.bytes) >= APPEND_BUFFER_BYTES) && flush_writer!(w)
    w.pos += write(w.bytes, s)
    w.n += 1
    w.offs[w.n] = w.pos
    w.written += 1
    return nothing
end

function flush_writer!(w::StringWriter)
    write(w.strio, take!(w.bytes))
    w.n > 0 && write(w.offio, view(w.offs, 1:w.n))
    w.n = 0
    return nothing
end

function close_writer!(w::NumericWriter)
    try
        flush_writer!(w)
    finally
        close(w.io)
    end
    return nothing
end

function close_writer!(w::StringWriter)
    try
        flush_writer!(w)
    finally
        close(w.strio)
        close(w.offio)
    end
    return nothing
end
