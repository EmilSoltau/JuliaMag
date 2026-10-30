using Test
import CImGui as ig
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK

const SHELL_SHOTS = joinpath(@__DIR__, "..", "shots")

# How many popups ImGui has open now.
function open_popups(ctx)
    n = Ref(-1)
    ctx.on_render(w -> (n[] = unsafe_load(Ptr{ig.lib.ImGuiContext}(ig.GetCurrentContext()).OpenPopupStack).Size))
    return n[]
end

# A dialog with one text field, to test Enter.
struct NameDialog
    buffer::Vector{UInt8}
    ok::Base.RefValue{Int}
end
NameDialog() = NameDialog(zeros(UInt8, 64), Ref(0))

function UI.draw_modal(app, d::NameDialog)
    UI.draw_dialog(app, d; title = "Rename", ok_label = "Rename",
        on_ok = () -> (d.ok[] += 1; UI.pop_dialog!(app))) do
        ig.InputText("Name", d.buffer, length(d.buffer))
    end
end

# A dialog whose body breaks after pushing on the ImGui stacks.
struct BrokenDialog end
function UI.draw_modal(app, d::BrokenDialog)
    UI.draw_dialog(app, d; title = "Broken", on_ok = () -> nothing) do
        ig.PushID("half done")
        ig.BeginGroup()
        throw(ArgumentError("the form broke"))
    end
end

