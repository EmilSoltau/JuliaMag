# Geosoft database (`.gdb`) import (spec 6.3a).
#
# The file is opened and its header, tables and metadata are read first, so a
# refused file makes no temp folder. Then `import_lines` runs the import into a
# new or an existing database, safely, as for XYZ (see `line_import.jl`).
#
# The data is read one blob at a time through the directory: the values of one
# channel on one line. Each blob is unpacked, decoded, resampled onto the
# line's main sampling when it has another one, and appended. Memory stays at
# a few buffers the size of one blob (spec 6.2). Progress and cancel work per
# blob.
#
# A damaged data blob fails the import with a message that names the line and
# the channel. Everything that can be read with a change gives a warning.

"The buffers of one import, reused across blobs: packed and unpacked bytes, and values by JuliaMag type."
struct GdbBuffers
    bytes::Vector{UInt8}
    scratch::Vector{UInt8}
    decoded::Dict{DataType,Any}
    resampled::Dict{DataType,Any}
end

GdbBuffers() = GdbBuffers(UInt8[], UInt8[], Dict{DataType,Any}(), Dict{DataType,Any}())

"""
    gdb_at(f, line, chan)

Run `f()`; a `GdbError` from it is thrown again as
`GdbError("line <line>, channel <chan>: <message>")`.
"""
function gdb_at(f, line::String, chan::String)
    try
        return f()
    catch e
        e isa GdbError && throw(GdbError("line $line, channel $chan: $(e.msg)"))
        rethrow()
    end
end

"`\"channel A\"` or `\"channels A, B\"`, for a warning."
gdb_channels_text(names::Vector{String}) =
    length(names) == 1 ? "channel $(only(names))" : "channels $(join(names, ", "))"

"""
The header of the data blob of channel `p` at byte `offset`, checked against
the channel: the same value type, and whole rows of its array width.
"""
function gdb_channel_blob(g::GdbFile, offset::Int, p::GdbChannelPlan)::GdbBlobHeader
    h = read_blob_header(g, offset)
    h.type == p.gtype.code ||
        throw(GdbError("blob $(h.index) holds type $(h.type), but the channel has type $(p.gtype.code)"))
    h.count % p.arraylen == 0 ||
        throw(GdbError("blob $(h.index) holds $(h.count) values, not a multiple of the array width $(p.arraylen)"))
    return h
end

"""
Decode the value bytes of one blob into the typed buffers, resample them from
`from` onto `to` when the two differ, and append them to `app`. The `t.T`
dispatch picks the method for the JuliaMag type, so the loops have concrete
types (a function barrier).
"""
gdb_append_blob!(app::ColumnAppender, bufs::GdbBuffers, t::GdbType, notes::GdbValueNotes, from::Sampling,
                 to::Sampling, rows::Int, width::Int) =
    gdb_append_typed!(app, bufs, t, notes, from, to, rows, width, t.T)

function gdb_append_typed!(app::ColumnAppender, bufs::GdbBuffers, t::GdbType, notes::GdbValueNotes,
                           from::Sampling, to::Sampling, rows::Int, width::Int, ::Type{T}) where {T}
    values = get!(() -> T[], bufs.decoded, T)::Vector{T}
    gdb_values!(values, bufs.bytes, t, notes)
    if !same_sampling(from, to)
        out = get!(() -> T[], bufs.resampled, T)::Vector{T}
        resize!(out, rows * width)
        values = resample!(out, values, from, to, rows, width)
    end
    gdb_put_values!(app, values)
    return nothing
end

"Append each value of `values` to `app`."
function gdb_put_values!(app::ColumnAppender, values::Vector{T}) where {T}
    for x in values
        append_value!(app, x)
    end
    return nothing
end

"""
Everything an import reads from the file before `import_lines` starts: the line
and channel records, the metadata and its warnings.
"""
struct GdbContents
    lines::Vector{GdbLineRecord}
    channels::Vector{GdbChannelRecord}
    meta::GdbMeta
    meta_warnings::Vector{String}
end

function GdbContents(g::GdbFile)
    lines, channels = read_gdb_lines(g), read_gdb_channels(g)
    meta, warns = read_gdb_meta(g, read_gdb_blob_symbols(g))
    return GdbContents(lines, channels, meta, warns)
end

