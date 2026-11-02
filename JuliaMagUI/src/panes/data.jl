# The Data tab of the left pane: the tree of the project's items, the Properties panel
# under it and the filter box at the bottom, as the prototype's `renderDataTab`.
#
# The tree model (`tree_rows`, `properties`) is pure: it reads a `Snapshot` and returns
# plain rows. Drawing reads the model; every change goes through the worker (`submit!`)
# or a request (`request!`).

# --- The tree model ---

"""
    TreeRow

One row of the Data tree.

- `key`: unique and stable, see `row_key`; it also names the row's expanded state.
- `depth`: 0 for the folders Databases and Grids, then one more per level.
- `kind`: `:databases`, `:database`, `:lines`, `:line`, `:channels`, `:channel`, `:pair`,
  `:grids` or `:grid`.
- `label`: the name; `right`: the dim text at the right (a count, units, a size).
- `icon`: a prototype icon name; `bold`: folders and the current database.
- `dim` and `italic`: an item whose folder is missing (or that cannot be read).
- `checkbox`: `nothing`, or whether a line is selected for processing.
- `tag`: a small boxed word after the name, such as a channel role, or `""`.
"""
struct TreeRow
    key::String
    depth::Int
    kind::Symbol
    label::String
    right::String
    icon::String
    bold::Bool
    dim::Bool
    italic::Bool
    checkbox::Union{Nothing,Bool}
    tag::String
end

TreeRow(key, depth, kind, label; right = "", icon = "", bold = false, dim = false,
        italic = false, checkbox = nothing, tag = "") =
    TreeRow(String(key), depth, kind, String(label), String(right), String(icon), bold, dim,
        italic, checkbox, String(tag))

const FOLDER_KEYS = (databases = "databases", grids = "grids")
# The kinds of rows that belong to a database: selecting one makes that database current.
const DATABASE_KINDS = (:database, :lines, :line, :channels, :channel, :pair)

"""
    row_key(kind, item, sub) -> String

The key of a tree row: `"databases"`, `"grids"`, the item id for a database or grid,
`"<id>/lines"`, `"<id>/channels"`, `"<id>/lines/<line>"`, `"<id>/channels/<channel>"` and
`"<id>/pairs/<x>,<y>"`. `row_target` reads it back.
"""
function row_key(kind::Symbol, item::AbstractString, sub::AbstractString)::String
    kind === :databases && return FOLDER_KEYS.databases
    kind === :grids && return FOLDER_KEYS.grids
    kind in (:database, :grid) && return String(item)
    kind === :lines && return string(item, "/lines")
    kind === :channels && return string(item, "/channels")
    kind === :line && return string(item, "/lines/", sub)
    kind === :channel && return string(item, "/channels/", sub)
    kind === :pair && return string(item, "/pairs/", sub)
    throw(ArgumentError("unknown tree row kind :$kind"))
end

"""
    row_target(row) -> (kind, item, sub)

What a tree row stands for: its kind, the item id (`""` for a top folder) and the line,
channel or pair (`"X,Y"`) name, or `""`. This is what `app.ui.selected` holds.
"""
function row_target(row::TreeRow)::Tuple{Symbol,String,String}
    k = row.kind
    k in (:databases, :grids) && return (k, "", "")
    k in (:database, :grid) && return (k, row.key, "")
    parts = split(row.key, '/'; limit = 3)
    return (k, String(parts[1]), length(parts) == 3 ? String(parts[3]) : "")
end

"Can the row open to show rows under it?"
has_children(row::TreeRow) = row.kind in (:databases, :grids, :lines, :channels) ||
    (row.kind === :database && !row.dim)

"The text of a position pair row, such as `\"X, Y\"`; `pair_sub` is its key part, `\"X,Y\"`."
pair_label(q::Core.PositionPair) = string(q.x, ", ", q.y)
pair_sub(q::Core.PositionPair) = string(q.x, ",", q.y)

"""
    role_tag(role) -> String

The tag of a channel role, such as `\"x\"` or `\"elevation\"`; `\"\"` for no role.
"""
role_tag(role::Core.ChannelRole) = get(ROLE_WORDS, role) do
    lowercase(replace(string(role), "ROLE_" => ""))
end

# The prototype's words where they are not the role's own name.
const ROLE_WORDS = Dict(Core.ROLE_NONE => "", Core.ROLE_LON => "longitude", Core.ROLE_LAT => "latitude")

"""
    fmt_int(n) -> String

`n` with a comma between groups of three digits, as the prototype's `fmtInt`: `"172,900"`.
"""
function fmt_int(n::Integer)::String
    d = string(abs(n))
    groups = String[]
    while length(d) > 3
        pushfirst!(groups, d[end-2:end])
        d = d[1:end-3]
    end
    pushfirst!(groups, d)
    return (n < 0 ? "-" : "") * join(groups, ",")
end

# Numbers this big or bigger are written with an exponent ("1.70141e38"): they do not fit
# an `Int`, and a grid of Float32 values can hold up to 3.4e38.
const HUGE_NUMBER = 1e15

# `x` with an exponent and 6 significant digits, or "NaN", "Inf", "-Inf".
exp_num(x::Real) = isfinite(x) ? string(round(Float64(x); sigdigits = 6)) : string(Float64(x))

