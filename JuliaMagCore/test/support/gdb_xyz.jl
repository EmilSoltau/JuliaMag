# Compare a database imported from a `.gdb` with the Oasis XYZ export of the
# same file, value by value, within what the export's printed digits allow.
# It has its own small XYZ parser: `import_xyz` turns time and date text into
# missing values, and it does not keep the digit count of each value, which
# the tolerances need.

import Dates

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
    decimals(m) = (k = findfirst('.', m); k === nothing ? 0 : length(m) - k)
    if (m = match(r"^(\d+):(\d{2}):(\d{2}(?:\.\d*)?)$", t)) !== nothing
        h, mi, s = parse(Int, m[1]), parse(Int, m[2]), parse(Float64, m[3])
        return (h + mi / 60 + s / 3600, 0.5 * 10.0^-decimals(m[3]) / 3600)
    end
    if (m = match(r"^(\d{4})/(\d{2})/(\d{2})$", t)) !== nothing
        d = Dates.Date(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]))
        days = Dates.daysinyear(Dates.year(d))
        return (Dates.year(d) + (Dates.dayofyear(d) - 1) / days, 0.5 / days)
    end
    if (m = match(r"^([-+]?\d*\.?\d*)[eE]([-+]?\d+)$", t)) !== nothing && !isempty(m[1])
        x = tryparse(Float64, t)
        x === nothing && return nothing
        return (x, 0.5 * 10.0^(parse(Int, m[2]) - decimals(m[1])))
    end
    x = tryparse(Float64, t)
    x === nothing && return nothing
    return (x, 0.5 * 10.0^-decimals(t))
end

"True when the stored value `v` agrees with the XYZ value `x` within `tol`."
function gdb_xyz_agrees(v, x::Float64, tol::Float64)::Bool
    isnan(x) && return v isa AbstractString ? isempty(v) : JuliaMagCore.ismissingvalue(v)
    (v isa AbstractString || JuliaMagCore.ismissingvalue(v)) && return false
    y = Float64(v)
    # A little room for the binary form of the printed and the stored number.
    return abs(y - x) <= tol * (1 + 1e-9) + 4 * eps(max(abs(x), abs(y)))
end

"""
    compare_gdb_xyz(db, xyz; rename = Dict{String,String}(), skip_all_missing_rows = false)

Compare `db` with the Oasis XYZ export at `xyz`. Returns the number of values
checked and the first 20 mismatches as text.

Columns match channels by name, then by label, ignoring case; `rename` maps an
XYZ name to a channel name first. The k-th line block (a line that starts with a
letter, such as `Line 10`) is line `k` of the database; a file with no block
lines is one block. Each data row is the next row of that line.
`skip_all_missing_rows` first drops the rows of a line that are missing in
every compared channel.
"""
function compare_gdb_xyz(db, xyz::AbstractString; rename = Dict{String,String}(),
                         skip_all_missing_rows::Bool = false)::Tuple{Int,Vector{String}}
    names = xyz_column_names(xyz)
    lower(s) = lowercase(String(s))
    chans = map(names) do n
        want = lower(get(rename, n, n))
        k = findfirst(c -> lower(c.name) == want, db.channels)
        k === nothing && (k = findfirst(c -> lower(c.label) == want, db.channels))
        k === nothing && error("no channel of $(db.name) matches the XYZ column $n")
        db.channels[k].name
    end
    bad = String[]
    checked = Ref(0)
    note!(msg) = length(bad) < 20 && push!(bad, msg)
    block = Ref(0)
    cols = Ref(Vector{Any}())
    rows = Ref(Int[])
    next = Ref(1)
    function start_block!()
        block[] += 1
        if block[] > length(db.lines)
            note!("XYZ block $(block[]) has no line in the database")
            cols[], rows[] = Any[], Int[]
            return nothing
        end
        l = db.lines[block[]]
        cols[] = Any[read_channel(db, l.id, c) for c in chans]
        keep = 1:l.nrows
        if skip_all_missing_rows
            keep = [r for r in keep if !all(c -> JuliaMagCore.ismissingvalue(c[r]), cols[])]
        end
        rows[], next[] = collect(keep), 1
        return nothing
    end
    function end_block!()
        block[] == 0 && return nothing
        left = length(rows[]) - next[] + 1
        left > 0 && block[] <= length(db.lines) &&
            note!("line $(line_name(db.lines[block[]].id)): the database has $left more rows than the XYZ block")
        return nothing
    end
    eachfileline(xyz) do lineno, line, _
        s = strip(line)
        (isempty(s) || startswith(s, "/")) && return nothing
        if isletter(first(s))
            end_block!()
            start_block!()
            return nothing
        end
        block[] == 0 && start_block!()
        fields = split(s)
        if length(fields) != length(names)
            note!("XYZ line $lineno has $(length(fields)) values, not $(length(names))")
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
            parsed = gdb_xyz_value(f)
            v = cols[][k][r]
            if parsed === nothing
                ok = v isa AbstractString && v == f
            else
                ok = gdb_xyz_agrees(v, parsed[1], parsed[2])
            end
            checked[] += 1
            ok || note!("XYZ line $lineno, column $(names[k]): the XYZ has $f, the database $(repr(v))")
        end
        return nothing
    end
    end_block!()
    return checked[], bad
end
