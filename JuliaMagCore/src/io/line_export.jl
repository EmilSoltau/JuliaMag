# Line data export (spec 7): Geosoft XYZ and CSV. Parquet is in `parquet_export.jl`.
#
# - An export reads the committed view of the database (see `open_database`), so
#   a database that an import is appending to exports what is committed. It
#   never changes the database.
# - Rows are read in blocks with plain file reads (see `block_reader`), so memory
#   stays flat however large the database is.
# - The file is written to `path * ".tmp"` and renamed at the end. On an error
#   or a cancel the temp file is removed and `path` is not touched.
# - Progress is the fraction of rows written. Cancel is checked once per block
#   and throws `ExportCancelled`.
# - Numbers: a channel with `decimals` set (0 or more) is written with that many
#   decimals (`%.Nf`, or `%.Ne` for format `:exponential`). With `decimals == -1`
#   (ruling R3) the value is written with the shortest digits that read back as
#   the same number (as `print` finds them), so an export then import gives the
#   same data. The exponent is written out for exponents from -7 to 15, so a
#   northing is `7000100.0`, not `7.0001e6` (see `plain_decimal`).
# - Array channels become one column per value: `SPEC[0]`, `SPEC[1]`, ...
# - Whole numbers are written as they are. Missing values are `*` in XYZ and
#   empty fields in CSV.

using Printf

"Most values read per block, over all channels."
const EXPORT_BLOCK_VALUES = 1 << 20

"Most rows read per block."
const EXPORT_BLOCK_ROWS = 1 << 16

"Rows of the first line used to choose the XYZ column widths."
const WIDTH_SAMPLE_ROWS = 1000

"The full word of a line type for XYZ line headers, such as `Line` or `Tie`."
const LINE_TYPE_WORDS = Dict(LINE => "Line", TIE => "Tie", BASE => "Base", TEST => "Test",
                             TREND => "Trend", SPECIAL => "Special", RANDOM => "Random")

"Delimiters that CSV export can write, and their labels."
const CSV_DELIMITERS = [",", ";", "\t", "|"]
const CSV_DELIMITER_LABELS = ["Comma", "Semicolon", "Tab", "Bar"]

# ---- what to export --------------------------------------------------------

"The committed view of a database, and the lines and channels to export."
struct ExportPlan
    item::String
    db::LineDatabase
    lines::Vector{LineInfo}
    channels::Vector{ChannelInfo}
end

"""
Open the committed view of database `item_id` and pick the lines and channels.
`lines` is `"all"`, `"selected"` or `"current"` (the line of the cursor).
Empty `channels` means all channels. Lines with no rows are left out.
Bad settings throw a `ToolError`.
"""
function export_plan(s::Session, item_id::AbstractString, lines::AbstractString,
                     channels::AbstractVector)::ExportPlan
    lines in LINES_CHOICES || throw(ToolError("Lines must be all, selected or current, not \"$lines\"."))
    db, cursor = lock(() -> (database(s.project, item_id), s.cursor), s.lock)
    names = unique(String[String(n) for n in channels])
    unknown = filter(n -> channel_position(db, n) == 0, names)
    isempty(unknown) || throw(ToolError("Database $item_id has no channel named " *
                                        join(repr.(unknown), ", ", " or ") * "."))
    chans = isempty(names) ? copy(db.channels) : ChannelInfo[channel(db, n) for n in names]
    isempty(chans) && throw(ToolError("Database $item_id has no channels to export."))
    ls = if lines == "all"
        copy(db.lines)
    elseif lines == "selected"
        filter(l -> l.selected, db.lines)
    else
        (cursor !== nothing && cursor.item == item_id && line_position(db, cursor.line) > 0) ||
            throw(ToolError("Lines = current needs the cursor on a line of database $item_id."))
        [line(db, cursor.line)]
    end
    filter!(l -> l.nrows > 0, ls)
    isempty(ls) && throw(ToolError("Database $item_id has no $(lines == "all" ? "" : lines * " ")lines with rows to export."))
    return ExportPlan(String(item_id), db, ls, chans)
