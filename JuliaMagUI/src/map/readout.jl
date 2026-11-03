# The point readout and the pick of the shared cursor: what the shown map has at a world
# point, from the loaded layer data only. On the render thread, with no I/O. The status bar
# shows the readout (`map_status`); a click on the map moves the shared cursor (`pick_cursor!`).

"""
    MapHover

What the shown map has under the pointer, at the world point `(x, y)`.

- `grids`: `(name, value, units)` of each visible grid layer with data, top first. The value
  is `NaN` where the grid has none (see `grid_value`).
- `near`: the nearest point of a visible line layer within `PICK_RADIUS` px, or `nothing`.
  `near_item` is its database, `near_channel` its layer's colour channel (`""` for none),
  `near_line` the id of its line.
- `version`: counts the changes, so the status texts are made again only after one.

`map_hover` changes the one `MapHover` of the app (`ui.hover_buf`) in place, so the mouse
moving over the map allocates nothing.
"""
mutable struct MapHover
    x::Float64
    y::Float64
    grids::Vector{Tuple{String,Float32,String}}
    near::Union{Nothing,NearPoint}
    near_item::String
    near_channel::String
    near_line::Core.LineId
    version::Int
end

MapHover() = MapHover(NaN, NaN, Tuple{String,Float32,String}[], nothing, "", "", Core.LineId(Core.LINE, 0, 0), 0)

"The texts `map_status` made last, and the snapshot, map and hover version they were made from."
mutable struct MapStatusCache
    snap::Any
    map::String
    hover::Int   # the hover's version, -1 for no hover
    texts::NTuple{3,String}
end

MapStatusCache() = MapStatusCache(nothing, "", -1, ("", "", ""))

"""
    map_hover(app, x, y) -> MapHover

What the shown map has at world point `(x, y)`: every visible grid layer, top first, with
`grid_value` (`nearest` when the layer's resample is `:nearest`), and the nearest point of any
visible line layer within `PICK_RADIUS` logical px (`nearest_on_map`). It becomes `ui.hover`.
Its `version` goes up when anything in it changed. Allocates nothing after warm-up.
"""
function map_hover(app, x::Real, y::Real)::MapHover
    ui = app.ui
    h = ui.hover_buf
    ui.hover = h
    snap = app.snap
    id = ui.current_map
    changed = !(isequal(h.x, Float64(x)) && isequal(h.y, Float64(y)))
    h.x = x
    h.y = y
    n = 0
    k, np = 0, NO_POINT
    if snap !== nothing && haskey(snap.maps, id)
        mv = snap.maps[id]
        ms = app.map
        refresh_plan!(ms, app, mv)
        plan = ms.plan
        for i in length(plan):-1:1
            p = plan[i]
            e = p.entry
            (p.layer.kind == :grid && e !== nothing) || continue
            d = e.data
            d isa GridLayerData || continue
            isempty(d.levels) && continue
            v = grid_value(d, x, y; nearest = plan_style(app, p).resample === :nearest)
            # Not `get`: its `Union` result boxes the grid view.
            units = haskey(snap.grids, p.layer.item) ? snap.grids[p.layer.item].units : ""
            g = (item_name(snap, p.layer.item), v, units)
            n += 1
            if n > length(h.grids)
                push!(h.grids, g)
                changed = true
            elseif !isequal(h.grids[n], g)
                h.grids[n] = g
                changed = true
            end
        end
        k, np = nearest_on_map(app, mv, x, y)
    end
    if n < length(h.grids)
        resize!(h.grids, n)
        changed = true
    end
    if k == 0
        h.near === nothing || (h.near = nothing; changed = true)
    else
        p = app.map.plan[k]
        line = ((p.entry::LayerEntry).data::LineLayerData).points.lines[np.line]
        if !(isequal(h.near, np) && h.near_item == p.layer.item && h.near_channel == p.layer.channel && h.near_line == line)
            h.near = np
            h.near_item = p.layer.item
            h.near_channel = p.layer.channel
            h.near_line = line
            changed = true
        end
    end
    changed && (h.version += 1)
    return h
end

"The pointer is off the map: no hover."
clear_hover!(app) = (app.ui.hover = nothing; nothing)

# No point: what `nearest_on_map` returns with layer 0.
const NO_POINT = NearPoint(0, 0, NaN, NaN, NaN32, Inf)

