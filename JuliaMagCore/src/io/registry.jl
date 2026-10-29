# Importers and exporters: shared result types, progress, and the lists of
# known importers and exporters. Each one is a small unit for one file type.
# It registers itself here, so new formats are added without touching the core
# (spec 7, 8.4).

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
- `settings` describe the settings `run` takes, for the import dialog.
- `run(session, path, settings::Dict, progress)` returns an `ImportResult`.
  It does not record the import in the history. `import_file` runs it as a
  job, and the job records it once, with the job id.
"""
struct ImporterSpec
    id::String
    name::String
    extensions::Vector{String}
    kind::ItemKind
    settings::Vector{SettingSpec}
    run::Function
end

"The default value of each setting of the importer, by key."
default_settings(spec::ImporterSpec)::Dict{String,Any} = default_settings(spec.settings)

"The problems with importer settings, as plain sentences. Empty means fine."
validate(spec::ImporterSpec, settings::AbstractDict)::Vector{String} =
    validate_settings(spec.settings, settings, spec.name)

const IMPORTERS = ImporterSpec[]
const IMPORTERS_LOCK = ReentrantLock()

"Add an importer, or replace the one with the same id."
function register_importer!(spec::ImporterSpec)
    check_setting_keys(spec.settings, "importer \"$(spec.id)\"")
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

# ---- exporters -------------------------------------------------------------

"Thrown by an exporter that stopped because `is_cancelled` returned true."
struct ExportCancelled <: Exception end

Base.showerror(io::IO, ::ExportCancelled) = print(io, "ExportCancelled: the export was cancelled")

"""
What an export wrote: the file, the rows and lines in it, and notes for the
report, such as text values that were changed to fit the format.
"""
struct ExportResult
    path::String
    rows::Int
    lines::Int
    notes::Vector{String}
end

"""
    ExporterSpec(id, name, extension, kind, settings, run)

One exporter.

- `id` is the command name in the history, such as `"export.geosoft_xyz"`.
- `extension` is lower case and starts with a dot, such as `".xyz"`.
- `kind` is the kind of item it writes.
- `settings` describe the settings `run` takes, for the export dialog.
- `run(session, item_id, path, settings::Dict, progress)` returns an `ExportResult`.
  It does not record the export in the history. `export_file` runs it as a
  job, and the job records it once, with the job id.
"""
struct ExporterSpec
    id::String
    name::String
    extension::String
    kind::ItemKind
    settings::Vector{SettingSpec}
    run::Function
end

"The default value of each setting of the exporter, by key."
default_settings(spec::ExporterSpec)::Dict{String,Any} = default_settings(spec.settings)

"The problems with exporter settings, as plain sentences. Empty means fine."
validate(spec::ExporterSpec, settings::AbstractDict)::Vector{String} =
    validate_settings(spec.settings, settings, spec.name)

const EXPORTERS = ExporterSpec[]
const EXPORTERS_LOCK = ReentrantLock()

"Add an exporter, or replace the one with the same id."
function register_exporter!(spec::ExporterSpec)
    check_setting_keys(spec.settings, "exporter \"$(spec.id)\"")
    lock(EXPORTERS_LOCK) do
        k = findfirst(e -> e.id == spec.id, EXPORTERS)
        k === nothing ? push!(EXPORTERS, spec) : (EXPORTERS[k] = spec)
    end
    return spec
end

"""
    exporters()
    exporters(kind)

All exporters, or those that write items of `kind`, in the order they were registered.
"""
exporters()::Vector{ExporterSpec} = lock(() -> copy(EXPORTERS), EXPORTERS_LOCK)
exporters(kind::ItemKind)::Vector{ExporterSpec} = filter(e -> e.kind == kind, exporters())

"""
    exporter_for(path) -> Union{Nothing,ExporterSpec}
    exporter_for(id) -> Union{Nothing,ExporterSpec}

The exporter with id `id`, or the exporter for a file, picked by its extension
(case is ignored). `nothing` when there is none.
"""
function exporter_for(path_or_id::AbstractString)::Union{Nothing,ExporterSpec}
    list = exporters()
    k = findfirst(e -> e.id == path_or_id, list)
    k === nothing || return list[k]
    ext = lowercase(file_extension(path_or_id))
    isempty(ext) && return nothing
    k = findfirst(e -> e.extension == ext, list)
    return k === nothing ? nothing : list[k]
end
