using Test, Aqua, JET, JuliaMagUI
import JuliaMagCore
# One scanner for both packages; it lives with the core's tests.
include(joinpath(pkgdir(JuliaMagCore), "test", "support", "consts.jl"))

@testset "quality" begin
    Aqua.test_all(JuliaMagUI)
    JET.test_package(JuliaMagUI; target_modules = (JuliaMagUI,))
    # A second `const` of the same name silently replaces the first (I1: the Jobs cards
    # took the backstage's 18 px gap). Every name is defined once.
    @test duplicate_consts(joinpath(pkgdir(JuliaMagUI), "src", "JuliaMagUI.jl")) == Dict()
end
