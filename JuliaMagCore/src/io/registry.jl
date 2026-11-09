# Importers and exporters: shared result types, progress, and the lists of
# known importers and exporters. Each one is a small unit for one file type.
# It registers itself here, so new formats are added without touching the core
# (spec 7, 8.4).

"""
A problem in the input that did not stop the import. `file_line` is the line
of a text file it is about, counting from 1, and such a warning goes in the job
report only. It is 0 for a warning about the item as a whole, which also goes
on the job card. It is `REPORT_ONLY` for detail that goes in the report only,
such as the list of lines a job card warning counts.
"""
struct ImportWarning
    file_line::Int
    message::String
end

"The `file_line` of an `ImportWarning` that is detail for the job report only."
const REPORT_ONLY = -1

"""
What an import made. `item` is the new or appended database item,
`rows` and `lines` count what this import added.
`summary` is one line for the job report. When it is empty, the report says
how many rows in how many lines were added.
"""
struct ImportResult
    item::Union{Nothing,ProjectItem}
    warnings::Vector{ImportWarning}
    rows::Int
    lines::Int
    summary::String
end

ImportResult(item, warnings, rows, lines) = ImportResult(item, warnings, rows, lines, "")

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
    function ImporterSpec(id, name, extensions, kind, settings, run)
        check_when(settings, "importer \"$id\"")
        return new(id, name, extensions, kind, settings, run)
    end
end

"The default value of each setting of the importer, by key."
default_settings(spec::ImporterSpec)::Dict{String,Any} = default_settings(spec.settings)

"The problems with importer settings, as plain sentences. Empty means fine. See `validate` of a tool."
validate(spec::ImporterSpec, settings::AbstractDict; session::Union{Nothing,Session} = nothing)::Vector{String} =
    last.(setting_problems(spec, settings; session))

"The problems with importer settings as `key => sentence`. See `setting_problems` of a tool."
setting_problems(spec::ImporterSpec, values::AbstractDict; session::Union{Nothing,Session} = nothing) =
    settings_problems(spec.settings, values, spec.name; session)

# Goes up by one at each change to the tools, importers or exporters.
const REGISTRY_GENERATION = Threads.Atomic{Int}(0)

"""
    registry_generation() -> Int

A number that goes up whenever a tool, importer or exporter is registered, replaced or
taken out. A caller that keeps a list built from `tools()`, `importers()` or
`exporters()` builds it again when the number changed. Safe from any thread, and cheap:
an atomic read.
"""
registry_generation()::Int = REGISTRY_GENERATION[]

bump_registry!() = (Threads.atomic_add!(REGISTRY_GENERATION, 1); nothing)

const IMPORTERS = ImporterSpec[]
const IMPORTERS_LOCK = ReentrantLock()

"Add an importer, or replace the one with the same id."
function register_importer!(spec::ImporterSpec)
    check_setting_keys(spec.settings, "importer \"$(spec.id)\"")
    lock(IMPORTERS_LOCK) do
        k = findfirst(i -> i.id == spec.id, IMPORTERS)
        k === nothing ? push!(IMPORTERS, spec) : (IMPORTERS[k] = spec)
        bump_registry!()
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
    function ExporterSpec(id, name, extension, kind, settings, run)
        check_when(settings, "exporter \"$id\"")
        return new(id, name, extension, kind, settings, run)
    end
end

"The default value of each setting of the exporter, by key."
default_settings(spec::ExporterSpec)::Dict{String,Any} = default_settings(spec.settings)

"The problems with exporter settings, as plain sentences. Empty means fine. See `validate` of a tool."
validate(spec::ExporterSpec, settings::AbstractDict; session::Union{Nothing,Session} = nothing)::Vector{String} =
    last.(setting_problems(spec, settings; session))

"The problems with exporter settings as `key => sentence`. See `setting_problems` of a tool."
setting_problems(spec::ExporterSpec, values::AbstractDict; session::Union{Nothing,Session} = nothing) =
    settings_problems(spec.settings, values, spec.name; session)

const EXPORTERS = ExporterSpec[]
const EXPORTERS_LOCK = ReentrantLock()

"Add an exporter, or replace the one with the same id."
function register_exporter!(spec::ExporterSpec)
    check_setting_keys(spec.settings, "exporter \"$(spec.id)\"")
    lock(EXPORTERS_LOCK) do
        k = findfirst(e -> e.id == spec.id, EXPORTERS)
        k === nothing ? push!(EXPORTERS, spec) : (EXPORTERS[k] = spec)
        bump_registry!()
    end
    return spec
end

"Take an exporter out of the list. Returns false when there was none with that id."
function unregister_exporter!(id::AbstractString)::Bool
    lock(EXPORTERS_LOCK) do
        k = findfirst(e -> e.id == id, EXPORTERS)
        k === nothing && return false
        deleteat!(EXPORTERS, k)
        bump_registry!()
        return true
    end
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

"""
    exporter_for(path, kind) -> Union{Nothing,ExporterSpec}

The exporter that writes items of `kind` to a file such as `path`, picked by
its extension (case is ignored). `nothing` when there is none.
"""
function exporter_for(path::AbstractString, kind::ItemKind)::Union{Nothing,ExporterSpec}
    ext = lowercase(file_extension(path))
    isempty(ext) && return nothing
    list = exporters(kind)
    k = findfirst(e -> e.extension == ext, list)
    return k === nothing ? nothing : list[k]
end
