using Test, Aqua, JET, JuliaMagCore
# JET exports a `report_text` too; the tests mean the one of JuliaMagCore.
using JuliaMagCore: report_text

@testset "quality" begin
    Aqua.test_all(JuliaMagCore)
    JET.test_package(JuliaMagCore; target_modules = (JuliaMagCore,))
end
