# Map items: layers and styles, written at once, undoable and in the script.

@testset "map items: the brief" begin
    s = fresh_session()
    db = survey_database!(s)
    g = add_test_grid!(s, Float32[i + 10j for i in 1:4, j in 1:3])
    m = new_map!(s)
    @test m == "map-1" && item(s.project, m).kind == ITEM_MAP && item(s.project, m).name == "Map 1"
    @test isfile(joinpath(s.project.folder, "maps", m, MAP_FILE))
    @test item(s.project, new_map!(s)).name == "Map 2"
    l1 = add_layer!(s, m, db)
    mi = map_item(s.project, m)
    @test l1 == "layer-1" && only(mi.layers).kind == :lines && only(mi.layers).channel == "MAG"
    @test mi.crs == "EPSG:32755" && only(mi.layers).labels && only(mi.layers).opacity == 1.0
    l2 = add_layer!(s, m, g)
    @test [l.id for l in map_item(s.project, m).layers] == ["layer-2", "layer-1"]   # grid below lines
    @test !map_item(s.project, m).layers[1].own_style
    set_layer!(s, m, l1; opacity = 0.5, style = LayerStyle(colours = "viridis"))
    L = map_item(s.project, m).layers[2]
    @test L.opacity == 0.5 && L.style.colours == "viridis" && s.history[end].command == "map.set_layer"
    undo!(s)
    L = map_item(s.project, m).layers[2]
    @test L.opacity == 1.0 && L.style.colours == "geosoft"
    move_layer!(s, m, l1, 1); @test [l.id for l in map_item(s.project, m).layers] == ["layer-1", "layer-2"]
    remove_layer!(s, m, l2); @test [l.id for l in map_item(s.project, m).layers] == ["layer-1"]
    undo!(s); @test length(map_item(s.project, m).layers) == 2
    n = length(s.undo_stack); set_layer!(s, m, l1; visible = true); @test length(s.undo_stack) == n
    @test_throws ArgumentError add_layer!(s, m, db; channel = "NOPE")
    @test_throws ArgumentError set_layer!(s, m, l1; opacity = 1.5)
    @test_throws ArgumentError set_layer!(s, m, "layer-9"; visible = false)
    @test_throws ArgumentError set_layer!(s, m, l1; style = LayerStyle(colours = "nope"))
    @test_throws ArgumentError set_layer!(s, m, l1; style = LayerStyle(clip_low = 50.0))
    remove_item!(s, db); @test any(l -> l.item == db, map_item(s.project, m).layers)
    undo!(s)
    @test default_colour_channel(database(s.project, db), PositionPair("X", "Y", "")) == "MAG"
    close_session!(s)
end

@testset "map items: file round trip" begin
    dir = joinpath(mktempdir(), "m")
    m = create_map(dir, "Round"; crs = "EPSG:32755")
    push!(m.layers, MapLayer("layer-1", "db-1", :lines, "MAG", true, 0.25, false, true,
                             LayerStyle(stretch = :linear, min = 1.5, reverse = true)))
    push!(m.layers, MapLayer("layer-2", "grid-1", :grid, "", false, 1.0, true, false,
                             LayerStyle(shade = true, zfactor = 2.0, resample = :nearest)))
    m.next_layer = 3
    save_map(m)
    r = open_map(dir)
    @test r.name == "Round" && r.crs == "EPSG:32755" && r.next_layer == 3
    @test length(r.layers) == 2
    for (a, b) in zip(r.layers, m.layers)
        @test all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(MapLayer))
    end
    @test isnan(r.layers[1].style.max) && isnan(r.layers[1].style.zfactor) && r.layers[1].style.min == 1.5
    @test r.layers[1].style == m.layers[1].style && r.layers[1].style != r.layers[2].style
    @test_throws MapError open_map(joinpath(mktempdir(), "none"))
    write(joinpath(dir, MAP_FILE), "{ not json")
    @test_throws MapError open_map(dir)
end

