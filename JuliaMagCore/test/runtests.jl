using Test

@testset "JuliaMagCore" begin
    include("test_quality.jl")
    include("test_model.jl")
    include("test_database.jl")
    include("test_project.jl")
    include("support/synthetic.jl")
    include("test_session.jl")
    include("test_xyz.jl")
    include("test_jobs.jl")
end
