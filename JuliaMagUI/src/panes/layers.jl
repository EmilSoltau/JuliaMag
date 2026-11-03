# The Layers tab of the left pane, as the prototype's `renderLayersTab` (`ui-prototype.md`
# section 4.2): the layers of the shown map, top layer first, under a toolbar with the map
# chooser, with the selected layer's opacity slider and a footer.
#
# Every change goes through the worker (`submit!`) and is one undo step. The toolbar and the
# context menu run the map commands (map_commands.jl), so their reasons and tooltips are the
# ribbon's. Rows are listed top layer first, while `move_layer!` counts positions from the
# bottom: `drop_position` is the one place that converts between them.

const LAYER_GONE_NAME = "Removed item"
const LAYERS_NO_MAP = "No map is open."
const LAYERS_NO_LAYERS = "This map has no layers."
const LAYERS_FOOT = "Drag rows to change the drawing order. The top layer draws last."

# Sizes in logical pixels (prototype CSS: `.ltools`, `.trow`, `.lvl-sub`, `.opac`, `.foot`).
const LAYERS_BAR_H = 32       # the toolbar, its 1 px line included
const LAYER_ROW_H = 26
const LAYER_SUB_H = 22
const LAYER_OPACITY_H = 28
const LAYER_INDENT = 74       # the sub line and the opacity row start here
const LAYERS_PAD = 4          # `.scroll` padding at the top and bottom
const LAYERS_EMPTY_H = 200    # the empty state's box (`.empty`)
const LAYER_RAMP_W = 60       # the colour ramp of a sub line
const LAYER_RAMP_H = 8
const LAYER_TEXT_SIZE = 11.5f0
const MAP_CHOOSER_W = 112
const OPACITY_LABEL_W = 50    # "Opacity" and the 8 px gap before the slider, as the prototype lays it out
const LAYER_DROP_LINE = 2

# The commands of the toolbar after Add Item, in its order.
const LAYER_TOOLS = ("map.remove_layer", "map.move_up", "map.move_down", "map.layer_style")

"""
One row of the Layers tab: a layer of the shown map, as the tab draws it.

- `id`: the layer id; `name`: its item's name ("$(LAYER_GONE_NAME)" when the item is not in
  the project); `icon`: `"lines"` or `"grid"`.
- `sub`: a line layer's colour channel ("One colour" without one), or "Grid colours" or
  "Own colours" for a grid layer.
- `colours`: the colour table of its ramp and `reverse` its direction; `method`: the
  stretch, "hist. eq.", "linear" or "clip". Both are `""` for one plain colour.
- `opacity_text`: such as "50 %" while the opacity is below 100 %, else `""`.
- `visible`; `missing`: the item is not in the project, or its folder is gone.
- `error`: why the layer cannot draw, or a note on data that draws (such as a grid drawn
  without reprojection); `""` for none. For a missing item, why it is missing.
- `loading`: a visible layer whose data is not in yet.
"""
struct LayerRow
    id::String
    name::String
    icon::String
    sub::String
    colours::String
    method::String
    opacity_text::String
    visible::Bool
    missing::Bool
    error::String
    loading::Bool
    reverse::Bool
end

const STRETCH_TEXT = Dict(:histeq => "hist. eq.", :linear => "linear", :clip => "clip")

"The opacity as the Layers tab shows it: \"50 %\" below 100 % (never \"100 %\"), else `\"\"`."
opacity_text(o::Real)::String = o < 1 ? string(clamp(round(Int, 100 * o), 0, 99), " %") : ""

"""
    layer_status(snap, mv, layer, entries; index = nothing) -> NamedTuple

What the Layers tab shows of a layer's data: its `name`, whether its item is `missing`, its
`error` (see `LayerRow`), whether it is `loading`, and whether it `failed`: the item is
missing, or its last load gave an error and no data. Reads the snapshot and the loader's
entries only. `index` maps item ids to their place in `snap.items`, to find many layers' items
without a search each (see `item_index`).
"""
function layer_status(snap, mv, l::Core.MapLayer, entries; index::Union{Nothing,Dict{String,Int}} = nothing)
    k = index === nothing ? findfirst(it -> it.id == l.item, snap.items) : get(index, l.item, nothing)
    k === nothing && return (; name = LAYER_GONE_NAME, missing = true, error = LAYER_ITEM_GONE, loading = false, failed = true)
    it = snap.items[k]
    it.missing && return (; name = it.name, missing = true, error = missing_text(it), loading = false, failed = true)
    e = get(entries, layer_key(snap, mv, l), nothing)
    loading = l.visible && (e === nothing || e.loading || (e.data === nothing && isempty(e.error)))
    failed = e !== nothing && !e.loading && e.data === nothing && !isempty(e.error)
    return (; name = it.name, missing = false, error = e === nothing ? "" : e.error, loading, failed)