@testset "map items: new map is undoable and cleaned up at close" begin
    s = fresh_session()
    m = new_map!(s; name = "  Survey  ")
    @test item(s.project, m).name == "Survey"
    folder = joinpath(s.project.folder, "maps", m)
    undo!(s)
    @test !any(i -> i.id == m, s.project.items) && isdir(folder)
    redo!(s)
    @test any(i -> i.id == m, s.project.items)
    @test item(s.project, new_map!(s)).name == "Map 1"
    undo!(s); undo!(s)
    @test !any(i -> i.id == m, s.project.items)
    close_session!(s)
    @test !isdir(folder)
    # an undone map is dropped at close too
    s = fresh_session()
    m = new_map!(s); undo!(s)
    folder = joinpath(s.project.folder, "maps", m)
    @test isdir(folder)
    close_session!(s)
    @test !isdir(folder)
end

@testset "map items: a grid layer starts with its grid's shading" begin
    s = fresh_session()
    g = add_test_grid!(s, Float32[1 2; 3 4])
    g2 = add_test_grid!(s, Float32[1 2; 3 4])
    set_grid_style!(s, g, GridStyle("viridis", :linear, NaN, NaN, false, true, 300.0, 30.0, 2.0))
    set_grid_style!(s, g2, GridStyle("geosoft", :histeq, NaN, NaN, false, false, 10.0, 120.0, -1.0))
    m = new_map!(s)
    layer(id) = only(filter(x -> x.id == id, map_item(s.project, m).layers))
    l = layer(add_layer!(s, m, g))
    @test !l.own_style && l.style.shade && l.style.declination == 300.0 && l.style.inclination == 30.0
    @test l.style.zfactor == 2.0
    gs = grid(s.project, g).style
    @test effective_style(l, gs, "turbo").colours == "viridis"   # the colours still come from the grid
    l2 = layer(add_layer!(s, m, g2))
    # An altitude out of range is clamped, and a vertical scale that is not above 0 means auto.
    @test !l2.style.shade && l2.style.inclination == 90.0 && l2.style.declination == 10.0 && isnan(l2.style.zfactor)
    # An azimuth outside 0 to 360 turns into that range.
    @test JuliaMagCore.grid_shading(GridStyle("geosoft", :histeq, NaN, NaN, false, true, -30.0, 45.0, 1.0)).declination == 330.0
    @test JuliaMagCore.grid_shading(GridStyle("geosoft", :histeq, NaN, NaN, false, true, 400.0, 45.0, 1.0)).declination == 40.0
    close_session!(s)
end

@testset "map items: add_layer! rules" begin
    s = fresh_session()
    db = survey_database!(s)
    g = add_test_grid!(s, Float32[1 2; 3 4]; crs = "EPSG:32633")
    m = new_map!(s)
    @test_throws ArgumentError add_layer!(s, "map-9", db)
    @test_throws ArgumentError add_layer!(s, m, "db-9")
    @test_throws ArgumentError add_layer!(s, m, g; channel = "MAG")
    add_layer!(s, m, g)
    @test map_item(s.project, m).crs == "EPSG:32633"
    undo!(s)
    @test isempty(map_item(s.project, m).layers) && map_item(s.project, m).crs == ""
    redo!(s)
    @test map_item(s.project, m).crs == "EPSG:32633"
    add_layer!(s, m, db)                 # crs stays
    @test map_item(s.project, m).crs == "EPSG:32633"
    @test [l.id for l in map_item(s.project, m).layers] == ["layer-1", "layer-2"]
    @test map_item(s.project, m).layers[2].kind == :lines
    g2 = add_test_grid!(s, Float32[1 2; 3 4])
    add_layer!(s, m, g2)
    @test [l.kind for l in map_item(s.project, m).layers] == [:grid, :grid, :lines]
    # a database with no current pair
    d2 = survey_database!(s)
    d = database(s.project, d2)
    d.current_pair = 0
    save_meta(d)
    err = try add_layer!(s, m, d2); nothing catch e e end
    @test err isa ArgumentError && err.msg == "database $(item(s.project, d2).name) has no current X, Y pair"
    close_session!(s)
end

