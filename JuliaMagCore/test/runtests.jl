using Test

@testset "JuliaMagCore" begin
    include("test_quality.jl")
    include("test_model.jl")
    include("test_database.jl")
    include("test_project.jl")
    include("support/synthetic.jl")
    include("test_session.jl")
    include("test_xyz.jl")
    include("test_csv.jl")
    include("test_jobs.jl")
    include("test_tools.jl")
    include("test_export.jl")
    include("test_coordinates.jl")
    include("test_channel_math.jl")
    include("test_statistics.jl")
    include("test_end_to_end.jl")
end
