# CSV and other delimited or fixed-width text import (spec 6.4).
#
# A `CsvLayout` says how to read a file: the delimiter or the column widths, the
# heading, units and first data rows, and the role, name, type and units of each
# column. It follows the three steps of the import dialog (Oasis ASCII wizard):
# file layout, column roles, lines and coordinates.
#
# - `sniff_csv` guesses a layout from the first rows; the user then changes it.
# - `preview_rows` splits the first rows of a file the way a layout says.
# - `import_csv` reads the whole file in a stream (see `eachfileline`).
#   Unquoted numbers are read by byte index, with no memory allocated per value.
#   Quoted fields and text columns allocate.
# - Layouts are saved as named templates in `templates/<name>.json`.
#
# Rows are split into fields in `csv_fields.jl`. Layout JSON and templates are
# in `csv_templates.jl`.
#
# How the import dialog passes a layout: it calls `sniff_csv` and `preview_rows`
# while the user edits the layout. To run the import as a job it calls
# `import_file(s, path; layout = layout_json(layout), mode, name, target)`.
# The importer setting `layout` holds the full layout as JSON text, so the job
# records the exact layout and a script can run it again. The setting `template`
# names a saved template instead. With neither, the importer uses `sniff_csv`.
# Code that does not need a job calls `import_csv(s, path, layout)` directly.
#
# Staging, commit, append with rollback and undo, warnings and progress are
# shared with the XYZ importer (see `line_import.jl`).
#
# How rows become lines:
# - With a line column (`line_column`), a new line starts when its value names a
#   different line. `L1001`, `T2001`, `Line 1001` and `1001` (type LINE) are line
#   names, with an optional version such as `L1001.2`. A value that is not a line
#   name is a warning, and the row goes to the current line.
# - Without a line column, the whole file is one line, D0 (as in XYZ).

"""
    CsvColumn(name, role, eltype, units)
    CsvColumn(name; role = :data, eltype = Float64, units = "")

One column of a text file.

- `role`: `:skip` (not imported), `:data`, `:line` (the line names),
  `:fiducial` (a data channel that also sets the fiducial start and step of
  each line) or `:array` (see below).
- `eltype`: `Float64` for numbers, `String` for text.
- Columns next to each other with role `:array` and the same base name with an
  index, such as `SPEC[0]`, `SPEC[1]` or `SPEC_0`, `SPEC_1`, become one array
  channel named after the base (`SPEC`). The values go in column order.
"""
struct CsvColumn
    name::String
    role::Symbol
    eltype::DataType
    units::String
end

CsvColumn(name::AbstractString; role::Symbol = :data, eltype::DataType = Float64, units::AbstractString = "") =
    CsvColumn(String(name), role, eltype, String(units))

"""
    CsvLayout(; delimiter = ',', fixed_widths = Int[], heading_row = 0, units_row = 0,
              first_data_row = 1, columns = CsvColumn[], line_column = "", x = "", y = "", crs = "",
              decimal = '.')
    CsvLayout(layout; changes...)

How to read a text file of line data.

- `delimiter` splits the fields. `' '` means runs of spaces and tabs.
  Fields may be quoted with `"`; a quote inside is written `""`.
- `fixed_widths`: the width of each column in characters. Empty means delimited.
  Spaces around a value are removed. Text past the last column is ignored.
- `heading_row`, `units_row`: file line numbers (from 1), 0 for none. Only
  `sniff_csv` and `preview_rows` read them; `import_csv` takes the names and
  units from `columns`.
- `first_data_row`: the file line number of the first row of data.
- `columns`: one per column of the file.
- `line_column`: the name of the column with role `:line`, or `""` for one line per file.
- `x`, `y`: the names of the columns of the position pair, or `""` for none.
- `crs`: the coordinate system of that pair, such as `"EPSG:7855"`.
- `decimal`: the decimal mark of numbers, `'.'` or `','` (as in `1,5`).
  A comma cannot be both the delimiter and the decimal mark.

The second form copies a layout with some fields changed.
"""
struct CsvLayout
    delimiter::Char
    fixed_widths::Vector{Int}
    heading_row::Int
    units_row::Int
    first_data_row::Int
    columns::Vector{CsvColumn}
    line_column::String
    x::String
    y::String
    crs::String
    decimal::Char
