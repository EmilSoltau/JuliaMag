# Reading text files in chunks, and splitting a line into fields without allocating.
#
# A file is read `chunk` bytes at a time, so memory use does not grow with the file.
# A line cut by the end of a chunk is carried over to the next chunk.
# Each line is handed out as a `SubString` of the chunk: no copy per line.

"Size of one read, in bytes."
const DEFAULT_CHUNK = 4 << 20

const BYTE_LF = UInt8('\n')
const BYTE_CR = UInt8('\r')

"""
    eachfileline(f, path; chunk = 4 MiB)

Call `f(lineno::Int, line::SubString{String}, bytes_read::Int)` for each line of the file.

- `lineno` counts from 1.
- `line` has no line end: `\\n` and a trailing `\\r` are removed.
  A UTF-8 byte order mark at the start of the file is removed too.
- `bytes_read` is how many bytes of the file have been read so far.
  It is the same for all lines of one chunk, so a change means a new chunk.

The file is read `chunk` bytes at a time. A line is never cut in two.
`line` is only valid during the call; copy it (`String(line)`) to keep it.
"""
function eachfileline(f::F, path::AbstractString; chunk::Integer = DEFAULT_CHUNK) where {F}
    chunk >= 1 || throw(ArgumentError("chunk must be 1 byte or more, not $chunk"))
    open(path, "r") do io
        scan_lines(f, io, Int(chunk))
    end
    return nothing
end

# `F` makes Julia compile this for each callback, so calls to `f` do not allocate.
function scan_lines(f::F, io::IO, chunk::Int) where {F}
    readbuf = Vector{UInt8}(undef, chunk)
    carry = UInt8[]          # the start of a line cut by the end of the last chunk
    lineno = 0
    bytes_read = 0
    first_chunk = true
    while true
        n = readbytes!(io, readbuf, chunk)
        bytes_read += n
        at_end = n < chunk && eof(io)
        # One new buffer per chunk. A `StringVector` lends its memory to `String`
        # without a copy (a plain Vector would be copied).
        buf = Base.StringVector(length(carry) + n)
        copyto!(buf, 1, carry, 1, length(carry))
        copyto!(buf, length(carry) + 1, readbuf, 1, n)
        start = 1
        if first_chunk && length(buf) >= 3 && buf[1] == 0xef && buf[2] == 0xbb && buf[3] == 0xbf
            start = 4
        elseif first_chunk && length(buf) < 3 && !at_end
            # Too short to tell whether a byte order mark starts the file. Read more first.
            carry = buf
            continue
        end
        first_chunk = false
        s = String(buf)
        stop = ncodeunits(s)
        # The end of the last whole line in this chunk.
        last_lf = at_end ? stop : something(findprev(==(BYTE_LF), codeunits(s), stop), start - 1)
        i = start
        while i <= last_lf
            j = something(findnext(==(BYTE_LF), codeunits(s), i), stop + 1)
            lineno += 1
            f(lineno, line_view(s, i, j - 1), bytes_read)
            i = j + 1
        end
        # Keep the cut line for the next chunk.
        rest = stop - last_lf
        carry = Vector{UInt8}(undef, max(rest, 0))
        rest > 0 && copyto!(carry, 1, codeunits(s), last_lf + 1, rest)
        at_end && break
    end
    return nothing
end

"The bytes `i:j` of `s` as a `SubString`, without a trailing `\\r`."
@inline function line_view(s::String, i::Int, j::Int)::SubString{String}
    j >= i && codeunit(s, j) == BYTE_CR && (j -= 1)
    j < i && return SubString(s, i, i - 1)
    # `i` follows a line end, so it starts a character. `j` may be inside a
    # character; `thisind` steps back to its first byte and the SubString then
    # ends at the end of that character.
    return SubString(s, i, thisind(s, j))
end

# ---- fields ----------------------------------------------------------------

"True for a byte that separates fields: space, tab or comma."
@inline is_field_sep(b::UInt8) = b == 0x20 || b == 0x09 || b == 0x2c

"""
    scan_fields!(starts, stops, s, i, j) -> count

Find the fields in bytes `i:j` of `s`. Fields are split by runs of spaces,
tabs and commas. The byte range of field `k` goes to `starts[k]` and `stops[k]`,
for the fields that fit; the vectors are not grown. Returns the number of fields.
No memory is allocated.
"""
function scan_fields!(starts::Vector{Int}, stops::Vector{Int}, s::String, i::Int, j::Int)::Int
    cap = min(length(starts), length(stops))
    count = 0
    k = i
    @inbounds while k <= j
        while k <= j && is_field_sep(codeunit(s, k))
            k += 1
        end
        k > j && break
        a = k
        while k <= j && !is_field_sep(codeunit(s, k))
            k += 1
        end
        count += 1
        if count <= cap
            starts[count] = a
            stops[count] = k - 1
        end
    end
    return count
end

"Byte range of `line` in its parent string."
@inline line_range(line::SubString{String}) = (line.offset + 1, line.offset + ncodeunits(line))

"""
    parse_field(s, a, b) -> Union{Float64,Nothing}

Parse bytes `a:b` of `s` as a number. Returns `nothing` when they are not a number.
Bytes that are not ASCII are never a number; checking first keeps the
`SubString` safe for broken UTF-8.
"""
@inline function parse_field(s::String, a::Int, b::Int)::Union{Float64,Nothing}
    @inbounds for k in a:b
        codeunit(s, k) >= 0x80 && return nothing
    end
    return tryparse(Float64, SubString(s, a, b))
end

"The text of bytes `a:b`, as a new `String`. Broken UTF-8 becomes `\ufffd`, so messages stay valid text."
function field_text(s::String, a::Int, b::Int)::String
    t = String(codeunits(s)[a:b])
    isvalid(t) && return t
    return map(c -> isvalid(c) ? c : '\ufffd', t)
end
