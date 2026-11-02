using Test, Aqua, JET, JuliaMagCore
# JET exports a `report_text` too; the tests mean the one of JuliaMagCore.
using JuliaMagCore: report_text
include(joinpath(@__DIR__, "support", "consts.jl"))

@testset "quality" begin
    Aqua.test_all(JuliaMagCore)
    JET.test_package(JuliaMagCore; target_modules = (JuliaMagCore,))
    # A second `const` of the same name silently replaces the first. Every name is
    # defined once.
    @test duplicate_consts(joinpath(pkgdir(JuliaMagCore), "src", "JuliaMagCore.jl")) == Dict()
    # The scanner itself finds a name defined twice across an include.
    mktempdir() do dir
        write(joinpath(dir, "main.jl"), "module M\nconst A = 1\ninclude(\"b.jl\")\nf() = (B = 2)\nend\n")
        write(joinpath(dir, "b.jl"), "const B, C = 1, 2\n@static if true\n    const A = 2\nend\n")
        @test duplicate_consts(joinpath(dir, "main.jl")) == Dict(:A => ["main.jl:2", "b.jl:3"])
    end
end