end

CsvLayout(; delimiter::Char = ',', fixed_widths::AbstractVector{<:Integer} = Int[], heading_row::Integer = 0,
          units_row::Integer = 0, first_data_row::Integer = 1, columns::AbstractVector{CsvColumn} = CsvColumn[],
          line_column::AbstractString = "", x::AbstractString = "", y::AbstractString = "",
          crs::AbstractString = "", decimal::Char = '.') =
    CsvLayout(delimiter, collect(Int, fixed_widths), heading_row, units_row, first_data_row,
              collect(CsvColumn, columns), String(line_column), String(x), String(y), String(crs), decimal)

CsvLayout(l::CsvLayout; kwargs...) =
    CsvLayout(; delimiter = l.delimiter, fixed_widths = l.fixed_widths, heading_row = l.heading_row,
              units_row = l.units_row, first_data_row = l.first_data_row, columns = l.columns,
              line_column = l.line_column, x = l.x, y = l.y, crs = l.crs, decimal = l.decimal,
              kwargs...)

Base.:(==)(a::CsvColumn, b::CsvColumn) =
    a.name == b.name && a.role == b.role && a.eltype === b.eltype && a.units == b.units
Base.hash(c::CsvColumn, h::UInt) = hash((c.name, c.role, c.eltype, c.units), hash(:CsvColumn, h))
Base.:(==)(a::CsvLayout, b::CsvLayout) = all(getfield(a, f) == getfield(b, f) for f in fieldnames(CsvLayout))
Base.hash(l::CsvLayout, h::UInt) = hash(Tuple(getfield(l, f) for f in fieldnames(CsvLayout)), hash(:CsvLayout, h))

const CSV_ROLES = (:skip, :data, :line, :fiducial, :array)

"A field splitter for a layout, with room for `cap` fields."
FieldSplitter(layout::CsvLayout, cap::Int) =
    FieldSplitter(layout.delimiter, layout.decimal, layout.fixed_widths, cap)

# ---- the first lines of a file ---------------------------------------------

struct EnoughLines <: Exception end

"The first `n` lines of a file, without line ends and byte order mark. Reads only what it needs."
function first_lines(path::AbstractString, n::Int)::Vector{String}
    out = String[]
    n <= 0 && return out
    try
        eachfileline(path; chunk = 1 << 16) do _, line, _
            push!(out, String(line))
            length(out) >= n && throw(EnoughLines())
        end
    catch e
        e isa EnoughLines || rethrow()
    end
    return out
end

# ---- checking a layout -----------------------------------------------------

"Columns grouped into channels: the file columns of each channel, in order."
struct ChannelPlan
    name::String          # name in the layout (the base name for an array)
    cols::Vector{Int}
    eltype::DataType
    units::String
    role::Symbol          # :data, :fiducial or :array
end

"The base name of an array column: `SPEC` for `SPEC[3]` or `SPEC_3`; the name itself otherwise."
function array_base(name::AbstractString)::String
    m = match(r"^(.*?)(?:\[\d+\]|_\d+)$", name)
    return m === nothing || isempty(something(m[1], "")) ? String(name) : String(something(m[1]))
end

