# Coordinate systems: the functions in crs/crs.jl and the coordinates tools.

"""
A session with one database: line L1001 with channels LON, LAT, X and Y.
Pair 1 is LON,LAT in EPSG:4326 and is current. Pair 2 is X,Y with `xy_crs`.
"""
function make_position_db(; lon = [147.1, 147.2, 147.3], lat = [-19.5, -19.6, -19.7],
                          xy_crs = "")
    n = length(lon)
    t = make_db_with(LON = lon, LAT = lat, X = collect(1.0:n), Y = collect(1.0:n))
    db = t.db
    push!(db.pairs, PositionPair("LON", "LAT", "EPSG:4326"), PositionPair("X", "Y", xy_crs))
    db.current_pair = 1
    save_meta(db)
    return t
end

pair_names(db) = [(p.x, p.y, p.crs) for p in db.pairs]
channel_names(db) = [c.name for c in db.channels]

@testset "coordinate systems" begin
    @test valid_crs("EPSG:7855") && valid_crs("EPSG:4326") && valid_crs("EPSG:32755")
    @test !valid_crs("garbage") && !valid_crs("") && !valid_crs("EPSG:") && !valid_crs("EPSG:999999")
    @test !valid_crs("EPSG:4326\0x")                      # a C string cannot hold it; no throw
    @test !valid_crs("+proj=utm +zone=55 +south")         # a map projection, not a coordinate system
    @test valid_crs("+proj=utm +zone=55 +south +datum=WGS84 +type=crs")
    @test crs_name("EPSG:7855") == "GDA2020 / MGA zone 55"
    @test crs_name("EPSG:32755") == "WGS 84 / UTM zone 55S"
    @test crs_name("nope") == "" && crs_name("") == ""
    # an error in the work on a good code is a real error, not "invalid code"
    @test_throws ErrorException JuliaMagCore.with_crs(_ -> error("bug"), "EPSG:4326")
end

@testset "guess UTM zone" begin
    @test guess_utm([147.1, 147.2, 147.3], [-19.5, -19.6, -19.7])[1] == ("EPSG:32755", 1.0)
    # zone = floor(lon / 6 + 31); largest share first; north when the median latitude is not below 0
    g = guess_utm([10.0, 11.0, 13.0, 14.0], [60.0, 60.0, 60.0, 60.0])
    @test g == [("EPSG:32632", 0.5), ("EPSG:32633", 0.5)] || g == [("EPSG:32633", 0.5), ("EPSG:32632", 0.5)]
    g = guess_utm([10.0, 13.0, 14.0, 15.0], [1.0, 2.0, 3.0, 4.0])
    @test g == [("EPSG:32633", 0.75), ("EPSG:32632", 0.25)]
    @test guess_utm([-177.0], [10.0]) == [("EPSG:32601", 1.0)]
    @test guess_utm([180.0], [10.0]) == [("EPSG:32660", 1.0)]
    # missing and impossible values are skipped
    @test guess_utm([NaN, 147.0, 500.0, 147.0], [-19.0, NaN, -19.0, -19.0]) == [("EPSG:32755", 1.0)]
    @test isempty(guess_utm(Float64[], Float64[]))
    @test isempty(guess_utm([NaN], [NaN]))
    # an exact split: the median is the mean of the two middle values
    @test guess_utm([147.0, 147.0], [-10.0, 5.0])[1][1] == "EPSG:32755"
    @test guess_utm([147.0, 147.0], [-5.0, 10.0])[1][1] == "EPSG:32655"
    @test_throws ArgumentError guess_utm([1.0], Float64[])
    # the official exceptions: southwest Norway is zone 32; Svalbard uses only zones 31, 33, 35 and 37
    @test guess_utm([5.0], [60.0]) == [("EPSG:32632", 1.0)]
    @test guess_utm([2.0], [60.0]) == [("EPSG:32631", 1.0)]      # west of 3E: the normal zone
    @test guess_utm([5.0], [55.0]) == [("EPSG:32631", 1.0)]      # south of 56N: the normal zone
    @test guess_utm([15.0], [78.0]) == [("EPSG:32633", 1.0)]
    @test guess_utm([8.0], [78.0]) == [("EPSG:32631", 1.0)]
    @test guess_utm([20.0], [78.0]) == [("EPSG:32633", 1.0)]
    @test guess_utm([25.0], [78.0]) == [("EPSG:32635", 1.0)]
    @test guess_utm([40.0], [78.0]) == [("EPSG:32637", 1.0)]
    @test guess_utm([8.0], [70.0]) == [("EPSG:32632", 1.0)]      # south of 72N: the normal zone