"""
    fmt_num(x, digits) -> String

`x` with `digits` decimals and commas between thousands, as the prototype's `fmtNum`.
A value of 1e15 or more, NaN, Inf, and a value whose digits do not fit an `Int128` are
written as `exp_num` does (`"1.0e20"`, `"NaN"`). `digits` is taken as 0 to 38.
"""
function fmt_num(x::Real, digits::Integer)::String
    (isfinite(x) && abs(x) < HUGE_NUMBER) || return exp_num(x)
    # 10^38 is the biggest power of ten an Int128 holds; more digits would wrap.
    digits = clamp(digits, 0, 38)
    digits == 0 && return fmt_int(round(Int, x))
    scaled = abs(Float64(x)) * 10.0^digits
    scaled < 1e38 || return exp_num(x)
    # Round once, in whole units of the last digit, so a fraction that rounds up carries
    # into the whole part (99.995 gives 100.00, never 99.100).
    n = round(Int128, scaled)
    whole, frac = divrem(n, Int128(10)^digits)
    sign = x < 0 && n != 0 ? "-" : ""
    return sign * fmt_int(whole) * "." * lpad(string(frac), digits, '0')
end

# A number as short as it reads: 25 for 25.0; huge and non-finite values as `exp_num`.
short_num(x::Real) = !(isfinite(x) && abs(x) < HUGE_NUMBER) ? exp_num(x) :
    isinteger(x) ? fmt_int(round(Int, x)) : string(Float64(x))

const MISSING_TEXT = "folder not found"
const BROKEN_TEXT = "cannot be read"

"""
    tree_rows(snap, expanded, filter; current = "") -> Vector{TreeRow}

The rows of the Data tree, top to bottom: `Databases` > each database > `Lines` > line
rows and `Channels` > position pairs and channel rows; then `Grids` > grid rows. A folder
shows its rows when its key is in `expanded`. The database `current` is bold.

A `filter` (case-insensitive, blank for none) keeps the database, grid, line, channel and
pair rows whose name holds it, with their parents, all open. A database that matches by
name shows itself; a folder (top folders too) shows only when it holds a match.
"""
function tree_rows(snap::Snapshot, expanded::AbstractSet{String}, filter::AbstractString;
        current::AbstractString = "")::Vector{TreeRow}
    q = lowercase(strip(filter))
    filtering = !isempty(q)
    hit(text) = filtering && occursin(q, lowercase(text))
    rows = TreeRow[]
    dbs = [it for it in snap.items if it.kind == Core.ITEM_DATABASE]
    grids = [it for it in snap.items if it.kind == Core.ITEM_GRID]

    folder = TreeRow(FOLDER_KEYS.databases, 0, :databases, "Databases"; right = string(length(dbs)),
        icon = "folder", bold = true)
    push!(rows, folder)
    if filtering || FOLDER_KEYS.databases in expanded
        for it in dbs
            add_database_rows!(rows, snap, it, expanded, filtering, hit, it.id == current)
        end
    end
    filtering && last(rows) === folder && pop!(rows)   # no match under it

    folder = TreeRow(FOLDER_KEYS.grids, 0, :grids, "Grids"; right = string(length(grids)),
        icon = "folder", bold = true)
    push!(rows, folder)
    if filtering || FOLDER_KEYS.grids in expanded
        for it in grids
            filtering && !hit(it.name) && continue
            v = get(snap.grids, it.id, nothing)
            broken = !it.missing && (v === nothing || !isempty(v.error))
            right = it.missing ? MISSING_TEXT : broken ? BROKEN_TEXT : string(v.nx, " x ", v.ny)
            push!(rows, TreeRow(it.id, 1, :grid, it.name; right, icon = it.missing ? "missing" : "grid",
                dim = it.missing || broken, italic = it.missing || broken))
        end
    end
    filtering && last(rows) === folder && pop!(rows)
    return rows
end

function add_database_rows!(rows::Vector{TreeRow}, snap::Snapshot, it::ItemRow,
        expanded::AbstractSet{String}, filtering::Bool, hit::Function, current::Bool)
    v = get(snap.databases, it.id, nothing)
    broken = it.missing || v === nothing || !isempty(v.error)
    lines = broken ? LineRow[] : filtering ? filter(l -> hit(l.name), v.lines) : v.lines
    chans = broken ? ChannelRow[] : filtering ? filter(c -> hit(c.name), v.channels) : v.channels
    pairs = broken ? Core.PositionPair[] :
            filtering ? filter(q -> hit(pair_label(q)), v.pairs) : v.pairs
    filtering && !hit(it.name) && isempty(lines) && isempty(chans) && isempty(pairs) && return nothing
    id = it.id
    right = it.missing ? MISSING_TEXT : broken ? BROKEN_TEXT : ""
    push!(rows, TreeRow(id, 1, :database, it.name; right, icon = broken ? "missing" : "database",
        bold = current, dim = broken, italic = broken))
    (broken || !(filtering || id in expanded)) && return nothing

    if !filtering || !isempty(lines)
        k = row_key(:lines, id, "")
        nsel = count(l -> l.selected, v.lines)
        push!(rows, TreeRow(k, 2, :lines, "Lines"; right = "$nsel of $(length(v.lines)) selected",
            icon = "lines", bold = true))
        if filtering || k in expanded
            for l in lines
                push!(rows, TreeRow(row_key(:line, id, l.name), 3, :line, l.name;
                    right = string("F", l.flight, "  ", fmt_int(l.nrows)),
                    icon = l.id.type == Core.TIE ? "lineT" : "lineL", checkbox = l.selected))
            end
        end
    end
    if !filtering || !isempty(chans) || !isempty(pairs)
        k = row_key(:channels, id, "")
        push!(rows, TreeRow(k, 2, :channels, "Channels"; right = string(length(v.channels)),
            icon = "channel", bold = true))
        if filtering || k in expanded
            for q in pairs
                cur = findfirst(==(q), v.pairs) == v.current_pair
                push!(rows, TreeRow(row_key(:pair, id, pair_sub(q)), 3, :pair, pair_label(q);
                    right = q.crs, icon = "pair", tag = cur ? "current" : ""))
            end
            for c in chans
                push!(rows, TreeRow(row_key(:channel, id, c.name), 3, :channel, c.name;
                    right = c.units, icon = c.protected ? "lock" : "channel", tag = role_tag(c.role)))
            end
        end
    end
    return nothing
