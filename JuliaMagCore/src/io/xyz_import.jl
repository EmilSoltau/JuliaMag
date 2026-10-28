# Geosoft XYZ import (spec 6.3).
#
# The file is read once, line by line, in chunks (see `eachfileline`).
# Values go straight to the channel appenders, so memory use does not grow
# with the file. A data row is scanned by byte index; no memory is allocated
# per value.
#
# Safety:
# - A new database is written to `databases/.importing-<id>/` and moved to its
#   final folder only when it is complete. Then the item is added to the project.
#   On any error the temp folder is removed and the error is thrown again.
# - In append mode the target database is written in place. `database.json` is
#   saved only at the end, so it is the commit point. On error the channel files
#   are cut back and new channel files are removed, so the target is as it was.
#   The target is marked busy while the file is read. Inside a job, the append
#   notes an undo that puts the target back (see `roll_back!`).

"Most warnings kept in a result. Later ones are counted, not kept."
const MAX_WARNINGS = 1000

"Most fiducial steps kept per line to find the median step."
const MAX_FID_STEPS = 1 << 20

const LINE_KEYWORDS = Dict("line" => LINE, "tie" => TIE, "base" => BASE, "test" => TEST,
                           "trend" => TREND, "random" => RANDOM, "special" => SPECIAL)

const XAppender = ColumnAppender{NumericWriter{Float64}}

"Everything the importer tracks while it reads a file."
mutable struct XyzState
    path::String
    db::LineDatabase
    crs::String
    progress::Progress
    file_bytes::Int
    last_bytes::Int
    # Names from "/" lines before the first data row, the last line for each count.
    names_by_count::Dict{Int,Vector{String}}
    # Columns. `ncols` is 0 until the first data row.
    ncols::Int
    colnames::Vector{String}
    apps::Vector{XAppender}
    appdict::Union{Nothing,Dict{String,ColumnAppender}}
    fid_col::Int
    starts::Vector{Int}
    stops::Vector{Int}
    # Lines. A header waits in `pending` until its first row comes.
    flight::Int
    date::String
    pending::Union{Nothing,LineId}
    pending_flight::Int
    pending_at::Int
    cur::Union{Nothing,LineInfo}
    warned::BitVector
    # Fiducials of the current line.
    fid_first::Float64
    fid_first_row::Int
    fid_prev::Float64
    fid_prev_row::Int
    fid_steps::Vector{Float64}
    # Result.
    warnings::Vector{ImportWarning}
    dropped_warnings::Int
    rows::Int
    lines::Int
end

function XyzState(path::String, db::LineDatabase, crs::String, progress::Progress)
    return XyzState(path, db, crs, progress, filesize(path), -1,
                    Dict{Int,Vector{String}}(), 0, String[], XAppender[], nothing, 0,
                    Vector{Int}(undef, 64), Vector{Int}(undef, 64),
                    0, "", nothing, 0, 0, nothing, falses(0),
                    NaN, 0, NaN, 0, Float64[],
                    ImportWarning[], 0, 0, 0)
end

function warn!(st::XyzState, file_line::Int, msg::String)
    if length(st.warnings) < MAX_WARNINGS
        push!(st.warnings, ImportWarning(file_line, msg))
    else
        st.dropped_warnings += 1
    end
    return nothing
end

# ---- one line of the file --------------------------------------------------

@inline is_blank(b::UInt8) = b == 0x20 || b == 0x09
@inline is_ascii_letter(b::UInt8) = (0x41 <= b <= 0x5a) || (0x61 <= b <= 0x7a)

function xyz_line!(st::XyzState, lineno::Int, line::SubString{String}, bytes_read::Int)
    if bytes_read != st.last_bytes      # a new chunk
        st.last_bytes = bytes_read
        is_cancelled(st.progress) && throw(ImportCancelled())
        report(st.progress, st.file_bytes == 0 ? 1.0 : min(bytes_read / st.file_bytes, 1.0))
    end
    s = line.string
    i, j = line_range(line)
    while i <= j && is_blank(codeunit(s, i))
        i += 1
    end
    i > j && return nothing
    b = codeunit(s, i)
    if b == UInt8('/')
        comment_line!(st, lineno, s, i, j)
    elseif is_ascii_letter(b) && !starts_with_number(s, i, j)
        id = parse_line_header(st, s, i, j)
        if id === nothing
            warn!(st, lineno, "not a line header, a comment or a row of numbers: " *
                              "\"$(field_text(s, i, min(j, i + 59)))\"; skipped")
        else
            header_line!(st, lineno, id)
        end
    else
        data_row!(st, lineno, s, i, j)
    end
    return nothing
