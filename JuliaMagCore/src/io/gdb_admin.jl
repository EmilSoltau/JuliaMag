# The admin objects of Geosoft databases (`.gdb`): registries and coordinate
# systems.
#
# The byte layout is in `docs/research/geosoft-gdb-format.md`, sections 5.3, 9
# and 10. A blob symbol names an admin blob. The ones read here are framed
# objects: `__dbreg` (the database registry with the current X and Y channels),
# `__<n>` for a channel handle `n` (label and units), and `?|IPJ_<X>:<Y>` (the
# coordinate system of the channel pair X, Y).
#
# These objects hold metadata, not data. A missing or damaged one gives a
# warning and is skipped; it never fails the import.

"The object frame at +28 of every framed admin object (research section 9)."
const GDB_OBJECT_FRAME = UInt8[0xff, 0x00, 0xf0, 0x0f]
"Where the class name of a framed object starts, and the byte where the member frame starts after it."
const GDB_OBJECT_CLASS = 44
const GDB_OBJECT_MEMBER = 60
"Where the entry count of a registry sits; its 256-byte entries follow it."
const GDB_REG_COUNT = 124
const GDB_REG_SLOT_BYTES = 256
"The text that starts the name of every coordinate system symbol."
const GDB_IPJ_PREFIX = "?|IPJ_"
"The byte offsets of the fields of an IPJ object, and the width of its text fields (research section 10)."
const GDB_IPJ_NAME = 104
const GDB_IPJ_METHOD = 168
const GDB_IPJ_DATUM = 180
const GDB_IPJ_UNITS = 452
const GDB_IPJ_TEXT_BYTES = 64

"""
    read_gdb_object(g, offset)

The class name (`"REG"`, `"IPJ"`, `"EXT"`) and the bytes of the framed admin
object at byte `offset`, as `blob_offset` gives it. The bytes run from the blob
start to `+28 + payload length` (the payload length is the int32 at +24).
`nothing` when the frame `ff 00 f0 0f` is not at +28, or when the object is too
short for its class name or runs past the blob's pages.
"""
function read_gdb_object(g::GdbFile, offset::Int)::Union{Nothing,Tuple{String,Vector{UInt8}}}
    seek(g.io, offset)
    head = read(g.io, 28)
    length(head) == 28 || return nothing
    len = gdb_word(head, 24)
    n = 28 + len
    GDB_OBJECT_MEMBER <= n <= gdb_word(head, 4) * g.header.page_size || return nothing
    seek(g.io, offset)
    b = read(g.io, n)
    length(b) == n && view(b, 29:32) == GDB_OBJECT_FRAME || return nothing
    # The class name is an identifier, not user text, so it never marks the Windows-1252 fallback.
    class, _ = gdb_text(view(b, GDB_OBJECT_CLASS + 1:GDB_OBJECT_MEMBER))
    return (class, b)
end

"The text of `bytes` up to the first NUL; sets `g.cp1252` when it used the fallback."
function gdb_text!(g::GdbFile, bytes::AbstractVector{UInt8})::String
    text, fallback = gdb_text(bytes)
    g.cp1252 |= fallback
    return text
end

"""
    gdb_registry(g, bytes)
    gdb_registry(bytes)

The entries of the `REG` object `bytes` (research section 9.1): the count `n`
at +124, then `n` slots of 256 bytes, each `KEY\\0value\\0`. A slot with an
empty key is left out; a slot with no NUL is a key with an empty value. The
method with `g` sets `g.cp1252` when any text used the Windows-1252 fallback.
Throws `GdbError` when `n` is negative or the slots run past the bytes.
"""
function gdb_registry(g::Union{Nothing,GdbFile}, bytes::AbstractVector{UInt8})::Dict{String,String}
    length(bytes) >= GDB_REG_COUNT + 4 || throw(GdbError("the registry entries run past the end of the object"))
    n = gdb_word(bytes, GDB_REG_COUNT)
    n >= 0 || throw(GdbError("the registry has a negative number of entries ($n)"))
    first = GDB_REG_COUNT + 4
    first + n * GDB_REG_SLOT_BYTES <= length(bytes) ||
        throw(GdbError("the registry entries run past the end of the object"))
    text(b) = g === nothing ? gdb_text(b)[1] : gdb_text!(g, b)
    out = Dict{String,String}()
    for k in 0:n - 1
        slot = view(bytes, first + k * GDB_REG_SLOT_BYTES + 1:first + (k + 1) * GDB_REG_SLOT_BYTES)
        nul = findfirst(iszero, slot)
        nul == 1 && continue
        key = text(slot)
        out[key] = nul === nothing ? "" : text(view(slot, nul + 1:GDB_REG_SLOT_BYTES))
    end
    return out
end
gdb_registry(bytes::AbstractVector{UInt8})::Dict{String,String} = gdb_registry(nothing, bytes)

"""
A coordinate system object (research section 10): the full name, which is an
EPSG name or a Geosoft custom name starting with `*`, the method (1 geographic,
11 Transverse Mercator, ...), the datum and the units (`m`, `dega`, ...).
"""
struct GdbIpj
    name::String
    method::Int
    datum::String
    units::String
end

