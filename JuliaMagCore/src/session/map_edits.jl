# Map edits (spec 5.4). Each edit writes `map.json` at once, pushes one undo
# step and is recorded in the history. The edits run under `s.lock`, refuse a
# busy map with `ItemBusyError` and follow `edit_grid_meta!`.
#
# - `new_map!`: a new map item, which undo takes out again.
# - `add_layer!`, `remove_layer!`, `move_layer!`: change the list of layers.
# - `set_layer!`: change the fields of one layer.

"What an edit changes in a map, kept for undo and redo."
struct MapState
    crs::String
    layers::Vector{MapLayer}
    next_layer::Int
end

map_state(m::MapItem) = MapState(m.crs, MapLayer[copy(l) for l in m.layers], m.next_layer)

"Open map `id`, or throw `ArgumentError` when the project has no such map."
function edit_target(s::Session, id::AbstractString)::MapItem
    k = findfirst(i -> i.id == id && i.kind == ITEM_MAP, s.project.items)
    k === nothing && throw(ArgumentError("there is no map $id in the project"))
    return map_item(s.project, id)
end

"""
Put `new` (the state of `m` after the edit) into map `key` as one undo step that goes
back to `old`. Writes `map.json` now. Call it under `s.lock`.
The step changes no data (`UndoStep.data`): a layer reads its own item, not the map.
"""
function push_map_step!(s::Session, key::String, label::String, old::MapState, new::MapState)
    apply(st::MapState) = () -> lock(s.lock) do        # `undo!` runs it without the lock
        m = map_item(s.project, key)
        m.crs = st.crs
        m.layers = MapLayer[copy(l) for l in st.layers]
        m.next_layer = st.next_layer
        save_map(m)
        nothing
    end
    step = UndoStep(label, apply(old), apply(new), () -> nothing, [key]; data = false)
    step.redo()
    push_undo!(s, step)
    return nothing
end

"The layer `id` of `m`, or an `ArgumentError`."
function find_layer(m::MapItem, id::AbstractString)::MapLayer
    k = findfirst(l -> l.id == id, m.layers)
    k === nothing && throw(ArgumentError("map $(basename(m.folder)) has no layer $id"))
    return m.layers[k]
end

# ---- new map -------------------------------------------------------------------

"The name \"Map N\" with the lowest N that no map of the project uses."
function free_map_name(p::Project)::String
    used = Set(i.name for i in p.items if i.kind == ITEM_MAP)
    n = 1
    while "Map $n" in used
        n += 1
    end
    return "Map $n"
end

"""
    new_map!(s; name = "") -> String

Make a map with no layers and return its item id, such as `"map-1"`. A blank name
becomes `"Map N"`, with the lowest N no map uses. Undoable: undo takes the item
out and redo puts it back. Its folder is deleted when the session closes with
the map out. Recorded as `"map.new"`.
"""
function new_map!(s::Session; name::AbstractString = "")::String
    check_open(s)
    p = s.project
    lock(s.lock) do
        check_open(s)
        label = String(strip(name))
        isempty(label) && (label = free_map_name(p))
        id = new_item_id(p, ITEM_MAP)
        rel = "maps/$id"
        create_map(joinpath(p.folder, "maps", id), label)
        it = ProjectItem(id, ITEM_MAP, label, rel, "", "")
        put_in() = lock(s.lock) do                  # `undo!` runs the steps without the lock
            any(i -> i.id == id, p.items) && return nothing
            set_items!(p, vcat(p.items, it))
            nothing
        end
        take_out() = lock(s.lock) do
            set_items!(p, filter(i -> i.id != id, p.items))
            nothing
        end
        # Undo or redo is no longer possible: delete the folder if the map is out.
        free() = lock(() -> remove_unused_folders!(p, [it]), s.lock)
        add_item!(p, it)
        try
            save_project(p)
        catch
            take_out()
            rm(joinpath(p.folder, "maps", id); recursive = true, force = true)
            rethrow()
        end
        push_undo!(s, UndoStep("new map $label", take_out, put_in, free, [id]; commit = free, data = false))
        record!(s, "map.new", Dict{String,Any}("name" => label); outputs = [id])
        return id
    end
end

# ---- layers --------------------------------------------------------------------

