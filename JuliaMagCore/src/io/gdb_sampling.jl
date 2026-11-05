# The sampling of a line in a Geosoft database (`.gdb`), and resampling.
#
# Oasis keeps a fiducial start and step per channel and line; JuliaMag keeps
# one per line (spec 5.3, research section 8). Ruling 4 of the gdb import
# plan: a line takes the sampling most of its channels share, and a channel
# with another sampling is resampled onto it by linear interpolation. Missing
# values are not interpolated across. Integers round to the nearest value,
# with ties away from zero; text takes the nearer row.

"A fiducial start and step: row `r` (1-based) is at `start + (r - 1) * step`."
struct Sampling
    start::Float64
    step::Float64
end

"""
    same_sampling(a, b)

True when the steps are equal within `1e-9` of their size and the starts within
`1e-6` of a step.
"""
function same_sampling(a::Sampling, b::Sampling)::Bool
    abs(a.step - b.step) <= 1e-9 * max(abs(a.step), abs(b.step)) || return false
    return abs(a.start - b.start) <= 1e-6 * abs(a.step)
end

"""
    main_sampling(list)

The sampling the most entries of `list` share (by `same_sampling`). On a tie,
the one that comes first in `list`, which is in display order. Throws an
`ArgumentError` for an empty list.
"""
function main_sampling(list::Vector{Sampling})::Sampling
    isempty(list) && throw(ArgumentError("main_sampling needs at least one sampling"))
    best, most = 1, 0
    for (i, s) in enumerate(list)
        n = count(t -> same_sampling(s, t), list)
        n > most && ((best, most) = (i, n))
    end
    return list[best]
end

"Tolerance, in source rows, for an output row to take a source row as it is."
const GDB_ROW_HIT = 1e-6

"""
    resample!(out, src, from, to, rows, width) -> out

Fill `out` (`rows * width` values) with `src` (`n * width` values, one row
after the other) resampled from the sampling `from` onto `to`. Output row `r`
is at source position `x = (to.start + (r - 1) * to.step - from.start) /
from.step` (0-based):

- `x` within `1e-6` of a row: that row's value, also when it is missing;
- between two rows that are both not missing: floats interpolate; integers
  interpolate and round to the nearest value, ties away from zero, never to
  the missing marker; text takes the nearer row, the earlier one on a tie;
- else (outside the source, next to a missing value, or a sampling with a
  step of 0 or a value that is not finite): missing.

Each of the `width` values of a row is done on its own. Throws an
`ArgumentError` when the lengths do not fit `rows` and `width`.
"""
function resample!(out::AbstractVector{T}, src::AbstractVector{T}, from::Sampling, to::Sampling,
                   rows::Int, width::Int) where {T}
    width >= 1 || throw(ArgumentError("width must be 1 or more, not $width"))
    rows >= 0 && length(out) == rows * width ||
        throw(ArgumentError("out has $(length(out)) values, not $rows rows of $width"))
    length(src) % width == 0 || throw(ArgumentError("src has $(length(src)) values, not whole rows of $width"))
    resample_rows!(out, src, from, to, rows, width)
    return out
end

"The loop of `resample!`, a function barrier with concrete argument types."
function resample_rows!(out::AbstractVector{T}, src::AbstractVector{T}, from::Sampling, to::Sampling,
                        rows::Int, width::Int) where {T}
    n = length(src) ÷ width
    m = missing_value(T)
    usable(s) = isfinite(s.start) && isfinite(s.step) && s.step != 0
    ok = usable(from) && usable(to)
    @inbounds for r in 1:rows
        o = (r - 1) * width
        x = ok ? (to.start + (r - 1) * to.step - from.start) / from.step : NaN
        if !(isfinite(x) && -GDB_ROW_HIT <= x <= n - 1 + GDB_ROW_HIT)
            for c in 1:width
                out[o + c] = m
            end
            continue
        end
        k = round(Int, x)
        if abs(x - k) <= GDB_ROW_HIT
            s = clamp(k, 0, n - 1) * width
            for c in 1:width
                out[o + c] = src[s + c]
            end
            continue
        end
        k = floor(Int, x)
        f = x - k
        s = k * width
        for c in 1:width
            a, b = src[s + c], src[s + width + c]
            out[o + c] = (ismissingvalue(a) || ismissingvalue(b)) ? m : gdb_between(a, b, f)
        end
    end
    return out
end

"The value a fraction `f` (between 0 and 1) of the way from `a` to `b`."
gdb_between(a::T, b::T, f::Float64) where {T<:AbstractFloat} = T(a + (b - a) * f)
gdb_between(a::String, b::String, f::Float64) = f <= 0.5 ? a : b
function gdb_between(a::T, b::T, f::Float64)::T where {T<:Integer}
    v = round(Float64(a) + (Float64(b) - Float64(a)) * f, RoundNearestTiesAway)
    lo, hi = T <: Signed ? (typemin(T) + one(T), typemax(T)) : (typemin(T), typemax(T) - one(T))
    v <= Float64(lo) && return lo
    v >= Float64(hi) && return hi
    return T(v)
end
