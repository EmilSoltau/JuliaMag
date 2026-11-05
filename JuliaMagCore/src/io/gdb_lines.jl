# How the lines and channels of a Geosoft database (`.gdb`) map onto a JuliaMag
# line database.
#
# The mapping is in `docs/research/geosoft-gdb-format.md`, section 12, and in
# rulings 5, 6 and 8 of the gdb import plan. This file only plans: it turns the
# records and the metadata into line ids, channel settings and position pairs,
# and logs a warning for each skipped or changed item. The importer (Task 9)
# acts on the plans.

import Dates

"""
    gdb_line_type(code)

The JuliaMag line type of a Geosoft line type code, by letter: 0 `L`, 1 `B`,
2 `T`, 3 `S`, 4 `R`, 5 `P`, 6 `D`. Another code gives `nothing`. The integer
orders differ (JuliaMag has `TIE` before `BASE`), so the code is never used as
an enum value.
"""
function gdb_line_type(code::Integer)::Union{Nothing,LineType}
    0 <= code <= 6 || return nothing
    return line_type(('L', 'B', 'T', 'S', 'R', 'P', 'D')[code + 1])
end

"""
    gdb_date(x)

The line date `yyyy-mm-dd` of a Geosoft decimal year `x`, which Oasis stores as
`year + (day_of_year - 1) / days_in_year`. Gives `""` for 0, a value that is
not finite, a dummy (`<= -1e31`) or a year outside 1 to 9999.
"""
function gdb_date(x::Float64)::String
    (x == 0 || !isfinite(x) || x <= GDB_FLOAT_DUMMY_LIMIT) && return ""
    1 <= x < 10000 || return ""
    year = floor(Int, x)
    days = Dates.daysinyear(year)
    doy = clamp(round(Int, (x - year) * days) + 1, 1, days)
    return string(Dates.Date(year) + Dates.Day(doy - 1))
end

"""
A line to import. `name` is the name in the file, for warnings; `id` may
differ from it when the name is not a number.
"""
struct GdbLinePlan
    slot::Int
    id::LineId
    flight::Int
    date::String
    name::String
end

"""
    plan_gdb_lines(records, db, log)

The lines to import from the line `records`, in slot order. Group lines and
lines of an unknown type are skipped with a warning. A line whose number field
holds the int32 dummy (its name is not a number, such as `L28_29`) gets the
next free number of its type: one above the highest number of that type in
`db.lines` and in the numeric lines of the file, counting up for each such
line. A taken id gets the next version when the line starts (`start_line!`).
"""
function plan_gdb_lines(records::Vector{GdbLineRecord}, db::LineDatabase, log::WarningLog)::Vector{GdbLinePlan}
    top = Dict{LineType,Int}()
    for l in db.lines
        top[l.id.type] = max(get(top, l.id.type, 0), l.id.number)
    end
    for r in records
        t = gdb_line_type(r.type)
        (r.category == 100 && t !== nothing && !gdb_is_dummy(Int32(r.number))) || continue
        top[t] = max(get(top, t, 0), r.number)
    end
    plans = GdbLinePlan[]
    for r in records
        if r.category == 200
            warn!(log, 0, "group line $(r.name) was skipped; JuliaMag has no group lines")
            continue
        end
        t = gdb_line_type(r.type)
        if t === nothing
            warn!(log, 0, "line $(r.name) has the line type $(r.type), which JuliaMag does not know; it was skipped")
            continue
        end
        id = LineId(t, r.number, r.version)
        if gdb_is_dummy(Int32(r.number))
            top[t] = get(top, t, 0) + 1
            id = LineId(t, top[t], r.version)
            warn!(log, 0, "line $(r.name) has a name that is not a number; it was imported as $(line_name(id))")
        end
        push!(plans, GdbLinePlan(r.slot, id, r.flight, gdb_date(r.date), r.name))
    end
    return plans
end