end

"""
    tree_empty_text(filter, rows) -> Union{Nothing,String}

What the tree says when it has no rows: `"No matches"` while a filter is typed, else
`nothing` (an empty project still shows its Databases and Grids folders).
"""
tree_empty_text(filter::AbstractString, rows::AbstractVector{TreeRow}) =
    isempty(rows) && !isempty(strip(filter)) ? "No matches" : nothing

"""
    next_row(rows, key, delta) -> Union{Nothing,Int}

The index of the row `delta` rows from the row with `key`, kept inside the list; the first
row when no row has `key`; `nothing` for no rows.
"""
function next_row(rows::AbstractVector{TreeRow}, key::Union{Nothing,AbstractString}, delta::Integer)
    isempty(rows) && return nothing
    k = key === nothing ? nothing : findfirst(r -> r.key == key, rows)
    k === nothing && return 1
    return clamp(k + delta, 1, length(rows))
end

"""
    visible_rows(n, row_h, scroll, view_h) -> UnitRange{Int}

The rows (1-based) of a list of `n` rows `row_h` high that a view `view_h` high shows when
it is scrolled `scroll` down from the first row's top. Only these rows are drawn.
"""
function visible_rows(n::Integer, row_h::Real, scroll::Real, view_h::Real)::UnitRange{Int}
    n == 0 && return 1:0
    first = max(1, floor(Int, scroll / row_h) + 1)
    last = min(n, ceil(Int, (scroll + view_h) / row_h))
    return first:last
end

"The tree rows for one state of the snapshot, the open folders, the filter and the current database."
struct TreeCache
    snap::Snapshot
    expanded::Set{String}
    filter::String
    current::String
    rows::Vector{TreeRow}
end

"""
    cached_tree_rows!(app) -> Vector{TreeRow}

`tree_rows` for the app's snapshot and Data tree state, built again only when one of them
changed (5,000 lines make a frame slow otherwise).
"""
function cached_tree_rows!(app)::Vector{TreeRow}
    snap = app.snap::Snapshot
    ui = app.ui
    c = ui.tree_cache
    if c isa TreeCache && c.snap === snap && c.expanded == ui.expanded && c.filter == ui.filter &&
            c.current == ui.current_db
        return c.rows
    end
    rows = tree_rows(snap, ui.expanded, ui.filter; current = ui.current_db)
    ui.tree_cache = TreeCache(snap, copy(ui.expanded), ui.filter, ui.current_db, rows)
    return rows
end

# --- Properties ---

"""
    PropsView

What the Properties panel shows: a `title` and `key => value` rows (a `""` key continues
the row above, such as a second position pair).
"""
struct PropsView
    title::String
    rows::Vector{Pair{String,String}}
end

const LINE_TYPE_NAMES = Dict(Core.LINE => "Line", Core.TIE => "Tie", Core.BASE => "Base",
    Core.TEST => "Test", Core.TREND => "Trend", Core.SPECIAL => "Special", Core.RANDOM => "Random")

yes_no(b::Bool) = b ? "Yes" : "No"

# A coordinate system as "<name> (<code>)", or the code, or "Not set".
function crs_text(snap::Snapshot, code::AbstractString)
    isempty(code) && return "Not set"
    info = get(snap.crs, code, nothing)
    return info === nothing || isempty(info.name) ? String(code) : string(info.name, " (", code, ")")
end

crs_short(snap::Snapshot, code::AbstractString) = isempty(code) ? "no system" :
    (info = get(snap.crs, code, nothing); info === nothing || isempty(info.name) ? String(code) : info.name)

crs_unit(snap::Snapshot, code::AbstractString) =
    (info = get(snap.crs, code, nothing); info === nothing ? "" : info.unit)

"""
    properties(snap, selected) -> Union{Nothing,PropsView}

The Properties of the selected tree row (`app.ui.selected`): the fields of a database,
grid, line, channel or position pair, from the snapshot only. `nothing` for a folder, for
no selection, and for an item that is no longer there.
"""
function properties(snap::Snapshot, sel)::Union{Nothing,PropsView}
    sel === nothing && return nothing
    kind, id, sub = sel
    k = findfirst(it -> it.id == id, snap.items)
    k === nothing && return nothing
    it = snap.items[k]
    problem = item_problem(snap, it)
    if kind in (:database, :grid) && problem !== nothing
        noun = kind === :database ? "Database" : "Grid"
        return PropsView(it.name, ["Type" => noun * (it.missing ? " (missing)" : ""),
            "Was at" => it.path, "Status" => problem])
    end
    kind === :grid && return grid_properties(snap, it, snap.grids[id])
    kind in DATABASE_KINDS || return nothing
    v = get(snap.databases, id, nothing)
    (v === nothing || !isempty(v.error)) && return nothing
    kind === :database && return database_properties(snap, it, v)
    if kind === :line
        i = findfirst(l -> l.name == sub, v.lines)
        i === nothing && return nothing
        l = v.lines[i]
        return PropsView("Line " * l.name, [
            "Type" => string(LINE_TYPE_NAMES[l.id.type], " (", first(l.name), ")"),
            "Number" => string(l.id.number, ", version ", l.id.version),
            "Flight" => string(l.flight), "Rows" => fmt_int(l.nrows), "Selected" => yes_no(l.selected)])
    elseif kind === :channel
        i = findfirst(c -> c.name == sub, v.channels)
        i === nothing && return nothing
        c = v.channels[i]
        role = role_tag(c.role)
        return PropsView("Channel " * c.name, [
            "Label" => c.label, "Data type" => c.eltype * (c.arraylen > 1 ? "[$(c.arraylen)]" : ""),
            "Units" => isempty(c.units) ? "-" : c.units, "Role" => isempty(role) ? "none" : role,
            "Protected" => yes_no(c.protected), "Format" => uppercasefirst(string(c.format)),
            "Decimals" => decimals_text(c.decimals)])
    elseif kind === :pair
        i = findfirst(q -> pair_sub(q) == sub, v.pairs)
        i === nothing && return nothing
        q = v.pairs[i]
        return PropsView("Pair " * pair_label(q), ["Type" => "Position pair", "X" => q.x, "Y" => q.y,
            "System" => crs_text(snap, q.crs), "Current" => yes_no(i == v.current_pair)])
    end
    return nothing
