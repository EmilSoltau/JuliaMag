# The commands of the Map ribbon tab (the prototype's Map tab, `ui-prototype.md` section 3),
# Show on Map and Add to Current Map.
#
# Edits of a map go through the worker (`submit!`), so Ctrl+Z undoes them, and they never ask
# first. Moves of the view are view state, not project data: they change the shown map's
# `MapViewState` at once, on the render thread.

const NEED_MAP_OPEN = "Open a map first."
const NEED_LAYER = "Select a layer first."
const NEED_GRID_LAYER = "The map has no grid layer."
const NEED_LINE_LAYER = "The map has no line layer."
const NO_EARLIER_EXTENT = "There is no earlier extent."
const NO_LATER_EXTENT = "There is no later extent."
const NEED_MAP_ITEM = "Import line data or a grid first."
const NEED_MAP_LAYERS = "The map has no layers."
const MAP_LOADING = "The map is still loading."
const MAP_FAILED = "The map's layers could not be loaded."
const MAP_HIDDEN = "Every layer of the map is hidden."
const MAP_NO_DATA = "The map's layers have nothing to draw."
const LAYER_HIDDEN = "The layer is hidden."
const LAYER_NO_DATA = "The layer has nothing to draw."
const LAYER_AT_TOP = "The layer is at the top."
const LAYER_AT_BOTTOM = "The layer is at the bottom."
# "The current point is not on this map." is `NOT_ON_MAP_TEXT` (overlays.jl), as the nav button says.

# --- What the commands act on ---

"The shown map (a `MapView`) and `nothing`, or `nothing` and the reason there is none."
function map_target(app)
    has_session(app) || return nothing, NEED_PROJECT
    mv = shown_map(app)
    mv === nothing && return nothing, NEED_MAP_OPEN
    return mv, nothing
end

"The selected layer (`app.ui.layer_selected`) of map view `mv`, or `nothing`."
function selected_layer(app, mv)::Union{Nothing,Core.MapLayer}
    k = findfirst(l -> l.id == app.ui.layer_selected, mv.layers)
    return k === nothing ? nothing : mv.layers[k]
end

"""
    toggle_target(app, mv, kind) -> Union{Nothing,Core.MapLayer}

The layer a Display toggle acts on: the selected layer when it is of `kind` (`:grid` or
`:lines`), else the top layer of that kind; `nothing` when the map has none.
"""
function toggle_target(app, mv, kind::Symbol)::Union{Nothing,Core.MapLayer}
    l = selected_layer(app, mv)
    l !== nothing && l.kind == kind && return l
    k = findlast(x -> x.kind == kind, mv.layers)
    return k === nothing ? nothing : mv.layers[k]
end

"""
    shown_view(app) -> (mv, st)

The shown map and its view state, or `nothing` for the view state until the map view has a
camera and a size (it has drawn a frame with data).
"""
function shown_view(app)
    mv = shown_map(app)
    mv === nothing && return nothing, nothing
    st = get(app.map.views, mv.id, nothing)
    (st === nothing || st.camera === nothing || st.size[1] <= 0 || st.size[2] <= 0) && return mv, nothing
    return mv, st
end

# The coordinate bands that Full Extent and Zoom to Layer fit inside, in device pixels.
band_inset(app) = px(app.window === nothing ? 1 : app.window.scale, BAND)

# The extent of the loaded data of layer `id` of the shown map `mv`, or `nothing`.
function shown_layer_extent(app, mv, id::AbstractString)::Union{Nothing,NTuple{4,Float64}}
    refresh_plan!(app.map, app, mv)
    for p in app.map.plan
        p.layer.id == id && return layer_extent(p.entry)
    end
    return nothing
end

# The effective style of grid layer `l`: its own, or its grid's.
function grid_layer_style(app, l::Core.MapLayer)::Core.LayerStyle
    gv = get(app.snap.grids, l.item, nothing)
    return Core.effective_style(l, gv === nothing ? nothing : gv.style, app.config.grid_colours)