end

"True when the first field is a number, such as `NaN` or `Inf`."
function starts_with_number(s::String, i::Int, j::Int)::Bool
    k = i
    while k <= j && !is_field_sep(codeunit(s, k))
        k += 1
    end
    return parse_field(s, i, k - 1) !== nothing
end

# ---- comments, flight and date ---------------------------------------------

"Split bytes `i:j` of `s` into fields, as new strings."
function field_strings(s::String, i::Int, j::Int)::Vector{String}
    out = String[]
    k = i
    while k <= j
        while k <= j && is_field_sep(codeunit(s, k))
            k += 1
        end
        k > j && break
        a = k
        while k <= j && !is_field_sep(codeunit(s, k))
            k += 1
        end
        push!(out, field_text(s, a, k - 1))
    end
    return out
end

function comment_line!(st::XyzState, lineno::Int, s::String, i::Int, j::Int)
    slashes = 0
    while i <= j && codeunit(s, i) == UInt8('/')
        slashes += 1
        i += 1
    end
    words = field_strings(s, i, j)
    if slashes >= 2 && !isempty(words)
        key = lowercase(rstrip(words[1], (':', '=')))
        if key == "flight"
            value = length(words) >= 2 ? lstrip(words[2], (':', '=')) : ""
            n = tryparse(Int, value)
            if n === nothing
                warn!(st, lineno, "the flight number \"$value\" is not a whole number; ignored")
            else
                st.flight = n
            end
            return nothing
        elseif key == "date"
            value = length(words) >= 2 ? String(lstrip(words[2], (':', '='))) : ""
            st.date = normal_date(value)
            return nothing
        end
    end
    # Only "/" lines before the first data row can name the columns.
    st.ncols == 0 && !isempty(words) && (st.names_by_count[length(words)] = words)
    return nothing
end

"Turn `yyyy/mm/dd` into `yyyy-mm-dd`. Other text is kept as it is."
function normal_date(t::String)::String
    m = match(r"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$", t)
    m === nothing && return t
    return string(m[1], "-", lpad(m[2], 2, '0'), "-", lpad(m[3], 2, '0'))
end

# ---- line headers ----------------------------------------------------------

"""
Read a line header such as `Line 1001`, `Tie 5.1`, `L1001`, `t 7.2` or `Line 10:16`
(`:16` is a flight number). Returns the line id, or `nothing` when the text is not
a header. A flight number in the header is stored in `st.pending_flight`.
"""
function parse_line_header(st::XyzState, s::String, i::Int, j::Int)::Union{Nothing,LineId}
    words = field_strings(s, i, min(j, i + 200))
    isempty(words) && return nothing
    w = words[1]
    k = something(findfirst(c -> !('A' <= c <= 'Z' || 'a' <= c <= 'z'), w), lastindex(w) + 1)
    word = lowercase(w[1:prevind(w, k)])
    rest = w[k:end]
    numtext = isempty(rest) ? (length(words) >= 2 ? words[2] : "") : rest
    t = get(LINE_KEYWORDS, word, nothing)
    if t === nothing
        (length(word) == 1 && uppercase(word[1]) in LINE_LETTERS) || return nothing
        t = line_type(word[1])
    end
    m = match(r"^(\d+)(?:\.(\d+))?(?::(\d+))?$", numtext)
    m === nothing && return nothing
    num, ver, fl = m[1], m[2], m[3]
    number = num === nothing ? nothing : tryparse(Int, num)
    version = ver === nothing ? 0 : tryparse(Int, ver)
    (number === nothing || version === nothing) && return nothing
    flight = fl === nothing ? nothing : tryparse(Int, fl)
    st.pending_flight = flight === nothing ? -1 : flight
    return LineId(t, number, version)
end

function header_line!(st::XyzState, lineno::Int, id::LineId)
    warn_empty_pending!(st)
    st.pending = id
    st.pending_at = lineno
    return nothing
end

function warn_empty_pending!(st::XyzState)
    id = st.pending
    id === nothing && return nothing
    warn!(st, st.pending_at, "line $(line_name(id)) has no rows; skipped")
    st.pending = nothing
    return nothing
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

# ---- data rows -------------------------------------------------------------

