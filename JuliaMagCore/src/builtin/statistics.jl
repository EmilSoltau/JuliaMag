# Channel statistics (spec 9.3, "Statistics pane").
#
# `channel_stats` reads the channel in blocks with a `block_reader`, so memory
# stays flat however long the lines are. It reads the data three times:
#
# 1. Count, missing, min, max, and the sum for the mean (a compensated sum,
#    so the mean is as exact as one division allows).
# 2. The histogram, and the sum of squared distances from the mean for the
#    standard deviation (the two-pass method, with its small correction term).
# 3. Finer bins inside the histogram bins that hold the median, p5 and p95.
#    Each such bin is cut into 1024 fine bins that also note their smallest and
#    largest value.
#
# Precision: median, p5 and p95 are within one fine bin, (max - min) / (bins * 1024),
# of the exact value. They are exact when each needed value is alone in its
# fine bin, as with small data. The quantile is the one `Statistics.quantile`
# gives by default: linear between the two nearest values in sorted order.
#
# Values that are missing or not finite (NaN, Inf, -Inf) count as missing.
# Every value of an array channel counts as one value.

using Printf

"""
Statistics of one channel. `count` is the number of values used and `missing`
the number of missing (or not finite) values. `std` is the sample standard
deviation (divided by `count - 1`). `histogram` has one count per bin, between
`edges` (one more than the bins, from `min` to `max`). With no values, the
numbers are `NaN` and `histogram` and `edges` are empty.
"""
struct ChannelStats
    count::Int
    missing::Int
    min::Float64
    max::Float64
    mean::Float64
    std::Float64
    median::Float64
    p5::Float64
    p95::Float64
    histogram::Vector{Int}
    edges::Vector{Float64}
end

"Rows read at a time."
const STATS_BLOCK = 1 << 16

"Fine bins per histogram bin in the third pass."
const STATS_FINE = 1024

"The quantiles `ChannelStats` holds, in field order: median, p5, p95."
const STATS_QUANTILES = (0.5, 0.05, 0.95)

# ---- the passes ------------------------------------------------------------

"Pass 1: count, missing, min, max and a compensated sum (Neumaier)."
mutable struct FirstPass
    count::Int
    missing::Int
    min::Float64
    max::Float64
    sum::Float64
    comp::Float64
end

function add_value!(p::FirstPass, x::Float64)
    if !isfinite(x)
        p.missing += 1
        return nothing
    end
    p.count += 1
    x < p.min && (p.min = x)
    x > p.max && (p.max = x)
    t = p.sum + x
    p.comp += abs(p.sum) >= abs(x) ? (p.sum - t) + x : (x - t) + p.sum
    p.sum = t
    return nothing
end

"The bins of the histogram: `bins` bins of equal width from `min` to `max`."
struct Bins
    min::Float64
    width::Float64
    n::Int
end

# Divide each end first, so a very wide range does not overflow.
bins_between(lo::Float64, hi::Float64, n::Int) = Bins(lo, hi / n - lo / n, n)

"The bin of a finite value, from 1. All values are in bin 1 when min equals max."
function bin_of(b::Bins, x::Float64)::Int
    b.width > 0 || return 1
    k = floor((x - b.min) / b.width)
    return k < 0 ? 1 : k >= b.n ? b.n : Int(k) + 1
end

"Pass 2: the histogram, and the sums for the standard deviation around `mean`."
mutable struct SecondPass
    bins::Bins
    mean::Float64
    hist::Vector{Int}
    ss::Float64
    sd::Float64
end

function add_value!(p::SecondPass, x::Float64)
    isfinite(x) || return nothing
    p.hist[bin_of(p.bins, x)] += 1
    d = x - p.mean
    p.ss += d * d
    p.sd += d
    return nothing
end

"The fine bins of one histogram bin: counts and the smallest and largest value in each."
struct FineBins
    bin::Int
    start::Float64
    width::Float64
    count::Vector{Int}
    lo::Vector{Float64}
    hi::Vector{Float64}
end

FineBins(b::Bins, k::Int) =
    FineBins(k, b.min + (k - 1) * b.width, b.width / STATS_FINE, zeros(Int, STATS_FINE),
             fill(Inf, STATS_FINE), fill(-Inf, STATS_FINE))