"""
Check a layout. Returns the channel plans and the index of the line column (0 for none).
Throws a `ToolError` with every problem found, as plain sentences.
"""
function plan_layout(l::CsvLayout)::Tuple{Vector{ChannelPlan},Int}
    problems = String[]
    d = l.delimiter
    if isempty(l.fixed_widths)
        (isascii(d) && !(d in ('"', '\r', '\n'))) ||
            push!(problems, "The delimiter must be one plain character other than a quote or a line end, not $(repr(d)).")
    else
        all(>(0), l.fixed_widths) || push!(problems, "Every fixed column width must be at least 1.")
        length(l.fixed_widths) == length(l.columns) || push!(problems,
            "There are $(length(l.fixed_widths)) fixed column widths for $(length(l.columns)) columns; they must match.")
    end
    if !(l.decimal in ('.', ','))
        push!(problems, "The decimal mark must be a point or a comma, not $(repr(l.decimal)).")
    elseif l.decimal == ',' && d == ',' && isempty(l.fixed_widths)
        push!(problems, "The comma cannot be both the delimiter and the decimal mark. " *
                        "Choose another delimiter, such as a semicolon, or a point as decimal mark.")
    end
    isempty(l.columns) && push!(problems, "The layout has no columns.")
    (l.heading_row >= 0 && l.units_row >= 0) || push!(problems, "The heading row and units row cannot be below 0.")
    l.first_data_row >= 1 || push!(problems, "The first data row must be 1 or more.")
    max(l.heading_row, l.units_row) < l.first_data_row ||
        push!(problems, "The first data row must come after the heading row and the units row.")
    names = [c.name for c in l.columns]
    for c in l.columns
        c.role in CSV_ROLES || push!(problems, "Column $(c.name) has the role $(c.role); it must be one of: " *
                                               join(CSV_ROLES, ", ") * ".")
        c.eltype in (Float64, String) || push!(problems, "Column $(c.name) has the type $(c.eltype); it must be Float64 or String.")
        c.role in (:fiducial, :array) && c.eltype !== Float64 &&
            push!(problems, "Column $(c.name) has the role $(c.role), so it must hold numbers (Float64).")
    end
    count(c -> c.role == :fiducial, l.columns) <= 1 || push!(problems, "Only one column can have the role fiducial.")
    # The line column.
    line_cols = findall(c -> c.role == :line, l.columns)
    line_col = 0
    if isempty(l.line_column)
        isempty(line_cols) || push!(problems, "Column $(l.columns[line_cols[1]].name) has the role line, " *
                                              "but the layout has no line column. Set the line column to its name, or change its role.")
    else
        k = findfirst(==(l.line_column), names)
        if k === nothing
            push!(problems, "The line column $(l.line_column) is not one of the columns.")
        elseif l.columns[k].role != :line
            push!(problems, "The line column $(l.line_column) must have the role line.")
        else
            line_col = k
        end
        length(line_cols) <= 1 || push!(problems, "Only one column can have the role line.")
    end
    # Channels.
    plans = ChannelPlan[]
    k = 1
    while k <= length(l.columns)
        c = l.columns[k]
        if c.role == :array
            base = array_base(c.name)
            m = k
            while m < length(l.columns) && l.columns[m + 1].role == :array && array_base(l.columns[m + 1].name) == base
                m += 1
            end
            push!(plans, ChannelPlan(base, collect(k:m), Float64, c.units, :array))
            k = m + 1
            continue
        end
        c.role in (:data, :fiducial) && push!(plans, ChannelPlan(c.name, [k], c.eltype, c.units, c.role))
        k += 1
    end
    # The position pair.
    if isempty(l.x) != isempty(l.y)
        push!(problems, "Set both the x and the y column, or neither.")
    else
        for (what, n) in (("x", l.x), ("y", l.y))
            isempty(n) && continue
            p = findfirst(p -> p.role in (:data, :fiducial) && p.name == n, plans)
            if p === nothing
                push!(problems, "The $what column $n is not an imported column.")
            elseif plans[p].eltype !== Float64
                push!(problems, "The $what column $n must hold numbers (Float64).")
            end
        end
    end
    isempty(plans) && !isempty(l.columns) && push!(problems, "The layout imports no columns.")
    isempty(problems) || throw(ToolError(join(problems, " ")))
    return plans, line_col
end

# ---- sniffing --------------------------------------------------------------

"Most lines `sniff_csv` reads."
const SNIFF_MAX_LINES = 2000

const LINE_COLUMN_NAMES = Set(["LINE", "LINES", "LINE_NO", "LINENO", "LINE_NUMBER", "LINENUMBER",
                               "LINE_ID", "LINEID", "LINE_NAME", "LINENAME"])
const FIDUCIAL_NAMES = Set(["FIDUCIAL", "FID"])

ismissingtext(t::AbstractString) = (u = strip(t); isempty(u) || u == "*")

"The most common value and how often it comes, for counts above 0."
function most_common(counts::Vector{Int})::Tuple{Int,Int}
    best, times = 0, 0
    for c in unique(counts)
        n = count(==(c), counts)
        (n > times || (n == times && c > best)) && ((best, times) = (c, n))
    end
    return best, times
end

