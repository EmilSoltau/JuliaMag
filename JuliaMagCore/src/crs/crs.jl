# Coordinate systems through PROJ (spec 5.3, 6.6).
#
# A coordinate system is a code such as "EPSG:7855", or any other text PROJ
# reads as a coordinate system. Blank means unknown.
#
# Each call makes its own PROJ context, so calls on different threads do not
# share PROJ state. The context has a quiet log function: PROJ errors do not
# throw out of C code (Proj.jl's default log function throws). We read errors
# from return values instead: a NULL object, or a point that comes back as
# infinity. The log function keeps the lines PROJ logs in a `ProjLog` of the
# context, so a caller can show them (see `with_crs` and `proj_messages`).
#
# PROJ logs nothing when it picks a ballpark transformation (checked with
# PROJ 9.9). So a `Reprojector` asks PROJ which operation it used, and adds a
# line when that operation is a ballpark one.

using Proj

"Most lines a `ProjLog` keeps. Later ones are counted, not kept."
const MAX_PROJ_LINES = 100

"""
The lines PROJ logged for one PROJ context, each kept once. PROJ calls the log
function from C on the thread that called PROJ, so the lines take a lock.
"""
mutable struct ProjLog
    lock::Threads.SpinLock
    lines::Vector{String}
    "Lines not kept, past `MAX_PROJ_LINES`."
    more::Int
end

ProjLog() = ProjLog(Threads.SpinLock(), String[], 0)

function add_line!(log::ProjLog, line::String)
    @lock log.lock begin
        line in log.lines && return nothing
        length(log.lines) < MAX_PROJ_LINES ? push!(log.lines, line) : (log.more += 1)
    end
    return nothing
end

"The lines of the log, with a note for the lines not kept."
function log_lines(log::ProjLog)::Vector{String}
    lines, more = @lock log.lock (copy(log.lines), log.more)
    more > 0 && push!(lines, "PROJ logged $more more lines.")
    return lines
end

# PROJ calls this for each log message of our contexts, with the `ProjLog` of
# the context as `data`. It must never throw into C.
function collect_proj_log(data::Ptr{Cvoid}, ::Cint, msg::Cstring)::Cvoid
    try
        (data == C_NULL || msg == C_NULL) && return nothing
        add_line!(unsafe_pointer_to_objref(data)::ProjLog, unsafe_string(msg))
    catch
    end
    return nothing
end

"""
A new PROJ context with a quiet log function that keeps the lines in `log`.
Keep `log` alive while the context lives. Free it with `Proj.proj_context_destroy`.
"""
function quiet_context(log::ProjLog)::Ptr{Proj.PJ_CONTEXT}
    ctx = Proj.proj_context_create()
    ctx == C_NULL && throw(ArgumentError("PROJ could not make a context"))
    Proj.proj_log_func(pointer_from_objref(log), @cfunction(collect_proj_log, Cvoid, (Ptr{Cvoid}, Cint, Cstring)),
                       ctx)
    Proj.proj_context_set_search_paths(1, [Proj.PROJ_DATA[]], ctx)
    return ctx
end

"""
    with_crs(f, code; messages = nothing)

Call `f(pj)` with the PROJ object of coordinate system `code` and return its
result. Returns `nothing` when PROJ cannot read `code` as a coordinate system.
Never throws for bad codes. An error in `f` is thrown as it is.
The lines PROJ logged meanwhile are added to the vector `messages`, if given.
"""
with_crs(f::F, code::AbstractString; messages::Union{Nothing,Vector{String}} = nothing) where {F} =
    with_crs_context((pj, _) -> f(pj), code; messages)

"Like `with_crs`, but call `f(pj, ctx)` with the PROJ context of `pj` too."
function with_crs_context(f::F, code::AbstractString; messages::Union{Nothing,Vector{String}} = nothing) where {F}
    (isempty(code) || occursin('\0', code)) && return nothing
    log = ProjLog()
    GC.@preserve log begin
        ctx = quiet_context(log)
        pj = Ptr{Proj.PJ}(C_NULL)
        try
            # Only reading the code counts as "not a coordinate system"; the quiet
            # log function means PROJ reports that with NULL, not with an error.
            pj = try
                Proj.proj_create(String(code), ctx)
            catch e
                e isa InterruptException && rethrow()
                Ptr{Proj.PJ}(C_NULL)
            end
            (pj == C_NULL || Proj.proj_is_crs(pj) == 0) && return nothing
            return f(pj, ctx)
        finally
            pj == C_NULL || Proj.proj_destroy(pj)
            Proj.proj_context_destroy(ctx)
            messages === nothing || append!(messages, log_lines(log))
        end
    end
