# Parts shared by the line data importers (Geosoft XYZ, CSV and other text).
#
# - `WarningLog`: warnings with file line numbers, at most `MAX_WARNINGS` kept.
# - `ChunkProgress`: progress by bytes read, and a check for cancel once per chunk.
# - `FidTracker`: the fiducial start and step of a line from its fiducial values.
# - Lines: `parse_line_name`, `free_line_id`, `start_line!`.
# - Channels: safe names, position roles by name, position pairs, and the channel
#   for an imported column (`import_channel!`).
# - Staging and commit (`import_lines`):
#   - A new database is written to `databases/.importing-<id>/` and moved to its
#     final folder only when it is complete. Then the item is added to the project.
#     On any error the temp folder is removed and the error is thrown again.
#   - In append mode the target database is written in place. `database.json` is
#     saved only at the end, so it is the commit point. On error the channel files
#     are cut back and new channel files are removed, so the target is as it was.
#     The target is marked busy while the file is read. Inside a job, the append
#     notes an undo that puts the target back (see `roll_back!`).

"Most warnings kept in a result. Later ones are counted, not kept."
const MAX_WARNINGS = 1000

"Most fiducial steps kept per line to find the median step."
const MAX_FID_STEPS = 1 << 20

"The line that rows go to when the file does not name one."
const DEFAULT_LINE_ID = LineId(RANDOM, 0, 0)

const XAppender = ColumnAppender{NumericWriter{Float64}}

"True for a space or a tab."
@inline is_blank(b::UInt8) = b == 0x20 || b == 0x09

"True for an ASCII letter."
@inline is_ascii_letter(b::UInt8) = (0x41 <= b <= 0x5a) || (0x61 <= b <= 0x7a)

# ---- warnings --------------------------------------------------------------

"The warnings of one import. At most `MAX_WARNINGS` are kept; the rest are counted."
mutable struct WarningLog
    list::Vector{ImportWarning}
    dropped::Int
end

WarningLog() = WarningLog(ImportWarning[], 0)

"Add a warning. `file_line` is 0 for a warning that is not about one line of the file."
function warn!(log::WarningLog, file_line::Int, msg::String)
    if length(log.list) < MAX_WARNINGS
        push!(log.list, ImportWarning(file_line, msg))
    else
        log.dropped += 1
    end
    return nothing
end

"The warnings for the result, with a last one that counts those not kept."
function final_warnings(log::WarningLog)::Vector{ImportWarning}
    out = copy(log.list)
    log.dropped > 0 && push!(out, ImportWarning(0, "$(log.dropped) more warnings were not listed"))
    return out
end

"The warning text for a row with the wrong number of values."
row_length_message(expected::Int, found::Int) = "expected $expected values, found $found; row skipped"

"Warn about a value that is not a number. The caller warns once per column per line."
@noinline function warn_bad_value!(log::WarningLog, lineno::Int, column::String, l::LineInfo,
                                   s::String, a::Int, b::Int)
    warn!(log, lineno, "column $column on line $(line_name(l.id)) has a value that is not " *
                       "a number: \"$(field_text(s, a, min(b, a + 39)))\"; read as missing. " *
                       "Later bad values in this column on this line are not listed.")
    return nothing
end

# ---- progress --------------------------------------------------------------

"Reports progress by bytes read and checks for cancel, once per chunk of the file."
mutable struct ChunkProgress
    progress::Progress
    file_bytes::Int
    last_bytes::Int
end

ChunkProgress(progress::Progress, path::AbstractString) = ChunkProgress(progress, filesize(path), -1)

"Call for each line with the `bytes_read` of `eachfileline`. Throws `ImportCancelled` on cancel."
@inline function tick!(c::ChunkProgress, bytes_read::Int)
    bytes_read == c.last_bytes && return nothing
    c.last_bytes = bytes_read
    is_cancelled(c.progress) && throw(ImportCancelled())
    report(c.progress, c.file_bytes == 0 ? 1.0 : min(bytes_read / c.file_bytes, 1.0))
    return nothing
