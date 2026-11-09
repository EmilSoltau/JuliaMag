# An LZRW1 decoder for the compressed blobs of Geosoft databases (`.gdb`).
#
# LZRW1 is Ross Williams' 1991 algorithm. Geosoft stores the stream with no
# 4-byte flag prefix. The layout is in `docs/research/geosoft-gdb-format.md`,
# section 6.3:
# - Items come in groups of 16. A 16-bit little-endian control word leads each
#   group. Its bits are read least significant bit first, one per item.
# - A clear bit is one literal byte.
# - A set bit is a copy item of two bytes `b0, b1`:
#   `offset = ((b0 & 0xF0) << 4) | b1` and `length = (b0 & 0x0F) + 1`.
#   It copies `length` bytes, one by one, from `offset` bytes back in the
#   output. The copy may overlap the bytes it writes.
#
# The stream is not trusted. Every copy and every read is checked, and a bad
# stream throws `GdbError`.

"""
    lzrw1_decode!(out, o, src, a, b, n) -> n

Decode the LZRW1 stream `src[a:b]` into `out[o:o+n-1]` and return `n`.
Decoding stops when `n` bytes are out, even in the middle of a group.
Throws `GdbError` when a copy has offset 0 or reaches before `o`, when the
output would pass `n` bytes, or when the input ends before `n` bytes are out.
"""
function lzrw1_decode!(out::AbstractVector{UInt8}, o::Int, src::AbstractVector{UInt8},
                       a::Int, b::Int, n::Int)::Int
    checkbounds(out, o:o + n - 1)
    a <= b && checkbounds(src, a:b)
    damaged(what) = throw(GdbError("an LZRW1 stream in the file is damaged: $what."))
    p, q, stop = a, o, o + n
    while q < stop
        p + 1 <= b || damaged("it ends after $(q - o) of $n bytes")
        ctrl = UInt16(src[p]) | UInt16(src[p + 1]) << 8
        p += 2
        for bit in 0:15
            q < stop || break
            if ctrl & (0x0001 << bit) == 0
                p <= b || damaged("it ends after $(q - o) of $n bytes")
                @inbounds out[q] = src[p]
                p += 1
                q += 1
            else
                p + 1 <= b || damaged("it ends after $(q - o) of $n bytes")
                b0, b1 = src[p], src[p + 1]
                p += 2
                offset = Int(b0 & 0xf0) << 4 | Int(b1)
                len = Int(b0 & 0x0f) + 1
                offset == 0 && damaged("a copy has offset 0")
                q - offset >= o || damaged("a copy reaches before the start of the output")
                q + len <= stop || damaged("it gives more than the $n bytes it should")
                @inbounds for k in 0:len - 1
                    out[q + k] = out[q + k - offset]
                end
                q += len
            end
        end
    end
    return n
end