end

"""
    valid_crs(code)::Bool

True when PROJ can build a coordinate system from `code`, such as `"EPSG:7855"`.
Never throws: garbage, blank text and map projections that are not a full
coordinate system give `false`.
"""
valid_crs(code::AbstractString)::Bool = with_crs(_ -> true, code) === true

"""
    crs_name(code)::String

The name of a coordinate system, such as `"GDA2020 / MGA zone 55"` for
`"EPSG:7855"`. Blank for a code that `valid_crs` refuses.
"""
function crs_name(code::AbstractString)::String
    name = with_crs(pj -> Proj.proj_get_name(pj), code)
    return name isa AbstractString ? String(name) : ""
end

"True when `code` is a coordinate system in degrees of longitude and latitude."
function is_geographic(code::AbstractString)::Bool
    geo = (Proj.PJ_TYPE_GEOGRAPHIC_CRS, Proj.PJ_TYPE_GEOGRAPHIC_2D_CRS, Proj.PJ_TYPE_GEOGRAPHIC_3D_CRS)
    return with_crs(pj -> Proj.proj_get_type(pj) in geo, code) === true
end

"""
    crs_axis_unit(code)::Union{Nothing,Tuple{String,Float64}}

The unit of the first axis of a coordinate system: its name, such as
`"metre"` or `"degree"`, and its size in metres (radians for an angle).
`nothing` when PROJ cannot tell, such as for a compound coordinate system, and for a
code that is not known.

It is public, not exported: call it as `JuliaMagCore.crs_axis_unit`. The UI uses it to
show lengths with their unit, such as a cell size of "25 m".
"""
function crs_axis_unit(code::AbstractString)::Union{Nothing,Tuple{String,Float64}}
    r = with_crs_context(code) do pj, ctx
        cs = Proj.proj_crs_get_coordinate_system(pj, ctx)
        cs == C_NULL && return nothing
        try
            factor, name = Ref{Cdouble}(0.0), Ref{Cstring}(C_NULL)
            ok = Proj.proj_cs_get_axis_info(cs, 0, C_NULL, C_NULL, C_NULL, factor, name, C_NULL, C_NULL, ctx)
            (ok == 0 || name[] == C_NULL) && return nothing
            return (unsafe_string(name[]), Float64(factor[]))
        finally
            Proj.proj_destroy(cs)
        end
    end
    return r isa Tuple{String,Float64} ? r : nothing
end

"""
    crs_from_wkt(wkt; any_name = false)::String

The code of a coordinate system given as WKT text, such as one read from a
GeoTIFF. `"EPSG:n"` when PROJ identifies it as that EPSG code with full
confidence (100), else the WKT text itself. Blank text gives `""`.
Never throws.

With `any_name`, the name may differ too: an EPSG code whose definition PROJ
finds the same counts when it is the only one. PROJ gives such a code
confidence 70. ER Mapper headers need this: they name a coordinate system by
ER Mapper's own names, such as `NUTM33` for `"EPSG:32633"`.
"""
function crs_from_wkt(wkt::AbstractString; any_name::Bool = false)::String
    text = String(strip(wkt))
    isempty(text) && return ""
    code = with_crs_context((pj, ctx) -> epsg_code(pj, ctx; any_name), text)
    return code isa String ? code : text
end

"""
The EPSG code of `pj` when PROJ is sure of it (confidence 100), else `nothing`.
With `any_name`, else the one code of confidence 70 or more whose definition
is the same as that of `pj` (see `same_definition_code`).
A candidate is checked for confidence 100 too, when it has no id.
"""
function epsg_code(pj::Ptr{Proj.PJ}, ctx::Ptr{Proj.PJ_CONTEXT}; any_name::Bool = false)::Union{Nothing,String}
    confidence = Ref(Ptr{Cint}(C_NULL))
    list = Proj.proj_identify(pj, "EPSG", confidence, C_NULL, ctx)
    list == C_NULL && return nothing
    try
        n = Proj.proj_list_get_count(list)
        same = Set{String}()
        for k in 1:n
            c = unsafe_load(confidence[], k)
            (c == 100 || any_name && c >= 70) || continue
            obj = Proj.proj_list_get(list, k - 1, ctx)
            obj == C_NULL && continue
            try
                auth = Proj.proj_get_id_auth_name(obj, 0)
                id = Proj.proj_get_id_code(obj, 0)
                c == 100 && auth isa String && id isa String && return "$auth:$id"
                # A bound coordinate system (see `same_definition_code`) gives candidates without an id.
                if any_name
                    code = same_definition_code(obj, pj, ctx)
                    code === nothing || push!(same, code)
                end
            finally
                Proj.proj_destroy(obj)
            end
        end
        return length(same) == 1 ? only(same) : nothing
    finally
        confidence[] == C_NULL || Proj.proj_int_list_destroy(confidence[])
        Proj.proj_list_destroy(list)
    end