"""
A channel to import. `name` is the JuliaMag name (safe and unique), `label`
the registry `LABEL` or the name in the file, `gtype` the value type, and
`format`, `width` and `decimals` the display settings JuliaMag accepts.
"""
struct GdbChannelPlan
    slot::Int
    name::String
    label::String
    units::String
    gtype::GdbType
    arraylen::Int
    format::Symbol
    width::Int
    decimals::Int
    role::ChannelRole
end

"The JuliaMag display format of the Geosoft formats 0 to 3; others are shown as `:normal`."
const GDB_FORMATS = (:normal, :exponential, :time, :date)

"A position pair being planned: indexes into the channel plans and the IPJ, if any."
struct GdbPairPlan
    x::Int
    y::Int
    ipj::Union{Nothing,GdbIpj}
    geographic::Bool
    assumed::Bool
end

"""
    plan_gdb_channels(records, meta, crs, log) -> (plans, pairs, current)

The channels to import from the live channel `records`, in slot order, their
position pairs and the index of the current pair (0 when there is none).

Names go through `channel_name`. The label is the registry `LABEL` when it holds
text, else the name in the file; it is never read as a unit. Display settings
JuliaMag does not accept become its defaults, with one warning for the file. A
text array channel is skipped with a warning.

The pairs, in order: the current pair (`DB_CHAN_X`, `DB_CHAN_Y` of the database
registry, else the X and Y channels by name); each IPJ pair of live channels
that names two channels no earlier pair has; the LON and LAT channels by name
with `EPSG:4326`, when no earlier pair uses them. The first pair is current. A
pair is geographic when its IPJ method is 1 or its units are `dega`. The first
projected pair gets roles X and Y, the first geographic one LON and LAT, and
`DB_CHAN_Z` gets Z. Only numeric channels with one value per row can be
positions.

A pair takes the coordinate system of its IPJ (`gdb_crs`). When that is empty
and the pair is current, it takes `crs` when that is set. A pair left with no
coordinate system gives a warning. Pairs name the JuliaMag channel names.
"""
function plan_gdb_channels(records::Vector{GdbChannelRecord}, meta::GdbMeta, crs::String,
                           log::WarningLog)::Tuple{Vector{GdbChannelPlan},Vector{PositionPair},Int}
    kept = GdbChannelRecord[]
    names = String[]
    taken = Set{String}()
    changed = String[]
    for r in records
        t = gdb_type(r.type)
        if t.T === String && r.arraylen > 1
            warn!(log, 0, "channel $(r.name) is an array of text values; JuliaMag cannot store it, so it was skipped")
            continue
        end
        name = channel_name(r.name, r.slot + 1, taken)
        push!(taken, lowercase(name))
        push!(kept, r)
        push!(names, name)
        (0 <= r.format < length(GDB_FORMATS) && r.width >= 1 && r.decimals >= -1) || push!(changed, name)
    end
    if length(changed) == 1
        warn!(log, 0, "channel $(only(changed)): its Oasis display settings have no JuliaMag equal; " *
                      "it is shown as a normal number")
    elseif length(changed) > 1
        warn!(log, 0, "channels $(join(changed, ", ")): their Oasis display settings have no JuliaMag equal; " *
                      "they are shown as normal numbers")
    end

    pairs = gdb_pair_plans(kept, names, meta)
    roles = fill(ROLE_NONE, length(kept))
    projected = findfirst(p -> !p.geographic, pairs)
    projected === nothing || (roles[pairs[projected].x] = ROLE_X; roles[pairs[projected].y] = ROLE_Y)
    geographic = findfirst(p -> p.geographic, pairs)
    geographic === nothing || (roles[pairs[geographic].x] = ROLE_LON; roles[pairs[geographic].y] = ROLE_LAT)
    z = gdb_find_channel(kept, get(meta.dbreg, "DB_CHAN_Z", ""))
    z > 0 && roles[z] == ROLE_NONE && (roles[z] = ROLE_Z)

    out = PositionPair[]
    for (i, p) in enumerate(pairs)
        x, y = names[p.x], names[p.y]
        if p.assumed
            c, w = "EPSG:4326", nothing
        elseif p.ipj !== nothing
            c, w = gdb_crs(p.ipj, x, y)
        else
            c, w = "", "the file stores no coordinate system for $x, $y. Set it in the database."
        end
        (isempty(c) && i == 1 && !isempty(crs)) && ((c, w) = (crs, nothing))
        w === nothing || warn!(log, 0, w)
        push!(out, PositionPair(x, y, c))
    end

    plans = GdbChannelPlan[]
    for (k, r) in enumerate(kept)
        reg = get(meta.channel_reg, r.slot, Dict{String,String}())
        label = get(reg, "LABEL", "")
        ok = 0 <= r.format < length(GDB_FORMATS)
        push!(plans, GdbChannelPlan(r.slot, names[k], isempty(label) ? r.name : label, get(reg, "UNITS", ""),
                                    gdb_type(r.type), r.arraylen, ok ? GDB_FORMATS[r.format + 1] : :normal,
                                    r.width >= 1 ? r.width : 10, r.decimals >= -1 ? r.decimals : -1, roles[k]))
    end
    return plans, out, isempty(out) ? 0 : 1