end

"The place of each item of the snapshot in `snap.items`, by id."
item_index(snap)::Dict{String,Int} = Dict{String,Int}(it.id => k for (k, it) in enumerate(snap.items))

"""
    layer_rows(snap, map_id, entries, app_colours) -> Vector{LayerRow}

The rows of map `map_id`, top layer first; none for a map the snapshot does not have.
A grid layer without its own style shows its grid's colours, with `app_colours` (the app's
"Grid colours" setting) for a grid that keeps the stock table (`Core.effective_style`).
"""
function layer_rows(snap, map_id::AbstractString, entries, app_colours::AbstractString)::Vector{LayerRow}
    mv = get(snap.maps, map_id, nothing)
    mv === nothing && return LayerRow[]
    index = item_index(snap)
    rows = LayerRow[]
    for l in Iterators.reverse(mv.layers)
        st = layer_status(snap, mv, l, entries; index)
        if l.kind == :lines
            plain = isempty(l.channel)
            sub = plain ? "One colour" : l.channel
            style = l.style
        else
            plain = false
            sub = l.own_style ? "Own colours" : "Grid colours"
            gv = get(snap.grids, l.item, nothing)
            style = Core.effective_style(l, gv === nothing ? nothing : gv.style, app_colours)
        end
        push!(rows, LayerRow(l.id, st.name, l.kind == :lines ? "lines" : "grid", sub,
            plain ? "" : style.colours, plain ? "" : get(STRETCH_TEXT, style.stretch, ""),
            opacity_text(l.opacity), l.visible, st.missing, st.error, st.loading, style.reverse))
    end
    return rows
end

"""
The Layers tab's rows of one map and what is built with them, kept while its key holds: the
snapshot, the map, the app's grid colours and the loader's `version`.

- `rows`: `layer_rows`, top first; `failed` and `extent`: for each row, whether its layer
  failed (`layer_status`) and whether its data has an extent. The map commands read them.
- `heights`, `tops`: the layout of the rows in the last frame, in device pixels (filled in
  place each frame); `foot_w`, `foot`: the footer's lines for that width.
"""
mutable struct LayersCache
    snap::Any
    map::String
    colours::String
    version::Int
    rows::Vector{LayerRow}
    failed::Vector{Bool}
    extent::Vector{Bool}
    heights::Vector{Float32}
    tops::Vector{Float32}
    foot_w::Float32
    foot::Vector{String}
end

"""
    layers_cache(app, mv) -> LayersCache

The rows of map view `mv` (`layer_rows`) and their states, built again only when the
snapshot, the map, the app's grid colours or a layer load changed (`MapState.version`).
"""
function layers_cache(app, mv)::LayersCache
    ms = app.map
    snap = app.snap
    colours = app.config.grid_colours
    c = app.ui.layers_cache
    if c isa LayersCache
        c.snap === snap && c.map == mv.id && c.version == ms.version && c.colours == colours && return c
    else
        c = LayersCache(nothing, "", "", -1, LayerRow[], Bool[], Bool[], Float32[], Float32[], -1f0, String[])
        app.ui.layers_cache = c
    end
    c.snap, c.map, c.colours, c.version = snap, mv.id, colours, ms.version
    c.rows = layer_rows(snap, mv.id, ms.entries, colours)
    index = item_index(snap)
    empty!(c.failed)
    empty!(c.extent)
    for l in Iterators.reverse(mv.layers)
        push!(c.failed, layer_status(snap, mv, l, ms.entries; index).failed)
        push!(c.extent, layer_extent(get(ms.entries, layer_key(snap, mv, l), nothing)) !== nothing)
    end
    return c
end

"""
    drop_position(from, to_row, n) -> Int

The `move_layer!` position (1 is the bottom) of the layer in row `from` when it is dropped
before row `to_row` (rows are top first; `to_row = n + 1` is after the last row), on a map
with `n` layers. A drop before its own row or the next one keeps its place.
"""
drop_position(from::Int, to_row::Int, n::Int)::Int = n + 1 - (to_row > from ? to_row - 1 : to_row)

# --- Live edits: the opacity and the style ---

# An edit the map draws live has a slot of its own in `app.ui`: the opacity (`Float64`) or the
# style (`Core.LayerStyle`). Each slot has the live value (`opacity_preview`, `style_preview`)
# and the edit on its way (`opacity_edit`, `style_pending`), with tokens from one counter.
live_preview(ui, ::Type{Float64}) = ui.opacity_preview
live_preview(ui, ::Type{Core.LayerStyle}) = ui.style_preview
live_edit(ui, ::Type{Float64}) = ui.opacity_edit
live_edit(ui, ::Type{Core.LayerStyle}) = ui.style_pending