end

# Why an item cannot be shown (its folder is gone, or it cannot be read), or `nothing`.
function item_problem(snap::Snapshot, it::ItemRow)::Union{Nothing,String}
    it.missing && return "Folder not found"
    v = it.kind == Core.ITEM_DATABASE ? get(snap.databases, it.id, nothing) :
        it.kind == Core.ITEM_GRID ? get(snap.grids, it.id, nothing) : nothing
    v === nothing && return "Not read yet"
    return isempty(v.error) ? nothing : v.error
end

function database_properties(snap::Snapshot, it::ItemRow, v::DatabaseView)
    n = length(v.lines)
    nl = count(l -> l.id.type == Core.LINE, v.lines)
    nt = count(l -> l.id.type == Core.TIE, v.lines)
    other = n - nl - nt
    kinds = [plural(nl, "line"), plural(nt, "tie")]
    other > 0 && push!(kinds, string(other, " other"))
    rows = ["Type" => "Line database", "Lines" => string(n, " (", join(kinds, ", "), ")"),
        "Rows" => fmt_int(v.rows), "Channels" => string(length(v.channels))]
    for (k, q) in enumerate(v.pairs)
        text = pair_label(q) * (k == v.current_pair ? " (current)" : "") * " - " * crs_short(snap, q.crs)
        push!(rows, (k == 1 ? "Positions" : "") => text)
    end
    isempty(v.pairs) && push!(rows, "Positions" => "None")
    push!(rows, "Folder" => it.path, "Made by" => made_by_text(snap, it.made_by))
    return PropsView(it.name, rows)
end

function made_by_text(snap::Snapshot, job_id::AbstractString)
    isempty(job_id) && return "-"
    k = findfirst(j -> j.id == job_id, snap.jobs)
    k === nothing && return String(job_id)
    j = snap.jobs[k]
    target = job_target(j)
    return isempty(target) ? string(job_title(j), " (", j.id, ")") : string(job_title(j), ", ", target, " (", j.id, ")")
end

function grid_properties(snap::Snapshot, it::ItemRow, g::GridView)
    unit = crs_unit(snap, g.crs)
    u = isempty(unit) ? "" : " " * unit
    cell = g.dx == g.dy ? short_num(g.dx) * u : string(short_num(g.dx), " x ", short_num(g.dy), u)
    origin = unit == "m" ? string(fmt_num(g.x0, 0), " E, ", fmt_num(g.y0, 0), " N") :
        string(short_num(g.x0), ", ", short_num(g.y0))
    values = g.count == 0 || isnan(g.vmin) ? g.eltype * ", no values" :
        rstrip(string(g.eltype, ", ", fmt_num(g.vmin, 1), " to ", fmt_num(g.vmax, 1), " ", g.units))
    return PropsView(it.name, ["Type" => "Grid", "Size" => string(g.nx, " x ", g.ny, " cells"),
        "Cell size" => cell, "Origin" => origin, "Rotation" => short_num(g.rotation) * " deg",
        "System" => crs_text(snap, g.crs), "Values" => String(values)])
end

# --- Actions ---

"""
    select_row!(app, row)

Select `row`. A row of a database (the database itself, its folders, lines, channels and
pairs) also makes that database the current one, which the Database tab acts on.
"""
function select_row!(app, row::TreeRow)
    target = row_target(row)
    app.ui.selected = target
    snap = app.snap
    if target[1] in DATABASE_KINDS && snap !== nothing && haskey(snap.databases, target[2])
        app.ui.current_db = target[2]
    end
    return nothing
end

toggle_open!(app, key::AbstractString) =
    (key in app.ui.expanded ? delete!(app.ui.expanded, key) : push!(app.ui.expanded, String(key)); nothing)

# Tick or untick a line through the worker; the snapshot shows the change.
function set_line_checked!(app, row::TreeRow, flag::Bool)
    _, id, name = row_target(row)
    v = app.snap === nothing ? nothing : get(app.snap.databases, id, nothing)
    v === nothing && return nothing
    i = findfirst(l -> l.name == name, v.lines)
    i === nothing && return nothing
    lid = v.lines[i].id
    submit!(app, (flag ? "Select " : "Deselect ") * name, s -> Core.set_line_selected!(s, id, lid, flag))
    return nothing
end

"""
    default_action!(app, row)

What Enter and a double click do: open or close a folder or database, tick or untick a
line, open the Channel Properties of a channel, make a position pair current.
"""
function default_action!(app, row::TreeRow)
    if has_children(row)
        toggle_open!(app, row.key)
    elseif row.kind === :line && row.checkbox !== nothing
        set_line_checked!(app, row, !row.checkbox)
    elseif row.kind === :channel
        _, id, name = row_target(row)
        open_channel_properties!(app, id, name)
    elseif row.kind === :pair
        _, id, _ = row_target(row)
        run_tool_on!(app, "coordinates.set_current", id)
    end
    return nothing
end

