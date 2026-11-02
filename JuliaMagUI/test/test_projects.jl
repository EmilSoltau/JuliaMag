using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: AppState, AppConfig, open_project!, new_project!, close_project!, open_last!,
    request_quit!, advance_quit!, project_name_problem, ConfirmDialog, WarningsDialog,
    set_session!, load_config, run_script_file, trim_log!, with_app_log, LOG_MAX_BYTES,
    lock_time_text, rendering_env, temp_folder_report, toggle_tab!, tabs_menu_items,
    commands, ribbon_layout, location, BigButton, SmallColumn, Custom, find_command,
    handle_requests!, CloseProject, OpenBackstage, OpenDialog, GettingStartedDialog,
    GETTING_STARTED, recent_after_open

# An app with no project, its settings in a temp folder.
empty_app() = test_app_state(nothing)

"""
    pump!(app, pred; timeout = 20)

Do what the render loop does between frames for the project lifecycle (worker results,
requests, a pending quit) until `pred()` holds. An error after `timeout` s.
"""
function pump!(app::AppState, pred; timeout::Real = 20)
    deadline = time() + timeout
    while true
        UI.drain!(app)
        handle_requests!(app)
        advance_quit!(app)
        pred() && return nothing
        time() > deadline && error("pump!: the condition did not hold within $timeout s")
        timedwait(() -> isready(app.queue.results), 0.05; pollint = 0.002)
    end
end

# A new project folder with one database, closed again. Returns its folder.
function project_folder(name::AbstractString = "p")
    s = session_with(project = name)
    folder = s.project.folder
    Core.close_session!(s)
    return folder
end

# Press the primary button of the top dialog.
press_ok!(app) = (d = last(app.ui.dialogs); press_ok!(app, d))
press_ok!(app, d::ConfirmDialog) = (filter!(x -> x !== d, app.ui.dialogs); d.on_yes(app))
press_ok!(app, d::WarningsDialog) = UI.finish_warnings!(app, d)

# The texts of the toasts of `app`.
toast_texts(app) = [t.text for t in app.toasts]