"""
    add_gdb_channels!(db, plans, pairs, current) -> names

Add the planned channels and position pairs to `db` and return the JuliaMag
name of each channel. In append mode a channel goes to the existing channel
with the same name (case is ignored), which keeps its own properties. A new
channel takes the display settings of its plan. The pairs name the returned
names. The current pair is set only when `db` has none.
"""
function add_gdb_channels!(db::LineDatabase, plans::Vector{GdbChannelPlan}, pairs::Vector{PositionPair},
                           current::Int)::Vector{String}
    names = String[]
    for p in plans
        new = channel_position_ci(db, p.name) == 0
        name = import_channel!(db, p.name, p.label, p.gtype.T, p.units, p.role, p.arraylen, "Geosoft database")
        if new
            c = channel(db, name)
            c.format, c.width, c.decimals = p.format, p.width, p.decimals
        end
        push!(names, name)
    end
    renamed = Dict(p.name => names[k] for (k, p) in enumerate(plans))
    for pp in pairs
        add_pair!(db, renamed[pp.x], renamed[pp.y], pp.crs)
    end
    if db.current_pair == 0 && current > 0
        x, y = renamed[pairs[current].x], renamed[pairs[current].y]
        db.current_pair = something(findfirst(p -> p.x == x && p.y == y, db.pairs), 0)
    end
    return names
end

"""
    read_gdb_into!(db, g, contents, crs, progress) -> (warnings, rows, lines)

Read the lines of the open file `g` into `db` (the body of `import_lines`).
"""
function read_gdb_into!(db::LineDatabase, g::GdbFile, contents::GdbContents, crs::String,
                        progress::Progress)::Tuple{Vector{ImportWarning},Int,Int}
    log = WarningLog()
    foreach(w -> warn!(log, 0, w), contents.meta_warnings)
    lplans = plan_gdb_lines(contents.lines, db, log)
    cplans, pairs, current = plan_gdb_channels(contents.channels, contents.meta, crs, log)
    names = add_gdb_channels!(db, cplans, pairs, current)

    h = g.header
    index(lp, cp) = lp.slot * h.chans_max + cp.slot
    total = count(g.dir[index(lp, cp) + 1].live for lp in lplans for cp in cplans)
    done = 0
    notes = [GdbValueNotes(0, 0, 0) for _ in cplans]
    bufs = GdbBuffers()
    rows_total, lines_total = 0, 0
    apps = open_appenders(db, names)
    heads = Vector{Union{Nothing,GdbBlobHeader}}(undef, length(cplans))
    for lp in lplans
        for (k, cp) in enumerate(cplans)
            heads[k] = gdb_at(lp.name, names[k]) do
                off = blob_offset(g, index(lp, cp))
                off === nothing ? nothing : gdb_channel_blob(g, off, cp)
            end
        end
        if all(isnothing, heads)
            warn!(log, 0, "line $(lp.name) has no data; skipped")
            continue
        end
        main = main_sampling(Sampling[Sampling(b.fid_start, b.fid_step) for b in heads if b !== nothing])
        rows = 0
        for (k, b) in enumerate(heads)
            b !== nothing && same_sampling(Sampling(b.fid_start, b.fid_step), main) &&
                (rows = max(rows, b.count ÷ cplans[k].arraylen))
        end
        l = start_line!(db, lp.id, lp.flight, lp.date)
        l.nrows, l.fid_start, l.fid_step = rows, main.start, main.step
        resampled, padded, absent = String[], String[], String[]
        for (k, cp) in enumerate(cplans)
            b = heads[k]
            if b === nothing
                push!(absent, names[k])
                continue
            end
            is_cancelled(progress) && throw(ImportCancelled())
            from = Sampling(b.fid_start, b.fid_step)
            gdb_at(lp.name, names[k]) do
                read_blob_bytes!(bufs.bytes, bufs.scratch, g, b, cp.gtype.size)
                gdb_append_blob!(apps[names[k]], bufs, cp.gtype, notes[k], from, main, rows, cp.arraylen)
            end
            if !same_sampling(from, main)
                push!(resampled, names[k])
            elseif b.count ÷ cp.arraylen < rows
                push!(padded, names[k])
            end
            done += 1
            report(progress, done / total)
        end
        lname = line_name(l.id)
        isempty(resampled) || warn!(log, 0, "line $lname: $(gdb_channels_text(resampled)) " *
            (length(resampled) == 1 ? "has" : "have") * " another fiducial start or step than the line " *
            "(start $(main.start), step $(main.step)); " *
            (length(resampled) == 1 ? "it was" : "they were") * " resampled onto it")
        isempty(padded) || warn!(log, 0, "line $lname: $(gdb_channels_text(padded)) " *
            (length(padded) == 1 ? "has" : "have") * " fewer rows than the line; the rest are missing")
        isempty(absent) || warn!(log, 0, "line $lname: $(gdb_channels_text(absent)) " *
            (length(absent) == 1 ? "has no data on this line; it is missing" :
                                   "have no data on this line; they are missing"))
        rows_total += rows
        lines_total += 1
    end
    close_appenders!(apps)
    lines_total == 0 && throw(GdbError("$(basename(g.path)) has no line with data to import"))

    (g.cp1252 || any(n -> n.cp1252 > 0, notes)) &&
        warn!(log, 0, "some names or text values are not valid UTF-8; they were read as Windows-1252")
    for (k, n) in enumerate(notes)
        n.clashes == 1 && warn!(log, 0, "channel $(names[k]): 1 value equals JuliaMag's missing marker and reads as missing")
        n.clashes > 1 && warn!(log, 0, "channel $(names[k]): $(n.clashes) values equal JuliaMag's missing marker " *
                                       "and read as missing")
        n.inexact == 1 && warn!(log, 0, "channel $(names[k]): 1 64-bit value cannot be stored exactly as Float64 " *
                                        "and was rounded")
        n.inexact > 1 && warn!(log, 0, "channel $(names[k]): $(n.inexact) 64-bit values cannot be stored exactly " *
                                       "as Float64 and were rounded")
    end
    return (final_warnings(log), rows_total, lines_total)