run_tool_on!(app, tool_id::AbstractString, item::AbstractString; values = Dict{String,Any}()) =
    request!(app, OpenToolDialog(tool_id; item, values))

# A menu row for tool `id` acting on `item` (T11-C1: it asks for the tool dialog), with
# settings `values` to start with.
function tool_item(app, id::AbstractString, item::AbstractString; label = nothing,
        values = Dict{String,Any}())
    cmd = find_command(app, id)
    cmd === nothing && return nothing
    return MenuItem(something(label, cmd.name); icon = cmd.icon, help = cmd.help, id = cmd.id,
        reason = cmd.enabled(app), action = a -> run_tool_on!(a, id, item; values))
end

# The menu rows of the commands in a split button's menu (the importers or exporters).
function split_items(app, split_id::AbstractString, action::Function)
    split = find_command(app, split_id)
    split === nothing && return MenuItem[]
    items = MenuItem[]
    for id in split.menu
        cmd = find_command(app, id)
        cmd === nothing && continue
        push!(items, MenuItem(cmd.name; icon = cmd.icon, help = cmd.help, id = cmd.id,
            reason = cmd.enabled(app), action = a -> action(a, cmd)))
    end
    return items
end

item_name(snap, id) = (k = findfirst(it -> it.id == id, snap.items); k === nothing ? id : snap.items[k].name)

function remove_item_item(app, kind::Symbol, id::AbstractString)
    name = item_name(app.snap, id)
    noun = kind === :database ? "database" : "grid"
    return MenuItem("Remove from Project"; icon = "trash", danger = true,
        action = a -> confirm!(a, "Remove $name?", "The $noun leaves the project. It can be undone.";
            action = "Remove", danger = true,
            on_yes = b -> submit!(b, "Remove $name", s -> Core.remove_item!(s, id))))
end

rename_item_item(kind::Symbol, id::AbstractString, sub::AbstractString, name::AbstractString) =
    MenuItem("Rename..."; icon = "rename", action = a -> open_rename!(a, (kind, String(id), String(sub)), name))

"""
    tree_menu(app, row) -> Vector{MenuItem}

The context menu of a tree row, as the prototype's menus for each kind of row (section 4.1).
Tool rows ask for the tool's dialog with the row's item; edits go through the worker;
removals and deletes ask first. Empty for rows without a menu (lines).
"""
function tree_menu(app, row::TreeRow)::Vector{MenuItem}
    snap = app.snap
    snap === nothing && return MenuItem[]
    kind, id, sub = row_target(row)
    open_import = (a, cmd) -> run_command!(a, cmd.id)
    export_on = (a, cmd) -> (cmd.enabled(a) === nothing && request!(a, OpenExport(cmd.id, id)); nothing)
    sep = menu_separator()
    items = MenuItem[]
    if kind === :databases
        append!(items, split_items(app, "import.database", open_import))
    elseif kind === :grids
        append!(items, split_items(app, "import.grid", open_import))
    elseif kind in (:database, :grid) && row.dim
        push!(items, rename_item_item(kind, id, "", row.label), remove_item_item(app, kind, id))
    elseif kind === :database
        foreach(x -> x === nothing || push!(items, x),
            (tool_item(app, "database.statistics", id), tool_item(app, "database.channel_math", id)))
        append!(items, split_items(app, "export.database", export_on))
        push!(items, sep, rename_item_item(kind, id, "", row.label), remove_item_item(app, kind, id))
    elseif kind === :grid
        foreach(x -> x === nothing || push!(items, x),
            (tool_item(app, "grid.statistics", id; label = "Grid Statistics..."),
             tool_item(app, "grid.set_crs", id; label = "Set Coordinate System...")))
        push!(items, sep)
        append!(items, split_items(app, "export.grid", export_on))
        push!(items, sep, rename_item_item(kind, id, "", row.label), remove_item_item(app, kind, id))
    elseif kind === :lines
        for cid in ("database.select_all_lines", "database.select_no_lines")
            cmd = find_command(app, cid)
            cmd === nothing && continue
            push!(items, MenuItem(cmd.name; icon = cmd.icon, help = cmd.help, id = cmd.id,
                action = a -> (a.ui.current_db = id; run_command!(a, cid))))
        end
    elseif kind === :channel
        v = get(snap.databases, id, nothing)
        c = v === nothing ? nothing : findfirst(x -> x.name == sub, v.channels)
        c === nothing && return items
        ch = v.channels[c]
        x = tool_item(app, "database.statistics", id; values = Dict{String,Any}("channel" => sub))
        x === nothing || push!(items, x)
        push!(items, MenuItem("Channel Properties..."; icon = "props",
            action = a -> open_channel_properties!(a, id, sub)))
        flag = !ch.protected
        push!(items, MenuItem(flag ? "Protect" : "Unprotect"; icon = flag ? "lock" : "unlock",
            action = a -> submit!(a, (flag ? "Protect " : "Unprotect ") * sub,
                s -> Core.set_channel_protected!(s, id, sub, flag))))
        push!(items, sep, rename_item_item(:channel, id, sub, sub))
        dbname = item_name(snap, id)
        push!(items, MenuItem("Delete Channel..."; icon = "channelDel", danger = true,
            action = a -> confirm!(a, "Delete channel $sub?",
                "The channel and its values leave $dbname. It can be undone.";
                action = "Delete", danger = true,
                on_yes = b -> submit!(b, "Delete channel $sub", s -> Core.delete_channel!(s, id, sub)))))
    elseif kind === :pair
        v = get(snap.databases, id, nothing)
        k = v === nothing ? nothing : findfirst(q -> pair_sub(q) == sub, v.pairs)
        k === nothing && return items
        q = v.pairs[k]
        x = tool_item(app, "coordinates.set_current", id; label = "Set as Current")
        x === nothing || push!(items, x)
        push!(items, MenuItem("Remove Pair"; icon = "trash",
            action = a -> submit!(a, "Remove pair " * pair_label(q), s -> Core.remove_pair!(s, id, q.x, q.y))))
    end
    return items