end

"""
The EPSG code of the candidate `obj` that `proj_identify` found for `pj`, when
the coordinate system of that code has the same definition as `pj`, else
`nothing`. A candidate of confidence 70 may have no id; its name then gives
the code (`crs_from_name`).

WKT with `TOWGS84`, as GDAL gives for ER Mapper, makes PROJ build a bound
coordinate system: the coordinate system and a shift to WGS 84. An EPSG code
holds no such shift, so the coordinate system inside is compared.
"""
function same_definition_code(obj::Ptr{Proj.PJ}, pj::Ptr{Proj.PJ}, ctx::Ptr{Proj.PJ_CONTEXT})::Union{Nothing,String}
    auth = Proj.proj_get_id_auth_name(obj, 0)
    id = Proj.proj_get_id_code(obj, 0)
    name = Proj.proj_get_name(obj)
    code = (auth isa String && id isa String) ? "$auth:$id" : name isa String ? crs_from_name(name) : nothing
    code === nothing && return nothing
    ref = Proj.proj_create(code, ctx)
    ref == C_NULL && return nothing
    base = Proj.proj_get_type(pj) == Proj.PJ_TYPE_BOUND_CRS ? Proj.proj_get_source_crs(pj, ctx) : C_NULL
    try
        target = base == C_NULL ? pj : base
        same = Proj.proj_is_equivalent_to_with_ctx(ref, target, Proj.PJ_COMP_EQUIVALENT_EXCEPT_AXIS_ORDER_GEOGCRS, ctx)
        return same == 1 ? code : nothing
    finally
        Proj.proj_destroy(ref)
        base == C_NULL || Proj.proj_destroy(base)
    end
end

"The kinds of coordinate system `crs_from_name` looks for."
const NAMED_CRS_TYPES = [Proj.PJ_TYPE_GEOGRAPHIC_2D_CRS, Proj.PJ_TYPE_PROJECTED_CRS, Proj.PJ_TYPE_COMPOUND_CRS]

"""
    crs_from_name(name)::Union{Nothing,String}

The EPSG code of the coordinate system with exactly this name, such as
`"EPSG:28355"` for `"GDA94 / MGA zone 55"`. Case is ignored. Only 2D
geographic, projected and compound systems count, so `"WGS 84"` is
`"EPSG:4326"`. `nothing` when PROJ knows no such name, or when more than one
current system has it. Never throws.
"""
function crs_from_name(name::AbstractString)::Union{Nothing,String}
    text = String(strip(name))
    (isempty(text) || occursin('\0', text)) && return nothing
    log = ProjLog()            # the lines are not used; PROJ needs a log to write to
    GC.@preserve log begin
        ctx = quiet_context(log)
        try
            list = Proj.proj_create_from_name("EPSG", text, NAMED_CRS_TYPES, length(NAMED_CRS_TYPES), 0, 0, C_NULL, ctx)
            list == C_NULL && return nothing
            codes = String[]
            try
                for k in 1:Proj.proj_list_get_count(list)
                    obj = Proj.proj_list_get(list, k - 1, ctx)
                    obj == C_NULL && continue
                    try
                        Proj.proj_is_deprecated(obj) == 0 || continue
                        id = Proj.proj_get_id_code(obj, 0)
                        id isa String && push!(codes, "EPSG:$id")
                    finally
                        Proj.proj_destroy(obj)
                    end
                end
            finally
                Proj.proj_list_destroy(list)
            end
            return length(codes) == 1 ? only(codes) : nothing
        finally
            Proj.proj_context_destroy(ctx)
        end
    end
end

"""
    crs_wkt(code)::String

The coordinate system `code` as WKT 1 in GDAL style, for file formats that store
WKT. `""` for blank text or a code that `valid_crs` refuses.
"""
function crs_wkt(code::AbstractString)::String
    wkt = with_crs_context((pj, ctx) -> Proj.proj_as_wkt(pj, Proj.PJ_WKT1_GDAL, C_NULL, ctx), code)
    return wkt isa AbstractString ? String(wkt) : ""
end

# ---- UTM zones -------------------------------------------------------------

