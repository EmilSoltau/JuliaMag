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
    include("test_shell.jl")
    include("test_ribbon.jl")
    include("test_data_tree.jl")
    include("test_form.jl")
    include("test_jobs_view.jl")
    include("test_search.jl")
    include("test_projects.jl")
    include("window/test_harness.jl")
    include("window/test_shell.jl")
    include("window/test_ribbon.jl")
    include("window/test_data.jl")
    include("window/test_dialogs.jl")
    include("window/test_jobs.jl")
    include("window/test_search.jl")
    include("window/test_backstage.jl")
end

end