@testset "projects" begin
    @testset "a project name must be a folder name" begin
        @test project_name_problem("Survey 2024") === nothing
        @test project_name_problem("") == "Type a name."
        @test project_name_problem("   ") == "Type a name."
        for bad in ("a/b", "a\\b", "a:b", "a*b", "a?b", "a\"b", "a<b", "a>b", "a|b")
            @test project_name_problem(bad) ==
                  "A folder name cannot have any of these characters: < > : \" / \\ | ? *"
        end
        @test project_name_problem("..") == "Type a name."
    end

    @testset "new_project! refuses a/b and makes no folder" begin
        with_app(empty_app()) do app
            parent = mktempdir()
            @test new_project!(app, parent, "a/b") ==
                  "A folder name cannot have any of these characters: < > : \" / \\ | ? *"
            wait_drained(app)
            @test app.session === nothing && isempty(readdir(parent))
        end
    end

    @testset "new_project! makes the project, opens it and remembers it" begin
        with_app(empty_app()) do app
            parent = mktempdir()
            app.ui.backstage = true
            @test new_project!(app, parent, "Survey 2024") === nothing
            pump!(app, () -> app.session !== nothing)
            s = app.session
            @test s.project.name == "Survey 2024"
            @test realpath(s.project.folder) == realpath(joinpath(parent, "Survey 2024"))
            @test isfile(joinpath(parent, "Survey 2024", "project.jmag.json"))
            @test app.config.recent == [realpath(joinpath(parent, "Survey 2024"))]
            @test !app.ui.backstage && app.switching === nothing
            wait_drained(app)
            @test load_config(app.config_dir)[1].recent == app.config.recent
        end
    end

    @testset "new_project! never writes over a project that is there" begin
        with_app(empty_app()) do app
            folder = project_folder("Old")
            @test new_project!(app, dirname(folder), basename(folder)) === nothing
            pump!(app, () -> app.switching === nothing && app.queue.pending == 0)
            @test app.session === nothing
            @test "There is a project in this folder already. Open it from the Open page." in toast_texts(app)
            @test Core.open_project(folder).name == "Old"   # still the old project
        end
    end

    @testset "open_project! of a folder without a project gives the plain message" begin
        with_app(empty_app()) do app
            folder = mktempdir()
            open_project!(app, folder)
            @test app.switching == "Opening $(basename(folder))..."
            pump!(app, () -> app.switching === nothing)
            @test app.session === nothing
            @test toast_texts(app) == ["This folder has no JuliaMag project."]
            @test isempty(app.config.recent)
        end
    end

    @testset "open_project! of a missing folder keeps it in the recent list" begin
        with_app(empty_app()) do app
            gone = joinpath(mktempdir(), "gone")
            push!(app.config.recent, gone)
            open_project!(app, gone)
            pump!(app, () -> app.switching === nothing)
            @test app.session === nothing
            @test toast_texts(app) == ["The folder $gone was not found."]
            @test app.config.recent == [gone]
            @test app.ui.bs.recent[gone].found == false
        end
    end

    @testset "open_project! of a broken project gives the core's message" begin
        with_app(empty_app()) do app
            folder = mktempdir()
            write(joinpath(folder, "project.jmag.json"), "{ not json")
            open_project!(app, folder)
            pump!(app, () -> app.switching === nothing)
            @test app.session === nothing
            @test occursin("is broken", only(toast_texts(app)))
        end
    end

    @testset "the recent list after opening three projects, newest first" begin
        with_app(empty_app()) do app
            folders = [project_folder("P$k") for k in 1:3]
            for f in folders
                open_project!(app, f)
                pump!(app, () -> app.session !== nothing && app.session.project.folder == f &&
                                 app.switching === nothing)
            end
            @test app.config.recent == realpath.(reverse(folders))
            open_project!(app, folders[1])   # opening one again moves it to the front
            pump!(app, () -> app.session !== nothing && app.session.project.folder == folders[1] &&
                             app.switching === nothing)
            @test app.config.recent == realpath.(folders[[1, 3, 2]])
            # The project opened before is closed: its lock is free again.
            s = Core.open_session(folders[2])
            Core.close_session!(s)
            wait_drained(app)
            @test load_config(app.config_dir)[1].recent == app.config.recent
        end
    end

    @testset "recent_after_open keeps 10 and has no copies" begin
        list = ["/p$k" for k in 1:10]
        @test recent_after_open(list, "/p5") == ["/p5"; ["/p$k" for k in 1:10 if k != 5]]
        @test recent_after_open(list, "/new") == ["/new"; ["/p$k" for k in 1:9]]
    end

    @testset "open_project! sets the current database to the first one" begin
        with_app(empty_app()) do app
            folder = project_folder()
            open_project!(app, folder)
            pump!(app, () -> app.session !== nothing)
            refresh_now!(app)
            UI.sync_current_db!(app)
            @test app.ui.current_db == only(app.snap.items).id
            # Another spelling of the open folder is the open project (T15-P4).
            @test UI.is_open_project(app, folder * "/")
            @test UI.is_open_project(app, joinpath(folder, "x", ".."))
            Sys.iswindows() && @test UI.is_open_project(app, uppercase(folder))
            @test !UI.is_open_project(app, folder * "-other")
        end
    end

    @testset "open_last opens the last project when the setting is on" begin
        folder = project_folder("Last")
        with_app(empty_app()) do app
            app.config.recent = [realpath(folder)]
            open_last!(app)
            wait_drained(app)
            @test app.session === nothing   # the setting is off
            app.config.open_last = true
            open_last!(app)
            pump!(app, () -> app.session !== nothing)
            @test app.session.project.name == "Last"
        end
        with_app(empty_app()) do app   # a last project that is gone: nothing happens
            app.config.open_last = true
            app.config.recent = [joinpath(mktempdir(), "gone")]
            open_last!(app)
            wait_drained(app)
            @test app.session === nothing && isempty(app.toasts)
        end
    end

    @testset "a project locked by another session: Open Anyway opens it" begin
        folder = project_folder("Locked")
        other = Core.open_session(folder)
        try
            locked = try
                Core.open_session(folder)
                nothing
            catch e
                e
            end
            @test locked isa Core.ProjectLockedError
            with_app(empty_app()) do app
                open_project!(app, folder)
                pump!(app, () -> !isempty(app.ui.dialogs))
                d = only(app.ui.dialogs)
                @test d isa ConfirmDialog && d.danger && d.action == "Open Anyway"
                @test d.title == "This project is open somewhere else"
                @test d.text == "$(locked.user) on $(locked.host) opened it at $(lock_time_text(locked.started))."
                @test app.session === nothing && app.switching === nothing
                press_ok!(app)
                pump!(app, () -> app.session !== nothing)
                @test app.session.project.name == "Locked"
                s = app.session
                set_session!(app, nothing)
                Core.close_session!(s)
            end
        finally
            Core.close_session!(other)
        end
    end

    @testset "a recent folder that was not found says so after one space" begin
        @test UI.recent_path_text("/data/p", true) == "/data/p"
        @test UI.recent_path_text("/data/p", false) == "/data/p (folder not found)"
    end

    @testset "a close that fails is toasted and goes to the log file" begin
        dir = mktempdir()
        with_test_session(session_with(project = "Closing")) do s
        with_app(test_app_state(s)) do app
            next = Ref(false)
            with_app_log(dir; console = Base.CoreLogging.NullLogger()) do
                UI.closed!(app, s, 0, UI.CloseResult(String[], Core.ProjectError("the disk is full")),
                    a -> (next[] = true))
            end
            @test app.session === nothing && next[]
            @test last(app.toasts).kind == :error && last(app.toasts).text == "The disk is full."
            @test occursin("The project did not close cleanly", read(joinpath(dir, UI.LOG_FILE), String))
        end
        end
    end

    @testset "lock_time_text" begin
        @test lock_time_text("2026-10-31T09:15:02+0000"; offset = 0) == "09:15 on 31 October 2026"
        @test lock_time_text("2026-10-31T23:15:02Z"; offset = 3600) == "00:15 on 1 November 2026"
        @test lock_time_text("not a time") == "not a time"
        # Older locks: an offset, or on Windows the zone's name (read as the local clock).
        @test lock_time_text("2026-10-31T09:15:02+0100"; offset = 0) == "08:15 on 31 October 2026"
        @test lock_time_text("2026-10-31T09:15:02W. Europe Standard Time"; offset = 7200) ==
              "09:15 on 31 October 2026"
        @test lock_time_text(Core.now_text(1_793_438_102.0); offset = -18000) == "04:15 on 31 October 2026"
    end

    @testset "close_project! closes, then runs `then`" begin
        with_app(empty_app()) do app
            s = session_with()
            set_session!(app, s)
            done = Ref(0)
            close_project!(app; then = a -> (done[] += 1; nothing))
            @test app.switching == "Closing..."
            pump!(app, () -> done[] == 1)
            @test app.session === nothing && !isopen(s) && app.switching === nothing
        end
    end

    @testset "close warnings show in a dialog before `then` runs" begin
        with_app(empty_app()) do app
            s = session_with()
            fail = () -> error("the disk is full")
            Core.push_undo!(s, Core.UndoStep("test step", () -> nothing, () -> nothing,
                () -> nothing, String[]; commit = fail))
            set_session!(app, s)
            done = Ref(0)
            close_project!(app; then = a -> (done[] += 1; nothing))
            pump!(app, () -> !isempty(app.ui.dialogs))
            d = only(app.ui.dialogs)
            @test d isa WarningsDialog && d.title == "Closing the project gave these warnings"
            @test length(d.lines) == 1 && occursin("the disk is full", only(d.lines))
            @test done[] == 0 && app.session === nothing
            press_ok!(app)
            @test done[] == 1 && isempty(app.ui.dialogs)
        end
    end

    @testset "close_project! with a running job asks first" begin
        with_tools([gate_tool(Channel{Int}(10))]) do
            with_app(empty_app()) do app
                s = session_with()
                set_session!(app, s)
                job = Core.run_tool(s, "test.gate")
                refresh_now!(app)
                closed = Ref(false)
                close_project!(app; then = a -> (closed[] = true; nothing))
                d = only(app.ui.dialogs)
                @test d isa ConfirmDialog && d.text == "1 job is running. Cancel it and close?"
                @test d.action == "Close Project" && app.switching === nothing
                filter!(x -> x !== d, app.ui.dialogs)   # Cancel: nothing happens
                d.on_no(app)
                @test isopen(s) && !closed[]
                close_project!(app; then = a -> (closed[] = true; nothing))
                press_ok!(app)
                pump!(app, () -> closed[])
                @test !isopen(s) && Core.status(job) == Core.JOB_CANCELLED
            end
        end
    end

    @testset "the CloseProject request closes the project" begin
        with_app(empty_app()) do app
            s = session_with()
            set_session!(app, s)
            UI.run_command!(app, "project.close")
            @test app.ui.requests == Any[CloseProject()]
            pump!(app, () -> app.session === nothing && app.switching === nothing)
            @test !isopen(s)
        end
    end

    @testset "OpenBackstage and OpenDialog requests" begin
        with_app(empty_app()) do app
            UI.run_command!(app, "project.open")
            handle_requests!(app)
            @test app.ui.backstage && app.ui.backstage_page === :open
            UI.request!(app, OpenDialog(:about))
            handle_requests!(app)
            @test app.ui.backstage && app.ui.backstage_page === :about
            app.ui.backstage = false
            UI.request!(app, OpenDialog(:getting_started))
            handle_requests!(app)
            @test only(app.ui.dialogs) isa GettingStartedDialog
            UI.request!(app, OpenDialog(:getting_started))   # not twice
            handle_requests!(app)
            @test length(app.ui.dialogs) == 1
        end
    end

    @testset "a quit waits for the close and survives a project switch (T9-P1)" begin
        with_app(empty_app()) do app
            quits = Ref(0)
            app.quit_hook = a -> (quits[] += 1; nothing)
            s1 = session_with(project = "One")
            set_session!(app, s1)
            # An open of another project is under way when the user closes the window.
            folder = project_folder("Two")
            open_project!(app, folder)
            @test request_quit!(app) == false
            @test app.quit_pending
            pump!(app, () -> quits[] == 1)
            @test app.session === nothing && !isopen(s1)
            @test !app.quit_pending
            # Two was opened and closed again on the way out: its lock is free.
            s2 = Core.open_session(folder)
            Core.close_session!(s2)
        end
    end

    @testset "a quit without a project calls the quit hook at once" begin
        with_app(empty_app()) do app
            quits = Ref(0)
            app.quit_hook = a -> (quits[] += 1; nothing)
            push!(app.ui.dialogs, GettingStartedDialog())   # dialogs do not hold up a quit
            @test request_quit!(app) == false
            advance_quit!(app)
            @test quits[] == 1 && isempty(app.ui.dialogs)
        end
    end

    @testset "Cancel on the running-jobs question cancels the quit" begin
        with_tools([gate_tool(Channel{Int}(10))]) do
            with_app(empty_app()) do app
                quits = Ref(0)
                app.quit_hook = a -> (quits[] += 1; nothing)
                s = session_with()
                set_session!(app, s)
                Core.run_tool(s, "test.gate")
                refresh_now!(app)
                request_quit!(app)
                advance_quit!(app)
                d = only(app.ui.dialogs)
                @test d isa ConfirmDialog
                filter!(x -> x !== d, app.ui.dialogs)
                d.on_no(app)
                @test !app.quit_pending
                advance_quit!(app)
                @test quits[] == 0 && isopen(s)
            end
        end
    end

    @testset "run_script_file runs a script in a module of its own and returns its output" begin
        dir = mktempdir()
        ok = joinpath(dir, "ok.jl")
        write(ok, """
            x = 21
            println("x is ", 2x)
            print(stderr, "to stderr")
            @info "a log line"
            """)
        out_before = stdout
        r = run_script_file(ok)
        @test r.error === nothing
        @test occursin("x is 42", r.output) && occursin("to stderr", r.output)
        @test occursin("a log line", r.output)
        @test stdout === out_before
        @test !isdefined(Main, :x) || Main.x != 21

        bad = joinpath(dir, "bad.jl")
        write(bad, "println(\"before\")\nerror(\"the script broke\")\n")
        r = run_script_file(bad)
        @test stdout === out_before
        @test occursin("before", r.output)
        @test r.error !== nothing && occursin("the script broke", r.error)

        # A script that prints more than a pipe holds does not hang.
        big = joinpath(dir, "big.jl")
        write(big, "for k in 1:20_000; println(\"line \", k); end\n")
        r = run_script_file(big)
        @test r.error === nothing && occursin("line 20000", r.output)
    end

    @testset "run_script_file can use JuliaMagCore" begin
        folder = project_folder("Script")
        id = only(Core.open_project(folder).items).id
        path = joinpath(mktempdir(), "rename.jl")
        write(path, """
            using JuliaMagCore
            s = open_session($(repr(folder)))
            try
                rename_item!(s, $(repr(id)), "Renamed")
                println("renamed")
            finally
                close_session!(s)
            end
            """)
        r = run_script_file(path)
        @test r.error === nothing && occursin("renamed", r.output)
        @test only(Core.open_project(folder).items).name == "Renamed"
    end

    @testset "run_script_file closes a project the script left open" begin
        folder = project_folder("Left")
        path = joinpath(mktempdir(), "left.jl")
        write(path, """
            using JuliaMagCore
            s = open_session($(repr(folder)))
            error("the script broke before close_session!")
            """)
        r = run_script_file(path)
        @test r.error !== nothing && occursin("the script broke", r.error)
        @test occursin("The script left the project in $folder open. JuliaMag closed it.", r.output)
        # The lock is gone: the project opens without "open somewhere else" (final review M4).
        s = Core.open_session(folder)
        @test isempty(Core.warnings(s))
        Core.close_session!(s)
    end

    @testset "the log file: cut to the last 1 MB at start, errors go in" begin
        dir = mktempdir()
        path = joinpath(dir, "juliamag.log")
        write(path, repeat("old line\n", 200_000))   # 1.8 MB
        trim_log!(path)
        @test filesize(path) <= LOG_MAX_BYTES
        @test startswith(read(path, String), "old line\n")   # cut at a line start
        small = joinpath(dir, "small.log")
        write(small, "short\n")
        trim_log!(small)
        @test read(small, String) == "short\n"
        trim_log!(joinpath(dir, "none.log"))   # no file: nothing to do
        @test !isfile(joinpath(dir, "none.log"))

        with_app_log(dir; console = devnull) do
            @error "the frame broke" code = 7
            @warn "a warning"
            @info "an info line"
        end
        text = read(path, String)
        @test occursin("the frame broke", text) && occursin("code = 7", text)
        @test occursin("a warning", text)
        @test !occursin("an info line", text)
        # Tasks started inside take the same logger.
        with_app_log(dir; console = devnull) do
            wait(Threads.@spawn @error "from a worker task")
        end
        @test occursin("from a worker task", read(path, String))
    end

    @testset "software rendering takes effect at the next start" begin
        c = AppConfig()
        @test rendering_env(c) == Pair{String,String}[]
        c.software_rendering = true
        @test rendering_env(c) == (Sys.iswindows() ? Pair{String,String}[] :
                                   ["LIBGL_ALWAYS_SOFTWARE" => "1"])
    end

    @testset "temp_folder_report" begin
        dir = mktempdir()
        r = temp_folder_report(dir)
        @test r.free > 0 && occursin("free", r.text)
        @test isempty(readdir(dir))   # the write test leaves nothing
        @test_throws ArgumentError temp_folder_report(joinpath(dir, "gone"))
    end

    @testset "Show Tabs: a hidden tab is saved; Settings and Help stay" begin
        with_app(empty_app()) do app
            all_items = tabs_menu_items(app)
            @test first(all_items).head && first(all_items).label == "Tabs"
            items = filter(it -> !it.head, all_items)
            labels = [it.label for it in items]
            @test labels == ["Database", "Database Tools", "Coordinates", "Grid and Image",
                "Settings", "Help"]
            @test all(it -> it.checked === true && it.stay, items)
            @test items[end].reason !== nothing && items[end-1].reason !== nothing
            toggle_tab!(app, "Coordinates")
            @test app.config.hidden_tabs == ["Coordinates"]
            @test !(filter(it -> !it.head, tabs_menu_items(app))[3].checked)
            @test !("Coordinates" in UI.tab_order(commands(app), app.config.hidden_tabs))
            toggle_tab!(app, "Help")   # cannot be hidden
            @test app.config.hidden_tabs == ["Coordinates"]
            wait_drained(app)
            @test load_config(app.config_dir)[1].hidden_tabs == ["Coordinates"]
            toggle_tab!(app, "Coordinates")
            @test isempty(app.config.hidden_tabs)
        end
    end

    @testset "the Settings and Help ribbons as the prototype" begin
        with_app(empty_app()) do app
            cmds = commands(app)
            byid = Dict(c.id => c for c in cmds)
            groups = ribbon_layout(cmds, "Settings")
            @test [g.name for g in groups] == ["Theme", "Defaults", "Startup", "Rendering", "Ribbon"]
            @test [byid[b.cmd_id].label for b in groups[1].items] == ["Light", "Dark", "System"]
            @test groups[2].items == [Custom(:defaults), SmallColumn(["settings.temp_folder"])]
            @test groups[3].items == [SmallColumn(["settings.open_last"])]
            @test byid["settings.open_last"].label == "Open Last Project"
            @test groups[4].items == [BigButton("settings.software")]
            @test byid["settings.software"].label == "Software\nRendering"
            @test groups[5].items == [Custom(:tabs_menu)]
            help = ribbon_layout(cmds, "Help")
            @test [g.name for g in help] == ["Help", "About"]
            @test [byid[b.cmd_id].label for b in help[1].items] ==
                  ["Command\nSearch", "Getting\nStarted", "Keyboard\nShortcuts"]
            @test [byid[b.cmd_id].label for b in help[2].items] == ["All Tools", "About"]
        end
    end

    @testset "shell commands have the prototype's location" begin
        with_app(empty_app()) do app
            loc(id) = location(find_command(app, id))
            @test loc("project.backstage") == "Project"
            @test loc("project.new") == "Project" && loc("project.open") == "Project"
            @test loc("project.close") == "Project" && loc("project.run_script") == "Project"
            @test loc("session.undo") == "Quick Access" && loc("session.redo") == "Quick Access"
            @test loc("ui.theme.toggle") == "Quick Access"
            @test loc("ui.ribbon") == "Window" && loc("ui.jobs_pane") == "Panes"
            @test loc("ui.theme.dark") == "Settings > Theme"
            @test find_command(app, "project.run_script").changes_project
            for id in ("settings.open_last", "settings.software", "settings.temp_folder")
                @test !find_command(app, id).changes_project
            end
        end
    end

    @testset "Settings toggles change and save the settings" begin
        with_app(empty_app()) do app
            UI.run_command!(app, "settings.open_last")
            @test app.config.open_last
            UI.run_command!(app, "settings.software")
            @test app.config.software_rendering
            @test any(t -> t.text == "Takes effect the next time JuliaMag starts.", app.toasts)
            UI.set_distance_units!(app, "km")
            UI.set_grid_colours!(app, "viridis")
            wait_drained(app)
            c = load_config(app.config_dir)[1]
            @test c.open_last && c.software_rendering
            @test c.distance_units == "km" && c.grid_colours == "viridis"
            @test "viridis" in first.(Core.colour_tables())
            # Nothing draws grids yet: the toast does not claim an effect (final review M1).
            @test any(t -> t.text == "Saved: Viridis for grids." &&
                           t.sub == "Grid views use it once JuliaMag has them.", app.toasts)
        end
    end

    @testset "Getting Started lists the processing chain" begin
        @test [s.name for s in GETTING_STARTED] == ["Import", "Check the data", "Lag correction",
            "Heading correction", "Base station correction", "Levelling", "IGRF removal",
            "Gridding", "Filters", "Reduction to pole"]
        @test count(s -> s.now, GETTING_STARTED) == 3
    end

    # --- Fix round 1 (task-15-review.md, ruling T15-R1) ---

    @testset "a quit cancels a pending `then`: the next project never opens" begin
        with_app(empty_app()) do app
            quits = Ref(0)
            app.quit_hook = a -> (quits[] += 1; nothing)
            set_session!(app, session_with(project = "One"))
            other = project_folder("Two")
            open_project!(app, other)          # closes One, then would open Two
            @test app.switching == "Closing..."
            request_quit!(app)
            pump!(app, () -> quits[] == 1)
            @test app.session === nothing && isempty(app.config.recent)
            s2 = Core.open_session(other)      # Two was never opened: its lock is free
            Core.close_session!(s2)
        end
    end

    @testset "closing the window while a script runs asks, and Quit ends the app" begin
        with_app(empty_app()) do app
            quits = Ref(0)
            app.quit_hook = a -> (quits[] += 1; nothing)
            flag = joinpath(mktempdir(), "go")
            script = joinpath(mktempdir(), "wait.jl")
            write(script, "while !isfile($(repr(flag))); sleep(0.02); end\nprintln(\"done\")\n")
            UI.run_script!(app, script)
            @test app.switching == "Running wait.jl..."
            request_quit!(app)
            advance_quit!(app)
            d = only(app.ui.dialogs)
            @test d isa ConfirmDialog && d.text == "A script is still running. Quit anyway?"
            @test d.action == "Quit" && quits[] == 0
            press_ok!(app)
            @test quits[] == 1 && !app.quit_pending
            touch(flag)                         # let the script end, so the worker can stop
            pump!(app, () -> app.switching === nothing)
            advance_quit!(app)
            @test quits[] == 1                  # not a second time
        end
        with_app(empty_app()) do app            # Cancel: the script goes on, no quit
            quits = Ref(0)
            app.quit_hook = a -> (quits[] += 1; nothing)
            flag = joinpath(mktempdir(), "go")
            script = joinpath(mktempdir(), "wait.jl")
            write(script, "while !isfile($(repr(flag))); sleep(0.02); end\n")
            UI.run_script!(app, script)
            request_quit!(app)
            d = only(app.ui.dialogs)
            filter!(x -> x !== d, app.ui.dialogs)
            d.on_no(app)
            @test !app.quit_pending
            touch(flag)
            pump!(app, () -> app.switching === nothing)
            advance_quit!(app)
            @test quits[] == 0
        end
    end

    @testset "a script that ends while the quit question is open: Cancel opens the project again" begin
        folder = project_folder("Reopen")
        with_app(empty_app()) do app
            quits = Ref(0)
            app.quit_hook = a -> (quits[] += 1; nothing)
            open_project!(app, folder)
            pump!(app, () -> (UI.refresh!(app); app.snap !== nothing && app.switching === nothing))
            flag = joinpath(mktempdir(), "go")
            script = joinpath(mktempdir(), "wait.jl")
            write(script, "while !isfile($(repr(flag))); sleep(0.02); end\n")
            UI.run_script!(app, script)
            pump!(app, () -> app.session === nothing && app.ui.bs.running)
            request_quit!(app)
            d = only(app.ui.dialogs)
            touch(flag)                         # the script ends while the question is open
            pump!(app, () -> !app.ui.bs.running)
            @test app.session === nothing && only(app.ui.dialogs) === d
            filter!(x -> x !== d, app.ui.dialogs)
            d.on_no(app)                        # Cancel: no quit, the project opens again
            pump!(app, () -> app.session !== nothing && app.switching === nothing)
            @test !app.quit_pending && quits[] == 0
            @test app.session.project.folder == folder && app.ui.bs.reopen === nothing
        end
    end

    @testset "lock text when the core cannot read the lock" begin
        with_app(empty_app()) do app
            e = Core.ProjectLockedError("/p", "a computer not known yet", "another program",
                "2026-10-31T09:15:02+0000", "The lock file was kept as project.lock.old.")
            UI.opened!(app, "/p", nothing, e; stay = false)
            d = only(app.ui.dialogs)
            @test startswith(d.text, "Another program on a computer not known yet opened it at ")
            @test endswith(d.text, ". The lock file was kept as project.lock.old.")
        end
    end

    @testset "New Project refuses a folder that is not empty" begin
        with_app(empty_app()) do app
            parent = mktempdir()
            mkpath(joinpath(parent, "Busy"))
            write(joinpath(parent, "Busy", "notes.txt"), "mine")
            @test new_project!(app, parent, "Busy") === nothing
            pump!(app, () -> app.switching === nothing && app.queue.pending == 0)
            @test app.session === nothing
            @test toast_texts(app) == ["The folder $(joinpath(parent, "Busy")) is not empty. Pick another name, or an empty folder."]
            @test readdir(joinpath(parent, "Busy")) == ["notes.txt"]
            mkpath(joinpath(parent, "Empty"))   # an empty folder is fine
            @test new_project!(app, parent, "Empty") === nothing
            pump!(app, () -> app.session !== nothing)
            @test app.session.project.name == "Empty"
        end
    end

    @testset "New Project refuses Windows reserved names and a dot or space at the end" begin
        reserved = "Windows keeps this name for itself. Pick another name."
        for bad in ("CON", "con", "Nul", "PRN.txt", "aux.survey", "COM1", "com9", "LPT1", "lpt9.x")
            @test project_name_problem(bad) == reserved
        end
        for ok in ("CONSOLE", "COM10", "LPT", "Nulla", "con-2024")
            @test project_name_problem(ok) === nothing
        end
        ends = "A folder name cannot end with a dot or a space."
        @test project_name_problem("Survey.") == ends
        @test project_name_problem("Survey ") == ends
        @test project_name_problem(" Survey") === nothing
    end

    @testset "log trim never starts inside a UTF-8 character" begin
        dir = mktempdir()
        path = joinpath(dir, "juliamag.log")
        write(path, repeat("é✓", 300_000))     # 1.5 MB of 2 and 3 byte characters, no newline
        trim_log!(path)
        text = read(path, String)
        @test filesize(path) <= LOG_MAX_BYTES && isvalid(text) && !isempty(text)
        @test startswith(text, "é") || startswith(text, "✓")
    end

    @testset "a script that prints 200,000 lines keeps the last 10,000" begin
        path = joinpath(mktempdir(), "chatty.jl")
        write(path, "for k in 1:200_000; println(\"line \", k); end\n")
        r = run_script_file(path)
        lines = split(rstrip(r.output, '\n'), '\n')
        @test length(lines) == UI.OUTPUT_MAX_LINES + 1
        @test first(lines) == "Earlier output was cut."
        @test lines[2] == "line 190001" && last(lines) == "line 200000"
        @test sizeof(r.output) < 200_000
        # The page splits the output once, not in every frame.
        with_app(empty_app()) do app
            UI.script_done!(app, r, nothing)
            bs = app.ui.bs
            @test length(bs.output_lines) == UI.OUTPUT_MAX_LINES + 1 && bs.output_errors == 0
            UI.script_done!(app, UI.ScriptRun("a\nb\n", "Error in x.jl, line 2: boom"), nothing)
            @test bs.output_lines == ["a", "b", "Error in x.jl, line 2: boom"] && bs.output_errors == 1
        end
    end

    @testset "Browse to the project that is open only leaves the backstage" begin
        with_app(empty_app()) do app
            folder = project_folder("Here")
            open_project!(app, folder)
            pump!(app, () -> app.session !== nothing)
            s = app.session
            app.ui.backstage = true
            open_project!(app, folder)
            @test app.switching === nothing && app.session === s && isopen(s)
            @test !app.ui.backstage
        end
    end

    @testset "the System theme is read again when the window gets the focus" begin
        with_app(empty_app()) do app
            app.config.theme = UI.THEME_SYSTEM
            UI.note_focus!(app, false)
            @test app.queue.pending == 0
            UI.note_focus!(app, true)
            @test app.queue.pending == 1        # the OS theme is read on the worker
            UI.note_focus!(app, true)
            @test app.queue.pending == 1        # only when the focus comes back
            wait_drained(app)
            app.config.theme = UI.THEME_LIGHT
            UI.note_focus!(app, false); UI.note_focus!(app, true)
            @test app.queue.pending == 0        # not for a fixed theme
        end
    end

    @testset "temp_folder_report: a folder that cannot be written" begin
        dir = mktempdir()
        chmod(dir, 0o555)
        try
            writable = try
                p, io = mktemp(dir); close(io); rm(p); true
            catch
                false
            end
            if writable   # root, or a system without these permissions
                @test_skip "this user can write in a read-only folder"
            else
                err = try
                    temp_folder_report(dir); nothing
                catch e
                    e
                end
                @test err isa ArgumentError && err.msg == "JuliaMag cannot write in the folder $dir."
            end
        finally
            chmod(dir, 0o755)
        end
    end
