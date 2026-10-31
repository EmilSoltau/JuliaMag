using Test
import CImGui as ig
import ImGuiTestEngine as te
import PNGFiles
import GLFW
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK, ConfirmDialog, WarningsDialog,
    GettingStartedDialog

const BACKSTAGE_SHOTS = joinpath(@__DIR__, "..", "shots")

# Test engine references of the backstage: the nav and the page body.
nav_ref(name) = "Backstage/nav/" * name
body_ref(name) = "Backstage/body/" * name
recent_ref(folder) = body_ref("recent/" * ref_part(folder))
dialog_button(name) = "//###dialog1/" * name

bs_dialog(app) = isempty(app.ui.dialogs) ? nothing : last(app.ui.dialogs)

# A closed project folder with one database called `name`'s data. Returns the folder.
function closed_project(; name = "Survey", project = "p")
    s = session_with(; name, project)
    folder = s.project.folder
    Core.close_session!(s)
    return folder
end

# The pixel at device point (x, y) of a PNG, as 0-255 RGB.
bs_pixel(img, x, y) = rgb255(img[round(Int, y)+1, round(Int, x)+1])

# Close the window as the user does: the window's close box.
close_window(ctx) = ctx.on_render(w -> GLFW.SetWindowShouldClose(w.handle, true))

