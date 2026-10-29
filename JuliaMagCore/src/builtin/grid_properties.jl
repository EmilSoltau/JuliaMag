# Grid properties (spec 5.4, 13.4; research 4.3 "Properties").
#
# - `set_grid_crs!`: set the coordinate system of a grid ("Modify Coordinate System").
# - `set_grid_georef!`: move a grid: origin, cell sizes and rotation (Properties "Modify").
# - `set_grid_style!`: save a style as the grid's default ("Save as grid default").
# - Tool `grid.set_crs`: the quick tool for `set_grid_crs!`.
#
# Each edit changes `grid.json` only, never the values. It runs under `s.lock`,
# refuses a busy grid with `ItemBusyError` (an export reads it), saves
# `grid.json` atomically, pushes an undo step and is recorded in the history.
# A tool run is recorded by `run_tool`, so the tool uses the edit without its record.

const GRID_INPUT = ["grid" => ITEM_GRID]

"""
The grid of tool input `id`, opened. Call it under `s.lock`.
Throws `ToolError` when the item is missing, not a grid, busy or broken.
With `allow_readers = true`, an item that readers (such as exports) use is not
busy: use it for tools that only read, and mark the item with `mark_reading!`
under the same lock.
"""
function tool_grid(s::Session, id::AbstractString; allow_readers::Bool = false)::Grid
    k = findfirst(i -> i.id == id, s.project.items)
    k === nothing && throw(ToolError("There is no item $id in the project."))
    s.project.items[k].kind == ITEM_GRID || throw(ToolError("Item $id is not a grid."))
    m = get(s.busy, id, nothing)
    (m === nothing || (allow_readers && readers_allowed(m))) ||
        throw(ToolError("Grid $id is busy: $(busy_reason(m))."))
    try
        return grid(s.project, id)
    catch e
        e isa Union{ProjectError,GridError} || rethrow()
        throw(ToolError("Grid $id cannot be opened: $(e.msg)"))
    end
end

"""
Change the metadata of grid `id` to `new` with `setter!(g, value)`, save
`grid.json`, and push an undo step that puts back the value `getter(g)` had.
Throws `ItemBusyError` when the grid is busy, before anything changes.
"""
function edit_grid_meta!(getter::Function, setter!::Function, s::Session, id::AbstractString, label::String, new)
    key = String(id)
    lock(s.lock) do
        check_not_busy(s, key)
        old = getter(grid(s.project, key))
        apply(v) = () -> lock(s.lock) do       # `undo!` runs it without the lock
            g = grid(s.project, key)
            setter!(g, v)
            save_grid_meta(g)
            nothing
        end
        step = UndoStep(label, apply(old), apply(new), () -> nothing, [key])
        step.redo()
        push_undo!(s, step)
    end
    return nothing
end

# ---- coordinate system -----------------------------------------------------

"Set the coordinate system of grid `id` to `code` (checked already). Undoable, not recorded."
change_grid_crs!(s::Session, id::AbstractString, code::String) =
    edit_grid_meta!(g -> g.crs, (g, v) -> (g.crs = v), s, id, "set coordinate system of grid $id", code)

"""
    set_grid_crs!(s, id, crs)

Set the coordinate system of grid `id`, such as `"EPSG:32633"`. Blank means
unknown. Changes `grid.json` only. Undoable and recorded as `"grid.set_crs"`.
Throws `ArgumentError` for a code PROJ does not know, and `ItemBusyError` while
an import or an export uses the grid.
"""
function set_grid_crs!(s::Session, id::AbstractString, crs::AbstractString)
    code = String(strip(crs))
    isempty(code) || valid_crs(code) || throw(ArgumentError("coordinate system \"$code\" is not known"))
    lock(s.lock) do
        change_grid_crs!(s, id, code)
        record!(s, "grid.set_crs", Dict{String,Any}("item" => String(id), "crs" => code))
    end
    return nothing
end

# ---- georeference ----------------------------------------------------------

const GEOREF_FIELDS = (:x0, :y0, :dx, :dy, :rotation)

