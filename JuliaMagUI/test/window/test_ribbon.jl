using Test
import CImGui as ig
import ImGuiTestEngine as te
import PNGFiles
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: LIGHT, DARK, THEME_LIGHT, THEME_DARK

const RIBBON_SHOTS = joinpath(@__DIR__, "..", "shots")

"""
    with_wide_tools(f, n)

Register `n` test tools with long names in a group "Wide test" of the Database tab, run
`f()`, and take them out again. The real Database tab fits in 900 px; these make it wider.
"""
function with_wide_tools(f, n::Integer)
    ids = ["test.wide.$k" for k in 1:n]
    for (k, id) in enumerate(ids)
        Core.register_tool!(Core.ToolSpec(id, "Wide test tool number $k", "A test tool.", "math",
            [Core.Place("Database", "Wide test")], ["database" => Core.ITEM_DATABASE],
            Core.SettingSpec[], :quick, (s, ins, st, progress, report) -> nothing))
    end
    try
        return f()
    finally
        foreach(Core.unregister_tool!, ids)
    end
end

"""
    request_log() -> (log, app_ref, hook)

`hook` is an `extra_ui` that copies the requests of each frame of the app in `app_ref` into
`log`. Requests live for one frame (nobody handles a tool request before Task 13), so a
test reads the log.
"""
function request_log()
    log = Any[]
    app = Ref{Any}(nothing)
    hook = w -> (a = app[]; a === nothing || append!(log, a.ui.requests); nothing)
    return log, app, hook
end

exists(ref) = te.ItemExists(ref)

