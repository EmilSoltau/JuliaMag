# Grid import through GDAL: GeoTIFF, ER Mapper, and Surfer (Task 6 forces the driver).
# Grid export through GDAL: GeoTIFF and ER Mapper (see "export" below).
#
# The file is opened read-only. One band is read in blocks of rows with
# `ArchGDAL.read!`, turned into real values (nodata becomes `NaN`, band scale
# and offset are applied) and put into the import sink in JuliaMag's row order.
#
# GDAL errors become `GridError` with GDAL's message. GDAL never prints: a quiet
# error handler is set when the package loads. GDAL still keeps the last error,
# which GDAL.jl reads after each call.

import ArchGDAL

const GDAL = ArchGDAL.GDAL

# GDAL calls this for each error and warning. It drops them; GDAL.jl reads the
# last error from GDAL after each call and throws it as `GDALError`.
quiet_gdal_error(::GDAL.CPLErr, ::Cint, ::Cstring)::Cvoid = nothing

"The handler `quiet_gdal!` gave GDAL, so a test can check it is still in place."
const QUIET_GDAL_HANDLER = Ref{Ptr{Cvoid}}(C_NULL)

"Set the quiet GDAL error handler. Called once by the module's `__init__`."
function quiet_gdal!()
    QUIET_GDAL_HANDLER[] = @cfunction(quiet_gdal_error, Cvoid, (GDAL.CPLErr, Cint, Cstring))
    GDAL.cplseterrorhandler(QUIET_GDAL_HANDLER[])
    return nothing
end

"Call `f()` and throw a GDAL error as `GridError` with GDAL's message."
function gdal_errors(f::F) where {F}
    try
        return f()
    catch e
        e isa GDAL.GDALError || rethrow()
        msg = strip(e.msg)
        throw(GridError(isempty(msg) ? "GDAL failed (error $(e.code))" : String(msg)))
    end
end

# ---- the GDAL block cache ------------------------------------------------------
#
# GDAL keeps the blocks it reads and writes in a cache of 5 % of the memory by
# default, so a big file would fill over 1 GB of it. JuliaMag moves blocks of
# rows and needs little of it: the cache is set to `GDAL_CACHE_FLOOR` when the
# package loads, and a job raises it by what it needs while it runs.

"The size of the GDAL block cache when no job needs more, in bytes."
const GDAL_CACHE_FLOOR = 64 * 2^20

# The needs of the running jobs, guarded by the lock.
const GDAL_CACHE_NEEDS = Int[]
const GDAL_CACHE_LOCK = ReentrantLock()

"Set the GDAL cache to the needs of the running jobs, and at least `GDAL_CACHE_FLOOR`."
set_gdal_cache!() = lock(() -> GDAL.gdalsetcachemax64(max(GDAL_CACHE_FLOOR, sum(GDAL_CACHE_NEEDS; init = 0))),
                         GDAL_CACHE_LOCK)

"""
    gdal_cache_need(nx, block_height, T) -> Int

The cache a job needs to read or write a band of `nx` cells of type `T` per
row whose blocks are `block_height` rows high: two rows of blocks, since a block
of rows of JuliaMag can start in one row of blocks and end in the next.
"""
gdal_cache_need(nx::Integer, block_height::Integer, ::Type{T}) where {T} = 2 * Int(nx) * Int(block_height) * sizeof(T)

"""
    with_gdal_cache(f, need)

Call `f()` with `need` bytes more in the GDAL cache than the other running jobs
need. The cache is set back after, also on an error.
"""
function with_gdal_cache(f::F, need::Integer) where {F}
    n = Int(need)
    lock(GDAL_CACHE_LOCK) do
        push!(GDAL_CACHE_NEEDS, n)
        set_gdal_cache!()
    end
    try
        return f()
    finally
        lock(GDAL_CACHE_LOCK) do
            deleteat!(GDAL_CACHE_NEEDS, findfirst(==(n), GDAL_CACHE_NEEDS)::Int)
            set_gdal_cache!()
        end
    end