end

"The last check at the end of the file, so a cancel during the last chunk stops the import too."
check_cancel(c::ChunkProgress) = (is_cancelled(c.progress) && throw(ImportCancelled()); nothing)

# ---- fiducials -------------------------------------------------------------

"The fiducial values of the current line: the first one and the steps between them."
mutable struct FidTracker
    first::Float64
    first_row::Int
    prev::Float64
    prev_row::Int
    steps::Vector{Float64}
end

FidTracker() = FidTracker(NaN, 0, NaN, 0, Float64[])

"Forget the values of the line before. Call it when a new line starts."
function reset!(t::FidTracker)
    t.first, t.first_row = NaN, 0
    t.prev, t.prev_row = NaN, 0
    empty!(t.steps)
    return nothing
end

"Note the fiducial value `v` of row `row` (from 1) of the current line. Missing values are skipped."
function track_fiducial!(t::FidTracker, v::Float64, row::Int)
    isnan(v) && return nothing
    if t.first_row == 0
        t.first, t.first_row = v, row
    elseif length(t.steps) < MAX_FID_STEPS
        push!(t.steps, (v - t.prev) / (row - t.prev_row))
    end
    t.prev, t.prev_row = v, row
    return nothing
end

"""
Set the fiducial start and step of line `l` from the values noted.
The step is the median step. A line with no values keeps its start and step.
"""
function finish_fiducials!(t::FidTracker, l::LineInfo, log::WarningLog)
    t.first_row == 0 && return nothing
    step = 1.0
    n = length(t.steps)
    if n > 0
        v = t.steps
        # Median. `partialsort!` with one index selects in place; a range would allocate.
        m = isodd(n) ? partialsort!(v, (n + 1) ÷ 2) : (partialsort!(v, n ÷ 2) + partialsort!(v, n ÷ 2 + 1)) / 2
        if isfinite(m) && m > 0
            step = m
        else
            warn!(log, 0, "line $(line_name(l.id)): the fiducial step is $m, not above 0; step set to 1")
        end
    end
    l.fid_step = step
    l.fid_start = t.first - (t.first_row - 1) * step
    return nothing
end

# ---- lines -----------------------------------------------------------------

const LINE_KEYWORDS = Dict("line" => LINE, "tie" => TIE, "base" => BASE, "test" => TEST,
                           "trend" => TREND, "random" => RANDOM, "special" => SPECIAL)

"""
    parse_line_name(words) -> (id, flight) or nothing

Read a line name from the first one or two words, such as `["Line", "1001"]`,
`["Tie", "5.1"]`, `["L1001"]`, `["t", "7.2"]`, `["Line", "10:16"]` or `["1001"]`.
A plain number is a line of type `LINE`. `.2` is a version, `:16` a flight number
(`flight` is -1 when there is none). Returns `nothing` when the words are not a line name.
"""
function parse_line_name(words::Vector{String})::Union{Nothing,Tuple{LineId,Int}}
    isempty(words) && return nothing
    w = words[1]
    k = something(findfirst(c -> !('A' <= c <= 'Z' || 'a' <= c <= 'z'), w), lastindex(w) + 1)
    word = lowercase(w[1:prevind(w, k)])
    rest = w[k:end]
    numtext = isempty(rest) ? (length(words) >= 2 ? words[2] : "") : rest
    t = LINE
    if !isempty(word)
        tw = get(LINE_KEYWORDS, word, nothing)
        if tw === nothing
            (length(word) == 1 && uppercase(word[1]) in LINE_LETTERS) || return nothing
            tw = line_type(word[1])
        end
        t = tw
    end
    m = match(r"^(\d+)(?:\.(\d+))?(?::(\d+))?$", numtext)
    m === nothing && return nothing
    num, ver, fl = m[1], m[2], m[3]
    number = num === nothing ? nothing : tryparse(Int, num)
    version = ver === nothing ? 0 : tryparse(Int, ver)
    (number === nothing || version === nothing) && return nothing
    flight = fl === nothing ? nothing : tryparse(Int, fl)
    return (LineId(t, number, version), flight === nothing ? -1 : flight)
