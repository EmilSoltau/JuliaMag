module JuliaMagUI

import JuliaMagCore as Core
import CImGui as ig
import CImGui.lib as lib
import GLFW
import ModernGL as GL
import PNGFiles
import Cairo
import Rsvg
using JSON3
using PrecompileTools: @setup_workload, @compile_workload

include("theme/tokens.jl")
include("theme/fonts.jl")
include("app/config.jl")
include("app/x11.jl")
include("app/loop.jl")
include("theme/icons.jl")
include("app/precompile.jl")

function __init__()
    ICON_SVGS[] = nothing   # read the icon files again, not the copy from precompiling
    return nothing
end

end