end

# --- Drawing ---

const TREE_ROW_H = 26
const TREE_PAD = 4          # `.tree` padding at the top and bottom
const TREE_WHEEL = 100      # px a wheel step scrolls, as Chromium
const PROPS_HEAD_H = 28
const PROPS_KEY_W = 96
const PROPS_ROW_H = 15      # 12 px text, line height 1.25
const PROPS_ROW_GAP = 4
const PROPS_MAX = 0.46      # of the pane body
const FOOT_H = 44           # 8 + 28 + 8, under a 1 px line
const FILTER_HINT = "Filter items, lines and channels"

# The height of the Properties key-value grid with `n` rows: padding 8 and 4.
props_grid_h(scale::Real, n::Integer) =
    fpx(scale, 8 + 4) + n * fpx(scale, PROPS_ROW_H) + max(n - 1, 0) * fpx(scale, PROPS_ROW_GAP)

"""
    draw_data_tab(app, dl, body)

The Data tab in the pane body `body`: the tree, the Properties panel of the selected row
under it (at most 46 % of the body) and the filter box at the bottom.
"""
function draw_data_tab(app, dl, body::Box)
    s = app.window.scale
    hl = hairline(s)
    snap = app.snap
    foot = Box(body.x0, rnd(body.y1 - hl - fpx(s, FOOT_H)), body.x1, body.y1)
    props = snap === nothing ? nothing : properties(snap, app.ui.selected)
    bottom = foot.y0
    if props !== nothing
        natural = hl + fpx(s, PROPS_HEAD_H) + props_grid_h(s, length(props.rows))
        bottom = rnd(foot.y0 - min(natural, PROPS_MAX * height(body)))
        draw_properties(app, dl, Box(body.x0, bottom, body.x1, foot.y0), props)
    end
    view = Box(body.x0, body.y0, body.x1, bottom)
    if snap === nothing
        app.ui.tree_drawn = 0
    else
        draw_tree(app, dl, view, cached_tree_rows!(app))
    end
    draw_filter(app, dl, foot)
    return nothing
end

"""
    draw_tree(app, dl, view, rows)

The tree rows in `view`, scrolled by `app.ui.tree_scroll`. Only the rows in view are drawn
and take input. Keys work while the tree has the focus (the last click was on it).
"""
function draw_tree(app, dl, view::Box, rows::Vector{TreeRow})
    s = app.window.scale
    ui = app.ui
    row_h = fpx(s, TREE_ROW_H)
    pad = fpx(s, TREE_PAD)
    content = 2 * pad + length(rows) * row_h
    picked = ui.selected
    sel_key = picked === nothing ? nothing : row_key(picked...)
    sel = sel_key === nothing ? nothing : findfirst(r -> r.key == sel_key, rows)
    if ui.tree_reveal && sel !== nothing
        top = pad + (sel - 1) * row_h - ui.tree_scroll
        top < 0 && (ui.tree_scroll += top)
        top + row_h > height(view) && (ui.tree_scroll += top + row_h - height(view))
    end
    ui.tree_reveal = false
    mouse = unsafe_load(ig.GetIO().MousePos)
    clicked_any = ig.IsMouseClicked(0) || ig.IsMouseClicked(1)
    # A click elsewhere takes the keys from the tree; a click on its context menu does not.
    clicked_any && !inside(view, mouse.x, mouse.y) && !inside_menu(app, mouse.x, mouse.y) &&
        (ui.tree_focused = false)
    ui.tree_view = view

    ig.PushID("tree")
    ui.tree_scroll, bar = scroll_area!(app, "scrollbar", view, content, ui.tree_scroll)
    right = view.x1 - (bar ? fpx(s, SCROLLBAR_W) : 0f0)
    ig.PushClipRect((view.x0, view.y0), (right, view.y1), true)
    range = visible_rows(length(rows), row_h, ui.tree_scroll - pad, height(view))
    for k in range
        y = view.y0 + pad + (k - 1) * row_h - ui.tree_scroll
        draw_tree_row(app, dl, rows[k], Box(view.x0, y, right, y + row_h), k == sel)
    end
    ui.tree_drawn = length(range)
    empty = tree_empty_text(ui.filter, rows)
    if empty !== nothing   # in the first row's place, centred, as the central empty state
        tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, empty)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, view.x0 + (width(view) - tw) / 2,
            view.y0 + pad + row_h / 2, u32(app.tokens.text_dim), empty)
    end
    ig.PopClipRect()
    ig.PopID()
    # The context menu belongs to the selected row. It stays open while the tree draws
    # that row's menu, and its rows follow the snapshot (Protect becomes Unprotect).
    m = ui.menu
    if m isa OpenMenu && m.owner == "tree"
        picked = ui.selected
        k = picked === nothing ? nothing : findfirst(r -> r.key == row_key(picked...), rows)
        items = k === nothing ? MenuItem[] : tree_menu(app, rows[k])
        isempty(items) || keep_menu!(app, "tree", m.anchor; items)
    end
    tree_keys!(app, rows, sel, view)
    return nothing
end

