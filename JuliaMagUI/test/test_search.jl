using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Box, search_commands, search_layout, shortcut_rows, tool_groups, tool_entries, shell_layout

ids(cmds) = [c.id for c in cmds]

@testset "command search" begin
    @testset "scores: name start, name, id, location and help" begin
        with_app(app_with_database()) do app
            cmds = UI.commands(app)
            @test first(search_commands(cmds, "channel m")).id == "database.channel_math"     # name starts with: 4
            r = search_commands(cmds, "statistics")
            @test findfirst(c -> c.id == "database.statistics", r) < findfirst(c -> c.id == "grid.statistics", r)   # name starts with beats contains
            @test first(search_commands(cmds, "guess_utm")).id == "coordinates.guess_utm"   # id match
            @test isempty(search_commands(cmds, "zzzz"))
            @test length(search_commands(cmds, "")) == count(c -> c.searchable, cmds)
            # Case and spaces around the query do not matter.
            @test ids(search_commands(cmds, "  CHANNEL M ")) == ids(search_commands(cmds, "channel m"))
            # The location ("Database Tools > Channels") and the help text count too.
            @test "database.channel_math" in ids(search_commands(cmds, "database tools >"))
            @test "session.undo" in ids(search_commands(cmds, "last change"))
            # Split buttons are not searchable.
            @test !("import.database" in ids(search_commands(cmds, "import")))
        end
    end

    @testset "ties keep the command order, disabled ones go last, limit" begin
        run = app -> nothing
        cmds = [UI.Command("t.a", "Alpha One", run; enabled = app -> "Not now."),
            UI.Command("t.b", "Alpha Two", run),
            UI.Command("t.c", "Alpha Three", run),
            UI.Command("t.d", "The Alpha", run),
            UI.Command("t.e", "Hidden Alpha", run; searchable = false)]
        on(c) = c.enabled(nothing) === nothing
        @test ids(search_commands(cmds, "alpha")) == ["t.a", "t.b", "t.c", "t.d"]
        @test ids(search_commands(cmds, "alpha"; enabled = on)) == ["t.b", "t.c", "t.a", "t.d"]
        # A disabled command with a better score still comes first.
        @test ids(search_commands(cmds, "alpha one"; enabled = on)) == ["t.a"]
        @test ids(search_commands(cmds, ""; enabled = on)) == ["t.b", "t.c", "t.d", "t.a"]
        @test ids(search_commands(cmds, "alpha"; limit = 2)) == ["t.a", "t.b"]
        @test isempty(search_commands(cmds, "alpha"; limit = -1))   # a negative limit gives none
        # Regex characters are plain text; letters outside ASCII match in any case.
        more = [UI.Command("t.r", "A.B (Copy)", run), UI.Command("t.x", "AxB", run),
            UI.Command("t.u", "Ändra Östra", run), UI.Command("t.o", "Ørsted Grid", run)]
        @test ids(search_commands(more, "a.b")) == ["t.r"]
        @test ids(search_commands(more, "(copy")) == ["t.r"]
        @test isempty(search_commands(more, "a+b")) && isempty(search_commands(more, "["))
        @test ids(search_commands(more, "ä")) == ["t.u"] && ids(search_commands(more, "ÖSTRA")) == ["t.u"]
        @test ids(search_commands(more, "Ø")) == ["t.o"] && ids(search_commands(more, "ørsted")) == ["t.o"]
    end

    @testset "an empty query lists the shell commands first, in the prototype's order" begin
        with_app(app_with_database()) do app
            r = ids(search_commands(UI.commands(app), ""))
            @test r[1:7] == ["project.backstage", "project.new", "project.open", "project.close",
                "project.run_script", "session.undo", "session.redo"]
            @test findfirst(==("ui.command_search"), r) < findfirst(==("database.channel_math"), r)
            # A query still ranks by score first.
            @test first(search_commands(UI.commands(app), "channel m")).id == "database.channel_math"
        end
    end

    @testset "the overlay layout" begin
        vp = Box(0, 0, 1480, 920)
        l = search_layout(vp, 1, 40)
        @test l.box == Box(460, 84, 1020, 536)   # 1 + 42 + 380 + 28 + 1, as the prototype
        @test l.top == Box(461, 85, 1019, 127) && l.list == Box(461, 127, 1019, 507)
        @test l.foot == Box(461, 507, 1019, 535)
        one = search_layout(vp, 1, 1)
        @test one.list == Box(461, 127, 1019, 163) && one.box.y1 == 192   # 4 + 28 + 4
        none = search_layout(vp, 1, 0)
        @test none.list == Box(461, 127, 1019, 215) && none.box.y1 == 244   # 4 + 80 + 4
        # At most the window width less 48 px; at scale 1.5 every length scales.
        @test search_layout(Box(0, 0, 500, 920), 1, 3).box == Box(24, 84, 476, 84 + 1 + 42 + 92 + 28 + 1)
        h = search_layout(Box(0, 0, 1480, 920), 1.5, 40)
        @test h.box.y0 == 126 && h.box.x1 - h.box.x0 == 840 && h.box.x0 == 320
        # A short window: the list shrinks so the overlay stays 24 px above the bottom.
        short = search_layout(Box(0, 0, 900, 400), 1, 40)
        @test short.box.y1 <= 376 && short.list.y1 - short.list.y0 >= 28
    end

    @testset "open, close and the cached results" begin
        with_app(app_with_database()) do app
            ui = app.ui
            UI.run_command!(app, "ui.command_search")
            @test ui.search == "" && ui.search_index == 1 && ui.search_level == 0
            first_hits = UI.search_hits!(app)
            @test UI.search_hits!(app) === first_hits   # not searched again
            UI.set_search_query!(app, "math")
            @test ui.search_index == 1
            hits = UI.search_hits!(app)
            @test hits !== first_hits && first(hits).id == "database.channel_math"
            @test UI.search_hits!(app) === hits
            # The enabled state is part of the key: a command that turns off moves down.
            s = app.session
            UI.set_session!(app, nothing)
            Core.close_session!(s)
            @test UI.search_hits!(app) !== hits
            UI.close_search!(app)
            @test ui.search === nothing
        end
    end

    @testset "over a dialog, commands that change the project wait" begin
        with_app(app_with_database()) do app
            Core.rename_item!(app.session, app.ui.current_db, "Renamed")
            refresh_now!(app)
            find(id) = UI.find_command(app, id)
            @test UI.search_reason(app, find("session.undo")) === nothing
            UI.confirm!(app, "Remove?", "Sure?"; action = "Remove", on_yes = a -> nothing)
            UI.open_search!(app)
            for id in ("session.undo", "project.close", "project.new", "project.open",
                    "project.backstage", "database.select_all_lines", "database.select_no_lines")
                @test UI.search_reason(app, find(id)) == "Close the dialog first."
            end
            # Commands that open a dialog on top, or only change the view, still run.
            for id in ("database.channel_math", "import.csv", "ui.theme.dark", "ui.shortcuts", "ui.tools_pane")
                @test UI.search_reason(app, find(id)) === nothing
            end
            # Run from the search, Undo only says why.
            UI.run_search_hit!(app, find("session.undo"))
            @test last(app.toasts).text == "Close the dialog first." && app.queue.pending == 0
            # They sort after the commands that can run: the list opens on Command Search.
            UI.open_search!(app)
            r = ids(UI.search_hits!(app))
            @test first(r) == "ui.command_search"
            @test findfirst(==("session.undo"), r) > findfirst(==("database.channel_math"), r)
        end
    end

    @testset "the highlight follows its command when the order changes" begin
        with_app(app_with_database()) do app
            UI.open_search!(app)
            before = UI.search_hits!(app)
            k = findfirst(c -> c.id == "database.statistics", before)
            app.ui.search_index = k
            @test findfirst(c -> c.id == "session.undo", before) > k   # Undo cannot run yet
            # Undo turns on: it moves up, before Statistics, which moves down a row.
            Core.rename_item!(app.session, app.ui.current_db, "Renamed")
            refresh_now!(app)
            moved = UI.search_hits!(app)
            @test moved !== before && findfirst(c -> c.id == "session.undo", moved) < k
            @test app.ui.search_index == k + 1 && moved[app.ui.search_index].id == "database.statistics"
            # A command that leaves the list leaves the index in range.
            app.ui.search_index = length(moved)
            s = app.session
            UI.set_session!(app, nothing)
            Core.close_session!(s)
            after = UI.search_hits!(app)
            @test 1 <= app.ui.search_index <= max(length(after), 1)
        end
    end

    @testset "shortcuts while the search is open" begin
        with_app(test_app_state(nothing)) do app
            cmds = UI.commands(app)
            route(text) = (c = UI.shortcut_command(cmds, UI.parse_chord(text), UI.blocks_shortcuts(app), false);
                c === nothing ? nothing : c.id)
            @test route("Ctrl+F1") == "ui.ribbon"
            UI.open_search!(app)
            @test route("Ctrl+F1") === nothing && route("Ctrl+K") == "ui.command_search"
            # Ctrl+K again keeps the query.
            UI.set_search_query!(app, "ma")
            UI.run_command!(app, "ui.command_search")
            @test app.ui.search == "ma"
        end
    end
