# Bulk line positions and the change counters of items.

@testset "line points: the brief" begin
    s = fresh_session(); id = survey_database!(s; nan_line = 2)
    db = database(s.project, id)
    p = read_line_points(db, "X", "Y", "MAG")
    @test p.origin == (500_000.0, 7_000_000.0) && length(p.x) == 10
    @test p.part_line == Int32[1, 3] && p.part_row == Int32[1, 1] && p.part_count == Int32[5, 5]
    @test p.part_first == Int32[0, 5] && length(p.lines) == 3
    @test p.x[1:5] == Float32[0, 10, 20, 30, 40] && p.y[6] == 100f0 && p.value[1:5] == Float32[101, 102, 103, 104, 105]
    @test all(isnan, p.extents[2]) && p.extents[1] == (500_000.0, 7_000_000.0, 500_040.0, 7_000_000.0)
    L = LineId(LINE, 1001, 0)
    set_cell!(s, id, L, "X", 3, NaN); set_cell!(s, id, L, "MAG", 1, NaN)
    q = read_line_points(database(s.project, id), "X", "Y", "MAG"; into = p)
    @test q === p && q.part_row[1:2] == Int32[1, 4] && q.part_count[1:2] == Int32[2, 2] && isnan(q.value[1])
    @test all(isnan, read_line_points(database(s.project, id), "X", "Y").value)
    @test_throws ArgumentError read_line_points(database(s.project, id), "X", "Y", "NOPE")
    r0 = item_revision(s, id)
    set_cell!(s, id, L, "MAG", 2, 7.0); @test item_revision(s, id) == r0 + 1
    undo!(s); @test item_revision(s, id) == r0 + 2 && item_revisions(s)[id] == r0 + 2
    redo!(s); @test item_revision(s, id) == r0 + 3
    @test item_revision(s, "db-99") == 0
end

@testset "line points: edge cases" begin
    s = fresh_session(); id = survey_database!(s; lines = 2, nan_line = 1)
    set_cell!(s, id, LineId(LINE, 1002, 0), "X", 1, NaN)
    for r in 2:5
        set_cell!(s, id, LineId(LINE, 1002, 0), "Y", r, NaN)
    end
    p = read_line_points(database(s.project, id), "X", "Y", "MAG")
    @test isempty(p.x) && isempty(p.part_first) && length(p.extents) == 2 && all(e -> all(isnan, e), p.extents)
    @test isempty(LinePoints().x)

    # a reprojected read
    s2 = fresh_session()
    id2 = survey_database!(s2; x0 = 147.0, y0 = -42.0, dx = 0.001, dy = 0.01, crs = "EPSG:4326")
    db2 = database(s2.project, id2)
    r = JuliaMagCore.Reprojector("EPSG:4326", "EPSG:32755")
    q = read_line_points(db2, "X", "Y"; reproject = r)
    close(r)
    xs = [147.0 + (k - 1) * 0.001 for l in 1:3 for k in 1:5]
    ys = [-42.0 + (l - 1) * 0.01 for l in 1:3 for k in 1:5]
    ex, ey = reproject_xy(xs, ys, "EPSG:4326", "EPSG:32755")
    @test length(q.x) == 15
    @test all(abs.(q.origin[1] .+ Float64.(q.x) .- ex) .< 1e-3)
    @test all(abs.(q.origin[2] .+ Float64.(q.y) .- ey) .< 1e-3)
    @test q.origin == (floor(ex[1]), floor(ey[1]))
end

@testset "line points: no new arrays on a second read" begin
    s = fresh_session(); id = survey_database!(s; lines = 4, rows = 50_000)
    db = database(s.project, id)
    p = read_line_points(db, "X", "Y", "MAG")
    @test length(p.x) == 200_000
    read_line_points(db, "X", "Y", "MAG"; into = p)
    @test (@allocated read_line_points(db, "X", "Y", "MAG"; into = p)) < 100_000
end
