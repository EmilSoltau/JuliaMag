using Test
import CImGui as ig
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK

const DATA_SHOTS = joinpath(@__DIR__, "..", "shots")

# A right click on `ref` 100 px from the window's left, where the prototype shots click.
function right_click_at_100(ref)
    te.MouseMove(ref)
    y = unsafe_load(ig.GetIO()).MousePos.y
    te.MouseMoveToPos((100f0, Float32(y)))
    te.MouseClick(1)
    return nothing
end

# Dialogs that break inside `draw_app`, past the guard of a dialog body (`run_body`):
# in the footer of a modal, in a child window, in a popup.
struct BreakInFooter end
struct BreakInChild end
struct BreakInPopup end
function UI.draw_modal(app, d::BreakInFooter)
    UI.draw_dialog(app, d; title = "Breaks", on_ok = () -> nothing,
        footer_left = () -> error("the footer broke")) do
        UI.paragraph(app, "A footer that breaks.")
    end
end
function UI.draw_modal(app, ::BreakInChild)
    ig.BeginChild("breaking child", (200f0, 100f0))
    ig.PushID("deep")
    error("the child broke")
end
function UI.draw_modal(app, ::BreakInPopup)
    ig.IsPopupOpen("breaking popup") || ig.OpenPopup("breaking popup")
    if ig.BeginPopup("breaking popup")
        ig.BeginGroup()
        error("the popup broke")
    end
end

# How many popups ImGui has open now.
function popups_open(ctx)
    n = Ref(-1)
    ctx.on_render(w -> (n[] = unsafe_load(Ptr{ig.lib.ImGuiContext}(ig.GetCurrentContext()).OpenPopupStack).Size))
    return n[]
end

"Put `text` into the text field `ref` without pressing Enter (which would press OK)."
fill_field(ref, text) = (te.ItemClick(ref); te.KeyCharsReplace(text); nothing)

# The lines of database `db` in the app's snapshot, by name.
line_selected(app, db, name) = only(l for l in app.snap.databases[db].lines if l.name == name).selected

# The height of the tree at 1480 x 920 with no Properties panel: the pane body less the
# filter box. The tree shows at most this many rows (one more when cut at both ends).
function tree_view_rows(scale = 1)
    body = 920 - sum(UI.px(scale, h) for h in (UI.HEADER_H, UI.TABS_H, UI.RIBBON_H, UI.STATUS_H, UI.PANE_HEAD_H))
    view = body - (UI.hairline(scale) + UI.fpx(scale, UI.FOOT_H))
    return ceil(Int, view / UI.fpx(scale, UI.TREE_ROW_H))
end

# The open tree with a channel selected, the context menus, and the dialogs, at scale 1.
function more_shots(ctx, app, name)
    db = app.ui.current_db
    # Open everything for a second shot, with a channel selected.
    union!(app.ui.expanded, [db, "$db/channels"])
    ctx.frames(2)
    ctx.click(tree_ref("$db/channels/MAG"))
    te.MouseMoveToPos((700, 600))
    ctx.frames(3)
    ctx.shot(joinpath(DATA_SHOTS, "data-open-$name.png"))
    right_click_at_100(tree_ref("$db/channels/MAG"))
    ctx.frames(2)
    te.MouseMove("//###menu/Channel Properties...")
    ctx.frames(2)
    ctx.shot(joinpath(DATA_SHOTS, "data-menu-$name.png"))
    ctx.key("Escape")
    right_click_at_100(tree_ref(db))
    te.MouseMoveToPos((700, 400))
    ctx.frames(2)
    ctx.shot(joinpath(DATA_SHOTS, "data-menu-db-$name.png"))
    ctx.click("//###menu/Rename...")
    ctx.frames(3)
    path = ctx.shot(joinpath(DATA_SHOTS, "data-rename-$name.png"))
    # The selected name has the prototype's selection colour and on-accent text.
    img = PNGFiles.load(path)
    tokens = app.tokens
    # The box is y 421 to 435, as the prototype's (proto-data-rename-*.png); x 590 is
    # between two glyphs of "Kangaroo".
    col = [near(rgb255(img[y + 1, 591]), rgb255(tokens.text_selection)) for y in 418:438]
    @test findfirst(col) + 417 == 421 && findlast(col) + 417 == 435
    @test any(near(rgb255(img[y, x]), rgb255(tokens.on_accent); tol = 30) for y in 420:436, x in 574:690)
    ctx.key("Escape")
    ctx.frames(2)
    right_click(tree_ref("$db/channels/MAG"))
    ctx.click("//###menu/Channel Properties...")
    ctx.frames(3)
    ctx.shot(joinpath(DATA_SHOTS, "data-channel-props-$name.png"))
    ctx.key("Escape")
    ctx.frames(2)
    UI.push_dialog!(app, UI.ResultDialog("Statistics: MAG", "count   172,900\nmin     -173.31\nmax      430.08"))
    ctx.frames(3)
    ctx.shot(joinpath(DATA_SHOTS, "data-result-$name.png"))
    ctx.click("//###dialog1/Close")
    ctx.frames(2)
    @test isempty(app.ui.dialogs)
