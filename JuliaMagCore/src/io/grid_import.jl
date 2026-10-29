# The shared frame of every grid importer (GDAL, Geosoft and others).
#
# A reader gives `import_grid` a `GridHeader` and a function. The function puts
# the values into a `GridSink`, by blocks of rows (`put_rows!`) or of columns
# (`put_columns!`), in any order. The frame does the rest:
#
# - It writes the grid to `grids/.importing-<id>/` and moves it to its final
#   folder only when every cell is written. Then the item is added to the project.
#   On any error or cancel the temp folder is removed.
# - The sink owns `vmin`, `vmax` and `count`. They are saved with the metadata.
# - Progress is counted in cells. A cancel throws `ImportCancelled`.

"What a reader knows about a grid before it reads the values."
struct GridHeader
    nx::Int
    ny::Int
    dx::Float64
    dy::Float64
    x0::Float64
    y0::Float64
    rotation::Float64
    crs::String
    units::String
    "The stored type: `Float32` or `Float64`."
    eltype::DataType
    source::GridSource
end

"""
Where a reader puts the values of a grid.
Rows and columns are not mixed in one sink, and each is put once.
Rows are written with `write_rows!`. The value file is mapped lazily on the
first column block (row-only readers never map it) and released before the
folder is moved.
"""
mutable struct GridSink
    grid::Grid
    progress::Progress
    "`:none` until the first put, then `:rows` or `:columns`."
    mode::Symbol
    "One flag per row (`:rows`) or per column (`:columns`)."
    seen::BitVector
    cells::Int
    vmin::Float64
    vmax::Float64
    count::Int
    "The map of the value file. Opened lazily on the first column block, released by `close_map!`."
    map::Union{Nothing,Matrix}
end

GridSink(g::Grid, progress::Progress) =
    GridSink(g, progress, :none, falses(0), 0, Inf, -Inf, 0, nothing)

function set_mode!(sink::GridSink, mode::Symbol)
    if sink.mode === :none
        sink.mode = mode
        sink.seen = falses(mode === :rows ? sink.grid.ny : sink.grid.nx)
    elseif sink.mode !== mode
        throw(GridError("rows and columns cannot be mixed in one grid import"))
    end
    return nothing
end

"Mark `n` rows or columns from `k1` on as put. Throws `GridError` when one is put twice or is outside the grid."
function claim!(sink::GridSink, what::String, k1::Integer, n::Integer)
    last = length(sink.seen)
    (k1 >= 1 && n >= 1 && k1 + n - 1 <= last) ||
        throw(GridError("$what $k1 to $(k1 + n - 1) are outside the grid ($what 1 to $last)"))
    for k in k1:(k1 + n - 1)
        sink.seen[k] && throw(GridError("$(what[1:end-1]) $k was put twice"))
        sink.seen[k] = true
    end
    return nothing
end

function update_stats!(sink::GridSink, block::AbstractMatrix)
    lo, hi, n = sink.vmin, sink.vmax, sink.count
    for v in block
        isnan(v) && continue
        n += 1
        lo = min(lo, v)
        hi = max(hi, v)
    end
    sink.vmin, sink.vmax, sink.count = lo, hi, n
    return nothing
end

function after_put!(sink::GridSink, block::AbstractMatrix)
    update_stats!(sink, block)
    sink.cells += length(block)
    report(sink.progress, sink.cells / (sink.grid.nx * sink.grid.ny))
    return nothing
end

"""
    put_rows!(sink, j1, block)

Put rows `j1` to `j1 + k - 1`. `block` is `nx` by `k`. Values are converted to
the type of the grid. Throws `ImportCancelled` when the job is cancelled.
"""
function put_rows!(sink::GridSink, j1::Integer, block::AbstractMatrix)
    is_cancelled(sink.progress) && throw(ImportCancelled())
    g = sink.grid
    size(block, 1) == g.nx ||
        throw(GridError("a block of rows needs $(g.nx) values per row, not $(size(block, 1))"))
    set_mode!(sink, :rows)
    claim!(sink, "rows", j1, size(block, 2))
    B = Matrix{g.eltype}(block)
    write_rows!(g, j1, B)
    after_put!(sink, B)
    return nothing
end