function set_live!(ui, ::Type{Float64}, p::Union{Nothing,Tuple{String,Float64}}, e::Union{Nothing,LayerEdit{Float64}})
    ui.opacity_preview = p
    ui.opacity_edit = e
    return nothing
end

function set_live!(ui, ::Type{Core.LayerStyle}, p::Union{Nothing,Tuple{String,Core.LayerStyle}},
        e::Union{Nothing,LayerEdit{Core.LayerStyle}})
    ui.style_preview = p
    ui.style_pending = e
    return nothing
end

"End every live value and forget the edits on their way: on a map switch and a project switch."
function clear_previews!(ui)
    set_live!(ui, Float64, nothing, nothing)
    set_live!(ui, Core.LayerStyle, nothing, nothing)
    return nothing
end

"""
    commit_layer_edit!(app, T, label, map_id, layer_id, shown::T; kwargs...)

Run `Core.set_layer!(s, map_id, layer_id; kwargs...)` on the worker: one undo step. The map
draws `shown` (an opacity when `T` is `Float64`, the style the layer will be drawn with when
`T` is `Core.LayerStyle`) at once, and keeps it until a snapshot has this edit: the edit has a
token of its own, so an older edit that comes back later never ends the live value of a newer
one (see `settle_previews!`). A failed edit is reported as other edits are, and ends the live
value too.
"""
function commit_layer_edit!(app, ::Type{T}, label::AbstractString, map_id::AbstractString,
        layer_id::AbstractString, shown::T; kwargs...) where {T}
    ui = app.ui
    m, id = String(map_id), String(layer_id)
    token = (ui.layer_edits += 1)
    set_live!(ui, T, (id, shown), LayerEdit{T}(token, id, shown, -1))
    submit!(app, label, s -> begin
            try
                Core.set_layer!(s, m, id; kwargs...)
                (Core.revision(s), nothing)
            catch e
                e isa InterruptException && rethrow()
                (Core.revision(s), (e, catch_backtrace()))
            end
        end;
        done = (a, r) -> begin
            ed = live_edit(a.ui, T)
            ed !== nothing && ed.token == token && (ed.revision = r[1])
            r[2] === nothing || report_error!(a, r[2]...)
            nothing
        end)
    return nothing
end

"""
    commit_opacity!(app, map_id, layer_id, opacity)

Set the opacity of a layer on the worker: one undo step, drawn live until a snapshot has it
(`commit_layer_edit!`).
"""
commit_opacity!(app, map_id::AbstractString, layer_id::AbstractString, opacity::Real) =
    commit_layer_edit!(app, Float64, "Change opacity", map_id, layer_id, Float64(opacity); opacity = Float64(opacity))

"""
    shown_opacity(app, mv, layer_id) -> Float64

The opacity a slider shows for a layer of map view `mv`: the value of an edit still on its
way (`app.ui.opacity_edit`), so the slider does not jump back after its release; else the
layer's own.
"""
function shown_opacity(app, mv, id::AbstractString)::Float64
    ed = app.ui.opacity_edit
    ed !== nothing && ed.layer == id && return ed.value
    k = findfirst(l -> l.id == id, mv.layers)
    return k === nothing ? 1.0 : mv.layers[k].opacity
end

"Is a `slider!` being dragged now? Reads ImGui's active item; false without a slider drag."
slider_dragging(app) = (d = app.ui.drag; d isa SliderDrag && lib.igGetActiveID() == d.id)

"""
    settle_drags!(app)

End a layer row drag or a slider drag whose item is no longer ImGui's active item: its row
or slider went away while the mouse was down (an undo took the layer out), so no release
ever comes. Call it once per frame, before drawing.
"""
function settle_drags!(app)
    d = app.ui.drag
    (d isa LayerDrag || d isa SliderDrag) && lib.igGetActiveID() != d.id && (app.ui.drag = nothing)
    return nothing
end

"""
    settle_previews!(app)

End the live opacity and the live style once nothing needs them: each when the snapshot has
its slot's last edit, unless a slider drags again, or at once when no slider drags and no
edit is on its way (the slider was let go with no change, Esc cancelled it, or it went
away). Call it once per frame.
"""
function settle_previews!(app)
    settle_live!(app, Float64)
    settle_live!(app, Core.LayerStyle)
    return nothing
end

function settle_live!(app, ::Type{T}) where {T}
    ui = app.ui
    ed = live_edit(ui, T)
    snap = app.snap
    if ed !== nothing && ed.revision >= 0 && snap !== nothing && snap.revision >= ed.revision
        ed = nothing
        set_live!(ui, T, live_preview(ui, T), nothing)
    end
    live_preview(ui, T) === nothing && return nothing
    ed === nothing && !slider_dragging(app) && set_live!(ui, T, nothing, nothing)
    return nothing
