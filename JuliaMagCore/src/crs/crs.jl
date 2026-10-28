# Coordinate systems through PROJ (spec 5.3, 6.6).
#
# A coordinate system is a code such as "EPSG:7855", or any other text PROJ
# reads as a coordinate system. Blank means unknown.
#
# Each call makes its own PROJ context, so calls on different threads do not
# share PROJ state. The context has a quiet log function: PROJ errors do not
# throw out of C code (Proj.jl's default log function throws). We read errors
# from return values instead: a NULL object, or a point that comes back as
# infinity.

using Proj

# PROJ calls this for each log message of our contexts. It drops them.
quiet_proj_log(::Ptr{Cvoid}, ::Cint, ::Cstring)::Cvoid = nothing

"A new PROJ context with a quiet log function. Free it with `Proj.proj_context_destroy`."
function quiet_context()::Ptr{Proj.PJ_CONTEXT}
    ctx = Proj.proj_context_create()
    ctx == C_NULL && throw(ArgumentError("PROJ could not make a context"))
    Proj.proj_log_func(C_NULL, @cfunction(quiet_proj_log, Cvoid, (Ptr{Cvoid}, Cint, Cstring)), ctx)
    Proj.proj_context_set_search_paths(1, [Proj.PROJ_DATA[]], ctx)
    return ctx
end

"""
    with_crs(f, code)

Call `f(pj)` with the PROJ object of coordinate system `code` and return its
result. Returns `nothing` when PROJ cannot read `code` as a coordinate system.
Never throws for bad codes. An error in `f` is thrown as it is.
"""
function with_crs(f::F, code::AbstractString) where {F}
    (isempty(code) || occursin('\0', code)) && return nothing
    ctx = quiet_context()
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
        return f(pj)
    finally
        pj == C_NULL || Proj.proj_destroy(pj)
        Proj.proj_context_destroy(ctx)
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
Use it on one thread at a time.
"""
mutable struct Reprojector
    ctx::Ptr{Proj.PJ_CONTEXT}
    trans::Proj.Transformation
end

"""
    Reprojector(from, to)

Throws `ArgumentError` with a plain message when PROJ cannot read a code or
cannot find a way between the two systems.
"""
function Reprojector(from::AbstractString, to::AbstractString)
    for code in (from, to)
        valid_crs(code) || throw(ArgumentError("Coordinate system \"$code\" is not known."))
    end
    ctx = quiet_context()
    trans = try
        Proj.Transformation(String(from), String(to); always_xy = true, ctx)
    catch e
        Proj.proj_context_destroy(ctx)
        e isa InterruptException && rethrow()
        throw(ArgumentError("There is no way to transform from $from to $to."))
    end
    r = Reprojector(ctx, trans)
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
    reproject!(r, x, y, ox, oy)::Int

Transform the points `x, y` into `ox, oy`. A missing value in gives `NaN` out.
A point PROJ cannot transform gives `NaN` too. Returns how many points PROJ
could not transform. Never throws for bad points.
"""
function reproject!(r::Reprojector, x::AbstractVector, y::AbstractVector,
                    ox::AbstractVector{Float64}, oy::AbstractVector{Float64})::Int
    length(x) == length(y) == length(ox) == length(oy) ||
        throw(ArgumentError("there are $(length(x)) x values but $(length(y)) y values"))
    r.ctx == C_NULL && throw(ArgumentError("the reprojector is closed"))
    t = r.trans
    failed = 0
    @inbounds for k in eachindex(x, y, ox, oy)
        px, py = as_float(x[k]), as_float(y[k])
        if !(isfinite(px) && isfinite(py))
            ox[k], oy[k] = NaN, NaN
            continue
        end
        qx, qy = t(px, py)
        if isfinite(qx) && isfinite(qy)
            ox[k], oy[k] = qx, qy
        else
            ox[k], oy[k] = NaN, NaN
            failed += 1
            Proj.proj_errno_reset(t.pj)
        end
    end
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
    failed = try
        reproject!(r, x, y, ox, oy)
    finally
        close(r)
    end
    failed > 0 && @warn failed_text(failed, from, to)
    return ox, oy
end

"The sentence for points that PROJ could not transform."
failed_text(n::Integer, from::AbstractString, to::AbstractString)::String =
    n == 1 ? "1 point could not be transformed from $from to $to. It is missing now." :
    "$n points could not be transformed from $from to $to. They are missing now."
