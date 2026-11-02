# The checks of bin/start.jl: is every package of the app's environment installed, with its artifacts?
# This file only defines functions, so the tests can include it.

"""
The names of the packages the app loads that are not installed in the depot: the deps of
the active project and theirs, as the manifest lists them. The manifest is the
workspace's, so it also lists packages only the tests and tools need; those are skipped.
A package whose artifacts are not all in the depot (a half-finished install) counts as
missing too.
"""
function missing_packages(project = Base.active_project())::Vector{String}
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
            path = Base.locate_package(Base.PkgId(Base.UUID(uuid), name))
            if path === nothing || !isempty(missing_artifacts(dirname(dirname(path))))
                push!(absent, name)
            end
            # `deps` is a list of names, or a table of name => uuid when names repeat.
            append!(todo, collect(String, get(entry, "deps", String[]) isa AbstractDict ?
                keys(entry["deps"]) : get(entry, "deps", String[])))
        end
    end
    return absent
end

# The keys of an artifact entry that the host platform decides.
const PLAIN_KEYS = Set(["git-tree-sha1", "download", "lazy", "os", "arch", "libc",
    "libgfortran_version", "cxxstring_abi", "call_abi", "julia_version", "os_version"])

# Is the artifact with this tree hash in a depot? The Artifacts stdlib could tell, but a
# test environment does not list it, and this is one line.
in_depot(hash::AbstractString) = any(d -> isdir(joinpath(d, "artifacts", hash)), Base.DEPOT_PATH)

"""
The artifacts of the package in `dir` that the depot does not have: the ones that
`Pkg.instantiate()` would download for this system. Empty when the package has none.

An artifact counts as missing when none of its entries for this operating system and
processor is in the depot. Some packages pick the entry with settings Pkg knows (an MPI
library, for example), so an entry with a setting outside `PLAIN_KEYS` is not checked.
Lazy artifacts are downloaded on first use, so they are not checked either.
"""
function missing_artifacts(dir::AbstractString)::Vector{String}
    toml = joinpath(dir, "Artifacts.toml")
    isfile(toml) || (toml = joinpath(dir, "JuliaArtifacts.toml"))
    isfile(toml) || return String[]
    host = Base.BinaryPlatforms.HostPlatform()
    here(meta) = get(meta, "os", Base.BinaryPlatforms.os(host)) == Base.BinaryPlatforms.os(host) &&
        get(meta, "arch", Base.BinaryPlatforms.arch(host)) == Base.BinaryPlatforms.arch(host)
    absent = String[]
    for (name, entry) in Base.parsed_toml(toml)
        variants = [m for m in (entry isa AbstractVector ? entry : [entry])
                    if haskey(m, "download") && !get(m, "lazy", false) &&
                       keys(m) ⊆ PLAIN_KEYS && here(m)]
        isempty(variants) && continue
        any(m -> in_depot(m["git-tree-sha1"]), variants) ||
            push!(absent, name)
    end
    return sort!(absent)
end
