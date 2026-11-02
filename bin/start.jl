# Start JuliaMag. bin/juliamag.sh and bin/juliamag.cmd run this file with the app's project:
#   julia -t auto,1 --project=JuliaMagUI bin/start.jl [project folder]
#
# On the first start the depot does not have the packages yet, and `using JuliaMagUI`
# would stop with "Package ... is required but does not seem to be installed".
# So this file first checks that every package of the manifest is installed. That check
# reads the manifest only and takes a few milliseconds. When a package is missing, it
# installs them all with `Pkg.instantiate()` in a separate Julia process: that way the
# app's process never loads Pkg, and later starts stay fast.

"""
The names of the packages the app loads that are not installed in the depot: the deps of
the active project and theirs, as the manifest lists them. The manifest is the
workspace's, so it also lists packages only the tests and tools need; those are skipped.
"""
function missing_packages()::Vector{String}
    project = Base.active_project()
    manifest = project === nothing ? nothing : Base.project_file_manifest_path(project)
    manifest === nothing && return ["(the manifest)"]
    entries = Base.parsed_toml(manifest)["deps"]
    todo = collect(keys(get(Base.parsed_toml(project), "deps", Dict{String,Any}())))
    seen = Set{String}()
    absent = String[]
    while !isempty(todo)
        name = pop!(todo)
        name in seen && continue
        push!(seen, name)
        haskey(entries, name) || (push!(absent, name); continue)
        for entry in entries[name]
            uuid = get(entry, "uuid", nothing)
            uuid === nothing && continue
            Base.locate_package(Base.PkgId(Base.UUID(uuid), name)) === nothing && push!(absent, name)
            # `deps` is a list of names, or a table of name => uuid when names repeat.
            append!(todo, collect(String, get(entry, "deps", String[]) isa AbstractDict ?
                keys(entry["deps"]) : get(entry, "deps", String[])))
        end
    end
    return absent
end

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