end

export_rows(p::ExportPlan)::Int = sum(l.nrows for l in p.lines; init = 0)

"The output column names: the channel names, with arrays as `NAME[0]`, `NAME[1]`, ..."
function column_names(chans::Vector{ChannelInfo})::Vector{String}
    out = String[]
    for c in chans
        c.arraylen == 1 ? push!(out, c.name) : append!(out, ("$(c.name)[$k]" for k in 0:(c.arraylen - 1)))
    end
    return out
end

"Rows per block, so a block holds about `EXPORT_BLOCK_VALUES` values."
block_rows(chans::Vector{ChannelInfo}) =
    clamp(EXPORT_BLOCK_VALUES ÷ max(1, sum(c.arraylen for c in chans; init = 0)), 1, EXPORT_BLOCK_ROWS)

"Open a block reader for each channel. Closes those already open on an error."
function open_readers(p::ExportPlan)::Vector{BlockReader}
    out = BlockReader[]
    try
        foreach(c -> push!(out, block_reader(p.db, c.name)), p.channels)
    catch
        foreach(close, out)
        rethrow()
    end
    return out
end

# ---- progress --------------------------------------------------------------

"Progress by rows written, and a check for cancel."
mutable struct RowProgress
    progress::Progress
    total::Int
    done::Int
end

RowProgress(progress::Progress, total::Int) = RowProgress(progress, total, 0)

"Throw `ExportCancelled` when the user asked to stop."
check_export_cancel(t::RowProgress) = (is_cancelled(t.progress) && throw(ExportCancelled()); nothing)

function rows_done!(t::RowProgress, n::Int)
    t.done += n
    report(t.progress, t.total == 0 ? 1.0 : min(t.done / t.total, 1.0))
    check_export_cancel(t)
    return nothing
end

"""
    each_block(f, plan, readers, ticker, nrows)

Call `f(line, rows, values)` for each block of at most `nrows` rows of each
line, where `values[k]` is the block of channel `k` (see `read_block`).
Reports progress and checks for cancel after each block.
"""
function each_block(f::F, p::ExportPlan, readers::Vector{BlockReader}, t::RowProgress, nrows::Int) where {F}
    vals = Vector{AbstractArray}(undef, length(readers))
    for l in p.lines
        start = 1
        while start <= l.nrows
            rows = start:min(start + nrows - 1, l.nrows)
            for k in eachindex(readers)
                vals[k] = read_block(readers[k], l, rows)
            end
            f(l, rows, vals)
            rows_done!(t, length(rows))
            start = last(rows) + 1
        end
    end
    return nothing
end

# ---- the temp file ---------------------------------------------------------

"""
Call `f(io)` to write `path * ".tmp"`, then move it to `path`.
On any error the temp file is removed and the error is thrown again.
"""
function write_via_temp(f::F, path::String) where {F}
    isdir(path) && throw(ToolError("$path is a folder. Give the name of a file to export to."))
    tmp = path * ".tmp"
    try
        open(f, tmp, "w")
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return nothing
end

# ---- values as text --------------------------------------------------------

"How to write the values of one channel."
struct ValueFormat
    "A Printf format when `decimals` is set; `nothing` for the shortest exact form."
    fmt::Union{Nothing,Printf.Format}
    "The decimal mark, `.` or `,`."
    decimal::UInt8
end

function ValueFormat(c::ChannelInfo, decimal::Char)
    fmt = nothing
    if c.eltype <: AbstractFloat && c.decimals >= 0
        fmt = Printf.Format(c.format == :exponential ? "%.$(c.decimals)e" : "%.$(c.decimals)f")
    end
    return ValueFormat(fmt, UInt8(decimal))
end

