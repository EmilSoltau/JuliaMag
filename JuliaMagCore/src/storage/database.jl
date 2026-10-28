# A line database: a folder with `database.json` and one file (or two) per channel.
# All lines are stored end to end in each channel file.
# A line's rows are `offset+1 : offset+nrows`.

using JSON3, StructTypes

"An error in a database: a missing or broken file, or an unknown name."
struct DatabaseError <: Exception
    msg::String
end

Base.showerror(io::IO, e::DatabaseError) = print(io, "DatabaseError: ", e.msg)

"""
A line database stored in `folder`.

The fields after `made_by` are internal caches. They are not saved.
"""
mutable struct LineDatabase
    folder::String
    name::String
    description::String
    lines::Vector{LineInfo}
    channels::Vector{ChannelInfo}
    pairs::Vector{PositionPair}
    "Index into `pairs` of the pair in use, or 0 for none."
    current_pair::Int
    "Id of the job that made the database, or `\"\"`."
    made_by::String
    "Mapped column files by channel name. See `release_map!`."
    maps::Dict{String,Vector}
    "Channels that have an open appender."
    appending::Set{String}
    line_index::Dict{LineId,Int}
    channel_index::Dict{String,Int}

    function LineDatabase(folder, name, description, lines, channels, pairs, current_pair, made_by)
        return new(folder, name, description, lines, channels, pairs, current_pair, made_by,
                   Dict{String,Vector}(), Set{String}(), Dict{LineId,Int}(), Dict{String,Int}())
    end
end

Base.show(io::IO, db::LineDatabase) =
    print(io, "LineDatabase(", repr(db.name), ", ", length(db.lines), " lines, ",
          length(db.channels), " channels)")

# ---- database.json ---------------------------------------------------------

const META_FILE = "database.json"
const META_VERSION = 1

StructTypes.StructType(::Type{LineId}) = StructTypes.Struct()
StructTypes.StructType(::Type{LineInfo}) = StructTypes.Struct()
StructTypes.StructType(::Type{PositionPair}) = StructTypes.Struct()

"How a channel is written in `database.json`: like `ChannelInfo`, with `eltype` as a name."
struct ChannelRecord
    name::String
    label::String
    eltype::String
    units::String
    role::ChannelRole
    format::Symbol
    width::Int
    decimals::Int
    protected::Bool
    arraylen::Int
end
StructTypes.StructType(::Type{ChannelRecord}) = StructTypes.Struct()

"The content of `database.json`."
struct MetaRecord
    version::Int
    name::String
    description::String
    lines::Vector{LineInfo}
    channels::Vector{ChannelRecord}
    pairs::Vector{PositionPair}
    current_pair::Int
    made_by::String
end
StructTypes.StructType(::Type{MetaRecord}) = StructTypes.Struct()

function ChannelRecord(c::ChannelInfo)
    name = eltype_name(c.eltype)
    name === nothing && throw(DatabaseError("channel $(c.name) has a type that cannot be stored: $(c.eltype)"))
    return ChannelRecord(c.name, c.label, name, c.units, c.role, c.format, c.width,
                         c.decimals, c.protected, c.arraylen)
end

function ChannelInfo(r::ChannelRecord)
    T = get(CHANNEL_ELTYPES, r.eltype, nothing)
    T === nothing && throw(DatabaseError("channel $(r.name) has an unknown type: $(r.eltype)"))
    return ChannelInfo(r.name, r.label, T, r.units, r.role, r.format, r.width,
                       r.decimals, r.protected, r.arraylen)
end

meta_path(db::LineDatabase) = joinpath(db.folder, META_FILE)
channels_folder(folder::AbstractString) = joinpath(folder, "channels")

"""
    create_database(folder, name) -> LineDatabase

Make a new, empty database in `folder`. The folder is created when needed.
Throws `DatabaseError` when a database already exists there.
"""
function create_database(folder::String, name::String)::LineDatabase
    isfile(joinpath(folder, META_FILE)) &&
        throw(DatabaseError("a database already exists in $folder"))
    mkpath(channels_folder(folder))
    db = LineDatabase(folder, name, "", LineInfo[], ChannelInfo[], PositionPair[], 0, "")
    save_meta(db)
    return db