end

const GDAL_GRID_SETTINGS = SettingSpec[NumberSetting("band", "Band"; default = 1, min = 1, integer = true)]

"""
    read_gdal_grid(s, path, settings, progress; format_name = "", driver = "") -> ImportResult

Import one band of a raster file through GDAL as a grid item named after the file.

- `settings["band"]` is the band to read (default 1). A file with more bands
  gives a warning that only this band was read.
- `driver` is a GDAL short driver name, such as `"GSBG"`; `""` lets GDAL pick.
- `format_name` names the format in setting messages.

Nodata becomes `NaN`, and the band scale and offset are applied. The grid is
`Float32` only when every value fits it exactly: a `Byte`, `Int8`, `UInt16`,
`Int16` or `Float32` band with scale 1 and offset 0. Every other band, and every
band with a scale or an offset, gives a `Float64` grid. The grid source records the GDAL
driver's long name, the band type and the `COMPRESSION` of the file.
GDAL errors are thrown as `GridError`. Pass the job's progress, so the import
can be cancelled.
"""
function read_gdal_grid(s::Session, path::AbstractString, settings::AbstractDict, progress::Progress;
                        format_name::AbstractString = "", driver::AbstractString = "")::ImportResult
    v = spec_values(GDAL_GRID_SETTINGS, settings, isempty(format_name) ? "GDAL grid" : String(format_name))
    n = v["band"]::Int
    path = String(path)
    lowercase(file_extension(path)) == ".ers" && check_ers_data_file(path)
    ds = open_gdal(path, String(driver))
    try
        return gdal_errors(() -> import_gdal_band(s, ds, path, n, progress))
    finally
        ArchGDAL.destroy(ds)
    end
end

"Open `path` read-only as a raster. With a `driver` name, only that driver is tried."
function open_gdal(path::String, driver::String)::ArchGDAL.Dataset
    flags = ArchGDAL.OF_READONLY | ArchGDAL.OF_RASTER | ArchGDAL.OF_VERBOSE_ERROR
    ds = gdal_errors() do
        isempty(driver) ? ArchGDAL.unsafe_read(path; flags) :
        ArchGDAL.unsafe_read(path; flags, alloweddrivers = [driver])
    end
    ds.ptr == C_NULL && throw(GridError("GDAL could not open $path"))
    return ds
end

"""
The grid type of a band of type `T`: `Float32` when every value fits it exactly,
else `Float64`. A scale or an offset (`scaled`) makes values such as 50000.1
that a `Float32` cannot hold, so a scaled band is always `Float64`.
"""
grid_eltype(T::Type, scaled::Bool)::DataType =
    !scaled && T in (UInt8, Int8, UInt16, Int16, Float16, Float32) ? Float32 : Float64