end

"The id itself when it is free, else the same type and number with the next free version."
function free_line_id(db::LineDatabase, id::LineId)::LineId
    line_position(db, id) == 0 && return id
    v = id.version
    for l in db.lines
        (l.id.type == id.type && l.id.number == id.number) && (v = max(v, l.id.version))
    end
    return LineId(id.type, id.number, v + 1)
end

"""
Add a new line for the rows that come next. A line id that is taken gets the next
free version. Ends the line before it (see `add_line!`).
"""
function start_line!(db::LineDatabase, id::LineId, flight::Int, date::String)::LineInfo
    l = LineInfo(free_line_id(db, id), flight, date, 0.0, 1.0, 0, 0, true)
    add_line!(db, l)
    return l
end

# ---- channels --------------------------------------------------------------

"Index of the channel whose name equals `name`, ignoring case, or 0."
channel_position_ci(db::LineDatabase, name::AbstractString) =
    something(findfirst(c -> lowercase(c.name) == lowercase(name), db.channels), 0)

"The position role a channel name suggests, such as `ROLE_X` for `EASTING`."
function name_role(name::AbstractString)::ChannelRole
    u = uppercase(name)
    u in ("X", "EASTING") && return ROLE_X
    u in ("Y", "NORTHING") && return ROLE_Y
    u in ("LON", "LONG", "LONGITUDE") && return ROLE_LON
    u in ("LAT", "LATITUDE") && return ROLE_LAT
    return ROLE_NONE
end

"""
The position role of each column by its name. Only the first column with a role gets it.
"""
function position_roles(names::Vector{String})::Vector{ChannelRole}
    seen = Set{ChannelRole}()
    out = ChannelRole[]
    for n in names
        role = name_role(n)
        (role == ROLE_NONE || role in seen) && (role = ROLE_NONE)
        role == ROLE_NONE || push!(seen, role)
        push!(out, role)
    end
    return out
end

"""
Add the pair of the `ROLE_X` and `ROLE_Y` columns with `crs`, and the pair of the
`ROLE_LON` and `ROLE_LAT` columns with `EPSG:4326`. Makes the first pair current.
"""
function add_position_pairs!(db::LineDatabase, names::Vector{String}, roles::Vector{ChannelRole}, crs::String)
    named(r) = (k = findfirst(==(r), roles); k === nothing ? "" : names[k])
    add_pair!(db, named(ROLE_X), named(ROLE_Y), crs)
    add_pair!(db, named(ROLE_LON), named(ROLE_LAT), "EPSG:4326")
    db.current_pair == 0 && !isempty(db.pairs) && (db.current_pair = 1)
    return nothing
end

"Add a position pair, unless a name is empty or the pair is there already."
function add_pair!(db::LineDatabase, x::String, y::String, crs::String)
    (isempty(x) || isempty(y)) && return nothing
    any(p -> p.x == x && p.y == y, db.pairs) && return nothing
    push!(db.pairs, PositionPair(x, y, crs))
    return nothing
end

"""
A channel name made from a name in the file that is safe as a file name
(see `check_channel_info`) and not in `taken` (lower case names).
"""
function channel_name(raw::AbstractString, k::Int, taken::Set{String})::String
    t = map(c -> (!isvalid(c) || c in BAD_NAME_CHARS || iscntrl(c)) ? '_' : c, String(raw))
    t = String(rstrip(t, (' ', '.')))
    isempty(t) && (t = "C$k")
    uppercase(t) in RESERVED_NAMES && (t *= "_")
    name = t
    n = 2
    while lowercase(name) in taken
        name = "$(t)_$n"
        n += 1
    end
    return name
end

