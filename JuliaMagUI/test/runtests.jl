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
    include("test_start.jl")
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
    include("test_map_camera.jl")
    include("test_map_lines.jl")
    include("test_map_grids.jl")
    include("test_map_cpu.jl")
    include("test_map_loader.jl")
    include("test_map_view.jl")
    include("test_map_frame.jl")
    include("test_map_commands.jl")
    include("test_map_readout.jl")
    include("test_layers.jl")
    include("test_style_pane.jl")
    include("window/test_harness.jl")
    include("window/test_shell.jl")
    include("window/test_ribbon.jl")
    include("window/test_data.jl")
    include("window/test_dialogs.jl")
    include("window/test_jobs.jl")
    include("window/test_search.jl")
    include("window/test_backstage.jl")
    include("window/test_end_to_end.jl")
    include("window/test_map_gl.jl")
    include("window/test_map_view.jl")
    include("window/test_map_fallback.jl")
    include("window/test_map_commands.jl")
    include("window/test_map_cursor.jl")
    include("window/test_layers.jl")
    include("window/test_style_pane.jl")
end

end