window_testset("backstage") do
    mkpath(BACKSTAGE_SHOTS)

    @testset "the Project button opens the backstage; Esc and Back leave it" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.click("JuliaMag/tabs/Project")
            ctx.frames(2)
            @test app.ui.backstage && app.ui.backstage_page === :start
            @test te.ItemExists(nav_ref("Start")) && !te.ItemExists("JuliaMag/tabs/Project")
            ctx.click(nav_ref("New"))
            @test app.ui.backstage_page === :new
            ctx.key("Escape")
            ctx.frames(2)
            @test !app.ui.backstage && te.ItemExists("JuliaMag/tabs/Project")
            ctx.key("Ctrl+O")
            ctx.frames(2)
            @test app.ui.backstage && app.ui.backstage_page === :open
            ctx.click(nav_ref("Back"))
            ctx.frames(2)
            @test !app.ui.backstage
        end
    end

    @testset "shots of every backstage page, light and dark, and at scale 1.5" begin
        folders = [closed_project(project = p) for p in
                   ("Georgetown Infill 2023", "Mt Isa Regional Reprocessing", "Charters Towers Test Lines")]
        gone = joinpath(mktempdir(), "Hodgkinson Basin 2022")
        for theme in (THEME_LIGHT, THEME_DARK), (scale, size, sfx) in ((1f0, (1480, 920), ""), (1.5f0, (1480, 920), "-1.5x"))
            name = theme == THEME_LIGHT ? "light" : "dark"
            with_project_app(kangaroo_data(); theme, scale, size) do ctx, app
                app.config.recent = [realpath(app.session.project.folder); realpath.(folders); gone]
                UI.request!(app, UI.OpenBackstage(:start))
                ctx.wait_until(() -> length(app.ui.bs.recent) == 5; timeout = 10)
                te.MouseMove(nav_ref("Back")); te.MouseMoveToPos(ig.ImVec2(1470, 900))
                ctx.frames(3)
                @test te.ItemExists(recent_ref(gone))
                ctx.shot(joinpath(BACKSTAGE_SHOTS, "backstage-start-$name$sfx.png"))
                for page in (:new, :open, :script, :about)
                    ctx.click(nav_ref(Dict(:new => "New", :open => "Open", :script => "Run Script",
                        :about => "About")[page]))
                    te.MouseMoveToPos(ig.ImVec2(1470, 900))
                    page === :script && ctx.wait_until(() -> app.ui.bs.script !== nothing; timeout = 10)
                    ctx.frames(3)
                    ctx.shot(joinpath(BACKSTAGE_SHOTS, "backstage-$page-$name$sfx.png"))
                end
                ctx.click(nav_ref("Back"))
                UI.request!(app, UI.OpenDialog(:getting_started))
                ctx.wait_until(() -> bs_dialog(app) isa GettingStartedDialog)
                ctx.frames(3)
                ctx.shot(joinpath(BACKSTAGE_SHOTS, "getting-started-$name$sfx.png"))
                ctx.click(dialog_button("Close"))
                ctx.frames(2)
                @test isempty(app.ui.dialogs)
            end
        end
        # The nav is brand purple with white text; the body is the ribbon colour.
        img = PNGFiles.load(joinpath(BACKSTAGE_SHOTS, "backstage-start-light.png"))
        @test near(bs_pixel(img, 5, 500), rgb255(LIGHT.brand))
        @test near(bs_pixel(img, 1400, 500), rgb255(LIGHT.ribbon))
        img = PNGFiles.load(joinpath(BACKSTAGE_SHOTS, "backstage-start-dark.png"))
        @test near(bs_pixel(img, 1400, 500), rgb255(DARK.ribbon))
    end

    @testset "New: a bad name is refused in the form; Create Project opens the new one" begin
        with_test_app() do ctx
            app = ctx.app_state()
            parent = mktempdir()
            app.pick_file = (; kw...) -> (get(kw, :folder, false) ? parent : "")
            UI.request!(app, UI.OpenBackstage(:new))
            ctx.frames(2)
            ctx.click(body_ref("Browse..."))
            ctx.frames(2)
            @test UI.field_text(app.ui.bs.folder_buffer) == parent
            te.ItemClick(body_ref("##name")); te.KeyCharsReplace("a/b")
            ctx.click(body_ref("Create Project"))
            ctx.frames(2)
            @test app.ui.bs.new_problem ==
                  "A folder name cannot have any of these characters: < > : \" / \\ | ? *"
            ctx.shot(joinpath(BACKSTAGE_SHOTS, "backstage-new-error-light.png"))
            @test app.session === nothing && isempty(readdir(parent))
            te.ItemClick(body_ref("##name")); te.KeyCharsReplace("Survey 2024")
            ctx.frames(1)
            @test app.ui.bs.new_problem === nothing   # typing clears it
            ctx.click(body_ref("Create Project"))
            ctx.wait_until(() -> app.session !== nothing; timeout = 10)
            ctx.frames(2)
            @test !app.ui.backstage && app.session.project.name == "Survey 2024"
            @test isdir(joinpath(parent, "Survey 2024"))
            s = app.session
            UI.set_session!(app, nothing)
            Core.close_session!(s)
        end
    end

    @testset "Close on the nav: does nothing with no project; asks while a job runs" begin
        with_test_app() do ctx
            app = ctx.app_state()
            UI.request!(app, UI.OpenBackstage(:open))
            ctx.frames(2)
            ctx.click(nav_ref("Close"))
            ctx.frames(2)
            @test app.ui.backstage && app.ui.backstage_page === :open && app.switching === nothing
        end
        with_tools([gate_tool()]) do
            s = kangaroo()
            with_project_app(s) do ctx, app
                job = Core.run_tool(s, "test.gate")
                ctx.wait_until(() -> UI.running_jobs(app.snap) == 1; timeout = 10)
                UI.request!(app, UI.OpenBackstage(:about))
                ctx.frames(2)
                ctx.click(nav_ref("Close"))
                ctx.wait_until(() -> bs_dialog(app) isa ConfirmDialog; timeout = 5)
                @test app.ui.backstage_page === :start && isopen(s)
                ctx.click(dialog_button("Close Project"))
                ctx.wait_until(() -> app.session === nothing && app.switching === nothing; timeout = 20)
                @test !isopen(s) && Core.status(job) == Core.JOB_CANCELLED
                @test app.ui.backstage && app.ui.backstage_page === :start
            end
        end
    end

    @testset "Open: a folder with no project gives the plain message; the page stays usable" begin
        with_test_app() do ctx
            app = ctx.app_state()
            empty = mktempdir()
            app.pick_file = (; kw...) -> empty
            UI.request!(app, UI.OpenBackstage(:open))
            ctx.frames(2)
            ctx.click(body_ref("Browse for a Project..."))
            ctx.wait_until(() -> !isempty(app.toasts); timeout = 10)
            @test app.toasts[end].text == "This folder has no JuliaMag project."
            @test app.ui.backstage && app.session === nothing && app.switching === nothing
            @test te.ItemExists(body_ref("Browse for a Project..."))
        end
    end

    @testset "Open: a locked project names the user; Open Anyway opens it" begin
        folder = closed_project(project = "Locked")
        other = Core.open_session(folder)
        try
            locked = try
                Core.open_session(folder); nothing
            catch e
                e
            end
            with_test_app() do ctx
                app = ctx.app_state()
                app.pick_file = (; kw...) -> folder
                UI.request!(app, UI.OpenBackstage(:open))
                ctx.frames(2)
                ctx.click(body_ref("Browse for a Project..."))
                ctx.wait_until(() -> bs_dialog(app) isa ConfirmDialog; timeout = 10)
                d = bs_dialog(app)
                @test d.title == "This project is open somewhere else"
                @test occursin(locked.user, d.text) && occursin(locked.host, d.text)
                ctx.frames(3)
                ctx.shot(joinpath(BACKSTAGE_SHOTS, "backstage-locked-light.png"))
                ctx.click(dialog_button("Open Anyway"))
                ctx.wait_until(() -> app.session !== nothing; timeout = 10)
                @test app.session.project.name == "Locked" && !app.ui.backstage
                s = app.session
                UI.set_session!(app, nothing)
                Core.close_session!(s)
            end
        finally
            Core.close_session!(other)
        end
    end

    @testset "opening shows the busy state and greys the shell" begin
        folder = closed_project(project = "Slow")   # its folder is called p
        gate = Channel{Int}(1)
        with_project_app(kangaroo()) do ctx, app
            old = app.session
            try
                UI.submit!(app, "Wait", _ -> take!(gate))   # holds the worker, so the open waits
                UI.open_project!(app, folder)
                ctx.frames(2)
                @test app.switching == "Closing..."
                @test te.ItemExists("###busy/busy")
            finally
                isready(gate) || put!(gate, 1)   # never leave the worker held
            end
            ctx.wait_until(() -> app.session !== nothing && app.session !== old; timeout = 10)
            @test app.switching === nothing && !isopen(old)
            s = app.session
            UI.set_session!(app, nothing)
            Core.close_session!(s)
        end
        # The shot: the worker is held while the open waits.
        gate = Channel{Int}(1)
        with_test_app() do ctx
            app = ctx.app_state()
            try
                UI.submit!(app, "Wait", _ -> take!(gate))
                UI.open_project!(app, folder)
                ctx.frames(3)
                @test app.switching == "Opening p..."   # the folder name
                ctx.shot(joinpath(BACKSTAGE_SHOTS, "busy-opening-light.png"))
            finally
                isready(gate) || put!(gate, 1)
            end
            ctx.wait_until(() -> app.session !== nothing; timeout = 10)
            ctx.frames(2)
            @test !te.ItemExists("###busy/busy")
            s = app.session
            UI.set_session!(app, nothing)
            Core.close_session!(s)
        end
    end

    @testset "closing the window with a running 3 s job asks, then closes and quits" begin
        with_tools([gate_tool()]) do
            s = kangaroo()
            with_project_app(s) do ctx, app
                quits = Ref(0)
                app.quit_hook = a -> (quits[] += 1; nothing)
                job = Core.run_tool(s, "test.gate")
                ctx.wait_until(() -> UI.running_jobs(app.snap) == 1; timeout = 10)
                close_window(ctx)
                ctx.wait_until(() -> bs_dialog(app) isa ConfirmDialog; timeout = 5)
                @test bs_dialog(app).text == "1 job is running. Cancel it and close?"
                @test quits[] == 0 && isopen(s)
                ctx.frames(2)
                ctx.shot(joinpath(BACKSTAGE_SHOTS, "close-jobs-light.png"))
                ctx.click(dialog_button("Close Project"))
                ctx.wait_until(() -> quits[] == 1; timeout = 20)
                @test !isopen(s) && Core.status(job) == Core.JOB_CANCELLED
                @test app.session === nothing
            end
        end
    end

    @testset "a close warning is shown before the app quits" begin
        s = kangaroo()
        Core.push_undo!(s, Core.UndoStep("test step", () -> nothing, () -> nothing, () -> nothing,
            String[]; commit = () -> error("the disk is full")))
        with_project_app(s) do ctx, app
            quits = Ref(0)
            app.quit_hook = a -> (quits[] += 1; nothing)
            close_window(ctx)
            ctx.wait_until(() -> bs_dialog(app) isa WarningsDialog; timeout = 20)
            @test quits[] == 0 && !isopen(s)
            ctx.frames(3)
            ctx.shot(joinpath(BACKSTAGE_SHOTS, "close-warnings-light.png"))
            ctx.click(dialog_button("OK"))
            ctx.wait_until(() -> quits[] == 1; timeout = 5)
        end
    end

    @testset "Settings > Dark changes the tokens and the look" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.click("JuliaMag/tabs/Settings")
            ctx.frames(2)
            light = ctx.shot(joinpath(BACKSTAGE_SHOTS, "settings-light.png"))
            ctx.click("JuliaMag/ribbon/Dark Theme")
            ctx.frames(3)
            @test app.tokens === DARK && app.config.theme == THEME_DARK
            dark = ctx.shot(joinpath(BACKSTAGE_SHOTS, "settings-dark.png"))
            @test near(bs_pixel(PNGFiles.load(light), 1100, 120), rgb255(LIGHT.ribbon))
            @test near(bs_pixel(PNGFiles.load(dark), 1100, 120), rgb255(DARK.ribbon))
            ctx.wait_until(() -> app.queue.pending == 0)
            @test UI.load_config(app.config_dir)[1].theme == THEME_DARK
            # The Defaults combos and Show Tabs open their menus.
            ctx.click("JuliaMag/ribbon/Distance units")
            ctx.frames(2)
            ctx.shot(joinpath(BACKSTAGE_SHOTS, "settings-units-dark.png"))
            ctx.click("//###menu/Kilometres")
            ctx.frames(2)
            @test app.config.distance_units == "km"
        end
    end

    @testset "hiding the Coordinates tab survives a restart" begin
        dir = mktempdir()
        with_project_app(kangaroo(); config_dir = dir) do ctx, app
            ctx.click("JuliaMag/tabs/Settings")
            ctx.click("JuliaMag/ribbon/Show Tabs")
            ctx.frames(2)
            ctx.shot(joinpath(BACKSTAGE_SHOTS, "settings-tabs-light.png"))
            ctx.click("//###menu/Coordinates")
            ctx.frames(2)
            @test app.ui.menu !== nothing   # the menu stays open for more changes
            @test "Coordinates" in app.config.hidden_tabs
            ctx.key("Escape")
            ctx.frames(2)
            @test !te.ItemExists("JuliaMag/tabs/Coordinates")
            ctx.wait_until(() -> app.queue.pending == 0)
        end
        with_project_app(kangaroo(); config_dir = dir) do ctx, app
            ctx.frames(2)
            @test !te.ItemExists("JuliaMag/tabs/Coordinates")
            @test te.ItemExists("JuliaMag/tabs/Database Tools")
        end
    end

    @testset "Run Script: a script that renames an item; the reopened project shows it" begin
        s = kangaroo()
        folder = s.project.folder
        id = only(s.project.items).id
        script = joinpath(mktempdir(), "rename.jl")
        write(script, """
            using JuliaMagCore
            s = open_session($(repr(folder)))
            try
                rename_item!(s, $(repr(id)), "Renamed by a script")
                println("renamed ", $(repr(id)))
            finally
                close_session!(s)
            end
            """)
        with_project_app(s) do ctx, app
            app.pick_file = (; kw...) -> script
            UI.request!(app, UI.OpenBackstage(:script))
            ctx.wait_until(() -> app.ui.bs.script !== nothing; timeout = 10)
            @test occursin("open_session", app.ui.bs.script)
            ctx.click(body_ref("Run Script..."))
            ctx.wait_until(() -> bs_dialog(app) isa ConfirmDialog)
            @test bs_dialog(app).text ==
                  "Running a script closes this project, runs the script, then opens the project again."
            ctx.click(dialog_button("Run Script"))
            ctx.wait_until(() -> app.ui.bs.output !== nothing && app.session !== nothing &&
                                 app.switching === nothing; timeout = 30)
            @test app.session !== s && !isopen(s)
            @test occursin("renamed $id", app.ui.bs.output)
            ctx.wait_until(() -> app.snap !== nothing && app.snap.items[1].name == "Renamed by a script";
                timeout = 10)
            @test app.ui.backstage && app.ui.backstage_page === :script
            ctx.frames(3)
            ctx.shot(joinpath(BACKSTAGE_SHOTS, "backstage-script-output-light.png"))
            # A script that fails: the error shows in the output box, and the project opens again.
            write(script, "println(\"first\")\nerror(\"the script broke\")\n")
            ctx.click(body_ref("Run Script..."))
            ctx.wait_until(() -> bs_dialog(app) isa ConfirmDialog)
            ctx.click(dialog_button("Run Script"))
            ctx.wait_until(() -> app.ui.bs.output_failed && app.session !== nothing &&
                                 app.switching === nothing; timeout = 30)
            @test occursin("the script broke", app.ui.bs.output)
            s2 = app.session
            UI.set_session!(app, nothing)
            Core.close_session!(s2)
        end
    end

    @testset "the Help ribbon, as the prototype" begin
        with_project_app(kangaroo()) do ctx, app
            ctx.click("JuliaMag/tabs/Help")
            ctx.frames(2)
            ctx.shot(joinpath(BACKSTAGE_SHOTS, "help-light.png"))
            ctx.click("JuliaMag/ribbon/About JuliaMag")
            ctx.frames(2)
            @test app.ui.backstage && app.ui.backstage_page === :about
        end
    end

    @testset "one Esc closes only the top layer: a dialog over the backstage" begin
        with_project_app(kangaroo()) do ctx, app
            UI.request!(app, UI.OpenBackstage(:start))
            ctx.frames(2)
            UI.request!(app, UI.OpenDialog(:getting_started))
            ctx.wait_until(() -> bs_dialog(app) isa GettingStartedDialog)
            ctx.frames(2)
            ctx.key("Escape")
            ctx.frames(2)
            @test isempty(app.ui.dialogs) && app.ui.backstage
            ctx.key("Ctrl+K")                  # the search too
            ctx.frames(2)
            @test app.ui.search !== nothing
            ctx.key("Escape")
            ctx.frames(2)
            @test app.ui.search === nothing && app.ui.backstage
            ctx.key("Escape")                  # now the backstage
            ctx.frames(2)
            @test !app.ui.backstage
        end
    end

    @testset "a script that prints 200,000 lines: the output is cut and frames stay fast" begin
        script = joinpath(mktempdir(), "chatty.jl")
        write(script, "for k in 1:200_000; println(\"line \", k); end\n")
        with_test_app() do ctx
            app = ctx.app_state()
            app.pick_file = (; kw...) -> script
            UI.request!(app, UI.OpenBackstage(:script))
            ctx.frames(2)
            ctx.click(body_ref("Run Script..."))   # no project: it runs at once
            ctx.wait_until(() -> app.ui.bs.output !== nothing; timeout = 60)
            ctx.frames(5)
            bs = app.ui.bs
            @test length(bs.output_lines) == UI.OUTPUT_MAX_LINES + 1
            @test first(bs.output_lines) == "Earlier output was cut."
            times = Int[]
            for _ in 1:10
                ctx.frames(1)
                push!(times, app.draw_ns)
            end
            @test minimum(times) < 20_000_000   # 20 ms
            ctx.shot(joinpath(BACKSTAGE_SHOTS, "backstage-script-chatty-light.png"))
        end
    end
end
