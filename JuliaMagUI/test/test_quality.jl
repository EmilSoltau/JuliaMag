using Test, Aqua, JET, JuliaMagUI

@testset "quality" begin
    Aqua.test_all(JuliaMagUI)
    JET.test_package(JuliaMagUI; target_modules = (JuliaMagUI,))
end