# The source of a new layer: its kind, the colour channel, the coordinate system and the
# style it starts with (a grid layer takes its grid's shading).
function layer_source(s::Session, source::AbstractString, channel::Union{Nothing,AbstractString})
    k = findfirst(i -> i.id == source, s.project.items)
    k === nothing && throw(ArgumentError("there is no item $source in the project"))
    it = s.project.items[k]
    if it.kind == ITEM_DATABASE
        db = database(s.project, source)
        db.current_pair == 0 && throw(ArgumentError("database $(it.name) has no current X, Y pair"))
        pair = db.pairs[db.current_pair]
        ch = channel === nothing ? default_colour_channel(db, pair) : check_colour_channel(db, String(channel))
        return :lines, ch, pair.crs, LayerStyle()
    elseif it.kind == ITEM_GRID
        channel === nothing || throw(ArgumentError("a grid layer has no colour channel"))
        g = grid(s.project, source)
        return :grid, "", g.crs, grid_shading(g.style)
    end
    throw(ArgumentError("item $source is not a database or a grid"))
end

"The name of a numeric channel that is not an array, or an `ArgumentError`. `\"\"` is allowed only for `blank_ok`."
function check_colour_channel(db::LineDatabase, name::String; blank_ok::Bool = false)::String
    blank_ok && isempty(name) && return name
    k = findfirst(c -> c.name == name, db.channels)
    k === nothing && throw(ArgumentError("database $(db.name) has no channel $name"))
    c = db.channels[k]
    (c.eltype <: Number && c.arraylen == 1) ||
        throw(ArgumentError("channel $name cannot colour a layer: it must be a numeric channel and not an array"))
    return name
end

"""
    add_layer!(s, map_id, item_id; channel = nothing) -> String

Add a layer for database or grid `item_id` and return its id, such as `"layer-1"`.
A line layer goes on top and colours by `channel`, by default the first channel
`default_colour_channel` finds for the current position pair. A grid layer goes above the
other grid layers and below the line layers, and uses the default colours of its grid; it
starts with the grid's shading (`grid_shading`), which is the layer's own from then on.
When the map has no coordinate system yet, it takes that of the pair or the grid.
Undoable and recorded as `"map.add_layer"`.
Throws `ArgumentError` for an unknown map or item, a channel that is not a numeric
channel, a database with no current pair, or a channel for a grid.
"""
function add_layer!(s::Session, map_id::AbstractString, item_id::AbstractString; channel::Union{Nothing,AbstractString} = nothing)::String
    check_open(s)
    key, src = String(map_id), String(item_id)
    lock(s.lock) do
        check_open(s)
        m = edit_target(s, key)
        check_not_busy(s, key)
        kind, ch, crs, style = layer_source(s, src, channel)
        old = map_state(m)
        layer = MapLayer("layer-$(m.next_layer)", src, kind, ch, true, 1.0, kind == :lines, kind == :lines, style)
        m.next_layer += 1
        if kind == :lines
            push!(m.layers, layer)
        else
            last_grid = findlast(l -> l.kind == :grid, m.layers)
            first_line = findfirst(l -> l.kind == :lines, m.layers)
            at = last_grid !== nothing ? last_grid + 1 : first_line !== nothing ? first_line : length(m.layers) + 1
            insert!(m.layers, at, layer)
        end
        isempty(m.crs) && (m.crs = crs)
        push_map_step!(s, key, "add layer $(layer.id) to $(item(s.project, key).name)", old, map_state(m))
        record!(s, "map.add_layer", Dict{String,Any}("item" => key, "source" => src, "channel" => ch))
        return layer.id
    end
end

"""
    remove_layer!(s, map_id, layer_id)

Take a layer out of the map. Undoable and recorded as `"map.remove_layer"`.
Throws `ArgumentError` for an unknown map or layer.
"""
function remove_layer!(s::Session, map_id::AbstractString, layer_id::AbstractString)
    check_open(s)
    key, lid = String(map_id), String(layer_id)
    lock(s.lock) do
        check_open(s)
        m = edit_target(s, key)
        check_not_busy(s, key)
        find_layer(m, lid)
        old = map_state(m)
        filter!(l -> l.id != lid, m.layers)
        push_map_step!(s, key, "remove layer $lid from $(item(s.project, key).name)", old, map_state(m))
        record!(s, "map.remove_layer", Dict{String,Any}("item" => key, "layer" => lid))
        return nothing
    end