"Copy `B` (`ny` by `k`) into columns `i1` on of `A`. A function barrier, so the loop is type stable."
function write_columns!(A::Matrix{T}, i1::Integer, B::Matrix{T}) where {T}
    for j in 1:size(B, 1), c in 1:size(B, 2)
        @inbounds A[i1 + c - 1, j] = B[j, c]
    end
    return nothing
end

"""
    put_columns!(sink, i1, block)

Put columns `i1` to `i1 + k - 1`. `block` is `ny` by `k`: column `i1` is
`block[:, 1]`, from row 1 up. Values are converted to the type of the grid.
Throws `ImportCancelled` when the job is cancelled.
"""
function put_columns!(sink::GridSink, i1::Integer, block::AbstractMatrix)
    is_cancelled(sink.progress) && throw(ImportCancelled())
    g = sink.grid
    size(block, 1) == g.ny ||
        throw(GridError("a block of columns needs $(g.ny) values per column, not $(size(block, 1))"))
    set_mode!(sink, :columns)
    claim!(sink, "columns", i1, size(block, 2))
    B = Matrix{g.eltype}(block)
    sink.map === nothing && (sink.map = map_values(g; write = true))
    write_columns!(sink.map::Matrix{g.eltype}, i1, B)
    after_put!(sink, B)
    return nothing
end

"Sync and unmap the value file. Safe to call twice."
function close_map!(sink::GridSink)
    A = sink.map
    A === nothing && return nothing
    sink.map = nothing
    unmap_values!(A; write = true)
    return nothing
end

"Throw `GridError` when a row or column was not put."
function check_complete(sink::GridSink)
    if sink.mode === :none || !all(sink.seen)
        k = sink.mode === :none ? 1 : findfirst(!, sink.seen)::Int
        throw(GridError("the file ended before $(sink.mode === :columns ? "column" : "row") $k"))
    end
    return nothing
end

"""
    import_grid(fill!, s, name, header; warnings = ImportWarning[], progress = NO_PROGRESS) -> ImportResult

Import a grid as item `name`. `fill!(sink)` puts every cell into the sink
(see `put_rows!` and `put_columns!`). When it throws, or a cell is missing,
nothing is added and the temp folder is removed. Call it inside a job and pass
the job's `progress`, so the import shows progress and can be cancelled.
"""
function import_grid(fill!::F, s::Session, name::AbstractString, header::GridHeader;
                     warnings::Vector{ImportWarning} = ImportWarning[],
                     progress::Progress = NO_PROGRESS)::ImportResult where {F}
    p = s.project
    name = String(name)
    id = lock(() -> reserve_item_id!(p, ITEM_GRID), s.lock)
    grids = joinpath(p.folder, "grids")
    mkpath(grids)
    tmp = joinpath(grids, ".importing-$id")
    note_job_folder!(tmp)
    sink = nothing
    local g::Grid
    try
        rm(tmp; recursive = true, force = true)
        g = create_grid(tmp, name, header.eltype, header.nx, header.ny; dx = header.dx, dy = header.dy,
                        x0 = header.x0, y0 = header.y0, rotation = header.rotation,
                        crs = header.crs, units = header.units)
        g.source = header.source
        sink = GridSink(g, progress)
        fill!(sink)
        close_map!(sink)
        check_complete(sink)
        g.count = sink.count
        g.vmin = sink.count == 0 ? NaN : sink.vmin
        g.vmax = sink.count == 0 ? NaN : sink.vmax
        save_grid_meta(g)
    catch
        sink === nothing || try close_map!(sink) catch end
        rm(tmp; recursive = true, force = true)
        rethrow()
    end
    new_item = lock(s.lock) do
        folder = free_folder(grids, folder_slug(name))
        final = joinpath(grids, folder)
        try
            mv(tmp, final)
        catch
            rm(tmp; recursive = true, force = true)
            rethrow()
        end
        it = ProjectItem(id, ITEM_GRID, name, "grids/$folder", "", "")
        try
            add_item!(p, it)
            save_project(p)
        catch
            any(i -> i === it, p.items) && remove_item!(p, id)
            rm(final; recursive = true, force = true)
            rethrow()
        end
        it
    end
    summary = "$(header.source.format) grid $(g.nx) x $(g.ny) cells, $(g.count) with values"
    return ImportResult(new_item, warnings, 0, 0, summary)
end
