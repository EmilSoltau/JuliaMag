using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Box, search_commands, search_layout, shortcut_rows, tool_groups, shell_layout

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
            UI.set_session!(app, nothing)
            @test UI.search_hits!(app) !== hits
            UI.close_search!(app)
            @test ui.search === nothing
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
    tools = Core.tools()
    groups = tool_groups(tools, "")
    @test first.(groups) == ["Database Tools", "Coordinates", "Grid and Image"]
    listed = [t.id for (_, ts) in groups for t in ts]
    @test sort(listed) == sort([t.id for t in tools])   # every tool, once
    # A tool is in the tab of its first place.
    @test "grid.set_crs" in [t.id for t in last(groups[2])]
    @test [t.id for (_, ts) in tool_groups(tools, "MATH") for t in ts] == ["database.channel_math"]
    @test [t.id for (_, ts) in tool_groups(tools, "guess_") for t in ts] == ["coordinates.guess_utm"]
    @test isempty(tool_groups(tools, "zzzz"))
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
        # It never pushes the centre below nothing.
        n = shell_layout(0, 0, 600, 560, 1, 480f0, false; right_width = 480f0)
        @test n.center.x1 >= n.center.x0 && n.right.x1 == 600
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
