# The frame of every grid export (spec 7). Each format writes its files with
# `run_grid_export`; Geosoft `.grd` is in `geosoft_grd.jl`, GeoTIFF and
# ER Mapper are in `gdal_grid.jl`.
#
# - While it runs, an export marks its grid busy for reading (`mark_reading!`,
#   ruling R12), so edits of the grid wait with `ItemBusyError`.
# - Rows are read in blocks of at most `GRID_BLOCK_BYTES` (`each_row_block`),
#   so memory stays flat however large the grid is.
# - A writer that opens its files itself, such as GDAL, gets the temp name
#   from `output_path!`.
# - An export may write several files, such as a `.grd` and its `.grd.xml`.
#   Each is written to a temp name next to it (`path.tmp-<random>`). Only when
#   all are complete are they renamed, one after the other. On an error or a
#   cancel every temp file is removed and no target is touched.
# - Progress is the fraction of rows written. Cancel is checked once per block
#   and throws `ExportCancelled`.

"""
One running grid export: the grid, the name of its item, the main file, the
progress, and the files written so far.
"""
struct GridExport
    grid::Grid
    "The name of the grid item."
    name::String
    "The main file of the export."
    path::String
    ticker::RowProgress
    "Each temp file and the file it becomes, in the order they were started."
    files::Vector{Pair{String,String}}
    "Old files to remove once the new files are in place: the path, why, and the note when it cannot be removed."
    remove::Vector{NTuple{3,String}}
end

"""
    write_output(f, x, path)

Call `f(io)` to write the file `path` of export `x`, and return what `f`
returns. The file is written to a temp name; `run_grid_export` renames it once
every file of the export is complete.
"""
write_output(f::F, x::GridExport, path::String) where {F} = open(f, output_path!(x, path), "w")

"""
    output_path!(x, path; tmp = export_temp_path(path))::String

Add the file `path` to export `x` and return the temp name to write it to, for
a writer that opens the file itself, such as GDAL. `run_grid_export` renames
the temp file to `path` once every file of the export is complete, and removes
it on a failure or a cancel. Close the file before the export ends.
"""
function output_path!(x::GridExport, path::String; tmp::String = export_temp_path(path))::String
    isdir(path) && throw(ToolError("$path is a folder. Give the name of a file to export to."))
    push!(x.files, tmp => path)          # before the file exists, so a failure removes it
    return tmp
end

"""
    remove_after!(x, path, why, stuck)

Remove the old file `path`, if there is one, once the new files of export `x`
are in place. `why` ends the note in the report. When it cannot be removed,
the export still succeeds and `stuck` is the note instead.
"""
remove_after!(x::GridExport, path::String, why::String, stuck::String) = (push!(x.remove, (path, why, stuck)); nothing)

"""
    each_row_block(f, x; north_first = false)

Call `f(j1, block)` for each block of rows of the grid of `x`, south row first,
or north row first when `north_first`. `block` is a new `nx` by `n` matrix of
rows `j1` to `j1 + n - 1` (south row first inside the block), which `f` may
change. Reports progress and checks for cancel after each block.
"""
function each_row_block(f::F, x::GridExport; north_first::Bool = false) where {F}
    g = x.grid
    n = block_rows(g)
    left = g.ny                          # rows not yet read
    while left > 0
        k = min(n, left)
        j1 = north_first ? left - k + 1 : g.ny - left + 1
        f(j1, read_rows(g, j1, k))
        rows_done!(x.ticker, k)
        left -= k
    end
    return nothing
end

"""
Move every temp file of `x` to its target, then remove the old files of
`remove_after!`. Returns the notes for the removed files, and for those that
could not be removed. If a move fails, the
temp files not yet moved are removed; files already moved stay.
"""
function commit_output!(x::GridExport)::Vector{String}
    for (k, (tmp, path)) in enumerate(x.files)
        try
            mv(tmp, path; force = true)
        catch
            foreach(((t, _),) -> rm(t; force = true), x.files[k:end])
            rethrow()
        end
    end
    # The new files are in place, so a file that cannot be removed (on Windows,
    # one that another program holds open) is a note, not a failed export.
    notes = String[]
    for (path, why, stuck) in x.remove
        ispath(path) || continue
        try
            rm(path)
            push!(notes, "Removed $(basename(path)): $why.")
        catch e
            e isa Base.IOError || e isa SystemError || rethrow()
            push!(notes, stuck)
        end
    end
    return notes
end

"""
    run_grid_export(write_body, s, command, item_id, path, progress, record; extra = Dict())::ExportResult

Run one grid export. Marks the grid busy for reading, calls `write_body(x)`
with a `GridExport` `x`, then renames all its files into place and records
the export in the history unless `record` is false. `write_body` writes each
file with `write_output` (the main file is `x.path`), reads the grid with
`each_row_block`, and returns notes for the report. `extra` holds the settings
to record besides `item` and `path`.

`rows` of the result is the number of cells, and `lines` is 0. A cancel throws
`ExportCancelled`. On a cancel or an error no temp file is left and no target
is touched.
"""
function run_grid_export(write_body::F, s::Session, command::String, item_id::AbstractString, path::AbstractString,
                         progress::Progress, record::Bool;
                         extra::Dict{String,Any} = Dict{String,Any}())::ExportResult where {F}
    report(progress, 0.0)
    path = String(path)
    notes = String[]
    # The item is busy for reading until the files are written (ruling R12).
    mark_reading!(s, item_id)
    local g::Grid
    try
        g, name = lock(() -> (grid(s.project, item_id), item(s.project, item_id).name), s.lock)
        x = GridExport(g, name, path, RowProgress(progress, g.ny), Pair{String,String}[], NTuple{3,String}[])
        try
            check_export_cancel(x.ticker)
            append!(notes, write_body(x))
            append!(notes, commit_output!(x))
        catch
            foreach(((tmp, _),) -> rm(tmp; force = true), x.files)
            rethrow()
        end
    finally
        unmark_reading!(s, item_id)
    end
    report(progress, 1.0)
    if record
        record!(s, command, merge(Dict{String,Any}("item" => String(item_id), "path" => path), extra))
    end
    return ExportResult(path, g.nx * g.ny, 0, notes)
end
