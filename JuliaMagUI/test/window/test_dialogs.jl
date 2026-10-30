using Test
import CImGui as ig
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK, ToolDialog, ResultDialog

const DIALOG_SHOTS = joinpath(@__DIR__, "..", "shots")

const D1 = "//###dialog1/"

# Click a text field, select its text and type `text` (no Enter, which would press the
# primary button).
fill_text(ref, text) = (te.ItemClick(ref); te.KeyCharsReplace(text); nothing)

# The test engine reference of a row of the open menu.
menu_row(app, label) = "//" * app.ui.menu.ref * "/" * label

# The pixel at device point (x, y) of a PNG, as 0-255 RGB.
pixel(img, x, y) = rgb255(img[round(Int, y)+1, round(Int, x)+1])

# A small XYZ file in a temp folder: 2 lines of 20 rows.
function dialog_xyz()
    path = joinpath(mktempdir(), "small.xyz")
    write_synthetic_xyz(path; lines = 2, ties = 0, rows_per_line = 20)
    return path
end

tool_dialog(app) = (d = isempty(app.ui.dialogs) ? nothing : last(app.ui.dialogs); d isa ToolDialog ? d : nothing)

# The box of an item in device pixels, read through the test engine.
function item_box(ref)
    info = te.ItemInfo(ref)
    r = info.RectFull
    return UI.Box(r.Min.x, r.Min.y, r.Max.x, r.Max.y)
end

# A dialog with a multi-line and a one-line text field; its primary button counts presses.
struct MultiLineDialog
    buf::Vector{UInt8}
    single::Vector{UInt8}
    pressed::Base.RefValue{Int}
end
MultiLineDialog(buf, pressed) = MultiLineDialog(buf, zeros(UInt8, 64), pressed)
function UI.draw_modal(app, d::MultiLineDialog)
    UI.draw_dialog(app, d; title = "Notes", on_ok = () -> (d.pressed[] += 1; nothing)) do
        ig.InputTextMultiline("##notes", d.buf, length(d.buf), (300f0, 80f0))
        ig.InputText("##single", d.single, length(d.single))
    end
end

