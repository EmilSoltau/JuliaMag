# Compare a database imported from a `.gdb` with the Oasis XYZ export of the
# same file, value by value, within what the export's printed digits allow.
# It has its own small XYZ parser: `import_xyz` turns time and date text into
# missing values, and it does not keep the digit count of each value, which
# the tolerances need.

import Dates

"The number of digits after the point in `t`."
gdb_xyz_decimals(t::AbstractString) = (k = findfirst('.', t); k === nothing ? 0 : lastindex(t) - k)

"""
    gdb_xyz_value(text) -> (value, tolerance) or `nothing`

The value of one XYZ field and how far a stored value may be from it:
- `*`: `(NaN, 0.0)`, a missing value;
- a number with `d` digits after the point: `0.5 * 10^-d`;
- `m e k` (exponent form): `0.5 * 10^(k - d)`, with `d` the digits after the point of `m`;
- `hh:mm:ss.ss`: decimal hours, within half a unit of the last seconds digit, over 3600;
- `yyyy/mm/dd`: a decimal year `year + (doy - 1) / days_in_year`, within half a day.
`nothing` for text that is none of these.
"""
function gdb_xyz_value(t::AbstractString)::Union{Nothing,Tuple{Float64,Float64}}
    t == "*" && return (NaN, 0.0)
    if occursin(':', t)
        m = match(r"^(\d+):(\d{2}):(\d{2}(?:\.\d*)?)$", t)
        m === nothing && return nothing
        h, mi, s = parse(Int, m[1]), parse(Int, m[2]), parse(Float64, m[3])
        return (h + mi / 60 + s / 3600, 0.5 * 10.0^-gdb_xyz_decimals(m[3]) / 3600)
    end
    if occursin('/', t)
        m = match(r"^(\d{4})/(\d{2})/(\d{2})$", t)
        m === nothing && return nothing
        d = Dates.Date(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]))
        days = Dates.daysinyear(Dates.year(d))
        return (Dates.year(d) + (Dates.dayofyear(d) - 1) / days, 0.5 / days)
    end
    x = tryparse(Float64, t)
    x === nothing && return nothing
    e = findfirst(c -> c == 'e' || c == 'E', t)
    e === nothing && return (x, 0.5 * 10.0^-gdb_xyz_decimals(t))
    return (x, 0.5 * 10.0^(parse(Int, t[nextind(t, e):end]) - gdb_xyz_decimals(t[1:prevind(t, e)])))
end

"True when the stored value `y` (NaN when missing) agrees with the XYZ value `x` within `tol`."
function gdb_xyz_agrees(y::Float64, x::Float64, tol::Float64)::Bool
    isnan(x) && return isnan(y)
    isnan(y) && return false
    # A little room for the binary form of the printed and the stored number.
    return abs(y - x) <= tol * (1 + 1e-9) + 4 * eps(max(abs(x), abs(y)))
end

"The values of one channel on one line as Float64 (NaN when missing), or as text for a text channel."
function gdb_xyz_column(v::AbstractVector)
    eltype(v) === String && return Vector{String}(v)
    return Float64[JuliaMagCore.ismissingvalue(x) ? NaN : Float64(x) for x in v]
end
gdb_xyz_column(v::AbstractMatrix) = error("compare_gdb_xyz cannot compare array channels")

