# Grid statistics (`grid_stats`, tool "grid.statistics") and the undoable grid
# properties: coordinate system, georeference and style.

"The fields of two `ChannelStats`, compared with `isequal` (so `NaN` equals `NaN`)."
same_stats(a::ChannelStats, b::ChannelStats) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(ChannelStats))

"A new session with one grid item that holds `A`. Returns `(s, id)`."
function grid_session(A::Matrix = [1.0 3.0; 2.0 NaN; 4.0 5.0])
    s = fresh_session()
    return s, add_test_grid!(s, A)
end

georef(g::Grid) = (g.x0, g.y0, g.dx, g.dy, g.rotation)
style_fields(st::GridStyle) = Tuple(getfield(st, f) for f in fieldnames(GridStyle))

@testset "grid statistics: the brief" begin
    st = grid_stats(make_grid([1.0 3.0; 2.0 NaN; 4.0 5.0]))
    @test st.count == 5 && st.missing == 1 && st.median == 3.0 && st.min == 1.0 && st.max == 5.0
    @test st.mean == 3.0 && st.std ≈ sqrt(2.5)
    @test length(st.histogram) == 64 && sum(st.histogram) == 5 && st.edges[[1, end]] == [1.0, 5.0]
    st = grid_stats(make_grid([1.0 3.0; 2.0 NaN; 4.0 5.0]); bins = 4)
    @test st.histogram == [1, 1, 1, 2]
    @test_throws ArgumentError grid_stats(make_grid([1.0 2.0]); bins = 0)
    # a grid with no values
    st = grid_stats(make_grid(fill(NaN32, 2, 2)))
    @test st.count == 0 && st.missing == 4 && isnan(st.median) && isempty(st.histogram)
end

@testset "grid statistics: blocks, Float32 and channels share the passes" begin
    rng = TestRng(23)
    A = Float32[1000 * next_unit!(rng)^2 - 50 for _ in 1:7, _ in 1:30]
    A[3, 4] = NaN32
    A[7, 30] = NaN32
    g = make_grid(A)
    one_block = JuliaMagCore.value_stats(JuliaMagCore.GridValues(g, 30), 64)
    three_blocks = JuliaMagCore.value_stats(JuliaMagCore.GridValues(g, 10), 64)
    @test same_stats(one_block, three_blocks)
    @test same_stats(grid_stats(g), one_block)
    good = sort!(Float64.(filter(!isnan, vec(A))))
    st = grid_stats(g)
    @test st.count == 208 && st.missing == 2
    @test st.median == exact_quantile(good, 0.5)            # from test_statistics.jl
    @test st.p5 == exact_quantile(good, 0.05) && st.p95 == exact_quantile(good, 0.95)
    # the same values in a channel give the same statistics
    @test same_stats(st, channel_stats(make_db_with(V = Float64.(vec(A))).db, "V"))
end

@testset "grid statistics tool" begin
    s, id = grid_session()
    ins = Dict("grid" => id)
    t = tool("grid.statistics")
    @test t.mode == :quick && t.inputs == ["grid" => ITEM_GRID]
    @test t.places == [Place("Grid and Image", "Properties")]
    @test only(st for st in t.settings if st.key == "bins").advanced
    ok, msg, out = run_tool(s, "grid.statistics"; inputs = ins)
    @test ok && out == ProjectItem[]
    @test msg == "Statistics of grid Mag:\n" *
                 "Count 5, missing 1.\n" *
                 "Min 1, max 5, mean 3, standard deviation 1.58114.\n" *
                 "Median 3, 5th percentile 1.2, 95th percentile 4.8."
    @test isempty(s.busy) && isempty(s.undo_stack) && last(s.history).command == "grid.statistics"
    # reads share the grid with an export, but not with a writer
    JuliaMagCore.mark_reading!(s, id)
    @test run_tool(s, "grid.statistics"; inputs = ins)[1]
    JuliaMagCore.unmark_reading!(s, id)
    JuliaMagCore.mark_busy!(s, id)
    ok, msg, _ = run_tool(s, "grid.statistics"; inputs = ins)
    @test !ok && msg == "Grid $id is busy: an import is running."
    JuliaMagCore.unmark_busy!(s, id)
    @test isempty(s.busy)
    # problems are plain messages
    ok, msg, _ = run_tool(s, "grid.statistics"; inputs = Dict("grid" => "grid-99"))
    @test !ok && msg == "There is no item grid-99 in the project."
    db = add_test_database!(s, ["V" => [1.0]])
    ok, msg, _ = run_tool(s, "grid.statistics"; inputs = Dict("grid" => db))
    @test !ok && msg == "Item $db is not a grid."
    s2, id2 = grid_session(fill(NaN, 2, 2))
    ok, msg, _ = run_tool(s2, "grid.statistics"; inputs = Dict("grid" => id2))
    @test ok && msg == "Statistics of grid Mag:\nCount 0, missing 4.\nThere are no values to describe."
