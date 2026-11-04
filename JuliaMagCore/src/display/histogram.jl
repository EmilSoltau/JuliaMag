# Fine histograms of channel or grid values, for percent clips and histogram
# equalization. Pure functions, safe on the render thread.

const HIST_BINS = 4096

"""
A histogram of values between `lo` and `hi` in `HIST_BINS` equal bins. Values outside
the limits are not counted. `total` is the number of values counted.
"""
mutable struct ValueHistogram
    lo::Float64
    hi::Float64
    counts::Vector{Int}
    total::Int
end

ValueHistogram(lo::Real, hi::Real) = ValueHistogram(Float64(lo), Float64(hi), zeros(Int, HIST_BINS), 0)
ValueHistogram() = ValueHistogram(NaN, NaN)

"Empty the histogram and give it new limits. Does not allocate."
function reset!(h::ValueHistogram, lo::Real, hi::Real)
    fill!(h.counts, 0)
    h.lo = lo
    h.hi = hi
    h.total = 0
    return h
end

"Add the values to the histogram. Skips `NaN` and missing values."
function add_values!(h::ValueHistogram, v::AbstractVector{<:Real})
    lo, hi = h.lo, h.hi
    (isnan(lo) || isnan(hi)) && return h
    width = hi - lo
    counts = h.counts
    n = 0
    @inbounds for x in v
        ismissingvalue(x) && continue
        y = Float64(x)
        (isnan(y) || y < lo || y > hi) && continue
        b = width > 0 ? min(floor(Int, (y - lo) / width * HIST_BINS), HIST_BINS - 1) + 1 : 1
        counts[b] += 1
        n += 1
    end
    h.total += n
    return h
end

"""
    quantile_value(h, p) -> Float64

The value below which a fraction `p` of the values lie, linear inside a bin.
`NaN` when the histogram is empty.
"""
function quantile_value(h::ValueHistogram, p::Real)::Float64
    h.total == 0 && return NaN
    target = clamp(p, 0, 1) * h.total
    width = (h.hi - h.lo) / HIST_BINS
    before = 0
    @inbounds for b in 1:HIST_BINS
        c = h.counts[b]
        if c > 0 && before + c >= target
            return h.lo + (b - 1 + (target - before) / c) * width
        end
        before += c
    end
    return h.hi
end

"""
    equalize_table!(out, h)

Fill `out` so that entry k is the fraction of values below
`lo + (k - 1) / (n - 1) * (hi - lo)`, linear inside bins. The entries do not decrease
and the last is 1. An empty histogram gives a straight ramp. Does not allocate.
"""
function equalize_table!(out::AbstractVector{Float32}, h::ValueHistogram)
    n = length(out)
    n == 0 && return out
    if h.total == 0 || !(h.hi > h.lo)
        for k in 1:n
            out[k] = n == 1 ? 1f0 : Float32((k - 1) / (n - 1))
        end
        return out
    end
    cum = 0       # values in the bins before bin `b`
    b = 0
    inv_total = 1 / h.total
    @inbounds for k in 1:n
        u = n == 1 ? Float64(HIST_BINS) : (k - 1) / (n - 1) * HIST_BINS
        want = min(floor(Int, u), HIST_BINS - 1)
        while b < want
            cum += h.counts[b+1]
            b += 1
        end
        out[k] = Float32(min((cum + h.counts[b+1] * (u - b)) * inv_total, 1.0))
    end
    out[n] = 1f0
    return out
end

"The equalization table of `h` with `n` entries. See `equalize_table!`."
equalize_table(h::ValueHistogram; n::Integer = 1024)::Vector{Float32} = equalize_table!(Vector{Float32}(undef, n), h)

"""
    stretch_range(style, h) -> (lo, hi)

The value range that maps to the ends of the colour table. `:linear` uses `style.min`
and `style.max` (the histogram limits where they are `NaN`), `:clip` cuts the
percentages `clip_low` and `clip_high`, `:histeq` uses the histogram limits.
"""
function stretch_range(st::LayerStyle, h::ValueHistogram)::NTuple{2,Float64}
    if st.stretch === :linear
        return (isnan(st.min) ? h.lo : st.min, isnan(st.max) ? h.hi : st.max)
    elseif st.stretch === :clip
        return (quantile_value(h, st.clip_low / 100), quantile_value(h, 1 - st.clip_high / 100))
    end
    return (h.lo, h.hi)
end
