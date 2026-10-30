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

fpx_(scale, v) = Float32(v) * Float32(scale)

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
                # The busy button keeps its full accent (it is not greyed).
                @test near(pixel(img, b.x0 + 4, (b.y0 + b.y1) / 2), rgb255(LIGHT.accent); tol = 6)
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
            xyz = small_xyz()
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

    # Run and Cancel stay on the screen and work, however tall the form is (fix round 1).
    function footer_reachable(ctx, app, w, h)
        run, cancel = item_box(D1 * "Run"), item_box(D1 * "Cancel")
        ok = run.y1 <= h && cancel.y1 <= h && run.y0 >= 0
        d = tool_dialog(app)
        d.form.values["expr"] = ""
        empty!(d.buffers)
        ctx.click(D1 * "Run")
        ctx.wait_until(() -> haskey(d.form.errors, "expr"); timeout = 5)
        ctx.click(D1 * "Cancel")
        ctx.frames(2)
        return ok && isempty(app.ui.dialogs)
    end

    @testset "a tall dialog scrolls its body; Run and Cancel stay reachable" begin
        for (size, scale, sfx) in (((900, 560), 1f0, "900x560"), ((1480, 920), 1.5f0, "1.5x"))
            with_project_app(kangaroo(); size, scale) do ctx, app
                UI.request!(app, UI.OpenToolDialog("database.channel_math"; item = app.ui.current_db))
                ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                ctx.frames(2)
                ctx.click(D1 * "Tool Description")
                ctx.frames(3)
                vp = unsafe_load(ig.GetMainViewport())
                b = item_box(D1 * "Run")
                ctx.shot(joinpath(DIALOG_SHOTS, "dialog-tall-$sfx.png"))
                # The dialog is at most the window less 40 px, 20 px from its top and bottom.
                @test b.y1 <= vp.Size.y - fpx_(scale, 20) - fpx_(scale, 12) + 1
                # The body scrolls: the wheel over it moves the Tool Description box.
                te.MouseMove(D1 * "##expr")
                te.MouseWheelY(-5)
                ctx.frames(2)
                ctx.shot(joinpath(DIALOG_SHOTS, "dialog-tall-scrolled-$sfx.png"))
                @test footer_reachable(ctx, app, vp.Size.x, vp.Size.y)
            end
        end
        many = session_with(lines = 3, channels = 300, name = "Wide")
        with_project_app(many) do ctx, app
            UI.request!(app, UI.OpenToolDialog("database.channel_math"; item = app.ui.current_db))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            ctx.frames(3)
            ctx.shot(joinpath(DIALOG_SHOTS, "dialog-300-channels.png"))
            vp = unsafe_load(ig.GetMainViewport())
            @test footer_reachable(ctx, app, vp.Size.x, vp.Size.y)
        end
    end

    @testset "a 300-channel combo fits the window and scrolls to the last channels" begin
        many = session_with(lines = 3, channels = 300, name = "Wide")
        with_project_app(many) do ctx, app
            UI.request!(app, UI.OpenToolDialog("database.statistics"; item = app.ui.current_db))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            d = tool_dialog(app)
            ctx.frames(2)
            ctx.click(D1 * "channel")
            ctx.frames(2)
            m = app.ui.menu
            vp = unsafe_load(ig.GetMainViewport())
            @test m.box.y0 >= 8 && m.box.y1 <= vp.Size.y - 8
            # The wheel scrolls the rows; the last ones come into view and can be picked.
            te.MouseMoveToPos(((m.box.x0 + m.box.x1) / 2, (m.box.y0 + m.box.y1) / 2))
            for _ in 1:40
                te.MouseWheelY(-10)
            end
            ctx.frames(2)
            @test m.scroll > 0
            ctx.shot(joinpath(DIALOG_SHOTS, "dialog-menu-scrolled-light.png"))
            ctx.click(menu_row(app, "C298"))
            ctx.frames(2)
            @test d.form.values["channel"] == "C298" && app.ui.menu === nothing
            # The keyboard keeps the highlighted row in view: Down, then Page Down.
            ctx.click(D1 * "channel")
            ctx.frames(2)
            m = app.ui.menu
            function key_row_in_view()
                inview = Ref(false)
                ctx.on_render(w -> begin
                    vp = unsafe_load(ig.GetMainViewport())
                    l = UI.menu_layout(m.anchor, m.items, UI.Box(0, 0, vp.Size.x, vp.Size.y), w.scale,
                        (t, sz) -> UI.text_width(UI.FONT_REGULAR, sz, t); min_width = m.min_width,
                        gap = m.gap, scroll = m.scroll)
                    r = l.rows[m.key]
                    inview[] = r.y0 >= l.box.y0 && r.y1 <= l.box.y1
                end)
                return inview[]
            end
            for _ in 1:45
                ctx.key("Down")
            end
            ctx.frames(2)
            @test m.key > 40 && key_row_in_view()
            for _ in 1:4
                ctx.key("PageDown")
            end
            ctx.frames(2)
            @test m.key > 100 && key_row_in_view()
            # The mouse takes the highlight over: only one row is lit.
            target = m.items[m.key - 3].label
            te.MouseMove(menu_row(app, target))
            ctx.frames(2)
            @test m.items[m.key].label == target
            ctx.key("Escape")
            ctx.frames(2)
            # The keyboard: End, then Enter picks the last channel.
            ctx.click(D1 * "channel")
            ctx.frames(2)
            ctx.key("End")
            ctx.frames(2)
            ctx.key("Enter")
            ctx.frames(2)
            @test d.form.values["channel"] == "C300" && d in app.ui.dialogs
        end
    end

    @testset "the import's path line is read-only text, not a field" begin
        with_project_app(Core.new_session(joinpath(mktempdir(), "p"), "p")) do ctx, app
            xyz = small_xyz()
            app.pick_file = (; kw...) -> xyz
            UI.request!(app, UI.OpenImport("import.geosoft_xyz"))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            ctx.frames(3)
            @test !te.ItemExists(D1 * "##path")
            d = tool_dialog(app)
            path = joinpath(DIALOG_SHOTS, "dialog-import-path-light.png")
            ctx.shot(path)
            img = PNGFiles.load(path)
            b = d.path_box
            # No input frame: the row's ends are the dialog's own fill.
            @test near(pixel(img, b.x1 - 2, (b.y0 + b.y1) / 2), rgb255(LIGHT.menu); tol = 2)
            @test near(pixel(img, b.x1 - 2, b.y0 + 1), rgb255(LIGHT.menu); tol = 2)
        end
    end

    @testset "a line that comes or goes while typing does not move the dialog" begin
        # A short dialog (the old rule kept a tall one at 20 px anyway), whose settings have
        # no help: an error or a coordinate system name adds a line.
        small = Core.ToolSpec("test.small", "Small", "A small test tool.", "tools", Core.Place[],
            ["database" => Core.ITEM_DATABASE],
            Core.SettingSpec[Core.NumberSetting("n", "Count"; default = 1),
                Core.CRSSetting("crs", "Coordinate system")], :quick, (s, i, st, p, r) -> nothing)
        with_tools([small]) do
            with_project_app(kangaroo()) do ctx, app
                UI.request!(app, UI.OpenToolDialog("test.small"; item = app.ui.current_db))
                ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
                d = tool_dialog(app)
                ctx.frames(4)
                top = item_box(D1 * "Close dialog").y0
                # The name of a code comes from the worker as a new line under the field.
                fill_text(D1 * "##crs", "EPSG:7855")
                ctx.wait_until(() -> haskey(d.crs_names, "EPSG:7855"); timeout = 5)
                ctx.frames(3)
                @test d.hint_boxes["crs"] !== nothing
                @test item_box(D1 * "Close dialog").y0 == top
                # An error line under Count appears after Run: still no move.
                fill_text(D1 * "##n", "x")
                ctx.click(D1 * "Run")
                ctx.wait_until(() -> haskey(d.form.errors, "n"); timeout = 5)
                ctx.frames(3)
                @test item_box(D1 * "Close dialog").y0 == top
                # A drag is kept when the error line goes again (typing clears it).
                te.ItemDragWithDelta(D1 * "##move", Ref(ig.ImVec2(40f0, 30f0)))
                ctx.frames(2)
                moved = item_box(D1 * "Close dialog").y0
                @test moved != top
                fill_text(D1 * "##n", "3")
                ctx.frames(3)
                @test !haskey(d.form.errors, "n") && item_box(D1 * "Close dialog").y0 == moved
                # Opening a section places it again, centred.
                ctx.click(D1 * "Tool Description")
                ctx.frames(4)
                @test item_box(D1 * "Close dialog").y0 != moved
            end
        end
    end

    @testset "the dialog's scrollbar looks like the panes', dark" begin
        with_project_app(kangaroo(); theme = THEME_DARK, size = (900, 560)) do ctx, app
            UI.request!(app, UI.OpenToolDialog("database.channel_math"; item = app.ui.current_db))
            ctx.wait_until(() -> tool_dialog(app) !== nothing; timeout = 5)
            ctx.frames(2)
            ctx.click(D1 * "Tool Description")
            ctx.frames(3)
            te.MouseMoveToPos((5f0, 5f0))
            ctx.frames(2)
            path = joinpath(DIALOG_SHOTS, "dialog-scroll-dark.png")
            ctx.shot(path)
            img = PNGFiles.load(path)
            d = tool_dialog(app)
            right = round(Int, d.ok_box.x1) + 16            # the body's right edge
            top = round(Int, item_box(D1 * "Close dialog").y1) + 12 + 1
            y = top + 10                                    # inside the thumb at scroll 0
            thumb = rgb255(DARK.border_strong)
            @test all(x -> near(pixel(img, x, y), thumb; tol = 3), right-8:right-3)   # 6 px wide
            @test near(pixel(img, right - 9, y), rgb255(DARK.menu); tol = 3)         # no track fill
            @test near(pixel(img, right - 1, y), rgb255(DARK.menu); tol = 3)
            @test near(pixel(img, right - 5, top), rgb255(DARK.menu); tol = 3)       # 2 px from the end
            # The thumb keeps its colour under the mouse, as the panes' thumb does.
            te.MouseMoveToPos((Float32(right - 5), Float32(y)))
            ctx.frames(2)
            ctx.shot(path)
            img = PNGFiles.load(path)
            @test near(pixel(img, right - 5, y), thumb; tol = 3)
            ctx.shot(joinpath(DIALOG_SHOTS, "dialog-scroll-dark.png"))
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
                        wpath = ctx.shot(joinpath(DIALOG_SHOTS, "dialog-widgets-$name.png"))
                        if name == "light"   # the unit's baseline is 16 px under the field's top, as Chromium's
                            img = PNGFiles.load(wpath)
                            fb = item_box(D1 * "##factor")
                            top = round(Int, fb.y0) - 1
                            ux = round(Int, fb.x1) + 14
                            inked(y) = any(x -> sum(pixel(img, x, y)) < 600, ux:ux+14)
                            @test inked(top + 15) && !inked(top + 16)
                        end
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