# The arrow keys, Enter and the menu key, while the tree has the focus.
function tree_keys!(app, rows::Vector{TreeRow}, sel::Union{Nothing,Int}, view::Box)
    ui = app.ui
    (ui.tree_focused && isempty(ui.dialogs) && ui.menu === nothing && ui.search === nothing) ||
        return nothing
    unsafe_load(ig.GetIO()).WantTextInput && return nothing
    io = unsafe_load(ig.GetIO())
    pressed(k) = ig.IsKeyPressed(k, true)
    for (key, delta) in ((lib.ImGuiKey_DownArrow, 1), (lib.ImGuiKey_UpArrow, -1))
        pressed(key) || continue
        k = next_row(rows, sel === nothing ? nothing : rows[sel].key, delta)
        k === nothing && return nothing
        select_row!(app, rows[k])
        ui.tree_reveal = true
        return nothing
    end
    sel === nothing && return nothing
    row = rows[sel]
    open = !isempty(strip(ui.filter)) || row.key in ui.expanded
    if pressed(lib.ImGuiKey_RightArrow) && has_children(row) && !open
        push!(ui.expanded, row.key)
    elseif pressed(lib.ImGuiKey_LeftArrow) && has_children(row) && open
        delete!(ui.expanded, row.key)
    elseif ig.IsKeyPressed(lib.ImGuiKey_Enter, false) || ig.IsKeyPressed(lib.ImGuiKey_KeypadEnter, false)
        default_action!(app, row)
    elseif ig.IsKeyPressed(lib.ImGuiKey_Menu, false) ||
            (io.KeyShift && !io.KeyCtrl && !io.KeyAlt && ig.IsKeyPressed(lib.ImGuiKey_F10, false))
        s = app.window.scale
        y = view.y0 + fpx(s, TREE_PAD) + sel * fpx(s, TREE_ROW_H) - ui.tree_scroll
        open_tree_menu!(app, row, view.x0 + fpx(s, 40), y)
    end
    return nothing
end

# Open the context menu of `row` at the device point (x, y), when it has one.
function open_tree_menu!(app, row::TreeRow, x::Real, y::Real)
    items = tree_menu(app, row)
    isempty(items) && return nothing
    open_menu!(app, "tree", Box(x, y, x, y), items; gap = 0)
    return nothing
end

"""
    draw_tree_row(app, dl, row, b, selected)

One tree row in box `b` (26 px), as the prototype's `.trow`: the hover or selection fill
inset 4 px with radius 5, the chevron (14 px, 9 + 16 per level in), the checkbox of a
line, the 16 px icon, the name (cut with "..." to fit), the tag and the right text.
"""
function draw_tree_row(app, dl, row::TreeRow, b::Box, selected::Bool)
    s = app.window.scale
    t = app.tokens
    ui = app.ui
    f(v) = fpx(s, v)
    hl = hairline(s)
    mid = centre_y(b)
    folder = row.kind in (:databases, :grids, :lines, :channels)

    # Where the parts go: chevron, checkbox, icon, name; from the right the count text
    # (8 px before it) and the tag (6 px before it). The name ends where they start.
    chev = Box(b.x0 + f(9 + 16 * row.depth), b.y0, b.x0 + f(9 + 16 * row.depth + 14), b.y1)
    kids = has_children(row)
    open = kids && (!isempty(strip(ui.filter)) || row.key in ui.expanded)
    cbox = row.checkbox === nothing ? nothing : Box(chev.x1 + f(4), mid - f(7), chev.x1 + f(4 + 14), mid + f(7))
    ix = (cbox === nothing ? chev.x1 : cbox.x1) + f(4)
    name_x = ix + f(16 + 8)
    edge = b.x1 - f(8)
    cw = isempty(row.right) ? 0f0 : text_width(FONT_REGULAR, 12, row.right)
    isempty(row.right) || (edge -= cw + f(8))
    tag = nothing
    if !isempty(row.tag)
        tw = text_width(FONT_REGULAR, 10.5, row.tag)
        tag = snap(Box(edge - tw - f(8) - 2 * hl, mid - f(8), edge, mid + f(8)))
        edge = tag.x0 - f(6)
    end
    role = row.bold ? FONT_SEMIBOLD : FONT_REGULAR
    name = elide(text_width, row.label, max(edge - name_x, 0f0); role)

    ig.PushID(row.key)
    # The row's button comes first and owns the row: hover, tooltip, right click and
    # selection. The chevron and checkbox lie on top of it and take their own clicks.
    clicked, hovered, _ = hit("row", b; overlap = true)
    on_row = ig.IsItemHovered()   # not on the chevron or checkbox
    name != row.label && item_tip!(app, row.label; hovered)
    if kids && first(hit("chevron", chev))
        toggle_open!(app, row.key)
        select_row!(app, row)
        ui.tree_focused = true
    end
    if cbox !== nothing && first(hit("check", Box(cbox.x0, b.y0, cbox.x1, b.y1)))
        set_line_checked!(app, row, !(row.checkbox::Bool))
        select_row!(app, row)
        ui.tree_focused = true
    end
    if clicked
        select_row!(app, row)
        ui.tree_focused = true
        folder && toggle_open!(app, row.key)
    end
    on_row && !folder && ig.IsMouseDoubleClicked(0) && default_action!(app, row)
    if hovered && ig.IsMouseClicked(1)
        select_row!(app, row)
        ui.tree_focused = true
        mouse = unsafe_load(ig.GetIO().MousePos)
        open_tree_menu!(app, row, mouse.x, mouse.y)
    end
    ig.PopID()

    fill = selected ? t.selection : hovered ? t.hover : nothing
    if fill !== nothing
        bg = snap(Box(b.x0 + f(4), b.y0 + f(1), b.x1 - f(4), b.y1 - f(1)))
        ig.AddRectFilled(dl, (bg.x0, bg.y0), (bg.x1, bg.y1), u32(fill), f(5))
    end
    kids && draw_icon(dl, open ? "chevDown" : "chevRight", (rnd(chev.x0), rnd(mid - f(7))), 14; style = :dim)
    cbox === nothing || draw_checkbox(app, dl, snap(cbox), row.checkbox::Bool)
    draw_icon(dl, row.icon, (rnd(ix), rnd(mid - f(8))), 16)
    isempty(row.right) || draw_text_mid(dl, FONT_REGULAR, 12, b.x1 - f(8) - cw, mid, u32(t.text_dim), row.right)
    if tag !== nothing
        ig.AddRect(dl, (tag.x0, tag.y0), (tag.x1, tag.y1), u32(t.border), f(4), hl)
        draw_text_mid(dl, FONT_REGULAR, 10.5, tag.x0 + hl + f(4), centre_y(tag), u32(t.text_dim), row.tag;
            line = 14 / 10.5)
    end
    draw_text_mid(dl, role, BODY_FONT_SIZE, name_x, mid, u32(row.dim ? t.text_disabled : t.text), name;
        italic = row.italic)
    return nothing