end

window_testset("data tab") do
    mkpath(DATA_SHOTS)

    @testset "5,000 lines: only the rows in view are drawn, and the frame is fast" begin
        with_project_app(session_with(lines = 5_000, channels = 300)) do ctx, app
            db = app.ui.current_db
            union!(app.ui.expanded, ["databases", db, "$db/lines", "$db/channels"])
            ctx.frames(3)
            limit = tree_view_rows() + 2
            @test 0 < app.ui.tree_drawn <= limit
            app.ui.tree_scroll = 60_000f0   # the middle of the lines
            ctx.frames(2)
            @test app.ui.tree_scroll == 60_000f0 && 0 < app.ui.tree_drawn <= limit
            app.ui.tree_scroll = 1f9        # past the end: clamped
            ctx.frames(2)
            @test app.ui.tree_scroll < 1f9 && 0 < app.ui.tree_drawn <= limit
            ctx.frames(10)                  # warm up
            times = Int[]
            for _ in 1:20
                ctx.frames(1)
                push!(times, app.draw_ns)
            end
            sort!(times)
            @test times[10] < 16_000_000   # the median frame draws in under 16 ms
        end
    end

    @testset "a 200-character name is cut, the pane keeps its width" begin
        with_project_app(session_with(name = "x"^200)) do ctx, app
            push!(app.ui.expanded, "databases")
            ctx.frames(2)
            path = ctx.shot(joinpath(DATA_SHOTS, "data-long-name.png"))
            img = PNGFiles.load(path)
            @test app.config.left_width == 272f0
            row_y = 168 + 34 + 4 + 26 + 13   # the database row's middle
            @test near(rgb255(img[row_y, 272]), rgb255(LIGHT.border))   # the pane's right border
            @test near(rgb255(img[row_y, 274]), rgb255(LIGHT.canvas))   # the central area
            # Nothing is drawn in the row's 8 px right padding: the name stops before it.
            @test all(near(rgb255(img[y, x]), rgb255(LIGHT.pane)) for y in row_y-6:row_y+6, x in 265:270)
            # The full name is in the tooltip.
            te.MouseMove(tree_ref(app.ui.current_db))
            ctx.wait_until(() -> app.ui.tip !== nothing; timeout = 5)
            @test app.ui.tip.title == "x"^200
        end
    end

    @testset "a line checkbox goes through the worker, and Ctrl+Z ticks it again" begin
        with_project_app(session_with(lines = 3)) do ctx, app
            db = app.ui.current_db
            union!(app.ui.expanded, ["databases", db, "$db/lines"])
            ctx.frames(2)
            @test line_selected(app, db, "L1001")
            ctx.click(tree_ref("$db/lines/L1001", "check"))
            ctx.wait_until(() -> !line_selected(app, db, "L1001"))
            @test line_selected(app, db, "L1002")
            @test app.snap.undo_label !== nothing
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> line_selected(app, db, "L1001"))

            # Select None and Select All in the Lines folder menu act on that database.
            right_click(tree_ref("$db/lines"))
            ctx.click("//###menu/Select No Lines")
            ctx.wait_until(() -> !any(l -> l.selected, app.snap.databases[db].lines))
            right_click(tree_ref("$db/lines"))
            ctx.click("//###menu/Select All Lines")
            ctx.wait_until(() -> all(l -> l.selected, app.snap.databases[db].lines))
        end
    end

    @testset "Remove from Project asks, removes, and Ctrl+Z brings the item back" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            push!(app.ui.expanded, "databases")
            ctx.frames(2)
            right_click(tree_ref(db))
            ctx.frames(1)
            @test UI.menu_open(app, "tree") && app.ui.selected == (:database, db, "")
            ctx.click("//###menu/Remove from Project")
            ctx.frames(1)
            d = only(app.ui.dialogs)
            @test d isa UI.ConfirmDialog && d.title == "Remove Kangaroo Hills 2024?"
            ctx.click("//###dialog1/Remove")
            ctx.wait_until(() -> !haskey(app.snap.databases, db))
            ctx.frames(2)
            @test !te.ItemExists(tree_ref(db))
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> haskey(app.snap.databases, db))
            ctx.frames(2)
            @test te.ItemExists(tree_ref(db))
        end
    end

    @testset "Delete Channel on a protected channel shows the core's message" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            union!(app.ui.expanded, ["databases", db, "$db/channels"])
            ctx.frames(2)
            right_click(tree_ref("$db/channels/MAG"))
            ctx.click("//###menu/Delete Channel...")
            ctx.click("//###dialog1/Delete")
            ctx.wait_until(() -> any(t -> t.kind === :error, app.toasts))
            t = only(filter(t -> t.kind === :error, app.toasts))
            @test t.text == UI.user_message(Core.ProtectedError("MAG")) ==
                  "Channel MAG is protected and cannot be edited."
            @test any(c -> c.name == "MAG", app.snap.databases[db].channels)
        end
    end

    @testset "Rename: an empty name keeps the button greyed" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            push!(app.ui.expanded, "databases")
            ctx.frames(2)
            right_click(tree_ref(db))
            ctx.click("//###menu/Rename...")
            ctx.frames(2)
            d = only(app.ui.dialogs)
            @test d isa UI.RenameDialog && UI.field_text(d.name) == "Kangaroo Hills 2024"
            fill_field("//###dialog1/##Name", "")
            ctx.frames(1)
            @test UI.field_text(d.name) == ""
            ctx.click("//###dialog1/Rename")
            ctx.frames(2)
            @test only(app.ui.dialogs) === d   # nothing happened
            path = ctx.shot(joinpath(DATA_SHOTS, "data-rename-empty-light.png"))
            ctx.type("//###dialog1/##Name", "Survey B")   # Enter presses Rename
            ctx.wait_until(() -> UI.item_name(app.snap, db) == "Survey B")
            @test isempty(app.ui.dialogs)
            # Rename a channel; the selection follows the new name.
            union!(app.ui.expanded, [db, "$db/channels"])
            ctx.frames(2)
            right_click(tree_ref("$db/channels/IGRF"))
            ctx.click("//###menu/Rename...")
            ctx.type("//###dialog1/##Name", "IGRF_2025")
            ctx.wait_until(() -> any(c -> c.name == "IGRF_2025", app.snap.databases[db].channels))
            @test app.ui.selected == (:channel, db, "IGRF_2025")
        end
    end

    @testset "Channel Properties sets the channel info" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            union!(app.ui.expanded, ["databases", db, "$db/channels"])
            ctx.frames(2)
            right_click(tree_ref("$db/channels/IGRF"))
            ctx.click("//###menu/Channel Properties...")
            ctx.frames(2)
            @test only(app.ui.dialogs) isa UI.ChannelPropsDialog
            fill_field("//###dialog1/##Decimals", "x")
            ctx.frames(1)
            ctx.click("//###dialog1/Apply")
            ctx.frames(1)
            @test length(app.ui.dialogs) == 1   # a bad number: Apply is greyed
            fill_field("//###dialog1/##Decimals", "auto")
            fill_field("//###dialog1/##Units", "  nT/m ")   # spaces are stripped
            # Format is a combo; its menu opens over the dialog (T11-C4).
            ctx.click("//###dialog1/Format")
            ctx.frames(2)
            @test app.ui.menu !== nothing && app.ui.menu.level == 1
            ctx.click("//" * app.ui.menu.ref * "/Exponential")
            ctx.frames(2)
            @test app.ui.menu === nothing && only(app.ui.dialogs).format[] === :exponential
            ctx.click("//###dialog1/Apply")
            ch() = only(c for c in app.snap.databases[db].channels if c.name == "IGRF")
            ctx.wait_until(() -> ch().units == "nT/m")
            @test ch().decimals == -1 && ch().format == :exponential && ch().label == "IGRF"
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> ch().units == "nT")
        end
    end

    @testset "the current database follows the tree selection" begin
        s = kangaroo_data()
        second = add_test_database!(s, ["A" => [1.0, 2.0]])
        with_project_app(s) do ctx, app
            first_db = app.ui.current_db
            @test first_db != second
            union!(app.ui.expanded, ["databases", second, first_db, "$first_db/channels"])
            ctx.frames(2)
            ctx.click(tree_ref(second))
            @test app.ui.current_db == second && app.ui.selected == (:database, second, "")
            ctx.click(tree_ref("$first_db/channels/MAG"))   # a row under a database
            @test app.ui.current_db == first_db
            ctx.click(tree_ref("$second/lines"))
            @test app.ui.current_db == second
            # A grid row leaves the current database as it is.
            ctx.click(tree_ref("grids"))
            ctx.frames(1)
            grid = first(it.id for it in app.snap.items if it.kind == Core.ITEM_GRID)
            ctx.click(tree_ref(grid))
            @test app.ui.current_db == second && app.ui.selected == (:grid, grid, "")
        end
    end

    @testset "keyboard: arrows, Enter and Shift+F10" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            ctx.click(tree_ref("databases"))   # selects it and opens it
            @test app.ui.selected == (:databases, "", "") && "databases" in app.ui.expanded
            ctx.key("Down")
            @test app.ui.selected == (:database, db, "")
            ctx.key("Right")
            @test db in app.ui.expanded
            ctx.key("Down")
            @test app.ui.selected == (:lines, db, "")
            ctx.key("Enter")
            @test "$db/lines" in app.ui.expanded
            ctx.key("Down")
            @test app.ui.selected == (:line, db, "L1001")
            ctx.key("Enter")   # ticks the line off
            ctx.wait_until(() -> !line_selected(app, db, "L1001"))
            ctx.key("Up")
            ctx.key("Left")
            @test !("$db/lines" in app.ui.expanded)
            ctx.key("Up")
            ctx.key("Shift+F10")
            ctx.frames(1)
            @test UI.menu_open(app, "tree") && app.ui.menu.items[end].label == "Remove from Project"
            ctx.key("Escape")
            ctx.frames(1)
            @test app.ui.menu === nothing
            # The keys pass to the tree only while it has the focus.
            ctx.click("JuliaMag/left/Data")
            ctx.key("Down")
            @test app.ui.selected == (:database, db, "")
            # Down to the end keeps the selected row in view.
            union!(app.ui.expanded, ["$db/lines"])
            ctx.click(tree_ref(db))
            for _ in 1:40
                ctx.key("Down")
            end
            ctx.frames(1)
            @test app.ui.selected[1] === :line && app.ui.tree_scroll > 0
            # The selected row lies wholly inside the tree view.
            rows = UI.cached_tree_rows!(app)
            k = findfirst(r -> UI.row_target(r) == app.ui.selected, rows)
            v = app.ui.tree_view
            top = v.y0 + UI.fpx(1, UI.TREE_PAD) + (k - 1) * UI.fpx(1, UI.TREE_ROW_H) - app.ui.tree_scroll
            @test v.y0 <= top && top + UI.fpx(1, UI.TREE_ROW_H) <= v.y1
            # After a menu action the arrow keys still move in the tree.
            app.ui.tree_scroll = 0f0
            ctx.frames(2)
            right_click(tree_ref(db))
            ctx.click("//###menu/Rename...")
            ctx.key("Escape")
            ctx.frames(2)
            @test isempty(app.ui.dialogs) && app.ui.tree_focused
            ctx.key("Down")
            @test app.ui.selected == (:lines, db, "")
        end
    end

    @testset "the filter shows matches with their parents; Esc clears it" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            union!(app.ui.expanded, ["databases", db, "$db/lines"])
            ctx.frames(2)
            @test te.ItemExists(tree_ref("$db/lines/L1001"))   # drawn before the filter
            ctx.type("JuliaMag/left/##Filter", "t2010")
            ctx.frames(2)
            @test app.ui.filter == "t2010"
            @test te.ItemExists(tree_ref("$db/lines/T2010"))
            @test !te.ItemExists(tree_ref("$db/lines/L1001"))
            @test !te.ItemExists(tree_ref("grids"))   # no grid matches
            ctx.shot(joinpath(DATA_SHOTS, "data-filter-light.png"))
            te.ItemClick("JuliaMag/left/##Filter")
            ctx.key("Escape")
            ctx.frames(2)
            @test app.ui.filter == ""
            @test !te.ItemExists(tree_ref("$db/lines/T2010"))
        end
    end

    @testset "the splitter resizes the pane and saves the width on release" begin
        dir = mktempdir()
        with_test_app(; config_dir = dir) do ctx
            app = ctx.app_state()
            te.MouseMove("JuliaMag/left/splitter")
            ctx.frames(1)
            path = ctx.shot(joinpath(DATA_SHOTS, "data-splitter-hover.png"))
            img = PNGFiles.load(path)
            # 2 px of accent at 70 % over the pane's border (x 271) and the canvas (x 272).
            over(c) = ntuple(i -> i == 4 ? 1f0 : LIGHT.accent[i] * 0.7f0 + c[i] * 0.3f0, 4)
            @test near(rgb255(img[500, 272]), rgb255(over(LIGHT.border)); tol = 2)
            @test near(rgb255(img[500, 273]), rgb255(over(LIGHT.canvas)); tol = 2)
            @test near(rgb255(img[500, 271]), rgb255(LIGHT.pane)) && near(rgb255(img[500, 274]), rgb255(LIGHT.canvas))
            te.MouseDragWithDelta((50, 0))
            ctx.frames(2)
            @test app.config.left_width == 322f0
            ctx.wait_until(() -> app.queue.pending == 0)
            @test UI.load_config(dir)[1].left_width == 322f0
            te.MouseMove("JuliaMag/left/splitter")
            te.MouseDragWithDelta((-500, 0))
            ctx.frames(2)
            @test app.config.left_width == 200f0
        end
    end

    @testset "the Jobs tab shows the number of running jobs" begin
        s = kangaroo_data()
        go = Base.Event()
        job = Core.start_job!(s, "test.waiting_job", Dict{String,Any}(),
            (progress, io) -> (wait(go); Core.ProjectItem[]))
        try
            with_project_app(s) do ctx, app
                try
                    ctx.frames(2)
                    path = ctx.shot(joinpath(DATA_SHOTS, "data-jobs-badge.png"))
                    img = PNGFiles.load(path)
                    # The badge: a 16 px accent pill after "Jobs", after the Data and Layers tabs.
                    row = img[168 + 17, :]
                    xs = [x for x in 120:220 if near(rgb255(row[x]), rgb255(LIGHT.accent); tol = 6)]
                    @test !isempty(xs) && 14 <= last(xs) - first(xs) + 1 <= 17
                finally
                    notify(go)   # before the session closes, which waits for the job
                end
                Core.wait_job(job)
                ctx.wait_until(() -> UI.running_jobs(app.snap) == 0)
            end
        finally
            notify(go)
        end
    end

    @testset "a grid with huge values: the Properties panel stays sensible" begin
        with_project_app(kangaroo_data(; vmin = 1e20, vmax = Float64(Float32(1.70141e38)))) do ctx, app
            grid = first(it.id for it in app.snap.items if it.kind == Core.ITEM_GRID && !it.missing)
            push!(app.ui.expanded, "grids")
            ctx.frames(2)
            ctx.click(tree_ref(grid))
            ctx.frames(5)   # the app keeps drawing
            p = UI.properties(app.snap, app.ui.selected)
            @test p.rows[end] == ("Values" => "Float32, 1.0e20 to 1.70141e38 nT")
            @test isempty(app.draw_errors)
        end
    end

    @testset "the frame guard: a draw error becomes one toast and one log entry" begin
        logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
        Base.CoreLogging.with_logger(logger) do
            with_test_app(; extra_ui = w -> error("the hook broke"), draw_errors_ok = true) do ctx
                app = ctx.app_state()
                ctx.frames(6)
                @test count(t -> t.kind === :error, app.toasts) == 1
                @test only(app.toasts).text == "Something went wrong: the hook broke"
                e = only(app.draw_errors)
                @test e.count >= 6 && e.text == "Something went wrong: the hook broke"
                ctx.click("JuliaMag/left/Jobs")   # the app still takes input
                @test app.ui.left_tab === :jobs
            end
        end
        @test count(r -> r.level == Base.CoreLogging.Error, logger.logs) == 1
    end

    @testset "the frame guard inside a modal, a child window and a popup" begin
        for (d, text) in ((BreakInFooter(), "the footer broke"), (BreakInChild(), "the child broke"),
                (BreakInPopup(), "the popup broke"))
            logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
            Base.CoreLogging.with_logger(logger) do
                with_project_app(kangaroo_data(); draw_errors_ok = true) do ctx, app
                    UI.push_dialog!(app, d)
                    ctx.frames(5)   # it breaks in every frame
                    e = only(app.draw_errors)
                    @test e.count >= 5 && e.reports == 1 && e.text == "Something went wrong: $text"
                    @test count(t -> t.kind === :error, app.toasts) == 1
                    empty!(app.ui.dialogs)
                    ctx.frames(3)
                    # ImGui is balanced: a dialog and a menu work as before.
                    @test popups_open(ctx) == 0
                    UI.confirm!(app, "Go on?", "A normal dialog."; action = "Go", on_yes = a -> (a.ui.tab = "Help"))
                    ctx.frames(2)
                    ctx.click("//###dialog1/Go")
                    ctx.frames(2)
                    @test app.ui.tab == "Help" && isempty(app.ui.dialogs)
                    ctx.click("JuliaMag/tabs/Database")
                    ctx.click("JuliaMag/ribbon/More import formats")
                    ctx.frames(1)
                    @test UI.menu_open(app, "import.database")
                    ctx.key("Escape")
                    @test only(app.draw_errors).count == e.count   # nothing broke since
                end
            end
            @test count(r -> r.level == Base.CoreLogging.Error, logger.logs) == 1
        end
    end

    @testset "a filter without matches says so" begin
        with_project_app(kangaroo_data()) do ctx, app
            ctx.type("JuliaMag/left/##Filter", "zzz")
            ctx.frames(2)
            @test app.ui.tree_drawn == 0
            img = PNGFiles.load(ctx.shot(joinpath(DATA_SHOTS, "data-no-matches-light.png")))
            # Dim text in the first row's place, centred in the tree.
            row = [img[202 + 4 + 13 + 1, x] for x in 1:271]
            dim = [x for x in 1:271 if near(rgb255(row[x]), rgb255(LIGHT.text_dim); tol = 40)]
            @test !isempty(dim) && abs((first(dim) + last(dim)) / 2 - 136) <= 3
        end
    end

    @testset "chevrons and checkboxes belong to their row" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            union!(app.ui.expanded, ["databases", db, "$db/lines"])
            ctx.frames(2)
            ctx.click(tree_ref(db, "chevron"))   # closes it, selects it, focuses the tree
            @test !(db in app.ui.expanded) && app.ui.selected == (:database, db, "") && app.ui.tree_focused
            ctx.click(tree_ref(db, "chevron"))
            ctx.frames(1)
            ctx.click(tree_ref("$db/lines/L1002", "check"))
            @test app.ui.selected == (:line, db, "L1002")
            ctx.wait_until(() -> !line_selected(app, db, "L1002"))
            # The row keeps its hover fill under the mouse on the checkbox.
            te.MouseMove(tree_ref("$db/lines/L1003", "check"))
            ctx.frames(2)
            img = PNGFiles.load(ctx.shot(joinpath(DATA_SHOTS, "data-hover-check.png")))
            y = 202 + 4 + 26 * 5 + 13 + 1   # the row of L1003, 1-based
            @test near(rgb255(img[y, 10]), rgb255(LIGHT.hover))
            # A right click on a chevron opens the row's menu.
            right_click(tree_ref(db, "chevron"))
            ctx.frames(1)
            @test UI.menu_open(app, "tree") && app.ui.menu.items[end].label == "Remove from Project"
            ctx.key("Escape")
        end
    end

    @testset "an open context menu follows the project" begin
        with_project_app(kangaroo_data()) do ctx, app
            db = app.ui.current_db
            union!(app.ui.expanded, ["databases", db, "$db/channels"])
            ctx.frames(2)
            right_click(tree_ref("$db/channels/IGRF"))
            ctx.frames(1)
            @test any(it -> it.label == "Protect", app.ui.menu.items)
            UI.submit!(app, "Protect IGRF", s -> Core.set_channel_protected!(s, db, "IGRF", true))
            ctx.wait_until(() -> any(it -> it.label == "Unprotect", app.ui.menu.items))
            @test UI.menu_open(app, "tree")
            ctx.key("Escape")
        end
    end

    @testset "the result dialog copies its text" begin
        with_project_app(kangaroo_data()) do ctx, app
            text = join(["line $k " * "x"^(k == 3 ? 300 : 3) for k in 1:2000], "\n")
            UI.push_dialog!(app, UI.ResultDialog("Report", text))
            ctx.frames(3)
            ctx.click("//###dialog1/Copy")
            got = Ref("")
            ctx.on_render(w -> (got[] = unsafe_string(ig.GetClipboardText())))
            @test got[] == text
            @test any(t -> t.text == "Report copied", app.toasts)
            ctx.click("//###dialog1/Close")
            ctx.frames(2)
            @test isempty(app.ui.dialogs)
        end
    end

    @testset "shots of the tree, the properties, the menu and the dialogs" begin
        for (theme, tokens, name) in ((THEME_LIGHT, LIGHT, "light"), (THEME_DARK, DARK, "dark"))
            for scale in (1, 1.5)
                sfx = scale == 1 ? "" : "-1.5x"
                with_project_app(kangaroo_data(); theme, scale) do ctx, app
                    db = app.ui.current_db
                    union!(app.ui.expanded, ["databases", db, "grids"])   # as the prototype opens
                    ctx.frames(1)
                    ctx.click(tree_ref(db))
                    te.MouseMoveToPos((700, 600))
                    ctx.frames(3)
                    path = ctx.shot(joinpath(DATA_SHOTS, "data-$name$sfx.png"))
                    img = PNGFiles.load(path)
                    p(v) = Int(UI.px(scale, v))
                    # The selected row's fill, inset 4 px; the Properties header band.
                    y = p(168 + 34 + 4 + 26 + 13)
                    @test near(rgb255(img[y, p(10)]), rgb255(tokens.selection))
                    @test near(rgb255(img[y, p(2)]), rgb255(tokens.pane))
                    scale == 1 && more_shots(ctx, app, name)
                end
            end
        end
    end
end