"""
    value_text!(buf, x, f) -> Bool

Write the text of `x` to `buf`. Returns false, and writes nothing, for a missing value.
"""
function value_text!(buf::IOBuffer, x::AbstractFloat, f::ValueFormat)::Bool
    isnan(x) && return false
    fmt = f.fmt
    fmt === nothing ? print(buf, plain_decimal(string(x))) : Printf.format(buf, fmt, x)
    return true
end

"""
    plain_decimal(t) -> String

The shortest text of a number (as `print` writes it) without the exponent when
the exponent is from -7 to 15, so `7.0001e6` becomes `7000100.0` and `1.0e-5`
becomes `0.00001`. The digits do not change, so the text reads back as the same
number. Other text is returned as it is.
"""
function plain_decimal(t::String)::String
    m = match(r"^(-?)(\d+)\.(\d+)e(-?\d+)$", t)
    m === nothing && return t
    sign, whole, frac, ex = String(something(m[1])), String(something(m[2])), String(something(m[3])),
                            parse(Int, something(m[4]))
    -7 <= ex <= 15 || return t
    digits = rstrip(whole * frac, '0')
    isempty(digits) && return t
    point = length(whole) + ex          # digits before the decimal point
    if point >= length(digits)
        return sign * digits * "0"^(point - length(digits)) * ".0"
    elseif point <= 0
        return sign * "0." * "0"^(-point) * digits
    end
    return sign * digits[1:point] * "." * digits[(point + 1):end]
end

function value_text!(buf::IOBuffer, x::Integer, ::ValueFormat)::Bool
    ismissingvalue(x) && return false
    print(buf, x)
    return true
end

function value_text!(buf::IOBuffer, x::AbstractString, ::ValueFormat)::Bool
    isempty(x) && return false
    print(buf, x)
    return true
end

"The text of a value as bytes, or `nothing` when it is missing. Uses the decimal mark of `f`."
function cell_bytes(buf::IOBuffer, x, f::ValueFormat)::Union{Nothing,Vector{UInt8}}
    value_text!(buf, x, f) || return nothing
    b = take!(buf)
    if f.decimal != UInt8('.') && !(x isa AbstractString)
        replace!(b, UInt8('.') => f.decimal)
    end
    return b
end

"Value `i` (and element `e` of an array channel) of a block."
@inline cell(v::AbstractVector, ::Int, i::Int) = v[i]
@inline cell(v::AbstractMatrix, e::Int, i::Int) = v[e, i]

# ---- Geosoft XYZ -----------------------------------------------------------

"""
The XYZ text of a cell, or `*` when it is missing. Blanks in text would split
the field, so they become `_`; `blanks[]` counts the values changed.
"""
function xyz_cell(buf::IOBuffer, x, f::ValueFormat, blanks::Ref{Int})::String
    b = cell_bytes(buf, x, f)
    b === nothing && return "*"
    t = String(b)
    if x isa AbstractString && any(isspace, t)
        blanks[] += 1
        t = map(c -> isspace(c) ? '_' : c, t)
    end
    return t
end

"`yyyy-mm-dd` as `yyyy/mm/dd`, as Geosoft writes dates. Other text is kept."
function xyz_date(d::String)::String
    m = match(r"^(\d{4})-(\d{2})-(\d{2})$", d)
    return m === nothing ? d : string(m[1], "/", m[2], "/", m[3])
end

"A line header such as `Line 1001`, `Tie 2001` or `Line 1001.1`."
function xyz_line_header(id::LineId)::String
    word = LINE_TYPE_WORDS[id.type]
    return id.version > 0 ? "$word $(id.number).$(id.version)" : "$word $(id.number)"
end

"Call `f(column, value)` for each output column of row `i` of a block, in order."
function each_cell(f::F, chans::Vector{ChannelInfo}, vals::Vector{AbstractArray}, i::Int) where {F}
    col = 0
    for (k, c) in enumerate(chans)
        for e in 1:c.arraylen
            col += 1
            f(col, cell(vals[k], e, i))
        end
    end
    return nothing
end