"""
Counts for `guess_utm`, gathered a block at a time: points per UTM zone, and
what decides the sign of the median latitude.
"""
mutable struct UtmTally
    zones::Vector{Int}
    "Points with latitude below 0, and at or above 0."
    south::Int
    north::Int
    "Largest latitude below 0, and smallest at or above 0."
    top_south::Float64
    low_north::Float64
end

UtmTally() = UtmTally(zeros(Int, 60), 0, 0, -Inf, Inf)

"""
    utm_zone(lon, lat)::Int

The UTM zone of a point: `floor(Int, lon / 6 + 31)`, from 1 to 60, with the
official exceptions. Southwest Norway (56 to 64 N, 3 to 12 E) is zone 32.
Svalbard (72 to 84 N) uses only zones 31 (0 to 9 E), 33 (9 to 21 E),
35 (21 to 33 E) and 37 (33 to 42 E).
"""
function utm_zone(lon::Float64, lat::Float64)::Int
    56 <= lat < 64 && 3 <= lon < 12 && return 32
    if 72 <= lat < 84 && 0 <= lon < 42
        lon < 9 && return 31
        lon < 21 && return 33
        lon < 33 && return 35
        return 37
    end
    return clamp(floor(Int, lon / 6 + 31), 1, 60)
end

"Add points to the tally. Missing values and impossible positions are skipped."
function tally!(t::UtmTally, lon::AbstractVector, lat::AbstractVector)
    length(lon) == length(lat) ||
        throw(ArgumentError("there are $(length(lon)) longitudes but $(length(lat)) latitudes"))
    for k in eachindex(lon, lat)
        x, y = as_float(lon[k]), as_float(lat[k])
        (isfinite(x) && isfinite(y) && -180 <= x <= 180 && -90 <= y <= 90) || continue
        t.zones[utm_zone(x, y)] += 1
        if y < 0
            t.south += 1
            t.top_south = max(t.top_south, y)
        else
            t.north += 1
            t.low_north = min(t.low_north, y)
        end
    end
    return t
end

"""
True when the median latitude is below 0. With as many points on each side,
the median is the mean of the two middle values.
"""
function south_median(t::UtmTally)::Bool
    t.south == t.north && return t.top_south + t.low_north < 0
    return t.south > t.north
end

"The zones of the tally with their share of the points, largest first."
function utm_result(t::UtmTally)::Vector{Tuple{String,Float64}}
    n = t.south + t.north
    n == 0 && return Tuple{String,Float64}[]
    base = south_median(t) ? 32700 : 32600
    out = Tuple{String,Float64}[("EPSG:$(base + z)", t.zones[z] / n) for z in 1:60 if t.zones[z] > 0]
    return sort!(out; by = last, rev = true)
end

"""
    guess_utm(lon, lat)::Vector{Tuple{String,Float64}}

The UTM zones of the points, as EPSG codes with the share of the points in each,
largest share first. The zone of each point is `floor(Int, lon / 6 + 31)`,
with the official exceptions for southwest Norway and Svalbard (see `utm_zone`). All zones are
southern (`EPSG:327zz`) when the median latitude is below 0, else northern
(`EPSG:326zz`). Missing values and impossible positions are skipped.
Empty when no point is left.
"""
guess_utm(lon::AbstractVector, lat::AbstractVector)::Vector{Tuple{String,Float64}} =
    utm_result(tally!(UtmTally(), lon, lat))

# ---- reprojection ----------------------------------------------------------

"A value as `Float64`; the missing value of any number type becomes `NaN`."
as_float(x::Real)::Float64 = ismissingvalue(x) ? NaN : Float64(x)
as_float(_)::Float64 = NaN

"""
A transformation from one coordinate system to another, with its own PROJ
context. Make it once and use it for many points; `close` frees it.
Use it on one thread at a time. `proj_messages` gives what PROJ said, such as
that it used a ballpark transformation.
"""
mutable struct Reprojector
    ctx::Ptr{Proj.PJ_CONTEXT}
    trans::Proj.Transformation
    log::ProjLog
end

"Points between two checks of the operation PROJ used (see `note_ballpark!`)."
const OPERATION_CHECK_POINTS = 4096

"""
    Reprojector(from, to)

Throws `ArgumentError` with a plain message when PROJ cannot read a code or
cannot find a way between the two systems.
"""
function Reprojector(from::AbstractString, to::AbstractString)
    for code in (from, to)
        valid_crs(code) || throw(ArgumentError("Coordinate system \"$code\" is not known."))
    end
    log = ProjLog()
    ctx = quiet_context(log)
    trans = try
        Proj.Transformation(String(from), String(to); always_xy = true, ctx)
    catch e
        Proj.proj_context_destroy(ctx)
        e isa InterruptException && rethrow()
        throw(ArgumentError("There is no way to transform from $from to $to."))
    end
    r = Reprojector(ctx, trans, log)
    finalizer(close, r)
    return r