end

"""
    import_gdb(s, path; name, crs = "", mode = :new, target = "", progress = NO_PROGRESS, record = true)

Import the Geosoft database (`.gdb`) at `path` into a new database (`mode =
:new`, named `name`, by default the file name without its extension) or append
it to the database item `target` (`mode = :append`).

- Each line keeps its type, number, version, flight and date (spec 6.3a). A
  line whose name is not a number gets the next free number of its type. Group
  lines are skipped. A line id the database has already gets the next version.
- Each channel keeps its name (made safe), label, units, display settings and
  array width. Integer types JuliaMag lacks are widened; Geosoft dummies
  become missing values.
- The position pairs come from the file's current X and Y channels and its
  coordinate systems. `crs` is used for the current pair when the file stores
  no coordinate system for it, or one JuliaMag cannot use.
- A channel with another fiducial start or step than its line is resampled
  onto the line's main sampling.
- `progress` gets the fraction of blobs read and is checked for cancel once
  per blob. A cancelled import throws `ImportCancelled`.

Changed and skipped items become warnings in the result. A file that is not a
Geosoft database, fails a layout check or holds a damaged data blob throws
`GdbError`, and the import leaves no new item and no changed database behind.
The import is recorded in the history as `"import.geosoft_gdb"`, unless
`record = false` (the job that runs it records it; see `import_file`).
"""
function import_gdb(s::Session, path::String; name::AbstractString = splitext(basename(path))[1],
                    crs::AbstractString = "", mode::Symbol = :new, target::AbstractString = "",
                    progress::Progress = NO_PROGRESS, record::Bool = true)::ImportResult
    why = gdb_refusal(path)
    why === nothing || throw(GdbError(why))
    check_import_args(path, mode, target)
    args = Dict{String,Any}("path" => path, "name" => String(name), "crs" => String(crs),
                            "mode" => String(mode), "target" => String(target))
    report(progress, 0.0)
    g = open_gdb(path)
    r = try
        contents = GdbContents(g)
        import_lines(s, mode, String(name), String(target)) do db
            read_gdb_into!(db, g, contents, String(crs), progress)
        end
    finally
        close(g)
    end
    made = mode == :new && r.item !== nothing ? String[r.item.id] : String[]
    record && record!(s, "import.geosoft_gdb", args; outputs = made)
    return r
end

# ---- registration ----------------------------------------------------------

"The settings of the `.gdb` importer: those of XYZ, with its own help for `crs`."
const GDB_SETTINGS = SettingSpec[
    XYZ_SETTINGS[1:3]...,
    CRSSetting("crs", "Coordinate system";
               help = "Used for the current X and Y channels when the file stores no coordinate system for " *
                      "them, or one JuliaMag cannot use, such as a Geosoft custom system. Example: EPSG:7855."),
]

"""
Run the `.gdb` importer from settings: `name`, `crs`, `mode` (\"new\" or
\"append\"), `target`. Bad settings throw a `ToolError`. Not recorded: the job
that runs it records it (see `ImporterSpec`).
"""
function run_gdb_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult
    v = spec_values(GDB_SETTINGS, settings, "Geosoft database")
    name = v["name"]::String
    return import_gdb(s, path; name = isempty(name) ? splitext(basename(path))[1] : name,
                      crs = v["crs"]::String, mode = Symbol(v["mode"]::String),
                      target = v["target"]::String, progress, record = false)
end

register_importer!(ImporterSpec("import.geosoft_gdb", "Geosoft database", [".gdb"], ITEM_DATABASE,
                                GDB_SETTINGS, run_gdb_importer))
