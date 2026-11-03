using Test
using JuliaMagUI: AppConfig, load_config, save_config, add_recent!, config_dir,
    system_dark, THEME_LIGHT, THEME_DARK, THEME_SYSTEM, command_says_dark

@testset "config" begin
    @testset "save and load" begin
        withenv("JULIAMAG_CONFIG_DIR" => mktempdir()) do
            c, err = load_config()
            @test err === nothing && c.theme == THEME_SYSTEM
            @test c.window == (0, 0, 1480, 920) && c.left_width == 272f0 && c.right_width == 300f0
            @test c.distance_units == "m" && c.grid_colours == "geosoft" && c.temp_folder == ""
            @test !c.open_last && !c.software_rendering && !c.ribbon_collapsed
            c.theme = THEME_DARK
            add_recent!(c, pwd())
            c.hidden_tabs = ["Jobs"]
            c.advanced_open = ["coordinates.reproject"]
            c.window = (10, 20, 1200, 700)
            c.left_width = 300f0
            c.distance_units = "ft"
            @test c.last_folder == ""
            c.last_folder = "/data/surveys"
            save_config(c)
            c2, err2 = load_config()
            @test err2 === nothing
            @test c2.theme == THEME_DARK && c2.recent == [realpath(pwd())]
            @test c2.hidden_tabs == ["Jobs"] && c2.advanced_open == ["coordinates.reproject"]
            @test c2.window == (10, 20, 1200, 700) && c2.left_width == 300f0
            @test c2.distance_units == "ft" && c2.last_folder == "/data/surveys"
            # No temp file is left behind.
            @test readdir(config_dir()) == ["settings.json"]
        end
    end

    @testset "broken files" begin
        withenv("JULIAMAG_CONFIG_DIR" => mktempdir()) do
            write(joinpath(config_dir(), "settings.json"), "{broken")
            c3, err3 = load_config()
            @test c3.theme == THEME_SYSTEM && err3 isa String
            write(joinpath(config_dir(), "settings.json"), """{"theme": "purple"}""")
            c4, err4 = load_config()
            @test c4.theme == THEME_SYSTEM && err4 isa String
            write(joinpath(config_dir(), "settings.json"), """{"distance_units": "miles"}""")
            c5, err5 = load_config()
            @test c5.distance_units == "m" && err5 isa String
            write(joinpath(config_dir(), "settings.json"), "[1, 2]")
            c6, err6 = load_config()
            @test c6.theme == THEME_SYSTEM && err6 isa String
        end
    end

    @testset "missing keys use the defaults" begin
        withenv("JULIAMAG_CONFIG_DIR" => mktempdir()) do
            write(joinpath(config_dir(), "settings.json"), """{"theme": "light"}""")
            c, err = load_config()
            @test err === nothing && c.theme == THEME_LIGHT && c.window == (0, 0, 1480, 920)
        end
    end

    @testset "save creates the folder" begin
        dir = joinpath(mktempdir(), "a", "b")
        save_config(AppConfig(), dir)
        @test isfile(joinpath(dir, "settings.json"))
    end

    @testset "recent folders" begin
        c = AppConfig()
        a, b = mktempdir(), mktempdir()
        add_recent!(c, a); add_recent!(c, b); add_recent!(c, a)
        @test c.recent == [realpath(a), realpath(b)]
        folders = [mktempdir() for _ in 1:12]
        foreach(f -> add_recent!(c, f), folders)
        @test length(c.recent) == 10 && c.recent[1] == realpath(folders[end])
    end

    @testset "config_dir" begin
        withenv("JULIAMAG_CONFIG_DIR" => "/x/y") do
            @test config_dir() == "/x/y"
        end
        if Sys.isunix()
            withenv("JULIAMAG_CONFIG_DIR" => nothing, "XDG_CONFIG_HOME" => "/xdg") do
                @test config_dir() == "/xdg/juliamag"
            end
        end
    end

    @testset "system_dark reads the theme command's answer" begin
        # A stand-in for the command, so the test does not depend on this machine's theme.
        answer(out) = (cmd, is_dark) -> is_dark(out)
        if Sys.islinux()
            @test system_dark(answer("'prefer-dark'\n"))
            @test !system_dark(answer("'default'\n"))
        elseif Sys.iswindows()
            @test system_dark(answer("    AppsUseLightTheme    REG_DWORD    0x0\n"))
            @test !system_dark(answer("    AppsUseLightTheme    REG_DWORD    0x1\n"))
        end
        @test !system_dark((cmd, is_dark) -> false)
    end

    @testset "command_says_dark never hangs or throws" begin
        @test !command_says_dark(`juliamag-no-such-command-xyz`, _ -> true)
        if Sys.isunix()
            @test command_says_dark(`echo dark`, out -> occursin("dark", out))
            @test !command_says_dark(`false`, _ -> true)
            t = @elapsed r = command_says_dark(`sleep 20`, _ -> true; timeout = 0.5)
            @test !r && t < 5
            # One that ignores the request to stop is killed and waited for.
            t = @elapsed r = command_says_dark(`sh -c 'trap "" TERM; sleep 20'`, _ -> true; timeout = 0.5)
            @test !r && t < 5
        end
    end

    @testset "bad widths and window sizes are refused" begin
        withenv("JULIAMAG_CONFIG_DIR" => mktempdir()) do
            for bad in ("""{"left_width": true}""", """{"right_width": -5}""", """{"left_width": 0}""",
                    """{"window": [0, 0, true, 700]}""", """{"window": [0, 0, 0, 700]}""",
                    """{"window": [0, 0, 1200]}""", """{"window": [0, 0, 1200.5, 700]}""")
                write(joinpath(config_dir(), "settings.json"), bad)
                c, err = load_config()
                @test err isa String && c.left_width == 272f0 && c.window == (0, 0, 1480, 920)
            end
            write(joinpath(config_dir(), "settings.json"), """{"window": [-1600, 20, 1200, 700], "left_width": 300.5}""")
            c, err = load_config()
            @test err === nothing && c.window == (-1600, 20, 1200, 700) && c.left_width == 300.5f0
        end
    end
end