function data_row!(st::XyzState, lineno::Int, s::String, i::Int, j::Int)
    if st.ncols == 0
        # Before the first data row, a line with no number in it is not data.
        if !has_number(st, s, i, j)
            warn!(st, lineno, "not a line header, a comment or a row of numbers: " *
                              "\"$(field_text(s, i, min(j, i + 59)))\"; skipped")
            return nothing
        end
        setup_columns!(st, lineno, s, i, j)
    end
    n = scan_fields!(st.starts, st.stops, s, i, j)
    if n != st.ncols
        warn!(st, lineno, "expected $(st.ncols) values, found $n; row skipped")
        return nothing
    end
    l = current_line!(st)
    row = l.nrows + 1
    apps = st.apps
    @inbounds for c in 1:st.ncols
        a = st.starts[c]
        b = st.stops[c]
        v = NaN
        if !(a == b && codeunit(s, a) == UInt8('*'))
            x = parse_field(s, a, b)
            if x === nothing
                bad_value!(st, lineno, l, c, s, a, b)
            else
                v = x
            end
        end
        append_value!(apps[c], v)
        c == st.fid_col && track_fiducial!(st, v, row)
    end
    l.nrows = row
    st.rows += 1
    return nothing
end

function has_number(st::XyzState, s::String, i::Int, j::Int)::Bool
    n = scan_fields!(st.starts, st.stops, s, i, j)
    if n > length(st.starts)
        resize!(st.starts, n)
        resize!(st.stops, n)
        scan_fields!(st.starts, st.stops, s, i, j)
    end
    for k in 1:n
        a, b = st.starts[k], st.stops[k]
        (a == b && codeunit(s, a) == UInt8('*')) && return true
        parse_field(s, a, b) === nothing || return true
    end
    return false
end

@noinline function bad_value!(st::XyzState, lineno::Int, l::LineInfo, c::Int, s::String, a::Int, b::Int)
    st.warned[c] && return nothing
    st.warned[c] = true
    warn!(st, lineno, "column $(st.colnames[c]) on line $(line_name(l.id)) has a value that is not " *
                      "a number: \"$(field_text(s, a, min(b, a + 39)))\"; read as missing. " *
                      "Later bad values in this column on this line are not listed.")
    return nothing
end

"The line that rows go to now. Starts a new line when a header is waiting."
function current_line!(st::XyzState)::LineInfo
    cur = st.cur
    st.pending === nothing && cur !== nothing && return cur
    id = something(st.pending, LineId(RANDOM, 0, 0))
    flight = st.pending_flight >= 0 && st.pending !== nothing ? st.pending_flight : st.flight
    st.pending = nothing
    finish_line!(st)
    l = LineInfo(free_line_id(st.db, id), flight, st.date, 0.0, 1.0, 0, 0, true)
    add_line!(st.db, l)       # ends the line before it (see `add_line!`)
    st.cur = l
    st.lines += 1
    fill!(st.warned, false)
    st.fid_first, st.fid_first_row = NaN, 0
    st.fid_prev, st.fid_prev_row = NaN, 0
    empty!(st.fid_steps)
    return l
end

function track_fiducial!(st::XyzState, v::Float64, row::Int)
    isnan(v) && return nothing
    if st.fid_first_row == 0
        st.fid_first, st.fid_first_row = v, row
    elseif length(st.fid_steps) < MAX_FID_STEPS
        push!(st.fid_steps, (v - st.fid_prev) / (row - st.fid_prev_row))
    end
    st.fid_prev, st.fid_prev_row = v, row
    return nothing
end

"Set the fiducial start and step of the current line from its FIDUCIAL column."
function finish_line!(st::XyzState)
    l = st.cur
    (l === nothing || st.fid_col == 0 || st.fid_first_row == 0) && return nothing
    step = 1.0
    n = length(st.fid_steps)
    if n > 0
        v = st.fid_steps
        # Median. `partialsort!` with one index selects in place; a range would allocate.
        m = isodd(n) ? partialsort!(v, (n + 1) ÷ 2) : (partialsort!(v, n ÷ 2) + partialsort!(v, n ÷ 2 + 1)) / 2
        if isfinite(m) && m > 0
            step = m
        else
            warn!(st, 0, "line $(line_name(l.id)): the fiducial step is $m, not above 0; step set to 1")
        end
    end
    l.fid_step = step
    l.fid_start = st.fid_first - (st.fid_first_row - 1) * step
    return nothing
end

# ---- columns ---------------------------------------------------------------

