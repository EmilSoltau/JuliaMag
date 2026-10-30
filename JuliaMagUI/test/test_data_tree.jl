using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: TreeRow, tree_rows, snapshot, row_target, row_key, has_children, properties,
    visible_rows, tree_menu, drag_width, menu_layout, MenuItem, menu_separator, Box,
    next_row, rename_problem, decimals_text, parse_decimals, channel_info_problem, fmt_int,
    role_tag, ResultDialog, RenameDialog, ChannelPropsDialog, height, fmt_num, short_num

labels(rows) = [r.label for r in rows]
row(rows, key) = rows[findfirst(r -> r.key == key, rows)]

@testset "Data tree" begin
    @testset "the brief: 5,000 lines, 300 channels, a 200-character name" begin
        s = session_with(lines = 5_000, channels = 300, name = "x"^200)
        try
            snap = snapshot(s)
            rows = tree_rows(snap, Set(["databases", "db-1", "db-1/lines"]), "")
            @test count(r -> r.kind == :line, rows) == 5_000
            # The prototype shows the count right of the name ("Databases   1"), not in it.
            @test rows[1].label == "Databases" && rows[1].right == "1"
            @test rows[2].label == "x"^200 && rows[2].kind == :database
            f = tree_rows(snap, Set{String}(), "L1001")
            @test any(r -> r.label == "L1001", f) && all(r -> r.kind != :channel, f)
        finally
            Core.close_session!(s)
        end
    end

    s = kangaroo_data()
    try
    snap = snapshot(s)
    db = only(k for (k, v) in snap.databases)
    grid, gone = [it.id for it in snap.items if it.kind == Core.ITEM_GRID]

    @testset "structure, collapsed" begin
        rows = tree_rows(snap, Set{String}(), "")
        @test labels(rows) == ["Databases", "Grids"]
        @test [r.kind for r in rows] == [:databases, :grids]
        @test rows[1].bold && rows[1].icon == "folder" && rows[1].depth == 0 && rows[1].right == "1"
        @test rows[2].right == "2"
        @test all(r -> r.checkbox === nothing && r.tag == "", rows)
    end

    @testset "structure, open" begin
        open = Set(["databases", db, "$db/lines", "$db/channels", "grids"])
        rows = tree_rows(snap, open, ""; current = db)
        @test labels(rows)[1:3] == ["Databases", "Kangaroo Hills 2024", "Lines"]
        d = rows[2]
        @test d.key == db && d.depth == 1 && d.icon == "database" && d.bold   # the current database
        @test !tree_rows(snap, open, ""; current = "")[2].bold
        lines = row(rows, "$db/lines")
        @test lines.kind == :lines && lines.depth == 2 && lines.bold && lines.icon == "lines" &&
              lines.right == "60 of 60 selected"
        l = row(rows, "$db/lines/L1001")
        @test l.kind == :line && l.depth == 3 && l.icon == "lineL" && l.checkbox === true &&
              l.right == "F12  2,882" && !l.bold
        @test row(rows, "$db/lines/T2001").icon == "lineT"
        chans = row(rows, "$db/channels")
        @test chans.right == "9" && chans.icon == "channel"
        # The position pairs come first under Channels, with their system; the current one has a tag.
        k = findfirst(r -> r.key == "$db/channels", rows)
        @test rows[k+1].kind == :pair && rows[k+1].label == "X, Y" && rows[k+1].right == "EPSG:7855" &&
              rows[k+1].tag == "current" && rows[k+1].icon == "pair"
        @test rows[k+2].label == "LON, LAT" && rows[k+2].tag == ""
        mag = row(rows, "$db/channels/MAG")
        @test mag.icon == "lock" && mag.tag == "" && mag.right == "nT"
        @test row(rows, "$db/channels/X").tag == "x"
        igrf = row(rows, "$db/channels/IGRF")
        @test igrf.icon == "channel" && igrf.right == "nT"
        g = row(rows, grid)
        @test g.kind == :grid && g.depth == 1 && g.right == "400 x 800" && g.icon == "grid" && !g.dim
        m = row(rows, gone)
        @test m.italic && m.dim && m.right == "folder not found" && m.icon == "missing"
        @test !has_children(m) && has_children(d) && has_children(lines) && !has_children(l)
    end

    @testset "keys and targets" begin
        rows = tree_rows(snap, Set(["databases", db, "$db/lines", "$db/channels", "grids"]), "")
        for r in rows
            kind, item, sub = row_target(r)
            @test row_key(kind, item, sub) == r.key
        end
        @test row_target(row(rows, "$db/lines/L1001")) == (:line, db, "L1001")
        @test row_target(row(rows, "$db/channels/X")) == (:channel, db, "X")
        @test row_target(row(rows, "$db/pairs/X,Y")) == (:pair, db, "X,Y")
        @test row_target(rows[1]) == (:databases, "", "")
    end

    @testset "filter" begin
        f = tree_rows(snap, Set{String}(), "mag")   # case-insensitive, parents open
        @test labels(f) == ["Databases", "Kangaroo Hills 2024", "Channels", "MAG", "MAG_IGRF",
            "Grids", "KH2024_MAG_IGRF"]
        # A top folder without a match is left out.
        f = tree_rows(snap, Set{String}(), "t2010")
        @test labels(f) == ["Databases", "Kangaroo Hills 2024", "Lines", "T2010"]
        f = tree_rows(snap, Set{String}(), "kangaroo")   # a database name shows the database only
        @test labels(f) == ["Databases", "Kangaroo Hills 2024"]
        f = tree_rows(snap, Set{String}(), "lon, lat")   # a pair by its text
        @test labels(f) == ["Databases", "Kangaroo Hills 2024", "Channels", "LON, LAT"]
        f = tree_rows(snap, Set{String}(), "regional")
        @test labels(f) == ["Grids", "Regional_TMI_GA2019"]
        @test isempty(tree_rows(snap, Set{String}(), "no such name"))
        # The tree says so when a filter matches nothing; an empty project says nothing.
        @test UI.tree_empty_text("no such name", TreeRow[]) == "No matches"
        @test UI.tree_empty_text("", TreeRow[]) === nothing
        @test UI.tree_empty_text("mag", tree_rows(snap, Set{String}(), "mag")) === nothing
        f = tree_rows(snap, Set{String}(), "  ")   # blank is no filter
        @test labels(f) == ["Databases", "Grids"]
    end

    @testset "role tags and numbers" begin
        @test role_tag(Core.ROLE_NONE) == "" && role_tag(Core.ROLE_LINE) == "line" &&
              role_tag(Core.ROLE_ELEVATION) == "elevation"
        # The prototype's words for the geographic roles.
        @test role_tag(Core.ROLE_LON) == "longitude" && role_tag(Core.ROLE_LAT) == "latitude"
        @test fmt_int(0) == "0" && fmt_int(999) == "999" && fmt_int(1000) == "1,000" &&
              fmt_int(-1234567) == "-1,234,567"
        @test fmt_num(380_000, 0) == "380,000" && fmt_num(-260.34, 1) == "-260.3" &&
              fmt_num(607, 1) == "607.0" && fmt_num(-0.04, 1) == "0.0"
        # Huge and non-finite values never throw (a Float32 grid can hold 3.4e38).
        @test fmt_num(1e20, 1) == "1.0e20" && fmt_num(3e38, 0) == "3.0e38" && fmt_num(-3e38, 1) == "-3.0e38"
        @test fmt_num(Float64(typemax(Int)), 0) == "9.22337e18"
        @test fmt_num(Float64(Float32(1.70141e38)), 1) == "1.70141e38"
        @test fmt_num(NaN, 1) == "NaN" && fmt_num(Inf, 0) == "Inf" && fmt_num(-Inf, 1) == "-Inf"
        # A fraction that rounds up carries into the whole part, never ".100".
        @test fmt_num(99999999999999.995, 2) == "100,000,000,000,000.00"
        @test fmt_num(99999999999999.9, 2) == "99,999,999,999,999.90"
        @test fmt_num(0.999, 2) == "1.00" && fmt_num(-1.995, 2) == "-2.00" && fmt_num(1.005, 3) == "1.005"
        @test fmt_num(5e-324, 2) == "0.00" && fmt_num(-5e-324, 2) == "0.00" && short_num(5e-324) == "5.0e-324"
        @test fmt_num(123.456, 40) == "123.456"   # more digits than fit: as `exp_num`
        @test short_num(25.0) == "25" && short_num(12.5) == "12.5" && short_num(1e20) == "1.0e20" &&
              short_num(-3e38) == "-3.0e38" && short_num(Float64(typemax(Int))) == "9.22337e18" &&
              short_num(NaN) == "NaN" && short_num(Inf) == "Inf"
    end

    @testset "properties" begin
        p = properties(snap, (:database, db, ""))
        @test p.title == "Kangaroo Hills 2024"
        @test p.rows == [
            "Type" => "Line database", "Lines" => "60 (50 lines, 10 ties)", "Rows" => "172,900",
            "Channels" => "9", "Positions" => "X, Y (current) - GDA2020 / MGA zone 55",
            "" => "LON, LAT - GDA2020", "Folder" => "databases/$db", "Made by" => "-"]
        p = properties(snap, (:grid, grid, ""))
        @test p.title == "KH2024_MAG_IGRF"
        @test p.rows == ["Type" => "Grid", "Size" => "400 x 800 cells", "Cell size" => "25 m",
            "Origin" => "380,000 E, 7,905,000 N", "Rotation" => "0 deg",
            "System" => "GDA2020 / MGA zone 55 (EPSG:7855)", "Values" => "Float32, -260.3 to 607.1 nT"]
        p = properties(snap, (:line, db, "T2001"))
        @test p.title == "Line T2001"
        @test p.rows == ["Type" => "Tie (T)", "Number" => "2001, version 0", "Flight" => "12",
            "Rows" => "2,881", "Selected" => "Yes"]
        p = properties(snap, (:channel, db, "LON"))
        @test p.title == "Channel LON"
        @test p.rows == ["Label" => "LONGITUDE", "Data type" => "Float64", "Units" => "deg",
            "Role" => "longitude", "Protected" => "Yes", "Format" => "Normal", "Decimals" => "6"]
        p = properties(snap, (:pair, db, "LON,LAT"))
        @test p.rows == ["Type" => "Position pair", "X" => "LON", "Y" => "LAT",
            "System" => "GDA2020 (EPSG:7844)", "Current" => "No"]
        p = properties(snap, (:grid, gone, ""))
        @test p.rows == ["Type" => "Grid (missing)", "Was at" => "grids/gone", "Status" => "Folder not found"]
        @test properties(snap, (:databases, "", "")) === nothing
        @test properties(snap, (:channel, db, "NOPE")) === nothing   # gone since the click
        @test properties(snap, nothing) === nothing
    end

    @testset "keyboard moves and the visible rows" begin
        rows = tree_rows(snap, Set(["databases", "grids"]), "")
        @test next_row(rows, nothing, 1) == 1
        @test next_row(rows, rows[1].key, 1) == 2
        @test next_row(rows, rows[end].key, 1) == length(rows)
        @test next_row(rows, rows[1].key, -1) == 1
        @test next_row(rows, "gone-key", 1) == 1
        @test next_row(TreeRow[], nothing, 1) === nothing
        # Rows 26 px; a 100 px view scrolled 30 px shows rows 2 to 5 (1-based).
        @test visible_rows(5_000, 26f0, 30f0, 100f0) == 2:5
        @test visible_rows(3, 26f0, 0f0, 500f0) == 1:3
        @test visible_rows(0, 26f0, 0f0, 500f0) == 1:0
    end

    @testset "splitter width" begin
        @test drag_width(272, 30, 1, :left, (200, 480)) == 302
        @test drag_width(272, 30, 1.5, :left, (200, 480)) == 292
        @test drag_width(300, 30, 1, :right, (240, 480)) == 270   # the right pane grows to the left
        @test drag_width(272, -500, 1, :left, (200, 480)) == 200
        @test drag_width(272, 500, 1, :left, (200, 480)) == 480
    end

    @testset "menu separators and danger rows" begin
        items = [MenuItem("Rename..."), menu_separator(), MenuItem("Remove from Project"; danger = true)]
        view = Box(0, 0, 1000, 1000)
        l = menu_layout(Box(10, 10, 10, 10), items, view, 1, (t, z) -> 7f0 * length(t); gap = 0)
        @test l.box.y0 == 10   # a context menu opens at the point, no gap
        @test [height(r) for r in l.rows] == [24, 9, 24]
        @test height(l.box) == 2 + 8 + 24 + 9 + 24
        @test items[3].danger && items[2].separator
        l = menu_layout(Box(10, 980, 10, 980), items, view, 1, (t, z) -> 7f0 * length(t); gap = 0)
        @test l.box.y1 == 980   # flipped above the point
    end

    @testset "context menus" begin
        app = test_app_state(s)
        try
            refresh_now!(app)
            rows = tree_rows(app.snap, Set(["databases", db, "$db/lines", "$db/channels", "grids"]), "")
            menu(key) = [it.separator ? "-" : it.label for it in tree_menu(app, row(rows, key))]
            @test menu("databases") == ["Import Geosoft XYZ...", "Import CSV and Text..."]
            @test menu(db) == ["Statistics...", "Channel Math...", "Export Geosoft XYZ...",
                "Export CSV...", "Export Parquet...", "-", "Rename...", "Remove from Project"]
            @test menu("$db/lines") == ["Select All Lines", "Select No Lines"]
            @test menu("$db/channels/MAG") == ["Statistics...", "Channel Properties...", "Unprotect", "-",
                "Rename...", "Delete Channel..."]
            @test menu("$db/channels/IGRF")[3] == "Protect"
            @test menu("$db/pairs/X,Y") == ["Set as Current", "Remove Pair"]
            @test menu("grids") == ["Import GeoTIFF...", "Import ER Mapper...", "Import Geosoft or Surfer Grid..."]
            @test menu(grid) == ["Grid Statistics...", "Set Coordinate System...", "-", "Export GeoTIFF...",
                "Export ER Mapper...", "Export Geosoft Grid...", "-", "Rename...", "Remove from Project"]
            @test menu(gone) == ["Rename...", "Remove from Project"]
            @test isempty(tree_menu(app, row(rows, "$db/lines/L1001")))
            items = tree_menu(app, row(rows, db))
            @test items[end].danger && items[end].icon == "trash"

            # A tool entry pushes the tool request with the item (T11-C1).
            empty!(app.ui.requests)
            items[1].action(app)
            r = only(app.ui.requests)
            @test r isa UI.OpenToolDialog && r.id == "database.statistics" && r.item == db &&
                  isempty(r.values)
            # The channel's Statistics also names the channel.
            empty!(app.ui.requests)
            tree_menu(app, row(rows, "$db/channels/MAG"))[1].action(app)
            r = only(app.ui.requests)
            @test r.id == "database.statistics" && r.item == db && r.values == Dict{String,Any}("channel" => "MAG")
            empty!(app.ui.requests)
            gi = tree_menu(app, row(rows, grid))
            gi[2].action(app)
            r = only(app.ui.requests)
            @test r.id == "grid.set_crs" && r.item == grid
            empty!(app.ui.requests)
            gi[4].action(app)
            r = only(app.ui.requests)
            @test r isa UI.OpenExport && r.exporter_id == "export.geotiff" && r.item == grid
            empty!(app.ui.requests)
            tree_menu(app, row(rows, "$db/pairs/LON,LAT"))[1].action(app)
            r = only(app.ui.requests)
            @test r.id == "coordinates.set_current" && r.item == db

            # Rename opens the rename dialog; Remove from Project asks first.
            items[end-1].action(app)
            d = only(app.ui.dialogs)
            @test d isa RenameDialog && d.target == (:database, db, "") && UI.field_text(d.name) == "Kangaroo Hills 2024"
            empty!(app.ui.dialogs)
            items[end].action(app)
            c = only(app.ui.dialogs)
            @test c isa UI.ConfirmDialog && c.title == "Remove Kangaroo Hills 2024?" && c.danger &&
                  c.action == "Remove" && endswith(c.text, "It can be undone.")
            empty!(app.ui.dialogs)

            # Protect goes through the worker and the core.
            tree_menu(app, row(rows, "$db/channels/IGRF"))[3].action(app)
            wait_drained(app)
            refresh_now!(app)
            @test only(c for c in app.snap.databases[db].channels if c.name == "IGRF").protected
            # Remove Pair too; undo puts it back.
            tree_menu(app, row(rows, "$db/pairs/LON,LAT"))[2].action(app)
            wait_drained(app)
            refresh_now!(app)
            @test length(app.snap.databases[db].pairs) == 1
            UI.run_undo(app, false)
            wait_drained(app)
            refresh_now!(app)
            @test length(app.snap.databases[db].pairs) == 2
        finally
            UI.stop_worker!(app.queue)
        end
    end

    @testset "Select All and Select None act on the current database" begin
        app = test_app_state(s)
        try
            refresh_now!(app)
            app.ui.current_db = db
            UI.run_command!(app, "database.select_no_lines")
            wait_drained(app)
            refresh_now!(app)
            @test !any(l -> l.selected, app.snap.databases[db].lines)
            UI.run_command!(app, "database.select_all_lines")
            wait_drained(app)
            refresh_now!(app)
            @test all(l -> l.selected, app.snap.databases[db].lines)
        finally
            UI.stop_worker!(app.queue)
        end
    end

    @testset "item dialogs: rules" begin
        @test rename_problem("") !== nothing && rename_problem("   ") !== nothing
        @test rename_problem("New name") === nothing
        @test decimals_text(-1) == "auto" && decimals_text(3) == "3"
        @test parse_decimals("auto") == -1 && parse_decimals(" Auto ") == -1 && parse_decimals("") == -1
        @test parse_decimals("4") == 4 && parse_decimals("-1") == -1
        @test parse_decimals("-2") === nothing && parse_decimals("x") === nothing && parse_decimals("2.5") === nothing
        @test channel_info_problem("2", "10") === nothing
        @test channel_info_problem("x", "10") == "Decimals must be a whole number from 0, or auto."
        @test channel_info_problem("2", "0") == "Width must be a whole number from 1."
        @test channel_info_problem("2", "") == "Width must be a whole number from 1."
        r = ResultDialog("Statistics", "count 3\nmin 1")
        @test r.title == "Statistics" && r.text == "count 3\nmin 1" && r.lines == ["count 3", "min 1"]
    end

    finally
        Core.close_session!(s)
    end