"""
    set_grid_georef!(s, id; x0, y0, dx, dy, rotation)

Move grid `id`: set the centre of its lower-left cell (`x0`, `y0`), its cell
sizes (`dx`, `dy`) and its rotation (degrees counter-clockwise about `x0, y0`).
Each keyword is optional; the others stay. The values do not change.
Undoable and recorded as `"grid.set_georef"` with the given keywords.
Throws `ArgumentError` for a value that is not finite or a cell size that is
not above 0, and `ItemBusyError` while an import or an export uses the grid.
"""
function set_grid_georef!(s::Session, id::AbstractString; x0::Union{Nothing,Real} = nothing,
                          y0::Union{Nothing,Real} = nothing, dx::Union{Nothing,Real} = nothing,
                          dy::Union{Nothing,Real} = nothing, rotation::Union{Nothing,Real} = nothing)
    given = Dict{Symbol,Float64}()
    for (k, v) in zip(GEOREF_FIELDS, (x0, y0, dx, dy, rotation))
        v === nothing && continue
        isfinite(v) || throw(ArgumentError("$k must be a finite number, not $v"))
        k in (:dx, :dy) && v <= 0 && throw(ArgumentError("$k must be above 0, not $v"))
        given[k] = Float64(v)
    end
    georef(g) = Tuple(getfield(g, k) for k in GEOREF_FIELDS)
    set_georef!(g, v) = foreach((k, x) -> setfield!(g, k, x), GEOREF_FIELDS, v)
    lock(s.lock) do
        check_not_busy(s, id)
        old = georef(grid(s.project, id))
        new = Tuple(get(given, k, o) for (k, o) in zip(GEOREF_FIELDS, old))
        edit_grid_meta!(georef, set_georef!, s, id, "move grid $id", new)
        record!(s, "grid.set_georef",
                merge(Dict{String,Any}("item" => String(id)), Dict{String,Any}(String(k) => v for (k, v) in given)))
    end
    return nothing
end

# ---- style -----------------------------------------------------------------

const STYLE_METHODS = (:linear, :histeq, :normal, :loglinear)

"A copy of a style."
copy_style(st::GridStyle) = GridStyle((getfield(st, f) for f in fieldnames(GridStyle))...)

"""
    set_grid_style!(s, id, style)

Make `style` the default style of grid `id` ("Save as grid default"). The style
is copied. Undoable and recorded as `"grid.set_style"` with the style's fields.
Throws `ArgumentError` for an unknown method or a shading number that is not
finite, and `ItemBusyError` while an import or an export uses the grid.
"""
function set_grid_style!(s::Session, id::AbstractString, style::GridStyle)
    style.method in STYLE_METHODS ||
        throw(ArgumentError("the colour method must be one of $(join(STYLE_METHODS, ", ")), not $(style.method)"))
    for (k, v) in (("azimuth", style.azimuth), ("altitude", style.altitude), ("zfactor", style.zfactor))
        isfinite(v) || throw(ArgumentError("$k must be a finite number, not $v"))
    end
    new = copy_style(style)
    lock(s.lock) do
        edit_grid_meta!(g -> copy_style(g.style), (g, v) -> (g.style = copy_style(v)), s, id,
                        "set the style of grid $id", new)
        args = Dict{String,Any}("item" => String(id))
        for f in fieldnames(GridStyle)
            v = getfield(new, f)
            args[String(f)] = v isa Symbol ? String(v) : v
        end
        record!(s, "grid.set_style", args)
    end
    return nothing
end

"The script text of a `GridStyle` from the args of a `\"grid.set_style\"` entry."
function style_text(a::AbstractDict)::String
    parts = String[]
    for (f, T) in zip(fieldnames(GridStyle), fieldtypes(GridStyle))
        v = a[String(f)]
        push!(parts, T === Symbol ? repr(Symbol(v)) : repr(T(v)))
    end
    return "GridStyle(" * join(parts, ", ") * ")"
end

# ---- the tool --------------------------------------------------------------

function run_grid_set_crs(s::Session, ins::Dict{String,String}, st::Dict{String,Any}, _, report::IO)
    id = ins["grid"]
    code = String(strip(st["crs"]))
    isempty(code) || check_crs(code)
    lock(s.lock) do
        tool_grid(s, id)
        change_grid_crs!(s, id, code)
        name = item(s.project, id).name
        print(report, "Grid ", name, isempty(code) ? " has no coordinate system now." : " is now in $(crs_text(code)).")
    end
    return nothing
end

register_tool!(ToolSpec("grid.set_crs", "Set grid coordinate system",
    "Set the coordinate system of a grid. Only the metadata changes; the values stay.",
    "crs", [Place(COORDINATES_TAB, "Coordinate system"), Place("Grid and Image", "Properties")], GRID_INPUT,
    SettingSpec[CRSSetting("crs", "Coordinate system"; help = "Such as EPSG:32633. Blank means unknown.")],
    :quick, run_grid_set_crs))
