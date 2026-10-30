using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: RibbonGroup, RibbonItem, BigButton, SplitButton, SmallColumn, Custom,
    ribbon_layout, item_width, group_width, commands, Command, ribbon_scroll_max,
    ribbon_arrows, ribbon_scroll_step, chooser_note, menu_layout, MenuItem, Box, width

# Text widths without fonts: 7 px per character at scale 1.
measure7(text, size) = 7f0 * length(text)

# A command with only an id, a label and places, for layout tests.
fake_command(id, places; label = id, menu = String[]) =
    Command(id, id, app -> nothing; label, places, menu)

@testset "ribbon" begin
    @testset "layout of the real tabs" begin
        with_app(app_with_database()) do app
            cmds = commands(app)
            g = ribbon_layout(cmds, "Coordinates")
            @test [x.name for x in g] == ["Coordinate system", "Reproject", "Position pairs"]
            @test g[1].items == [BigButton("coordinates.set_crs"), SmallColumn(["coordinates.guess_utm"]),
                BigButton("grid.set_crs")]
            @test g[2].items == [BigButton("coordinates.reproject")]
            @test g[3].items == [SmallColumn(["coordinates.set_current"])]

            d = ribbon_layout(cmds, "Database")
            @test first(d).items == [Custom(:db_chooser)] && d[2].name == "Import" &&
                  d[2].items[1] isa SplitButton
            @test [x.name for x in d] == ["Database", "Import", "Export", "Lines", "Channels"]
            # Importers and exporters show only through their split buttons (T8-R1).
            @test d[2].items == [SplitButton("import.database")]
            @test d[3].items == [SplitButton("export.database")]
            @test d[4].items == [SmallColumn(["database.select_all_lines", "database.select_no_lines"])]
            @test d[5].items == [BigButton("coordinates.set_current")]
            # The split menu shows the format names.
            byid = Dict(c.id => c for c in cmds)
            @test [byid[id].menu_label for id in byid["import.database"].menu] ==
                  ["Geosoft XYZ...", "CSV and text..."]
            @test byid["export.database"].menu_label == "Export"

            gi = ribbon_layout(cmds, "Grid and Image")
            @test [x.name for x in gi] == ["Import", "Export", "Properties"]
            @test gi[3].items == [BigButton("grid.set_crs"), BigButton("grid.statistics")]

            t = ribbon_layout(cmds, "Database Tools")
            @test [x.name for x in t] == ["Channels", "Find"]
            @test t[1].items == [BigButton("database.channel_math"), BigButton("database.statistics")]

            @test isempty(ribbon_layout(cmds, "No Such Tab"))
            # Settings and Help come from the same item types (Task 15 draws more there).
            @test ribbon_layout(cmds, "Settings")[1].items ==
                  [BigButton("ui.theme.light"), BigButton("ui.theme.dark"), BigButton("ui.theme.system")]
        end
    end

    @testset "order: place order, then the order of the list" begin
        P(group, size, order) = [Core.Place("T", group; size, order)]
        cmds = [
            fake_command("b", P("G1", :big, 5)),
            fake_command("a", P("G1", :big, -1)),
            fake_command("s1", P("G1", :small, 0)),
            fake_command("s2", P("G1", :small, 0)),
            fake_command("s3", P("G1", :small, 0)),
            fake_command("s4", P("G1", :small, 0)),
            fake_command("x", P("G2", :big, 0)),
            fake_command("other tab", [Core.Place("U", "G1")]),
        ]
        g = ribbon_layout(cmds, "T")
        @test [x.name for x in g] == ["G1", "G2"]
        # Three small buttons per column at most; a big button ends a column.
        @test g[1].items == [BigButton("a"), SmallColumn(["s1", "s2", "s3"]), SmallColumn(["s4"]),
            BigButton("b")]
        @test g[2].items == [BigButton("x")]
    end

    @testset "a split button hides the commands of its menu in its group only" begin
        cmds = [
            fake_command("fmt.a", [Core.Place("T", "Import"; size = :small), Core.Place("T", "Other"; size = :small)]),
            fake_command("fmt.b", [Core.Place("T", "Import"; size = :small)]),
            fake_command("split", [Core.Place("T", "Import")]; menu = ["fmt.a", "fmt.b"]),
        ]
        g = ribbon_layout(cmds, "T")
        @test g[1] == RibbonGroup("Import", RibbonItem[SplitButton("split")])
        @test g[2].items == [SmallColumn(["fmt.a"])]
    end

    @testset "items compare by value" begin
        @test SmallColumn(["a", "b"]) == SmallColumn(["a", "b"])
        @test hash(SmallColumn(["a", "b"])) == hash(SmallColumn(["a", "b"]))
        @test SmallColumn(["a"]) != SmallColumn(["b"])
        @test BigButton("a") != SplitButton("a")
        @test hash(BigButton("a")) != hash(SplitButton("a"))
        @test Custom(:db_chooser) == Custom(:db_chooser)
        @test RibbonGroup("G", [BigButton("a")]) == RibbonGroup("G", RibbonItem[BigButton("a")])
        @test hash(RibbonGroup("G", [BigButton("a")])) == hash(RibbonGroup("G", RibbonItem[BigButton("a")]))
        @test length(Set([SmallColumn(["a"]), SmallColumn(["a"])])) == 1
        @test_throws ArgumentError SmallColumn(String[])
        @test_throws ArgumentError SmallColumn(["a", "b", "c", "d"])
    end

    @testset "widths" begin
        w = item_width(BigButton("x"), (t, s) -> 7f0 * length(t))
        @test w == 50f0                                            # short label: the 50 px floor
        label = Dict("cm" => "Channel\nMath", "imp" => "Import", "s" => "Select All", "n" => "Select None")
        lab(id) = label[id]
        # Big: the widest line + 14.
        @test item_width(BigButton("cm"), measure7; label = lab) == 7 * 7 + 14
        # Split: big + 20.
        @test item_width(SplitButton("imp"), measure7; label = lab) == 6 * 7 + 14 + 20
        # Small: 26 + label + 8; a column is as wide as its widest button.
        @test item_width(SmallColumn(["s", "n"]), measure7; label = lab) == 26 + 77 + 8
        # The chooser: 170 px combo + 4 px padding each side, or a wider note (180 at most).
        @test item_width(Custom(:db_chooser), measure7) == 178
        @test item_width(Custom(:db_chooser), measure7; note = "60 lines, 24 channels") == 178
        @test item_width(Custom(:db_chooser), measure7; note = "x"^25) == 8 + 175
        @test item_width(Custom(:db_chooser), measure7; note = "x"^40) == 8 + 180
        # Group: items with 2 px between, or the label + 12, then 7 + 1 + 6 + 2 for the
        # separator (the prototype render; the brief said 6 + 1 + 7).
        g = RibbonGroup("Lines", [SmallColumn(["s", "n"]), BigButton("cm")])
        @test group_width(g, measure7; label = lab) == (111 + 2 + 63) + 16
        @test group_width(RibbonGroup("A very long group name", [BigButton("imp")]), measure7; label = lab) ==
              7 * 22 + 12 + 16

        # High DPI: at scale 1.5 every width is 1.5 times as wide.
        measure15(t, s) = 1.5f0 * measure7(t, s)
        for item in (BigButton("x"), BigButton("cm"), SplitButton("imp"), SmallColumn(["s", "n"]),
                Custom(:db_chooser))
            @test item_width(item, measure15; label = id -> get(label, id, id), scale = 1.5) ==
                  1.5f0 * item_width(item, measure7; label = id -> get(label, id, id))
        end
        @test group_width(g, measure15; label = lab, scale = 1.5) == 1.5f0 * group_width(g, measure7; label = lab)
    end

    @testset "scrolling" begin
        @test ribbon_scroll_max(500, 884) == 0
        @test ribbon_scroll_max(1200, 884) == 316
        @test ribbon_arrows(0, 0) == (false, false)
        @test ribbon_arrows(0, 316) == (false, true)
        @test ribbon_arrows(100, 316) == (true, true)
        @test ribbon_arrows(316, 316) == (true, false)
        @test ribbon_arrows(315.6, 316) == (true, false)   # within half a pixel of the end
        # A click on an arrow scrolls 60 % of the view, at least 120 px.
        @test ribbon_scroll_step(884, 1) == 884 * 0.6f0
        @test ribbon_scroll_step(150, 1) == 120
        @test ribbon_scroll_step(150, 1.5) == 180
    end

    @testset "the chooser note" begin
        with_app(test_app_state(session_with(lines = 60, channels = 24))) do app
            refresh_now!(app)
            UI.sync_current_db!(app)
            @test chooser_note(app) == "60 lines, 24 channels"
            app.ui.current_db = ""
            @test chooser_note(app) == ""
        end
        with_app(test_app_state(session_with(lines = 1, channels = 1))) do app
            refresh_now!(app)
            UI.sync_current_db!(app)
            @test chooser_note(app) == "1 line, 1 channel"
        end
        with_app(test_app_state(nothing)) do app
            @test chooser_note(app) == ""
        end
    end

    @testset "menu layout" begin
        items = [MenuItem("Geosoft XYZ..."; icon = "import"), MenuItem("CSV and text..."; icon = "fileCsv")]
        vp = Box(0, 0, 1480, 920)
        m = menu_layout(Box(252, 71, 272, 141), items, vp, 1, measure7)
        # Under the anchor, 2 px down; 200 px wide at least; 4 px padding and 24 px rows.
        @test m.box == Box(252, 143, 452, 143 + 2 + 8 + 48)
        @test m.rows == [Box(257, 148, 447, 172), Box(257, 172, 447, 196)]
        # Near the right edge it moves left; near the bottom it opens above the anchor.
        r = menu_layout(Box(1400, 860, 1420, 900), items, vp, 1, measure7)
        @test r.box.x1 == 1472 && r.box.y1 == 858
        # A long label makes it wider, up to 360.
        long = [MenuItem("x"^80)]
        @test width(menu_layout(Box(0, 0, 10, 10), long, vp, 1, measure7).box) == 360
        # min_width: a combo's menu is as wide as the combo.
        c = menu_layout(Box(12, 91, 182, 113), [MenuItem("A"; checked = true)], vp, 1,
            measure7; min_width = 170)
        @test width(c.box) == 170
    end
end