window_testset("tool dialogs") do
    mkpath(DIALOG_SHOTS)

    @testset "Channel Math from the ribbon runs as a job; the channel shows in the tree" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.click("JuliaMag/tabs/Database Tools")
            ctx.click("JuliaMag/ribbon/Channel Math")
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            d = tool_dialog(app)
            @test d.form.owner.id == "database.channel_math" && d.form.inputs["database"] == app.ui.current_db
            ctx.frames(2)
            fill_text(D1 * "##expr", "C3 = C1 * 2")
            ctx.click(D1 * "Run")
            ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
            @test any(t -> t.text == "Channel Math started.", app.toasts)
            @test app.ui.left_tab == :jobs
            job = only(Core.jobs(app.session))
            ctx.wait_until(() -> Core.status(job) != Core.JOB_RUNNING; timeout = 20)
            @test Core.status(job) == Core.JOB_DONE
            db = app.ui.current_db
            ctx.wait_until(() -> any(c -> c.name == "C3", app.snap.databases[db].channels); timeout = 10)
            ctx.click("JuliaMag/left/Data")
            push!(app.ui.expanded, "databases", db, "$db/channels")
            ctx.frames(3)
            @test te.ItemExists(tree_ref("$db/channels/C3"))
        end
    end

    @testset "a blank expression: a red error under the field, nothing runs" begin
        with_project_app(kangaroo()) do ctx, app
            UI.request!(app, UI.OpenToolDialog("database.channel_math"; item = app.ui.current_db))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            d = tool_dialog(app)
            d.form.values["expr"] = ""
            empty!(d.buffers)
            ctx.frames(2)
            ctx.click(D1 * "Run")
            ctx.wait_until(() -> !isempty(d.form.errors); timeout = 5)
            ctx.frames(2)
            @test d in app.ui.dialogs && isempty(Core.jobs(app.session))
            @test d.form.errors["expr"] == "Expression is empty."
            path = joinpath(DIALOG_SHOTS, "dialog-cm-error-light.png")
            ctx.shot(path)
            img = PNGFiles.load(path)
            b = item_box(D1 * "##expr")
            # The field's frame is red: the left edge of the frame, 7 px left of the text box.
            @test near(pixel(img, b.x0 - 8, (b.y0 + b.y1) / 2), rgb255(LIGHT.red); tol = 40)
            @test d.hint_boxes["expr"] !== nothing
            hb = d.hint_boxes["expr"]
            red = count(y -> any(x -> near(pixel(img, x, y), rgb255(LIGHT.red); tol = 60),
                hb.x0:hb.x0+120), hb.y0:hb.y1-1)
            @test red > 3
        end
    end

    @testset "Statistics (quick) shows its report; the tree's channel entry preselects it" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            push!(app.ui.expanded, "databases", db, "$db/channels")
            ctx.frames(3)
            right_click(tree_ref("$db/channels/IGRF"))
            ctx.frames(1)
            ctx.click("//###menu/Statistics...")
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            d = tool_dialog(app)
            @test d.form.values["channel"] == "IGRF" && d.form.inputs["database"] == db
            ctx.click(D1 * "Run")
            ctx.wait_until(() -> !isempty(app.ui.dialogs) && last(app.ui.dialogs) isa ResultDialog; timeout = 10)
            @test occursin("IGRF", last(app.ui.dialogs).text)
        end
    end

    @testset "a quick tool that sleeps 2 s: the loop keeps drawing and shows a spinner" begin
        with_tools([sleep_tool(2)]) do
            with_project_app(kangaroo()) do ctx, app
                UI.request!(app, UI.OpenToolDialog("test.sleep"; item = app.ui.current_db))
                ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                d = tool_dialog(app)
                ctx.frames(2)
                ctx.click(D1 * "Run")
                ctx.wait_until(() -> d.running; timeout = 5)
                f0, t0 = ctx.window.frame, time()
                ctx.frames(2)
                path = joinpath(DIALOG_SHOTS, "dialog-spinner-light.png")
                ctx.shot(path)
                ctx.wait_until(() -> !d.running; timeout = 10)
                fps = (ctx.window.frame - f0) / (time() - t0)
                @test fps > 20
                @test !(d in app.ui.dialogs)
                @test app.toasts[end].text == "Slept." && app.toasts[end].kind == :ok
                # The spinner: accent on the primary button became a ring of on-accent pixels.
                img = PNGFiles.load(path)
                b = d.ok_box
                white = count(p -> near(rgb255(p), rgb255(LIGHT.on_accent); tol = 40),
                    img[round(Int, b.y0)+1:round(Int, b.y1), round(Int, b.x0)+1:round(Int, b.x1)])
                @test white > 10
            end
        end
    end

    @testset "Reset to Defaults and the Advanced section" begin
        with_project_app(kangaroo(); config_dir = mktempdir()) do ctx, app
            id = "database.statistics"
            UI.request!(app, UI.OpenToolDialog(id; item = app.ui.current_db))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            d = tool_dialog(app)
            @test !(id in app.config.advanced_open)
            @test !te.ItemExists(D1 * "##bins")
            ctx.click(D1 * "Advanced")
            ctx.frames(2)
            @test id in app.config.advanced_open && te.ItemExists(D1 * "##bins")
            fill_text(D1 * "##bins", "12")
            ctx.frames(1)
            @test d.form.texts["bins"] == "12"
            ctx.click(D1 * "Reset to Defaults")
            ctx.wait_until(() -> any(t -> t.text == "Settings reset to their defaults.", app.toasts); timeout = 5)
            ctx.frames(2)
            @test d.form.texts["bins"] == "64" && d.form.values["bins"] === 64
            # Close Advanced; an error in bins opens it again and focuses the field.
            ctx.click(D1 * "Advanced")
            ctx.frames(2)
            @test !(id in app.config.advanced_open)
            d.form.texts["bins"] = "lots"
            ctx.click(D1 * "Run")
            ctx.wait_until(() -> haskey(d.form.errors, "bins"); timeout = 5)
            ctx.frames(3)
            @test id in app.config.advanced_open && te.ItemExists(D1 * "##bins")
            @test d.form.errors["bins"] == "Type a number."
            ctx.wait_until(() -> isfile(joinpath(app.config_dir, "settings.json")); timeout = 5)
        end
    end

    @testset "combos and checklists open over the dialog; Esc closes only the menu" begin
        with_tools([every_setting_tool()]) do
            with_project_app(kangaroo_data()) do ctx, app
                UI.request!(app, UI.OpenToolDialog("test.every_setting"; item = app.ui.current_db))
                ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                d = tool_dialog(app)
                ctx.frames(2)
                ctx.click(D1 * "table")
                ctx.frames(2)
                @test app.ui.menu !== nothing
                ctx.click(menu_row(app, "Grey"))
                ctx.frames(2)
                @test d.form.values["table"] == "grey" && app.ui.menu === nothing
                ctx.click(D1 * "table")
                ctx.frames(2)
                ctx.key("Escape")
                ctx.frames(2)
                @test app.ui.menu === nothing && d in app.ui.dialogs
                # The checklist: None, then two channels, then All.
                ctx.click(D1 * "channels")
                ctx.frames(2)
                ctx.click(menu_row(app, "None"))
                ctx.frames(1)
                @test app.ui.menu !== nothing   # a checklist stays open
                ctx.click(menu_row(app, "MAG"))
                ctx.click(menu_row(app, "IGRF"))
                ctx.frames(1)
                @test d.form.values["channels"] == ["MAG", "IGRF"]
                ctx.click(menu_row(app, "All"))
                ctx.frames(1)
                @test d.form.values["channels"] == String[]
                ctx.key("Escape")
                ctx.frames(2)
                @test app.ui.menu === nothing && d in app.ui.dialogs
                # A segment, a checkbox and a chip.
                ctx.click(D1 * "method/linear")
                ctx.click(D1 * "protect")
                ctx.frames(1)
                @test d.form.values["method"] == "linear" && d.form.values["protect"] == false
                fill_text(D1 * "##expr", "OUT = ")
                ctx.click(D1 * "expr/IGRF")
                ctx.frames(2)
                @test d.form.values["expr"] == "OUT = IGRF"
                # The coordinate system name comes from the worker, 300 ms after typing stops.
                fill_text(D1 * "##crs", "EPSG:7844")
                ctx.wait_until(() -> get(d.crs_names, "EPSG:7844", nothing) !== nothing; timeout = 5)
                @test d.crs_names["EPSG:7844"] == "GDA2020"
                fill_text(D1 * "##crs", "nonsense")
                ctx.wait_until(() -> haskey(d.crs_names, "nonsense"); timeout = 5)
                @test d.crs_names["nonsense"] == ""
            end
        end
    end

    @testset "Enter in a multi-line field does not press the primary button" begin
        with_project_app(kangaroo()) do ctx, app
            buf = zeros(UInt8, 256)
            pressed = Ref(0)
            UI.push_dialog!(app, MultiLineDialog(buf, pressed))
            ctx.frames(2)
            te.ItemClick(D1 * "##notes")
            te.KeyChars("one")
            te.KeyPress(ig.lib.ImGuiKey_Enter)
            te.KeyChars("two")
            ctx.frames(2)
            @test pressed[] == 0 && UI.field_text(buf) == "one\ntwo"
            # Enter in a one-line field still presses it.
            te.ItemClick(D1 * "##single")
            te.KeyPress(ig.lib.ImGuiKey_Enter)
            ctx.frames(2)
            @test pressed[] == 1
        end
    end

    @testset "no caret over selected text, as in Chromium" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.on_render(w -> (io = Ptr{ig.lib.ImGuiIO}(ig.GetIO()); io.ConfigInputTextCursorBlink = false))
            UI.request!(app, UI.OpenToolDialog("database.channel_math"; item = app.ui.current_db))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            ctx.frames(2)
            fill_text(D1 * "##expr", "MAG")
            ctx.frames(2)
            b = item_box(D1 * "##expr")
            tw = Ref(0f0)
            ctx.on_render(w -> (tw[] = UI.text_width(UI.FONT_MONO, 12, "MAG")))
            x = round(Int, b.x0 + tw[])   # the caret's column, after the text
            mid = (b.y0 + b.y1) / 2
            caret_dark(path) = (img = PNGFiles.load(path);
                any(dx -> near(pixel(img, x + dx, mid), rgb255(LIGHT.text); tol = 60), 0:1))
            path = joinpath(DIALOG_SHOTS, "dialog-caret-light.png")
            ctx.shot(path)
            @test caret_dark(path)            # the caret shows after typing
            ctx.key("Ctrl+A")
            ctx.frames(2)
            ctx.shot(path)
            @test !caret_dark(path)           # and hides while the text is selected
            img = PNGFiles.load(path)
            @test near(pixel(img, b.x0 + 2, mid), rgb255(LIGHT.text_selection); tol = 30)
        end
    end

    @testset "import an XYZ file through the dialog, then run it again with replace" begin
        with_project_app(Core.new_session(joinpath(mktempdir(), "p"), "p")) do ctx, app
            xyz = dialog_xyz()
            app.pick_file = (; kw...) -> xyz
            ctx.click("JuliaMag/ribbon/More import formats")
            ctx.frames(1)
            ctx.click("//###menu/Geosoft XYZ...")
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            d = tool_dialog(app)
            @test d.form.path == xyz && d.file_size == filesize(xyz)
            ctx.frames(2)
            path = joinpath(DIALOG_SHOTS, "dialog-import-light.png")
            ctx.shot(path)
            ctx.click(D1 * "Import")
            ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
            job = only(Core.jobs(app.session))
            ctx.wait_until(() -> Core.status(job) != Core.JOB_RUNNING; timeout = 30)
            @test Core.status(job) == Core.JOB_DONE
            ctx.wait_until(() -> length(app.snap.databases) == 1; timeout = 10)

            # Run Again with replace: still one database.
            UI.open_form(app, Core.importer_for(xyz); args = job.args, rerun_of = job)
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            d = tool_dialog(app)
            @test d.form.source == :rerun && d.form.path == xyz
            ctx.frames(2)
            ctx.click(D1 * "replace")
            ctx.frames(1)
            @test d.form.replace
            ctx.click(D1 * "Import")
            ctx.wait_until(() -> length(Core.jobs(app.session)) == 2; timeout = 10)
            again = first(Core.jobs(app.session))
            ctx.wait_until(() -> Core.status(again) != Core.JOB_RUNNING; timeout = 30)
            @test Core.status(again) == Core.JOB_DONE
            ctx.wait_until(() -> app.snap.revision == Core.revision(app.session); timeout = 10)
            @test count(it -> it.kind == Core.ITEM_DATABASE, app.snap.items) == 1
        end
    end

    @testset "export to a temp folder writes the file" begin
        with_project_app(kangaroo()) do ctx, app
            out = joinpath(mktempdir(), "kangaroo.csv")
            app.pick_file = (; kw...) -> out
            UI.request!(app, UI.OpenExport("export.csv", app.ui.current_db))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            ctx.frames(2)
            ctx.click(D1 * "path/Browse...")
            ctx.frames(1)
            @test tool_dialog(app).form.path == out
            ctx.click(D1 * "Export")
            ctx.wait_until(() -> isempty(app.ui.dialogs); timeout = 10)
            job = only(Core.jobs(app.session))
            ctx.wait_until(() -> Core.status(job) != Core.JOB_RUNNING; timeout = 30)
            @test Core.status(job) == Core.JOB_DONE && isfile(out) && filesize(out) > 0
        end
    end

    @testset "shots: Channel Math, Import, every widget, light and dark" begin
        with_tools([every_setting_tool()]) do
            for (theme, tokens, name) in ((THEME_LIGHT, LIGHT, "light"), (THEME_DARK, DARK, "dark"))
                for scale in (1f0, 1.5f0)
                    sfx = scale == 1 ? "" : "-1.5x"
                    with_project_app(kangaroo_data(); theme, scale) do ctx, app
                        app.ui.left_tab = :data
                        UI.request!(app, UI.OpenToolDialog("database.channel_math"; item = app.ui.current_db))
                        ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                        ctx.frames(3)
                        te.MouseMoveToPos((5f0, 5f0))
                        ctx.frames(2)
                        ctx.shot(joinpath(DIALOG_SHOTS, "dialog-cm-$name$sfx.png"))
                        scale == 1 || return
                        ctx.click(D1 * "Tool Description")
                        te.MouseMoveToPos((5f0, 5f0))
                        ctx.frames(2)
                        ctx.shot(joinpath(DIALOG_SHOTS, "dialog-cm-desc-$name.png"))
                        ctx.key("Escape")
                        ctx.frames(2)
                        # Channel Math has no advanced settings in the core; Statistics has.
                        UI.request!(app, UI.OpenToolDialog("database.statistics"; item = app.ui.current_db))
                        ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                        ctx.frames(2)
                        ctx.click(D1 * "Advanced")
                        te.MouseMoveToPos((5f0, 5f0))
                        ctx.frames(2)
                        ctx.shot(joinpath(DIALOG_SHOTS, "dialog-stats-adv-$name.png"))
                        ctx.click(D1 * "Advanced")
                        ctx.key("Escape")
                        ctx.frames(2)
                        UI.request!(app, UI.OpenToolDialog("test.every_setting"; item = app.ui.current_db))
                        ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                        ctx.frames(3)
                        te.MouseMoveToPos((5f0, 5f0))
                        ctx.frames(2)
                        ctx.shot(joinpath(DIALOG_SHOTS, "dialog-widgets-$name.png"))
                        ctx.click(D1 * "table")
                        ctx.frames(2)
                        ctx.shot(joinpath(DIALOG_SHOTS, "dialog-widgets-combo-$name.png"))
                        ctx.key("Escape")
                        ctx.click(D1 * "channels")
                        ctx.frames(2)
                        ctx.shot(joinpath(DIALOG_SHOTS, "dialog-widgets-checklist-$name.png"))
                        ctx.key("Escape")
                        ctx.key("Escape")
                        ctx.frames(2)
                        app.pick_file = (; kw...) -> (p = joinpath(mktempdir(), "KH2024_infill_F18.xyz");
                            write_synthetic_xyz(p; lines = 2, ties = 0, rows_per_line = 20); p)
                        UI.request!(app, UI.OpenImport("import.geosoft_xyz"))
                        ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                        ctx.frames(3)
                        te.MouseMoveToPos((5f0, 5f0))
                        ctx.frames(2)
                        ctx.shot(joinpath(DIALOG_SHOTS, "dialog-xyz-$name.png"))
                    end
                end
            end
        end
    end
end