"""
Guess the delimiter: the one that splits most lines into the same number (2 or more)
of fields. A semicolon or a tab that does this for as many lines as a comma wins
over the comma, since then the commas are most likely decimal commas.
"""
function guess_delimiter(lines::Vector{String})::Char
    body = filter(!isblankline, lines)
    scores = Dict{Char,Tuple{Int,Int}}()
    best, score = ',', (0, 0)
    for d in (',', ';', '\t', '|', ' ')
        sp = FieldSplitter(CsvLayout(; delimiter = d), 64)
        n, times = most_common([length(split_texts(sp, t)) for t in body])
        n >= 2 || continue
        scores[d] = (times, n)
        # Most lines first; then the most fields. Earlier delimiters win a tie.
        (times, n) > score && ((best, score) = (d, (times, n)))
    end
    if best == ','
        for d in (';', '\t')
            haskey(scores, d) && scores[d][1] >= score[1] && return d
        end
    end
    return best
end

const COMMA_NUMBER_TEXT = r"^[-+]?\d+,\d+(?:[eE][-+]?\d+)?$"

"""
Guess the decimal mark. With a semicolon or a tab as delimiter, fields such as
`1,5` and no number with a point mean a decimal comma. Otherwise a point.
"""
function guess_decimal(fields::Vector{Vector{String}}, delimiter::Char)::Char
    delimiter in (';', '\t') || return '.'
    commas, points = 0, 0
    for f in fields, t in f
        u = strip(t)
        occursin(COMMA_NUMBER_TEXT, u) && (commas += 1)
        occursin('.', u) && isnumbertext(u) && (points += 1)
    end
    return commas > 0 && points == 0 ? ',' : '.'
end

"""
    sniff_csv(path; rows = 20, delimiter = nothing, fixed_widths = Int[]) -> CsvLayout

Guess the layout of a text file from its first lines:

- the delimiter, from `, ; tab |`, or runs of spaces (`' '`), unless `delimiter`
  or `fixed_widths` is given;
- the decimal mark: a comma when the delimiter is a semicolon or a tab, fields look
  like `1,5`, and no number has a point; else a point;
- the heading row (names, no numbers) and a units row right after it;
- the first data row: the first row that has the usual number of fields and a number;
- the type of each column from up to `rows` data rows: a column is text (`String`)
  when it has a value that is not a number, empty or `*`;
- roles by name: a line column (`LINE`, `LINE_NO`, ...), a fiducial column
  (`FIDUCIAL`, `FID`), and arrays (`SPEC[0]`, `SPEC[1]`, ...);
- the x and y columns by name (`X`/`EASTING`, `Y`/`NORTHING`, else `LON`/`LAT`
  with crs `EPSG:4326`), as the XYZ importer does.

Throws a `ToolError` when the file is missing or has no rows.
"""
function sniff_csv(path::AbstractString; rows::Integer = 20, delimiter::Union{Nothing,Char} = nothing,
                   fixed_widths::AbstractVector{<:Integer} = Int[])::CsvLayout
    isfile(path) || throw(ToolError("There is no file at $path."))
    lines = first_lines(path, SNIFF_MAX_LINES)
    all(isblankline, lines) && throw(ToolError("The file $path has no rows."))
    d = isempty(fixed_widths) ? something(delimiter, guess_delimiter(lines)) : ','
    sp = FieldSplitter(CsvLayout(; delimiter = d, fixed_widths), 64)
    fields = [isblankline(t) ? String[] : split_texts(sp, t) for t in lines]
    decimal = isempty(fixed_widths) ? guess_decimal(fields, d) : '.'
    width = isempty(fixed_widths) ? most_common([length(f) for f in fields if !isempty(f)])[1] : length(fixed_widths)
    fits(f) = length(f) == width || (!isempty(fixed_widths) && !isempty(f))
    hasnumber(f) = any(t -> isnumbertext(t, decimal), f)
    first_data = something(findfirst(f -> fits(f) && hasnumber(f), fields), 0)
    heading, units = 0, 0
    if first_data == 0
        # No numbers at all: the first row is the heading, the rest is text.
        heading = something(findfirst(!isempty, fields), 0)
        first_data = heading + 1
    else
        before = [k for k in 1:(first_data - 1) if fits(fields[k]) && !hasnumber(fields[k])]
        if !isempty(before)
            heading = before[1]
            heading + 1 in before && (units = heading + 1)
        end
    end
    pad(f) = [k <= length(f) ? strip(f[k]) : "" for k in 1:width]
    names = heading > 0 ? pad(fields[heading]) : fill("", width)
    names = [isempty(n) ? "C$k" : String(n) for (k, n) in enumerate(names)]
    unit_names = units > 0 ? String.(pad(fields[units])) : fill("", width)
    istext = falses(width)
    seen = 0
    for k in first_data:length(fields)
        seen >= rows && break
        f = fields[k]
        fits(f) || continue
        seen += 1
        for (c, t) in enumerate(pad(f))
            ismissingtext(t) || isnumbertext(t, decimal) || (istext[c] = true)
        end
    end
    types = DataType[istext[c] ? String : Float64 for c in 1:width]
    roles = sniff_roles(names, types)
    line_column = something(findfirst(==(:line), roles), 0)
    columns = [CsvColumn(names[c], roles[c], types[c], unit_names[c]) for c in 1:width]
    x, y, crs = sniff_pair(names, roles, types)
    return CsvLayout(; delimiter = d, fixed_widths, heading_row = heading, units_row = units,
                     first_data_row = max(first_data, 1), columns,
                     line_column = line_column == 0 ? "" : names[line_column], x, y, crs, decimal)