function import_gdal_band(s::Session, ds::ArchGDAL.Dataset, path::String, n::Int, progress::Progress)::ImportResult
    m = ArchGDAL.nraster(ds)
    1 <= n <= m || throw(GridError("$path has $(m == 1 ? "1 band" : "$m bands"), so there is no band $n"))
    warnings = ImportWarning[]
    m > 1 && push!(warnings, ImportWarning(0, "The file has $m bands; only band $n of $m was read."))
    band = ArchGDAL.getband(ds, n)
    nx = Int(ArchGDAL.width(ds))
    ny = Int(ArchGDAL.height(ds))
    drv = ArchGDAL.getdriver(ds)
    gt = geotransform(ds)
    # ER Mapper names coordinate systems its own way, such as NUTM33 (see `crs_from_wkt`).
    ers = ArchGDAL.shortname(drv) == "ERS"
    if gt === nothing && ers
        gt = ers_meters_transform(path)
    end
    if gt === nothing
        push!(warnings, ImportWarning(0, "The file has no georeference. The cells are 1 by 1, from 0, 0."))
        gt = (0.0, 1.0, 0.0, Float64(ny), 0.0, -1.0)
    elseif ers
        gt = ers_rotated(path, gt)
    end
    geo = georef_from_affine(gt, nx, ny)
    T = ArchGDAL.pixeltype(band)
    T <: Real || throw(GridError("band $n of $path holds $T values. JuliaMag grids hold real numbers only."))
    # GDAL converts while it reads. Float32 is read as it is; every other type
    # is read as Float64, which holds all of them exactly up to 32 bits.
    W = T === Float32 ? Float32 : Float64
    nodata = ArchGDAL.getnodatavalue(band)
    scale = Float64(ArchGDAL.getscale(band))
    offset = Float64(ArchGDAL.getoffset(band))
    O = grid_eltype(T, scale != 1 || offset != 0)
    compression = ArchGDAL.metadataitem(ds, "COMPRESSION"; domain = "IMAGE_STRUCTURE")
    source = GridSource(path, ArchGDAL.longname(drv), lowercase(string(T)), compression)
    header = GridHeader(nx, ny, geo.dx, geo.dy, geo.x0, geo.y0, geo.rotation,
                        crs_from_wkt(ArchGDAL.getproj(ds); any_name = ers), ArchGDAL.getunittype(band), O, source)
    name = splitext(basename(path))[1]
    need = gdal_cache_need(nx, ArchGDAL.blocksize(band)[2], W)
    fill = sink -> with_gdal_cache(() -> read_band!(sink, band, W, O, nodata, scale, offset, geo.bottom_up), need)
    return import_grid(fill, s, name, header; warnings, progress)
end

"GDAL's affine transform of `ds` as a tuple, or `nothing` when the file has none."
function geotransform(ds::ArchGDAL.Dataset)::Union{Nothing,NTuple{6,Float64}}
    gt = zeros(6)
    ok = GDAL.gdalgetgeotransform(ds, gt) == GDAL.CE_None
    return ok ? (gt[1], gt[2], gt[3], gt[4], gt[5], gt[6]) : nothing
end

"""
Read the band into the sink, a block of at most `GRID_BLOCK_BYTES` rows at a
time, from the first stored row on. Read as `W`, stored as `O`.
"""
function read_band!(sink::GridSink, band, ::Type{W}, ::Type{O}, nodata::Union{Nothing,Float64},
                    scale::Float64, offset::Float64, bottom_up::Bool) where {W,O}
    nx, ny = sink.grid.nx, sink.grid.ny
    k = max(1, GRID_BLOCK_BYTES ÷ (nx * max(sizeof(W), sizeof(O))))
    has_nodata = nodata !== nothing
    nd = has_nodata ? W(nodata) : zero(W)
    buf = Matrix{W}(undef, nx, min(k, ny))
    out = Matrix{O}(undef, nx, min(k, ny))
    r1 = 1
    while r1 <= ny
        rows = min(k, ny - r1 + 1)
        if rows != size(buf, 2)
            buf = Matrix{W}(undef, nx, rows)
            out = Matrix{O}(undef, nx, rows)
        end
        GC.@preserve buf ArchGDAL.read!(band, buf, r1:(r1 + rows - 1), 1:nx)   # ArchGDAL passes a bare pointer
        real_values!(out, buf, has_nodata, nd, scale, offset, !bottom_up)
        # A top-down file: stored row r is grid row ny - r + 1, so the block is flipped.
        put_rows!(sink, bottom_up ? r1 : ny - (r1 + rows - 1) + 1, out)
        r1 += rows
    end
    return nothing
end

"Turn the raw values of `buf` into real values in `out`, with the rows reversed when `flip`."
function real_values!(out::Matrix{O}, buf::Matrix{W}, has_nodata::Bool, nd::W, scale::Float64,
                      offset::Float64, flip::Bool) where {O,W}
    nx, n = size(buf)
    plain = scale == 1 && offset == 0
    @inbounds for c in 1:n
        t = flip ? n - c + 1 : c
        for i in 1:nx
            v = buf[i, c]
            out[i, t] = has_nodata && v == nd ? O(NaN) :
                        plain ? O(v) : O(Float64(v) * scale + offset)
        end
    end
    return out
