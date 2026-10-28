# Splitting a row of a CSV or other text file into fields, and reading numbers.
#
# A row is split by byte index into field ranges; nothing is allocated for an
# unquoted or simply quoted field. Numbers with a decimal point use `parse_field`;
# numbers with a decimal comma use Parsers, which reads the bytes in place.
# Quoted fields with `""` inside and text values allocate.

import Parsers

const BYTE_QUOTE = UInt8('"')
const BYTE_COMMA = UInt8(',')
const BYTE_POINT = UInt8('.')

const SPLIT_DELIMITED = 0x00
const SPLIT_BLANKS = 0x01
const SPLIT_FIXED = 0x02

const FIELD_PLAIN = 0x00
const FIELD_QUOTED = 0x01          # the range is inside the quotes
const FIELD_QUOTED_QUOTES = 0x02   # quoted, with `""` inside: the text must be unescaped

"Options for numbers with a decimal comma. No delimiter or quotes: the field range is already cut."
const COMMA_NUMBER = Parsers.Options(decimal = BYTE_COMMA, delim = nothing, quoted = false, stripwhitespace = true)

"""
Splits the rows of a file. The byte range of field `k` is `starts[k]:stops[k]`
and `flags[k]` says whether it was quoted. The vectors are not grown while a
file is read; `extra` is true when a field past them has text. `junk` is the
first field (0 for none) with text between its closing quote and the next
delimiter; that text is not part of the field.
"""
mutable struct FieldSplitter
    mode::UInt8
    delim::UInt8
    decimal::UInt8
    widths::Vector{Int}
    starts::Vector{Int}
    stops::Vector{Int}
    flags::Vector{UInt8}
    extra::Bool
    junk::Int
end

"""
    FieldSplitter(delimiter, decimal, widths, cap)

A splitter for fields split by `delimiter` (`' '` means runs of spaces and tabs),
or of fixed `widths` in characters when that is not empty. `decimal` is `'.'` or `','`.
"""
function FieldSplitter(delimiter::Char, decimal::Char, widths::Vector{Int}, cap::Int)
    mode = !isempty(widths) ? SPLIT_FIXED : delimiter == ' ' ? SPLIT_BLANKS : SPLIT_DELIMITED
    d = isascii(delimiter) ? UInt8(delimiter) : BYTE_COMMA
    return FieldSplitter(mode, d, decimal == ',' ? BYTE_COMMA : BYTE_POINT, copy(widths),
                         Vector{Int}(undef, cap), Vector{Int}(undef, cap), Vector{UInt8}(undef, cap), false, 0)
end

"True for space or tab, except when it is the delimiter itself."
@inline is_pad(b::UInt8, delim::UInt8) = (b == 0x20 || b == 0x09) && b != delim

@inline function put_field!(sp::FieldSplitter, count::Int, a::Int, e::Int, flag::UInt8)
    if count <= length(sp.starts)
        @inbounds sp.starts[count] = a
        @inbounds sp.stops[count] = e
        @inbounds sp.flags[count] = flag
    elseif e >= a
        sp.extra = true
    end
    return nothing
end

"""
Read a quoted field that starts with the quote at `k`. Returns `(a, e, flag, next)`:
the content range, the flag, and the byte after the closing quote. A field with no
closing quote runs to the end of the line.
"""
@inline function quoted_field(s::String, k::Int, j::Int)
    a = k + 1
    flag = FIELD_QUOTED
    k = a
    @inbounds while k <= j
        if codeunit(s, k) == BYTE_QUOTE
            if k < j && codeunit(s, k + 1) == BYTE_QUOTE
                flag = FIELD_QUOTED_QUOTES
                k += 2
                continue
            end
            break
        end
        k += 1
    end
    return a, k - 1, flag, k + 1
end