end

function sniff_roles(names::Vector{String}, types::Vector{DataType})::Vector{Symbol}
    roles = fill(:data, length(names))
    k = findfirst(n -> uppercase(n) in LINE_COLUMN_NAMES, names)
    k === nothing || (roles[k] = :line)
    k = findfirst(c -> roles[c] == :data && types[c] === Float64 && uppercase(names[c]) in FIDUCIAL_NAMES,
                  eachindex(names))
    k === nothing || (roles[k] = :fiducial)
    # Arrays: two or more number columns in a row named like SPEC[0], SPEC[1].
    k = 1
    while k <= length(names)
        bracket(c) = roles[c] == :data && types[c] === Float64 && occursin(r"^.+\[\d+\]$", names[c])
        if bracket(k)
            base = array_base(names[k])
            m = k
            while m < length(names) && bracket(m + 1) && array_base(names[m + 1]) == base
                m += 1
            end
            m > k && (roles[k:m] .= :array)
            k = m + 1
        else
            k += 1
        end
    end
    return roles
end

function sniff_pair(names::Vector{String}, roles::Vector{Symbol}, types::Vector{DataType})
    usable = [roles[c] in (:data, :fiducial) && types[c] === Float64 for c in eachindex(names)]
    pick(r) = (k = findfirst(c -> usable[c] && name_role(names[c]) == r, eachindex(names)); k === nothing ? "" : names[k])
    x, y = pick(ROLE_X), pick(ROLE_Y)
    !isempty(x) && !isempty(y) && return x, y, ""
    x, y = pick(ROLE_LON), pick(ROLE_LAT)
    !isempty(x) && !isempty(y) && return x, y, "EPSG:4326"
    return "", "", ""
end

"""
    preview_rows(path, layout; rows = 20) -> Vector{Vector{String}}

The first `rows` lines of the file, each split into fields the way `layout` says,
with quotes removed. Row `k` is file line `k`, so the heading and units rows are
included; a blank line gives an empty row.
"""
function preview_rows(path::AbstractString, layout::CsvLayout; rows::Integer = 20)::Vector{Vector{String}}
    isfile(path) || throw(ToolError("There is no file at $path."))
    sp = FieldSplitter(layout, 64)
    return Vector{String}[isblankline(t) ? String[] : split_texts(sp, t) for t in first_lines(path, Int(rows))]
end

# ---- reading a file --------------------------------------------------------

const COL_SKIP = 0x00
const COL_NUMBER = 0x01
const COL_TEXT = 0x02
const COL_LINE = 0x03

const SAppender = ColumnAppender{StringWriter}