end

@testset "keyboard shortcuts list" begin
    with_app(test_app_state(nothing)) do app
        rows = shortcut_rows(UI.commands(app))
        @test [r.keys for r in rows] == [["Ctrl+K"], ["Ctrl+Z"], ["Ctrl+Y", "Ctrl+Shift+Z"],
            ["Ctrl+N"], ["Ctrl+O"], ["Ctrl+F1"], ["Ctrl+Shift+L"], ["Esc"]]
        @test [r.text for r in rows] == ["Command search", "Undo", "Redo", "New project",
            "Open project", "Collapse or expand the ribbon", "Switch light and dark",
            "Close a dialog, menu or the command search"]
        # A command with a shortcut of its own is listed by its name, before Esc.
        extra = [UI.commands(app); UI.Command("t.x", "Do Something...", a -> nothing; shortcut = "Ctrl+F2")]
        r = shortcut_rows(extra)
        @test r[end-1].keys == ["Ctrl+F2"] && r[end-1].text == "Do Something" && r[end].keys == ["Esc"]
    end
end

@testset "Tools pane" begin
    with_app(test_app_state(nothing)) do app
        cmds = UI.commands(app)
        entries = tool_entries(cmds)
        ids(groups) = [e.cmd.id for (_, es) in groups for e in es]
        groups = tool_groups(entries, "")
        @test first.(groups) == ["Database", "Database Tools", "Coordinates", "Grid and Image"]
        # Every tool, importer and exporter, once, by its command.
        everything = [[t.id for t in Core.tools()]; [i.id for i in Core.importers()]; [e.id for e in Core.exporters()]]
        @test sort(ids(groups)) == sort(everything)
        # The prototype's grouping: a tab's imports, then its exports, then its tools.
        db = last(groups[1])
        @test [e.cmd.id for e in db] == ["import.geosoft_xyz", "import.csv", "export.geosoft_xyz", "export.csv", "export.parquet"]
        @test UI.plain_name(first(db).cmd) == "Import Geosoft XYZ"
        grid = [e.cmd.id for e in last(groups[4])]
        @test findfirst(==("import.geotiff"), grid) < findfirst(==("export.geotiff"), grid) <
              findfirst(==("grid.statistics"), grid)
        # A tool is in the tab of its first place.
        @test "grid.set_crs" in [e.cmd.id for e in last(groups[3])]
        # Imports and exports run as jobs, a tool as its registry says.
        job(id) = only(e for e in entries if e.cmd.id == id).job
        @test job("import.csv") && job("export.parquet") && job("database.channel_math")
        @test !job("database.statistics")
        # The filter matches the name or the id, in any case.
        @test ids(tool_groups(entries, "MATH")) == ["database.channel_math"]
        @test ids(tool_groups(entries, "guess_")) == ["coordinates.guess_utm"]
        @test ids(tool_groups(entries, "geosoft xyz")) == ["import.geosoft_xyz", "export.geosoft_xyz"]
        @test isempty(tool_groups(entries, "zzzz"))
        # The pane's rows are cached on the command list and the filter.
        first_rows = UI.tools_rows!(app)
        @test UI.tools_rows!(app) === first_rows
        app.ui.tools_query = "math"
        @test UI.tools_rows!(app) !== first_rows && ids(UI.tools_rows!(app)) == ["database.channel_math"]
    end