end

@testset "reproject points" begin
    x, y = reproject_xy([147.0], [-19.0], "EPSG:4326", "EPSG:32755")
    @test isapprox(x[1], 500000.0; atol = 1) && isapprox(y[1], 7899000.0; atol = 1000)
    @test isnan(reproject_xy([NaN], [1.0], "EPSG:4326", "EPSG:32755")[1][1])
    # missing in, missing out; the other points are fine
    x, y = reproject_xy([147.0, NaN, 147.0], [-19.0, -19.0, NaN], "EPSG:4326", "EPSG:32755")
    @test isfinite(x[1]) && isnan(x[2]) && isnan(y[2]) && isnan(x[3]) && isnan(y[3])
    # a point that PROJ cannot transform becomes NaN and is counted; nothing throws
    x, y = @test_logs (:warn, r"1 point could not be transformed") reproject_xy(
        [147.0, 147.0], [-19.0, 95.0], "EPSG:4326", "EPSG:32755")
    @test isfinite(x[1]) && isnan(x[2]) && isnan(y[2])
    # back again
    lon, lat = reproject_xy([500000.0], [7899172.548199037], "EPSG:32755", "EPSG:4326")
    @test isapprox(lon[1], 147.0; atol = 1e-9) && isapprox(lat[1], -19.0; atol = 1e-9)
    # other number types; an integer missing value gives NaN
    x, _ = reproject_xy(Float32[147.0], Float32[-19.0], "EPSG:4326", "EPSG:32755")
    @test isapprox(x[1], 500000.0; atol = 1)
    x, _ = reproject_xy([147, typemin(Int)], [-19, -19], "EPSG:4326", "EPSG:32755")
    @test isfinite(x[1]) && isnan(x[2])
    @test_throws ArgumentError reproject_xy([1.0], [1.0], "garbage", "EPSG:32755")
    @test_throws ArgumentError reproject_xy([1.0], [1.0, 2.0], "EPSG:4326", "EPSG:32755")
    # many points at once, fast, and the same from several threads
    n = 1_000_000
    lon = [146.0 + 2.0 * (k / n) for k in 1:n]
    lat = [-20.0 + (k % 1000) / 1000 for k in 1:n]
    bx, by = reproject_xy(lon, lat, "EPSG:4326", "EPSG:32755")
    @test all(isfinite, bx) && all(isfinite, by)
    results = Vector{Any}(undef, 4)
    Threads.@threads for k in 1:4
        results[k] = reproject_xy(lon[1:100_000], lat[1:100_000], "EPSG:4326", "EPSG:32755")
    end
    @test all(r -> r[1] == bx[1:100_000] && r[2] == by[1:100_000], results)
end

@testset "coordinates tools are registered" begin
    ids = ["coordinates.set_crs", "coordinates.reproject", "coordinates.set_current", "coordinates.guess_utm"]
    for id in ids
        t = tool(id)
        @test t.inputs == ["database" => ITEM_DATABASE]
        @test any(p -> p.tab == "Coordinates", t.places)
        @test t.mode == (id == "coordinates.reproject" ? :job : :quick)
    end
    @test Place("Database", "Channels") in tool("coordinates.set_current").places
    @test default_settings(tool("coordinates.reproject"))["make_current"] == false
    @test "Coordinates" in tabs()
end