end

"Free the PROJ objects. Safe to call twice."
function Base.close(r::Reprojector)
    r.trans.pj == C_NULL || (r.trans.pj = Proj.proj_destroy(r.trans.pj))
    r.ctx == C_NULL || (Proj.proj_context_destroy(r.ctx); r.ctx = C_NULL)
    return nothing
end

"""
    proj_messages(r)::Vector{String}

What PROJ said while `r` was made and used, each line once: the lines PROJ
logged, and a line for each ballpark transformation it used.
"""
proj_messages(r::Reprojector)::Vector{String} = log_lines(r.log)

"""
Add a line to the log of `r` when the operation PROJ used for the last point is
a ballpark transformation. PROJ picks the operation per point, by area, so
`reproject!` checks every `OPERATION_CHECK_POINTS` points and at the end.
"""
function note_ballpark!(r::Reprojector)
    op = Proj.proj_trans_get_last_used_operation(r.trans.pj)
    op == C_NULL && return nothing
    try
        Proj.proj_coordoperation_has_ballpark_transformation(op, r.ctx) == 1 || return nothing
        name = Proj.proj_get_name(op)
        name isa AbstractString || return nothing
        name = replace(String(name), " (with axis order normalized for visualization)" => "")
        add_line!(r.log, "PROJ used a ballpark transformation: \"$name\". It leaves out the shift between " *
                         "the two datums, so the positions can be off by many metres.")
    finally
        Proj.proj_destroy(op)
    end
    return nothing
end

"""
    reproject!(r, x, y, ox, oy)::Int

Transform the points `x, y` into `ox, oy`. A missing value in gives `NaN` out.
A point PROJ cannot transform gives `NaN` too. Returns how many points PROJ
could not transform. Never throws for bad points.
A ballpark transformation adds a line to `proj_messages(r)`.
"""
function reproject!(r::Reprojector, x::AbstractVector, y::AbstractVector,
                    ox::AbstractVector{Float64}, oy::AbstractVector{Float64})::Int
    length(x) == length(y) == length(ox) == length(oy) ||
        throw(ArgumentError("there are $(length(x)) x values but $(length(y)) y values"))
    r.ctx == C_NULL && throw(ArgumentError("the reprojector is closed"))
    t = r.trans
    failed = 0
    done = 0                       # points PROJ transformed since the last check
    @inbounds for k in eachindex(x, y, ox, oy)
        px, py = as_float(x[k]), as_float(y[k])
        if !(isfinite(px) && isfinite(py))
            ox[k], oy[k] = NaN, NaN
            continue
        end
        qx, qy = t(px, py)
        if isfinite(qx) && isfinite(qy)
            ox[k], oy[k] = qx, qy
            done += 1
            done == OPERATION_CHECK_POINTS && (note_ballpark!(r); done = 0)
        else
            ox[k], oy[k] = NaN, NaN
            failed += 1
            Proj.proj_errno_reset(t.pj)
        end
    end
    done > 0 && note_ballpark!(r)
    return failed
end

"""
    reproject_xy(x, y, from, to)::Tuple{Vector{Float64},Vector{Float64}}

Transform points from coordinate system `from` to `to`, such as from
`"EPSG:4326"` (longitude, latitude) to `"EPSG:32755"`. Coordinates are in
x, y order (longitude first). A missing value in gives `NaN` out. A point PROJ
cannot transform also gives `NaN`, and a warning says how many there were.
Throws `ArgumentError` for an unknown coordinate system.
"""
function reproject_xy(x::AbstractVector, y::AbstractVector, from::AbstractString,
                      to::AbstractString)::Tuple{Vector{Float64},Vector{Float64}}
    length(x) == length(y) || throw(ArgumentError("there are $(length(x)) x values but $(length(y)) y values"))
    ox = Vector{Float64}(undef, length(x))
    oy = Vector{Float64}(undef, length(y))
    r = Reprojector(from, to)
    failed, messages = try
        reproject!(r, x, y, ox, oy), proj_messages(r)
    finally
        close(r)
    end
    foreach(m -> @warn(m), messages)
    failed > 0 && @warn failed_text(failed, from, to)
    return ox, oy
end

"The sentence for points that PROJ could not transform."
failed_text(n::Integer, from::AbstractString, to::AbstractString)::String =
    n == 1 ? "1 point could not be transformed from $from to $to. It is missing now." :
    "$n points could not be transformed from $from to $to. They are missing now."