@testset "map items: set_layer! and move_layer! checks" begin
    s = fresh_session()
    db = survey_database!(s)
    m = new_map!(s)
    l = add_layer!(s, m, db)
    @test_throws ArgumentError set_layer!(s, m, l; opacity = -0.1)
    @test_throws ArgumentError set_layer!(s, m, l; channel = "NOPE")
    @test_throws ArgumentError set_layer!(s, m, l; style = LayerStyle(stretch = :nope))
    @test_throws ArgumentError set_layer!(s, m, l; style = LayerStyle(inclination = 91.0))
    @test_throws ArgumentError set_layer!(s, m, l; style = LayerStyle(declination = Inf))
    @test_throws ArgumentError set_layer!(s, m, l; style = LayerStyle(zfactor = 0.0))
    @test_throws ArgumentError set_layer!(s, m, l; style = LayerStyle(resample = :cubic))
    @test_throws ArgumentError move_layer!(s, m, l, 2)
    @test_throws ArgumentError move_layer!(s, m, "layer-9", 1)
    @test_throws ArgumentError remove_layer!(s, m, "layer-9")
    n = length(s.history)
    set_layer!(s, m, l; style = LayerStyle())     # same as it is
    move_layer!(s, m, l, 1)                       # same place
    @test length(s.history) == n
    set_layer!(s, m, l; channel = "", labels = false)
    L = only(map_item(s.project, m).layers)
    @test L.channel == "" && !L.labels
    # the style is copied
    st = LayerStyle(colours = "viridis")
    set_layer!(s, m, l; style = st)
    st.colours = "rainbow"
    @test only(map_item(s.project, m).layers).style.colours == "viridis"
    close_session!(s)
end

@testset "map items: a busy map is refused" begin
    s = fresh_session()
    m = new_map!(s)
    db = survey_database!(s)
    lock(s.lock) do
        JuliaMagCore.mark_busy!(s, m; reason = "test")
    end
    @test_throws ItemBusyError add_layer!(s, m, db)
    lock(s.lock) do
        JuliaMagCore.unmark_busy!(s, m)
    end
    add_layer!(s, m, db)
    close_session!(s)
end

@testset "map items: the script replays" begin
    s = fresh_session()
    folder = s.project.folder
    db = survey_database!(s)
    g = add_test_grid!(s, Float32[i + 10j for i in 1:4, j in 1:3])
    m = new_map!(s)
    l1 = add_layer!(s, m, db; channel = "MAG")
    l2 = add_layer!(s, m, g)
    l3 = add_layer!(s, m, db)
    remove_layer!(s, m, l3)
    move_layer!(s, m, l1, 1)
    set_layer!(s, m, l1; opacity = 0.5, style = LayerStyle(colours = "viridis", stretch = :clip, clip_low = 2.0))
    set_layer!(s, m, l2; own_style = true, visible = false, style = LayerStyle(shade = true, zfactor = 3.0))
    text = script_text(s)
    @test occursin("map_1 = new_map!(s; name = \"Map 1\")", text)
    @test occursin("add_layer!(s, map_1, ", text)
    @test occursin("remove_layer!(s, map_1, \"layer-3\")", text)
    @test occursin("move_layer!(s, map_1, \"layer-1\", 1)", text)
    @test occursin("set_layer!(s, map_1, \"layer-1\"; opacity = 0.5, style = LayerStyle(", text)
    @test !occursin("only(map_1", text) && !occursin("map_1.outputs", text)
    close_session!(s)
    include_string(Module(), text)
    p = open_project(folder)
    maps = [i.id for i in p.items if i.kind == ITEM_MAP]
    @test length(maps) == 2
    a, b = map_item(p, maps[1]), map_item(p, maps[2])
    @test [l.id for l in a.layers] == [l.id for l in b.layers]
    @test [l.kind for l in a.layers] == [l.kind for l in b.layers]
    @test all(x.style == y.style && x.opacity == y.opacity && x.visible == y.visible &&
              x.own_style == y.own_style && x.channel == y.channel for (x, y) in zip(a.layers, b.layers))
    @test a.crs == b.crs == "EPSG:32755"
    with_session(_ -> nothing, folder)
end
