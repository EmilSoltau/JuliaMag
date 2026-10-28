# Channel statistics: `channel_stats` and the "database.statistics" tool.

# Quantile as `Statistics.quantile` gives it by default (linear between order statistics).
function exact_quantile(sorted::Vector{Float64}, p::Float64)
    h = (length(sorted) - 1) * p + 1
    lo = floor(Int, h)
    hi = min(lo + 1, length(sorted))
    return sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo])
end

@testset "channel statistics: the brief" begin
    st = channel_stats(make_db_with(V = [1.0, 2.0, 3.0, 4.0, NaN]).db, "V")
    @test st.count == 4 && st.missing == 1 && st.mean == 2.5 && st.min == 1.0 && st.max == 4.0
    @test st.median == 2.5 && st.std ≈ sqrt(5 / 3)
    @test length(st.histogram) == 64 && length(st.edges) == 65 && sum(st.histogram) == 4
    @test st.edges[1] == 1.0 && st.edges[end] == 4.0
end

@testset "channel statistics: precision on random data" begin
    rng = TestRng(7)
    v = [100.0 * next_unit!(rng)^3 - 20.0 for _ in 1:20_001]
    v[17] = NaN
    v[18] = Inf                            # values that are not finite count as missing
    (; db) = make_db_with(V = v)
    good = sort!(filter(isfinite, v))
    n = length(good)
    for bins in (64, 7, 1)
        st = channel_stats(db, "V"; bins)
        @test st.count == n && st.missing == 2
        @test st.min == good[1] && st.max == good[end]
        @test st.mean ≈ sum(good) / n rtol = 1e-14
        m = sum(good) / n
        @test st.std ≈ sqrt(sum((x - m)^2 for x in good) / (n - 1)) rtol = 1e-12
        width = (good[end] - good[1]) / (bins * 1024)
        @test abs(st.median - exact_quantile(good, 0.5)) <= width
        @test abs(st.p5 - exact_quantile(good, 0.05)) <= width
        @test abs(st.p95 - exact_quantile(good, 0.95)) <= width
        @test length(st.histogram) == bins && sum(st.histogram) == n
        @test length(st.edges) == bins + 1 && issorted(st.edges)
        # the histogram counts agree with the edges
        @test st.histogram[1] == count(x -> x < st.edges[2], good) || bins == 1
    end
end

@testset "channel statistics: special cases" begin
    # small data is exact: each order statistic sits alone in a fine bin
    st = channel_stats(make_db_with(V = [5.0, 1.0, 3.0]).db, "V")
    @test st.median == 3.0 && st.p5 == exact_quantile([1.0, 3.0, 5.0], 0.05) &&
          st.p95 == exact_quantile([1.0, 3.0, 5.0], 0.95) && st.p5 ≈ 1.2 && st.p95 ≈ 4.8
    # one value
    st = channel_stats(make_db_with(V = [2.0, NaN]).db, "V")
    @test st.count == 1 && st.mean == 2.0 && isnan(st.std) && st.median == 2.0 && st.p95 == 2.0
    # all values the same
    st = channel_stats(make_db_with(V = [3.0, 3.0, 3.0]).db, "V")
    @test st.std == 0.0 && st.median == 3.0 && st.histogram[1] == 3 && sum(st.histogram) == 3
    # all values missing is not an error
    st = channel_stats(make_db_with(V = [NaN, NaN]).db, "V")
    @test st.count == 0 && st.missing == 2
    @test all(isnan, (st.min, st.max, st.mean, st.std, st.median, st.p5, st.p95))
    @test isempty(st.histogram) && isempty(st.edges)
    # integer channels: the missing value counts as missing
    (; s, id, L, db) = make_db_with(V = [1.0, 2.0, 3.0])
    add_channel!(db, ChannelInfo("N", "N", Int16, "", ROLE_NONE, :normal, 6, -1, false, 1))
    write_channel!(db, L, "N", Int16[7, typemin(Int16), 9])
    save_meta(db)
    st = channel_stats(database(s.project, id), "N")
    @test st.count == 2 && st.missing == 1 && st.mean == 8.0 && st.median == 8.0
    # an explicit empty list of lines
    st = channel_stats(database(s.project, id), "V"; lines = LineId[])
    @test st.count == 0 && st.missing == 0
    # problems
    @test_throws ArgumentError channel_stats(database(s.project, id), "V"; bins = 0)
    @test_throws DatabaseError channel_stats(database(s.project, id), "NOPE")
    @test_throws DatabaseError channel_stats(database(s.project, id), "V"; lines = [LineId(LINE, 5, 0)])
end

@testset "channel statistics: lines and blocks" begin
    s, id = two_line_db()            # from test_channel_math.jl
    db = database(s.project, id)
    st = channel_stats(db, "MAG")
    @test st.count == 6 && st.mean == 3.5 && st.median == 3.5
    st = channel_stats(db, "MAG"; lines = [CM_L2])
    @test st.count == 3 && st.mean == 5.0 && st.min == 4.0
    # a line longer than one block
    n = 3 * JuliaMagCore.STATS_BLOCK + 5
    t = make_db_with(V = collect(1.0:n))
    st = channel_stats(t.db, "V")
    @test st.count == n && st.mean == (n + 1) / 2 && st.max == n
    @test abs(st.median - (n + 1) / 2) <= (n - 1) / (64 * 1024)
end

@testset "statistics tool" begin
    s, id = two_line_db()
    ins = Dict("database" => id)
    @test tool("database.statistics").mode == :quick
    ok, msg, out = run_tool(s, "database.statistics"; inputs = ins, channel = "MAG", lines = "all")
    @test ok && out == ProjectItem[]
    @test msg == "Statistics of MAG on 2 lines:\n" *
                 "Count 6, missing 0.\n" *
                 "Min 1, max 6, mean 3.5, standard deviation 1.87083.\n" *
                 "Median 3.5, 5th percentile 1.25, 95th percentile 5.75."
    @test isempty(s.busy) && isempty(s.undo_stack) && last(s.history).command == "database.statistics"
    set_cursor!(s, Cursor(id, CM_L1, 1))
    ok, msg, _ = run_tool(s, "database.statistics"; inputs = ins, channel = "CNT", lines = "current")
    @test ok && startswith(msg, "Statistics of CNT on 1 line:\nCount 2, missing 1.\n")
    # reads share the database with an export, but not with a writer
    JuliaMagCore.mark_reading!(s, id)
    @test run_tool(s, "database.statistics"; inputs = ins, channel = "MAG", lines = "all")[1]
    JuliaMagCore.unmark_reading!(s, id)
    JuliaMagCore.mark_busy!(s, id; reason = "Channel Math is running")
    ok, msg, _ = run_tool(s, "database.statistics"; inputs = ins, channel = "MAG", lines = "all")
    @test !ok && msg == "Database $id is busy: Channel Math is running."
    JuliaMagCore.unmark_busy!(s, id)
    @test isempty(s.busy)
    # problems are plain messages
    ok, msg, _ = run_tool(s, "database.statistics"; inputs = ins, channel = "NOPE", lines = "all")
    @test !ok && msg == "Database $id has no channel NOPE."
    (; s, id) = make_db_with(V = [NaN, NaN])
    ok, msg, _ = run_tool(s, "database.statistics"; inputs = Dict("database" => id), channel = "V", lines = "all")
    @test ok && msg == "Statistics of V on 1 line:\nCount 0, missing 2.\nThere are no values to describe."
    @test isempty(s.busy)
end
