# Coordinates tools (spec 9.1, "Coordinates" tab).
#
# - `coordinates.set_crs`: set the coordinate system of a position pair. Metadata only.
# - `coordinates.reproject`: write a new pair of channels in another system (a job).
# - `coordinates.set_current`: make a pair the current one.
# - `coordinates.guess_utm`: say which UTM zone most points are in.
#
# The quick tools change `database.json` under `s.lock` and push an undo step
# that puts the old values back. The reproject job marks the database busy while
# it writes (readers such as exports wait too), and notes an undo that rolls the
# database back to its committed state before the job (see `note_append_undo!`).
# Guess UTM zone only reads: it shares the database with exports and appends.

const COORDINATES_TAB = "Coordinates"

# ---- shared parts ----------------------------------------------------------

"""
The database of tool input `id`, opened. Call it under `s.lock`.
Throws `ToolError` when the item is missing, not a database, busy or broken.
With `allow_readers = true`, an item that readers (such as exports) or an
appending import use is not busy: use it for tools that only read the committed
rows, and mark the item with `mark_reading!` under the same lock.
"""
function tool_database(s::Session, id::AbstractString; allow_readers::Bool = false)::LineDatabase
    k = findfirst(i -> i.id == id, s.project.items)
    k === nothing && throw(ToolError("There is no item $id in the project."))
    s.project.items[k].kind == ITEM_DATABASE || throw(ToolError("Item $id is not a database."))
    m = get(s.busy, id, nothing)
    (m === nothing || (allow_readers && readers_allowed(m))) ||
        throw(ToolError("Database $id is busy: $(busy_reason(m))."))
    try
        return database(s.project, id)
    catch e
        e isa Union{ProjectError,DatabaseError} || rethrow()
        throw(ToolError("Database $id cannot be opened: $(e.msg)"))
    end
end

pair_text(p::PositionPair) = "$(p.x),$(p.y)"

"""
The index of the position pair named by a `PairSetting` value, such as `"X,Y"`.
Blank means the current pair. Throws `ToolError` when there is no such pair.
"""
function find_pair(db::LineDatabase, id::AbstractString, text::AbstractString)::Int
    if isempty(strip(text))
        db.current_pair == 0 && throw(ToolError("Database $id has no current position pair."))
        return db.current_pair
    end
    parts = strip.(split(text, ','))
    (length(parts) == 2 && all(!isempty, parts)) ||
        throw(ToolError("Position pair must be two channel names with a comma, such as \"X,Y\"."))
    k = findfirst(p -> p.x == parts[1] && p.y == parts[2], db.pairs)
    k === nothing && throw(ToolError("Database $id has no position pair $(parts[1]),$(parts[2])."))
    return k
end

"A code with its name for messages, such as `EPSG:7855 (GDA2020 / MGA zone 55)`."
function crs_text(code::AbstractString)::String
    name = crs_name(code)
    return isempty(name) ? String(code) : "$code ($name)"
end

"Throw `ToolError` unless PROJ knows the code."
check_crs(code::AbstractString) =
    valid_crs(code) || throw(ToolError("Coordinate system \"$code\" is not known."))

"""
An undo step that sets the pair `x,y` of database `id` back to `old` with
`apply(pair_index, db, value)`, and forward to `new` again.
"""
function meta_undo_step(s::Session, id::String, label::String, apply::Function, x::String, y::String, old, new)
    put(v) = () -> begin
        db = database(s.project, id)
        k = findfirst(p -> p.x == x && p.y == y, db.pairs)
        k === nothing && throw(DatabaseError("database $id has no position pair $x,$y any more"))
        apply(k, db, v)
        save_meta(db)
        nothing
    end
    return UndoStep(label, put(old), put(new), () -> nothing, [id])
end

# ---- set coordinate system -------------------------------------------------

function run_set_crs(s::Session, ins::Dict{String,String}, st::Dict{String,Any}, _, report::IO)
    id = ins["database"]
    code = String(strip(st["crs"]))
    isempty(code) || check_crs(code)
    lock(s.lock) do
        db = tool_database(s, id)
        k = find_pair(db, id, st["pair"])
        p = db.pairs[k]
        old = p.crs
        apply = (i, d, v) -> (d.pairs[i].crs = v)
        step = meta_undo_step(s, id, "set coordinate system of $(pair_text(p))", apply, p.x, p.y, old, code)
        step.redo()
        push_undo!(s, step)
        print(report, "Position pair ", pair_text(p), isempty(code) ? " has no coordinate system now." :
                                                      " is now in $(crs_text(code)).")
    end
    return nothing
end

# ---- set current pair ------------------------------------------------------