end

"""
    open_database(folder) -> LineDatabase

Open the database in `folder`.
Throws `DatabaseError` when `database.json` is missing or broken,
or when a channel file is missing.
"""
function open_database(folder::String)::LineDatabase
    path = joinpath(folder, META_FILE)
    isfile(path) || throw(DatabaseError("no database in $folder: $META_FILE is missing"))
    rec = try
        JSON3.read(read(path, String), MetaRecord; allow_inf = true)
    catch e
        e isa InterruptException && rethrow()
        throw(DatabaseError("$META_FILE in $folder is broken: $(sprint(showerror, e))"))
    end
    rec.version == META_VERSION ||
        throw(DatabaseError("$META_FILE in $folder has version $(rec.version); this program reads version $META_VERSION"))
    channels = ChannelInfo[ChannelInfo(r) for r in rec.channels]
    db = LineDatabase(folder, rec.name, rec.description, rec.lines, channels, rec.pairs,
                      rec.current_pair, rec.made_by)
    check_meta(db)
    return db
end

"Check that the facts in `database.json` fit together and that the channel files exist."
function check_meta(db::LineDatabase)
    broken(msg) = throw(DatabaseError("$META_FILE in $(db.folder) is broken: $msg"))
    rows = 0
    ids = Set{LineId}()
    for l in db.lines
        l.id in ids && broken("line $(line_name(l.id)) appears twice")
        push!(ids, l.id)
        l.nrows >= 0 || broken("line $(line_name(l.id)) has $(l.nrows) rows")
        l.offset == rows || broken("line $(line_name(l.id)) starts at row $(l.offset), expected $rows")
        rows += l.nrows
    end
    taken = Set{String}()
    for c in db.channels
        check_channel_info(c, taken)
        push!(taken, lowercase(c.name))
        for p in channel_files(db, c)
            isfile(p) || throw(DatabaseError("channel $(c.name) of $(db.folder): file $p is missing"))
        end
    end
    0 <= db.current_pair <= length(db.pairs) ||
        broken("current_pair $(db.current_pair) does not name a position pair")
    return nothing
end

"""
    save_meta(db)

Write `database.json`. The file is first written to `database.json.tmp`
and then moved over the old one, so a crash never leaves a half-written file.
Channel files shorter than `total_rows(db)` are first padded with missing values.
"""
function save_meta(db::LineDatabase)
    isempty(db.appending) ||
        throw(DatabaseError("close the appenders of $(join(sort!(collect(db.appending)), ", ")) before saving"))
    pad_channels!(db)
    rec = MetaRecord(META_VERSION, db.name, db.description, db.lines,
                     ChannelRecord[ChannelRecord(c) for c in db.channels],
                     db.pairs, db.current_pair, db.made_by)
    path = meta_path(db)
    tmp = path * ".tmp"
    open(tmp, "w") do io
        JSON3.pretty(io, JSON3.write(rec; allow_inf = true); allow_inf = true)
        println(io)
    end
    mv(tmp, path; force = true)
    return nothing
end

# ---- lookups ---------------------------------------------------------------

"Total number of rows of all lines. Every channel file holds this many rows."
total_rows(db::LineDatabase)::Int = sum(l -> l.nrows, db.lines; init = 0)

# The indexes are caches. A lookup checks the hit and rebuilds the index on a miss,
# so code that edits `db.lines` or `db.channels` directly never gets a wrong answer.
function line_position(db::LineDatabase, id::LineId)::Int
    i = get(db.line_index, id, 0)
    (1 <= i <= length(db.lines) && db.lines[i].id == id) && return i
    empty!(db.line_index)
    for (k, l) in enumerate(db.lines)
        db.line_index[l.id] = k
    end
    return get(db.line_index, id, 0)
