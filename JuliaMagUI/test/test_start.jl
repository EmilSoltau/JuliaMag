# The install check of bin/start.jl (bin/packages.jl).
include(joinpath(@__DIR__, "..", "..", "bin", "packages.jl"))

@testset "start: the install check" begin
    @testset "the app's own environment is complete" begin
        @test missing_packages(Base.active_project()) == String[]
    end

    @testset "a package without artifacts misses none" begin
        mktempdir() do dir
            @test missing_artifacts(dir) == String[]
        end
    end

    @testset "an artifact the depot does not have is reported" begin
        mktempdir() do dir
            write(joinpath(dir, "Artifacts.toml"), """
                [data]
                git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"
                    [[data.download]]
                    url = "https://example.invalid/data.tar.gz"
                    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
                """)
            @test missing_artifacts(dir) == ["data"]
        end
    end

    @testset "a half install makes the package count as missing" begin
        mktempdir() do dir
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "src", "Half.jl"), "module Half end\n")
            write(joinpath(dir, "Artifacts.toml"), """
                [data]
                git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"
                    [[data.download]]
                    url = "https://example.invalid/data.tar.gz"
                    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
                """)
            uuid = "11111111-2222-3333-4444-555555555555"
            write(joinpath(dir, "Project.toml"), "name = \"Half\"\nuuid = \"$uuid\"\n")
            env = joinpath(dir, "env")
            mkpath(env)
            write(joinpath(env, "Project.toml"), "[deps]\nHalf = \"$uuid\"\n")
            write(joinpath(env, "Manifest.toml"), """
                manifest_format = "2.0"
                [[deps.Half]]
                uuid = "$uuid"
                path = ".."
                version = "0.1.0"
                """)
            @test missing_packages(joinpath(env, "Project.toml")) == ["Half"]
        end
    end
end
