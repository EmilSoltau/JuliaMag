# The `.grd` importer, and the coordinate system side files of Geosoft grids.
#
# Geosoft and Surfer both use `.grd`. The first bytes tell them apart (research
# section 7): Surfer files start with `DSBB` (Surfer 6), `DSRB` (Surfer 7) or
# `DSAA` (Surfer ASCII), and a Geosoft file has a header `read_grd_header`
# accepts. Surfer grids are read through GDAL with the driver named.
#
# A Geosoft grid keeps its coordinate system in side files (research section 5):
# `<file>.grd.xml` (Geosoft XML metadata) and `<file>.grd.gi` (a compound file
# with an `ipj` stream). The `.xml` is tried first, then the `.gi`. A side file
# that cannot be read gives a warning, never a failed import.

import EzXML

"The kind of `.grd` file of each Surfer magic, its words in the report, and its GDAL driver."
const SURFER_GRD = [(Vector{UInt8}("DSBB"), :surfer6, "Surfer 6", "GSBG"),
                    (Vector{UInt8}("DSRB"), :surfer7, "Surfer 7", "GS7BG"),
                    (Vector{UInt8}("DSAA"), :surfer_ascii, "Surfer ASCII", "GSAG")]

"""
    grd_kind(path)::Symbol

What a `.grd` file is, from its first bytes: `:geosoft` (a header that
`read_grd_header` accepts), `:surfer6`, `:surfer7`, `:surfer_ascii`, or
`:unknown`.
"""
function grd_kind(path::AbstractString)::Symbol
    head = open(io -> read(io, 4), String(path))
    for (magic, kind, _, _) in SURFER_GRD
        head == magic && return kind
    end
    try
        open(read_grd_header, String(path))
        return :geosoft
    catch e
        e isa GridError || rethrow()
        return :unknown
    end
end

"The message for a `.grd` file that is neither Geosoft nor Surfer."
function not_grd_message(path::String)::String
    head = open(io -> read(io, 4), path)
    what = isempty(head) ? "the file is empty" : "it starts with " * join(string.(head; base = 16, pad = 2), " ")
    return "$(basename(path)) is not a Geosoft or Surfer grid ($what)"
end

"""
Import a `.grd` file: a Geosoft grid with the coordinate system of its side
files, or a Surfer grid through GDAL. The report's first line says which format
was found.
"""
function run_grd_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult
    spec_values(SettingSpec[], settings, "Geosoft or Surfer grid")
    kind = grd_kind(path)
    kind === :unknown && throw(GridError(not_grd_message(path)))
    if kind === :geosoft
        crs, warnings = grd_side_crs(path)
        r = read_geosoft_grd(s, path, settings, progress; crs, warnings)
        words = "Geosoft"
    else
        _, _, words, driver = SURFER_GRD[findfirst(t -> t[2] === kind, SURFER_GRD)::Int]
        r = read_gdal_grid(s, path, Dict{String,Any}(), progress; format_name = words, driver)
    end
    return ImportResult(r.item, r.warnings, r.rows, r.lines, "This .grd file is a $words grid. $(r.summary)")
end

"""
The coordinate system of the Geosoft grid `path` from its side files, and the
warnings for the job report. `""` when no side file gives one.
"""
function grd_side_crs(path::String)::Tuple{String,Vector{ImportWarning}}
    warnings = ImportWarning[]
    name, from = "", ""
    for (ext, find) in ((".xml", grd_xml_projection), (".gi", grd_gi_projection))
        side = path * ext
        isfile(side) || continue
        found = try
            find(side)
        catch e
            e isa GridError || e isa SystemError || e isa Base.IOError || rethrow()
            msg = e isa GridError ? e.msg : sprint(showerror, e)
            push!(warnings, ImportWarning(0, "The coordinate system in $(basename(side)) could not be read: $msg"))
            continue
        end
        code, n = found
        code === nothing || return code, warnings
        if isempty(name) && !isempty(n)
            name, from = n, ext
        end
    end
    msg = "No coordinate system was found for $(basename(path)). Set it in the grid properties."
    isempty(name) || (msg *= " The $from file names it \"$name\", which Proj does not know.")
    push!(warnings, ImportWarning(0, msg))
    return "", warnings
end

# ---- .grd.xml ----------------------------------------------------------------

"Guards EzXML, which keeps the errors of libxml2 in one global list."
const XML_LOCK = ReentrantLock()

