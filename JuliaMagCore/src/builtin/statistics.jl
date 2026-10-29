# Channel statistics (spec 9.3, "Statistics pane").
#
# `channel_stats` reads the channel in blocks with a `block_reader`, so memory
# stays flat however long the lines are. It reads the data at least three times:
#
# 1. Count, missing, min, max, and the sum for the mean (a compensated sum,
#    so the mean is as exact as one division allows).
# 2. The histogram, and the sum of squared distances from the mean for the
#    standard deviation (the two-pass method, with its small correction term).
# 3. Median, p5 and p95: passes that narrow a value range around each wanted
#    rank until few enough values are left to collect (see "exact quantiles").
#    Usually one or two passes; one extreme value adds at most one.
#
# Precision: median, p5 and p95 are exact. The quantile is the one
# `Statistics.quantile` gives by default: linear between the two nearest values
# in sorted order. (Only data made to defeat the fine bins, which still has more
# than 100,000 values in the range after 64 passes, gets a value read between
# the ends of that range, which is then about 1024^64 times narrower than max - min.)
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

"Fine bins per refining pass of the quantiles."
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

"The ranks (from 1) whose values give quantile `q` of `n` values, and the weight of the second."
function quantile_ranks(n::Int, q::Float64)::Tuple{Int,Int,Float64}
    h = (n - 1) * q + 1
    lo = floor(Int, h)
    return lo, min(lo + 1, n), h - lo
end

# ---- exact quantiles -------------------------------------------------------
#
# A value of known rank is found by narrowing a value range [lo, hi] that holds it.
# The count of values in the range, and the rank of the wanted one among them,
# are known.
# - With few enough values in the range (`STATS_COLLECT`), a pass collects them,
#   and a partial sort gives the exact value.
# - Else a pass counts the values of the range in `STATS_FINE` fine bins, noting
#   the smallest and largest value of each. The fine bin that holds the rank
#   becomes the new range, cut to its smallest and largest value. So the range
#   shrinks to where the data is, and one extreme value costs at most one pass.
# A rank that is the first or last value of its fine bin, or a fine bin of equal
# values, is exact at once. The fine bins are ordered by value, so the values in
# a fine bin are exactly the data values from its smallest to its largest.

"Most values collected for one wanted rank."
const STATS_COLLECT = 100_000

"""
Most refining passes. Only data made to defeat the fine bins needs more (each
pass cuts the range at least 1024 times). Then the value is read between the
ends of the last range, and is within that range of the exact value.
"""
const STATS_MAX_PASSES = 64

"A search for the value of one rank: the range that holds it, the count of values in it, and the rank among them."
mutable struct RankSearch
    lo::Float64
    hi::Float64
    count::Int
    rank::Int
    value::Float64
    done::Bool
    "Collected values (when the range holds at most `STATS_COLLECT` values)."
    values::Vector{Float64}
    "Fine bins (when it holds more): count, smallest and largest value of each."
    fcount::Vector{Int}
    flo::Vector{Float64}
    fhi::Vector{Float64}
end

RankSearch(lo::Float64, hi::Float64, count::Int, rank::Int) =
    RankSearch(lo, hi, count, rank, NaN, false, Float64[], Int[], Float64[], Float64[])

collecting(r::RankSearch) = r.count <= STATS_COLLECT

"One pass over the data, for the searches that are not done."
struct RefinePass
    searches::Vector{RankSearch}
end

function add_value!(p::RefinePass, x::Float64)
    isfinite(x) || return nothing
    for r in p.searches
        (x < r.lo || x > r.hi) && continue
        if collecting(r)
            push!(r.values, x)
        else
            w = r.hi / STATS_FINE - r.lo / STATS_FINE        # divide first: no overflow
            j = w > 0 ? floor((x - r.lo) / w) : 0.0             # 0 only for tiny subnormal ranges
            i = j < 0 ? 1 : j >= STATS_FINE ? STATS_FINE : Int(j) + 1
            r.fcount[i] += 1
            x < r.flo[i] && (r.flo[i] = x)
            x > r.fhi[i] && (r.fhi[i] = x)
        end
    end
    return nothing
