# Grid import through GDAL: GeoTIFF, ER Mapper, and Surfer (Task 6 forces the driver).
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

function __init__()
    GDAL.cplseterrorhandler(@cfunction(quiet_gdal_error, Cvoid, (GDAL.CPLErr, Cint, Cstring)))
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

const GDAL_GRID_SETTINGS = SettingSpec[NumberSetting("band", "Band"; default = 1, min = 1, integer = true)]

"""
    read_gdal_grid(s, path, settings, progress; format_name = "", driver = "") -> ImportResult

Import one band of a raster file through GDAL as a grid item named after the file.

- `settings["band"]` is the band to read (default 1). A file with more bands
  gives a warning that only this band was read.
- `driver` is a GDAL short driver name, such as `"GSBG"`; `""` lets GDAL pick.
- `format_name` names the format in setting messages.

Nodata becomes `NaN`, and the band scale and offset are applied. `Byte`,
`Int8`, `UInt16` and `Int16` bands become `Float32`; `Int32`, `UInt32` and
`Float64` become `Float64`; `Float32` stays. The grid source records the GDAL
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

"The grid type of a band type: `Float32` when every value fits exactly, else `Float64`."
grid_eltype(T::Type)::DataType = T in (UInt8, Int8, UInt16, Int16, Float16, Float32) ? Float32 : Float64

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
    if gt === nothing
        push!(warnings, ImportWarning(0, "The file has no georeference. The cells are 1 by 1, from 0, 0."))
        gt = (0.0, 1.0, 0.0, Float64(ny), 0.0, -1.0)
    elseif ArchGDAL.shortname(drv) == "ERS"
        gt = ers_rotated(path, gt)
    end
    geo = georef_from_affine(gt, nx, ny)
    T = ArchGDAL.pixeltype(band)
    T <: Real || throw(GridError("band $n of $path holds $T values. JuliaMag grids hold real numbers only."))
    O = grid_eltype(T)
    # GDAL converts while it reads. Float32 is read as it is; every other type
    # is read as Float64, which holds all of them exactly up to 32 bits.
    W = T === Float32 ? Float32 : Float64
    nodata = ArchGDAL.getnodatavalue(band)
    scale = Float64(ArchGDAL.getscale(band))
    offset = Float64(ArchGDAL.getoffset(band))
    compression = ArchGDAL.metadataitem(ds, "COMPRESSION"; domain = "IMAGE_STRUCTURE")
    source = GridSource(path, ArchGDAL.longname(drv), lowercase(string(T)), compression)
    header = GridHeader(nx, ny, geo.dx, geo.dy, geo.x0, geo.y0, geo.rotation,
                        crs_from_wkt(ArchGDAL.getproj(ds)), ArchGDAL.getunittype(band), O, source)
    name = splitext(basename(path))[1]
    fill = sink -> read_band!(sink, band, W, O, nodata, scale, offset, geo.bottom_up)
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

# ---- importers ---------------------------------------------------------------

run_geotiff_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult =
    read_gdal_grid(s, path, settings, progress; format_name = "GeoTIFF")

run_ers_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult =
    read_gdal_grid(s, path, settings, progress; format_name = "ER Mapper")

register_importer!(ImporterSpec("import.geotiff", "GeoTIFF", [".tif", ".tiff"], ITEM_GRID,
                                GDAL_GRID_SETTINGS, run_geotiff_importer))
register_importer!(ImporterSpec("import.ers", "ER Mapper", [".ers"], ITEM_GRID,
                                GDAL_GRID_SETTINGS, run_ers_importer))