"""
    nearest_on_map(app, mv, x, y) -> (k, point)

The nearest point to world point `(x, y)` of the visible line layers of map `mv` within
`PICK_RADIUS` logical px at its camera: the index `k` of its layer in `app.map.plan` and the
`NearPoint`; `(0, NO_POINT)` when there is none or the map has no camera. The upper layer wins a tie.
"""
function nearest_on_map(app, mv, x::Real, y::Real)::Tuple{Int,NearPoint}
    ms = app.map
    st = get(ms.views, mv.id, nothing)
    (st === nothing || st.camera === nothing) && return 0, NO_POINT
    w = app.window
    radius = PICK_RADIUS * (w === nothing ? 1.0 : Float64(w.scale)) * st.camera.res
    best, bk = NO_POINT, 0
    for (k, p) in enumerate(ms.plan)
        e = p.entry
        (p.layer.kind == :lines && e !== nothing) || continue
        d = e.data
        d isa LineLayerData || continue
        q = nearest_point(d, x, y, radius)
        q === nothing && continue
        if q.dist <= best.dist
            best = q
            bk = k
        end
    end
    return bk, best
end

"""
    pick_cursor!(app, mv, x, y) -> Bool

A click on map `mv` at world point `(x, y)`: move the shared cursor to the nearest line point
within `PICK_RADIUS` px (`nearest_on_map`) through the worker, labelled "Move the cursor".
Returns false, and the cursor stays, when no point is that near.
"""
function pick_cursor!(app, mv, x::Real, y::Real)::Bool
    refresh_plan!(app.map, app, mv)
    k, np = nearest_on_map(app, mv, x, y)
    k == 0 && return false
    p = app.map.plan[k]
    db = p.layer.item
    line = ((p.entry::LayerEntry).data::LineLayerData).points.lines[np.line]
    row = np.row
    submit!(app, "Move the cursor", s -> Core.set_cursor!(s, Core.Cursor(db, line, row)))
    return true
end

# --- The status texts ---

"""
    map_status(app) -> NTuple{3,String}

The status bar texts of the shown map: its coordinate system's name (or "No coordinate
system"), the pointer (`pointer_text`, or `"X -  Y -"` off the map) and the readout of
`ui.hover`, two spaces between its parts: each grid as `"TMI 12.35 nT"` (`"TMI -"` where it
has no value), then the line point as `"L1002 fid 0.3 MAG 203.00"`. Made again only when the
snapshot, the map or the hover changed; else the same texts, with no allocation.
"""
function map_status(app)::NTuple{3,String}
    ui = app.ui
    c = ui.map_status
    snap = app.snap
    id = ui.current_map
    h = ui.hover
    version = h === nothing ? -1 : h.version
    (c.snap === snap && c.map == id && c.hover == version) && return c.texts
    texts = (snap === nothing || !haskey(snap.maps, id)) ? ("", "X -  Y -", "") :
        map_texts(snap, snap.maps[id], h)
    c.snap = snap
    c.map = id
    c.hover = version
    c.texts = texts
    return texts
end

function map_texts(snap, mv, h::Union{Nothing,MapHover})::NTuple{3,String}
    info = get(snap.crs, mv.crs, nothing)
    crs = isempty(mv.crs) ? "No coordinate system" : info === nothing || isempty(info.name) ? mv.crs : info.name
    h === nothing && return (crs, "X -  Y -", "")
    io = IOBuffer()
    for (name, v, units) in h.grids
        position(io) > 0 && print(io, "  ")
        print(io, name, " ", isnan(v) ? "-" : fmt_num(v, 2))
        isnan(v) || isempty(units) || print(io, " ", units)
    end
    np = h.near
    np === nothing || near_text(io, snap, h, np)
    return (crs, pointer_text(h.x, h.y, info === nothing ? "" : info.unit), String(take!(io)))
end

# The line point of the readout: "L1002 fid 0.3 MAG 203.00", the value with the channel's
# decimals (2 when not set). Nothing when the database is not in the snapshot.
function near_text(io::IO, snap, h::MapHover, np::NearPoint)
    v = get(snap.databases, h.near_item, nothing)
    v === nothing && return nothing
    k = findfirst(l -> l.id == h.near_line, v.lines)
    k === nothing && return nothing
    l = v.lines[k]
    position(io) > 0 && print(io, "  ")
    print(io, l.name, " fid ", fmt_num(l.fid_start + (np.row - 1) * l.fid_step, 1))
    isempty(h.near_channel) && return nothing
    c = findfirst(ch -> ch.name == h.near_channel, v.channels)
    decimals = c === nothing || v.channels[c].decimals < 0 ? 2 : v.channels[c].decimals
    print(io, " ", h.near_channel, " ", isnan(np.value) ? "-" : fmt_num(np.value, decimals))
    return nothing
end

"""
    pointer_text(x, y, unit) -> String

The pointer as `"X 500,123.4  Y 7,000,056.1"`: 1 decimal, or 6 for a unit of `deg`.
"""
function pointer_text(x::Real, y::Real, unit::AbstractString)::String
    d = unit == "deg" ? 6 : 1
    return string("X ", fmt_num(x, d), "  Y ", fmt_num(y, d))
end