end

# --- Drawing ---

"""
A drag of a layer row: the ImGui `id` of the row, the map and the layer, whether the mouse
has `moved` far enough to be a drag, and whether Esc `cancelled` it.
"""
mutable struct LayerDrag
    id::UInt32
    map::String
    layer::String
    moved::Bool
    cancelled::Bool
end

"""
    draw_layers_tab(app, dl, body)

The Layers tab in box `body`: the 32 px toolbar (Add Item, Remove Layer, Move Up, Move Down
and Layer Style, and a $(MAP_CHOOSER_W) px map chooser at the right), the layers of the shown
map, top first, and the footer "$(LAYERS_FOOT)". A map with no layers says so and offers Add Item.
"""
function draw_layers_tab(app, dl, body::Box)
    s = app.window.scale
    hl = hairline(s)
    f(v) = fpx(s, v)
    ui = app.ui
    snap = app.snap
    mv = shown_map(app)
    ig.PushID("layers")
    bar = Box(body.x0, body.y0, body.x1, body.y0 + f(LAYERS_BAR_H))
    draw_layers_bar(app, dl, bar, mv)
    lines = foot_lines!(app, width(body) - f(16))
    foot = Box(body.x0, rnd(body.y1 - hl - f(16) - length(lines) * f(LAYER_TEXT_SIZE * 1.4)), body.x1, body.y1)
    view = Box(body.x0, rnd(bar.y1), body.x1, foot.y0)
    empty!(ui.layer_boxes)
    if snap === nothing || mv === nothing
        ui.layers_scroll = 0f0
        draw_layers_empty(app, dl, view, LAYERS_NO_MAP; add = false)
    elseif isempty(mv.layers)
        ui.layers_scroll = 0f0
        draw_layers_empty(app, dl, view, isempty(mv.error) ? LAYERS_NO_LAYERS : mv.error; add = isempty(mv.error))
    else
        draw_layer_list(app, dl, view, mv, layers_cache(app, mv))
    end
    draw_layers_foot(app, dl, foot, lines)
    ig.PopID()
    return nothing
end

# The footer's lines at `width`, wrapped again only when the width changes.
function foot_lines!(app, width::Float32)::Vector{String}
    c = app.ui.layers_cache
    c isa LayersCache || return wrap_lines(FONT_REGULAR, LAYER_TEXT_SIZE, LAYERS_FOOT, width)
    if c.foot_w != width
        c.foot = wrap_lines(FONT_REGULAR, LAYER_TEXT_SIZE, LAYERS_FOOT, width)
        c.foot_w = width
    end
    return c.foot
end

# The toolbar (`.ltools`): icon buttons 22 px square, 2 apart, 6 px in; the map chooser at
# the right, 10 px in; a 1 px `border` line at the bottom.
function draw_layers_bar(app, dl, bar::Box, mv)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    line = rnd(bar.y1 - hl)
    ig.AddRectFilled(dl, (bar.x0, line), (bar.x1, line + hl), u32(t.border))
    mid = (bar.y0 + line) / 2
    button_box(x) = snap(Box(x, mid - f(11), x + f(22), mid + f(11)))
    x = bar.x0 + f(6)
    add = find_command(app, "map.add_item")
    add === nothing || add_item_button!(app, dl, add, button_box(x), "layers/add_item")
    for id in LAYER_TOOLS
        x += f(22 + 2)
        cmd = find_command(app, id)
        cmd === nothing && continue
        tool_button!(app, dl, cmd, button_box(x)) && guarded(app, cmd.run)
    end
    # In a narrow pane the chooser gets narrower rather than cover the buttons.
    x0 = max(bar.x1 - f(6 + 4 + MAP_CHOOSER_W), x + f(22 + 8))
    x1 = bar.x1 - f(6 + 4)
    x1 - x0 >= f(48) || return nothing
    combo!(app, "Map", Box(x0, mid - f(11), x1, mid + f(11)), mv === nothing ? "No map" : mv.name;
        icon = "map", items = () -> map_chooser_items(app), owner = "layers/map", size = LAYER_TEXT_SIZE,
        min_width = MENU_MIN_WIDTH)
    return nothing
end

# The rows of the map chooser: the project's maps, the shown one checked.
function map_chooser_items(app)::Vector{MenuItem}
    rows = MenuItem[]
    for it in snap_items(app)
        it.kind == Core.ITEM_MAP || continue
        id = it.id
        push!(rows, MenuItem(it.name; checked = id == app.ui.current_map,
            reason = it.missing ? "Its folder is missing." : nothing, action = a -> open_map!(a, id)))
    end
    isempty(rows) && push!(rows, MenuItem("No maps"; reason = "Make a map with New Map on the Map tab."))
    return rows