"Everything the importer tracks while it reads a file."
mutable struct CsvState
    path::String
    db::LineDatabase
    first_data_row::Int
    ticker::ChunkProgress
    sp::FieldSplitter
    ncols::Int
    # Per file column: what it is, which appender it goes to, and its channel name.
    kind::Vector{UInt8}
    slot::Vector{Int}
    colnames::Vector{String}
    napps::Vector{XAppender}
    sapps::Vector{SAppender}
    appdict::Union{Nothing,Dict{String,ColumnAppender}}
    warned::BitVector
    fid_col::Int
    fid::FidTracker
    # Lines.
    line_col::Int
    last_value::Vector{UInt8}
    cur_src::LineId
    cur::Union{Nothing,LineInfo}
    # Result.
    log::WarningLog
    rows::Int
    lines::Int
end

function CsvState(path::String, db::LineDatabase, layout::CsvLayout, line_col::Int, progress::Progress)
    n = length(layout.columns)
    return CsvState(path, db, layout.first_data_row, ChunkProgress(progress, path), FieldSplitter(layout, n), n,
                    fill(COL_SKIP, n), zeros(Int, n), String[c.name for c in layout.columns], XAppender[], SAppender[], nothing,
                    falses(n), 0, FidTracker(), line_col, UInt8[], DEFAULT_LINE_ID, nothing,
                    WarningLog(), 0, 0)
end

"Make the channels (or find them, in append mode), the position pair and the appenders."
function setup_csv_channels!(st::CsvState, layout::CsvLayout, plans::Vector{ChannelPlan})
    db = st.db
    taken = Set{String}()
    names = String[]
    for (k, p) in enumerate(plans)
        name = channel_name(p.name, k, taken)
        push!(taken, lowercase(name))
        push!(names, name)
    end
    for (k, p) in enumerate(plans)
        role = ROLE_NONE
        if p.role != :array && !isempty(layout.x)
            p.name == layout.x && (role = name_role(p.name) == ROLE_LON ? ROLE_LON : ROLE_X)
            p.name == layout.y && (role = name_role(p.name) == ROLE_LAT ? ROLE_LAT : ROLE_Y)
        end
        names[k] = import_channel!(db, names[k], p.name, p.eltype, p.units, role, length(p.cols), "CSV")
    end
    if !isempty(layout.x)
        xk = findfirst(p -> p.role != :array && p.name == layout.x, plans)
        yk = findfirst(p -> p.role != :array && p.name == layout.y, plans)
        crs = isempty(layout.crs) && name_role(layout.x) == ROLE_LON ? "EPSG:4326" : layout.crs
        add_pair!(db, names[something(xk)], names[something(yk)], crs)
        db.current_pair == 0 && !isempty(db.pairs) && (db.current_pair = 1)
    end
    d = open_appenders(db, names)
    st.appdict = d
    for (k, p) in enumerate(plans)
        a = d[names[k]]
        if p.eltype === String
            push!(st.sapps, a::SAppender)
            slot, kind = length(st.sapps), COL_TEXT
        else
            push!(st.napps, a::XAppender)
            slot, kind = length(st.napps), COL_NUMBER
        end
        for c in p.cols
            st.kind[c] = kind
            st.slot[c] = slot
            st.colnames[c] = names[k]
            p.role == :fiducial && (st.fid_col = c)
        end
    end
    st.line_col > 0 && (st.kind[st.line_col] = COL_LINE)
    return nothing
end

function csv_line!(st::CsvState, lineno::Int, line::SubString{String}, bytes_read::Int)
    tick!(st.ticker, bytes_read)
    lineno < st.first_data_row && return nothing
    s = line.string
    i, j = line_range(line)
    # Skip blank rows. The fields are split from the start of the row, since
    # leading blanks are part of the first fixed-width column.
    k = i
    while k <= j && is_blank(codeunit(s, k))
        k += 1
    end
    k > j && return nothing
    sp = st.sp
    n = split_fields!(sp, s, i, j)
    if n < st.ncols || sp.extra
        warn!(st.log, lineno, row_length_message(st.ncols, n))
        return nothing
    end
    sp.junk > 0 && warn_junk!(st, lineno)
    # A row of empty fields, such as ",,,", is skipped.
    empty_row = true
    @inbounds for k in 1:st.ncols
        sp.starts[k] <= sp.stops[k] && (empty_row = false; break)
    end
    empty_row && return nothing
    l = row_line!(st, lineno, s)
    row = l.nrows + 1
    @inbounds for c in 1:st.ncols
        kind = st.kind[c]
        if kind == COL_NUMBER
            v = NaN
            if !field_missing(sp, s, c)
                x = field_number(sp, s, c)
                if x === nothing
                    if !st.warned[c]
                        st.warned[c] = true
                        warn_bad_value!(st.log, lineno, st.colnames[c], l, s, sp.starts[c], sp.stops[c])
                    end
                else
                    v = x
                end
            end
            append_value!(st.napps[st.slot[c]], v)
            c == st.fid_col && track_fiducial!(st.fid, v, row)
        elseif kind == COL_TEXT
            append_value!(st.sapps[st.slot[c]], field_missing(sp, s, c) ? "" : field_string(sp, s, c))
        end
    end
    l.nrows = row
    st.rows += 1
    return nothing