"""
    import_channel!(db, name, label, T, units, role, arraylen, what) -> name

The channel an imported column goes to. In append mode a channel with the same name
(case is ignored) is used, and its name is returned; it must hold `T` values with
`arraylen` values per row, else a `DatabaseError` is thrown. Otherwise a new
protected channel is added. `what` names the importer in the message.
"""
function import_channel!(db::LineDatabase, name::String, label::String, ::Type{T}, units::String,
                         role::ChannelRole, arraylen::Int, what::String)::String where {T}
    old = channel_position_ci(db, name)
    if old > 0
        c = db.channels[old]
        (c.eltype === T && c.arraylen == arraylen) || throw(DatabaseError(
            "channel $(c.name) of database $(db.name) holds " * value_kind(c.eltype, c.arraylen) *
            "; $what import writes " * value_kind(T, arraylen)))
        return c.name
    end
    add_channel!(db, ChannelInfo(name, label, T, units, role, :normal, 10, -1, true, arraylen))
    return name
end

value_kind(T::DataType, arraylen::Int) = arraylen == 1 ? "$T values" : "arrays of $arraylen $T values"

release_maps!(db::LineDatabase) = foreach(c -> release_map!(db, c.name), db.channels)

# ---- names of files and folders --------------------------------------------

"Lower case letters, digits, `-` and `_` made from `name`. May be empty."
function safe_slug(name::AbstractString)::String
    io = IOBuffer()
    dash = false
    for c in lowercase(name)
        if isascii(c) && (isletter(c) || isdigit(c) || c == '_')
            write(io, c)
            dash = false
        elseif !dash && position(io) > 0
            write(io, '-')
            dash = true
        end
    end
    return String(rstrip(String(take!(io)), '-'))
end

"A folder name made from a database name: lower case letters, digits, `-` and `_`."
function folder_slug(name::AbstractString)::String
    t = safe_slug(name)
    return isempty(t) ? "database" : t
end

"`slug`, or `slug-2`, `slug-3`, ... : the first one not taken in `folder`."
function free_folder(folder::String, slug::String)::String
    ispath(joinpath(folder, slug)) || return slug
    n = 2
    while ispath(joinpath(folder, "$slug-$n"))
        n += 1
    end
    return "$slug-$n"
end

# ---- staging and commit ----------------------------------------------------

"Check the mode, the target and the file of an import. Throws `ArgumentError`."
function check_import_args(path::AbstractString, mode::Symbol, target::AbstractString)
    mode in (:new, :append) || throw(ArgumentError("mode must be :new or :append, not $(repr(mode))"))
    mode == :append && isempty(target) && throw(ArgumentError("mode :append needs a target database id"))
    isfile(path) || throw(ArgumentError("no file at $path"))
    return nothing
end

"""
    import_lines(read!, s, mode, name, target) -> ImportResult

Run an import into a new database (`mode = :new`, named `name`) or into the
database item `target` (`mode = :append`), safely (see the top of this file).

`read!(db)` reads the file into `db` and returns `(warnings, rows, lines)`.
It closes its appenders when it is done. When it throws, the appenders still
open are closed here, and the database is put back.
"""
function import_lines(read!::F, s::Session, mode::Symbol, name::String, target::String)::ImportResult where {F}
    return mode == :new ? import_new(read!, s, name) : import_append(read!, s, target)
end

"Close the appenders still open on `db` after a failure. Errors here are dropped; the first error counts."
function abort_appenders!(db::LineDatabase)
    isempty(db.appenders) && return nothing
    d = Dict{String,ColumnAppender}(k => a::ColumnAppender for (k, a) in db.appenders)
    try
        close_appenders!(d)
    catch
    end
    return nothing
end