end

"""
    tool_button!(app, dl, cmd, b; on = false) -> Bool

A toolbar button (`.ibtn`) for command `cmd` in box `b`: its 16 px icon, `hover` fill on
hover, `checked` fill while `on`, greyed when the command cannot run; the command's tooltip
with its reason. Returns true when clicked while the command can run.
"""
function tool_button!(app, dl, cmd::Command, b::Box; on::Bool = false)::Bool
    enabled = cmd.enabled(app) === nothing
    on && ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(app.tokens.checked), px(app.window.scale, 4))
    clicked, hovered = icon_button(app, cmd.name, cmd.icon, b; enabled, dl)
    hovered && command_tip!(app, cmd)
    return clicked
end

# The Add Item button of the toolbar: opens the command's menu (`add_item_menu`) under it,
# and shows checked while it is open.
function add_item_button!(app, dl, cmd::Command, b::Box, owner::String)
    items = cmd.items::Function
    open = menu_open(app, owner)
    open && keep_menu!(app, owner, b; items = items(app))
    tool_button!(app, dl, cmd, b; on = open) && toggle_menu!(app, owner, b, () -> items(app))
    return nothing
end

# The `.empty` state in the list's place: `text` centred in a 200 px box (lines 1.6 high,
# `text_dim`), with a small "Add Item" button under it when `add` is set; the button's text
# is `text_dim` too, as it takes the colour of `.empty`.
function draw_layers_empty(app, dl, view::Box, text::AbstractString; add::Bool)
    s = app.window.scale
    f(v) = fpx(s, v)
    box = Box(view.x0, view.y0 + f(LAYERS_PAD), view.x1, view.y0 + f(LAYERS_PAD + LAYERS_EMPTY_H))
    lines = wrap_lines(FONT_REGULAR, BODY_FONT_SIZE, text, width(box) - f(24))
    lh = f(BODY_FONT_SIZE * 1.6)
    h = length(lines) * lh + (add ? px(s, 22) : 0f0)
    y = centre_y(box) - h / 2
    for l in lines
        tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, l)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, box.x0 + (width(box) - tw) / 2, y + lh / 2,
            u32(app.tokens.text_dim), l; line = 1.6)
        y += lh
    end
    add || return nothing
    cmd = find_command(app, "map.add_item")
    cmd === nothing && return nothing
    items = cmd.items::Function
    owner = "layers/add_item_empty"
    bw = round(button_width(app, "Add Item"; small = true))
    x = round(box.x0 + (width(box) - bw) / 2)
    b = Box(x, round(y), x + bw, round(y) + px(s, 22))
    open = menu_open(app, owner)
    open && keep_menu!(app, owner, b; items = items(app))
    enabled = cmd.enabled(app) === nothing
    button(app, "Add Item", "Add Item", b.x0, b.y0; small = true, enabled, dim = true, dl) &&
        toggle_menu!(app, owner, b, () -> items(app))
    ig.IsItemHovered() && command_tip!(app, cmd)
    return nothing
end

# The footer (`.foot`): a 1 px `border` line on top, then the hint in 11.5 `text_dim`
# on lines 1.4 high, 8 px in.
function draw_layers_foot(app, dl, foot::Box, lines::Vector{String})
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.AddRectFilled(dl, (foot.x0, foot.y0), (foot.x1, foot.y1), u32(t.pane))
    ig.AddRectFilled(dl, (foot.x0, foot.y0), (foot.x1, foot.y0 + hl), u32(t.border))
    lh = f(LAYER_TEXT_SIZE * 1.4)
    y = foot.y0 + hl + f(8)
    for l in lines
        draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, foot.x0 + f(8), y + lh / 2, u32(t.text_dim), l; line = 1.4)
        y += lh
    end
    return nothing
end

# The height of a layer's rows: the row and its sub line, and the opacity row when selected.
layer_block_h(scale::Real, selected::Bool) = fpx(scale, LAYER_ROW_H + LAYER_SUB_H + (selected ? LAYER_OPACITY_H : 0))

# The row a drop at device y goes before: the first whose block's middle is below y, or n + 1.
function drop_row(tops::Vector{Float32}, heights::Vector{Float32}, y::Real)::Int
    k = findfirst(i -> y < tops[i] + heights[i] / 2, eachindex(tops))
    return k === nothing ? length(tops) + 1 : k
end