end

@noinline function warn_junk!(st::CsvState, lineno::Int)
    k = st.sp.junk
    warn!(st.log, lineno, "column $(k <= length(st.colnames) ? st.colnames[k] : string(k)) has text after its closing quote; " *
                          "only the quoted text is read")
    return nothing
end

"True when bytes `a:e` of `s` equal `v`."
function same_bytes(v::Vector{UInt8}, s::String, a::Int, e::Int)::Bool
    n = max(e - a + 1, 0)
    length(v) == n || return false
    @inbounds for k in 1:n
        v[k] == codeunit(s, a + k - 1) || return false
    end
    return true
end

"The line this row goes to. Starts a new line when the line value names another line."
function row_line!(st::CsvState, lineno::Int, s::String)::LineInfo
    cur = st.cur
    if st.line_col == 0
        return cur === nothing ? new_csv_line!(st, DEFAULT_LINE_ID) : cur
    end
    c = st.line_col
    a, e = st.sp.starts[c], st.sp.stops[c]
    # The same text as the row before: the same line. No memory is allocated.
    cur !== nothing && same_bytes(st.last_value, s, a, e) && return cur
    resize!(st.last_value, max(e - a + 1, 0))
    e >= a && copyto!(st.last_value, 1, codeunits(s), a, e - a + 1)
    text = field_string(st.sp, s, c)
    r = field_missing(st.sp, s, c) ? nothing : parse_line_name(String.(split(text)))
    if r === nothing
        l = cur === nothing ? new_csv_line!(st, DEFAULT_LINE_ID) : cur
        warn!(st.log, lineno, "the line value \"$(first(text, 40))\" is not a line name such as L1001, " *
                              "T2001 or 1001; the row is added to line $(line_name(l.id))")
        return l
    end
    id = r[1]
    cur !== nothing && id == st.cur_src && return cur
    return new_csv_line!(st, id)
end

function new_csv_line!(st::CsvState, id::LineId)::LineInfo
    finish_csv_line!(st)
    l = start_line!(st.db, id, 0, "")
    st.cur = l
    st.cur_src = id
    st.lines += 1
    fill!(st.warned, false)
    reset!(st.fid)
    return l
end

"Set the fiducial start and step of the current line from its fiducial column."
function finish_csv_line!(st::CsvState)
    l = st.cur
    (l === nothing || st.fid_col == 0) && return nothing
    finish_fiducials!(st.fid, l, st.log)
    return nothing
end

"Read the file into `st.db`. Ends with the appenders closed."
function read_csv!(st::CsvState)
    eachfileline(st.path) do lineno, line, bytes_read
        csv_line!(st, lineno, line, bytes_read)
    end
    st.rows == 0 && throw(ToolError("The file $(st.path) has no rows of data to import " *
                                    "from row $(st.first_data_row) on."))
    check_cancel(st.ticker)
    finish_csv_line!(st)
    d = st.appdict
    st.appdict = nothing
    d === nothing || close_appenders!(d)
    report(st.ticker.progress, 1.0)
    return nothing
end

