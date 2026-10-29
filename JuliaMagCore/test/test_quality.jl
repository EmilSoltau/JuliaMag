using Test, Aqua, JET, JuliaMagCore

@testset "quality" begin
    Aqua.test_all(JuliaMagCore)
    JET.test_package(JuliaMagCore; target_modules = (JuliaMagCore,))
end
