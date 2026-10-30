using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Form, open_form, is_drawn, check!, reset!, ToolDialog, OpenToolDialog,
    OpenImport, OpenExport, choice_style, channel_options, number_text, job_args, form_title,
    description_lines, channel_list_text, lines_labels, pair_options, item_options, ResultDialog

# A small XYZ file in a temp folder: 2 lines of 20 rows.
function small_xyz()
    path = joinpath(mktempdir(), "small.xyz")
    write_synthetic_xyz(path; lines = 2, ties = 0, rows_per_line = 20)
    return path
end

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

            # Export: the item is the input; Browse asks for a file to save, named after the item.
            db = app.ui.current_db
            UI.handle_request!(app, OpenExport("export.csv", db))
            wait_drained(app)
            e = top_dialog(app).form
            @test e.owner isa Core.ExporterSpec && e.inputs["item"] == db
            @test !check!(e, app.session) && e.errors["path"] == "Choose a file."
            out = joinpath(mktempdir(), "out.csv")
            app.pick_file = (; kw...) -> (asked[] = values(kw); out)
            UI.browse_path!(app, top_dialog(app))
            @test asked[].save && asked[].extensions == [".csv"] && endswith(asked[].start, db * ".csv")
            @test e.path == out && check!(e, app.session)
        end
    end
end
