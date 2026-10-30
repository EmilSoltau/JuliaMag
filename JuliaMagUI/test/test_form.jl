using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Form, open_form, is_drawn, check!, reset!, ToolDialog, OpenToolDialog,
    OpenImport, OpenExport, choice_style, channel_options, number_text, job_args, form_title,
    description_lines, channel_list_text, lines_labels, pair_options, item_options, ResultDialog,
    ConfirmDialog, menu_layout, MenuItem, Box

top_dialog(app) = last(app.ui.dialogs)

@testset "Tool forms" begin
    @testset "the brief" begin
        with_app(app_with_database()) do app
            f = open_form_now(app, Core.tool("database.channel_math"))
            @test f.inputs["database"] == app.ui.current_db && f.source == :defaults
            f.values["expr"] = ""
            @test !check!(f, app.session) && haskey(f.errors, "expr")
            imp = open_form_now(app, Core.importer_for("a.xyz"); path = small_xyz())
            imp.values["mode"] = "new"
            @test !is_drawn(imp, "target")
            imp.values["mode"] = "append"
            @test is_drawn(imp, "target")
            f2 = open_form_now(app, Core.tool("database.statistics"))
            f2.texts["bins"] = "12."
            @test check!(f2, app.session)                                  # "12." parses as 12
            @test f2.values["bins"] === 12
        end
    end

    @testset "opening: inputs, channels, preset values, the dialog" begin
        with_app(app_with_database()) do app
            db = app.ui.current_db
            f = open_form_now(app, Core.tool("database.statistics"))
            d = top_dialog(app)
            @test d isa ToolDialog && d.form === f
            @test f.owner.id == "database.statistics" && f.path == "" && !f.replace && f.rerun_of === nothing
            # An empty channel setting takes the first channel of the input database.
            @test f.values["channel"] == "MAG" && f.values["lines"] == "all"
            @test f.texts["bins"] == "64" && isempty(f.errors)
            @test is_drawn(f, "bins") && !is_drawn(f, "nope")
            # The request of a channel's "Statistics..." names the channel.
            UI.handle_request!(app, OpenToolDialog("database.statistics"; item = db,
                values = Dict{String,Any}("channel" => "MAGP")))
            wait_drained(app)
            g = top_dialog(app).form
            @test g.values["channel"] == "MAGP" && g.inputs["database"] == db
            @test form_title(g) == "Statistics" && form_title(f) == "Statistics"
        end
    end

    @testset "checking: numbers, core problems, inputs" begin
        with_app(app_with_database()) do app
            f = open_form_now(app, Core.tool("database.statistics"))
            f.texts["bins"] = "abc"
            @test !check!(f, app.session) && f.errors["bins"] == "Type a number."
            f.texts["bins"] = "0"
            @test !check!(f, app.session) && f.errors["bins"] == "Histogram bins must be at least 1."
            f.texts["bins"] = " 1e2 "
            @test check!(f, app.session) && f.values["bins"] === 100 && isempty(f.errors)
            f.inputs["database"] = ""
            @test !check!(f, app.session) && haskey(f.errors, "database")
        end
    end

    @testset "remembered settings and reset" begin
        with_app(app_with_database()) do app
            db = app.ui.current_db
            ok, _, _ = Core.run_tool(app.session, "database.statistics"; inputs = Dict("database" => db),
                channel = "MAGP", bins = 7)
            @test ok
            f = open_form_now(app, Core.tool("database.statistics"))
            @test f.source == :remembered && f.values["bins"] === 7 && f.texts["bins"] == "7"
            @test f.values["channel"] == "MAGP"
            f.errors["bins"] = "Type a number."
            reset!(app, f)
            wait_drained(app)
            @test f.values["bins"] === 64 && f.texts["bins"] == "64" && f.values["channel"] == "MAG"
            @test f.inputs["database"] == db && isempty(f.errors) && f.source == :defaults
            @test app.toasts[end].text == "Settings reset to their defaults."
            # The project forgot them, so the next open starts from the defaults.
            g = open_form_now(app, Core.tool("database.statistics"))
            @test g.source == :defaults && g.values["bins"] === 64
        end
    end

    @testset "widget rules" begin
        method = Core.ChoiceSetting("method", "Method", ["near", "linear"]; labels = ["Nearest", "Linear"])
        @test choice_style(method) == :segmented
        # "Append to existing" has 18 characters: the XYZ import's mode is a combo.
        @test choice_style(only(st for st in Core.importer_for("a.xyz").settings if st.key == "mode")) == :combo
        four = Core.ChoiceSetting("f", "Format", ["a", "b", "c", "d"])
        @test choice_style(four) == :combo
        long = Core.ChoiceSetting("l", "Long", ["a", "b"]; labels = ["Fourteen chars", "b"])
        @test choice_style(long) == :combo
        @test number_text(nothing) == "" && number_text(64) == "64" && number_text(25.0) == "25" &&
              number_text(0.1) == "0.1" && number_text(-2.5e-7) == "-2.5e-7"
        @test channel_list_text(String[], 5) == "All channels" &&
              channel_list_text(["A", "B"], 5) == "2 channels" && channel_list_text(["A"], 5) == "1 channel"

        s = kangaroo_data()
        try
            snap = UI.snapshot(s)
            db = only(keys(snap.databases))
            v = snap.databases[db]
            st = Core.ChannelSetting("ch", "Channel"; roles = [Core.ROLE_LON])
            names = first.(channel_options(st, v))
            @test names[1] == "LON" && length(names) == 9 && Set(names) == Set(c.name for c in v.channels)
            @test last(channel_options(st, v)[1]) == "longitude, deg"
            @test lines_labels(v) == ["All (60)", "Selected (60)", "Current"]
            @test pair_options(v) == ["" => "Current pair", "X,Y" => "X, Y", "LON,LAT" => "LON, LAT"]
            @test item_options(snap, Core.ITEM_GRID, true)[1] == ("" => "None")
            @test length(item_options(snap, Core.ITEM_GRID, false)) == 2
        finally
            Core.close_session!(s)
        end
    end

    @testset "the description: settings and the script call" begin
        with_app(app_with_database()) do app
            f = open_form_now(app, Core.tool("database.statistics"))
            args = job_args(f)
            @test args["channel"] == "MAG" && args["inputs"] == Dict{String,Any}("database" => app.ui.current_db)
            text = join((join(first.(l)) for l in description_lines(f)), "\n")
            @test occursin("database.statistics", text)
            @test occursin("ChannelSetting(\"channel\"", text) && occursin("NumberSetting(\"bins\"", text)
            @test occursin("run_tool(s, \"database.statistics\"", text)
            imp = open_form_now(app, Core.importer_for("a.xyz"); path = "/data/small.xyz")
            @test job_args(imp)["path"] == "/data/small.xyz"
            @test occursin("import_file(s, \"/data/small.xyz\"", join((join(first.(l)) for l in description_lines(imp)), "\n"))
            @test form_title(imp) == "Import Geosoft XYZ"
        end
    end

    @testset "a quick tool through the dialog: its report" begin
        with_app(app_with_database()) do app
            open_form_now(app, Core.tool("database.statistics"))
            d = top_dialog(app)
            UI.press_ok!(app, d)
            @test d.running
            wait_drained(app)
            @test !(d in app.ui.dialogs) && !d.running
            r = top_dialog(app)
            @test r isa ResultDialog && occursin("MAG", r.text)
        end
    end

    @testset "a job tool through the dialog: the toast and the Jobs tab" begin
        with_app(app_with_database()) do app
            f = open_form_now(app, Core.tool("database.channel_math"))
            f.values["expr"] = "MAG2 = MAG * 2"
            UI.press_ok!(app, top_dialog(app))
            wait_drained(app)
            @test isempty(app.ui.dialogs)
            t = app.toasts[end]
            @test t.text == "Channel Math started." && t.kind == :info &&
                  t.sub == "It runs in the background. Progress is in the Jobs pane." && t.ms == 2600
            @test app.ui.left_tab == :jobs && app.ui.jobs_shown
            job = only(Core.jobs(app.session))
            Core.wait_job(job)
            @test Core.status(job) == Core.JOB_DONE
            # Only once per session: a second run leaves the left pane alone.
            app.ui.left_tab = :data
            f = open_form_now(app, Core.tool("database.channel_math"))
            f.values["expr"] = "MAG3 = MAG * 3"
            UI.press_ok!(app, top_dialog(app))
            wait_drained(app)
            @test app.ui.left_tab == :data
            foreach(Core.wait_job, Core.jobs(app.session))
        end
    end

    @testset "problems keep the dialog open and open Advanced" begin
        with_app(app_with_database()) do app
            id = "database.statistics"
            filter!(!=(id), app.config.advanced_open)
            f = open_form_now(app, Core.tool(id))
            f.texts["bins"] = "many"
            d = top_dialog(app)
            UI.press_ok!(app, d)
            wait_drained(app)
            @test d in app.ui.dialogs && !d.running
            @test f.errors == Dict("bins" => "Type a number.")
            @test id in app.config.advanced_open && d.focus == "bins"
        end
    end

    @testset "import and export requests" begin
        with_app(app_with_database()) do app
            xyz = small_xyz()
            asked = Ref{Any}(nothing)
            app.pick_file = (; kw...) -> (asked[] = values(kw); xyz)
            UI.handle_request!(app, OpenImport("import.geosoft_xyz"))
            wait_drained(app)
            @test asked[].save == false && asked[].title == "Import Geosoft XYZ" &&
                  asked[].extensions == [".xyz"]
            f = top_dialog(app).form
            @test f.owner isa Core.ImporterSpec && f.path == xyz && top_dialog(app).file_size == filesize(xyz)
            @test app.config.last_folder == dirname(xyz)
            pop!(app.ui.dialogs)

            # A cancelled pick opens nothing; a broken native dialog is an error toast.
            app.pick_file = (; kw...) -> ""
            UI.handle_request!(app, OpenImport("import.geosoft_xyz"))
            wait_drained(app)
            @test isempty(app.ui.dialogs)
            app.pick_file = (; kw...) -> error("GTK is missing")
            UI.handle_request!(app, OpenImport("import.geosoft_xyz"))
            wait_drained(app)
            @test isempty(app.ui.dialogs)
            @test app.toasts[end].kind == :error && occursin("GTK is missing", app.toasts[end].text)

            # Export: the item is the input; Browse asks for a file to save, named after the
            # item (its name, not its id).
            db = app.ui.current_db
            Core.rename_item!(app.session, db, "Survey A")
            refresh_now!(app)
            UI.handle_request!(app, OpenExport("export.csv", db))
            wait_drained(app)
            e = top_dialog(app).form
            @test e.owner isa Core.ExporterSpec && e.inputs["item"] == db
            @test !check!(e, app.session) && e.errors["path"] == "Choose a file."
            out = joinpath(mktempdir(), "out.csv")
            app.pick_file = (; kw...) -> (asked[] = values(kw); out)
            UI.browse_path!(app, top_dialog(app))
            @test asked[].save && asked[].extensions == [".csv"] && basename(asked[].start) == "Survey A.csv"
            @test e.path == out && check!(e, app.session)
        end
    end

    @testset "fix round 1: hidden settings stay out of the args and the script" begin
        with_app(app_with_database()) do app
            imp = open_form_now(app, Core.importer_for("a.xyz"); path = "/data/small.xyz")
            imp.values["mode"] = "new"
            imp.values["target"] = app.ui.current_db
            @test job_args(imp)["target"] == ""
            text = join((join(first.(l)) for l in description_lines(imp)), "\n")
            @test !occursin("target = \"$(app.ui.current_db)\"", text)
            imp.values["mode"] = "append"
            @test job_args(imp)["target"] == app.ui.current_db
        end
    end

    @testset "fix round 1: extents read as typed; an error focuses the first field" begin
        with_tools([every_setting_tool()]) do
            with_app(app_with_database()) do app
                f = open_form_now(app, Core.tool("test.every_setting"))
                d = top_dialog(app)
                UI.set_part_text!(f, Core.ExtentSetting("area", "Area"), 3, "30")
                @test f.values["area"] == [1.0, 2.0, 30.0, 4.0]
                UI.set_part_text!(f, Core.ExtentSetting("area", "Area"), 1, "")
                @test f.values["area"] == [1.0, 2.0, 30.0, 4.0]   # not complete: kept until it is
                UI.finish_ok!(app, d, Dict("area" => "Type a number."), nothing)
                @test d.focus == "area_1"
            end
        end
    end

    @testset "fix round 1: a quick run that is cancelled ends as a toast" begin
        lines2 = Core.ToolSpec("test.two_lines", "Two lines", "", "tools", Core.Place[],
            ["database" => Core.ITEM_DATABASE], Core.SettingSpec[], :quick,
            (s, i, st, p, r) -> (sleep(0.3); println(r, "one"); println(r, "two"); nothing))
        with_tools([sleep_tool(0.3), lines2]) do
            with_app(app_with_database()) do app
                # One line: an ok toast after Cancel.
                open_form_now(app, Core.tool("test.sleep"))
                d = top_dialog(app)
                UI.press_ok!(app, d)
                UI.cancel_dialog!(app, d)
                @test isempty(app.ui.dialogs)
                wait_drained(app)
                @test app.toasts[end].text == "Slept." && app.toasts[end].kind == :ok
                @test isempty(app.ui.dialogs)
                # More lines: a toast whose Show opens the report.
                open_form_now(app, Core.tool("test.two_lines"))
                d = top_dialog(app)
                UI.press_ok!(app, d)
                UI.cancel_dialog!(app, d)
                wait_drained(app)
                t = app.toasts[end]
                @test t.text == "Two Lines is done." && first(only(t.actions)) == "Show"
                last(only(t.actions))(app)
                @test only(app.ui.dialogs) isa ResultDialog && only(app.ui.dialogs).text == "one\ntwo"
                empty!(app.ui.dialogs)
                # The project closes during the run: the result is dropped quietly.
                open_form_now(app, Core.tool("test.sleep"))
                d = top_dialog(app)
                n = length(app.toasts)
                UI.press_ok!(app, d)
                Core.close_session!(app.session)
                wait_drained(app)
                @test length(app.toasts) == n
            end
        end
    end

    @testset "fix round 1: a failed quick run keeps the dialog and the edits" begin
        fails = Core.ToolSpec("test.fails", "Fails", "", "tools", Core.Place[],
            ["database" => Core.ITEM_DATABASE], Core.SettingSpec[Core.TextSetting("note", "Note")], :quick,
            (s, i, st, p, r) -> throw(Core.ToolError("The note is wrong.")))
        with_tools([fails]) do
            with_app(app_with_database()) do app
                f = open_form_now(app, Core.tool("test.fails"))
                f.values["note"] = "my edit"
                d = top_dialog(app)
                UI.press_ok!(app, d)
                wait_drained(app)
                @test top_dialog(app) === d && f.values["note"] == "my edit" && !d.running
                @test app.toasts[end].kind == :error && app.toasts[end].text == "The note is wrong."
            end
        end
    end

    @testset "fix round 1: an import runs only the dialog's importer" begin
        with_app(app_with_database()) do app
            csv = joinpath(mktempdir(), "small.csv")
            write(csv, "X,Y\n1,2\n")
            app.pick_file = (; kw...) -> csv
            UI.handle_request!(app, OpenImport("import.geosoft_xyz"))
            wait_drained(app)
            @test isempty(app.ui.dialogs)
            @test app.toasts[end].kind == :error &&
                  app.toasts[end].text == "small.csv is not a Geosoft XYZ file. Pick a .xyz file."
            # A run again with such a path is refused by the check too.
            imp = open_form_now(app, Core.importer_for("a.xyz"); path = csv)
            @test !check!(imp, app.session) && imp.errors["path"] == "small.csv is not a Geosoft XYZ file. Pick a .xyz file."
        end
    end

    @testset "fix round 1: export adds the extension and asks before replacing" begin
        with_app(app_with_database()) do app
            db = app.ui.current_db
            dir = mktempdir()
            UI.handle_request!(app, OpenExport("export.csv", db))
            wait_drained(app)
            d = top_dialog(app)
            app.pick_file = (; kw...) -> joinpath(dir, "out")
            UI.browse_path!(app, d)
            @test d.form.path == joinpath(dir, "out.csv")
            # A typed path gets it too, before the file is looked for.
            write(joinpath(dir, "typed.csv"), "old")
            d.form.path = joinpath(dir, "typed")
            UI.press_ok!(app, d)
            wait_drained(app)
            @test d.form.path == joinpath(dir, "typed.csv")
            c = top_dialog(app)
            @test c isa ConfirmDialog && c.title == "Replace typed.csv?" && c.action == "Replace"
            @test isempty(Core.jobs(app.session))
            c.on_yes(app)
            pop!(app.ui.dialogs)
            wait_drained(app)
            @test !(d in app.ui.dialogs)
            job = only(Core.jobs(app.session))
            Core.wait_job(job)
            @test Core.status(job) == Core.JOB_DONE && read(joinpath(dir, "typed.csv"), String) != "old"
        end
    end

    @testset "fix round 1: the default channel; one open at a time" begin
        with_app(app_with_database()) do app
            db = app.ui.current_db
            app.ui.selected = (:channel, db, "MAGP")
            f = open_form_now(app, Core.tool("database.statistics"))
            @test f.values["channel"] == "MAGP"
            empty!(app.ui.dialogs)
            app.ui.selected = (:channel, "db-99", "MAGP")   # another database: not used
            f = open_form_now(app, Core.tool("database.statistics"))
            @test f.values["channel"] == "MAG"
            empty!(app.ui.dialogs)
            # A second open before the worker answers opens nothing more.
            UI.open_form(app, Core.tool("database.statistics"))
            UI.open_form(app, Core.tool("database.statistics"))
            wait_drained(app)
            @test length(app.ui.dialogs) == 1
            empty!(app.ui.dialogs)
            UI.open_form(app, Core.tool("database.statistics"))
            wait_drained(app)
            @test length(app.ui.dialogs) == 1
        end
    end

    @testset "fix round 1: a long menu fits the window and scrolls" begin
        items = [MenuItem("C$k") for k in 1:300]
        view = Box(0, 0, 1480, 920)
        l = menu_layout(Box(100, 100, 300, 124), items, view, 1, (t, s) -> 7f0 * length(t))
        @test l.box.y0 >= 8 && l.box.y1 <= 912 && UI.height(l.box) == 920 - 16
        @test l.scroll_max == 2 + 8 + 300 * 24 - UI.height(l.box)
        l2 = menu_layout(Box(100, 100, 300, 124), items, view, 1, (t, s) -> 7f0 * length(t); scroll = 1e6)
        @test l2.scroll == l2.scroll_max && l2.rows[end].y1 <= l2.box.y1 - 5
        l3 = menu_layout(Box(100, 100, 300, 124), items[1:3], view, 1, (t, s) -> 7f0 * length(t); scroll = 50)
        @test l3.scroll == 0 && l3.scroll_max == 0
    end
end