end

@testset "frame guard: one report per error source, sticky while it lasts" begin
    app = test_app_state(nothing)
    logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
    reports() = count(r -> r.level == Base.CoreLogging.Error, logger.logs)
    try
    Base.CoreLogging.with_logger(logger) do
        # Messages that change every frame, from one place: one entry, one toast.
        bad(k, t) = try
            UI.hex_rgba("red$k")
        catch err
            UI.note_draw_error!(app, err, catch_backtrace(); now = t)
        end
        for k in 1:5
            bad(k, 100.0 + 0.1k)
        end
        e = only(app.draw_errors)
        @test e.count == 5 && e.reports == 1 && e.text == "Expected a colour like #RRGGBB, got \"red1\"."
        t = only(app.toasts)
        @test t.kind === :error && UI.toast_expired(t, 1e9) == false   # sticky
        # While it keeps coming the toast stays; once it stops for a while it goes.
        UI.settle_draw_errors!(app; now = 102.0)
        @test only(app.toasts) === t
        UI.settle_draw_errors!(app; now = 100.5 + UI.DRAW_ERROR_QUIET + 0.1)
        @test isempty(app.toasts) && e.toast === nothing
        # Back again after that: a new toast and a new report.
        bad(6, 120.0)
        @test e.reports == 2 && e.count == 6 && length(app.toasts) == 1 && e.toast === only(app.toasts)
        # Another place is another entry.
        try
            UI.parse_chord("Ctrl+Nope")
        catch err
            UI.note_draw_error!(app, err, catch_backtrace(); now = 121.0)
        end
        @test length(app.draw_errors) == 2 && length(app.toasts) == 2
    end
    @test reports() == 3   # one log entry per report, with its backtrace
    @test all(r -> r.kwargs[:exception] isa Tuple, logger.logs)
    finally
        UI.stop_worker!(app.queue)
    end
end