end

@testset "set_grid_crs!" begin
    s, id = grid_session()
    set_grid_crs!(s, id, "EPSG:32633")
    @test grid(s.project, id).crs == "EPSG:32633"
    @test last(s.history).command == "grid.set_grid_crs"
    @test last(s.history).args == Dict("item" => id, "crs" => "EPSG:32633")
    undo!(s); @test grid(s.project, id).crs == ""
    redo!(s); @test grid(s.project, id).crs == "EPSG:32633"
    set_grid_crs!(s, id, "")
    @test grid(s.project, id).crs == ""
    @test_throws ArgumentError set_grid_crs!(s, id, "EPSG:nope")
    @test grid(s.project, id).crs == "" && length(s.undo_stack) == 2
    # only metadata changes
    before = read_rows(grid(s.project, id), 1, 2)
    set_grid_crs!(s, id, "EPSG:7855")
    @test isequal(read_rows(grid(s.project, id), 1, 2), before)
    # an export reads the grid: the edit, undo and redo wait
    JuliaMagCore.mark_reading!(s, id)
    @test_throws ItemBusyError set_grid_crs!(s, id, "EPSG:32633")
    @test_throws ItemBusyError undo!(s)
    JuliaMagCore.unmark_reading!(s, id)
    @test grid(s.project, id).crs == "EPSG:7855"
    @test !any(f -> endswith(f, ".tmp"), readdir(grid(s.project, id).folder))
end

@testset "set_grid_georef!" begin
    s, id = grid_session()
    g0 = grid(s.project, id)
    values = read_rows(g0, 1, 2)
    @test_throws ArgumentError set_grid_georef!(s, id; dx = 0.0)
    @test_throws ArgumentError set_grid_georef!(s, id; dy = -5.0)
    @test_throws ArgumentError set_grid_georef!(s, id; x0 = NaN)
    @test_throws ArgumentError set_grid_georef!(s, id; rotation = Inf)
    @test georef(grid(s.project, id)) == georef(g0) && isempty(s.undo_stack)
    set_grid_georef!(s, id; x0 = 500.0, rotation = 30.0)
    g = grid(s.project, id)
    @test georef(g) == (500.0, 200.0, 10.0, 20.0, 30.0)
    @test isequal(read_rows(g, 1, 2), values)
    @test last(s.history).args == Dict("item" => id, "x0" => 500.0, "rotation" => 30.0)
    set_grid_georef!(s, id; y0 = 7.5, dx = 2.0, dy = 3.0)
    @test georef(grid(s.project, id)) == (500.0, 7.5, 2.0, 3.0, 30.0)
    undo!(s); @test georef(grid(s.project, id)) == (500.0, 200.0, 10.0, 20.0, 30.0)
    undo!(s); @test georef(grid(s.project, id)) == georef(g0)
    redo!(s); @test georef(grid(s.project, id)) == (500.0, 200.0, 10.0, 20.0, 30.0)
    JuliaMagCore.mark_busy!(s, id)
    @test_throws ItemBusyError set_grid_georef!(s, id; x0 = 1.0)
    JuliaMagCore.unmark_busy!(s, id)
end