end

function channel_position(db::LineDatabase, name::AbstractString)::Int
    i = get(db.channel_index, name, 0)
    (1 <= i <= length(db.channels) && db.channels[i].name == name) && return i
    empty!(db.channel_index)
    for (k, c) in enumerate(db.channels)
        db.channel_index[c.name] = k
    end
    return get(db.channel_index, name, 0)
end

"Return the line with id `id`. Throws `DatabaseError` when there is none."
function line(db::LineDatabase, id::LineId)::LineInfo
    i = line_position(db, id)
    i == 0 && throw(DatabaseError("no line $(line_name(id)) in database $(db.name)"))
    return db.lines[i]
end

"Return the channel called `name`. Throws `DatabaseError` when there is none."
function channel(db::LineDatabase, name::AbstractString)::ChannelInfo
    i = channel_position(db, name)
    i == 0 && throw(DatabaseError("no channel $name in database $(db.name)"))
    return db.channels[i]
end

# ---- channel files ---------------------------------------------------------

"Paths of the files of a channel: one for numbers, two (`.str`, `.off`) for strings."
function channel_files(db::LineDatabase, c::ChannelInfo)::Vector{String}
    base = joinpath(channels_folder(db.folder), c.name)
    c.eltype === String && return [base * ".str", base * ".off"]
    return [base * COLUMN_EXTENSIONS[c.eltype]]
end

# The file name of a channel is its name, so the name must be a valid file name
# on Windows too. Windows also ignores case, so `mag` and `MAG` would clash.
const BAD_NAME_CHARS = Set("<>:\"/\\|?*")
const RESERVED_NAMES = Set(["CON", "PRN", "AUX", "NUL",
    ("COM$i" for i in 0:9)..., ("LPT$i" for i in 0:9)...])

function check_channel_info(c::ChannelInfo, taken::Set{String})
    bad(msg) = throw(DatabaseError("channel $(repr(c.name)): $msg"))
    isempty(c.name) && bad("the name is empty")
    any(ch -> ch in BAD_NAME_CHARS || iscntrl(ch), c.name) &&
        bad("the name may not contain control characters or any of <>:\"/\\|?*")
    (endswith(c.name, ' ') || endswith(c.name, '.')) && bad("the name may not end with a space or a dot")
    uppercase(c.name) in RESERVED_NAMES && bad("the name is reserved on Windows")
    lowercase(c.name) in taken && bad("a channel with this name already exists (case is ignored)")
    eltype_name(c.eltype) === nothing &&
        bad("type $(c.eltype) cannot be stored; use one of $(join(sort!(collect(keys(CHANNEL_ELTYPES))), ", "))")
    c.arraylen >= 1 || bad("arraylen must be 1 or more, not $(c.arraylen)")
    (c.eltype === String && c.arraylen != 1) && bad("a string channel cannot be an array")
    return nothing
end

"""
    add_channel!(db, info)

Add a channel. Its file is created at once with `total_rows(db)` missing values.
Call `save_meta` to store the change in `database.json`.
"""
function add_channel!(db::LineDatabase, info::ChannelInfo)
    check_channel_info(info, Set{String}(lowercase(c.name) for c in db.channels))
    n = total_rows(db)
    files = channel_files(db, info)
    if info.eltype === String
        create_string_column(files[1], files[2], n)
    else
        create_column(files[1], info.eltype, n * info.arraylen)
    end
    push!(db.channels, info)
    return info
end

"""
    add_line!(db, info)

Add a line after the last one. Sets `info.offset` to the current total rows.
The rows of the line are written with appenders.
Channels that get no values are padded with missing values by
`close_appenders!` and `save_meta`.
"""
function add_line!(db::LineDatabase, info::LineInfo)
    line_position(db, info.id) == 0 ||
        throw(DatabaseError("line $(line_name(info.id)) is already in database $(db.name)"))
    info.nrows >= 0 || throw(DatabaseError("line $(line_name(info.id)) cannot have $(info.nrows) rows"))
    info.offset = total_rows(db)
    push!(db.lines, info)
    return info