"Count the fields of the first data row, name the columns and make the channels."
function setup_columns!(st::XyzState, lineno::Int, s::String, i::Int, j::Int)
    n = scan_fields!(st.starts, st.stops, s, i, j)   # `has_number` made them long enough
    resize!(st.starts, n)
    resize!(st.stops, n)
    raw = get(st.names_by_count, n, nothing)
    if raw === nothing
        raw = ["C$k" for k in 1:n]
        warn!(st, lineno, "no \"/\" line has $n names for the $n columns; the channels are named C1 to C$n")
    end
    empty!(st.names_by_count)
    db = st.db
    taken = Set{String}()
    roles = Dict{ChannelRole,String}()
    for (k, r) in enumerate(raw)
        label = String(strip(r, ('"', '\'')))
        name = channel_name(label, k, taken)
        push!(taken, lowercase(name))
        old = channel_position_ci(db, name)
        if old > 0
            # Append mode: the column goes to the channel that is already there.
            c = db.channels[old]
            (c.eltype === Float64 && c.arraylen == 1) || throw(DatabaseError(
                "channel $(c.name) of database $(db.name) holds $(c.eltype) values; XYZ import writes Float64"))
            name = c.name
        end
        push!(st.colnames, name)
        uppercase(name) == "FIDUCIAL" && st.fid_col == 0 && (st.fid_col = k)
        role = name_role(name)
        (role == ROLE_NONE || haskey(roles, role)) && (role = ROLE_NONE)
        role == ROLE_NONE || (roles[role] = name)
        old == 0 && add_channel!(db, ChannelInfo(name, label, Float64, "", role, :normal, 10, -1, true, 1))
    end
    add_pair!(db, get(roles, ROLE_X, ""), get(roles, ROLE_Y, ""), st.crs)
    add_pair!(db, get(roles, ROLE_LON, ""), get(roles, ROLE_LAT, ""), "EPSG:4326")
    db.current_pair == 0 && !isempty(db.pairs) && (db.current_pair = 1)
    st.ncols = n
    st.warned = falses(n)
    d = open_appenders(db, st.colnames)
    st.appdict = d
    st.apps = XAppender[d[c]::XAppender for c in st.colnames]
    return nothing
end

"Index of the channel whose name equals `name`, ignoring case, or 0."
channel_position_ci(db::LineDatabase, name::AbstractString) =
    something(findfirst(c -> lowercase(c.name) == lowercase(name), db.channels), 0)

function add_pair!(db::LineDatabase, x::String, y::String, crs::String)
    (isempty(x) || isempty(y)) && return nothing
    any(p -> p.x == x && p.y == y, db.pairs) && return nothing
    push!(db.pairs, PositionPair(x, y, crs))
    return nothing
end

function name_role(name::AbstractString)::ChannelRole
    u = uppercase(name)
    u in ("X", "EASTING") && return ROLE_X
    u in ("Y", "NORTHING") && return ROLE_Y
    u in ("LON", "LONG", "LONGITUDE") && return ROLE_LON
    u in ("LAT", "LATITUDE") && return ROLE_LAT
    return ROLE_NONE
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

# ---- the whole file --------------------------------------------------------

"Read the file into `st.db`. Ends with the appenders closed."
function read_xyz!(st::XyzState)
    eachfileline(st.path) do lineno, line, bytes_read
        xyz_line!(st, lineno, line, bytes_read)
    end
    st.ncols == 0 && throw(ArgumentError("$(st.path) has no rows of numbers to import"))
    # A last check, so a cancel during the last chunk stops the import too.
    is_cancelled(st.progress) && throw(ImportCancelled())
    finish_line!(st)
    warn_empty_pending!(st)
    d = st.appdict
    st.appdict = nothing
    d === nothing || close_appenders!(d)
    st.dropped_warnings > 0 &&
        push!(st.warnings, ImportWarning(0, "$(st.dropped_warnings) more warnings were not listed"))
    report(st.progress, 1.0)
    return nothing
end

"Close the appenders after a failure. Errors here are dropped; the first error counts."
function abort_appenders!(st::XyzState)
    d = st.appdict
    st.appdict = nothing
    d === nothing && return nothing
    try
        close_appenders!(d)
    catch
    end
    return nothing
end

release_maps!(db::LineDatabase) = foreach(c -> release_map!(db, c.name), db.channels)

"A folder name made from a database name: lower case letters, digits, `-` and `_`."
function folder_slug(name::AbstractString)::String
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
    t = rstrip(String(take!(io)), '-')
    return isempty(t) ? "database" : String(t)
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