"""
    draw_layer_list(app, dl, view, mv, rows)

The layer rows of map `mv` in `view`, scrolled by `app.ui.layers_scroll`. A press on a row
selects it; a drag moves it (a 2 px `accent` line shows where it goes, and the row fades); Esc
cancels a drag. The selected layer has its opacity slider under its sub line. The right
click opens the layer's context menu; a double click opens Layer Style.
"""
function draw_layer_list(app, dl, view::Box, mv, c::LayersCache)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    ui = app.ui
    rows = c.rows
    n = length(rows)
    heights = resize!(c.heights, n)
    for (k, r) in enumerate(rows)
        heights[k] = layer_block_h(s, r.id == ui.layer_selected)
    end
    pad = f(LAYERS_PAD)
    ui.layers_scroll, bar = scroll_area!(app, "scrollbar", view, 2pad + sum(heights), ui.layers_scroll)
    right = view.x1 - (bar ? fpx(s, SCROLLBAR_W) : 0f0)
    tops = resize!(c.tops, n)
    y = view.y0 + pad - ui.layers_scroll
    for k in 1:n
        tops[k] = y
        y += heights[k]
    end
    # A drop goes before row `target`; 0 while the mouse is outside the list: no drop.
    mouse = unsafe_load(ig.GetIO().MousePos)
    target = inside(Box(view.x0, view.y0, right, view.y1), mouse.x, mouse.y) ? drop_row(tops, heights, mouse.y) : 0
    ig.PushClipRect((view.x0, view.y0), (right, view.y1), true)
    for (k, r) in enumerate(rows)
        b = Box(view.x0, tops[k], right, tops[k] + f(LAYER_ROW_H))
        ui.layer_boxes[r.id] = b
        draw_layer_row(app, dl, mv, r, k, n, b, target)
        draw_layer_sub(app, dl, r, Box(b.x0, b.y1, b.x1, b.y1 + f(LAYER_SUB_H)))
        if r.id == ui.layer_selected
            ob = Box(b.x0, b.y1 + f(LAYER_SUB_H), b.x1, b.y1 + f(LAYER_SUB_H + LAYER_OPACITY_H))
            draw_opacity_row(app, dl, mv, r, ob)
        end
    end
    d = ui.drag
    if d isa LayerDrag && d.map == mv.id && d.moved && !d.cancelled
        k = findfirst(r -> r.id == d.layer, rows)
        if k !== nothing
            b = ui.layer_boxes[d.layer]   # the dragged row fades, as the prototype's opacity 0.5
            ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.pane, 0.5))
            if target != 0 && target != k && target != k + 1
                ly = rnd(target <= n ? tops[target] : y - f(LAYER_DROP_LINE))
                ig.AddRectFilled(dl, (view.x0, ly), (right, ly + px(s, LAYER_DROP_LINE)), u32(t.accent))
            end
        end
    end
    ig.PopClipRect()
    # The context menu belongs to the selected layer and follows the commands' reasons.
    m = ui.menu
    if m isa OpenMenu && m.owner == "layers"
        any(r -> r.id == ui.layer_selected, rows) && keep_menu!(app, "layers", m.anchor; items = layer_menu(app))
    end
    return nothing
end

"""
    layer_menu(app) -> Vector{MenuItem}

The context menu of a layer row: Zoom to Layer, Layer Style..., Move Up, Move Down and Remove
Layer. Each row runs its map command, with the command's reason when it cannot run.
"""
function layer_menu(app)::Vector{MenuItem}
    function row(id, label = nothing)
        c = find_command(app, id)
        c === nothing && return nothing
        return MenuItem(something(label, c.name); icon = c.icon, help = c.help, id = c.id,
            reason = c.enabled(app), action = a -> run_command!(a, id))
    end
    items = [row("map.zoom_layer"), row("map.layer_style", "Layer Style..."), menu_separator(),
        row("map.move_up"), row("map.move_down"), menu_separator(), row("map.remove_layer")]
    return MenuItem[x for x in items if x !== nothing]
end

