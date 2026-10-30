using Test

@testset "JuliaMagUI" begin
    include("test_quality.jl")
    include("test_tokens.jl")
    include("test_config.jl")
end