end

# A line's checkbox (14 px, radius 3): `input` with an `input_border` frame, or `accent`
# with a white tick, as the prototype's checked `input[type=checkbox]`.
function draw_checkbox(app, dl, b::Box, checked::Bool)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    r = fpx(s, 3)
    if checked
        ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.accent), r)
        # The prototype's tick: M3 7 l3 3 5-6 in a 14 px box drawn 1 px up and left.
        pt(x, y) = (b.x0 + fpx(s, x - 1), b.y0 + fpx(s, y - 1))
        w = fpx(s, 1.8)
        ig.AddLine(dl, pt(3, 7), pt(6, 10), u32(t.on_accent), w)
        ig.AddLine(dl, pt(6, 10), pt(11, 4), u32(t.on_accent), w)
    else
        ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.input), r)
        ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.input_border), r, hl)
    end
    return nothing
end

"""
    draw_properties(app, dl, b, props)

The Properties panel in `b`: a 1 px line on top, the 28 px header "PROPERTIES: <TITLE>"
(11 px semibold, upper case, letter spacing 0.02 em) and the key-value grid (12 px text,
96 px key column, 10 px gap, rows 15 high and 4 apart). It scrolls when it is cut.
A value shows its full text in a tooltip.
"""
function draw_properties(app, dl, b::Box, props::PropsView)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.pane))
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y0 + hl), u32(t.border))
    head = Box(b.x0, b.y0 + hl, b.x1, rnd(b.y0 + hl + f(PROPS_HEAD_H)))
    ig.AddRectFilled(dl, (head.x0, head.y0), (head.x1, head.y1), u32(t.pane_header))
    ig.AddRectFilled(dl, (head.x0, head.y1 - hl), (head.x1, head.y1), u32(t.border))
    spacing = f(11 * 0.02)
    measure = (role, size, text) -> spaced_width(role, size, text, spacing)
    title = elide(measure, uppercase("Properties: " * props.title), width(head) - f(20);
        role = FONT_SEMIBOLD, size = 11)
    draw_spaced_text(dl, FONT_SEMIBOLD, 11, head.x0 + f(10), centre_y(head) - hl / 2, u32(t.text_dim),
        title, spacing)

    view = Box(b.x0, head.y1, b.x1, b.y1)
    n = length(props.rows)
    ig.PushID("props")
    app.ui.props_scroll, bar = scroll_area!(app, "scrollbar", view, props_grid_h(s, n), app.ui.props_scroll)
    right = view.x1 - (bar ? fpx(s, SCROLLBAR_W) : 0f0)
    ig.PushClipRect((view.x0, view.y0), (right, view.y1), true)
    key_x = view.x0 + f(12)
    val_x = key_x + f(PROPS_KEY_W + 10)
    val_w = max(right - f(12) - val_x, 0f0)
    for (k, (key, value)) in enumerate(props.rows)
        y = view.y0 + f(8) + (k - 1) * f(PROPS_ROW_H + PROPS_ROW_GAP) - app.ui.props_scroll
        y + f(PROPS_ROW_H) < view.y0 && continue
        y > view.y1 && break
        mid = y + f(PROPS_ROW_H) / 2
        draw_text_mid(dl, FONT_REGULAR, 12, key_x, mid, u32(t.text_dim),
            elide(text_width, key, f(PROPS_KEY_W); size = 12))
        draw_text_mid(dl, FONT_REGULAR, 12, val_x, mid, u32(t.text), elide(text_width, value, val_w; size = 12))
        _, hovered, _ = hit("value$k", Box(val_x, y, val_x + max(val_w, 1f0), y + f(PROPS_ROW_H)))
        hovered && item_tip!(app, isempty(key) ? "Positions" : key; help = value)
    end
    ig.PopClipRect()
    ig.PopID()
    return nothing
end

"""
    draw_filter(app, dl, foot)

The filter box at the bottom of the Data tab, as the prototype's `.foot .search`: a 1 px
line on top, then 8 px padding around a 28 px `search_box!` with the text field "Filter
items, lines and channels". Typing filters the tree; Esc clears it.
"""
function draw_filter(app, dl, foot::Box)
    s = app.window.scale
    t = app.tokens
    ui = app.ui
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.AddRectFilled(dl, (foot.x0, foot.y0), (foot.x1, foot.y1), u32(t.pane))
    ig.AddRectFilled(dl, (foot.x0, foot.y0), (foot.x1, foot.y0 + hl), u32(t.border))
    box = snap(Box(foot.x0 + f(8), foot.y0 + hl + f(8), foot.x1 - f(8), foot.y0 + hl + f(8 + 28)))
    text, _ = search_box!(app, dl, box, "##Filter", ui.filter_buffer, FILTER_HINT;
        flags = Int(lib.ImGuiInputTextFlags_EscapeClearsAll))
    if text != ui.filter
        ui.filter = text
        ui.tree_scroll = 0f0
    end
    return nothing
end