"Pass 3: fine bins for the histogram bins that hold the wanted ranks."
struct ThirdPass
    bins::Bins
    fine::Vector{FineBins}
end

function add_value!(p::ThirdPass, x::Float64)
    isfinite(x) || return nothing
    k = bin_of(p.bins, x)
    for f in p.fine
        f.bin == k || continue
        j = f.width > 0 ? floor((x - f.start) / f.width) : 0.0
        i = j < 0 ? 1 : j >= STATS_FINE ? STATS_FINE : Int(j) + 1
        f.count[i] += 1
        x < f.lo[i] && (f.lo[i] = x)
        x > f.hi[i] && (f.hi[i] = x)
        break
    end
    return nothing
end

"Feed every value of the channel on `lines` to `pass`, one block at a time."
function read_pass!(pass, db::LineDatabase, name::AbstractString, lines::Vector{LineInfo})
    r = block_reader(db, name)
    try
        for l in lines, a in 1:STATS_BLOCK:l.nrows
            add_block!(pass, read_block(r, l, a:min(a + STATS_BLOCK - 1, l.nrows)))
        end
    finally
        close(r)
    end
    return pass
end

# A function barrier: the loop is compiled for the block's element type.
function add_block!(pass, block::AbstractArray)
    for x in block
        add_value!(pass, as_float(x))
    end
    return nothing
end

# ---- quantiles -------------------------------------------------------------

"The ranks (from 1) whose values give quantile `q` of `n` values, and the weight of the second."
function quantile_ranks(n::Int, q::Float64)::Tuple{Int,Int,Float64}
    h = (n - 1) * q + 1
    lo = floor(Int, h)
    return lo, min(lo + 1, n), h - lo
end

"The histogram bin that holds rank `r`, and the rank within that bin."
function bin_of_rank(hist::Vector{Int}, r::Int)::Tuple{Int,Int}
    seen = 0
    for (k, c) in enumerate(hist)
        seen + c >= r && return k, r - seen
        seen += c
    end
    throw(ArgumentError("rank $r is past the $seen values of the histogram"))
end

"The value of rank `r` within the fine bins: exact when it is alone, else read between the fine bin's ends."
function value_of_rank(f::FineBins, r::Int)::Float64
    seen = 0
    for i in 1:STATS_FINE
        c = f.count[i]
        if seen + c >= r
            j = r - seen
            (c == 1 || j == 1) && return f.lo[i]
            j == c && return f.hi[i]
            return f.lo[i] + (f.hi[i] - f.lo[i]) * (j - 1) / (c - 1)
        end
        seen += c
    end
    throw(ArgumentError("rank $r is past the $seen values of the fine bins"))
end

# ---- channel_stats ---------------------------------------------------------

"""
    channel_stats(db, channel; lines = <all lines with data>, bins = 64)::ChannelStats

Statistics of a channel of numbers over the lines with ids `lines`.
Reads the channel in blocks, so memory stays flat. Count, missing, min, max and
mean are exact. The standard deviation uses two passes. Median, p5 and p95 are
within `(max - min) / (bins * 1024)` of the exact value (see the top of
`statistics.jl`). A channel with no values gives count 0 and `NaN`s.

Throws `DatabaseError` for an unknown channel or line, and `ArgumentError` for
a text channel or fewer than 1 bin.
"""
function channel_stats(db::LineDatabase, name::AbstractString;
                       lines::AbstractVector{LineId} = LineId[l.id for l in db.lines if !is_open_line(db, l)],
                       bins::Integer = 64)::ChannelStats
    bins >= 1 || throw(ArgumentError("statistics need at least 1 bin, not $bins"))
    c = channel(db, name)
    c.eltype <: Real || throw(ArgumentError("channel $(c.name) holds text; statistics need numbers"))
    ls = LineInfo[line(db, id) for id in lines]
    p1 = read_pass!(FirstPass(0, 0, Inf, -Inf, 0.0, 0.0), db, name, ls)
    n = p1.count
    n == 0 && return ChannelStats(0, p1.missing, NaN, NaN, NaN, NaN, NaN, NaN, NaN, Int[], Float64[])
    mean = (p1.sum + p1.comp) / n
    b = bins_between(p1.min, p1.max, Int(bins))
    p2 = read_pass!(SecondPass(b, mean, zeros(Int, b.n), 0.0, 0.0), db, name, ls)
    std = n == 1 ? NaN : sqrt(max(p2.ss - p2.sd^2 / n, 0.0) / (n - 1))
    edges = Float64[b.min + k * b.width for k in 0:b.n]
    edges[end] = p1.max
    qs = if p1.min == p1.max
        fill(p1.min, length(STATS_QUANTILES))
    else
        quantiles(db, name, ls, b, p2.hist, n)
    end
    return ChannelStats(n, p1.missing, p1.min, p1.max, mean, std, qs[1], qs[2], qs[3], p2.hist, edges)
