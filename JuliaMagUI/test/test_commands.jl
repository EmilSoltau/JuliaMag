using Test
import JuliaMagCore as Core
import JuliaMagUI as UI

# A request type no task handles.
struct UnknownRequest end

# Requests whose handlers fail or count, for the error test of `handle_requests!`.
struct FailingRequest end
struct CountingRequest
    count::Base.RefValue{Int}
end
UI.handle_request!(app, ::FailingRequest) = error("the handler broke")
UI.handle_request!(app, r::CountingRequest) = (r.count[] += 1; true)
struct SwitchProjectRequest end
UI.handle_request!(app, ::SwitchProjectRequest) = (UI.set_session!(app, nothing); true)

@testset "commands" begin
    @testset "list, enabled and places" begin
        with_app(test_app_state(fresh_session())) do app
            cmds = UI.commands(app)
            ids = Set(c.id for c in cmds)
            @test "database.channel_math" in ids && "import.geosoft_xyz" in ids && "session.undo" in ids
            @test length(ids) == length(cmds)
            cm = only(filter(c -> c.id == "database.channel_math", cmds))
            @test cm.enabled(app) == "Import line data first."
            @test UI.tab_order(cmds, String[]) == ["Database", "Database Tools", "Coordinates", "Grid and Image"]
            @test UI.tab_order(cmds, ["Coordinates"]) == ["Database", "Database Tools", "Grid and Image"]
            @test UI.location(cm) == "Database Tools > Channels"
            @test UI.location(only(filter(c -> c.id == "session.undo", cmds))) == ""
            @test UI.commands(app) === cmds   # cached

            gs = only(filter(c -> c.id == "grid.statistics", cmds))
            @test gs.enabled(app) == "Import a grid first."
            imp = only(filter(c -> c.id == "import.geosoft_xyz", cmds))
            @test imp.name == "Import Geosoft XYZ..." && imp.enabled(app) === nothing
            @test imp.places == [Core.Place("Database", "Import"; size = :small)]
            csv = only(filter(c -> c.id == "import.csv", cmds))
            @test csv.name == "Import CSV and Text..."
            exp = only(filter(c -> c.id == "export.csv", cmds))
            @test exp.name == "Export CSV..." && exp.enabled(app) == "Import line data first."
            split = only(filter(c -> c.id == "import.database", cmds))
            @test split.menu == [i.id for i in Core.importers() if i.kind == Core.ITEM_DATABASE]
            @test only(split.places).size == :big && !split.searchable
            @test !only(filter(c -> c.id == "database.choose", cmds)).searchable
            sel = only(filter(c -> c.id == "database.select_all_lines", cmds))
            @test only(sel.places).size == :small
            @test UI.title_case("set coordinate system") == "Set Coordinate System"
            @test UI.title_case("Guess UTM zone") == "Guess UTM Zone"
            @test UI.ribbon_label("Set Coordinate System...") == "Set Coordinate\nSystem"
            @test UI.ribbon_label("Reproject...") == "Reproject"

            nosession = only(filter(c -> c.id == "session.undo", cmds))
            @test nosession.enabled(app) == "Nothing to undo."   # a session, no steps
            @test UI.tab_order(cmds, String[]) ⊇ ["Database"]
        end
        app = test_app_state(nothing)
        with_app(app) do app
            cmds = UI.commands(app)
            cm = only(filter(c -> c.id == "database.channel_math", cmds))
            @test cm.enabled(app) == "Open a project first."
            @test only(filter(c -> c.id == "import.csv", cmds)).enabled(app) == "Open a project first."
            @test only(filter(c -> c.id == "project.close", cmds)).enabled(app) == "Open a project first."
        end
    end

    @testset "enabled with a database, rebuild on registry change" begin
        with_app(app_with_database()) do app
            cmds = UI.commands(app)
            cm = only(filter(c -> c.id == "database.channel_math", cmds))
            @test cm.enabled(app) === nothing
            @test only(filter(c -> c.id == "export.csv", cmds)).enabled(app) === nothing
            @test only(filter(c -> c.id == "export.database", cmds)).enabled(app) === nothing
            @test only(filter(c -> c.id == "export.grid", cmds)).enabled(app) == "Import a grid first."

            tool = Core.ToolSpec("magnetics.test", "Lag correction", "Test.", "math",
                [Core.Place("Magnetics", "Corrections")], ["database" => Core.ITEM_DATABASE],
                Core.SettingSpec[], :quick, (args...) -> nothing)
            Core.register_tool!(tool)
            try
                cmds2 = UI.commands(app)
                @test cmds2 !== cmds && any(c -> c.id == "magnetics.test", cmds2)
                @test UI.tab_order(cmds2, String[]) ==
                      ["Database", "Database Tools", "Coordinates", "Grid and Image", "Magnetics"]
                t = only(filter(c -> c.id == "magnetics.test", cmds2))
                @test t.name == "Lag Correction..."
                t.run(app)
                @test app.ui.requests == Any[UI.OpenToolDialog("magnetics.test", app.ui.current_db)]
            finally
                Core.unregister_tool!("magnetics.test")
            end
            @test !any(c -> c.id == "magnetics.test", UI.commands(app))
            # A new project clears the cache.
            before = UI.commands(app)
            UI.set_session!(app, app.session)
            @test UI.commands(app) !== before
        end
    end

    @testset "requests" begin
        with_app(app_with_database()) do app
            cmds = Dict(c.id => c for c in UI.commands(app))
            cmds["project.new"].run(app)
            cmds["project.open"].run(app)
            cmds["project.backstage"].run(app)
            cmds["import.csv"].run(app)
            cmds["export.csv"].run(app)
            cmds["ui.shortcuts"].run(app)
            cmds["ui.tools_pane"].run(app)
            cmds["project.close"].run(app)
            id = app.ui.current_db
            @test app.ui.requests == Any[UI.OpenBackstage(:new), UI.OpenBackstage(:open),
                UI.OpenBackstage(:start), UI.OpenImport("import.csv"), UI.OpenExport("export.csv", id),
                UI.OpenDialog(:shortcuts), UI.OpenPane(:tools), UI.CloseProject()]
        end
    end

    @testset "handle_requests! drops what nobody handles" begin
        with_app(test_app_state(nothing)) do app
            push!(app.ui.requests, UnknownRequest(), UI.OpenPane(:nothing_here))
            @test_logs (:debug, "No handler for this request, dropped") (:debug, "No handler for this request, dropped") min_level = Base.CoreLogging.Debug UI.handle_requests!(app)
            @test isempty(app.ui.requests)
            UI.handle_requests!(app)   # empty list: nothing happens
        end
    end

    @testset "handle_requests! survives a handler that throws" begin
        with_app(test_app_state(nothing)) do app
            count = Ref(0)
            push!(app.ui.requests, CountingRequest(count), FailingRequest(), CountingRequest(count))
            @test_logs (:error, "Unexpected error") UI.handle_requests!(app)
            # The rest of the batch ran, and the error became a toast.
            @test count[] == 2 && isempty(app.ui.requests)
            t = only(app.toasts)
            @test t.kind == :error && occursin("the handler broke", t.text)
        end
    end

    @testset "handle_requests! drops the rest of a batch made for the old project" begin
        with_test_session(fresh_session()) do s
            with_app(test_app_state(s)) do app
                count = Ref(0)
                push!(app.ui.requests, CountingRequest(count), SwitchProjectRequest(),
                    CountingRequest(count))
                UI.handle_requests!(app)
                @test count[] == 1 && app.session === nothing && isempty(app.ui.requests)
            end
        end
    end

    @testset "undo and redo go through the worker" begin
        with_app(app_with_database()) do app
            id = app.ui.current_db
            cmds = Dict(c.id => c for c in UI.commands(app))
            @test cmds["session.undo"].enabled(app) == "Nothing to undo."
            Core.rename_item!(app.session, id, "Renamed")
            refresh_now!(app)
            @test cmds["session.undo"].enabled(app) === nothing
            @test cmds["session.redo"].enabled(app) == "Nothing to redo."
            cmds["session.undo"].run(app)
            wait_drained(app)
            @test Core.item(app.session.project, id).name != "Renamed"
            refresh_now!(app)
            @test cmds["session.redo"].enabled(app) === nothing
            cmds["session.redo"].run(app)
            wait_drained(app)
            @test Core.item(app.session.project, id).name == "Renamed"
        end
    end

    @testset "select all and no lines" begin
        with_app(app_with_database()) do app
            id = app.ui.current_db
            cmds = Dict(c.id => c for c in UI.commands(app))
            pick_all, pick_none = cmds["database.select_all_lines"], cmds["database.select_no_lines"]
            @test pick_all.enabled(app) === nothing
            pick_none.run(app); wait_drained(app); refresh_now!(app)
            @test all(!l.selected for l in app.snap.databases[id].lines)
            pick_all.run(app); wait_drained(app); refresh_now!(app)
            @test all(l.selected for l in app.snap.databases[id].lines)
            app.ui.current_db = ""
            @test pick_all.enabled(app) == "Import line data first."
        end
    end

    @testset "ui commands" begin
        with_app(test_app_state(nothing)) do app
            cmds = Dict(c.id => c for c in UI.commands(app))
            cmds["ui.command_search"].run(app)
            @test app.ui.search == ""
            @test !cmds["ui.ribbon"].checked(app)
            cmds["ui.ribbon"].run(app)
            @test app.config.ribbon_collapsed && cmds["ui.ribbon"].checked(app)
            cmds["ui.theme.dark"].run(app)
            @test app.tokens === UI.DARK && cmds["ui.theme.dark"].checked(app) && !cmds["ui.theme.light"].checked(app)
            cmds["ui.theme.toggle"].run(app)
            @test app.tokens === UI.LIGHT && app.config.theme == UI.THEME_LIGHT
            wait_drained(app)
            saved, problem = UI.load_config(app.config_dir)
            @test problem === nothing && saved.theme == UI.THEME_LIGHT && saved.ribbon_collapsed
            cmds["ui.theme.system"].run(app)
            @test cmds["ui.theme.system"].checked(app)
            wait_drained(app)
            @test app.tokens === UI.tokens_for(UI.THEME_SYSTEM, UI.system_dark())
        end
    end

    @testset "chords" begin
        @test UI.parse_chord("Ctrl+Shift+Z") == (ctrl = true, shift = true, alt = false, key = :Z)
        @test UI.parse_chord("Ctrl+F1") == (ctrl = true, shift = false, alt = false, key = :F1)
        @test UI.parse_chord("Alt+Left").alt
        @test UI.parse_chord("Escape").key === :Escape
        @test_throws ArgumentError UI.parse_chord("Ctrl+")
        @test_throws ArgumentError UI.parse_chord("Ctrl+Nope")
        @test_throws ArgumentError UI.parse_chord("Ctrl+A+B")
    end

    @testset "shortcut routing" begin
        with_app(test_app_state(nothing)) do app
            cmds = UI.commands(app)
            route(text; modal = false, typing = false) =
                (c = UI.shortcut_command(cmds, UI.parse_chord(text), modal, typing); c === nothing ? nothing : c.id)
            @test route("Ctrl+K") == "ui.command_search"
            @test route("Ctrl+N") == "project.new"
            @test route("Ctrl+O") == "project.open"
            @test route("Ctrl+Z") == "session.undo"
            @test route("Ctrl+Y") == "session.redo"
            @test route("Ctrl+Shift+Z") == "session.redo"
            @test route("Ctrl+Shift+L") == "ui.theme.toggle"
            @test route("Ctrl+F1") == "ui.ribbon"
            @test route("Ctrl+L") === nothing && route("Z") === nothing
            # A modal dialog lets only Ctrl+K and Esc pass.
            @test route("Ctrl+N"; modal = true) === nothing
            @test route("Ctrl+Z"; modal = true) === nothing
            @test route("Ctrl+K"; modal = true) == "ui.command_search"
            @test route("Escape"; modal = true) === nothing   # passes, but no command has it
            # A text field lets only Ctrl chords pass, and never text undo.
            @test route("Ctrl+K"; typing = true) == "ui.command_search"
            @test route("Ctrl+Z"; typing = true) === nothing
            @test route("Ctrl+Y"; typing = true) === nothing
            @test route("Ctrl+Shift+Z"; typing = true) === nothing
            @test route("Ctrl+F1"; typing = true) == "ui.ribbon"
            @test route("Alt+Left"; typing = true) === nothing
        end
    end
end