"""
    gdb_ipj(g, bytes)
    gdb_ipj(bytes)

The coordinate system in the `IPJ` object `bytes`: the name at +104, the method
at +168, the datum at +180 and the units at +452. The method with `g` sets
`g.cp1252` when any text used the Windows-1252 fallback. Throws `GdbError`
when the object is too short for these fields.
"""
function gdb_ipj(g::Union{Nothing,GdbFile}, bytes::AbstractVector{UInt8})::GdbIpj
    length(bytes) >= GDB_IPJ_UNITS + GDB_IPJ_TEXT_BYTES ||
        throw(GdbError("the coordinate system object is too short for its fields"))
    text(off) = (b = view(bytes, off + 1:off + GDB_IPJ_TEXT_BYTES); g === nothing ? gdb_text(b)[1] : gdb_text!(g, b))
    return GdbIpj(text(GDB_IPJ_NAME), gdb_word(bytes, GDB_IPJ_METHOD), text(GDB_IPJ_DATUM), text(GDB_IPJ_UNITS))
end
gdb_ipj(bytes::AbstractVector{UInt8})::GdbIpj = gdb_ipj(nothing, bytes)

"""
The metadata of a Geosoft database: the database registry (`dbreg`), the
channel registries by 0-based channel slot (`channel_reg`), and the coordinate
systems as `(x name, y name, ipj)` in symbol order (`ipj`). The names in `ipj`
are the names in the file; their channels may not be live.
"""
struct GdbMeta
    dbreg::Dict{String,String}
    channel_reg::Dict{Int,Dict{String,String}}
    ipj::Vector{Tuple{String,String,GdbIpj}}
end

"""
    gdb_ipj_channels(name)

The X and Y channel names in the coordinate system symbol `name`
(`?|IPJ_<X>:<Y>`), or `nothing` when the name has no `:`, more than one, or an
empty channel name.
"""
function gdb_ipj_channels(name::String)::Union{Nothing,Tuple{String,String}}
    parts = split(chopprefix(name, GDB_IPJ_PREFIX), ':')
    length(parts) == 2 && all(!isempty, parts) || return nothing
    return (String(parts[1]), String(parts[2]))
end

"""
    read_gdb_meta(g, symbols)

The metadata of `g` and its warnings. `symbols` are the live blob symbols from
`read_gdb_blob_symbols`. Reads `__dbreg`, the registry `__<n>` of each channel
handle `n` (`chan_handle0 <= n < user_handle0`, channel slot
`n - chan_handle0`), and every `?|IPJ_<X>:<Y>` object. Line registries and
other objects are not read.

A listed object with no live directory slot, one whose slot misses its blob, a
broken frame, the wrong class or bad contents each give the warning
`"the <name> object of the file is damaged; it was skipped"`, never an error.
An IPJ name that does not name two channels is skipped with a warning too.
"""
function read_gdb_meta(g::GdbFile, symbols::Vector{Tuple{Int,String}})::Tuple{GdbMeta,Vector{String}}
    h = g.header
    meta = GdbMeta(Dict{String,String}(), Dict{Int,Dict{String,String}}(), Tuple{String,String,GdbIpj}[])
    warns = String[]
    for (k, name) in symbols
        pair = nothing
        if name == "__dbreg"
            want, chan = "REG", -1
        elseif (m = match(r"^__([1-9][0-9]{0,8}|0)$", name)) !== nothing
            n = parse(Int, something(m[1]))
            h.chan_handle0 <= n < h.user_handle0 || continue
            want, chan = "REG", n - h.chan_handle0
        elseif startswith(name, GDB_IPJ_PREFIX)
            pair = gdb_ipj_channels(name)
            if pair === nothing
                push!(warns, "the coordinate system object $name of the file does not name two channels; it was skipped")
                continue
            end
            want, chan = "IPJ", -1
        else
            continue
        end
        try
            off = blob_offset(g, h.first_admin + k)
            obj = off === nothing ? nothing : read_gdb_object(g, off)
            obj === nothing && throw(GdbError("no $want object"))
            class, bytes = obj
            class == want || throw(GdbError("not a $want object"))
            if want == "IPJ"
                x, y = something(pair)
                push!(meta.ipj, (x, y, gdb_ipj(g, bytes)))
            elseif chan >= 0
                meta.channel_reg[chan] = gdb_registry(g, bytes)
            else
                merge!(meta.dbreg, gdb_registry(g, bytes))
            end
        catch e
            e isa GdbError || rethrow()
            push!(warns, "the $name object of the file is damaged; it was skipped")
        end
    end
    return meta, warns
end

"""
    gdb_crs(ipj, x, y)

The coordinate system of the pair `x`, `y` (JuliaMag channel names) from the
file's `ipj`: `("EPSG:n", nothing)` when `crs_from_name` finds the name, else
`("", warning)`. A name whose projection part starts with `*` (the whole name,
or the part after `/ `) is a Geosoft custom system with no EPSG code.
"""
function gdb_crs(ipj::GdbIpj, x::String, y::String)::Tuple{String,Union{Nothing,String}}
    tail = "Set the coordinate system of $x, $y in the database."
    isempty(strip(ipj.name)) && return ("", "the coordinate system of $x, $y in the file has no name. $tail")
    occursin(r"(^|/ )\*", ipj.name) &&
        return ("", "the coordinate system $(ipj.name) is a Geosoft custom system with no EPSG code. $tail")
    code = crs_from_name(ipj.name)
    code === nothing && return ("", "JuliaMag does not know the coordinate system $(ipj.name). $tail")
    return (code, nothing)
end