"""
    split_fields!(sp, s, i, j) -> count

Split bytes `i:j` of `s` into fields. Returns the number of fields.
No memory is allocated.
"""
function split_fields!(sp::FieldSplitter, s::String, i::Int, j::Int)::Int
    sp.extra = false
    sp.junk = 0
    sp.mode == SPLIT_FIXED && return split_fixed!(sp, s, i, j)
    sp.mode == SPLIT_BLANKS && return split_blanks!(sp, s, i, j)
    d = sp.delim
    count = 0
    k = i
    @inbounds while true
        while k <= j && is_pad(codeunit(s, k), d)
            k += 1
        end
        count += 1
        if k <= j && codeunit(s, k) == BYTE_QUOTE
            a, e, flag, k = quoted_field(s, k, j)
            # Text between the closing quote and the delimiter is not part of the field.
            while k <= j && codeunit(s, k) != d
                is_pad(codeunit(s, k), d) || (sp.junk == 0 && (sp.junk = count))
                k += 1
            end
        else
            a = k
            while k <= j && codeunit(s, k) != d
                k += 1
            end
            e = k - 1
            while e >= a && is_pad(codeunit(s, e), d)
                e -= 1
            end
            flag = FIELD_PLAIN
        end
        put_field!(sp, count, a, e, flag)
        k > j && break
        k += 1            # past the delimiter; a delimiter at the end makes one more, empty field
    end
    return count
end

"Fields split by runs of spaces and tabs. Quoted fields may hold spaces."
function split_blanks!(sp::FieldSplitter, s::String, i::Int, j::Int)::Int
    count = 0
    k = i
    @inbounds while true
        while k <= j && is_blank(codeunit(s, k))
            k += 1
        end
        k > j && break
        count += 1
        if codeunit(s, k) == BYTE_QUOTE
            a, e, flag, k = quoted_field(s, k, j)
            while k <= j && !is_blank(codeunit(s, k))
                sp.junk == 0 && (sp.junk = count)
                k += 1
            end
        else
            a = k
            while k <= j && !is_blank(codeunit(s, k))
                k += 1
            end
            e = k - 1
            flag = FIELD_PLAIN
        end
        put_field!(sp, count, a, e, flag)
    end
    return count
end

"""
Fields of fixed widths in characters, counted from byte `i`, the start of the row.
A row that ends inside a column gives a short last field.
"""
function split_fixed!(sp::FieldSplitter, s::String, i::Int, j::Int)::Int
    count = 0
    k = i
    @inbounds for w in sp.widths
        k > j && break
        a = k
        n = 0
        while n < w && k <= j
            k = codeunit(s, k) < 0x80 ? k + 1 : nextind(s, k)
            n += 1
        end
        e = min(k - 1, j)
        while a <= e && is_blank(codeunit(s, a))
            a += 1
        end
        while e >= a && is_blank(codeunit(s, e))
            e -= 1
        end
        count += 1
        put_field!(sp, count, a, e, FIELD_PLAIN)
    end
    return count
end

"True when field `k` is empty or `*`."
@inline function field_missing(sp::FieldSplitter, s::String, k::Int)::Bool
    @inbounds a, e = sp.starts[k], sp.stops[k]
    return a > e || (a == e && codeunit(s, a) == UInt8('*'))
end

"The text of a quoted field with `\"\"` inside, unescaped."
unescape_field(s::String, a::Int, e::Int)::String = replace(field_text(s, a, e), "\"\"" => "\"")

"True when bytes `a:e` of `s` equal `word`, ignoring the case of ASCII letters."
@inline function same_word_ci(s::String, a::Int, e::Int, word::String)::Bool
    e - a + 1 == ncodeunits(word) || return false
    @inbounds for k in 0:(e - a)
        codeunit(s, a + k) | 0x20 == codeunit(word, k + 1) || return false
    end
    return true
end