end

# ---- memory maps -----------------------------------------------------------
#
# Mapped column files are kept in `db.maps`, one per channel.
# Windows does not allow a file to be resized, truncated or renamed while it is mapped.
# So before a channel file grows, `release_map!` drops its map from the cache,
# and the next read maps the file again with its new size.
# On Windows the dropped map is only unmapped when the garbage collector frees it,
# so `release_map!` runs the collector there. A view that a caller still holds
# keeps the old map alive: do not keep views across calls that grow a channel.

function release_map!(db::LineDatabase, name::AbstractString)
    dropped = pop!(db.maps, name, nothing) !== nothing
    dropped && Sys.iswindows() && GC.gc()
    return nothing
end

# A separate function, so `mapped` holds no reference to an old map
# while `pad_channel!` releases it.
map_fits(m, ::Type{T}, need::Integer) where {T} = m isa Vector{T} && length(m) >= need

"""
Return the mapped file of a numeric channel, or the mapped `.off` file of a string channel.
The map holds at least `need` values. When the file is shorter (a line was added
and no appender wrote its rows yet), it is first padded to `total_rows(db)`.
"""
function mapped(db::LineDatabase, c::ChannelInfo, ::Type{T}, need::Integer) where {T}
    if !map_fits(get(db.maps, c.name, nothing), T, need)
        pad_channel!(db, c)
        path = c.eltype === String ? channel_files(db, c)[2] : channel_files(db, c)[1]
        db.maps[c.name] = map_column(path, T)
    end
    return db.maps[c.name]::Vector{T}
end

"Look up a line and a channel for reading or writing, with checks."
function locate(db::LineDatabase, id::LineId, name::AbstractString)
    c = channel(db, name)
    l = line(db, id)
    name in db.appending &&
        throw(DatabaseError("channel $name is being appended to; close its appender first"))
    return c, l
end

# ---- reading ---------------------------------------------------------------

"""
    read_channel(db, line, name)

Return the values of channel `name` on line `line`.

- A plain numeric channel gives a view into the mapped file (no copy).
- An array channel gives an `arraylen x nrows` view into the mapped file.
- A string channel gives a new `Vector{String}`.
"""
function read_channel(db::LineDatabase, id::LineId, name::String)::AbstractArray
    c, l = locate(db, id, name)
    return read_rows(db, c, l, c.eltype)
end

function read_rows(db::LineDatabase, c::ChannelInfo, l::LineInfo, ::Type{T}) where {T<:NumericEltype}
    a = c.arraylen
    m = mapped(db, c, T, (l.offset + l.nrows) * a)
    v = view(m, (l.offset * a + 1):((l.offset + l.nrows) * a))
    return a == 1 ? v : reshape(v, a, l.nrows)
end

function read_rows(db::LineDatabase, c::ChannelInfo, l::LineInfo, ::Type{String})
    offs = mapped(db, c, Int64, l.offset + l.nrows)
    return read_strings(channel_files(db, c)[1], offs, (l.offset + 1):(l.offset + l.nrows))
end

read_rows(::LineDatabase, c::ChannelInfo, ::LineInfo, T::Type) =
    throw(DatabaseError("channel $(c.name) has a type that cannot be read: $T"))

# ---- writing ---------------------------------------------------------------

"Convert `x` to the element type of a channel. A missing value of any type stays missing."
function to_value(::Type{T}, x, c::ChannelInfo) where {T<:NumericEltype}
    x isa Real || throw(DatabaseError("channel $(c.name) holds numbers, not $(repr(x))"))
    x isa Union{AbstractFloat,Signed,Unsigned} && ismissingvalue(x) && return missing_value(T)
    try
        return convert(T, x)
    catch e
        e isa InexactError || rethrow()
        throw(DatabaseError("value $x does not fit channel $(c.name) of type $T"))
    end