@testset "set_grid_style!" begin
    s, id = grid_session()
    st = GridStyle("greys", :linear, -10.0, 10.0, true, true, 315.0, 30.0, 2.5)
    set_grid_style!(s, id, st)
    @test style_fields(grid(s.project, id).style) == style_fields(st)
    e = last(s.history)
    @test e.command == "grid.set_style" && e.args["item"] == id && e.args["colours"] == "greys" &&
          e.args["method"] == "linear" && e.args["min"] == -10.0 && e.args["zfactor"] == 2.5
    undo!(s); @test isequal(style_fields(grid(s.project, id).style), style_fields(GridStyle()))
    redo!(s); @test style_fields(grid(s.project, id).style) == style_fields(st)
    # the caller's style is copied, not kept
    st.colours = "changed"
    @test grid(s.project, id).style.colours == "greys"
    @test_throws ArgumentError set_grid_style!(s, id, GridStyle("greys", :bogus, NaN, NaN, false, false, 45.0, 45.0, 1.0))
    @test_throws ArgumentError set_grid_style!(s, id, GridStyle("greys", :linear, NaN, NaN, false, false, NaN, 45.0, 1.0))
    JuliaMagCore.mark_reading!(s, id)
    @test_throws ItemBusyError set_grid_style!(s, id, GridStyle())
    JuliaMagCore.unmark_reading!(s, id)
end

@testset "grid.set_crs tool" begin
    s, id = grid_session()
    t = tool("grid.set_crs")
    @test t.mode == :quick && t.inputs == ["grid" => ITEM_GRID]
    @test t.places == [Place("Coordinates", "Coordinate system"), Place("Grid and Image", "Properties")]
    @test only(t.settings) isa CRSSetting && only(t.settings).key == "crs"
    ok, msg, _ = run_tool(s, "grid.set_crs"; inputs = Dict("grid" => id), crs = "EPSG:32633")
    @test ok && startswith(msg, "Grid Mag is now in EPSG:32633 (")
    @test grid(s.project, id).crs == "EPSG:32633" && length(s.undo_stack) == 1
    @test count(e -> e.command == "grid.set_crs", s.history) == 1
    undo!(s); @test grid(s.project, id).crs == ""
    ok, msg, _ = run_tool(s, "grid.set_crs"; inputs = Dict("grid" => id), crs = "EPSG:nope")
    @test !ok && msg == "Coordinate system \"EPSG:nope\" is not known."
    JuliaMagCore.mark_reading!(s, id)
    ok, msg, _ = run_tool(s, "grid.set_crs"; inputs = Dict("grid" => id), crs = "EPSG:32633")
    @test !ok && msg == "Grid $id is busy: an export is running."
    JuliaMagCore.unmark_reading!(s, id)
    ok, msg, _ = run_tool(s, "grid.set_crs"; inputs = Dict("grid" => id), crs = "")
    @test ok && msg == "Grid Mag has no coordinate system now."
end

@testset "grid properties replay by script" begin
    s, id = grid_session()
    copy_folder = joinpath(mktempdir(), "copy")
    cp(s.project.folder, copy_folder)
    set_grid_crs!(s, id, "EPSG:32633")
    set_grid_georef!(s, id; x0 = 1.5, rotation = -12.0)
    set_grid_style!(s, id, GridStyle("greys", :normal, NaN, 99.0, true, false, 300.0, 20.0, 3.0))
    set_grid_style!(s, id, GridStyle("rainbow", :linear, 1.0, 2.0, false, false, 45.0, 45.0, 1.0))
    undo!(s)
    @test run_tool(s, "grid.set_crs"; inputs = Dict("grid" => id), crs = "EPSG:7855")[1]
    text = replace(script_text(s), repr(s.project.folder) => repr(copy_folder))
    @test occursin("\nset_grid_crs!(s, $(repr(id)), \"EPSG:32633\")\n", text)
    @test occursin("\nset_grid_georef!(s, $(repr(id)); rotation = -12.0, x0 = 1.5)\n", text)
    @test occursin("\nset_grid_style!(s, $(repr(id)), GridStyle(\"greys\", :normal, NaN, 99.0, true, false, " *
                   "300.0, 20.0, 3.0))\n", text)
    @test occursin("wait_job(run_tool(s, \"grid.set_crs\"", text)
    # the saved history gives the same script (NaN and symbols survive JSON)
    strip_times(t) = replace(t, r"# \S+ " => "# ")
    close_session!(s)
    @test with_session(s2 -> strip_times(script_text(s2)), s.project.folder) == strip_times(script_text(s))
    include_string(Module(), text)
    a = grid(s.project, id)
    b = grid(open_project(copy_folder), id)
    @test a.crs == b.crs == "EPSG:7855"
    @test georef(a) == georef(b) == (1.5, 200.0, 10.0, 20.0, -12.0)
    @test isequal(style_fields(a.style), style_fields(b.style))
    @test b.style.colours == "greys"
end