function run_set_current(s::Session, ins::Dict{String,String}, st::Dict{String,Any}, _, report::IO)
    id = ins["database"]
    lock(s.lock) do
        db = tool_database(s, id)
        k = find_pair(db, id, st["pair"])
        p = db.pairs[k]
        if k == db.current_pair
            print(report, "Position pair ", pair_text(p), " is already the current pair.")
            return nothing
        end
        old = db.current_pair
        # Undo goes back to the old current pair by its names, so look them up now.
        oldp = old == 0 ? nothing : db.pairs[old]
        put(target) = () -> begin
            d = database(s.project, id)
            if target === nothing
                d.current_pair = 0
            else
                i = findfirst(q -> q.x == target.x && q.y == target.y, d.pairs)
                i === nothing && throw(DatabaseError("database $id has no position pair $(pair_text(target)) any more"))
                d.current_pair = i
            end
            save_meta(d)
            nothing
        end
        step = UndoStep("make $(pair_text(p)) the current pair", put(oldp), put(PositionPair(p.x, p.y, "")),
                        () -> nothing, [String(id)])
        step.redo()
        push_undo!(s, step)
        print(report, "Position pair ", pair_text(p), " is now the current pair.")
    end
    return nothing
end

# ---- guess UTM zone --------------------------------------------------------

"""
True when the pair holds longitude and latitude. A set coordinate system
decides: it must be geographic. When it is blank, the channel roles decide.
"""
function is_lonlat_pair(db::LineDatabase, p::PositionPair)::Bool
    isempty(p.crs) || return p.crs == "EPSG:4326" || is_geographic(p.crs)
    roles(name) = (k = channel_position(db, name); k == 0 ? ROLE_NONE : db.channels[k].role)
    return roles(p.x) == ROLE_LON && roles(p.y) == ROLE_LAT
end

"Values of a numeric channel on one line as `Float64`, with missing values as `NaN`."
function float_values(db::LineDatabase, l::LineInfo, name::String)::Vector{Float64}
    return Float64[as_float(v) for v in read_channel(db, l.id, name)]
end

"Throw `ToolError` unless the channel is there, is a number and is not an array."
function check_position_channel(db::LineDatabase, id::AbstractString, name::String)
    k = channel_position(db, name)
    k == 0 && throw(ToolError("Database $id has no channel $name."))
    c = db.channels[k]
    (c.eltype <: Real && c.arraylen == 1) || throw(ToolError("Channel $name is not a channel of single numbers."))
    return nothing
end

function run_guess_utm(s::Session, ins::Dict{String,String}, st::Dict{String,Any}, _, report::IO)
    id = ins["database"]
    # Pick the pair and mark the database as read under the lock; read without it.
    db, p = lock(s.lock) do
        db = tool_database(s, id; allow_readers = true)
        p = if isempty(strip(st["pair"]))
            k = db.current_pair
            if k == 0 || !is_lonlat_pair(db, db.pairs[k])
                k = something(findfirst(q -> is_lonlat_pair(db, q), db.pairs), 0)
                k == 0 && throw(ToolError("Database $id has no position pair with longitude and latitude. " *
                                          "Pick the pair with longitude and latitude."))
            end
            db.pairs[k]
        else
            q = db.pairs[find_pair(db, id, st["pair"])]
            is_lonlat_pair(db, q) || throw(ToolError("Position pair $(pair_text(q)) is not longitude and " *
                                                     "latitude. Pick the pair with longitude and latitude."))
            q
        end
        check_position_channel(db, id, p.x)
        check_position_channel(db, id, p.y)
        mark_reading!(s, id)
        return db, p
    end
    t = UtmTally()
    try
        for l in db.lines
            l.offset + l.nrows <= db.rows_written || continue
            tally!(t, float_values(db, l, p.x), float_values(db, l, p.y))
        end
    finally
        unmark_reading!(s, id)
    end
    zones = utm_result(t)
    isempty(zones) && throw(ToolError("Position pair $(pair_text(p)) has no valid longitude and latitude."))
    code, share = zones[1]
    print(report, "Most points (", percent(share), " %) are in ", crs_text(code), ".")
    if length(zones) > 1
        print(report, "\nOther zones: ", join(("$c ($(percent(f)) %)" for (c, f) in zones[2:end]), ", "), ".")
    end
    return nothing
end

percent(f::Real)::String = @sprintf("%.1f", 100 * f)

# ---- reproject -------------------------------------------------------------

"The part of a code for channel names: `\"32755\"` for `\"EPSG:32755\"`."
function code_suffix(code::AbstractString)::String
    m = match(r"^\s*[A-Za-z_]+\s*:\s*([A-Za-z0-9_-]+)\s*$", code)
    return m === nothing ? "new" : String(something(m[1]))
end

"Free names `X_<suffix>` and `Y_<suffix>`, with `_2`, `_3`, ... added when taken (case is ignored)."
function free_xy_names(db::LineDatabase, suffix::String)::Tuple{String,String}
    taken = Set(lowercase(c.name) for c in db.channels)
    free(x, y) = !(lowercase(x) in taken) && !(lowercase(y) in taken)
    x, y = "X_$suffix", "Y_$suffix"
    k = 2
    while !free(x, y)
        x, y = "X_$(suffix)_$k", "Y_$(suffix)_$k"
        k += 1
    end
    return x, y
end

