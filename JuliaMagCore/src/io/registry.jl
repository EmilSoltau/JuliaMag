# Importers: shared result types, progress, and the list of known importers.
# Each importer is a small unit for one file type. It registers itself here,
# so new formats are added without touching the core (spec 8.4).

"A problem in the input that did not stop the import. `file_line` counts from 1."
struct ImportWarning
    file_line::Int
    message::String
end

"""
What an import made. `item` is the new or appended database item,
`rows` and `lines` count what this import added.
"""
struct ImportResult
    item::Union{Nothing,ProjectItem}
    warnings::Vector{ImportWarning}
    rows::Int
    lines::Int
end

"""
    Progress(done, cancelled)

How a long task reports back. `done(fraction)` gets a number from 0 to 1.
`cancelled()` returns true when the task should stop.
Use `report` and `is_cancelled`. `NO_PROGRESS` does nothing.
"""
struct Progress
    done::Function
    cancelled::Function
end

"Report that `fraction` (0 to 1) of the work is done."
report(p::Progress, fraction::Real) = (p.done(Float64(fraction)); nothing)

"True when the user asked to stop."
is_cancelled(p::Progress)::Bool = p.cancelled()::Bool

"A `Progress` that ignores reports and is never cancelled."
const NO_PROGRESS = Progress(_ -> nothing, () -> false)

"Thrown by an importer that stopped because `is_cancelled` returned true."
struct ImportCancelled <: Exception end

Base.showerror(io::IO, ::ImportCancelled) = print(io, "ImportCancelled: the import was cancelled")

"""
    ImporterSpec(id, name, extensions, kind, settings, run)

One importer.

- `id` is the command name in the history, such as `"import.geosoft_xyz"`.
- `extensions` are lower case and start with a dot, such as `".xyz"`.
- `kind` is the kind of item it makes.
- `run(session, path, settings::Dict, progress)` returns an `ImportResult`.
  It does not record the import in the history. `import_file` runs it as a
  job, and the job records it once, with the job id.
"""
struct ImporterSpec
    id::String
    name::String
    extensions::Vector{String}
    kind::ItemKind
    # Task 8 tightens this to Vector{SettingSpec}.
    settings::Vector{Any}
    run::Function
end

const IMPORTERS = ImporterSpec[]
const IMPORTERS_LOCK = ReentrantLock()

"Add an importer, or replace the one with the same id."
function register_importer!(spec::ImporterSpec)
    lock(IMPORTERS_LOCK) do
        k = findfirst(i -> i.id == spec.id, IMPORTERS)
        k === nothing ? push!(IMPORTERS, spec) : (IMPORTERS[k] = spec)
    end
    return spec
end

"All importers, in the order they were registered."
importers()::Vector{ImporterSpec} = lock(() -> copy(IMPORTERS), IMPORTERS_LOCK)

"The importer for a file, picked by its extension (case is ignored), or `nothing`."
function importer_for(path::AbstractString)::Union{Nothing,ImporterSpec}
    ext = lowercase(file_extension(path))
    isempty(ext) && return nothing
    lock(IMPORTERS_LOCK) do
        k = findfirst(i -> ext in i.extensions, IMPORTERS)
        return k === nothing ? nothing : IMPORTERS[k]
    end
end

# The extension of a path with `/` or `\` folders, so Windows paths work on every system.
function file_extension(path::AbstractString)::String
    name = last(split(path, ('/', '\\')))
    k = findlast('.', name)
    return (k === nothing || k == firstindex(name)) ? "" : String(name[k:end])
end
