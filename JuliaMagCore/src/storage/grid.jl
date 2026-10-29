# A grid item: a folder with `grid.json` and one raw value file.
#
# The value file is `values.f32` or `values.f64` (little endian). Row 1 comes
# first. Within a row, `i` goes from 1 to `nx`. So the values are a Julia
# `Matrix` of size `(nx, ny)` with `A[i, j]`.
#
# Georeference is Geosoft's: `x0, y0` is the centre of the lower-left cell,
# `dx, dy` are the cell sizes and `rotation` is in degrees counter-clockwise
# about `(x0, y0)`.
#
# A whole grid is never read at once by the block readers and writers. They move
# at most `GRID_BLOCK_BYTES` per call (see `block_rows`).

using JSON3, StructTypes

"An error in a grid: a missing or broken file."
struct GridError <: Exception
    msg::String
end

Base.showerror(io::IO, e::GridError) = print(io, "GridError: ", e.msg)

"How a grid is drawn. `NaN` limits mean the limits come from the data."
mutable struct GridStyle
    colours::String
    "One of `:linear`, `:histeq`, `:normal`, `:loglinear`."
    method::Symbol
    min::Float64
    max::Float64
    reverse::Bool
    shade::Bool
    azimuth::Float64
    altitude::Float64
    zfactor::Float64
end

GridStyle() = GridStyle("rainbow", :histeq, NaN, NaN, false, false, 45.0, 45.0, 1.0)

"Where a grid came from."
mutable struct GridSource
    file::String
    format::String
    eltype::String
    compression::String
end

GridSource() = GridSource("", "", "", "")

"""
A grid stored in `folder`.

`vmin`, `vmax` and `count` (cells that are not `NaN`) are kept up to date by
every writer of the grid.
"""
mutable struct Grid
    folder::String
    name::String
    eltype::DataType
    nx::Int
    ny::Int
    dx::Float64
    dy::Float64
    x0::Float64
    y0::Float64
    rotation::Float64
    crs::String
    units::String
    source::GridSource
    trend::Vector{Float64}
    style::GridStyle
    vmin::Float64
    vmax::Float64
    count::Int
end

Base.show(io::IO, g::Grid) =
    print(io, "Grid(", repr(g.name), ", ", g.nx, " x ", g.ny, " ", g.eltype, ")")

const GRID_BLOCK_BYTES = 16 * 1024 * 1024

# ---- grid.json ---------------------------------------------------------------

const GRID_META_FILE = "grid.json"
const GRID_META_VERSION = 1
const GRID_ELTYPES = Dict("float32" => Float32, "float64" => Float64)

StructTypes.StructType(::Type{GridStyle}) = StructTypes.Mutable()
StructTypes.StructType(::Type{GridSource}) = StructTypes.Mutable()

"The content of `grid.json`."
struct GridRecord
    version::Int
    name::String
    eltype::String
    nx::Int
    ny::Int
    dx::Float64
    dy::Float64
    x0::Float64
    y0::Float64
    rotation::Float64
    crs::String
    units::String
    source::GridSource
    trend::Vector{Float64}
    style::GridStyle
    vmin::Float64
    vmax::Float64
    count::Int
end
StructTypes.StructType(::Type{GridRecord}) = StructTypes.Struct()

function eltype_text(T::DataType)::String
    T === Float32 && return "float32"
    T === Float64 && return "float64"
    throw(GridError("grid values must be Float32 or Float64, not $T"))
end

grid_meta_path(folder::AbstractString) = joinpath(folder, GRID_META_FILE)

"""
    values_path(g) -> String

The path of the value file of `g`.
"""
values_path(g::Grid)::String = joinpath(g.folder, g.eltype === Float32 ? "values.f32" : "values.f64")

"""
    save_grid_meta(g)

Write `grid.json` of `g` atomically.
"""
function save_grid_meta(g::Grid)
    rec = GridRecord(GRID_META_VERSION, g.name, eltype_text(g.eltype), g.nx, g.ny, g.dx, g.dy,
                     g.x0, g.y0, g.rotation, g.crs, g.units, g.source, g.trend, g.style,
                     g.vmin, g.vmax, g.count)
    write_json_atomic(grid_meta_path(g.folder), rec; allow_inf = true)
    return nothing
end

"""
    create_grid(folder, name, T, nx, ny; dx, dy, x0, y0, rotation = 0.0, crs = "", units = "") -> Grid

Make a new grid in `folder`. The folder is created when needed.
The value file is sized to `nx * ny` values but not written: the writer fills
every cell. Throws `GridError` when a grid already exists there.
"""
function create_grid(folder::AbstractString, name::AbstractString, ::Type{T}, nx::Integer, ny::Integer;
                     dx::Real, dy::Real, x0::Real, y0::Real, rotation::Real = 0.0,
                     crs::AbstractString = "", units::AbstractString = "")::Grid where {T<:Union{Float32,Float64}}
    nx > 0 && ny > 0 || throw(GridError("a grid needs at least one cell in each direction, not $nx by $ny"))
    isfile(grid_meta_path(folder)) && throw(GridError("a grid already exists in $folder"))
    mkpath(folder)
    g = Grid(String(folder), String(name), T, Int(nx), Int(ny), Float64(dx), Float64(dy),
             Float64(x0), Float64(y0), Float64(rotation), String(crs), String(units),
             GridSource(), Float64[], GridStyle(), NaN, NaN, 0)
    open(values_path(g), "w") do io
        truncate(io, g.nx * g.ny * sizeof(T))
    end
    save_grid_meta(g)
    return g