function import_new(read!::F, s::Session, name::String)::ImportResult where {F}
    p = s.project
    id = lock(() -> reserve_item_id!(p, ITEM_DATABASE), s.lock)
    dbs = joinpath(p.folder, "databases")
    mkpath(dbs)
    tmp = joinpath(dbs, ".importing-$id")
    note_job_folder!(tmp)
    db = nothing
    local result::Tuple{Vector{ImportWarning},Int,Int}
    try
        rm(tmp; recursive = true, force = true)
        db = create_database(tmp, name)
        result = read!(db)
        release_maps!(db)
        save_meta(db)
    catch
        db === nothing || abort_appenders!(db)
        rm(tmp; recursive = true, force = true)
        rethrow()
    end
    new_item = lock(s.lock) do
        folder = free_folder(dbs, folder_slug(name))
        final = joinpath(dbs, folder)
        try
            mv(tmp, final)
        catch
            rm(tmp; recursive = true, force = true)
            rethrow()
        end
        it = ProjectItem(id, ITEM_DATABASE, name, "databases/$folder", "", "")
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
    return ImportResult(new_item, result...)
end

function import_append(read!::F, s::Session, target::String)::ImportResult where {F}
    p = s.project
    # Take the lock only to find the target and mark it busy. While the file is
    # read, other changes to the target throw `ItemBusyError`; the rest of the
    # session is free. Readers see the committed rows (see `open_database`).
    it, db, before = lock(s.lock) do
        it = item(p, target)
        mark_busy!(s, target)
        try
            db = database(p, target)
            return it, db, committed_state(db)
        catch
            unmark_busy!(s, target)
            rethrow()
        end
    end
    local result::Tuple{Vector{ImportWarning},Int,Int}
    local committed::String
    try
        rows_before = db.rows_written
        nchannels = length(db.channels)
        try
            result = read!(db)
            release_maps!(db)
            committed = lock(s.lock) do
                save_meta(db)                    # the commit point
                read(meta_path(db), String)
            end
        catch
            abort_appenders!(db)
            undo_append!(db, nchannels, rows_before)
            rethrow()
        end
    finally
        unmark_busy!(s, target)
    end
    note_append_undo!(s, target, before, committed)
    return ImportResult(it, result...)
end

"""
Inside a job: note how to undo and redo the append to item `target`.
Undo keeps the appended rows in a side folder of the database until redo,
or until the redo is no longer possible.
"""
function note_append_undo!(s::Session, target::String, before::CommittedState, committed::String)
    side = Ref("")
    folder() = item_path(s.project, item(s.project, target))
    undo = () -> begin
        check_not_busy(s, target)
        side[] = roll_back!(folder(), before, committed)
        nothing
    end
    redo = () -> begin
        check_not_busy(s, target)
        roll_forward!(folder(), before, side[])
        side[] = ""
        nothing
    end
    drop = () -> begin
        isempty(side[]) || rm(side[]; recursive = true, force = true)
        side[] = ""
        nothing
    end
    note_job_undo!(undo, redo, drop; items = [target])
    return nothing
end

"After a failed append: cut the old channel files back and remove new ones."
function undo_append!(db::LineDatabase, nchannels::Int, rows::Int)
    for (k, c) in enumerate(db.channels)
        try
            if k <= nchannels
                cut_channel!(db, c, rows)
            else
                release_map!(db, c.name)
                foreach(f -> rm(f; force = true), channel_files(db, c))
            end
        catch e
            e isa InterruptException && rethrow()
            # `open_database` cuts uncommitted rows too; go on with the other channels.
        end
    end
    return nothing
end

"""
Bring importer settings to their stored types, with defaults for those not given.
Bad settings throw a `ToolError` with the problems, so a job fails with a
message the user can read.
"""
function importer_values(list::Vector{SettingSpec}, settings::AbstractDict, owner::String)::Dict{String,Any}
    problems = validate_settings(list, settings, owner)
    isempty(problems) || throw(ToolError(join(problems, " ")))
    v = default_settings(list)
    for st in list
        haskey(settings, st.key) && (v[st.key] = setting_value(st, settings[st.key]))
    end
    return v
end