end

# --- Enabled rules ---

map_reason(app) = last(map_target(app))

# A view move needs a camera: the map has layers and its first data is in. A map that could
# not be read gives its own error, as the Layers tab shows it. Without a camera, the reason
# comes from the layer states the Layers tab shows (`layers_cache`): every layer hidden; a
# visible layer still loading, or one with an extent (the view places the camera in its next
# frame); every visible layer failed (its item missing, or its load gave an error and no
# data); else the data that came has no point to place (all values missing).
function view_reason(app)
    mv, why = map_target(app)
    why === nothing || return why
    isempty(mv.error) || return mv.error
    isempty(mv.layers) && return NEED_MAP_LAYERS
    last(shown_view(app)) === nothing || return nothing
    c = layers_cache(app, mv)
    any(r -> r.visible, c.rows) || return MAP_HIDDEN
    failed = true
    for (k, r) in enumerate(c.rows)
        r.visible || continue
        (r.loading || c.extent[k]) && return MAP_LOADING
        failed &= c.failed[k]
    end
    return failed ? MAP_FAILED : MAP_NO_DATA
end

function layer_reason(app)
    mv, why = map_target(app)
    why === nothing || return why
    return selected_layer(app, mv) === nothing ? NEED_LAYER : nothing
end

# Zoom to Layer: a selected layer with something to fit, and a camera to move. A hidden layer,
# one whose item is missing or whose load failed (its own error), and one whose data has no
# extent say so; a layer still loading waits with the map.
function zoom_layer_reason(app)
    why = layer_reason(app)
    why === nothing || return why
    c = layers_cache(app, shown_map(app)::MapView)
    k = findfirst(r -> r.id == app.ui.layer_selected, c.rows)
    if k !== nothing
        r = c.rows[k]
        r.visible || return LAYER_HIDDEN
        (r.missing || c.failed[k]) && return r.error
        r.loading || c.extent[k] || return LAYER_NO_DATA
    end
    return view_reason(app)
end

# Move Up and Move Down: a selected layer that is not at the top (or the bottom) already.
function move_reason(app, up::Bool)
    mv, why = map_target(app)
    why === nothing || return why
    k = findfirst(l -> l.id == app.ui.layer_selected, mv.layers)
    k === nothing && return NEED_LAYER
    up && k == length(mv.layers) && return LAYER_AT_TOP
    !up && k == 1 && return LAYER_AT_BOTTOM
    return nothing
end

function kind_reason(app, kind::Symbol)
    mv, why = map_target(app)
    why === nothing || return why
    toggle_target(app, mv, kind) === nothing || return nothing
    return kind == :grid ? NEED_GRID_LAYER : NEED_LINE_LAYER
end

# Previous and Next Extent end a gesture that has not settled first (`end_gesture!`): its
# start becomes an earlier extent, and the later ones go.
function history_reason(app, back::Bool)
    why = map_reason(app)
    why === nothing || return why
    _, st = shown_view(app)
    st === nothing && return back ? NO_EARLIER_EXTENT : NO_LATER_EXTENT
    open = st.before !== nothing && st.before != st.camera
    back && isempty(st.history.past) && !open && return NO_EARLIER_EXTENT
    !back && (isempty(st.history.future) || open) && return NO_LATER_EXTENT
    return nothing
end

# Plans the shown map first (`refresh_plan!`, which does nothing when the plan is current),
# so the reason follows a map switch at once, before the view draws the map.
function cursor_reason(app)
    mv, why = map_target(app)
    why === nothing || return why
    refresh_plan!(app.map, app, mv)
    return cursor_target(app, mv) === nothing ? NOT_ON_MAP_TEXT : nothing
end

function add_item_reason(app)
    has_session(app) || return NEED_PROJECT
    any(it -> it.kind in (Core.ITEM_DATABASE, Core.ITEM_GRID), snap_items(app)) && return nothing
    return NEED_MAP_ITEM
