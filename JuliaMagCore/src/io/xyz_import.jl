# Geosoft XYZ import (spec 6.3).
#
# The file is read once, line by line, in chunks (see `eachfileline`).
# Values go straight to the channel appenders, so memory use does not grow
# with the file. A data row is scanned by byte index; no memory is allocated
# per value.
#
# Staging, commit, append with rollback and undo, warnings and progress are
# shared with the other line importers (see `line_import.jl`).

"Everything the importer tracks while it reads a file."
mutable struct XyzState
    path::String
    db::LineDatabase
    crs::String
    ticker::ChunkProgress
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
    fid::FidTracker
    # Result.
    log::WarningLog
    rows::Int
    lines::Int
end

function XyzState(path::String, db::LineDatabase, crs::String, progress::Progress)
    return XyzState(path, db, crs, ChunkProgress(progress, path),
                    Dict{Int,Vector{String}}(), 0, String[], XAppender[], nothing, 0,
                    Vector{Int}(undef, 64), Vector{Int}(undef, 64),
                    0, "", nothing, 0, 0, nothing, falses(0), FidTracker(),
                    WarningLog(), 0, 0)
end

warn!(st::XyzState, file_line::Int, msg::String) = warn!(st.log, file_line, msg)

# ---- one line of the file --------------------------------------------------


function xyz_line!(st::XyzState, lineno::Int, line::SubString{String}, bytes_read::Int)
    tick!(st.ticker, bytes_read)
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
    r = parse_line_name(field_strings(s, i, min(j, i + 200)))
    r === nothing && return nothing
    st.pending_flight = r[2]
    return r[1]
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
        warn!(st, lineno, row_length_message(st.ncols, n))
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
        c == st.fid_col && track_fiducial!(st.fid, v, row)
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

function bad_value!(st::XyzState, lineno::Int, l::LineInfo, c::Int, s::String, a::Int, b::Int)
    st.warned[c] && return nothing
    st.warned[c] = true
    warn_bad_value!(st.log, lineno, st.colnames[c], l, s, a, b)
    return nothing
end

"The line that rows go to now. Starts a new line when a header is waiting."
function current_line!(st::XyzState)::LineInfo
    cur = st.cur
    st.pending === nothing && cur !== nothing && return cur
    id = something(st.pending, DEFAULT_LINE_ID)
    flight = st.pending_flight >= 0 && st.pending !== nothing ? st.pending_flight : st.flight
    st.pending = nothing
    finish_line!(st)
    l = start_line!(st.db, id, flight, st.date)
    st.cur = l
    st.lines += 1
    fill!(st.warned, false)
    reset!(st.fid)
    return l
end

"Set the fiducial start and step of the current line from its FIDUCIAL column."
function finish_line!(st::XyzState)
    l = st.cur
    (l === nothing || st.fid_col == 0) && return nothing
    finish_fiducials!(st.fid, l, st.log)
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
    labels = String[]
    for (k, r) in enumerate(raw)
        label = String(strip(r, ('"', '\'')))
        name = channel_name(label, k, taken)
        push!(taken, lowercase(name))
        push!(labels, label)
        push!(st.colnames, name)
    end
    roles = position_roles(st.colnames)
    for k in 1:n
        # Append mode: the column goes to the channel that is already there.
        st.colnames[k] = import_channel!(db, st.colnames[k], labels[k], Float64, "", roles[k], 1, "XYZ")
        uppercase(st.colnames[k]) == "FIDUCIAL" && st.fid_col == 0 && (st.fid_col = k)
    end
    # `FIDUCIAL_` is the fiducial column that an export adds when it leaves out a FIDUCIAL channel.
    if st.fid_col == 0
        st.fid_col = something(findfirst(n -> uppercase(n) == "FIDUCIAL_", st.colnames), 0)
    end
    add_position_pairs!(db, st.colnames, roles, st.crs)
    st.ncols = n
    st.warned = falses(n)
    d = open_appenders(db, st.colnames)
    st.appdict = d
    st.apps = XAppender[d[c]::XAppender for c in st.colnames]
    return nothing
end

# ---- the whole file --------------------------------------------------------

"Read the file into `st.db`. Ends with the appenders closed."
function read_xyz!(st::XyzState)
    eachfileline(st.path) do lineno, line, bytes_read
        xyz_line!(st, lineno, line, bytes_read)
    end
    st.ncols == 0 && throw(ArgumentError("$(st.path) has no rows of numbers to import"))
    check_cancel(st.ticker)
    finish_line!(st)
    warn_empty_pending!(st)
    d = st.appdict
    st.appdict = nothing
    d === nothing || close_appenders!(d)
    report(st.ticker.progress, 1.0)
    return nothing
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
    check_import_args(path, mode, target)
    args = Dict{String,Any}("path" => path, "name" => String(name), "crs" => String(crs),
                            "mode" => String(mode), "target" => String(target))
    report(progress, 0.0)
    r = import_lines(s, mode, String(name), String(target)) do db
        st = XyzState(path, db, String(crs), progress)
        read_xyz!(st)
        return (final_warnings(st.log), st.rows, st.lines)
    end
    record && record!(s, "import.geosoft_xyz", args)
    return r
end

# ---- registration ----------------------------------------------------------

"The settings of the XYZ importer, for the import dialog and for checks."
const XYZ_SETTINGS = SettingSpec[
    ChoiceSetting("mode", "Import into", ["new", "append"]; default = "new",
                  labels = ["New database", "Append to existing"],
                  help = "new makes a new database. append adds the lines to an existing one."),
    TextSetting("name", "Database name"; help = "Leave blank to name it after the file."),
    TextSetting("target", "Append to"; help = "The id of the database to append to, such as db-1."),
    CRSSetting("crs", "Coordinate system"; help = "The code of the X and Y coordinates, such as EPSG:7855."),
]

"""
Run the XYZ importer from settings: `name`, `crs`, `mode` (\"new\" or \"append\"), `target`.
Missing settings take their defaults. Bad settings throw a `ToolError`
with the problems, so the job fails with a message the user can read.
Not recorded: the job that runs it records it (see `ImporterSpec`).
"""
function run_xyz_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult
    v = spec_values(XYZ_SETTINGS, settings, "Geosoft XYZ")
    name = v["name"]::String
    return import_xyz(s, path; name = isempty(name) ? splitext(basename(path))[1] : name,
                      crs = v["crs"]::String, mode = Symbol(v["mode"]::String),
                      target = v["target"]::String, progress, record = false)
end

register_importer!(ImporterSpec("import.geosoft_xyz", "Geosoft XYZ", [".xyz"], ITEM_DATABASE,
                                XYZ_SETTINGS, run_xyz_importer))