end

@testset "the command line: a project folder argument" begin
    @test UI.command_line(String[]) == (nothing, nothing)
    @test UI.command_line([""]) == (nothing, nothing)
    @test UI.command_line(["/data/Survey 2024"]) == (abspath("/data/Survey 2024"), nothing)
    @test UI.command_line(["Survey"]) == (joinpath(pwd(), "Survey"), nothing)
    # An unquoted folder name with a space: no project, and a plain sentence.
    project, problem = UI.command_line(["my", "project"])
    @test project === nothing
    @test problem == "JuliaMag takes one project folder, but it got 2 arguments. " *
                     "Put quotes around a folder name with spaces."
end

@testset "opening a file instead of a folder says so" begin
    file = joinpath(mktempdir(), "survey.xyz")
    write(file, "/ X Y\n")
    r = UI.open_on_worker(file, false, nothing)
    @test r isa UI.OpenFailure && r.text == "$file is a file, not a project folder." && !r.missing
end

@testset "one worker thread: a warning toast and a log line" begin
    with_app(empty_app()) do app
        UI.warn_threads!(app, 2)
        @test isempty(app.toasts)
        @test_logs (:warn, UI.ONE_THREAD_TEXT) UI.warn_threads!(app, 1)
        t = only(app.toasts)
        @test t.kind == :warn
        @test t.text == "JuliaMag runs with one worker thread. Start it with -t auto for faster jobs."
    end
end

@testset "toasts made before the first frame start their time then" begin
    t = UI.Toast(:warn, "early"; born = 100.0)
    UI.restart_toast_clocks!([t], 103.5)
    @test t.born == 103.5 && t.shown == 103.5
    @test !UI.toast_expired(t, 103.5 + 4.1) && UI.toast_expired(t, 103.5 + 4.2)
end

@testset "Close on the backstage nav says why it cannot be used" begin
    with_app(empty_app()) do app
        @test UI.close_nav_reason(app) == "Open a project first."
        app.switching = "Opening Survey..."
        @test UI.close_nav_reason(app) == "Wait until the project has opened or closed."
    end
    with_app(test_app_state(session_with())) do app
        @test UI.close_nav_reason(app) === nothing
        app.switching = "Closing..."
        @test UI.close_nav_reason(app) == "Wait until the project has opened or closed."
        app.switching = nothing
    end
end