end

"""
    move_layer!(s, map_id, layer_id, position)

Move a layer to index `position` in the draw order (1 is the bottom).
A move to the place the layer has already changes nothing and records nothing.
Undoable and recorded as `"map.move_layer"`.
Throws `ArgumentError` for an unknown map or layer, or a position out of range.
"""
function move_layer!(s::Session, map_id::AbstractString, layer_id::AbstractString, position::Integer)
    check_open(s)
    key, lid = String(map_id), String(layer_id)
    lock(s.lock) do
        check_open(s)
        m = edit_target(s, key)
        check_not_busy(s, key)
        find_layer(m, lid)
        1 <= position <= length(m.layers) ||
            throw(ArgumentError("the position must be from 1 to $(length(m.layers)), not $position"))
        old = map_state(m)
        from = findfirst(l -> l.id == lid, m.layers)
        from == position && return nothing
        insert!(m.layers, Int(position), popat!(m.layers, from))
        push_map_step!(s, key, "move layer $lid in $(item(s.project, key).name)", old, map_state(m))
        record!(s, "map.move_layer", Dict{String,Any}("item" => key, "layer" => lid, "position" => Int(position)))
        return nothing
    end
end

"A style as a dictionary of its fields, with symbols as strings."
function style_dict(st::LayerStyle)::Dict{String,Any}
    d = Dict{String,Any}()
    for f in fieldnames(LayerStyle)
        v = getfield(st, f)
        d[String(f)] = v isa Symbol ? String(v) : v
    end
    return d
end

"""
    set_layer!(s, map_id, layer_id; visible, opacity, channel, labels, own_style, style)

Change the given fields of a layer. The style is copied. A call that changes nothing
pushes no step and records nothing. Undoable and recorded as `"map.set_layer"`
with the given keywords.
Throws `ArgumentError` for an unknown map or layer, an opacity outside 0 to 1, a
channel that is not a numeric channel of the layer's database (`""` is one plain
colour), a channel for a grid layer, a style that `check_style` refuses, or
`own_style = false` for a line layer.
"""
function set_layer!(s::Session, map_id::AbstractString, layer_id::AbstractString;
                    visible::Union{Nothing,Bool} = nothing, opacity::Union{Nothing,Real} = nothing,
                    channel::Union{Nothing,AbstractString} = nothing, labels::Union{Nothing,Bool} = nothing,
                    own_style::Union{Nothing,Bool} = nothing, style::Union{Nothing,LayerStyle} = nothing)
    check_open(s)
    key, lid = String(map_id), String(layer_id)
    opacity === nothing || (isfinite(opacity) && 0 <= opacity <= 1) ||
        throw(ArgumentError("opacity must be from 0 to 1, not $opacity"))
    style === nothing || check_style(style)
    lock(s.lock) do
        check_open(s)
        m = edit_target(s, key)
        check_not_busy(s, key)
        layer = find_layer(m, lid)
        old = map_state(m)
        args = Dict{String,Any}("item" => key, "layer" => lid)
        if visible !== nothing
            layer.visible = visible
            args["visible"] = visible
        end
        if opacity !== nothing
            layer.opacity = Float64(opacity)
            args["opacity"] = Float64(opacity)
        end
        if channel !== nothing
            if layer.kind == :lines
                layer.channel = check_colour_channel(database(s.project, layer.item), String(channel); blank_ok = true)
            else
                isempty(channel) || throw(ArgumentError("a grid layer has no colour channel"))
            end
            args["channel"] = String(channel)
        end
        if labels !== nothing
            layer.labels = labels
            args["labels"] = labels
        end
        if own_style !== nothing
            (layer.kind == :lines && !own_style) &&
                throw(ArgumentError("a line layer always has its own style"))
            layer.own_style = own_style
            args["own_style"] = own_style
        end
        if style !== nothing
            layer.style = copy(style)
            args["style"] = style_dict(style)
        end
        new = map_state(m)
        old.layers == new.layers && return nothing
        push_map_step!(s, key, "change layer $lid of $(item(s.project, key).name)", old, new)
        record!(s, "map.set_layer", args)
        return nothing
    end
end