end

# ---- ER Mapper ---------------------------------------------------------------

"The text of an ER Mapper header: at most 1 MiB, so a wrong file is not read whole."
ers_header(path::String)::String = open(io -> String(read(io, 1 << 20)), path)

"The value of `key = value` in an ER Mapper header, without quotes, or `nothing`."
function ers_field(text::String, key::String)::Union{Nothing,String}
    m = match(Regex("^\\s*" * key * "\\s*=\\s*\"?([^\"\\r\\n]*)\"?", "m"), text)
    return m === nothing ? nothing : String(strip(something(m.captures[1], "")))
end

"""
The data file of an ER Mapper header: the `DataFile` entry next to the header,
else the header path without `.ers`. Throws `GridError` when it is missing, so
the message names the file (GDAL only says it does not know the format).
"""
function check_ers_data_file(path::String)
    isfile(path) || return nothing             # GDAL says the header is missing
    text = try
        ers_header(path)
    catch e
        e isa InterruptException && rethrow()
        return nothing                         # GDAL reports why it cannot be read
    end
    name = ers_field(text, "DataFile")
    data = name === nothing || isempty(name) ? splitext(path)[1] : joinpath(dirname(path), name)
    isfile(data) || throw(GridError("the data file $data of the ER Mapper header $path is missing"))
    return nothing
end

"An ER Mapper angle `degrees:minutes:seconds` (or plain degrees) in degrees."
function ers_angle(text::String, path::String)::Float64
    parts = split(strip(text), ':')
    nums = [tryparse(Float64, p) for p in parts]
    (1 <= length(nums) <= 3 && all(!isnothing, nums)) ||
        throw(GridError("the rotation \"$text\" in $path is not an angle"))
    deg = 0.0
    for (k, x) in enumerate(nums)
        deg += abs(x::Float64) / 60.0^(k - 1)
    end
    return startswith(strip(text), "-") ? -deg : deg
end

"""
The affine transform of an ER Mapper header with a `RAW` coordinate space, or
`nothing`. Such a header gives its registration point as `MetersX` and
`MetersY`. GDAL reads these only from version 3.14 on (GDAL pull request
15261); this is the same rule. The registration point sits at cell
`RegistrationCellX`, `RegistrationCellY`, counted from 0 at the outer
north-west corner.
"""
function ers_meters_transform(path::String)::Union{Nothing,NTuple{6,Float64}}
    text = ers_header(path)
    num(key, default) = (v = ers_field(text, key); v === nothing ? default : tryparse(Float64, v))
    mx = num("MetersX", nothing)
    my = num("MetersY", nothing)
    (mx === nothing || my === nothing) && return nothing
    xd = something(num("Xdimension", 1.0), 1.0)
    yd = something(num("Ydimension", 1.0), 1.0)
    cx = something(num("RegistrationCellX", 0.0), 0.0)
    cy = something(num("RegistrationCellY", 0.0), 0.0)
    return (mx - cx * xd, xd, 0.0, my + cy * yd, 0.0, -yd)
end

"""
GDAL ignores the `Rotation` of an ER Mapper header. ER Mapper turns the grid
counter-clockwise by that angle about the registration point (`Eastings`,
`Northings`, at cell `RegistrationCellX`, `RegistrationCellY`). Apply it to
GDAL's north-up affine transform `gt`.
"""
function ers_rotated(path::String, gt::NTuple{6,Float64})::NTuple{6,Float64}
    gt[3] == 0 && gt[5] == 0 || return gt     # GDAL already gave a rotation
    text = ers_header(path)
    rot = ers_field(text, "Rotation")
    θ = rot === nothing ? 0.0 : ers_angle(rot, path)
    θ == 0 && return gt
    cell(key) = (v = ers_field(text, key); v === nothing ? 0.0 : something(tryparse(Float64, v), 0.0))
    rx, ry = cell("RegistrationCellX"), cell("RegistrationCellY")
    gx, a, _, gy, _, d = gt
    ex, ey = gx + rx * a, gy + ry * d         # the registration point
    c, s = cosd(θ), sind(θ)
    return (ex - rx * a * c + ry * d * s, a * c, -d * s, ey - rx * a * s - ry * d * c, a * s, d * c)