window_testset("ribbon") do
    mkpath(RIBBON_SHOTS)

    @testset "a big button pushes its tool request; a disabled one shows why" begin
        log, app_ref, hook = request_log()
        with_project_app(kangaroo(); extra_ui = hook) do ctx, app
            app_ref[] = app
            ctx.click("JuliaMag/tabs/Database Tools")
            ctx.click("JuliaMag/ribbon/Channel Math")
            ctx.wait_until(() -> any(r -> r isa UI.OpenToolDialog, log); timeout = 5)
            r = only(filter(r -> r isa UI.OpenToolDialog, log))
            @test r.id == "database.channel_math" && r.item == app.ui.current_db != ""

            # No grid in the project: Grid Statistics is greyed, does nothing, and says why.
            ctx.click("JuliaMag/tabs/Grid and Image")
            empty!(log)
            ctx.click("JuliaMag/ribbon/Grid Statistics")
            ctx.frames(2)
            @test isempty(log)
            te.MouseMove("JuliaMag/left/Data")   # after a click the tooltip waits for the mouse to leave
            ctx.frames(1)
            te.MouseMove("JuliaMag/ribbon/Grid Statistics")
            ctx.wait_until(() -> app.ui.tip !== nothing; timeout = 5)
            tip = app.ui.tip
            @test tip.title == "Grid Statistics" && tip.reason == "Import a grid first." &&
                  tip.id == "grid.statistics"
        end
    end

    @testset "the split button arrow opens a menu of formats" begin
        log, app_ref, hook = request_log()
        with_project_app(kangaroo(); extra_ui = hook) do ctx, app
            app_ref[] = app
            @test app.ui.tab == "Database"
            arrow = "JuliaMag/ribbon/More import formats"
            ctx.click(arrow)
            ctx.frames(1)
            m = app.ui.menu
            @test m isa UI.OpenMenu && m.owner == "import.database"
            @test [it.label for it in m.items] == ["Geosoft XYZ...", "CSV and text..."]
            @test exists("//###menu/Geosoft XYZ...") && exists("//###menu/CSV and text...")
            # A row runs its importer command and closes the menu.
            ctx.click("//###menu/CSV and text...")
            ctx.wait_until(() -> any(r -> r isa UI.OpenImport, log); timeout = 5)
            @test only(filter(r -> r isa UI.OpenImport, log)).importer_id == "import.csv"
            @test app.ui.menu === nothing

            # A second click on the arrow closes it; so do Esc and a click outside.
            ctx.click(arrow)
            @test UI.menu_open(app, "import.database")
            ctx.click(arrow)
            ctx.frames(1)
            @test app.ui.menu === nothing
            ctx.click(arrow)
            ctx.key("Escape")
            ctx.frames(1)
            @test app.ui.menu === nothing
            ctx.click(arrow)
            ctx.click("JuliaMag/left/Data")
            ctx.frames(1)
            @test app.ui.menu === nothing
            # The menu goes when its button goes (another tab).
            ctx.click(arrow)
            ctx.click("JuliaMag/tabs/Coordinates")
            ctx.frames(2)
            @test app.ui.menu === nothing

            # In a collapsed ribbon's peek the menu works too: its click keeps the peek.
            ctx.key("Ctrl+F1")
            ctx.click("JuliaMag/tabs/Database")
            @test app.ui.ribbon_peek
            ctx.click("Ribbon/ribbon/More import formats")
            ctx.frames(1)
            @test UI.menu_open(app, "import.database")
            empty!(log)
            ctx.click("//###menu/Geosoft XYZ...")
            ctx.wait_until(() -> any(r -> r isa UI.OpenImport, log); timeout = 5)
            @test only(filter(r -> r isa UI.OpenImport, log)).importer_id == "import.geosoft_xyz"
            # Esc closes the open menu first, then the peek.
            ctx.click("Ribbon/ribbon/More import formats")
            ctx.key("Escape")
            ctx.frames(1)
            @test app.ui.menu === nothing && app.ui.ribbon_peek
            ctx.key("Escape")
            ctx.frames(1)
            @test !app.ui.ribbon_peek
            ctx.key("Ctrl+F1")
        end
    end

    @testset "the Acts on chooser sets the current database" begin
        s = kangaroo()
        second = add_test_database!(s, ["MAG" => [1.0, 2.0]])
        with_project_app(s) do ctx, app
            first_db = app.ui.current_db
            @test first_db != second
            ctx.click("JuliaMag/ribbon/Active database")
            ctx.frames(1)
            m = app.ui.menu
            @test m isa UI.OpenMenu && [it.checked for it in m.items] == [true, false]
            ctx.click("//###menu/$second")
            ctx.frames(1)
            @test app.ui.current_db == second && app.ui.menu === nothing
            @test UI.chooser_note(app) == "1 line, 1 channel"
        end
    end

    @testset "at 900 px the arrows and the wheel scroll the ribbon" begin
        with_wide_tools(10) do
            with_project_app(kangaroo(); size = (900, 560)) do ctx, app
                ui = app.ui
                left, right = "JuliaMag/ribbon/Scroll the ribbon left", "JuliaMag/ribbon/Scroll the ribbon right"
                ctx.frames(2)
                @test exists(right) && !exists(left) && ui.ribbon_scroll == 0
                ctx.click(right)
                ctx.frames(1)
                step = 0.6f0 * (900 - 16)
                @test ui.ribbon_scroll ≈ step
                @test exists(left)

                # The wheel over the ribbon scrolls it, 100 px a step; elsewhere it does not.
                te.MouseMoveToPos((450f0, 120f0))
                te.MouseWheelY(1f0)
                ctx.frames(2)
                @test ui.ribbon_scroll ≈ step - 100
                te.MouseWheelY(-2f0)
                ctx.frames(2)
                @test ui.ribbon_scroll ≈ step + 100
                te.MouseMoveToPos((450f0, 300f0))
                te.MouseWheelY(1f0)
                ctx.frames(2)
                @test ui.ribbon_scroll ≈ step + 100
                path = ctx.shot(joinpath(RIBBON_SHOTS, "ribbon-900-scrolled.png"))

                # At the end the right arrow goes; another tab starts at 0.
                for _ in 1:20
                    ctx.frames(2)
                    exists(right) || break
                    ctx.click(right)
                end
                @test !exists(right) && exists(left) && ui.ribbon_scroll > step
                ctx.click("JuliaMag/tabs/Help")
                ctx.frames(1)
                @test ui.ribbon_scroll == 0
                ctx.click("JuliaMag/tabs/Database")
                ctx.frames(1)
                @test ui.ribbon_scroll == 0 && exists(right)

                # The arrow is drawn over the groups in the ribbon colour, with a border.
                img = PNGFiles.load(path)
                at(x, y) = rgb255(img[y+1, x+1])
                @test near(at(8, 120), rgb255(LIGHT.border); tol = 2)            # left arrow edge
                @test near(at(10, 90), rgb255(LIGHT.ribbon); tol = 2)            # inside it
                @test near(at(900 - 9, 120), rgb255(LIGHT.border); tol = 2)      # right arrow edge
            end
        end
    end

    # Every tab in light and dark, at scale 1 and 1.5, for the pixel review against the
    # prototype (proto-ribbon-<tab>-<theme>.png, made in a browser).
    @testset "shots" begin
        tabs = ["Database", "Database Tools", "Coordinates", "Grid and Image", "Settings", "Help"]
        slug(t) = replace(lowercase(t), " " => "-")
        for (theme, tokens, name) in ((THEME_LIGHT, LIGHT, "light"), (THEME_DARK, DARK, "dark")),
                scale in (1f0, 1.5f0)
            sfx = scale == 1 ? "" : "-1.5x"
            with_project_app(kangaroo(); theme, scale) do ctx, app
                te.MouseMoveToPos((700f0, 600f0))   # away from the ribbon
                for tab in tabs
                    ctx.click("JuliaMag/tabs/$tab")
                    te.MouseMoveToPos((700f0, 600f0))
                    ctx.frames(2)
                    ctx.shot(joinpath(RIBBON_SHOTS, "ribbon-$(slug(tab))-$name$sfx.png"))
                end
                scale == 1 || return
                # Hover and the open menu.
                ctx.click("JuliaMag/tabs/Database")
                te.MouseMove("JuliaMag/ribbon/Select All Lines")
                ctx.shot(joinpath(RIBBON_SHOTS, "ribbon-hover-$name.png"))
                ctx.click("JuliaMag/ribbon/More import formats")
                te.MouseMove("//###menu/Geosoft XYZ...")
                ctx.frames(1)
                ctx.shot(joinpath(RIBBON_SHOTS, "ribbon-menu-$name.png"))
                ctx.key("Escape")
                ctx.click("JuliaMag/ribbon/Active database")
                te.MouseMoveToPos((700f0, 600f0))
                ctx.frames(1)
                ctx.shot(joinpath(RIBBON_SHOTS, "ribbon-chooser-$name.png"))
                ctx.key("Escape")
            end
            scale == 1 || continue
            img = PNGFiles.load(joinpath(RIBBON_SHOTS, "ribbon-database-$name.png"))
            at(x, y) = rgb255(img[y+1, x+1])
            # The separator after the chooser group (8 + 178 + 7) and the split divider.
            @test near(at(193, 111), rgb255(tokens.border); tol = 2)
            @test near(at(194, 111), rgb255(tokens.ribbon); tol = 2)
            @test near(at(202 + 50, 106), rgb255(tokens.border); tol = 2)
            # The combo box border and fill.
            @test near(at(12, 102), rgb255(tokens.input_border); tol = 2)
            # The checked Light Theme button on the Settings tab (only in the light theme).
            set = PNGFiles.load(joinpath(RIBBON_SHOTS, "ribbon-settings-$name.png"))
            fill = rgb255(set[66 + 5 + 60 + 1, 8 + 4 + 1])
            @test near(fill, rgb255(theme == THEME_LIGHT ? tokens.checked : tokens.ribbon); tol = 2)
        end
    end
end