"""
    compare_gdb_xyz(db, xyz; names = nothing, rename = Dict{String,String}(), skip_all_missing_rows = false)

Compare `db` with the Oasis XYZ export at `xyz`. Returns the number of values
checked and the first 20 mismatches as text.

The column names come from the export (`xyz_column_names`). An export with no
names line needs `names`, which must come from a reference that documents the
columns, never from the data; it must have one name per column. Columns match
channels by name, then by label, ignoring case; `rename` maps an XYZ name to a
channel name first.

A line block starts with a header, a line that starts with a letter, such as
`Line 10` or `LINE  10010`. The header names its line as JuliaMag's XYZ reader
reads it (`parse_line_name`), so the blocks may come in any order. A header that
is not a line name, such as `Line 28_29`, needs `lines`, which maps the header
(words joined by one space) to the JuliaMag line name, such as `"L30"`. A file
with no headers is one block, the first line. Each data row is the next row of
its line. A block that names no line, and a line with no block, are mismatches. `skip_all_missing_rows` first drops the rows
of a line that are missing in every compared channel.
"""
function compare_gdb_xyz(db, xyz::AbstractString; names::Union{Nothing,Vector{String}} = nothing,
                         rename = Dict{String,String}(), lines = Dict{String,String}(),
                         skip_all_missing_rows::Bool = false)::Tuple{Int,Vector{String}}
    given = names !== nothing
    cols_names = given ? names : xyz_column_names(xyz)
    lower(s) = lowercase(String(s))
    chans = map(cols_names) do n
        want = lower(get(rename, n, n))
        k = findfirst(c -> lower(c.name) == want, db.channels)
        k === nothing && (k = findfirst(c -> lower(c.label) == want, db.channels))
        k === nothing && error("no channel of $(db.name) matches the XYZ column $n")
        db.channels[k].name
    end
    ncol = length(cols_names)
    bad = String[]
    checked = Ref(0)
    note!(msg) = length(bad) < 20 && push!(bad, msg)
    block = Ref(0)
    used = Set{Int}()
    cols = Ref(Any[])
    rows = Ref(Int[])
    next = Ref(1)
    seen_row = Ref(false)
    started = Ref(false)
    function start_block!(header::Union{Nothing,AbstractString})
        k = nothing
        if header === nothing
            k = isempty(db.lines) ? nothing : 1
        else
            key = join(split(header), " ")
            if haskey(lines, key)
                k = findfirst(l -> line_name(l.id) == lines[key], db.lines)
            else
                id = JuliaMagCore.parse_line_name(String.(split(header)))
                id === nothing || (k = findfirst(l -> l.id == id[1], db.lines))
            end
            k === nothing && note!("XYZ block \"$key\" names no line of the database")
        end
        block[] = something(k, 0)
        if k === nothing
            cols[], rows[], next[] = Any[], Int[], 1
            return nothing
        end
        push!(used, k)
        l = db.lines[k]
        cols[] = Any[gdb_xyz_column(read_channel(db, l.id, c)) for c in chans]
        keep = collect(1:l.nrows)
        if skip_all_missing_rows
            gone(c, r) = c isa Vector{String} ? isempty(c[r]) : isnan(c[r])
            keep = [r for r in keep if !all(c -> gone(c, r), cols[])]
        end
        rows[], next[] = keep, 1
        return nothing
    end
    function end_block!()
        block[] == 0 && return nothing
        left = length(rows[]) - next[] + 1
        left > 0 &&
            note!("line $(line_name(db.lines[block[]].id)): the database has $left more rows than the XYZ block")
        return nothing
    end
    eachfileline(xyz) do lineno, line, _
        s = strip(line)
        (isempty(s) || startswith(s, "/")) && return nothing
        if isletter(first(s))
            end_block!()
            start_block!(s)
            started[] = true
            return nothing
        end
        started[] || (start_block!(nothing); started[] = true)
        fields = split(s)
        if !seen_row[]
            seen_row[] = true
            given && length(fields) != ncol &&
                error("the XYZ has $(length(fields)) columns, but $ncol names were given")
        end
        if length(fields) != ncol
            note!("XYZ line $lineno has $(length(fields)) values, not $ncol")
            return nothing
        end
        isempty(cols[]) && return nothing
        if next[] > length(rows[])
            note!("XYZ line $lineno: line $(line_name(db.lines[block[]].id)) has no more rows")
            return nothing
        end
        r = rows[][next[]]
        next[] += 1
        for (k, f) in enumerate(fields)
            checked[] += 1
            gdb_xyz_field_ok(cols[][k], r, f) ||
                note!("XYZ line $lineno, column $(cols_names[k]): the XYZ has $f, the database $(repr(cols[][k][r]))")
        end
        return nothing
    end
    end_block!()
    for (k, l) in enumerate(db.lines)
        k in used || note!("line $(line_name(l.id)) has no block in the XYZ")
    end
    return checked[], bad
end

"True when row `r` of the column `c` agrees with the XYZ field `f`. A function barrier on the column type."
function gdb_xyz_field_ok(c::Vector{Float64}, r::Int, f::AbstractString)::Bool
    parsed = gdb_xyz_value(f)
    return parsed !== nothing && gdb_xyz_agrees(c[r], parsed[1], parsed[2])
end
gdb_xyz_field_ok(c::Vector{String}, r::Int, f::AbstractString)::Bool = f == "*" ? isempty(c[r]) : c[r] == f