end

# ---- export ------------------------------------------------------------------

"""
The GDAL creation options of a GeoTIFF export (spec 7). `NUM_THREADS` lets
GDAL compress tiles in parallel: one thread managed 35 MB/s (docs/bench.md).
"""
const GEOTIFF_OPTIONS = ["COMPRESS=DEFLATE", "PREDICTOR=3", "TILED=YES", "BIGTIFF=IF_SAFER", "NUM_THREADS=ALL_CPUS"]

"What an ER Mapper export writes for `NaN`: the Geosoft float dummy, so Oasis reads the dummies."
const ERS_NODATA = -1.0e32

"""
Write the grid of export `x` with the GDAL driver `driver` to the temp file
`tmp`: one band of the grid's type, with the affine transform `gt`, the
coordinate system as WKT, and `NaN` written as `nodata`. Rows are written in
blocks, north row first, as GDAL stores them. The file is closed before this
returns, also on an error or a cancel. Returns the notes for the report.
"""
function write_gdal_grid!(x::GridExport, tmp::String, driver::String, options::Vector{String},
                          gt::NTuple{6,Float64}, nodata::Float64)::Vector{String}
    g = x.grid
    T = g.eltype
    wkt = isempty(g.crs) ? "" : crs_wkt(g.crs)
    notes = String[]
    isempty(g.crs) || !isempty(wkt) ||
        push!(notes, "PROJ could not read the coordinate system of the grid, so $(basename(x.path)) has none.")
    gdal_errors() do
        ds = ArchGDAL.unsafe_create(tmp; driver = ArchGDAL.getdriver(driver), width = g.nx, height = g.ny,
                                    nbands = 1, dtype = T, options)
        ds.ptr == C_NULL && throw(GridError("GDAL could not create $tmp"))
        try
            v = collect(gt)
            GC.@preserve v ArchGDAL.setgeotransform!(ds, v)   # ArchGDAL passes a bare pointer
            isempty(wkt) || ArchGDAL.setproj!(ds, wkt)
            band = ArchGDAL.getband(ds, 1)
            ArchGDAL.setnodatavalue!(band, nodata)
            dummy = T(nodata)
            with_gdal_cache(gdal_cache_need(g.nx, ArchGDAL.blocksize(band)[2], T)) do
                each_row_block(x; north_first = true) do j1, block
                    isnan(dummy) || replace_nan!(block, dummy)
                    reverse!(block; dims = 2)              # north row first, as stored
                    n = size(block, 2)
                    r1 = g.ny - (j1 + n - 1) + 1           # grid row j is stored row ny - j + 1
                    GC.@preserve block ArchGDAL.write!(band, block, r1:(r1 + n - 1), 1:g.nx)
                end
            end
        finally
            ArchGDAL.destroy(ds)                           # close before the rename (Windows)
        end
    end
    return notes
end

"Set each `NaN` of `block` to `dummy`."
function replace_nan!(block::Matrix{T}, dummy::T) where {T}
    @inbounds for k in eachindex(block)
        isnan(block[k]) && (block[k] = dummy)
    end
    return block
end

"""
Remove an old `<path>.aux.xml` once the new files of export `x` are in place.
GDAL reads such a file with the grid, and its coordinate system or nodata
would override those of the new file.
"""
remove_old_aux!(x::GridExport) =
    remove_after!(x, x.path * ".aux.xml", "GDAL would read its old settings with the new grid",
                  "The old $(basename(x.path)).aux.xml could not be removed; delete it by hand, " *
                  "or GDAL may read wrong settings from it.")