end

"""
    open_grid(folder) -> Grid

Open the grid in `folder`.
Throws `GridError` when `grid.json` is missing or broken,
or when the value file is missing or has the wrong size.
"""
function open_grid(folder::AbstractString)::Grid
    path = grid_meta_path(folder)
    isfile(path) || throw(GridError("no grid in $folder: $GRID_META_FILE is missing"))
    rec = try
        JSON3.read(read(path, String), GridRecord; allow_inf = true)
    catch e
        e isa InterruptException && rethrow()
        throw(GridError("$GRID_META_FILE in $folder is broken: $(sprint(showerror, e))"))
    end
    rec.version == GRID_META_VERSION ||
        throw(GridError("$GRID_META_FILE in $folder has version $(rec.version); this program reads version $GRID_META_VERSION"))
    T = get(GRID_ELTYPES, rec.eltype, nothing)
    T === nothing && throw(GridError("$GRID_META_FILE in $folder has an unknown value type: $(rec.eltype)"))
    (rec.nx > 0 && rec.ny > 0) ||
        throw(GridError("$GRID_META_FILE in $folder has a bad size: $(rec.nx) by $(rec.ny)"))
    g = Grid(String(folder), rec.name, T, rec.nx, rec.ny, rec.dx, rec.dy, rec.x0, rec.y0,
             rec.rotation, rec.crs, rec.units, rec.source, rec.trend, rec.style,
             rec.vmin, rec.vmax, rec.count)
    vp = values_path(g)
    isfile(vp) || throw(GridError("the value file $vp is missing"))
    want = g.nx * g.ny * sizeof(T)
    got = filesize(vp)
    got == want ||
        throw(GridError("the value file $vp has $got bytes; $(g.nx) by $(g.ny) values need $want"))
    return g
end

# ---- reading and writing -------------------------------------------------------

"""
    block_rows(g) -> Int

Rows per block: as many as fit in `GRID_BLOCK_BYTES`, and at least one.
"""
block_rows(g::Grid)::Int = max(1, GRID_BLOCK_BYTES ÷ (g.nx * sizeof(g.eltype)))

function check_rows(g::Grid, j1::Integer, n::Integer)
    (j1 >= 1 && n >= 0 && j1 + n - 1 <= g.ny) ||
        throw(ArgumentError("rows $j1 to $(j1 + n - 1) are outside the grid (1 to $(g.ny))"))
    return nothing
end

"""
    read_rows(g, j1, n) -> Matrix

Read `n` rows from row `j1` on. The result has size `nx` by `n`. No map is used.
"""
function read_rows(g::Grid, j1::Integer, n::Integer)
    check_rows(g, j1, n)
    T = g.eltype
    A = Matrix{T}(undef, g.nx, n)
    open(values_path(g), "r") do io
        seek(io, (j1 - 1) * g.nx * sizeof(T))
        read!(io, A)
    end
    return A
end

"""
    write_rows!(g, j1, block)

Write `block` (size `nx` by `n`) from row `j1` on. No map is used.
"""
function write_rows!(g::Grid, j1::Integer, block::Matrix{T}) where {T}
    T === g.eltype || throw(ArgumentError("the grid holds $(g.eltype) values, not $T"))
    size(block, 1) == g.nx || throw(ArgumentError("a block needs $(g.nx) values per row, not $(size(block, 1))"))
    check_rows(g, j1, size(block, 2))
    open(values_path(g), "r+") do io
        seek(io, (j1 - 1) * g.nx * sizeof(T))
        write(io, block)
    end
    return nothing
end

"""
    with_grid_values(f, g; write = false)

Map the values as a `Matrix` of size `(nx, ny)` and call `f(A)`.
With `write = true` the map can be changed and is synced after `f`.
The map is closed before this returns, also on error.
"""
function with_grid_values(f, g::Grid; write::Bool = false)
    A = open(values_path(g), write ? "r+" : "r") do io
        Mmap.mmap(io, Matrix{g.eltype}, (g.nx, g.ny); shared = write)
    end
    try
        r = f(A)
        write && Mmap.sync!(A)
        return r
    finally
        finalize(A)
    end
end

# ---- geometry ------------------------------------------------------------------

function rotated(g::Grid, u::Real, v::Real)::Tuple{Float64,Float64}
    c = cosd(g.rotation)
    s = sind(g.rotation)
    return (g.x0 + u * c - v * s, g.y0 + u * s + v * c)
end

"""
    cell_centre(g, i, j) -> (x, y)

The ground position of the centre of cell `(i, j)`, with rotation.
"""
cell_centre(g::Grid, i::Integer, j::Integer)::Tuple{Float64,Float64} =
    rotated(g, (i - 1) * g.dx, (j - 1) * g.dy)

"""
    grid_corners(g) -> NTuple{4,Tuple{Float64,Float64}}

The outer corners of the grid (cell edges, not centres), lower-left first,
counter-clockwise.
"""
function grid_corners(g::Grid)::NTuple{4,Tuple{Float64,Float64}}
    u0 = -g.dx / 2
    v0 = -g.dy / 2
    u1 = (g.nx - 0.5) * g.dx
    v1 = (g.ny - 0.5) * g.dy
    return (rotated(g, u0, v0), rotated(g, u1, v0), rotated(g, u1, v1), rotated(g, u0, v1))
end