@testset "set coordinate system" begin
    (; s, id) = make_position_db()
    ins = Dict("database" => id)
    ok, msg, _ = run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "X,Y", crs = "EPSG:7855")
    @test ok && msg == "Position pair X,Y is now in EPSG:7855 (GDA2020 / MGA zone 55)."
    @test database(s.project, id).pairs[2].crs == "EPSG:7855"
    @test last(s.undo_stack).items == [id]
    @test undo!(s)
    @test database(s.project, id).pairs[2].crs == ""
    @test redo!(s)
    @test database(s.project, id).pairs[2].crs == "EPSG:7855"
    # blank pair means the current pair; blank code means unknown
    ok, _, _ = run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "", crs = "")
    @test ok && database(s.project, id).pairs[1].crs == ""
    @test undo!(s) && database(s.project, id).pairs[1].crs == "EPSG:4326"
    # bad input gives a plain message and changes nothing
    n = length(s.undo_stack)
    ok, msg, _ = run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "X,Y", crs = "EPSG:999999")
    @test !ok && msg == "Coordinate system \"EPSG:999999\" is not known."
    ok, msg, _ = run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "E,N", crs = "EPSG:7855")
    @test !ok && msg == "Database $id has no position pair E,N."
    ok, msg, _ = run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "XY", crs = "EPSG:7855")
    @test !ok && msg == "Position pair must be two channel names with a comma, such as \"X,Y\"."
    ok, msg, _ = run_tool(s, "coordinates.set_crs"; inputs = Dict("database" => "db-99"), pair = "X,Y",
                          crs = "EPSG:7855")
    @test !ok && msg == "There is no item db-99 in the project."
    JuliaMagCore.mark_busy!(s, id)
    ok, msg, _ = run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "X,Y", crs = "EPSG:7855")
    @test !ok && msg == "Database $id is busy: an import is running."
    JuliaMagCore.unmark_busy!(s, id)
    @test length(s.undo_stack) == n
    @test database(s.project, id).pairs[2].crs == "EPSG:7855"
end

@testset "set current pair" begin
    (; s, id) = make_position_db()
    ins = Dict("database" => id)
    ok, msg, _ = run_tool(s, "coordinates.set_current"; inputs = ins, pair = "X,Y")
    @test ok && msg == "Position pair X,Y is now the current pair."
    @test database(s.project, id).current_pair == 2
    @test last(s.undo_stack).items == [id]
    @test undo!(s) && database(s.project, id).current_pair == 1
    @test redo!(s) && database(s.project, id).current_pair == 2
    n = length(s.undo_stack)
    ok, msg, _ = run_tool(s, "coordinates.set_current"; inputs = ins, pair = "X,Y")
    @test ok && msg == "Position pair X,Y is already the current pair." && length(s.undo_stack) == n
    ok, msg, _ = run_tool(s, "coordinates.set_current"; inputs = ins, pair = "A,B")
    @test !ok && msg == "Database $id has no position pair A,B."
end

@testset "guess UTM zone tool" begin
    (; s, id) = make_position_db(xy_crs = "EPSG:7855")
    ins = Dict("database" => id)
    ok, msg, _ = run_tool(s, "coordinates.guess_utm"; inputs = ins, pair = "")
    @test ok && msg == "Most points (100.0 %) are in EPSG:32755 (WGS 84 / UTM zone 55S)."
    @test isempty(s.undo_stack)
    # the current pair is X,Y in metres: the tool finds the longitude and latitude pair itself
    run_tool(s, "coordinates.set_current"; inputs = ins, pair = "X,Y")
    ok, msg, _ = run_tool(s, "coordinates.guess_utm"; inputs = ins, pair = "")
    @test ok && startswith(msg, "Most points (100.0 %) are in EPSG:32755")
    # a picked pair must be longitude and latitude
    ok, msg, _ = run_tool(s, "coordinates.guess_utm"; inputs = ins, pair = "X,Y")
    @test !ok && msg == "Position pair X,Y is not longitude and latitude. Pick the pair with longitude and latitude."
    @test isempty(s.busy)
    # a set coordinate system decides; channel roles count only when it is blank
    db = database(s.project, id)
    channel(db, "X").role = ROLE_LON
    channel(db, "Y").role = ROLE_LAT
    save_meta(db)
    ok, msg, _ = run_tool(s, "coordinates.guess_utm"; inputs = ins, pair = "X,Y")
    @test !ok && startswith(msg, "Position pair X,Y is not longitude and latitude.")
    run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "X,Y", crs = "")
    ok, msg, _ = run_tool(s, "coordinates.guess_utm"; inputs = ins, pair = "X,Y")
    @test ok && isempty(s.busy)      # X and Y hold 1 to 3: zone 31 north
    @test msg == "Most points (100.0 %) are in EPSG:32631 (WGS 84 / UTM zone 31N)."
    # shares of several zones
    t = make_position_db(lon = [147.1, 147.2, 147.3, 150.5], lat = [-19.5, -19.6, -19.7, -19.8])
    ok, msg, _ = run_tool(t.s, "coordinates.guess_utm"; inputs = Dict("database" => t.id), pair = "LON,LAT")
    @test ok && msg == "Most points (75.0 %) are in EPSG:32755 (WGS 84 / UTM zone 55S).\n" *
                       "Other zones: EPSG:32756 (25.0 %)."
    t = make_position_db(lon = [NaN], lat = [NaN])
    ok, msg, _ = run_tool(t.s, "coordinates.guess_utm"; inputs = Dict("database" => t.id), pair = "LON,LAT")
    @test !ok && msg == "Position pair LON,LAT has no valid longitude and latitude."