end

"Make the search ready for its next pass."
function prepare!(r::RankSearch)
    if collecting(r)
        r.values = sizehint!(Float64[], r.count)
    else
        r.fcount = zeros(Int, STATS_FINE)
        r.flo = fill(Inf, STATS_FINE)
        r.fhi = fill(-Inf, STATS_FINE)
    end
    return nothing
end

changed_error() = DatabaseError("the channel changed while its statistics were read")

"After a pass: find the value, or narrow the range. With `last`, the value must be found now."
function settle!(r::RankSearch, last::Bool)
    if collecting(r)
        length(r.values) == r.count || throw(changed_error())
        r.value, r.done = partialsort!(r.values, r.rank), true
        r.values = Float64[]
        return nothing
    end
    seen = 0
    for i in 1:STATS_FINE
        c = r.fcount[i]
        if seen + c >= r.rank
            j = r.rank - seen
            if j == 1 || r.flo[i] == r.fhi[i]
                r.value, r.done = r.flo[i], true
            elseif j == c
                r.value, r.done = r.fhi[i], true
            elseif last
                r.value, r.done = r.flo[i] + (r.fhi[i] - r.flo[i]) * (j - 1) / (c - 1), true
            else
                r.lo, r.hi, r.count, r.rank = r.flo[i], r.fhi[i], c, j
            end
            r.fcount, r.flo, r.fhi = Int[], Float64[], Float64[]
            return nothing
        end
        seen += c
    end
    throw(changed_error())
end

"""
The values of the ranks `ranks` (from 1) among the `n` finite values, which lie
from `lo` to `hi`. Exact (see above). Memory stays below `STATS_COLLECT` values
per rank.
"""
function values_of_ranks(db::LineDatabase, name::AbstractString, ls::Vector{LineInfo}, lo::Float64,
                         hi::Float64, n::Int, ranks::Vector{Int})::Dict{Int,Float64}
    searches = Dict{Int,RankSearch}(r => RankSearch(lo, hi, n, r) for r in unique(ranks))
    for pass in 1:STATS_MAX_PASSES
        open = RankSearch[r for r in values(searches) if !r.done]
        isempty(open) && break
        foreach(prepare!, open)
        read_pass!(RefinePass(open), db, name, ls)
        foreach(r -> settle!(r, pass == STATS_MAX_PASSES), open)
    end
    return Dict{Int,Float64}(k => r.value for (k, r) in searches)
end

# ---- channel_stats ---------------------------------------------------------

"""
    channel_stats(db, channel; lines = <all lines with data>, bins = 64)::ChannelStats

Statistics of a channel of numbers over the lines with ids `lines`.
Reads the channel in blocks, so memory stays flat. Count, missing, min, max and
mean are exact. The standard deviation uses two passes. Median, p5 and p95 are
exact; they take one or more extra passes (see the top of `statistics.jl`).
A channel with no values gives count 0 and `NaN`s.

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
        quantiles(db, name, ls, p1.min, p1.max, n)
    end
    return ChannelStats(n, p1.missing, p1.min, p1.max, mean, std, qs[1], qs[2], qs[3], p2.hist, edges)
end

"The values of `STATS_QUANTILES`, exact (see `values_of_ranks`)."
function quantiles(db::LineDatabase, name::AbstractString, ls::Vector{LineInfo}, lo::Float64, hi::Float64,
                   n::Int)::Vector{Float64}
    ranks = [quantile_ranks(n, q) for q in STATS_QUANTILES]
    v = values_of_ranks(db, name, ls, lo, hi, n, Int[r for (a, b, _) in ranks for r in (a, b)])
    return Float64[w == 0 ? v[a] : v[a] + w * (v[b] - v[a]) for (a, b, w) in ranks]
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