"""
The width of each XYZ column: the longest of the name and the values in the
first rows of the first line. Longer values later still get a blank before them.
"""
function xyz_widths(p::ExportPlan, readers::Vector{BlockReader}, fmts::Vector{ValueFormat},
                    names::Vector{String})::Vector{Int}
    w = Int[textwidth(n) for n in names]
    l = p.lines[1]
    rows = 1:min(WIDTH_SAMPLE_ROWS, l.nrows)
    vals = AbstractArray[read_block(r, l, rows) for r in readers]
    buf = IOBuffer()
    blanks = Ref(0)
    kfor = channel_of_column(p.channels)
    for i in eachindex(rows)
        each_cell(p.channels, vals, i) do col, x
            w[col] = max(w[col], textwidth(xyz_cell(buf, x, fmts[kfor[col]], blanks)))
        end
    end
    return w
end

"For each output column, the index of its channel."
channel_of_column(chans::Vector{ChannelInfo})::Vector{Int} =
    reduce(vcat, [fill(k, c.arraylen) for (k, c) in enumerate(chans)]; init = Int[])

function write_padded(io::IO, t::String, width::Int)
    for _ in 1:(width - textwidth(t))
        write(io, ' ')
    end
    write(io, t)
    return nothing
end

function write_xyz(io::IO, p::ExportPlan, t::RowProgress)::Vector{String}
    names = column_names(p.channels)
    fmts = ValueFormat[ValueFormat(c, '.') for c in p.channels]
    kfor = channel_of_column(p.channels)
    blanks = Ref(0)
    readers = open_readers(p)
    try
        widths = xyz_widths(p, readers, fmts, names)
        # The header. "/ " and the two blanks that start each row keep the columns in line.
        write(io, "/ ")
        for (col, n) in enumerate(names)
            col > 1 && write(io, ' ')
            write_padded(io, n, widths[col])
        end
        write(io, '\n')
        # The last flight and date written. The importer starts with flight 0 and no date.
        flight, date = Ref(0), Ref("")
        current = Ref{Union{Nothing,LineInfo}}(nothing)
        buf = IOBuffer()
        each_block(p, readers, t, block_rows(p.channels)) do l, rows, vals
            if l !== current[]
                current[] = l
                # Flight and date apply to the lines after them, so write them when they change.
                l.flight != flight[] && println(io, "//Flight ", l.flight)
                l.date != date[] && println(io, "//Date ", xyz_date(l.date))
                flight[], date[] = l.flight, l.date
                println(io, xyz_line_header(l.id))
            end
            for i in eachindex(rows)
                write(io, "  ")
                each_cell(p.channels, vals, i) do col, x
                    col > 1 && write(io, ' ')
                    write_padded(io, xyz_cell(buf, x, fmts[kfor[col]], blanks), widths[col])
                end
                write(io, '\n')
            end
        end
    finally
        foreach(close, readers)
    end
    notes = String[]
    blanks[] > 0 && push!(notes, "$(blanks[]) text values had blanks in them; each blank was written as _.")
    return notes
end

# ---- CSV -------------------------------------------------------------------

"True when a CSV field must be quoted: it holds the delimiter, a quote, a line end, or blanks at an end."
function needs_quotes(b::Vector{UInt8}, delim::UInt8)::Bool
    isempty(b) && return false
    (b[1] == 0x20 || b[1] == 0x09 || b[end] == 0x20 || b[end] == 0x09) && return true
    return any(x -> x == delim || x == UInt8('"') || x == UInt8('\n') || x == UInt8('\r'), b)
end

"Write a CSV field, quoted when needed, with `\"` inside written as `\"\"`."
function write_csv_field(io::IO, b::Vector{UInt8}, delim::UInt8)
    if needs_quotes(b, delim)
        write(io, '"')
        for x in b
            x == UInt8('"') && write(io, '"')
            write(io, x)
        end
        write(io, '"')
    else
        write(io, b)
    end
    return nothing
end