end

@testset "reproject tool" begin
    (; s, id) = make_position_db()
    ins = Dict("database" => id)
    before = read(joinpath(JuliaMagCore.item_path(s.project, item(s.project, id)), "database.json"), String)
    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT", crs = "EPSG:32755"))
    @test status(job) == JOB_DONE
    db = database(s.project, id)
    @test channel_names(db) == ["LON", "LAT", "X", "Y", "X_32755", "Y_32755"]
    @test pair_names(db)[3] == ("X_32755", "Y_32755", "EPSG:32755")
    @test db.current_pair == 1
    L = LineId(LINE, 1001, 0)
    ex, ey = reproject_xy([147.1, 147.2, 147.3], [-19.5, -19.6, -19.7], "EPSG:4326", "EPSG:32755")
    @test read_channel(db, L, "X_32755") == ex && read_channel(db, L, "Y_32755") == ey
    @test channel(db, "X_32755").units == "m"
    @test occursin("X_32755", String(take!(copy(job.report))))
    # undo removes the channels and the pair; redo puts them back
    @test undo!(s)
    db = database(s.project, id)
    @test channel_names(db) == ["LON", "LAT", "X", "Y"] && length(db.pairs) == 2
    @test read(joinpath(JuliaMagCore.item_path(s.project, item(s.project, id)), "database.json"), String) == before
    @test !isfile(joinpath(JuliaMagCore.item_path(s.project, item(s.project, id)), "channels", "X_32755.f64"))
    @test redo!(s)
    db = database(s.project, id)
    @test read_channel(db, L, "X_32755") == ex && length(db.pairs) == 3
    # a second run takes free names and can make the new pair current; undo restores the current pair
    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "", crs = "EPSG:32755",
                            make_current = true))
    @test status(job) == JOB_DONE
    db = database(s.project, id)
    @test pair_names(db)[4] == ("X_32755_2", "Y_32755_2", "EPSG:32755") && db.current_pair == 4
    @test undo!(s) && database(s.project, id).current_pair == 1
    # problems fail the job with a plain message and change nothing
    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "X,Y", crs = "EPSG:32755"))
    @test status(job) == JOB_FAILED
    @test job.error == "Position pair X,Y has no coordinate system. Set it first."
    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT", crs = "EPSG:0"))
    @test status(job) == JOB_FAILED && job.error == "Coordinate system \"EPSG:0\" is not known."
    @test length(database(s.project, id).pairs) == 3 && isempty(s.busy)
    JuliaMagCore.mark_busy!(s, id)
    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT", crs = "EPSG:32755"))
    @test status(job) == JOB_FAILED && job.error == "Database $id is busy: an import is running."
    JuliaMagCore.unmark_busy!(s, id)
    # a database whose state cannot be read fails the job and is not left busy
    meta = joinpath(JuliaMagCore.item_path(s.project, item(s.project, id)), "database.json")
    saved = read(meta, String)
    rm(meta)
    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT", crs = "EPSG:32755"))
    @test status(job) == JOB_FAILED && isempty(s.busy)
    write(meta, saved)
    # a projected target system
    job = run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT", crs = "EPSG:7855")
    wait_job(job)
    @test status(job) == JOB_DONE && isempty(s.busy)
    @test pair_names(database(s.project, id))[end] == ("X_7855", "Y_7855", "EPSG:7855")
