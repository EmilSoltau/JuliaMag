using Test

@testset "JuliaMagCore" begin
    include("test_quality.jl")
    include("test_model.jl")
    include("test_database.jl")
    include("test_project.jl")
end
