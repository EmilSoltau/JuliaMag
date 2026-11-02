# Start JuliaMag. bin/juliamag.sh and bin/juliamag.cmd run this file with the app's project:
#   julia -t auto,1 --project=JuliaMagUI bin/start.jl [project folder]
#
# On the first start the depot does not have the packages yet, and `using JuliaMagUI`
# would stop with "Package ... is required but does not seem to be installed".
# So this file first checks that every package of the manifest is installed, with its
# artifacts. That check reads the manifest and the artifact lists only and takes a few
# milliseconds. When a package or an artifact is missing, it installs them all with
# `Pkg.instantiate()` in a separate Julia process: that way the app's process never
# loads Pkg, and later starts stay fast.

include(joinpath(@__DIR__, "packages.jl"))

"Install the packages of the app's project, in a separate Julia process."
function install_packages()
    println("JuliaMag installs its packages. This first start takes a few minutes.")
    flush(stdout)
    project = something(Base.active_project())
    julia = Base.julia_cmd()
    run(`$julia --project=$project -e "import Pkg; Pkg.instantiate()"`)
    return nothing
end

absent = try
    missing_packages()
catch e
    # The check uses Julia's own loading code; if that changes, install to be safe.
    ["(the check failed: $(sprint(showerror, e)))"]
end
isempty(absent) || install_packages()

using JuliaMagUI
JuliaMagUI.main(ARGS)