function write_csv(io::IO, p::ExportPlan, t::RowProgress, delimiter::Char, decimal::Char)::Vector{String}
    d = UInt8(delimiter)
    fmts = ValueFormat[ValueFormat(c, decimal) for c in p.channels]
    kfor = channel_of_column(p.channels)
    write(io, "LINE")
    for n in column_names(p.channels)
        write(io, d)
        write_csv_field(io, Vector{UInt8}(n), d)
    end
    write(io, '\n')
    readers = open_readers(p)
    try
        buf = IOBuffer()
        current = Ref{Union{Nothing,LineInfo}}(nothing)
        name = Ref(UInt8[])
        each_block(p, readers, t, block_rows(p.channels)) do l, rows, vals
            if l !== current[]
                current[] = l
                name[] = Vector{UInt8}(line_name(l.id))
            end
            for i in eachindex(rows)
                write(io, name[])
                each_cell(p.channels, vals, i) do col, x
                    write(io, d)
                    b = cell_bytes(buf, x, fmts[kfor[col]])
                    b === nothing || write_csv_field(io, b, d)
                end
                write(io, '\n')
            end
        end
    finally
        foreach(close, readers)
    end
    return String[]
end

# ---- the export functions --------------------------------------------------

"""
Run one export: pick the lines and channels, write the file through a temp
file, and record it in the history unless `record` is false.
`write_body(io, plan, ticker)` writes the file and returns notes for the report.
"""
function run_export(write_body::F, s::Session, command::String, item_id::AbstractString, path::AbstractString,
                    lines::AbstractString, channels::AbstractVector, progress::Progress, record::Bool,
                    extra::Dict{String,Any} = Dict{String,Any}())::ExportResult where {F}
    report(progress, 0.0)
    p = export_plan(s, item_id, lines, channels)
    t = RowProgress(progress, export_rows(p))
    check_export_cancel(t)
    notes = String[]
    write_via_temp(String(path)) do io
        append!(notes, write_body(io, p, t))
    end
    report(progress, 1.0)
    if record
        args = merge(Dict{String,Any}("item" => String(item_id), "path" => String(path), "lines" => String(lines),
                                      "channels" => String[String(c) for c in channels]), extra)
        record!(s, command, args)
    end
    return ExportResult(String(path), t.total, length(p.lines), notes)
end

"""
    export_xyz(s, item_id, path; lines = "all", channels = String[], progress = NO_PROGRESS) -> ExportResult

Write database `item_id` to a Geosoft XYZ file (spec 6.3, 7):

- a `/` header with the column names, right-aligned over the columns;
- `//Flight n` and `//Date yyyy/mm/dd` before the first line they apply to, when
  they are set and when they change;
- a line header with the full type word, such as `Line 1001`, `Tie 2001` or
  `Line 1001.1` for version 1;
- the rows, with `*` for missing values.

`lines` is `"all"`, `"selected"` or `"current"`; empty `channels` means all.
Array channels become `NAME[0] NAME[1] ...` columns. Text is written as it is,
except that blanks become `_`, since a blank splits XYZ fields.
Recorded as `"export.geosoft_xyz"`; `record = false` skips that (see `export_file`).
Bad settings throw a `ToolError`; a cancel throws `ExportCancelled`. Either way
`path` is not touched.
"""
function export_xyz(s::Session, item_id::AbstractString, path::AbstractString; lines::AbstractString = "all",
                    channels::AbstractVector = String[], progress::Progress = NO_PROGRESS,
                    record::Bool = true)::ExportResult
    return run_export(write_xyz, s, "export.geosoft_xyz", item_id, path, lines, channels, progress, record)
end

"Check the delimiter and the decimal mark of a CSV export. Throws a `ToolError`."
function check_csv_marks(delimiter::Char, decimal::Char)
    string(delimiter) in CSV_DELIMITERS || throw(ToolError(
        "The delimiter must be a comma, a semicolon, a tab or a bar, not $(repr(delimiter))."))
    decimal in ('.', ',') || throw(ToolError("The decimal mark must be a point or a comma, not $(repr(decimal))."))
    (decimal == ',' && delimiter == ',') && throw(ToolError(
        "The comma cannot be both the delimiter and the decimal mark. " *
        "Choose another delimiter, such as a semicolon, or a point as decimal mark."))
    return nothing