"""
    export_geotiff(s, item_id, path; progress = NO_PROGRESS, record = true)::ExportResult

Write grid `item_id` to a GeoTIFF file through GDAL (spec 7): one band of the
grid's type, `NaN` cells as `NaN` with nodata `NaN`, the coordinate system as
WKT, and the affine transform of `affine_from_grid` (the rotation is kept).
The creation options are `GEOTIFF_OPTIONS`. An old `<path>.aux.xml` is removed.

The grid is busy for reading while the export runs (ruling R12). Rows are
written in blocks, north row first; cancel is checked once per block. The file
is written to a temp name and renamed when complete, so a cancel or a failure
leaves no new file. Recorded as `"export.geotiff"` unless `record` is false.
"""
function export_geotiff(s::Session, item_id::AbstractString, path::AbstractString;
                        progress::Progress = NO_PROGRESS, record::Bool = true)::ExportResult
    return run_grid_export(s, "export.geotiff", item_id, path, progress, record) do x
        tmp = output_path!(x, x.path)
        notes = write_gdal_grid!(x, tmp, "GTiff", GEOTIFF_OPTIONS, affine_from_grid(x.grid), NaN)
        remove_old_aux!(x)
        return notes
    end
end

"""
    export_ers(s, item_id, path; progress = NO_PROGRESS, record = true)::ExportResult

Write grid `item_id` to an ER Mapper header `path` (it must end in `.ers`) and
its data file, `path` without `.ers`, through GDAL (spec 7). The data has the
grid's type, north row first; `NaN` is written as `-1.0e32` with
`NullCellValue = -1e+32`, the Geosoft float dummy, so Oasis reads the dummies.

GDAL refuses a rotated affine transform for ER Mapper. So GDAL writes the grid
without rotation, registered at the outer north-west corner, and `Rotation`
in the header is then set to the grid's rotation (`ers_dms`). ER Mapper turns
the grid about that corner, which gives the grid's own georeference
(`ers_rotated` reads it back the same way). An old `<path>.aux.xml` is removed.
A coordinate system that ER Mapper has no name for is lost, with a note in
the report.

Both files are written to temp names and renamed when complete. See
`export_geotiff` for the busy mark, cancel and the history.
"""
function export_ers(s::Session, item_id::AbstractString, path::AbstractString;
                    progress::Progress = NO_PROGRESS, record::Bool = true)::ExportResult
    lowercase(file_extension(String(path))) == ".ers" ||
        throw(ToolError("The ER Mapper file $path must end in .ers, since its data file is the same name without .ers."))
    return run_grid_export(s, "export.ers", item_id, path, progress, record) do x
        g = x.grid
        # GDAL names the data file after the header: header `t.ers`, data file `t`.
        # The data file is first in the list, so it is renamed before the header.
        tmp = output_path!(x, String(chop(x.path; tail = 4)))
        header = output_path!(x, x.path; tmp = tmp * ".ers")
        gx, _, _, gy, _, _ = affine_from_grid(g)       # the north-west corner, which rotation keeps
        notes = write_gdal_grid!(x, header, "ERS", String[], (gx, g.dx, 0.0, gy, 0.0, -g.dy), ERS_NODATA)
        # GDAL writes the RAW projection when ER Mapper has no name for the coordinate system.
        if isempty(notes) && !isempty(g.crs) && ers_field(ers_header(header), "Projection") in (nothing, "RAW")
            push!(notes, "ER Mapper has no name for the coordinate system of the grid, so " *
                         "$(basename(x.path)) has none. Export to GeoTIFF to keep it.")
        end
        set_ers_header!(header, basename(x.path), g.rotation)
        remove_old_aux!(x)
        return notes
    end
end