end

# --- Edits ---

"""
    open_map!(app, id)

Show map `id` in the central area. Another map's selected layer is no longer selected, and a
live opacity or style of the map shown before goes.
"""
function open_map!(app, id::AbstractString)
    app.ui.current_map == id && return nothing
    app.ui.current_map = String(id)
    app.ui.layer_selected = ""
    clear_previews!(app.ui)
    return nothing
end

"Make a new empty map and show it."
function new_map_now!(app)
    submit!(app, "New map", s -> Core.new_map!(s); done = (a, id) -> open_map!(a, id))
    return nothing
end

"""
    add_to_map!(app, item)

Add database or grid `item` to the shown map as a new layer, always, so one database can show
twice with two channels; with no map shown, make a map with it. The new layer is selected.
A map's first layer fits the full extent once its data is in. Each is one undo step.
"""
function add_to_map!(app, item::AbstractString)
    src = String(item)
    mv = shown_map(app)
    if mv === nothing
        # The new map shows even when the add fails (a database with no current X, Y pair):
        # the error is a toast, and the map is one undo step, as New Map.
        submit!(app, "Show on map", s -> begin
                m = Core.new_map!(s)
                try
                    (m, Core.add_layer!(s, m, src), nothing)
                catch e
                    e isa InterruptException && rethrow()
                    (m, "", (e, catch_backtrace()))
                end
            end;
            done = (a, r) -> begin
                open_map!(a, r[1])
                a.ui.layer_selected = r[2]
                r[3] === nothing || report_error!(a, r[3]...)
                nothing
            end)
        return nothing
    end
    m = mv.id
    # A map with no layers fits its first layer anew: a camera it kept from older layers goes.
    isempty(mv.layers) && delete!(app.map.views, m)
    submit!(app, "Add to map", s -> Core.add_layer!(s, m, src);
        done = (a, l) -> (a.ui.current_map == m && (a.ui.layer_selected = l); nothing))
    return nothing
end

"""
    show_on_map!(app, item)

Show database or grid `item` on a map. When the shown map has a layer of it, select that
layer (the top one) and zoom to it. Else add it to the shown map, or make a new map with it
(`add_to_map!`).
"""
function show_on_map!(app, item::AbstractString)
    mv = shown_map(app)
    if mv !== nothing
        k = findlast(l -> l.item == item, mv.layers)
        if k !== nothing
            app.ui.layer_selected = mv.layers[k].id
            zoom_to_layer!(app)
            return nothing
        end
    end
    add_to_map!(app, item)
    return nothing
end

"""
    add_item_menu(app) -> Vector{MenuItem}

The rows of the Add Item menu, as the prototype's `addItemMenu`: the head "Databases" and
the databases, then "Grids" and the grids. A row adds its item to the shown map
(`add_to_map!`); an item already on it says "on map" at the right.
"""
function add_item_menu(app)::Vector{MenuItem}
    mv = shown_map(app)
    on_map(id) = mv !== nothing && any(l -> l.item == id, mv.layers)
    rows = MenuItem[]
    for (kind, head, icon) in ((Core.ITEM_DATABASE, "Databases", "database"), (Core.ITEM_GRID, "Grids", "grid"))
        mine = [it for it in snap_items(app) if it.kind == kind]
        isempty(mine) && continue
        push!(rows, menu_head(head))
        for it in mine
            id = it.id
            push!(rows, MenuItem(it.name; icon = it.missing ? "missing" : icon,
                shortcut = on_map(id) ? "on map" : "",
                reason = it.missing ? "Its folder is missing." : nothing,
                action = a -> add_to_map!(a, id)))
        end
    end
    return rows
end

