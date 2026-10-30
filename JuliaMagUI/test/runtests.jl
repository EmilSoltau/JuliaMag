using Test

include("support/app.jl")

@testset "JuliaMagUI" begin
    include("test_quality.jl")
    include("test_tokens.jl")
    include("test_config.jl")
    include("test_icons.jl")
    include("test_loop.jl")
    include("window/test_harness.jl")
end