"The channel of a new coordinate: degrees for a geographic system, else metres."
function coordinate_channel(name::String, geographic::Bool, east::Bool)::ChannelInfo
    role = geographic ? (east ? ROLE_LON : ROLE_LAT) : (east ? ROLE_X : ROLE_Y)
    return ChannelInfo(name, name, Float64, geographic ? "deg" : "m", role, :normal,
                       geographic ? 14 : 12, geographic ? 8 : 2, false, 1)
end

function run_reproject(s::Session, ins::Dict{String,String}, st::Dict{String,Any}, progress::Progress, out::IO)
    id = ins["database"]
    target = String(strip(st["crs"]))
    isempty(target) && throw(ToolError("Set the coordinate system to reproject to."))
    check_crs(target)
    # Find the pair and mark the database busy under the lock; write without it.
    db, before, p = lock(s.lock) do
        db = tool_database(s, id)
        p = db.pairs[find_pair(db, id, st["pair"])]
        isempty(p.crs) && throw(ToolError("Position pair $(pair_text(p)) has no coordinate system. Set it first."))
        check_crs(p.crs)
        check_position_channel(db, id, p.x)
        check_position_channel(db, id, p.y)
        # Read the state before the mark, so a failed read leaves no mark behind.
        before = committed_state(db)
        mark_busy!(s, id; reason = "a reprojection is running")
        return db, before, p
    end
    local committed::String
    local xname::String
    local yname::String
    failed = 0
    try
        nchannels, rows = length(db.channels), db.rows_written
        r = Reprojector(p.crs, target)
        try
            xname, yname = free_xy_names(db, code_suffix(target))
            geographic = is_geographic(target)
            add_channel!(db, coordinate_channel(xname, geographic, true))
            add_channel!(db, coordinate_channel(yname, geographic, false))
            done = 0
            for l in db.lines
                is_cancelled(progress) && throw(JobCancelled())
                l.offset + l.nrows <= db.rows_written || continue
                ox = Vector{Float64}(undef, l.nrows)
                oy = Vector{Float64}(undef, l.nrows)
                failed += reproject!(r, float_values(db, l, p.x), float_values(db, l, p.y), ox, oy)
                write_channel!(db, l.id, xname, ox)
                write_channel!(db, l.id, yname, oy)
                done += l.nrows
                report(progress, rows == 0 ? 1.0 : done / rows)
            end
            push!(db.pairs, PositionPair(xname, yname, target))
            st["make_current"] === true && (db.current_pair = length(db.pairs))
            release_maps!(db)
            committed = lock(s.lock) do
                save_meta(db)                    # the commit point
                read(meta_path(db), String)
            end
        catch
            undo_append!(db, nchannels, rows)
            rethrow()
        finally
            close(r)
        end
    catch e
        e isa ArgumentError && throw(ToolError(e.msg))
        rethrow()
    finally
        unmark_busy!(s, id)
    end
    note_append_undo!(s, id, before, committed)
    println(out, "Reprojected ", pair_text(p), " from ", crs_text(p.crs), " to ", crs_text(target), ".")
    println(out, "New position pair: ", xname, ",", yname,
            st["make_current"] === true ? " (now the current pair)." : ".")
    failed > 0 && println(out, failed_text(failed, p.crs, target))
    return nothing
end

# ---- registration ----------------------------------------------------------

const DATABASE_INPUT = ["database" => ITEM_DATABASE]

register_tool!(ToolSpec("coordinates.set_crs", "Set coordinate system",
    "Set the coordinate system of a position pair. The data is not changed.", "crs",
    [Place(COORDINATES_TAB, "Coordinate system")], DATABASE_INPUT,
    SettingSpec[PairSetting("pair", "Position pair"; help = "Blank means the current pair."),
                CRSSetting("crs", "Coordinate system"; help = "Such as EPSG:7855. Blank means unknown.")],
    :quick, run_set_crs))

register_tool!(ToolSpec("coordinates.reproject", "Reproject",
    "Write the positions of a pair in another coordinate system, as a new pair of channels.", "reproject",
    [Place(COORDINATES_TAB, "Reproject")], DATABASE_INPUT,
    SettingSpec[PairSetting("pair", "Position pair"; help = "Blank means the current pair."),
                CRSSetting("crs", "Reproject to"; help = "Such as EPSG:32755."),
                BoolSetting("make_current", "Make the new pair current"; default = false)],
    :job, run_reproject))

register_tool!(ToolSpec("coordinates.set_current", "Set current pair",
    "Make a position pair the current one. Maps and tools use the current pair.", "pair",
    [Place(COORDINATES_TAB, "Position pairs"), Place("Database", "Channels")], DATABASE_INPUT,
    SettingSpec[PairSetting("pair", "Position pair")],
    :quick, run_set_current))

register_tool!(ToolSpec("coordinates.guess_utm", "Guess UTM zone",
    "Say which UTM zone most points are in, from longitude and latitude.", "globe",
    [Place(COORDINATES_TAB, "Coordinate system")], DATABASE_INPUT,
    SettingSpec[PairSetting("pair", "Position pair";
                            help = "Blank uses the current pair, or else a pair with longitude and latitude.")],
    :quick, run_guess_utm))