end

"""
    export_csv(s, item_id, path; lines = "all", channels = String[], delimiter = ',', decimal = '.',
               progress = NO_PROGRESS) -> ExportResult

Write database `item_id` to a CSV file (spec 7): a heading row, then one row per
sample. The first column, `LINE`, holds the line name, such as `L1001` or
`T2001.1`. Missing values are empty fields. Fields that hold the delimiter,
a quote, a line end or blanks at an end are quoted, with `"` written as `""`.

- `delimiter`: `','`, `';'`, `'\\t'` or `'|'`.
- `decimal`: the decimal mark, `'.'` or `','` (ruling R10). A comma cannot be
  both the delimiter and the decimal mark.

The other settings, the history and errors are as for `export_xyz`.
Recorded as `"export.csv"`.
"""
function export_csv(s::Session, item_id::AbstractString, path::AbstractString; lines::AbstractString = "all",
                    channels::AbstractVector = String[], delimiter::Char = ',', decimal::Char = '.',
                    progress::Progress = NO_PROGRESS, record::Bool = true)::ExportResult
    check_csv_marks(delimiter, decimal)
    extra = Dict{String,Any}("delimiter" => string(delimiter), "decimal" => string(decimal))
    return run_export(s, "export.csv", item_id, path, lines, channels, progress, record, extra) do io, p, t
        write_csv(io, p, t, delimiter, decimal)
    end
end

# ---- registration ----------------------------------------------------------

const LINE_EXPORT_SETTINGS = SettingSpec[
    LinesSetting("lines", "Lines"; help = "all, selected or current (the line of the cursor)."),
    ChannelListSetting("channels", "Channels"; help = "The channels to export. Leave empty to export all channels."),
]

const CSV_EXPORT_SETTINGS = SettingSpec[
    LINE_EXPORT_SETTINGS...,
    ChoiceSetting("delimiter", "Delimiter", CSV_DELIMITERS; labels = CSV_DELIMITER_LABELS,
                  help = "The character between the fields."),
    ChoiceSetting("decimal", "Decimal mark", [".", ","]; labels = ["Point", "Comma"],
                  help = "A comma needs another delimiter than the comma."),
]

"""
Run the XYZ exporter from settings: `lines`, `channels`. Missing settings take
their defaults. Bad settings throw a `ToolError`, so the job fails with a message
the user can read. Not recorded: the job that runs it records it.
"""
function run_xyz_exporter(s::Session, item_id::String, path::String, settings::AbstractDict,
                          progress::Progress)::ExportResult
    v = importer_values(LINE_EXPORT_SETTINGS, settings, "Geosoft XYZ export")
    return export_xyz(s, item_id, path; lines = v["lines"]::String, channels = v["channels"]::Vector{String},
                      progress, record = false)
end

"Run the CSV exporter from settings: `lines`, `channels`, `delimiter`, `decimal`. As `run_xyz_exporter`."
function run_csv_exporter(s::Session, item_id::String, path::String, settings::AbstractDict,
                          progress::Progress)::ExportResult
    v = importer_values(CSV_EXPORT_SETTINGS, settings, "CSV export")
    return export_csv(s, item_id, path; lines = v["lines"]::String, channels = v["channels"]::Vector{String},
                      delimiter = only(v["delimiter"]::String), decimal = only(v["decimal"]::String),
                      progress, record = false)
end

register_exporter!(ExporterSpec("export.geosoft_xyz", "Geosoft XYZ", ".xyz", ITEM_DATABASE,
                                LINE_EXPORT_SETTINGS, run_xyz_exporter))
register_exporter!(ExporterSpec("export.csv", "CSV", ".csv", ITEM_DATABASE, CSV_EXPORT_SETTINGS, run_csv_exporter))