"""
    draw_layer_row(app, dl, mv, row, k, n, b, target)

Layer row `k` of `n` in box `b` (26 px), as the prototype's `.trow`: the hover or selection
fill inset 4 px with radius 5, the 12 px drag grip, the visibility box, the 16 px icon and
the name (`text_disabled` when hidden, `red` when the item is missing); at the right "not
found" in `red` for a missing item, else the opacity text, before it a spinner while the data
loads and an `amber` warning (its tooltip the error) when the layer has one. `target` is the
row a drag would drop before now.
"""
function draw_layer_row(app, dl, mv, r::LayerRow, k::Int, n::Int, b::Box, target::Int)
    s = app.window.scale
    t = app.tokens
    ui = app.ui
    f(v) = fpx(s, v)
    mid = centre_y(b)
    cbox = snap(Box(b.x0 + f(24), mid - f(7), b.x0 + f(38), mid + f(7)))
    name_x = b.x0 + f(66)
    edge = b.x1 - f(8)
    right_text = r.missing ? "not found" : r.opacity_text
    rw = isempty(right_text) ? 0f0 : text_width(FONT_REGULAR, 12, right_text)
    isempty(right_text) || (edge -= rw + f(8))
    warn = !r.missing && !isempty(r.error)
    wbox = warn ? snap(Box(edge - f(14), mid - f(7), edge, mid + f(7))) : nothing
    warn && (edge -= f(14 + 6))
    spin_x = edge - f(6)
    r.loading && (edge -= f(12 + 6))
    name = elide(text_width, r.name, max(edge - name_x, 0f0))

    ig.PushID(r.id)
    # The row's button owns the row: hover, selection, drag, right click. The visibility box
    # and the warning lie on top of it and take the mouse there.
    clicked, hovered, held = hit("row", b; overlap = true)
    on_row = ig.IsItemHovered()
    started = ig.IsItemActivated()
    row_id = ig.GetItemID()
    ended = ig.IsItemDeactivated()
    name != r.name && item_tip!(app, r.name; hovered = on_row)
    if r.missing && !isempty(right_text)
        hit("missing", Box(b.x1 - f(8) - rw, b.y0, b.x1 - f(8), b.y1))
        item_tip!(app, r.error)
    end
    if first(hit("check", Box(cbox.x0, b.y0, cbox.x1, b.y1)))
        m, id, flag = mv.id, r.id, !r.visible
        submit!(app, flag ? "Show layer" : "Hide layer", s -> Core.set_layer!(s, m, id; visible = flag))
    end
    if warn
        hit("warning", something(wbox))
        item_tip!(app, r.error)
    end
    started && (ui.drag = LayerDrag(row_id, mv.id, r.id, false, false))
    cur = ui.drag
    d = cur isa LayerDrag && cur.map == mv.id && cur.layer == r.id ? cur : nothing   # this row's drag, or `nothing`
    if held && d !== nothing && !d.cancelled
        ig.IsKeyPressed(lib.ImGuiKey_Escape, false) && (d.cancelled = true)
        d.moved |= ig.IsMouseDragging(0)
        d.moved && request_frames!(app.window::Window)
    end
    dragged = d !== nothing && d.moved
    if ended && d !== nothing
        ui.drag = nothing
        if d.moved && !d.cancelled && target != 0 && target != k && target != k + 1
            m, id, pos = mv.id, r.id, drop_position(k, target, n)
            submit!(app, "Move layer", s -> Core.move_layer!(s, m, id, pos))
        end
    end
    clicked && !dragged && (ui.layer_selected = r.id)
    if on_row && ig.IsMouseDoubleClicked(0)
        ui.layer_selected = r.id
        run_command!(app, "map.layer_style")
    end
    if hovered && ig.IsMouseClicked(1)
        ui.layer_selected = r.id
        mouse = unsafe_load(ig.GetIO().MousePos)
        open_menu!(app, "layers", Box(mouse.x, mouse.y, mouse.x, mouse.y), layer_menu(app); gap = 0)
    end
    ig.PopID()

    selected = r.id == ui.layer_selected
    fill = selected ? t.selection : (hovered && !(ui.drag isa LayerDrag)) ? t.hover : nothing
    if fill !== nothing
        bg = snap(Box(b.x0 + f(4), b.y0 + f(1), b.x1 - f(4), b.y1 - f(1)))
        ig.AddRectFilled(dl, (bg.x0, bg.y0), (bg.x1, bg.y1), u32(fill), f(5))
    end
    draw_icon(dl, "grip", (rnd(b.x0 + f(6)), rnd(mid - f(6))), 12; style = :disabled)
    draw_checkbox(app, dl, cbox, r.visible)
    draw_icon(dl, r.icon, (rnd(b.x0 + f(42)), rnd(mid - f(8))), 16)
    col = r.missing ? t.red : r.visible ? t.text : t.text_disabled
    draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, name_x, mid, u32(col), name)
    isempty(right_text) || draw_text_mid(dl, FONT_REGULAR, 12, b.x1 - f(8) - rw, mid,
        u32(r.missing ? t.red : t.text_dim), right_text)
    wbox === nothing || draw_icon(dl, "warn", (wbox.x0, wbox.y0), 14)
    if r.loading
        draw_spinner(app, dl, spin_x, mid)
        request_frames!(app.window::Window)   # the spinner turns
    end
    return nothing
end