"""
True when bytes `a:e` of `s` look like a number with the decimal mark `decimal`:
blanks around it, a sign, then either `inf`, `infinity` or `nan` (any case), or
only digits, the decimal mark, `e`, `E`, `+` and `-`. The parser then checks the
order of those. This keeps the two decimal marks to one rule: the point path
alone would also read hex such as `0x10`, the comma path alone `1f5`.
"""
@inline function number_shape(s::String, a::Int, e::Int, decimal::UInt8)::Bool
    @inbounds while a <= e && is_blank(codeunit(s, a))
        a += 1
    end
    @inbounds while e >= a && is_blank(codeunit(s, e))
        e -= 1
    end
    a > e && return false
    b = codeunit(s, a)
    (b == UInt8('+') || b == UInt8('-')) && (a += 1)
    a > e && return false
    if is_ascii_letter(codeunit(s, a))
        return same_word_ci(s, a, e, "inf") || same_word_ci(s, a, e, "infinity") || same_word_ci(s, a, e, "nan")
    end
    @inbounds for k in a:e
        b = codeunit(s, k)
        (UInt8('0') <= b <= UInt8('9') || b == decimal || b == UInt8('e') || b == UInt8('E') ||
         b == UInt8('+') || b == UInt8('-')) || return false
    end
    return true
end

"""
    parse_number(s, a, e, decimal) -> Union{Float64,Nothing}

Bytes `a:e` of `s` as a number, or `nothing`. `decimal` is the byte of the decimal
mark, `.` or `,`. Both marks follow the same rule (see `number_shape`): `1.`, `.5`,
`1.e5`, `inf` and `nan` are numbers, and the same with `,`. With a decimal comma
the whole field must be the number, so `1.5` and `1,5,3` are not numbers.
No memory is allocated.
"""
@inline function parse_number(s::String, a::Int, e::Int, decimal::UInt8)::Union{Float64,Nothing}
    number_shape(s, a, e, decimal) || return nothing
    decimal == BYTE_POINT && return parse_field(s, a, e)
    r = Parsers.xparse(Float64, codeunits(s), a, e, COMMA_NUMBER)
    return Parsers.ok(r.code) && r.tlen == e - a + 1 ? r.val : nothing
end

"Field `k` as a number, or `nothing`. Allocates only for a quoted field with `\"\"` inside."
@inline function field_number(sp::FieldSplitter, s::String, k::Int)::Union{Float64,Nothing}
    @inbounds a, e, flag = sp.starts[k], sp.stops[k], sp.flags[k]
    a > e && return nothing
    if flag == FIELD_QUOTED_QUOTES
        t = unescape_field(s, a, e)
        return parse_number(t, 1, ncodeunits(t), sp.decimal)
    end
    return parse_number(s, a, e, sp.decimal)
end

"True when `t` is a number with the decimal mark `decimal` (`'.'` or `','`)."
function isnumbertext(t::AbstractString, decimal::Char = '.')::Bool
    u = String(strip(t))
    return !isempty(u) && parse_number(u, 1, ncodeunits(u), decimal == ',' ? BYTE_COMMA : BYTE_POINT) !== nothing
end

"Field `k` as text."
function field_string(sp::FieldSplitter, s::String, k::Int)::String
    a, e, flag = sp.starts[k], sp.stops[k], sp.flags[k]
    a > e && return ""
    return flag == FIELD_QUOTED_QUOTES ? unescape_field(s, a, e) : field_text(s, a, e)
end

"Split a line into its field texts, growing the vectors as needed. For sniff and preview."
function split_texts(sp::FieldSplitter, line::AbstractString)::Vector{String}
    s = String(line)
    j = ncodeunits(s)
    n = split_fields!(sp, s, 1, j)
    if n > length(sp.starts)
        resize!(sp.starts, n)
        resize!(sp.stops, n)
        resize!(sp.flags, n)
        split_fields!(sp, s, 1, j)
    end
    return String[field_string(sp, s, k) for k in 1:n]
end

isblankline(t::AbstractString) = all(c -> c == ' ' || c == '\t', t)