end

function to_value(::Type{String}, x, c::ChannelInfo)
    x isa AbstractString || throw(DatabaseError("channel $(c.name) holds text, not $(repr(x))"))
    return String(x)
end

function check_row(c::ChannelInfo, l::LineInfo, row::Integer)
    1 <= row <= l.nrows || throw(DatabaseError(
        "row $row is outside line $(line_name(l.id)), which has $(l.nrows) rows (channel $(c.name))"))
    return nothing
end

"""
    write_value!(db, line, name, row, x)

Write one value at `row` (counted from 1 within the line) and return the old value.
For an array channel `x` is a vector of `arraylen` values, and the old row is returned.
The value goes straight to the file.
"""
function write_value!(db::LineDatabase, id::LineId, name::String, row::Int, x)
    c, l = locate(db, id, name)
    check_row(c, l, row)
    return write_one!(db, c, l, row, x, c.eltype)
end

function write_one!(db::LineDatabase, c::ChannelInfo, l::LineInfo, row::Int, x,
                    ::Type{T}) where {T<:NumericEltype}
    a = c.arraylen
    m = mapped(db, c, T, (l.offset + l.nrows) * a)
    i = (l.offset + row - 1) * a
    if a == 1
        new = to_value(T, x, c)
        old = m[i + 1]
        m[i + 1] = new
    else
        (x isa AbstractVector && length(x) == a) ||
            throw(DatabaseError("channel $(c.name) needs $a values per row"))
        new = T[to_value(T, v, c) for v in x]
        old = m[(i + 1):(i + a)]
        m[(i + 1):(i + a)] = new
    end
    Mmap.sync!(m)
    return old
end

function write_one!(db::LineDatabase, c::ChannelInfo, l::LineInfo, row::Int, x, ::Type{String})
    new = to_value(String, x, c)
    offs = mapped(db, c, Int64, l.offset + l.nrows)
    r = l.offset + row
    old = only(read_strings(channel_files(db, c)[1], offs, r:r))
    replace_strings!(channel_files(db, c)[1], offs, r:r, [new])
    Mmap.sync!(offs)
    return old
end

write_one!(::LineDatabase, c::ChannelInfo, ::LineInfo, ::Int, _, T::Type) =
    throw(DatabaseError("channel $(c.name) has a type that cannot be written: $T"))

"""
    write_channel!(db, line, name, values)

Write all values of a channel on one line and return the old values (a copy).
`values` must have one value per row of the line.
For an array channel it is an `arraylen x nrows` matrix.
"""
function write_channel!(db::LineDatabase, id::LineId, name::String, values::AbstractArray)
    c, l = locate(db, id, name)
    want = c.arraylen == 1 ? (l.nrows,) : (c.arraylen, l.nrows)
    size(values) == want || throw(DatabaseError(
        "channel $name on line $(line_name(id)) needs $(join(want, " x ")) values, not $(join(size(values), " x "))"))
    return write_all!(db, c, l, values, c.eltype)
end

function write_all!(db::LineDatabase, c::ChannelInfo, l::LineInfo, values::AbstractArray,
                    ::Type{T}) where {T<:NumericEltype}
    new = T[to_value(T, v, c) for v in values]   # convert all first, so a bad value writes nothing
    v = read_rows(db, c, l, T)
    old = copy(v)
    copyto!(vec(v), new)
    Mmap.sync!(mapped(db, c, T, 0))
    return old
end

function write_all!(db::LineDatabase, c::ChannelInfo, l::LineInfo, values::AbstractArray, ::Type{String})
    new = String[to_value(String, v, c) for v in values]
    old = read_rows(db, c, l, String)
    offs = mapped(db, c, Int64, l.offset + l.nrows)
    replace_strings!(channel_files(db, c)[1], offs, (l.offset + 1):(l.offset + l.nrows), new)
    Mmap.sync!(offs)
    return old
end

