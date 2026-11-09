# The value types of Geosoft databases (`.gdb`), their dummies, and how they
# map to JuliaMag types.
#
# The rules are in `docs/research/geosoft-gdb-format.md`, section 7, and in
# ruling 7 of the gdb import plan. Types JuliaMag lacks are widened: USHORT to
# Int32, and ULONG, LONG64 and ULONG64 to Float64. Geosoft dummies become
# JuliaMag missing values. Geosoft uses typemin + 1 as the dummy of a signed
# integer and JuliaMag uses typemin, so a real typemin value reads as missing;
# `GdbValueNotes` counts those, so the import can warn.

"""
A Geosoft value type. `code` is the Geosoft code (negative for a string of
`-code` bytes), `size` the bytes per value, `T` the JuliaMag type the values
become. `widened` is true when `T` is not the stored type, and `lossy` when
some stored values do not fit `T` exactly.
"""
struct GdbType
    code::Int
    size::Int
    T::DataType
    widened::Bool
    lossy::Bool
end

"The stored type of each numeric Geosoft code 0 to 9."
const GDB_STORED_TYPES = (Int8, UInt16, Int16, Int32, Float32, Float64, UInt8, UInt32, Int64, UInt64)

"The JuliaMag type of each numeric Geosoft code 0 to 9."
const GDB_VALUE_TYPES = (Int8, Int32, Int16, Int32, Float32, Float64, UInt8, Float64, Float64, Float64)

"A float value at or below this is a Geosoft dummy (the dummy is -1e32)."
const GDB_FLOAT_DUMMY_LIMIT = -1.0e31

"""
    gdb_type(code)

The `GdbType` of a Geosoft value type code. Throws `GdbError` for a code of 10
or more, which no known Geosoft version writes.
"""
function gdb_type(code::Integer)::GdbType
    code < 0 && return GdbType(code, -code, String, false, false)
    code < 10 || throw(GdbError("a channel has the value type $code, which JuliaMag cannot read."))
    S = GDB_STORED_TYPES[code + 1]
    return GdbType(code, sizeof(S), GDB_VALUE_TYPES[code + 1], code in (1, 7, 8, 9), code in (8, 9))
end

"""
What `gdb_values!` found while decoding, added up across calls:
- `clashes`: real values equal to JuliaMag's missing marker (Int8 -128, Int16
  -32768, Int32 typemin). They stay as stored and so read as missing.
- `inexact`: 64-bit integers that Float64 cannot store exactly.
- `cp1252`: string values decoded with the Windows-1252 fallback.
"""
mutable struct GdbValueNotes
    clashes::Int
    inexact::Int
    cp1252::Int
end

"Throw an `ArgumentError` unless `bytes` holds whole values of `t` and `out` has its type."
function check_gdb_values(out::Vector, bytes::Vector{UInt8}, t::GdbType)
    eltype(out) === t.T || throw(ArgumentError("value type $(t.code) gives $(t.T) values, not $(eltype(out))"))
    length(bytes) % t.size == 0 ||
        throw(ArgumentError("$(length(bytes)) bytes are not whole values of $(t.size) bytes"))
    return nothing
end

"""
    gdb_values!(out, bytes, t, notes)

Decode the little-endian values of type `t` in `bytes` into `out` (resized)
and return it. Geosoft dummies become `missing_value(T)`. Adds what it found to
`notes`. Throws `ArgumentError` when `out` is not a `Vector{t.T}` or `bytes`
does not hold whole values: callers size both from the blob header.
"""
function gdb_values!(out::Vector{T}, bytes::Vector{UInt8}, t::GdbType, notes::GdbValueNotes)::Vector{T} where {T<:Real}
    check_gdb_values(out, bytes, t)
    c = t.code
    c == 0 && return gdb_decode!(out, bytes, Int8, notes)
    c == 1 && return gdb_decode!(out, bytes, UInt16, notes)
    c == 2 && return gdb_decode!(out, bytes, Int16, notes)
    c == 3 && return gdb_decode!(out, bytes, Int32, notes)
    c == 4 && return gdb_decode!(out, bytes, Float32, notes)
    c == 5 && return gdb_decode!(out, bytes, Float64, notes)
    c == 6 && return gdb_decode!(out, bytes, UInt8, notes)
    c == 7 && return gdb_decode!(out, bytes, UInt32, notes)
    c == 8 && return gdb_decode!(out, bytes, Int64, notes)
    return gdb_decode!(out, bytes, UInt64, notes)
end

"""
String values: each is `gdb_text` of its fixed-width, NUL-padded bytes. Each
value that used the Windows-1252 fallback adds 1 to `notes.cp1252`.
"""
function gdb_values!(out::Vector{String}, bytes::Vector{UInt8}, t::GdbType, notes::GdbValueNotes)::Vector{String}
    check_gdb_values(out, bytes, t)
    w = t.size
    resize!(out, length(bytes) ÷ w)
    for i in eachindex(out)
        s, fallback = gdb_text(view(bytes, (i - 1) * w + 1:i * w))
        out[i] = s
        notes.cp1252 += fallback
    end
    return out
end

"The inner loop of `gdb_values!` with concrete types: stored type `S`, JuliaMag type `T`."
function gdb_decode!(out::Vector{T}, bytes::Vector{UInt8}, ::Type{S}, notes::GdbValueNotes)::Vector{T} where {T,S}
    raw = reinterpret(S, bytes)
    resize!(out, length(raw))
    clashes = 0
    inexact = 0
    @inbounds for i in eachindex(out, raw)
        v = ltoh(raw[i])
        if gdb_is_dummy(v)
            out[i] = missing_value(T)
        else
            x = convert(T, v)
            clashes += gdb_clashes(x)
            inexact += gdb_inexact(x, v)
            out[i] = x
        end
    end
    notes.clashes += clashes
    notes.inexact += inexact
    return out
end

# Geosoft dummies (research section 7). A float dummy is any value at or below
# -1e31 in the stored type, so a Float32 -1e31 counts too.
gdb_is_dummy(v::Int8) = v == Int8(-127)
gdb_is_dummy(v::Int16) = v == Int16(-32767)
gdb_is_dummy(v::Int32) = v == Int32(-2147483647)
gdb_is_dummy(v::Int64) = v == typemin(Int64)
gdb_is_dummy(v::Unsigned) = v == typemax(v)
gdb_is_dummy(v::T) where {T<:AbstractFloat} = v <= T(GDB_FLOAT_DUMMY_LIMIT)

"1 when a real value `x` equals JuliaMag's missing marker of a signed integer type."
gdb_clashes(x::Signed) = Int(x == typemin(x))
gdb_clashes(::Real) = 0

"1 when the 64-bit integer `v` did not become the Float64 `x` exactly. Compared in Int128, so 2^63 does not overflow."
gdb_inexact(x::Float64, v::Union{Int64,UInt64}) = Int(Int128(x) != Int128(v))
gdb_inexact(::Real, ::Real) = 0