window_testset("shell") do
    mkpath(SHELL_SHOTS)

    @testset "header, tabs, peek, status bar and shortcuts" begin
        with_project_app(kangaroo()) do ctx, app
            # The search pill opens the command search.
            @test app.ui.search === nothing
            ctx.click("JuliaMag/header/Command Search")
            @test app.ui.search == ""
            app.ui.search = nothing

            # A tab click picks the ribbon tab.
            ctx.click("JuliaMag/tabs/Database Tools")
            @test app.ui.tab == "Database Tools" && !app.ui.ribbon_peek
            # Ctrl+F1, pressed through ImGui, collapses the ribbon.
            ctx.key("Ctrl+F1")
            ctx.wait_until(() -> app.config.ribbon_collapsed)
            # While collapsed, a tab click shows the ribbon as a peek ...
            ctx.click("JuliaMag/tabs/Coordinates")
            @test app.ui.tab == "Coordinates" && app.ui.ribbon_peek
            # ... which a click outside it hides again (here: the status bar).
            ctx.click("JuliaMag/status/Jobs")
            @test !app.ui.ribbon_peek && app.ui.left_tab == :jobs
            ctx.click("JuliaMag/left/Data")
            @test app.ui.left_tab == :data
            ctx.click("JuliaMag/left/Jobs")
            @test app.ui.left_tab == :jobs
            ctx.click("JuliaMag/left/Data")
            # The chevron expands it again.
            ctx.click("JuliaMag/tabs/Collapse Ribbon")
            ctx.wait_until(() -> !app.config.ribbon_collapsed)

            # The status bar shows the current database; its jobs text opens the Jobs tab.
            st = UI.status_texts(app)
            @test st.database == "Kangaroo Hills 2024: 60 lines, 24 channels"
            @test st.selected == "Selected lines: 60 of 60"
            ctx.click("JuliaMag/status/Jobs")
            @test app.ui.left_tab == :jobs
            # Esc hides a peek too.
            ctx.key("Ctrl+F1")
            ctx.wait_until(() -> app.config.ribbon_collapsed)
            ctx.click("JuliaMag/tabs/Database")
            @test app.ui.ribbon_peek
            ctx.key("Escape")
            ctx.frames(1)
            @test !app.ui.ribbon_peek
            # A double click on a tab expands the ribbon again.
            te.ItemDoubleClick("JuliaMag/tabs/Database")
            ctx.wait_until(() -> !app.config.ribbon_collapsed)
            @test !app.ui.ribbon_peek
        end
    end

    @testset "a running job shows the spinner in the status bar" begin
        s = kangaroo()
        go = Base.Event()
        job = Core.start_job!(s, "test.waiting_job", Dict{String,Any}(),
            (progress, io) -> (wait(go); Core.ProjectItem[]))
        try
            with_project_app(s) do ctx, app
                @test UI.status_texts(app).running == 1
                ctx.frames(3)   # draws the spinner
                ctx.shot(joinpath(SHELL_SHOTS, "shell-job-running.png"))
                notify(go)
                Core.wait_job(job)
                ctx.wait_until(() -> UI.status_texts(app).running == 0)
            end
        finally
            notify(go)
        end
        @test Core.status(job) == Core.JOB_DONE
    end

    @testset "a shortcut whose command throws shows an error toast" begin
        with_project_app(kangaroo()) do ctx, app
            UI.commands(app)   # fills the cache
            cache = app.command_cache
            broken = UI.Command("test.broken", "Broken", a -> throw(ArgumentError("the shortcut broke"));
                shortcut = "Ctrl+F2")
            app.command_cache = UI.CommandCache(cache.sizes, [cache.commands; broken])
            ctx.key("Ctrl+F2")
            ctx.wait_until(() -> !isempty(app.toasts))
            @test last(app.toasts).kind == :error && last(app.toasts).text == "The shortcut broke."
            ctx.frames(2)   # the app keeps drawing
        end
    end

    @testset "Ctrl+Z undoes through the ImGui key path" begin
        with_project_app(kangaroo()) do ctx, app
            id = app.ui.current_db
            ids = [l.id for l in app.snap.databases[id].lines]
            UI.submit!(app, "Select no lines", s -> Core.set_lines_selected!(s, id, ids, false))
            selected() = count(l -> l.selected, app.snap.databases[id].lines)
            ctx.wait_until(() -> selected() == 0)
            @test app.snap.undo_label !== nothing
            ctx.key("Ctrl+Z")
            ctx.wait_until(() -> selected() == 60)
            @test app.snap.redo_label !== nothing
            ctx.key("Ctrl+Y")
            ctx.wait_until(() -> selected() == 0)
        end
    end

    @testset "confirm box: Esc closes it, a second Esc does nothing" begin
        # The broken dialog below is a draw error on purpose (T13-C6): one log entry.
        logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
        Base.CoreLogging.with_logger(logger) do
        with_project_app(kangaroo(); draw_errors_ok = true) do ctx, app
            yes = Ref(0)
            UI.confirm!(app, "Remove Kangaroo Hills 2024?", "It can be undone.";
                action = "Remove", danger = true, on_yes = a -> (yes[] += 1))
            ctx.frames(3)
            ref = "//" * UI.dialog_ref(1)
            @test te.ItemExists(ref * "/Remove") && te.ItemExists(ref * "/Cancel")
            @test open_popups(ctx) == 1
            ctx.key("Escape")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            @test open_popups(ctx) == 0   # the popup left ImGui too
            collapsed = app.config.ribbon_collapsed
            ctx.key("Escape")
            ctx.frames(2)
            @test isempty(app.ui.dialogs) && yes[] == 0 && app.config.ribbon_collapsed == collapsed

            # The primary button runs the action and closes the box.
            UI.confirm!(app, "Remove?", "It can be undone."; action = "Remove",
                on_yes = a -> (yes[] += 1))
            ctx.frames(3)
            ctx.click(ref * "/Remove")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            @test yes[] == 1
            # A dialog on a dialog: Esc closes the top one only.
            UI.confirm!(app, "First?", "One."; action = "OK", on_yes = a -> nothing)
            ctx.frames(2)
            UI.confirm!(app, "Second?", "Two."; action = "OK", on_yes = a -> nothing)
            ctx.frames(3)
            @test te.ItemExists("//" * UI.dialog_ref(2) * "/Cancel") && open_popups(ctx) == 2
            ctx.key("Escape")
            ctx.wait_until(() -> length(app.ui.dialogs) == 1)
            @test only(app.ui.dialogs).title == "First?" && open_popups(ctx) == 1
            # Shortcuts other than Ctrl+K and Esc wait while a modal is open.
            ctx.key("Ctrl+F1")
            ctx.frames(2)
            @test app.config.ribbon_collapsed == collapsed
            ctx.click(ref * "/Cancel")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            # Enter in a text field presses the primary button.
            d = UI.push_dialog!(app, NameDialog())
            ctx.frames(2)
            ctx.click(ref * "/Name")
            ctx.type("Survey A")
            ctx.frames(1)
            @test d.ok[] == 0
            ctx.key("Enter")
            ctx.wait_until(() -> isempty(app.ui.dialogs))
            @test d.ok[] == 1 && unsafe_string(pointer(d.buffer)) == "Survey A"
            # An action that throws becomes an error toast; the app keeps running.
            # (An ArgumentError is a user error: it shows its message and logs nothing.)
            UI.confirm!(app, "Break?", "It throws."; action = "Break",
                on_yes = a -> throw(ArgumentError("the name is taken")))
            ctx.frames(2)
            ctx.click(ref * "/Break")
            @test isempty(app.ui.dialogs) && last(app.toasts).text == "The name is taken."
            # A dialog body that throws leaves the ImGui stacks whole: the dialog closes with
            # an error toast and the app keeps running.
            UI.push_dialog!(app, BrokenDialog())
            ctx.frames(3)
            @test isempty(app.ui.dialogs) && last(app.toasts).text == "The form broke."
            @test only(app.draw_errors).count == 1
            @test open_popups(ctx) == 0
            ctx.click("JuliaMag/left/Jobs")
            @test app.ui.left_tab == :jobs
            # Dialogs of a project do not outlive it.
            UI.confirm!(app, "Gone?", "With the project."; action = "OK", on_yes = a -> nothing)
            ctx.frames(2)
            UI.set_session!(app, nothing)
            @test isempty(app.ui.dialogs) && open_popups(ctx) == 0
        end
        end
        @test count(r -> r.level == Base.CoreLogging.Error, logger.logs) == 1
    end

    @testset "toasts: at most three, oldest goes first, they expire and close" begin
        with_project_app(kangaroo()) do ctx, app
            # Long lifetimes: the first toast frames compile code, which must not expire them.
            for k in 1:4
                UI.toast!(app, :info, "Toast $k"; ms = 60_000)
            end
            ctx.frames(2)
            @test [t.text for t in app.toasts] == ["Toast 2", "Toast 3", "Toast 4"]
            newest = last(app.toasts)
            @test te.ItemExists(UI.toast_ref(newest) * "/Close")
            ctx.click(UI.toast_ref(newest) * "/Close")
            @test [t.text for t in app.toasts] == ["Toast 2", "Toast 3"]
            # A toast keeps its window when an older one goes.
            keep = last(app.toasts)
            popfirst!(app.toasts)
            ctx.frames(2)
            @test te.ItemExists(UI.toast_ref(keep) * "/Close")
            # An action button runs its action and closes the toast.
            ran = Ref(false)
            empty!(app.toasts)
            t = UI.toast!(app, :error, "Import failed"; sub = "No file.",
                actions = ["Report" => a -> (ran[] = true)], ms = 60_000)
            ctx.frames(2)
            ctx.click(UI.toast_ref(t) * "/Report##action1")
            @test ran[] && isempty(app.toasts)
            # A toast goes when its time is up, with no input. (The mouse leaves the corner
            # first: over a toast, its clock stops.)
            te.MouseMove("JuliaMag/left/Data")
            UI.toast!(app, :ok, "Short"; ms = 300)
            ctx.wait_until(() -> isempty(app.toasts); timeout = 5)
            # The mouse over a new toast stops its clock, but not its slide-in.
            t = UI.toast!(app, :ok, "Hovered"; ms = 60_000)
            ctx.frames(1)
            te.MouseMove(UI.toast_ref(t) * "/Close")
            ctx.wait_until(() -> time() - t.shown > 2 * UI.TOAST_SLIDE)
            @test UI.toast_slide(t) == 1 && t.born > t.shown
        end
    end

    @testset "tooltip after a pause on an item" begin
        with_project_app(kangaroo()) do ctx, app
            te.MouseMove("JuliaMag/header/Undo")
            ctx.wait_until(() -> app.ui.tip !== nothing; timeout = 5)
            tip = app.ui.tip
            @test tip.title == "Undo" && tip.shortcut == "Ctrl+Z" && tip.id == "session.undo"
            @test tip.reason == "Nothing to undo."
        end
    end

    @testset "at 900 by 560 the title drops and the pill keeps clear of the toolbar" begin
        long = "Kangaroo Hills 2024 aeromagnetic survey, final located and levelled data"
        s = session_with(lines = 2, channels = 2, project = long,
            name = long * ", contractor delivery of all flights")
        with_project_app(s; size = (900, 560)) do ctx, app
            layout = Ref{Any}(nothing)
            ctx.on_render(w -> begin
                vp = unsafe_load(ig.GetMainViewport())
                b = UI.Box(0, 0, vp.Size.x, UI.px(w, UI.HEADER_H))
                layout[] = UI.header_layout(b, w.scale, UI.text_width, UI.header_title(app),
                    length(UI.QAT))
            end)
            l = layout[]
            @test l.title === nothing && !l.pill_round
            @test l.pill.x0 >= last(l.qat).x1 + 12
            path = ctx.shot(joinpath(SHELL_SHOTS, "shell-900x560.png"))
            # The long database name is cut short with "..." and plain status bar stays
            # between it and the right side. No separator stands alone after it.
            layout = Ref{Any}(nothing)
            left_w = Ref(0f0)
            ctx.on_render(w -> begin
                layout[] = UI.status_layout(UI.Box(0, 534, 900, 560), w.scale, UI.text_width,
                    UI.status_texts(app))
                left_w[] = UI.text_width(UI.FONT_REGULAR, 11.5, layout[].left)
            end)
            l = layout[]
            @test endswith(l.left, "...") && 10 + left_w[] <= l.right_x - 10
            img = PNGFiles.load(path)
            bar = rgb255(LIGHT.status_bar)
            plain(x) = all(y -> near(rgb255(img[y, x+1]), bar; tol = 2), 538:557)
            @test !plain(12)   # the left text starts at 10 px
            @test all(plain, ceil(Int, 10 + left_w[]) + 1:floor(Int, l.right_x) - 1)
        end
    end

    # Light and dark shots at 1480 by 920, at scale 1 and 1.5, for the pixel review against
    # the prototype (prototype shots: proto-light.png and so on, made in a browser).
    @testset "shots" begin
        for (theme, tokens, name) in ((THEME_LIGHT, LIGHT, "light"), (THEME_DARK, DARK, "dark")),
                scale in (1f0, 1.5f0)
            path = joinpath(SHELL_SHOTS, "shell-$name" * (scale == 1 ? "" : "-1.5x") * ".png")
            with_project_app(kangaroo(); theme, scale) do ctx, app
                ctx.shot(path)
                scale == 1 || return
                # Toasts and a confirm box, as in proto-toasts-*.png and proto-confirm-*.png.
                te.MouseMove("JuliaMag/left/Data")
                UI.toast!(app, :info, "Channel Math started.";
                    sub = "It runs in the background. Progress is in the Jobs pane.")
                UI.toast!(app, :error, "Import failed"; sub = "Data file not found.",
                    actions = ["Report" => a -> nothing, "Run Again..." => a -> nothing])
                UI.toast!(app, :ok, "Saved")
                ctx.wait_until(() -> time() - last(app.toasts).shown > 2 * UI.TOAST_SLIDE)
                ctx.shot(joinpath(SHELL_SHOTS, "shell-toasts-$name.png"))
                empty!(app.toasts)
                UI.confirm!(app, "Remove Kangaroo Hills 2024?",
                    "The item leaves the project. Its files stay in the folder. It can be undone.";
                    action = "Remove", danger = true, on_yes = a -> nothing)
                ctx.frames(3)
                ctx.shot(joinpath(SHELL_SHOTS, "shell-confirm-$name.png"))
            end
            if scale == 1
                # The backdrop is there at once, at its full strength.
                dimmed = PNGFiles.load(joinpath(SHELL_SHOTS, "shell-confirm-$name.png"))
                a = tokens.backdrop[4]
                blend = rgb255(ntuple(i -> i == 4 ? 1f0 : (1 - a) * tokens.header[i] + a * tokens.backdrop[i], 4))
                @test near(rgb255(dimmed[18, 401]), blend; tol = 2)
            end
            img = PNGFiles.load(path)
            @test size(img) == (920, 1480)
            p(v) = Int(UI.px(scale, v))
            # The colour at device pixel (x, y), counted from 0 as ImGui does.
            at(x, y) = rgb255(img[y+1, x+1])
            # Header, tab strip, ribbon, pane, central area and status bar in their colours.
            @test near(at(p(400), p(17)), rgb255(tokens.header); tol = 1)
            @test near(at(p(700), p(36)), rgb255(tokens.tab_strip); tol = 1)
            @test near(at(p(700), p(100)), rgb255(tokens.ribbon); tol = 1)
            @test near(at(p(700), p(168) - 1), rgb255(tokens.border); tol = 1)   # the ribbon's bottom line
            @test near(at(p(100), p(400)), rgb255(tokens.pane); tol = 1)
            @test near(at(p(700), p(300)), rgb255(tokens.canvas); tol = 1)
            @test near(at(p(700), 920 - p(3)), rgb255(tokens.status_bar); tol = 1)
            # The Project button in the brand colour.
            @test near(at(p(12), p(40)), rgb255(tokens.brand); tol = 1)
        end
    end
end