write_all!(::LineDatabase, c::ChannelInfo, ::LineInfo, _, T::Type) =
    throw(DatabaseError("channel $(c.name) has a type that cannot be written: $T"))

# ---- appending -------------------------------------------------------------

"""
Buffered writer that appends values to the end of one channel file.
Made by `open_appenders`; each appender buffers 1 MiB.
"""
mutable struct ColumnAppender{W<:Union{NumericWriter,StringWriter}}
    db::LineDatabase
    channel::ChannelInfo
    writer::W
    open::Bool
end

"""
    open_appenders(db, names) -> Dict{String,ColumnAppender}

Open one appender per channel name. Values go after the current end of each
channel file. Close them all with `close_appenders!`.
"""
function open_appenders(db::LineDatabase, names)::Dict{String,ColumnAppender}
    chans = ChannelInfo[channel(db, n) for n in names]
    for c in chans
        c.name in db.appending && throw(DatabaseError("channel $(c.name) already has an open appender"))
    end
    out = Dict{String,ColumnAppender}()
    try
        for c in chans
            release_map!(db, c.name)
            files = channel_files(db, c)
            w = c.eltype === String ? StringWriter(files[1], files[2]) : NumericWriter{c.eltype}(files[1])
            out[c.name] = ColumnAppender(db, c, w, true)
            push!(db.appending, c.name)
        end
    catch
        close_appenders!(out)
        rethrow()
    end
    return out
end

"""
    append_value!(a, x)

Append one value. For an array channel, append a vector of `arraylen` values
for a whole row, or the values of a row one by one.
"""
function append_value!(a::ColumnAppender, x)
    a.open || throw(DatabaseError("the appender of channel $(a.channel.name) is closed"))
    append_to!(a.writer, a.channel, x)
    return nothing
end

append_to!(w::NumericWriter{T}, c::ChannelInfo, x) where {T} = writer_put!(w, to_value(T, x, c))

function append_to!(w::NumericWriter{T}, c::ChannelInfo, x::AbstractVector) where {T}
    for v in x
        writer_put!(w, to_value(T, v, c))
    end
    return nothing
end

append_to!(w::StringWriter, c::ChannelInfo, x) = writer_put!(w, to_value(String, x, c))

"""
    close_appenders!(d)

Write out the buffers and close the files. Then every channel of the database
that is shorter than `total_rows(db)` is padded with missing values,
so all channels stay aligned. Throws `DatabaseError` when a channel got more
values than the lines have rows.
"""
function close_appenders!(d::AbstractDict{String,<:ColumnAppender})
    dbs = LineDatabase[]
    failure = nothing
    for a in values(d)
        a.open || continue
        try
            close_writer!(a.writer)
        catch e
            # Close the other appenders too, then report the first failure.
            failure === nothing && (failure = e)
        end
        a.open = false
        delete!(a.db.appending, a.channel.name)
        any(x -> x === a.db, dbs) || push!(dbs, a.db)
    end
    failure === nothing || throw(failure)
    foreach(pad_channels!, dbs)
    return nothing
end

"Pad every channel file that is shorter than `total_rows(db)` with missing values."
function pad_channels!(db::LineDatabase)
    for c in db.channels
        c.name in db.appending || pad_channel!(db, c)
    end
    return nothing
end

"""
Pad one channel file to `total_rows(db)` rows with missing values.
Throws `DatabaseError` when the file holds more rows than that.
"""
function pad_channel!(db::LineDatabase, c::ChannelInfo)
    n = total_rows(db)
    files = channel_files(db, c)
    have = c.eltype === String ? column_length(files[2], Int64) : column_length(files[1], c.eltype)
    want = c.eltype === String ? n : n * c.arraylen
    have == want && return nothing
    have > want && throw(DatabaseError(
        "channel $(c.name) of database $(db.name) has $have values, but the lines need $want"))
    release_map!(db, c.name)
    if c.eltype === String
        pad_string_column(files[2], n)
    else
        pad_column(files[1], c.eltype, want)
    end
    return nothing
end
