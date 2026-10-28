using Test

@testset "JuliaMagCore" begin
    include("test_quality.jl")
    include("test_model.jl")
end