"""
Set `Name` to the final file name `name` and `Rotation` to `rotation` degrees
in the ER Mapper header `path` that GDAL wrote. GDAL writes no `DataFile`, so
the data file is the header name without `.ers`, which the rename keeps.
For a grid with no coordinate system GDAL writes no `CoordinateSpace`; the
header then gets one with the `RAW` datum and projection, which ER Mapper
needs and which holds the rotation.
"""
function set_ers_header!(path::String, name::String, rotation::Float64)
    text = read(path, String)
    space = r"^\s*CoordinateSpace Begin\s*$"m
    if !occursin(space, text)
        raster = ers_entry(text, r"^\s*RasterInfo Begin\s*$"m, "RasterInfo block")
        block = "\tCoordinateSpace Begin\n\t\tDatum\t= \"RAW\"\n\t\tProjection\t= \"RAW\"\n" *
                "\t\tCoordinateType\t= EN\n\t\tRotation\t= 0:0:0.0\n\tCoordinateSpace End\n"
        text = replace(text, raster => line -> block * line)
    end
    ers_entry(text, space, "CoordinateSpace block")
    for (r, what, value) in ((r"^\s*Name\s*=.*$"m, "Name entry", "\"$name\""),
                             (r"^\s*Rotation\s*=.*$"m, "Rotation entry", ers_dms(rotation)))
        text = replace(text, ers_entry(text, r, what) => line -> line[1:something(findfirst('=', line))] * " " * value)
    end
    write(path, text)
    return nothing
end

"Return `r`, or throw `GridError` when the header `text` does not match it once."
function ers_entry(text::String, r::Regex, what::String)::Regex
    count(r, text) == 1 || throw(GridError("the ER Mapper header that GDAL wrote has no single $what"))
    return r
end

"""
An angle in degrees as ER Mapper writes it: `degrees:minutes:seconds`, such
as `15:0:0.0` or `-33:18:0.0`. The seconds are rounded to a nano second of arc
(about 3e-13 degrees), so `ers_angle` reads back the same angle to that.
"""
function ers_dms(θ::Float64)::String
    n = round(Int64, abs(θ) * 3600e9)          # nano seconds of arc
    d, r = divrem(n, 3_600_000_000_000)
    m, ns = divrem(r, 60_000_000_000)
    return (θ < 0 && n > 0 ? "-" : "") * "$d:$m:$(plain_decimal(string(ns / 1e9)))"
end

# ---- importers ---------------------------------------------------------------

run_geotiff_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult =
    read_gdal_grid(s, path, settings, progress; format_name = "GeoTIFF")

run_ers_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult =
    read_gdal_grid(s, path, settings, progress; format_name = "ER Mapper")

register_importer!(ImporterSpec("import.geotiff", "GeoTIFF", [".tif", ".tiff"], ITEM_GRID,
                                GDAL_GRID_SETTINGS, run_geotiff_importer))
register_importer!(ImporterSpec("import.ers", "ER Mapper", [".ers"], ITEM_GRID,
                                GDAL_GRID_SETTINGS, run_ers_importer))

"Run the GeoTIFF exporter. It has no settings. Not recorded: the job that runs it records it."
function run_geotiff_exporter(s::Session, item_id::String, path::String, settings::AbstractDict,
                              progress::Progress)::ExportResult
    spec_values(SettingSpec[], settings, "GeoTIFF export")
    return export_geotiff(s, item_id, path; progress, record = false)
end

"Run the ER Mapper exporter. It has no settings. Not recorded: the job that runs it records it."
function run_ers_exporter(s::Session, item_id::String, path::String, settings::AbstractDict,
                          progress::Progress)::ExportResult
    spec_values(SettingSpec[], settings, "ER Mapper export")
    return export_ers(s, item_id, path; progress, record = false)
end

register_exporter!(ExporterSpec("export.geotiff", "GeoTIFF", ".tif", ITEM_GRID, SettingSpec[], run_geotiff_exporter))
register_exporter!(ExporterSpec("export.ers", "ER Mapper", ".ers", ITEM_GRID, SettingSpec[], run_ers_exporter))