"""
    import_csv(s, path, layout; name, mode = :new, target = "", progress = NO_PROGRESS) -> ImportResult

Import a CSV, other delimited or fixed-width text file of line data (spec 6.4),
read the way `layout` says (see `CsvLayout`, `sniff_csv`).

- `name`: name of the new database; the file name without extension by default.
- `mode = :new` makes a new database item. `mode = :append` adds the lines to the
  database item `target`; a line that is already there gets the next free version.
- `progress` gets the fraction of bytes read, and is checked for cancel once per chunk.
  A cancelled import throws `ImportCancelled`.

A bad layout throws a `ToolError` with the problems, before anything is made.
Rows with too few or too many values, values that are not numbers and values that
are not line names become warnings with the file line number. A failed or cancelled
import throws, and leaves no new item and no changed database behind.

The import is recorded in the history as `"import.csv"`, with the layout as JSON
text, so a script can run it again. `record = false` skips that; the importer does
this inside a job, because the job records the import.
"""
function import_csv(s::Session, path::String, layout::CsvLayout; name::AbstractString = splitext(basename(path))[1],
                    mode::Symbol = :new, target::AbstractString = "", progress::Progress = NO_PROGRESS,
                    record::Bool = true)::ImportResult
    check_import_args(path, mode, target)
    plans, line_col = plan_layout(layout)
    args = Dict{String,Any}("path" => path, "name" => String(name), "mode" => String(mode),
                            "target" => String(target), "layout" => layout_json(layout))
    report(progress, 0.0)
    r = import_lines(s, mode, String(name), String(target)) do db
        st = CsvState(path, db, layout, line_col, progress)
        setup_csv_channels!(st, layout, plans)
        read_csv!(st)
        return (final_warnings(st.log), st.rows, st.lines)
    end
    record && record!(s, "import.csv", args)
    return r
end

# ---- registration ----------------------------------------------------------

"""
The settings of the CSV importer. The layout comes from, in this order:
`layout` (the full layout as JSON text, as the import dialog makes it with
`layout_json`), the template named by `template`, or `sniff_csv`.
A `crs` that is not blank replaces the crs of the layout.
"""
const CSV_SETTINGS = SettingSpec[
    ChoiceSetting("mode", "Import into", ["new", "append"]; default = "new",
                  labels = ["New database", "Append to existing"],
                  help = "new makes a new database. append adds the lines to an existing one."),
    TextSetting("name", "Database name"; help = "Leave blank to name it after the file."),
    TextSetting("target", "Append to"; help = "The id of the database to append to, such as db-1."),
    TextSetting("template", "Import template";
                help = "The name of a saved layout. Leave blank to guess the layout from the file."),
    TextSetting("layout", "Layout"; advanced = true,
                help = "The full layout as JSON text, from the import dialog. It is used before the template."),
    CRSSetting("crs", "Coordinate system";
               help = "The code of the X and Y coordinates, such as EPSG:7855. Leave blank to keep the one in the layout."),
]

"""
Run the CSV importer from settings (see `CSV_SETTINGS`).
Inside a job, a layout from a template or from `sniff_csv` is added to the
job's args as `layout`, so the job records the exact layout.
Bad settings, a missing template or a bad layout throw a `ToolError`, so the
job fails with a message the user can read.
Not recorded: the job that runs it records it (see `ImporterSpec`).
"""
function run_csv_importer(s::Session, path::String, settings::AbstractDict, progress::Progress)::ImportResult
    v = importer_values(CSV_SETTINGS, settings, "CSV")
    text, template = v["layout"]::String, v["template"]::String
    layout = !isempty(text) ? layout_from_json(text, "The layout setting") :
             !isempty(template) ? load_template(s, template) : sniff_csv(path)
    # Record the layout that was used, so a rerun does not depend on the template
    # file or on how `sniff_csv` guesses.
    isempty(text) && note_job_args!(Dict("layout" => layout_json(layout)))
    crs = v["crs"]::String
    isempty(crs) || (layout = CsvLayout(layout; crs))
    name = v["name"]::String
    return import_csv(s, path, layout; name = isempty(name) ? splitext(basename(path))[1] : name,
                      mode = Symbol(v["mode"]::String), target = v["target"]::String, progress, record = false)
end

register_importer!(ImporterSpec("import.csv", "CSV and text", [".csv", ".txt", ".tsv", ".dat"], ITEM_DATABASE,
                                CSV_SETTINGS, run_csv_importer))