"""
The `type`, `name` and `wellknown_epsg` of the `dataset/georeference/projection`
element of the XML file `path`, or `nothing` when it has none. Throws
`GridError` when the file is not XML.

Nothing is printed. libxml2 keeps its error handler per thread and prints
errors on a thread where EzXML set none; `noerror` and `nowarning` stop that.
EzXML may still log a warning when a file has several errors, so its log is
dropped. The lock guards EzXML's error list.
"""
function xml_projection(path::String)::Union{Nothing,NTuple{3,String}}
    return lock(XML_LOCK) do
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            doc = try
                EzXML.readxml(path; noerror = true, nowarning = true)
            catch e
                # EzXML throws `ErrorException` when libxml2 reported nothing.
                e isa EzXML.XMLError || e isa ErrorException || rethrow()
                throw(GridError("$(basename(path)) is not valid XML"))
            end
            p = findfirst("//*[local-name()='dataset']/*[local-name()='georeference']/*[local-name()='projection']",
                          doc)
            p === nothing && return nothing
            attr(key) = haskey(p, key) ? String(strip(p[key])) : ""
            return (attr("type"), attr("name"), attr("wellknown_epsg"))
        end
    end
end

"""
The coordinate system of a Geosoft `.grd.xml` file and the name it gives.
Only `dataset/georeference/projection` is read, not the copies under `lineage`.
Throws `GridError` when the file is not XML.
"""
function grd_xml_projection(path::String)::Tuple{Union{Nothing,String},String}
    p = xml_projection(path)
    p === nothing && return nothing, ""
    kind, name, epsg = p
    uppercase(kind) == "UNKNOWN" && return nothing, ""
    n = tryparse(Int, epsg)
    n !== nothing && n > 0 && valid_crs("EPSG:$n") && return "EPSG:$n", name
    return crs_from_name(name), name
end

"""
    crs_from_grd_xml(path)::Union{Nothing,String}

The coordinate system in a Geosoft `.grd.xml` file (`path` is the `.xml` file):
`"EPSG:n"` from `wellknown_epsg`, else from the `name` through `crs_from_name`.
`nothing` when the file has none or says `type="UNKNOWN"`. Throws `GridError`
when the file is not XML.
"""
crs_from_grd_xml(path::AbstractString)::Union{Nothing,String} = first(grd_xml_projection(String(path)))

# ---- .grd.gi -----------------------------------------------------------------

"The first 4 bytes of a frame inside an `ipj` stream (`ff 00 e1 1e`), as a little-endian number."
const IPJ_FRAME = 0x1ee100ff
"Where the full coordinate system name sits in an `ipj` stream, and its longest length."
const IPJ_NAME_OFFSET = 76
const IPJ_NAME_BYTES = 64

"""
The EPSG code of an `ipj` stream, or `nothing`. The frames after the first
start at byte 32. Each is 32 bytes of header (magic, payload length) and then
its payload. A payload that starts with `"EPSG"` holds the code as a 32-bit
number at payload byte 64.
"""
function ipj_epsg(b::Vector{UInt8})::Union{Nothing,String}
    p = 32
    while p + 32 <= length(b)
        cfb_u32(b, p) == IPJ_FRAME || break
        len = Int(cfb_u32(b, p + 4))
        q = p + 32
        len <= length(b) - q || break
        if len >= 68 && b[q + 1:q + 5] == UInt8['E', 'P', 'S', 'G', 0]
            n = Int(reinterpret(Int32, cfb_u32(b, q + 64)))
            n > 0 && valid_crs("EPSG:$n") && return "EPSG:$n"
        end
        p = q + len
    end
    return nothing
end

"The full coordinate system name of an `ipj` stream, or `\"\"`."
function ipj_name(b::Vector{UInt8})::String
    length(b) > IPJ_NAME_OFFSET || return ""
    return grd_text(view(b, IPJ_NAME_OFFSET + 1:min(length(b), IPJ_NAME_OFFSET + IPJ_NAME_BYTES)))
end

"""
The coordinate system of a Geosoft `.grd.gi` file and the name it gives.
Throws `GridError` when the file is damaged.
"""
function grd_gi_projection(path::String)::Tuple{Union{Nothing,String},String}
    b = read_cfb_stream(path, "ipj")
    b === nothing && return nothing, ""
    code = ipj_epsg(b)
    code === nothing || return code, ""
    name = ipj_name(b)
    return (isempty(name) ? nothing : crs_from_name(name)), name
end

"""
    crs_from_grd_gi(path)::Union{Nothing,String}

The coordinate system in a Geosoft `.grd.gi` file (`path` is the `.gi` file),
read from its `ipj` stream: the code of an `"EPSG"` frame, else the coordinate
system name (stream byte 76) through `crs_from_name`. `nothing` when there is
none or Proj does not know the name. Throws `GridError` when the file is damaged.
"""
crs_from_grd_gi(path::AbstractString)::Union{Nothing,String} = first(grd_gi_projection(String(path)))

register_importer!(ImporterSpec("import.grd", "Geosoft or Surfer grid", [".grd"], ITEM_GRID,
                                SettingSpec[], run_grd_importer))