end

"""
    gdb_find_channel(kept, name)

The index in `kept` of the channel named `name` in the file, or 0. An exact
match wins; else the first match that ignores case, since Oasis names ignore
case. Only numeric channels with one value per row are found, since only they
can be positions.
"""
function gdb_find_channel(kept::Vector{GdbChannelRecord}, name::AbstractString)::Int
    isempty(name) && return 0
    usable(r) = r.arraylen == 1 && r.type >= 0
    k = findfirst(r -> usable(r) && r.name == name, kept)
    k === nothing && (k = findfirst(r -> usable(r) && lowercase(r.name) == lowercase(name), kept))
    return something(k, 0)
end

"The pairs of `plan_gdb_channels`, in order, before roles and coordinate systems."
function gdb_pair_plans(kept::Vector{GdbChannelRecord}, names::Vector{String}, meta::GdbMeta)::Vector{GdbPairPlan}
    pairs = GdbPairPlan[]
    ipjs = Tuple{Int,Int,GdbIpj}[]
    for (x, y, ipj) in meta.ipj
        i, j = gdb_find_channel(kept, x), gdb_find_channel(kept, y)
        (i > 0 && j > 0 && i != j) && push!(ipjs, (i, j, ipj))
    end
    geo(ipj) = ipj.method == 1 || ipj.units == "dega"
    function add!(i, j)
        k = findfirst(e -> e[1] == i && e[2] == j, ipjs)
        ipj = k === nothing ? nothing : ipjs[k][3]
        push!(pairs, GdbPairPlan(i, j, ipj, ipj !== nothing && geo(ipj), false))
    end
    usable = [r.arraylen == 1 && r.type >= 0 for r in kept]
    by_role(roles, role) = something(findfirst(k -> roles[k] == role && usable[k], eachindex(roles)), 0)

    # 1. The current pair: the registry, else the X and Y channels by name.
    i = gdb_find_channel(kept, get(meta.dbreg, "DB_CHAN_X", ""))
    j = gdb_find_channel(kept, get(meta.dbreg, "DB_CHAN_Y", ""))
    if !(i > 0 && j > 0 && i != j)
        roles = position_roles([usable[k] ? names[k] : "" for k in eachindex(names)])
        i, j = by_role(roles, ROLE_X), by_role(roles, ROLE_Y)
    end
    (i > 0 && j > 0) && add!(i, j)
    # 2. Each IPJ pair with two channels that no earlier pair has.
    for (i, j, _) in ipjs
        any(p -> Set((p.x, p.y)) == Set((i, j)), pairs) || add!(i, j)
    end
    # 3. LON and LAT by name, as XYZ does, when no earlier pair uses them.
    roles = position_roles([usable[k] ? names[k] : "" for k in eachindex(names)])
    i, j = by_role(roles, ROLE_LON), by_role(roles, ROLE_LAT)
    used = Set(c for p in pairs for c in (p.x, p.y))
    (i > 0 && j > 0 && !(i in used) && !(j in used)) && push!(pairs, GdbPairPlan(i, j, nothing, true, true))
    return pairs
end