"""
    import_xyz(s, path; name, crs = "", mode = :new, target = "", progress = NO_PROGRESS) -> ImportResult

Import a Geosoft XYZ file (spec 6.3).

- `name`: name of the new database; the file name without extension by default.
- `crs`: coordinate system of the X/Y (or EASTING/NORTHING) pair, such as `"EPSG:7855"`.
  A LON/LAT pair always gets `"EPSG:4326"`.
- `mode = :new` makes a new database item. `mode = :append` adds the lines to the
  database item `target`; a line that is already there gets the next free version.
- `progress` gets the fraction of bytes read, and is checked for cancel once per chunk.
  A cancelled import throws `ImportCancelled`.

Problems in rows and values become warnings in the result. A failed or cancelled
import throws, and leaves no new item and no changed database behind.

The import is recorded in the history as `"import.geosoft_xyz"`.
`record = false` skips that. The importer does this when it runs inside a job
(see `import_file`), because the job records the import, with its job id.
"""
function import_xyz(s::Session, path::String; name::AbstractString = splitext(basename(path))[1],
                    crs::AbstractString = "", mode::Symbol = :new, target::AbstractString = "",
                    progress::Progress = NO_PROGRESS, record::Bool = true)::ImportResult
    mode in (:new, :append) || throw(ArgumentError("mode must be :new or :append, not $(repr(mode))"))
    mode == :append && isempty(target) && throw(ArgumentError("mode :append needs a target database id"))
    isfile(path) || throw(ArgumentError("no file at $path"))
    args = Dict{String,Any}("path" => path, "name" => String(name), "crs" => String(crs),
                            "mode" => String(mode), "target" => String(target))
    report(progress, 0.0)
    r = mode == :new ? import_xyz_new(s, path, String(name), String(crs), progress) :
                       import_xyz_append(s, path, String(target), String(crs), progress)
    record && record!(s, "import.geosoft_xyz", args)
    return r
end

function import_xyz_new(s::Session, path::String, name::String, crs::String, progress::Progress)
    p = s.project
    id = lock(() -> reserve_item_id!(p, ITEM_DATABASE), s.lock)
    dbs = joinpath(p.folder, "databases")
    mkpath(dbs)
    tmp = joinpath(dbs, ".importing-$id")
    note_job_folder!(tmp)
    st = nothing
    local result::Tuple{Vector{ImportWarning},Int,Int}
    try
        rm(tmp; recursive = true, force = true)
        db = create_database(tmp, name)
        st = XyzState(path, db, crs, progress)
        read_xyz!(st)
        release_maps!(db)
        save_meta(db)
        result = (st.warnings, st.rows, st.lines)
    catch
        st === nothing || abort_appenders!(st)
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

function import_xyz_append(s::Session, path::String, target::String, crs::String, progress::Progress)
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
    try
        rows_before = db.rows_written
        nchannels = length(db.channels)
        st = nothing
        try
            st = XyzState(path, db, crs, progress)
            read_xyz!(st)
            release_maps!(db)
            lock(() -> save_meta(db), s.lock)     # the commit point
            result = (st.warnings, st.rows, st.lines)
        catch
            st === nothing || abort_appenders!(st)
            undo_append!(db, nchannels, rows_before)
            rethrow()
        end
    finally
        unmark_busy!(s, target)
    end
    note_append_undo!(s, target, before)
    return ImportResult(it, result...)
end

"""
Inside a job: note how to undo and redo the append to item `target`.
Undo keeps the appended rows in a side folder of the database until redo,
or until the redo is no longer possible.
"""
function note_append_undo!(s::Session, target::String, before::CommittedState)
    side = Ref("")
    folder() = item_path(s.project, item(s.project, target))
    undo = () -> begin
        check_not_busy(s, target)
        side[] = roll_back!(folder(), before)
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
    note_job_undo!(undo, redo, drop)
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

# ---- registration ----------------------------------------------------------

"""
Run the XYZ importer from settings: `name`, `crs`, `mode` (\"new\" or \"append\"), `target`.
Not recorded: the job that runs it records it (see `ImporterSpec`).
"""
function run_xyz_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult
    get_text(k, default) = String(get(settings, k, default))
    name = get_text("name", "")
    return import_xyz(s, path; name = isempty(name) ? splitext(basename(path))[1] : name,
                      crs = get_text("crs", ""), mode = Symbol(get_text("mode", "new")),
                      target = get_text("target", ""), progress, record = false)
end

register_importer!(ImporterSpec("import.geosoft_xyz", "Geosoft XYZ", [".xyz"], ITEM_DATABASE,
                                Any[], run_xyz_importer))
