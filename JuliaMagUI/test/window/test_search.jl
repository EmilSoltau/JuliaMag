using Test
import CImGui as ig
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK, ToolDialog, ShortcutsDialog

const SEARCH_SHOTS = joinpath(@__DIR__, "..", "shots")

# The test engine reference of an item of the command search overlay.
search_ref(name) = "//" * UI.SEARCH_WINDOW * "/" * name

last_dialog(app) = isempty(app.ui.dialogs) ? nothing : last(app.ui.dialogs)

# How many popups ImGui has open now.
function popup_count(ctx)
    n = Ref(-1)
    ctx.on_render(w -> (n[] = unsafe_load(Ptr{ig.lib.ImGuiContext}(ig.GetCurrentContext()).OpenPopupStack).Size))
    return n[]
end

# The pixel at device point (x, y) of a PNG, as 0-255 RGB.
shot_pixel(img, x, y) = rgb255(img[round(Int, y)+1, round(Int, x)+1])

window_testset("command search") do
    mkpath(SEARCH_SHOTS)

    @testset "Ctrl+K, type, Enter opens Channel Math" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.key("Ctrl+K")
            ctx.frames(2)
            @test app.ui.search == "" && te.ItemExists(search_ref("##query"))
            ctx.type("math")
            ctx.frames(2)
            @test app.ui.search == "math"
            @test first(UI.search_hits!(app)).id == "database.channel_math"
            ctx.key("Enter")
            ctx.wait_until(() -> last_dialog(app) isa ToolDialog; timeout = 5)
            @test app.ui.search === nothing
            @test last_dialog(app).form.owner.id == "database.channel_math"
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
        end
    end

    @testset "keys, mouse and clicks in the list" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.click("JuliaMag/header/Command Search")
            ctx.frames(2)
            hits = UI.search_hits!(app)
            @test app.ui.search_index == 1
            ctx.key("Down"); ctx.key("Down")
            @test app.ui.search_index == 3
            ctx.key("Up")
            @test app.ui.search_index == 2
            # The keyboard reaches rows below the list; the list scrolls them into view.
            for _ in 1:20
                ctx.key("Down")
            end
            ctx.frames(2)
            k = app.ui.search_index
            @test k == min(22, length(hits)) && te.ItemExists(search_ref(hits[k].id))
            @test app.ui.search_scroll > 0
            # The mouse that moves takes the highlight; the last input wins.
            te.MouseMove(search_ref(hits[k-2].id))
            ctx.frames(1)
            @test app.ui.search_index == k - 2
            ctx.key("Down")
            @test app.ui.search_index == k - 1
            # A click runs the row's command and closes the search.
            ctx.type("ribbon")
            ctx.frames(2)
            ctx.click(search_ref("ui.ribbon"))
            ctx.frames(2)
            @test app.ui.search === nothing && app.config.ribbon_collapsed
            ctx.key("Ctrl+F1")
            ctx.wait_until(() -> !app.config.ribbon_collapsed)
            # The close x, and a click on the backdrop, close it too.
            ctx.key("Ctrl+K"); ctx.frames(2)
            ctx.click(search_ref("Close search"))
            ctx.frames(2)
            @test app.ui.search === nothing
            ctx.key("Ctrl+K"); ctx.frames(2)
            te.MouseMoveToPos((200, 700)); te.MouseClick(0)
            ctx.frames(2)
            @test app.ui.search === nothing && !app.config.ribbon_collapsed
            # Typing with no match shows the empty text; Enter keeps the search open, so a
            # typo can be fixed.
            ctx.key("Ctrl+K"); ctx.frames(2)
            ctx.type("zzzz")
            ctx.frames(2)
            @test isempty(UI.search_hits!(app))
            ctx.key("Enter")
            ctx.frames(2)
            @test app.ui.search == "zzzz" && isempty(app.ui.dialogs)
            # Ctrl+Z in the search field undoes its typing, never the project.
            ctx.key("Ctrl+Z")
            ctx.frames(2)
            @test app.ui.search == "zzz" && app.queue.pending == 0 && app.snap.undo_label === nothing
            ctx.key("Escape")
            ctx.frames(2)
            @test app.ui.search === nothing
        end
    end

    @testset "Ctrl+K from a text field of a tool dialog" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.click("JuliaMag/tabs/Database Tools")
            ctx.click("JuliaMag/ribbon/Channel Math")
            ctx.wait_until(() -> last_dialog(app) isa ToolDialog; timeout = 5)
            ctx.frames(2)
            ref = "//" * UI.dialog_ref(1) * "/##expr"
            te.ItemClick(ref); te.KeyCharsReplace("C3 = C1")
            ctx.frames(1)
            expr() = UI.field_text(last_dialog(app).buffers["expr"])
            @test expr() == "C3 = C1"
            ctx.key("Ctrl+K")
            ctx.frames(2)
            @test app.ui.search == "" && app.ui.search_level == 1
            ctx.type("theme")   # the keys go to the search, not to the dialog's field
            ctx.frames(2)
            @test app.ui.search == "theme" && expr() == "C3 = C1"
            ctx.key("Escape")
            ctx.frames(2)
            @test app.ui.search === nothing && last_dialog(app) isa ToolDialog && expr() == "C3 = C1"
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
        end
    end

    @testset "a reopened search starts on its first row, also over a dialog" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.key("Ctrl+K"); ctx.frames(2)
            @test UI.search_hits!(app)[1].id == "project.backstage"   # lit first
            ctx.key("Escape"); ctx.frames(2)
            ctx.click("JuliaMag/tabs/Database Tools")
            ctx.click("JuliaMag/ribbon/Channel Math")
            ctx.wait_until(() -> last_dialog(app) isa ToolDialog; timeout = 5)
            ctx.frames(2)
            ctx.key("Ctrl+K"); ctx.frames(2)
            hits = UI.search_hits!(app)
            # Project now waits for the dialog and sorts last; the highlight stays on row 1.
            @test app.ui.search_index == 1 && app.ui.search_scroll == 0
            first_hit = hits[1]
            @test UI.search_reason(app, first_hit) === nothing && te.ItemExists(search_ref(first_hit.id))
            @test first_hit.id == "ui.command_search"
            # Enter runs that row: Command Search opens the search again, empty, with no toast.
            ctx.type("comm"); ctx.frames(2)
            @test UI.search_hits!(app)[app.ui.search_index].id == "ui.command_search"
            toasts = length(app.toasts)
            ctx.key("Enter"); ctx.frames(3)
            @test app.ui.search == "" && length(app.toasts) == toasts && last_dialog(app) isa ToolDialog
            ctx.key("Escape"); ctx.frames(2)
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
        end
    end

    @testset "a command that cannot run shows its reason" begin
        with_test_app() do ctx
            app = ctx.app_state()
            ctx.key("Ctrl+K"); ctx.frames(2)
            ctx.type("channel math")
            ctx.frames(2)
            ctx.key("Enter")
            ctx.frames(2)
            @test app.ui.search === nothing && isempty(app.ui.dialogs)
            @test last(app.toasts).text == "Open a project first."
        end
    end

    @testset "over a dialog: Esc closes the search, then the dialog" begin
        with_project_app(kangaroo()) do ctx, app
            UI.confirm!(app, "Remove?", "It can be undone."; action = "Remove", on_yes = a -> nothing)
            ctx.frames(3)
            @test popup_count(ctx) == 1
            ctx.key("Ctrl+K")
            ctx.frames(2)
            @test app.ui.search == "" && app.ui.search_level == 1 && popup_count(ctx) == 2
            ctx.type("keyb")
            ctx.frames(2)
            @test app.ui.search == "keyb"   # the keys reach the search, not the dialog
            ctx.key("Escape")
            ctx.frames(2)
            @test app.ui.search === nothing && length(app.ui.dialogs) == 1 && popup_count(ctx) == 1
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            ctx.frames(2)
            @test popup_count(ctx) == 0

            # Enter on a command that opens a dialog stacks it on the open one.
            UI.confirm!(app, "Remove?", "It can be undone."; action = "Remove", on_yes = a -> nothing)
            ctx.frames(3)
            ctx.key("Ctrl+K"); ctx.frames(2)
            ctx.type("keyboard")
            ctx.frames(2)
            ctx.key("Enter")
            ctx.wait_until(() -> length(app.ui.dialogs) == 2)
            @test last_dialog(app) isa ShortcutsDialog && app.ui.search === nothing
            ctx.frames(2)
            @test te.ItemExists("//" * UI.dialog_ref(2) * "/Close")
            ctx.key("Escape")
            ctx.wait_until(() -> length(app.ui.dialogs) == 1)
            # Over a dialog, a command that changes the project only says why it waits.
            UI.submit!(app, "Rename", s -> Core.rename_item!(s, app.ui.current_db, "Survey C"))
            ctx.wait_until(() -> app.snap.undo_label !== nothing)
            ctx.key("Ctrl+K"); ctx.frames(2)
            ctx.type("undo"); ctx.frames(2)
            @test first(UI.search_hits!(app)).id == "session.undo"
            ctx.key("Enter")
            ctx.frames(3)
            @test last(app.toasts).text == "Close the dialog first."
            @test UI.item_name(app.snap, app.ui.current_db) == "Survey C" && length(app.ui.dialogs) == 1
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
        end
    end

    @testset "Ctrl+Z undoes a rename, but not inside a text field" begin
        with_project_app(kangaroo()) do ctx, app
            db = app.ui.current_db
            push!(app.ui.expanded, "databases")
            ctx.frames(2)
            right_click(tree_ref(db))
            ctx.click("//###menu/Rename...")
            ctx.frames(2)
            ctx.type("//###dialog1/##Name", "Survey B")   # Enter presses Rename
            ctx.wait_until(() -> UI.item_name(app.snap, db) == "Survey B")
            # In the filter field, Ctrl+Z undoes the typing, not the rename.
            ctx.click("JuliaMag/left/##Filter")
            ctx.type("xyz")
            ctx.frames(2)
            @test app.ui.filter == "xyz"
            ctx.key("Ctrl+Z")
            ctx.frames(3)
            @test app.ui.filter == "xy"   # the field's own undo: one typed character
            @test UI.item_name(app.snap, db) == "Survey B" && app.queue.pending == 0
            # Out of the field, Ctrl+Z undoes the rename.
            ctx.click("JuliaMag/left/Data")
            ctx.frames(2)
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> UI.item_name(app.snap, db) == "Kangaroo Hills 2024")
            ctx.key("Ctrl+Y")
            ctx.wait_until(() -> UI.item_name(app.snap, db) == "Survey B")
            # Ctrl+Shift+L switches the theme; Ctrl+Shift+Z redoes too.
            ctx.key("Ctrl+Shift+L")
            ctx.wait_until(() -> app.tokens === DARK)
            ctx.key("Ctrl+Shift+L")
            ctx.wait_until(() -> app.tokens === LIGHT)
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> UI.item_name(app.snap, db) == "Kangaroo Hills 2024")
            ctx.key("Ctrl+Shift+Z")
            ctx.wait_until(() -> UI.item_name(app.snap, db) == "Survey B")
        end
    end

    @testset "the Tools pane lists every tool, import and export; a click opens it" begin
        with_project_app(kangaroo()) do ctx, app
            @test !te.ItemExists("JuliaMag/right/Close all panes")
            ctx.click("JuliaMag/tabs/Database Tools")
            ctx.click("JuliaMag/ribbon/All Tools")
            ctx.frames(2)
            @test app.ui.right_tabs == [:tools]
            # Every row, found by its id in the pane's search (the list need not fit in view).
            ids = [[t.id for t in Core.tools()]; [i.id for i in Core.importers()]; [e.id for e in Core.exporters()]]
            for id in ids
                ctx.type("JuliaMag/right/tools/##find", id)
                ctx.frames(2)
                @test te.ItemExists("JuliaMag/right/tools/" * id)
            end
            ctx.type("JuliaMag/right/tools/##find", "")
            ctx.frames(2)
            # An importer asks for a file, then opens its import dialog.
            path = small_xyz()
            app.pick_file = (; kw...) -> path
            ctx.click("JuliaMag/right/tools/import.geosoft_xyz")
            ctx.wait_until(() -> last_dialog(app) isa ToolDialog; timeout = 5)
            @test last_dialog(app).form.owner.id == "import.geosoft_xyz" && last_dialog(app).form.path == path
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            # An exporter opens its export dialog for the current database.
            ctx.click("JuliaMag/right/tools/export.csv")
            ctx.wait_until(() -> last_dialog(app) isa ToolDialog; timeout = 5)
            @test last_dialog(app).form.owner.id == "export.csv"
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            ctx.click("JuliaMag/right/tools/database.statistics")
            ctx.wait_until(() -> last_dialog(app) isa ToolDialog; timeout = 5)
            @test last_dialog(app).form.owner.id == "database.statistics"
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            # The search box filters by name or id.
            ctx.click("JuliaMag/right/tools/##find")
            ctx.type("guess")
            ctx.frames(3)
            @test te.ItemExists("JuliaMag/right/tools/coordinates.guess_utm")
            @test !te.ItemExists("JuliaMag/right/tools/database.statistics")
            ctx.key("Ctrl+A"); ctx.type("zzzz"); ctx.frames(3)
            @test !te.ItemExists("JuliaMag/right/tools/coordinates.guess_utm")
            # Its splitter: a drag to the left widens it, down to the 480 px most.
            te.MouseMove("JuliaMag/right/splitter")
            te.MouseDragWithDelta((-50, 0))
            ctx.frames(2)
            @test app.config.right_width == 350f0
            te.MouseMove("JuliaMag/right/splitter")
            te.MouseDragWithDelta((-500, 0))
            ctx.frames(2)
            @test app.config.right_width == 480f0
            # The tab's x closes it, and the pane goes.
            ctx.click("JuliaMag/right/Close Tools")
            ctx.frames(3)
            @test isempty(app.ui.right_tabs) && !te.ItemExists("JuliaMag/right/Close all panes")
            # Close all, after Help > All Tools opened it again.
            ctx.click("JuliaMag/tabs/Help")
            ctx.click("JuliaMag/ribbon/All Tools")
            ctx.frames(2)
            @test app.ui.right_tabs == [:tools]
            ctx.click("JuliaMag/right/Close all panes")
            ctx.frames(3)
            @test isempty(app.ui.right_tabs)
        end
    end

    @testset "the smallest window: both panes at 480 keep the centre and their splitters" begin
        dir = mktempdir()
        config, _ = UI.load_config(dir)
        config.left_width = 480; config.right_width = 480
        UI.save_config(config, dir)
        with_test_app(; size = (900, 560), config_dir = dir) do ctx
            app = ctx.app_state()
            UI.run_command!(app, "ui.tools_pane")
            ctx.frames(3)
            @test app.ui.right_tabs == [:tools]
            # The right pane gave way to 260 px, so the centre keeps its 160.
            @test te.ItemInfo("JuliaMag/right/Close all panes").RectFull.Max.x == 900 - 6
            @test round(Int, te.ItemInfo("JuliaMag/right/splitter").RectFull.Min.x) == 640 - 3
            # The left splitter drags from where it is shown.
            te.MouseMove("JuliaMag/left/splitter")
            te.MouseDragWithDelta((-50, 0))
            ctx.frames(2)
            @test app.config.left_width == 430f0
            # The right one too: it is not under the left one.
            te.MouseMove("JuliaMag/right/splitter")
            te.MouseDragWithDelta((20, 0))
            ctx.frames(2)
            @test app.config.right_width == 290f0   # shown 310 (900 - 430 - 160), less 20
        end
    end

    @testset "a click on a squeezed pane's splitter keeps the saved width" begin
        dir = mktempdir()
        config, _ = UI.load_config(dir)
        config.left_width = 480; config.right_width = 480
        UI.save_config(config, dir)
        with_test_app(; size = (900, 560), config_dir = dir) do ctx
            app = ctx.app_state()
            UI.run_command!(app, "ui.tools_pane")
            ctx.frames(3)
            # The right pane shows at 260; a click with no move leaves its 480.
            ctx.click("JuliaMag/right/splitter")
            ctx.frames(2)
            ctx.wait_until(() -> app.queue.pending == 0)
            @test app.config.right_width == 480f0 && UI.load_config(dir)[1].right_width == 480f0
            ctx.click("JuliaMag/left/splitter")
            ctx.frames(2)
            ctx.wait_until(() -> app.queue.pending == 0)
            @test app.config.left_width == 480f0 && UI.load_config(dir)[1].left_width == 480f0
        end
    end

    @testset "the Keyboard Shortcuts dialog from the Help tab" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.click("JuliaMag/tabs/Help")
            ctx.click("JuliaMag/ribbon/Keyboard Shortcuts")
            ctx.wait_until(() -> last_dialog(app) isa ShortcutsDialog)
            ctx.frames(2)
            ctx.click("//" * UI.dialog_ref(1) * "/Close")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
        end
    end

    @testset "shots: search, Tools pane, Keyboard Shortcuts" begin
        for (theme, tokens, name) in ((THEME_LIGHT, LIGHT, "light"), (THEME_DARK, DARK, "dark")),
                (scale, sfx) in ((1f0, ""), (1.5f0, "-1.5x"))
            with_project_app(kangaroo(); theme, scale) do ctx, app
                te.MouseMoveToPos((5, 900))
                ctx.key("Ctrl+K")
                ctx.frames(3)
                img = PNGFiles.load(ctx.shot(joinpath(SEARCH_SHOTS, "search-empty-$name$sfx.png")))
                l = UI.search_layout(UI.Box(0, 0, 1480, 920), scale, length(UI.search_hits!(app)))
                # The first row has the hover fill; the box the menu fill.
                row = UI.fpx(scale, 4) + UI.fpx(scale, 28) / 2
                @test near(shot_pixel(img, l.list.x0 + UI.fpx(scale, 6), l.list.y0 + row), rgb255(tokens.hover))
                @test near(shot_pixel(img, l.list.x1 - 2, l.foot.y0 + UI.fpx(scale, 3)), rgb255(tokens.menu))
                ctx.type("math")
                ctx.frames(3)
                ctx.shot(joinpath(SEARCH_SHOTS, "search-query-$name$sfx.png"))
                ctx.key("Ctrl+A"); ctx.type("zzzz")
                ctx.frames(3)
                ctx.shot(joinpath(SEARCH_SHOTS, "search-none-$name$sfx.png"))
                ctx.key("Escape")
                ctx.frames(2)
                UI.run_command!(app, "ui.tools_pane")
                ctx.frames(3)
                ctx.shot(joinpath(SEARCH_SHOTS, "tools-$name$sfx.png"))
                UI.run_command!(app, "ui.tools_pane")
                UI.run_command!(app, "ui.shortcuts")
                ctx.frames(4)
                ctx.shot(joinpath(SEARCH_SHOTS, "shortcuts-$name$sfx.png"))
                ctx.key("Escape")
                ctx.wait_until(() -> isempty(app.ui.dialogs))
            end
        end
    end
end