function remove_selected_layer!(app)
    mv, _ = map_target(app)
    mv === nothing && return nothing
    l = selected_layer(app, mv)
    l === nothing && return nothing
    m, id = mv.id, l.id
    app.ui.layer_selected = ""
    submit!(app, "Remove layer", s -> Core.remove_layer!(s, m, id))
    return nothing
end

# Move the selected layer one place up (it draws later) or down (it draws earlier).
function move_selected_layer!(app, up::Bool)
    move_reason(app, up) === nothing || return nothing
    mv = shown_map(app)::MapView
    k = something(findfirst(l -> l.id == app.ui.layer_selected, mv.layers))
    m, id, to = mv.id, mv.layers[k].id, up ? k + 1 : k - 1
    submit!(app, up ? "Move layer up" : "Move layer down", s -> Core.move_layer!(s, m, id, to))
    return nothing
end

hillshade_on(app) = (mv = shown_map(app); l = mv === nothing ? nothing : toggle_target(app, mv, :grid);
    l !== nothing && shown_style(app, l).shade)

line_labels_on(app) = (mv = shown_map(app); l = mv === nothing ? nothing : toggle_target(app, mv, :lines);
    l !== nothing && l.labels)

# Shade the grid layer that `toggle_target` names, or stop: the Layer Style pane's edit of its
# Hillshade (`apply_style_edit!`). The shading is the layer's own, so a layer that uses its
# grid's colours keeps them.
function toggle_hillshade!(app)
    mv, _ = map_target(app)
    l = mv === nothing ? nothing : toggle_target(app, mv, :grid)
    l === nothing && return nothing
    on = !shown_style(app, l).shade
    apply_style_edit!(app, mv, l, :shade, on; label = on ? "Hillshade on" : "Hillshade off")
    return nothing
end

function toggle_line_labels!(app)
    mv, _ = map_target(app)
    l = mv === nothing ? nothing : toggle_target(app, mv, :lines)
    l === nothing && return nothing
    flag = !l.labels
    m, id = mv.id, l.id
    submit!(app, flag ? "Line labels on" : "Line labels off", s -> Core.set_layer!(s, m, id; labels = flag))
    return nothing
end

"""
    open_layer_style!(app)

Show the Layer Style pane, the right pane's `:style` tab, for the selected layer. It does
nothing until that pane is one of `RIGHT_TABS`.
"""
function open_layer_style!(app)
    lookup_tab(:style) === nothing && return nothing
    open_right_pane!(app, :style)
    return nothing
end

# --- View moves ---

function full_extent_now!(app)
    mv, st = shown_view(app)
    st === nothing && return nothing
    ext = map_extent(app, mv)
    ext === nothing || full_extent!(st, ext, st.size...; inset = band_inset(app))
    return nothing
end

zoom_now!(app, factor::Real) = (st = last(shown_view(app)); st === nothing || zoom_by!(st, factor); nothing)

"Fit the selected layer into the view, once its data is in."
function zoom_to_layer!(app)
    mv, st = shown_view(app)
    st === nothing && return nothing
    l = selected_layer(app, mv)
    l === nothing && return nothing
    ext = shown_layer_extent(app, mv, l.id)
    ext === nothing || zoom_layer!(st, ext, st.size...; inset = band_inset(app))
    return nothing
end

walk_extent!(app, back::Bool) =
    (st = last(shown_view(app)); st === nothing || (back ? previous!(st) : next!(st)); nothing)

function go_to_cursor!(app)
    mv, st = shown_view(app)
    st === nothing && return nothing
    refresh_plan!(app.map, app, mv)
    p = cursor_target(app, mv)
    p === nothing || go_to!(st, p)
    return nothing
end

# --- The commands ---

map_place(group::AbstractString, size::Symbol = :small) = [Core.Place("Map", group; size)]

