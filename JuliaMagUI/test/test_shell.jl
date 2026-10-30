using Test
import JuliaMagCore as Core
import JuliaMagUI as UI
using JuliaMagUI: Box, pane_width, shell_layout, header_layout, tab_layout, toast_layout, Toast,
    status_texts, software_renderer, central_state, font_metrics, FONT_REGULAR, FONT_SEMIBOLD,
    BUNDLED_FONTS

# Text widths without fonts: 7 px per character at scale 1.
fake_measure(role, size, text) = 7f0 * length(text)
fake_wrap(role, size, text, max_width) = begin
    lines = String[]
    line = ""
    for word in split(text)
        trial = isempty(line) ? String(word) : line * " " * word
        if isempty(line) || fake_measure(role, size, trial) <= max_width
            line = trial
        else
            push!(lines, line)
            line = String(word)
        end
    end
    push!(lines, line)
    lines
end

@testset "shell" begin
    @testset "pane widths from the settings are clamped" begin
        @test pane_width(300, (200, 480), 272) == 300f0
        @test pane_width(-5, (200, 480), 272) == 200f0
        @test pane_width(1e6, (200, 480), 272) == 480f0
        @test pane_width(NaN, (200, 480), 272) == 272f0
        @test pane_width(Inf32, (200, 480), 272) == 272f0
        @test pane_width(true, (200, 480), 272) == 272f0   # a Bool in a hand-edited file
        @test pane_width("wide", (200, 480), 272) == 272f0
    end

    @testset "shell layout" begin
        l = shell_layout(0, 0, 1480, 920, 1, 272f0, false)
        @test l.header == Box(0, 0, 1480, 34) && l.tabs == Box(0, 34, 1480, 66)
        @test l.ribbon == Box(0, 66, 1480, 168) && l.docked
        @test l.left == Box(0, 168, 272, 894) && l.center == Box(272, 168, 1480, 894)
        @test l.status == Box(0, 894, 1480, 920)
        # Collapsed: the main row starts under the tab strip; the peek floats in the same place.
        c = shell_layout(0, 0, 1480, 920, 1, 272f0, true)
        @test !c.docked && c.left.y0 == 66 && c.ribbon == l.ribbon
        # Every size scales; a bad width gives the default.
        h = shell_layout(0, 0, 1480, 920, 1.5, NaN32, false)
        @test h.header.y1 == 51 && h.tabs.y1 == 99 && h.ribbon.y1 == 252 && h.status.y0 == 881
        @test h.left.x1 == 408
        @test shell_layout(0, 0, 1480, 920, 1, 1f4, false).left.x1 == 480
    end

    @testset "header layout" begin
        title = "Kangaroo Hills 2024"
        l = header_layout(Box(0, 0, 1480, 34), 1, fake_measure, title, 5)
        @test l.logo == Box(10, 5, 34, 29) && l.name_x == 42
        @test first(l.qat) == Box(42 + 56 + 12, 6, 136, 28) && length(l.qat) == 5
        @test l.pill == Box(1222, 5, 1470, 29) && !l.pill_round
        @test l.title !== nothing
        @test (l.title.x0 + l.title.x1) / 2 ≈ 740 atol = 1
        # A long title does not fit at 900 px: it is dropped, and the pill keeps clear of
        # the toolbar.
        long = "Kangaroo Hills 2024 aeromagnetic survey, final located data"
        n = header_layout(Box(0, 0, 900, 34), 1, fake_measure, long, 5)
        @test n.title === nothing && n.pill.x0 > last(n.qat).x1
        @test header_layout(Box(0, 0, 1480, 34), 1, fake_measure, long, 5).title !== nothing
        # Narrow (a big scale on a small window): the pill shrinks, then becomes round.
        for width in (900, 700, 520, 400)
            m = header_layout(Box(0, 0, width, 34), 1.5, fake_measure, title, 5)
            @test m.pill.x0 >= last(m.qat).x1 + 18 || m.pill_round
            m.pill_round && @test UI.width(m.pill) == 39
        end
        @test UI.width(header_layout(Box(0, 0, 900, 34), 1.5, fake_measure, title, 5).pill) == 372
        shrunk = header_layout(Box(0, 0, 700, 34), 1.5, fake_measure, title, 5)
        @test !shrunk.pill_round && 225 <= UI.width(shrunk.pill) < 372
        @test header_layout(Box(0, 0, 400, 34), 1.5, fake_measure, title, 5).pill_round
        @test header_layout(Box(0, 0, 1480, 34), 1, fake_measure, "", 5).title === nothing
    end

    @testset "tab layout" begin
        tabs = ["Database", "Database Tools", "Coordinates"]
        l = tab_layout(Box(0, 34, 1480, 66), 1, fake_measure, tabs, ["Settings", "Help"])
        @test l.project == Box(8, 37, 8 + 49 + 26, 63)
        @test first(l.tabs) == ("Database" => Box(91, 34, 91 + 56 + 22, 66))
        @test [first(t) for t in l.tabs] == tabs
        @test l.chevron == Box(1448, 38, 1472, 62)
        help = last(l.pinned)
        @test first(help) == "Help" && last(help).x1 == 1442
        @test last(first(l.pinned)).x1 == last(help).x0 - 2
        # Tabs that do not fit before the pinned tabs are left out, never drawn over them.
        many = ["Tab $k" for k in 1:40]
        m = tab_layout(Box(0, 34, 900, 66), 1, fake_measure, many, ["Settings", "Help"])
        @test length(m.tabs) < 40 && last(last(m.tabs)).x1 <= last(first(m.pinned)).x0
    end

    @testset "toast layout" begin
        bw = label -> 7f0 * length(label) + 18
        plain = toast_layout(Toast(:ok, "Saved"), 1, fake_measure, fake_wrap, bw)
        @test plain.height == 40 && plain.width == 2 + 12 + 16 + 8 + 35 + 8 + 22 + 10
        sub = toast_layout(Toast(:info, "Done"; sub = "It ran."), 1, fake_measure, fake_wrap, bw)
        @test sub.height == round(2 + 16 + 17.5 + 16.1)
        acts = toast_layout(Toast(:error, "Failed"; sub = "No file.",
            actions = ["Report" => a -> nothing, "Run Again..." => a -> nothing]), 1, fake_measure,
            fake_wrap, bw)
        @test acts.height == round(2 + 16 + 17.5 + 16.1 + 6 + 22) && acts.action_widths == [60f0, 102f0]
        # Long text wraps: at most 380 px wide.
        long = toast_layout(Toast(:warn, "word "^80), 1, fake_measure, fake_wrap, bw)
        @test long.width <= 380 && length(long.lines) > 1
        @test toast_layout(Toast(:warn, "word "^80), 1.5, fake_measure, fake_wrap, bw).width <= 570
    end

    @testset "status bar texts" begin
        @test software_renderer("llvmpipe (LLVM 17.0.6, 256 bits)")
        @test software_renderer("softpipe") && software_renderer("Microsoft Basic Render Driver Software")
        @test !software_renderer("D3D12 (NVIDIA GeForce RTX 3060)") && !software_renderer("")
        @test UI.jobs_text(0) == "No jobs running" && UI.jobs_text(1) == "1 job running" &&
              UI.jobs_text(2) == "2 jobs running"
        with_app(test_app_state(nothing)) do app
            st = status_texts(app)
            @test st.database == "No database" && st.selected == "" && st.running == 0
            @test st.busy === nothing && !st.software
        end
        with_app(app_with_database()) do app
            st = status_texts(app)
            @test st.database == "$(app.ui.current_db): 1 line, 2 channels"
            @test st.selected == "Selected lines: 1 of 1"
            app.busy = "Undo"
            @test status_texts(app).busy == "Undo"
        end
        with_app(test_app_state(session_with(lines = 60, channels = 24, name = "Kangaroo Hills"))) do app
            refresh_now!(app)
            UI.sync_current_db!(app)   # the first database becomes current
            @test status_texts(app).database == "Kangaroo Hills: 60 lines, 24 channels"
            @test status_texts(app).selected == "Selected lines: 60 of 60"
        end
    end

    @testset "central empty state" begin
        with_app(test_app_state(nothing)) do app
            st = central_state(app)
            @test st.title == "Welcome to JuliaMag" && st.primary
            @test last.(st.buttons) == ["project.new", "project.open"]
        end
        with_app(test_app_state(fresh_session())) do app
            refresh_now!(app)
            st = central_state(app)
            @test st.lines == ["Import line data or a grid to start."]
            @test last.(st.buttons) == ["import.database", "import.grid"]
        end
        with_app(app_with_database()) do app
            @test central_state(app).lines[1] == "No view is open." && isempty(central_state(app).buttons)
        end
    end

    @testset "font metrics" begin
        ratio, ascent = font_metrics(BUNDLED_FONTS.regular)
        @test ratio ≈ (1984 + 494) / 2048 && ascent ≈ 1984 / (1984 + 494)
        @test font_metrics(BUNDLED_FONTS.mono)[1] ≈ (1705 + 615) / 2048
        @test font_metrics("/no/such/font.ttf") == (1f0, 0.8f0)
        mktempdir() do dir
            junk = joinpath(dir, "junk.ttf")
            write(junk, "not a font")
            @test font_metrics(junk) == (1f0, 0.8f0)
        end
    end

    @testset "dialog stack" begin
        with_app(test_app_state(nothing)) do app
            UI.pop_dialog!(app)   # nothing open: nothing happens
            yes = Ref(0)
            d = UI.confirm!(app, "Remove?", "It can be undone."; action = "Remove", danger = true,
                on_yes = a -> (yes[] += 1))
            @test app.ui.dialogs == Any[d] && d.danger && d.action == "Remove"
            UI.pop_dialog!(app)
            @test isempty(app.ui.dialogs) && yes[] == 0
        end
    end

    @testset "current database follows the snapshot" begin
        with_app(app_with_database()) do app
            id = app.ui.current_db
            app.ui.current_db = "db-99"
            UI.sync_current_db!(app)
            @test app.ui.current_db == id
        end
    end
end