end

"The values of `STATS_QUANTILES`, from a third pass with fine bins."
function quantiles(db::LineDatabase, name::AbstractString, ls::Vector{LineInfo}, b::Bins,
                   hist::Vector{Int}, n::Int)::Vector{Float64}
    ranks = [quantile_ranks(n, q) for q in STATS_QUANTILES]
    wanted = unique!([first(bin_of_rank(hist, r)) for (lo, hi, _) in ranks for r in (lo, hi)])
    p3 = read_pass!(ThirdPass(b, [FineBins(b, k) for k in wanted]), db, name, ls)
    function value(r::Int)
        k, j = bin_of_rank(hist, r)
        return value_of_rank(p3.fine[findfirst(f -> f.bin == k, p3.fine)::Int], j)
    end
    return Float64[(v = value(lo); w == 0 ? v : v + w * (value(hi) - v)) for (lo, hi, w) in ranks]
end

# ---- the tool --------------------------------------------------------------

"A number for the statistics message, with up to 6 significant digits."
stat_text(x::Float64)::String = @sprintf("%.6g", x)

"The statistics as a short message."
function stats_message(name::String, nlines::Int, st::ChannelStats)::String
    io = IOBuffer()
    println(io, "Statistics of ", name, " on ", nlines, nlines == 1 ? " line:" : " lines:")
    println(io, "Count ", st.count, ", missing ", st.missing, ".")
    if st.count == 0
        print(io, "There are no values to describe.")
    else
        println(io, "Min ", stat_text(st.min), ", max ", stat_text(st.max), ", mean ", stat_text(st.mean),
                ", standard deviation ", stat_text(st.std), ".")
        print(io, "Median ", stat_text(st.median), ", 5th percentile ", stat_text(st.p5),
              ", 95th percentile ", stat_text(st.p95), ".")
    end
    return String(take!(io))
end

function run_statistics(s::Session, ins::Dict{String,String}, st::Dict{String,Any}, _, report::IO)
    id = ins["database"]
    name = String(st["channel"])
    # Pick the lines and mark the database as read under the lock; read without it.
    db, lines = lock(s.lock) do
        db = tool_database(s, id; allow_readers = true)
        k = channel_position(db, name)
        k == 0 && throw(ToolError("Database $id has no channel $name."))
        db.channels[k].eltype <: Real || throw(ToolError("Channel $name holds text. Statistics need numbers."))
        lines = tool_lines(s, db, id, st["lines"])
        mark_reading!(s, id)
        return db, lines
    end
    stats = try
        channel_stats(db, name; lines = LineId[l.id for l in lines], bins = st["bins"])
    finally
        unmark_reading!(s, id)
    end
    print(report, stats_message(name, length(lines), stats))
    return nothing
end

register_tool!(ToolSpec("database.statistics", "Statistics",
    "Count, min, max, mean, standard deviation, median and percentiles of a channel, with a histogram.",
    "statistics", [Place("Database Tools", "Channels")], DATABASE_INPUT,
    SettingSpec[ChannelSetting("channel", "Channel"; allow_array = true),
                LinesSetting("lines", "Lines"),
                NumberSetting("bins", "Histogram bins"; default = 64, min = 1, max = 100_000, integer = true,
                              advanced = true)],
    :quick, run_statistics))