end

@testset "reproject tool: bad points and cancel" begin
    (; s, id) = make_position_db(lon = [147.0, 147.0], lat = [-19.0, 95.0])
    ins = Dict("database" => id)
    job = wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT", crs = "EPSG:32755"))
    @test status(job) == JOB_DONE
    @test occursin("1 point could not be transformed from EPSG:4326 to EPSG:32755.", String(take!(copy(job.report))))
    x = read_channel(database(s.project, id), LineId(LINE, 1001, 0), "X_32755")
    @test isfinite(x[1]) && isnan(x[2])
    # a cancelled run leaves the database as it was and not busy
    st = Dict{String,Any}("pair" => "LON,LAT", "crs" => "EPSG:7855", "make_current" => false)
    cancelled = JuliaMagCore.Progress(_ -> nothing, () -> true)
    @test_throws JuliaMagCore.JobCancelled JuliaMagCore.run_reproject(s, ins, st, cancelled, IOBuffer())
    db = database(s.project, id)
    @test channel_names(db) == ["LON", "LAT", "X", "Y", "X_32755", "Y_32755"] && length(db.pairs) == 3
    @test !isfile(joinpath(JuliaMagCore.item_path(s.project, item(s.project, id)), "channels", "X_7855.f64"))
    @test isempty(s.busy)
end

@testset "coordinates tools replay by script" begin
    (; s, id) = make_position_db()
    copy_folder = joinpath(mktempdir(), "copy")
    cp(s.project.folder, copy_folder)
    ins = Dict("database" => id)
    @test run_tool(s, "coordinates.set_crs"; inputs = ins, pair = "X,Y", crs = "EPSG:7855")[1]
    @test status(wait_job(run_tool(s, "coordinates.reproject"; inputs = ins, pair = "LON,LAT",
                                   crs = "EPSG:32755"))) == JOB_DONE
    text = replace(script_text(s), repr(s.project.folder) => repr(copy_folder))
    @test occursin("run_tool(s, \"coordinates.set_crs\"", text)
    @test occursin("wait_job(run_tool(s, \"coordinates.reproject\"", text)
    include_string(Module(), text)
    a = database(s.project, id)
    b = database(open_project(copy_folder), id)
    @test pair_names(a) == pair_names(b)
    L = LineId(LINE, 1001, 0)
    @test read_channel(a, L, "X_32755") == read_channel(b, L, "X_32755")
    @test read_channel(a, L, "Y_32755") == read_channel(b, L, "Y_32755")
end

@testset "readers share an item only with exports and appends (I2)" begin
    (; s, id) = make_position_db()
    ins = Dict("database" => id)
    stats() = run_tool(s, "database.statistics"; inputs = ins, channel = "LON")
    utm() = run_tool(s, "coordinates.guess_utm"; inputs = ins, pair = "LON,LAT")
    # An export reads the item: other readers may read it too.
    JuliaMagCore.mark_reading!(s, id)
    @test stats()[1] && utm()[1]
    @test_throws ItemBusyError JuliaMagCore.mark_busy!(s, id)
    JuliaMagCore.unmark_reading!(s, id)
    @test isempty(s.busy)
    # An append only adds rows past the commit point: readers may read the committed rows.
    JuliaMagCore.mark_busy!(s, id; kind = :append)
    @test stats()[1] && utm()[1]
    JuliaMagCore.mark_reading!(s, id)
    JuliaMagCore.unmark_reading!(s, id)
    JuliaMagCore.unmark_busy!(s, id)
    @test isempty(s.busy)
    # Any other writer changes rows in place: readers are refused.
    JuliaMagCore.mark_busy!(s, id; reason = "Channel Math is running")
    @test_throws ItemBusyError JuliaMagCore.mark_reading!(s, id)
    ok, msg, _ = stats()
    @test !ok && msg == "Database $id is busy: Channel Math is running."
    ok, msg, _ = utm()
    @test !ok && msg == "Database $id is busy: Channel Math is running."
    JuliaMagCore.unmark_busy!(s, id)
    @test isempty(s.busy)
end
