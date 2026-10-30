# The tests run in their own module: there `import JuliaMagCore as Core` works,
# as in the package. In Main the name `Core` is Julia's own module.
module JuliaMagUITests

using Test

include("support/app.jl")
include("support/state.jl")

@testset "JuliaMagUI" begin
    include("test_quality.jl")
    include("test_tokens.jl")
    include("test_config.jl")
    include("test_icons.jl")
    include("test_loop.jl")
    include("test_state.jl")
    include("test_worker.jl")
    include("test_commands.jl")
    include("window/test_harness.jl")
end

end