# The sub line (`.lvl-sub`, 22 px) in box `b`: from 74 px in, the channel or style text in
# 11.5 `text_dim`, the 60 by 8 colour ramp with a 1 px `border_strong` frame and the stretch
# method 8 px after it. The ramps of all rows end where "hist. eq." would start, 12 px before
# the right edge, so they line up. A ramp gets narrower, down to 40 px (the prototype's
# `min-width`), before the text is cut.
function draw_layer_sub(app, dl, r::LayerRow, b::Box)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    mid = centre_y(b)
    x = b.x0 + f(LAYER_INDENT)
    edge = b.x1 - f(12)
    col = u32(t.text_dim)
    if !isempty(r.colours)
        ramp_x1 = edge - text_width(FONT_REGULAR, LAYER_TEXT_SIZE, STRETCH_TEXT[:histeq]) - f(8)
        text_end = x + text_width(FONT_REGULAR, LAYER_TEXT_SIZE, r.sub) + f(8)
        ramp_x0 = clamp(text_end, ramp_x1 - f(LAYER_RAMP_W), ramp_x1 - f(40))
        ramp = snap(Box(ramp_x0, mid - f(LAYER_RAMP_H / 2), ramp_x1, mid + f(LAYER_RAMP_H / 2)))
        if ramp.x0 > x
            draw_table_ramp(dl, Box(ramp.x0 + hl, ramp.y0 + hl, ramp.x1 - hl, ramp.y1 - hl), r.colours, r.reverse)
            ig.AddRect(dl, (ramp.x0, ramp.y0), (ramp.x1, ramp.y1), u32(t.border_strong), f(2), hl)
            draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, ramp.x1 + f(8), mid, col,
                elide(text_width, r.method, max(edge - ramp.x1 - f(8), 0f0); size = LAYER_TEXT_SIZE))
            edge = ramp.x0 - f(8)
        end
    end
    draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, x, mid, col,
        elide(text_width, r.sub, max(edge - x, 0f0); size = LAYER_TEXT_SIZE))
    return nothing
end

# Colour table `name` across box `b`, one device pixel column at a time; from high to low
# when `reverse`.
function draw_table_ramp(dl, b::Box, name::AbstractString, reverse::Bool)
    n = round(Int, width(b))
    n > 0 || return nothing
    table = Core.colour_table(name)
    m = length(table)
    for i in 0:n-1
        k = n == 1 ? 0 : round(Int, i / (n - 1) * (m - 1))
        c = table[reverse ? m - k : k + 1]
        ig.AddRectFilled(dl, (b.x0 + i, b.y0), (b.x0 + i + 1, b.y1),
            UInt32(c[1]) | UInt32(c[2]) << 8 | UInt32(c[3]) << 16 | 0xff000000)
    end
    return nothing
end

"""
    draw_opacity_row(app, dl, mv, row, b)

The selected layer's opacity row (`.opac`, 28 px) in box `b`: "Opacity" in 11.5 `text_dim`
from 74 px in, then its `opacity_slider!` and its value ("85 %") 12 px before the right edge.
"""
function draw_opacity_row(app, dl, mv, r::LayerRow, b::Box)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    ui = app.ui
    mid = centre_y(b)
    x = b.x0 + f(LAYER_INDENT)
    draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, x, mid, u32(t.text_dim), "Opacity")
    x += f(OPACITY_LABEL_W)
    sb = Box(x, mid - f(8), max(x + f(SLIDER_THUMB + SLIDER_VALUE_W + 8), b.x1 - f(12)), mid + f(8))
    ig.PushID(r.id)
    opacity_slider!(app, mv, r.id, sb)
    ig.PopID()
    ui.layer_boxes["opacity"] = Box(sb.x0, sb.y0, sb.x1 - f(SLIDER_VALUE_W + 8), sb.y1)
    return nothing
end

"""
    opacity_slider!(app, mv, layer_id, b)

The opacity slider of a layer of map view `mv` in box `b`, with its value ("85 %") at the
right: the Layers tab's and the Layer Style pane's. A drag draws the map live through
`app.ui.opacity_preview`; the release sets the opacity, one undo step (`commit_opacity!`).
"""
function opacity_slider!(app, mv, id::AbstractString, sb::Box)
    ui = app.ui
    base = shown_opacity(app, mv, id)   # an edit still on its way shows its value
    pending = ui.opacity_edit !== nothing && ui.opacity_edit.layer == id
    value = 100 * base
    v, changed, released = slider!(app, "Opacity", sb, value, 0, 100;
        format = v -> string(round(Int, v), " %"), step = 1)
    same = v == value
    changed && (ui.opacity_preview = same && !pending ? nothing : (String(id), same ? base : v / 100))
    if released
        if same
            ui.opacity_preview = pending ? (String(id), base) : nothing
        else
            commit_opacity!(app, mv.id, id, v / 100)
        end
    end
    return nothing
end