end

@testset "right pane" begin
    @testset "layout" begin
        l = shell_layout(0, 0, 1480, 920, 1, 272f0, false; right_width = 300f0)
        @test l.right == Box(1180, 168, 1480, 894) && l.center == Box(272, 168, 1180, 894)
        @test shell_layout(0, 0, 1480, 920, 1, 272f0, false).right === nothing
        # Clamped to 240 to 480; a bad width gives 300.
        @test shell_layout(0, 0, 1480, 920, 1, 272f0, false; right_width = 9f3).right.x0 == 1000
        @test shell_layout(0, 0, 1480, 920, 1, 272f0, false; right_width = 10f0).right.x0 == 1240
        @test shell_layout(0, 0, 1480, 920, 1.5, 272f0, false; right_width = NaN32).right.x0 == 1030
        # In the smallest window with both panes at 480, the right pane shrinks first, so the
        # centre keeps its minimum and the splitters stay apart.
        n = shell_layout(0, 0, 900, 560, 1, 480f0, false; right_width = 480f0)
        @test n.left.x1 == 480 && n.right.x1 == 900
        @test n.center.x1 - n.center.x0 == UI.CENTER_MIN && n.right.x0 - n.left.x1 == UI.CENTER_MIN
        # Narrower still (900 px at scale 2): both panes at their least, the centre what is left.
        t = shell_layout(0, 0, 900, 560, 2, 480f0, false; right_width = 480f0)
        @test t.left.x1 == 400 && t.right.x0 == 900 - 480 && t.center.x1 - t.center.x0 == 20
        # Without a right pane the left one also leaves the centre its minimum.
        @test shell_layout(0, 0, 900, 560, 2, 480f0, false).left.x1 == 900 - 2 * UI.CENTER_MIN
    end

    @testset "requests open and close panes" begin
        with_app(test_app_state(nothing)) do app
            ui = app.ui
            UI.run_command!(app, "ui.tools_pane")
            UI.handle_requests!(app)
            @test ui.right_tabs == [:tools] && ui.right_active === :tools
            @test UI.find_command(app, "ui.tools_pane").checked(app)
            UI.run_command!(app, "ui.tools_pane")   # a toggle, as the prototype's
            UI.handle_requests!(app)
            @test isempty(ui.right_tabs) && ui.right_active === :none
            UI.run_command!(app, "ui.jobs_pane")
            UI.handle_requests!(app)
            @test ui.left_tab === :jobs && UI.find_command(app, "ui.jobs_pane").checked(app)
            UI.run_command!(app, "ui.shortcuts")
            UI.handle_requests!(app)
            @test only(ui.dialogs) isa UI.ShortcutsDialog
        end
    end
end