function map_commands()::Vector{Command}
    project_reason = app -> has_session(app) ? nothing : NEED_PROJECT
    return Command[
        Command("map.new", "New Map", new_map_now!;
            label = "New\nMap", icon = "newMap", help = "A new, empty map. It asks for nothing.",
            places = map_place("Map", :big), enabled = project_reason),
        Command("map.add_item", "Add Item to Map",
            app -> (app.ui.tab = "Map"; app.config.ribbon_collapsed && (app.ui.ribbon_peek = true);
                    app.ui.menu_request = "map.add_item"; nothing);
            label = "Add\nItem", icon = "addItem", help = "Add a database or grid of the project to the current map.",
            places = map_place("Map", :big), enabled = add_item_reason, items = add_item_menu),
        Command("map.remove_layer", "Remove Layer", remove_selected_layer!;
            icon = "removeLayer", help = "Remove the selected layer from the map. The item stays in the project.",
            places = map_place("Map"), enabled = layer_reason),
        Command("map.move_up", "Move Up", app -> move_selected_layer!(app, true);
            icon = "up", help = "Move the selected layer up, so it draws later, over the layers below.",
            where = "Layers", enabled = app -> move_reason(app, true)),
        Command("map.move_down", "Move Down", app -> move_selected_layer!(app, false);
            icon = "down", help = "Move the selected layer down, so it draws earlier, under the layers above.",
            where = "Layers", enabled = app -> move_reason(app, false)),
        Command("map.full_extent", "Full Extent", full_extent_now!;
            label = "Full\nExtent", icon = "fullExtent", help = "Zoom to all layers of the map.", shortcut = "Home",
            places = map_place("Navigate", :big), enabled = view_reason),
        Command("map.zoom_in", "Zoom In", app -> zoom_now!(app, ZOOM_STEP);
            icon = "zoomIn", help = "Zoom in about the centre of the map.",
            places = map_place("Navigate"), enabled = view_reason),
        Command("map.zoom_out", "Zoom Out", app -> zoom_now!(app, 1 / ZOOM_STEP);
            icon = "zoomOut", help = "Zoom out about the centre of the map.",
            places = map_place("Navigate"), enabled = view_reason),
        Command("map.zoom_layer", "Zoom to Layer", zoom_to_layer!;
            icon = "zoomLayer", help = "Zoom to the selected layer.",
            places = map_place("Navigate"), enabled = zoom_layer_reason),
        Command("map.prev_extent", "Previous Extent", app -> walk_extent!(app, true);
            icon = "prevExtent", help = "Go back to the extent before.",
            places = map_place("Navigate"), enabled = app -> history_reason(app, true)),
        Command("map.next_extent", "Next Extent", app -> walk_extent!(app, false);
            icon = "nextExtent", help = "Go forward to the extent after.",
            places = map_place("Navigate"), enabled = app -> history_reason(app, false)),
        Command("map.go_cursor", "Go To Cursor", go_to_cursor!;
            icon = "crosshair", help = "Centre the map on the current point.",
            places = map_place("Navigate"), enabled = cursor_reason),
        Command("map.layer_style", "Layer Style", open_layer_style!;
            label = "Layer\nStyle", icon = "brush", help = "Colours, stretch and shading of the selected layer.",
            places = map_place("Display", :big), enabled = layer_reason),
        Command("map.hillshade", "Hillshade", toggle_hillshade!;
            icon = "hillshade", help = "Shade the grid as if lit by the sun.",
            places = map_place("Display"), enabled = app -> kind_reason(app, :grid), checked = hillshade_on),
        Command("map.colour_bars", "Colour Bars", app -> (app.ui.colour_bars = !app.ui.colour_bars; nothing);
            icon = "colour", help = "Show a colour bar for each coloured layer.",
            places = map_place("Display"), enabled = project_reason, checked = app -> app.ui.colour_bars),
        Command("map.line_labels", "Line Labels", toggle_line_labels!;
            icon = "lineType", help = "Label each line at its start.",
            places = map_place("Display"), enabled = app -> kind_reason(app, :lines), checked = line_labels_on),
    ]
end
