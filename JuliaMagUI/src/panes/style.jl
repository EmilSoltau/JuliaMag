# The Layer Style pane, a tab of the right pane: the colours, stretch, shading, cells and
# opacity of the selected layer of the shown map. Its fields are those of the prototype's
# Layer Style dialog (`ui-prototype.md`), laid out as RustGIS lays out its Symbology pane: one
# column, a label over each control (`ui-rustgis.md` section 7).
#
# Each change applies at once and is one undo step: `Core.set_layer!` on the worker. The
# sliders draw the map live (`ui.style_preview`, `ui.opacity_preview`) and set the value on
# release, as the Layers tab's opacity slider does (`commit_layer_edit!`). `style_edit` is the
# one place that turns a new value of a field into the keywords of `set_layer!`; the ribbon's
# Hillshade goes through it too (`apply_style_edit!`).

const STYLE_NO_LAYER = "Select a layer in the Layers tab to change its style."
const STYLE_OWN_HINT = "Untick to give this layer its own colours."
const STYLE_LIMITS_HINT = "Blank means the data's own range."
const STYLE_CLIP_HINT = "From 0 to 49 % at each end."
const STYLE_ONE_COLOUR = "One colour"
const STYLE_NOT_NUMBER = "Enter a number."
const STYLE_BAD_SCALE = "Enter a number above 0, or leave it blank for auto."

# Sizes in logical pixels.
const STYLE_PAD = 12          # the pane's padding at each side
const STYLE_HEAD_H = 40       # the layer's name, over a 1 px line
const STYLE_SECT_H = 26       # a section title, as the Tools pane's `.sect`
const STYLE_LABEL_GAP = 4     # from a label to its control
const STYLE_ROW_GAP = 10      # from a control to the next label
const STYLE_HINT_GAP = 4      # from a control to its hint
const STYLE_PAIR_GAP = 8      # between the two fields of a pair (Minimum and Maximum)
const STYLE_RAMP_W = 96       # the strip after the Colour table combo, as the prototype's
const STYLE_RAMP_H = 14
const STYLE_SLIDER_H = 16
const STYLE_END = 16          # space under the last row

# The fields of the style a grid layer takes from its grid while it uses its grid's colours,
# and those that are always the layer's own (`Core.effective_style`).
const COLOUR_FIELDS = (:colours, :reverse, :stretch, :min, :max, :clip_low, :clip_high)
const SHADING_FIELDS = (:shade, :inclination, :declination, :zfactor, :resample)

const STRETCH_OPTIONS = ((:linear, "Linear", true), (:clip, "Clip", true), (:histeq, "Equalize", true))
const CELL_OPTIONS = ((:nearest, "Nearest", true), (:bilinear, "Bilinear", true))

# --- Edits ---

"""
    style_edit(layer, field, value; grid = nothing) -> NamedTuple

The keywords of `Core.set_layer!` for one edit of `layer`: `field` set to `value`. Pure: the
layer is not changed.

- `:channel`, `:labels`, `:opacity` give those keywords (the opacity clamped to 0 to 1).
- A style field gives `style`, a copy of the layer's style with the field set: `:colours`,
  `:reverse`, `:stretch`, `:min` and `:max` (`NaN` is the data's own), `:clip_low` and
  `:clip_high` (clamped to 0 to 49), `:shade`, `:inclination` (clamped to 0 to 90),
  `:declination` (clamped to 0 to 360), `:zfactor` (`NaN` is automatic) and `:resample`.
- `:own_style`: off gives `own_style = false`; on gives `own_style = true` and a style that
  starts from the grid's stored style `grid` (its own colour table, not the app's "Grid
  colours" resolved into it) with the layer's own shading.

Throws `ArgumentError` for a value the style cannot have, a colour field of a grid layer that
uses its grid's colours (`own_style = false`), a channel of a grid layer, `own_style` of a line
layer, or an unknown field.
"""
function style_edit(l::Core.MapLayer, field::Symbol, value; grid::Union{Nothing,Core.GridStyle} = nothing)::NamedTuple
    if field === :channel
        l.kind == :lines || throw(ArgumentError("a grid layer has no colour channel"))
        return (; channel = text_value("the channel", value))
    elseif field === :labels
        return (; labels = flag_value("labels", value))
    elseif field === :opacity
        o = Float64(value)
        isfinite(o) || throw(ArgumentError("the opacity must be a number, not $o"))
        return (; opacity = clamp(o, 0.0, 1.0))
    elseif field === :own_style
        l.kind == :lines && throw(ArgumentError("a line layer always has its own colours"))
        flag_value("own_style", value) || return (; own_style = false)
        st = copy(grid === nothing ? l.style : Core.effective_style(l, grid, grid.colours))
        return (; own_style = true, style = st)
    end
    if field in COLOUR_FIELDS
        (l.kind == :grid && !l.own_style) &&
            throw(ArgumentError("the layer uses its grid's colours; untick \"Use the grid's default colours\" first"))
    elseif !(field in SHADING_FIELDS)
        throw(ArgumentError("a layer style has no field $field"))
    end
    st = copy(l.style)
    set_style_field!(st, field, value)
    Core.check_style(st)
    return (; style = st)
end

# A text, a flag or a name of `what`, or an `ArgumentError` for a value of another kind.
text_value(what::AbstractString, v)::String =
    v isa AbstractString ? String(v) : throw(ArgumentError("$what must be a text, not $(repr(v))"))
flag_value(what::AbstractString, v)::Bool = v isa Bool ? v : throw(ArgumentError("$what must be true or false, not $(repr(v))"))
name_value(what::AbstractString, v)::Symbol = v isa Symbol ? v : Symbol(text_value(what, v))

# A finite number, or an `ArgumentError` naming `what`.
function finite_value(what::AbstractString, v)::Float64
    x = Float64(v)
    isfinite(x) || throw(ArgumentError("$what must be a number, not $x"))
    return x
end

# Set one field of `st`, clamped to its range.
function set_style_field!(st::Core.LayerStyle, field::Symbol, v)
    if field === :colours
        st.colours = text_value("the colour table", v)
    elseif field === :stretch
        st.stretch = name_value("the stretch", v)
    elseif field === :resample
        st.resample = name_value("the cells", v)
    elseif field === :reverse
        st.reverse = flag_value("reverse", v)
    elseif field === :shade
        st.shade = flag_value("shade", v)
    elseif field === :min || field === :max
        x = Float64(v)
        isinf(x) && throw(ArgumentError("$field must be a number or blank, not $x"))
        field === :min ? (st.min = x) : (st.max = x)
    elseif field === :clip_low
        st.clip_low = clamp(finite_value("clip_low", v), 0.0, 49.0)
    elseif field === :clip_high
        st.clip_high = clamp(finite_value("clip_high", v), 0.0, 49.0)
    elseif field === :inclination
        st.inclination = clamp(finite_value("the inclination", v), 0.0, 90.0)
    elseif field === :declination
        st.declination = clamp(finite_value("the declination", v), 0.0, 360.0)
    elseif field === :zfactor
        x = Float64(v)
        (isnan(x) || (isfinite(x) && x > 0)) ||
            throw(ArgumentError("the vertical scale must be above 0, or NaN for auto, not $x"))
        st.zfactor = x
    end
    return nothing
end

# The words of the worker's job for an edit of `field`.
function edit_label(field::Symbol, value)::String
    field === :channel && return "Change colour channel"
    field === :labels && return value === true ? "Line labels on" : "Line labels off"
    field === :shade && return value === true ? "Hillshade on" : "Hillshade off"
    field === :own_style && return value === true ? "Own colours" : "Grid colours"
    return "Change layer style"
end

# The stored style of the grid of grid layer `l`, or `nothing` (a line layer, or a grid the
# snapshot does not have).
function layer_grid_style(app, l::Core.MapLayer)::Union{Nothing,Core.GridStyle}
    l.kind == :grid || return nothing
    gv = get(app.snap.grids, l.item, nothing)
    return gv === nothing ? nothing : gv.style
end

"""
    pending_layer(app, l) -> Core.MapLayer

Layer `l` of the snapshot as it will be once a style edit on its way is in (`ui.style_pending`),
so a second quick edit builds on the first; `l` itself when none is on its way.
"""
function pending_layer(app, l::Core.MapLayer)::Core.MapLayer
    ed = app.ui.style_pending
    (ed === nothing || ed.layer != l.id) && return l
    out = copy(l)
    if l.kind == :lines || l.own_style
        out.style = copy(ed.value)
    else   # the drawn style has the grid's colours; only the shading is the layer's
        st = out.style
        v = ed.value
        st.shade, st.inclination, st.declination, st.zfactor, st.resample =
            v.shade, v.inclination, v.declination, v.zfactor, v.resample
    end
    return out
end

"""
    shown_style(app, l) -> Core.LayerStyle

The style the pane shows for layer `l` of the shown map: that of a style edit still on its way
(`ui.style_pending`), so a control does not jump back after a click; else the layer's
effective style (`Core.effective_style`).
"""
function shown_style(app, l::Core.MapLayer)::Core.LayerStyle
    ed = app.ui.style_pending
    ed !== nothing && ed.layer == l.id && return ed.value
    return Core.effective_style(l, layer_grid_style(app, l), app.config.grid_colours)
end

"""
    apply_style_edit!(app, mv, l, field, value; label)

Set `field` of layer `l` of map view `mv` to `value` (`style_edit`), as one undo step on the
worker. A change of the style draws at once and stays until a snapshot has it
(`commit_layer_edit!`). The Layer Style pane and the ribbon's Hillshade use it.
"""
function apply_style_edit!(app, mv, l::Core.MapLayer, field::Symbol, value;
        label::AbstractString = edit_label(field, value))
    gs = layer_grid_style(app, l)
    now = pending_layer(app, l)
    kw = style_edit(now, field, value; grid = gs)
    m, id = String(mv.id), l.id
    if haskey(kw, :style)
        after = copy(now)
        after.style = kw.style
        haskey(kw, :own_style) && (after.own_style = kw.own_style)
        shown = Core.effective_style(after, gs, app.config.grid_colours)
        commit_layer_edit!(app, Core.LayerStyle, label, m, id, shown; kw...)
    else
        submit!(app, label, s -> Core.set_layer!(s, m, id; kw...))
    end
    return nothing
end

# --- What the pane shows ---

"""
    style_fields(layer, style) -> Vector{Symbol}

The fields the pane shows for `layer` drawn with `style`, in order: a line layer's `:channel`,
or a grid layer's `:own_style`; the colour fields (none for a line layer in one colour), with
`:min` and `:max` for a linear stretch and `:clip_low` and `:clip_high` for a clip; a line
layer's `:labels`, or a grid layer's `:shade` (with the sun and `:zfactor` while it is on) and
`:resample`; then `:opacity`.
"""
function style_fields(l::Core.MapLayer, st::Core.LayerStyle)::Vector{Symbol}
    out = Symbol[]
    if l.kind == :lines
        push!(out, :channel)
        isempty(l.channel) && return push!(out, :labels, :opacity)
    else
        push!(out, :own_style)
    end
    push!(out, :colours, :reverse, :stretch)
    st.stretch === :linear && push!(out, :min, :max)
    st.stretch === :clip && push!(out, :clip_low, :clip_high)
    if l.kind == :lines
        push!(out, :labels)
    else
        push!(out, :shade)
        st.shade && push!(out, :inclination, :declination, :zfactor)
        push!(out, :resample)
    end
    return push!(out, :opacity)
end

"The channels of database view `v` a line layer can colour by: numeric and not arrays, in order."
function colour_channels(v::DatabaseView)::Vector{String}
    out = String[]
    for c in v.channels
        T = get(Core.CHANNEL_ELTYPES, c.eltype, nothing)
        (T !== nothing && T <: Number && c.arraylen == 1) && push!(out, c.name)
    end
    return out
end

"`x` to 3 significant digits, as short as it reads: \"2,030\", \"6.25\", \"0.0123\"."
sig_num(x::Real)::String = short_num(round(Float64(x); sigdigits = 3))

"""
    auto_scale_hint(mean_gradient) -> String

The hint under a blank Vertical scale: the automatic value, 2.5 over the mean gradient of the
layer's data (`Core.auto_zfactor`); `nothing` while the data is not in.
"""
function auto_scale_hint(mean_gradient::Union{Nothing,Real})::String
    mean_gradient === nothing && return "Auto: 2.5 over the mean gradient."
    (isnan(mean_gradient) || !(mean_gradient > 0)) && return "Auto: 1, as the grid is flat."
    return "Auto: 2.5 over the mean gradient = " * sig_num(2.5 / mean_gradient)
end

# A number as a field holds it: no thousands commas, so it reads back; blank for `NaN`.
field_num(x::Real)::String = isnan(x) ? "" : (isinteger(x) && abs(x) < HUGE_NUMBER) ? string(round(Int, x)) :
    string(Float64(x))

"""
    style_message(app) -> Union{Nothing,String}

What the pane says in place of the fields, or `nothing` when it shows them: no map is open,
the map cannot be read (its error), no layer of it is selected, or the selected layer's item
is missing (why).
"""
function style_message(app)::Union{Nothing,String}
    mv = has_session(app) ? shown_map(app) : nothing
    mv === nothing && return LAYERS_NO_MAP
    isempty(mv.error) || return mv.error
    l = selected_layer(app, mv)
    l === nothing && return STYLE_NO_LAYER
    st = layer_status(app.snap, mv, l, app.map.entries)
    return st.missing ? st.error : nothing
end

"""
What the pane shows of one layer, kept while its key holds: the snapshot, the map, the layer,
the loader's `version`, the app's grid colours and the style edit on its way.

- `layer`: the layer; `style`: the style shown (`shown_style`); `fields`: `style_fields`.
- `name`: its item's name; `missing`, `error`: as the Layers tab's row (`layer_status`).
- `channels`: what Colour by lists (`colour_channels`); `table`: the colour table's label.
- `legend`: the low and high values of the stretch, as text; `note`: why there are none, or `""`.
- `data_lo`, `data_hi`: the data's own range, for blank Minimum and Maximum fields.
- `texts`: the text of each number field, by key; `zhint`: the Vertical scale's hint
  (`auto_scale_hint`).
- `wrap_w`, `wraps`: hints wrapped to the width `wrap_w`, by text.
"""
mutable struct StyleCache
    snap::Any
    map::String
    layer_id::String
    version::Int
    colours::String
    pending::Any
    layer::Core.MapLayer
    style::Core.LayerStyle
    fields::Vector{Symbol}
    name::String
    missing::Bool
    error::String
    channels::Vector{String}
    table::String
    legend::Tuple{String,String}
    note::String
    data_lo::String
    data_hi::String
    texts::Dict{String,String}
    zhint::String
    wrap_w::Float32
    wraps::Dict{String,Vector{String}}
end

"""
    style_cache(app, mv, l) -> StyleCache

What the pane shows of layer `l` of map view `mv`, built again only when the snapshot, the map,
the layer, a layer load (`MapState.version`), the app's grid colours or the style edit on its
way changed. A cached call allocates nothing. When it is built again, the number fields that
are not being typed in (and hold no refused text) take their values again.
"""
function style_cache(app, mv, l::Core.MapLayer)::StyleCache
    ms = app.map
    snap = app.snap
    ui = app.ui
    colours = app.config.grid_colours
    pending = ui.style_pending
    c = ui.style_pane.cache
    if c isa StyleCache
        (c.snap === snap && c.map == mv.id && c.layer_id == l.id && c.version == ms.version &&
         c.colours == colours && c.pending === pending) && return c
    end
    pane = ui.style_pane
    if !(c isa StyleCache) || c.layer_id != l.id || c.map != mv.id
        empty!(pane.buffers)
        empty!(pane.errors)
        pane.active = ""
    else
        for k in collect(keys(pane.buffers))
            (k == pane.active || haskey(pane.errors, k)) || delete!(pane.buffers, k)
        end
    end
    style = shown_style(app, l)
    st = layer_status(snap, mv, l, ms.entries)
    e = get(ms.entries, layer_key(snap, mv, l), nothing)
    d = e === nothing ? nothing : e.data
    has = d !== nothing && d.hist.total > 0
    legend, note = ("", ""), ""
    if has
        lo, hi = Core.stretch_range(style, d.hist)
        legend = (legend_number(lo), legend_number(hi))
    else
        note = !l.visible ? "Show the layer to see its values." : st.loading ? "Loading the layer's values." :
            d === nothing ? "The layer's values could not be read." : "The layer has no values."
    end
    channels = String[]
    if l.kind == :lines
        v = get(snap.databases, l.item, nothing)
        v === nothing || (channels = colour_channels(v))
    end
    k = findfirst(p -> first(p) == style.colours, Core.colour_tables())
    table = k === nothing ? style.colours : last(Core.colour_tables()[k])
    texts = Dict{String,String}("min" => field_num(style.min), "max" => field_num(style.max),
        "clip_low" => field_num(style.clip_low), "clip_high" => field_num(style.clip_high),
        "zfactor" => field_num(style.zfactor))
    zhint = d isa GridLayerData ? auto_scale_hint(d.mean_gradient) : auto_scale_hint(nothing)
    c = StyleCache(snap, mv.id, l.id, ms.version, colours, pending, l, style, style_fields(l, style), st.name,
        st.missing, st.error, channels, table, legend, note, has ? field_num(round(d.hist.lo; sigdigits = 6)) : "",
        has ? field_num(round(d.hist.hi; sigdigits = 6)) : "", texts, zhint, -1f0, Dict{String,Vector{String}}())
    pane.cache = c
    return c
end

# `text` wrapped to `w` device px, kept in the cache while the width holds.
function style_lines!(c::StyleCache, role::FontRole, size::Real, text::String, w::Float32)::Vector{String}
    if c.wrap_w != w
        empty!(c.wraps)
        c.wrap_w = w
    end
    haskey(c.wraps, text) || (c.wraps[text] = wrap_lines(role, size, text, w))
    return c.wraps[text]
end

# --- Drawing ---

"""
    draw_style_pane(app, dl, body)

The Layer Style pane in box `body`: a 40 px head with the selected layer's icon, name and kind,
then its fields in sections (Colours; Shading for a grid; Display; Legend), scrolled when they
do not fit. Without a layer to style it says why (`style_message`).
"""
function draw_style_pane(app, dl, body::Box)
    s = app.window.scale
    f(v) = fpx(s, v)
    pane = app.ui.style_pane
    empty!(pane.boxes)
    ig.PushID("style")
    # As `style_message`, but the selected layer's state comes from the cache.
    mv = has_session(app) ? shown_map(app) : nothing
    msg = mv === nothing ? LAYERS_NO_MAP : isempty(mv.error) ? nothing : mv.error
    l = msg === nothing ? selected_layer(app, something(mv)) : nothing
    msg === nothing && l === nothing && (msg = STYLE_NO_LAYER)
    view = body
    if l !== nothing
        c = style_cache(app, something(mv), l)
        head = Box(body.x0, body.y0, body.x1, rnd(body.y0 + f(STYLE_HEAD_H)))
        draw_style_head(app, dl, head, c)
        view = Box(body.x0, head.y1, body.x1, body.y1)
        if !c.missing
            draw_style_fields(app, dl, view, something(mv), c)
            ig.PopID()
            return nothing
        end
        msg = c.error
    end
    pane.scroll = 0f0
    draw_layers_empty(app, dl, view, something(msg); add = false)
    ig.PopID()
    return nothing
end

# The head: the layer's 16 px icon and its item's name (semibold, `red` when the item is
# missing), "Line layer" or "Grid layer" at the right in 11.5 `text_dim`, a 1 px `border` line under.
function draw_style_head(app, dl, head::Box, c::StyleCache)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.AddRectFilled(dl, (head.x0, head.y1 - hl), (head.x1, head.y1), u32(t.border))
    mid = (head.y0 + head.y1 - hl) / 2
    x = head.x0 + f(STYLE_PAD)
    draw_icon(dl, c.layer.kind == :lines ? "lines" : "grid", (rnd(x), rnd(mid - f(8))), 16)
    kind = c.layer.kind == :lines ? "Line layer" : "Grid layer"
    kw = text_width(FONT_REGULAR, LAYER_TEXT_SIZE, kind)
    kx = head.x1 - f(STYLE_PAD) - kw
    draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, kx, mid, u32(t.text_dim), kind)
    nx = x + f(16 + 8)
    name = elide(text_width, c.name, max(kx - f(8) - nx, 0f0); role = FONT_SEMIBOLD)
    draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, nx, mid, u32(c.missing ? t.red : t.text), name)
    name != c.name && (hit("name", Box(nx, head.y0, kx - f(8), head.y1)); item_tip!(app, c.name))
    return nothing
end

# Where the next row of the pane goes: the left and right of the controls, and the top.
mutable struct StyleFlow
    x0::Float32
    x1::Float32
    y::Float32
end

# A section title (`.sect`): semibold 11, upper case, spaced, `text_dim`, 26 px high.
function style_section!(app, dl, g::StyleFlow, title::AbstractString)
    s = app.window.scale
    h = fpx(s, STYLE_SECT_H)
    draw_spaced_text(dl, FONT_SEMIBOLD, 11, g.x0, g.y + h / 2, u32(app.tokens.text_dim), uppercase(title),
        fpx(s, 11 * 0.02))
    g.y += h
    return nothing
end

# A label over a control, from `x`: 12.5 `text` on a row 15.625 high. Returns the control's top.
function style_label!(app, dl, x::Real, y::Real, text::AbstractString)::Float32
    s = app.window.scale
    h = fpx(s, BODY_FONT_SIZE * LABEL_LINE)
    draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x, y + h / 2, u32(app.tokens.text), text)
    return Float32(y + h + fpx(s, STYLE_LABEL_GAP))
end

# A hint under a control: 11 px `text_dim` (`red` for an error) on lines 1.35 high, wrapped.
function style_hint!(app, dl, g::StyleFlow, c::StyleCache, key::AbstractString, text::String; error::Bool = false)
    s = app.window.scale
    lh = fpx(s, FORM_HINT_SIZE * FORM_HINT_LINE)
    g.y += fpx(s, STYLE_HINT_GAP)
    lines = style_lines!(c, FONT_REGULAR, FORM_HINT_SIZE, text, g.x1 - g.x0)
    col = u32(error ? app.tokens.red : app.tokens.text_dim)
    for (k, line) in enumerate(lines)
        draw_text_mid(dl, FONT_REGULAR, FORM_HINT_SIZE, g.x0, g.y + (k - 0.5f0) * lh, col, line; line = FORM_HINT_LINE)
    end
    app.ui.style_pane.boxes[key] = Box(g.x0, g.y, g.x1, g.y + length(lines) * lh)
    g.y += length(lines) * lh
    return nothing
end

# The gap before the next row.
next_row!(app, g::StyleFlow) = (g.y += fpx(app.window.scale, STYLE_ROW_GAP); nothing)

# The fields of the selected layer in `view`, scrolled by the pane's `scroll`.
function draw_style_fields(app, dl, view::Box, mv, c::StyleCache)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    pane = app.ui.style_pane
    l = c.layer
    st = c.style
    pane.scroll, bar = scroll_area!(app, "scrollbar", view, pane.content_h, pane.scroll)
    right = view.x1 - (bar ? f(SCROLLBAR_W) : 0f0)
    g = StyleFlow(view.x0 + f(STYLE_PAD), right - f(STYLE_PAD), view.y0 - pane.scroll + f(4))
    top = g.y
    ig.PushClipRect((view.x0, view.y0), (right, view.y1), true)
    ig.PushID(l.id)
    if !c.missing && !isempty(c.error)    # a load that failed, such as a channel that was deleted
        g.y += f(6)
        style_hint!(app, dl, g, c, "error", c.error; error = true)
        g.y += f(2)
    end
    style_section!(app, dl, g, "Colours")
    if l.kind == :lines
        draw_channel_row!(app, dl, g, mv, c)
    else
        mid = g.y + f(BODY_FONT_SIZE * LABEL_LINE) / 2
        checkbox!(app, "Use the grid's default colours", g.x0, mid, "Use the grid's default colours", !l.own_style) &&
            apply_style_edit!(app, mv, l, :own_style, !l.own_style)
        g.y = mid + f(BODY_FONT_SIZE * LABEL_LINE) / 2
        l.own_style || style_hint!(app, dl, g, c, "own hint", STYLE_OWN_HINT)
    end
    if :colours in c.fields
        greyed = l.kind == :grid && !l.own_style
        if greyed   # the grid's colours show, faded, and take no input
            ig.BeginDisabled()
            ig.PushStyleVar(lib.ImGuiStyleVar_DisabledAlpha, 1f0)
        end
        next_row!(app, g)
        y0 = g.y
        draw_colour_rows!(app, dl, g, mv, c)
        if greyed
            ig.PopStyleVar()
            ig.EndDisabled()
            ig.AddRectFilled(dl, (view.x0, y0 - f(2)), (right, g.y + f(2)), u32(t.pane, 0.5))
        end
    end
    if l.kind == :grid
        next_row!(app, g)
        style_section!(app, dl, g, "Shading")
        draw_shading_rows!(app, dl, g, mv, c)
    end
    next_row!(app, g)
    style_section!(app, dl, g, "Display")
    if l.kind == :grid
        y = style_label!(app, dl, g.x0, g.y, "Cells")
        v = segmented!(app, "Cells", g.x0, Box(g.x0, y, g.x1, y + f(COMBO_H)), CELL_OPTIONS, st.resample)
        (v === nothing || v === st.resample) || apply_style_edit!(app, mv, l, :resample, v)
        g.y = y + f(COMBO_H)
    else
        mid = g.y + f(BODY_FONT_SIZE * LABEL_LINE) / 2
        checkbox!(app, "Line labels", g.x0, mid, "Line labels", l.labels) &&
            apply_style_edit!(app, mv, l, :labels, !l.labels)
        g.y = mid + f(BODY_FONT_SIZE * LABEL_LINE) / 2
    end
    next_row!(app, g)
    y = style_label!(app, dl, g.x0, g.y, "Opacity")
    sb = Box(g.x0, y + f((COMBO_H - STYLE_SLIDER_H) / 2), g.x1, y + f((COMBO_H + STYLE_SLIDER_H) / 2))
    opacity_slider!(app, mv, l.id, sb)
    pane.boxes["opacity"] = Box(sb.x0, sb.y0, sb.x1 - f(SLIDER_VALUE_W + 8), sb.y1)
    g.y = y + f(COMBO_H)
    if :colours in c.fields
        next_row!(app, g)
        style_section!(app, dl, g, "Legend")
        draw_style_legend!(app, dl, g, c)
    end
    ig.PopID()
    ig.PopClipRect()
    pane.content_h = g.y - top + f(4 + STYLE_END)
    return nothing
end

# Colour by: "One colour" and the channels a line layer can colour by.
function draw_channel_row!(app, dl, g::StyleFlow, mv, c::StyleCache)
    s = app.window.scale
    l = c.layer
    y = style_label!(app, dl, g.x0, g.y, "Colour by")
    text = isempty(l.channel) ? STYLE_ONE_COLOUR : l.channel
    items = () -> begin
        rows = [MenuItem(STYLE_ONE_COLOUR; checked = isempty(l.channel), action = a -> apply_style_edit!(a, mv, l, :channel, ""))]
        for n in c.channels
            push!(rows, MenuItem(n; checked = n == l.channel, action = a -> apply_style_edit!(a, mv, l, :channel, n)))
        end
        rows
    end
    combo!(app, "Colour by", Box(g.x0, y, g.x1, y + fpx(s, COMBO_H)), text; items, owner = "style/channel")
    g.y = y + fpx(s, COMBO_H)
    return nothing
end

# Colour table (a combo, and the table as a 96 by 14 strip after it), Reverse colours, Stretch
# and the fields of the stretch.
function draw_colour_rows!(app, dl, g::StyleFlow, mv, c::StyleCache)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    l = c.layer
    st = c.style
    y = style_label!(app, dl, g.x0, g.y, "Colour table")
    row = Box(g.x0, y, g.x1, y + f(COMBO_H))
    strip = width(row) >= f(STYLE_RAMP_W + 6 + 100)
    cx1 = strip ? row.x1 - f(STYLE_RAMP_W + 6) : row.x1
    items = () -> [MenuItem(label; ramp = name, checked = name == st.colours,
        action = a -> apply_style_edit!(a, mv, l, :colours, name)) for (name, label) in Core.colour_tables()]
    combo!(app, "Colour table", Box(row.x0, row.y0, cx1, row.y1), c.table; items, owner = "style/colours")
    if strip
        mid = centre_y(row)
        r = snap(Box(row.x1 - f(STYLE_RAMP_W), mid - f(STYLE_RAMP_H / 2), row.x1, mid + f(STYLE_RAMP_H / 2)))
        draw_table_ramp(dl, inset(r, hl, hl), st.colours, st.reverse)
        ig.AddRect(dl, (r.x0, r.y0), (r.x1, r.y1), u32(t.border_strong), f(2), hl)
    end
    g.y = row.y1
    next_row!(app, g)
    mid = g.y + f(BODY_FONT_SIZE * LABEL_LINE) / 2
    checkbox!(app, "Reverse colours", g.x0, mid, "Reverse colours", st.reverse) &&
        apply_style_edit!(app, mv, l, :reverse, !st.reverse)
    g.y = mid + f(BODY_FONT_SIZE * LABEL_LINE) / 2
    next_row!(app, g)
    y = style_label!(app, dl, g.x0, g.y, "Stretch")
    v = segmented!(app, "Stretch", g.x0, Box(g.x0, y, g.x1, y + f(COMBO_H)), STRETCH_OPTIONS, st.stretch)
    (v === nothing || v === st.stretch) || apply_style_edit!(app, mv, l, :stretch, v)
    g.y = y + f(COMBO_H)
    if st.stretch === :linear
        next_row!(app, g)
        number_pair!(app, dl, g, mv, c, ("min", :min, "Minimum", c.data_lo), ("max", :max, "Maximum", c.data_hi))
        pair_hint!(app, dl, g, c, ("min", "max"), STYLE_LIMITS_HINT)
    elseif st.stretch === :clip
        next_row!(app, g)
        number_pair!(app, dl, g, mv, c, ("clip_low", :clip_low, "Low clip %", ""), ("clip_high", :clip_high, "High clip %", ""))
        pair_hint!(app, dl, g, c, ("clip_low", "clip_high"), STYLE_CLIP_HINT)
    end
    return nothing
end

# The hint under a pair of fields: the error of one of them, else `text`.
function pair_hint!(app, dl, g::StyleFlow, c::StyleCache, keys::NTuple{2,String}, text::String)
    errors = app.ui.style_pane.errors
    for k in keys
        haskey(errors, k) && return style_hint!(app, dl, g, c, k * " hint", errors[k]; error = true)
    end
    return style_hint!(app, dl, g, c, keys[1] * " hint", text)
end

# Two number fields side by side, each with its label over it: `(key, field, label, placeholder)`.
function number_pair!(app, dl, g::StyleFlow, mv, c::StyleCache, a::Tuple, b::Tuple)
    s = app.window.scale
    gap = fpx(s, STYLE_PAIR_GAP)
    w = (g.x1 - g.x0 - gap) / 2
    y = g.y
    for (k, (key, field, label, placeholder)) in enumerate((a, b))
        x = g.x0 + (k - 1) * (w + gap)
        fy = style_label!(app, dl, x, y, label)
        number_field!(app, mv, c, key, field, Box(x, fy, x + w, fy + fpx(s, FIELD_H)), placeholder)
        g.y = fy + fpx(s, FIELD_H)
    end
    return nothing
end

"""
    number_field!(app, mv, c, key, field, b, placeholder)

A number field of the pane (`field!`, its text at the right) for style `field` in box `b`, with
`placeholder` in grey while it is blank. The value is set when the field is let go after an
edit (Enter, or a click elsewhere): blank is `NaN` (the data's own, or auto); a text that is
not a number, or a value the style cannot have, is refused with a red hint.
"""
function number_field!(app, mv, c::StyleCache, key::String, field::Symbol, b::Box, placeholder::String)
    pane = app.ui.style_pane
    new = field!(app, pane, key, b, c.texts[key]; right = true, placeholder, error = haskey(pane.errors, key))
    new === nothing || delete!(pane.errors, key)
    if ig.IsItemActive()
        pane.active = key
    elseif pane.active == key
        pane.active = ""
    end
    ig.IsItemDeactivatedAfterEdit() || return nothing
    text = strip(field_text(pane.buffers[key]))
    x = isempty(text) ? NaN : parse_number(text)
    if x === nothing
        pane.errors[key] = STYLE_NOT_NUMBER
        return nothing
    end
    (isnan(x) && field in (:clip_low, :clip_high)) && (delete!(pane.buffers, key); return nothing)
    try
        apply_style_edit!(app, mv, c.layer, field, x)
    catch e
        e isa ArgumentError || rethrow()
        pane.errors[key] = field === :zfactor ? STYLE_BAD_SCALE : STYLE_NOT_NUMBER
        return nothing
    end
    delete!(pane.buffers, key)   # it takes the stored value again once the edit is in
    return nothing
end

# Hillshade, then while it is on the sun (two sliders) and the vertical scale with its hint.
function draw_shading_rows!(app, dl, g::StyleFlow, mv, c::StyleCache)
    s = app.window.scale
    f(v) = fpx(s, v)
    l = c.layer
    st = c.style
    mid = g.y + f(BODY_FONT_SIZE * LABEL_LINE) / 2
    checkbox!(app, "Hillshade", g.x0, mid, "Hillshade", st.shade) && apply_style_edit!(app, mv, l, :shade, !st.shade)
    g.y = mid + f(BODY_FONT_SIZE * LABEL_LINE) / 2
    st.shade || return nothing
    for (field, label, hi) in ((:inclination, "Sun inclination", 90), (:declination, "Sun declination", 360))
        next_row!(app, g)
        y = style_label!(app, dl, g.x0, g.y, label)
        sb = Box(g.x0, y + f((COMBO_H - STYLE_SLIDER_H) / 2), g.x1, y + f((COMBO_H + STYLE_SLIDER_H) / 2))
        sun_slider!(app, mv, l, field, label, sb, hi, st)
        app.ui.style_pane.boxes[String(field)] = Box(sb.x0, sb.y0, sb.x1 - f(SLIDER_VALUE_W + 8), sb.y1)
        g.y = y + f(COMBO_H)
    end
    next_row!(app, g)
    y = style_label!(app, dl, g.x0, g.y, "Vertical scale")
    w = min(g.x1 - g.x0, f(NUMBER_MAX_W))
    number_field!(app, mv, c, "zfactor", :zfactor, Box(g.x0, y, g.x0 + w, y + f(FIELD_H)), "auto")
    g.y = y + f(FIELD_H)
    err = get(app.ui.style_pane.errors, "zfactor", nothing)
    if err !== nothing
        style_hint!(app, dl, g, c, "zfactor hint", err; error = true)
    elseif isnan(st.zfactor)
        style_hint!(app, dl, g, c, "zfactor hint", c.zhint)
    end
    return nothing
end

degrees_text(v::Real) = string(round(Int, v), "°")

"""
    sun_slider!(app, mv, l, field, label, b, hi, base)

A slider for the sun's `:inclination` (0 to `hi` = 90) or `:declination` (0 to 360) of layer
`l`, from the shown style `base`. A drag draws the map live through `ui.style_preview`; the
release sets the value, one undo step (`apply_style_edit!`); Esc or a release with no change
sets nothing.
"""
function sun_slider!(app, mv, l::Core.MapLayer, field::Symbol, label::String, b::Box, hi::Real, base::Core.LayerStyle)
    ui = app.ui
    pending = ui.style_pending !== nothing && ui.style_pending.layer == l.id
    value = field === :inclination ? base.inclination : base.declination
    v, changed, released = slider!(app, label, b, value, 0, hi; format = degrees_text, step = 1)
    same = v == value
    if changed
        live = copy(base)
        field === :inclination ? (live.inclination = v) : (live.declination = v)
        ui.style_preview = same && !pending ? nothing : (l.id, same ? base : live)
    end
    if released
        if same
            ui.style_preview = pending ? (l.id, base) : nothing
        else
            apply_style_edit!(app, mv, l, field, v)
        end
    end
    return nothing
end

# The legend: the colour table as a strip 14 high across the pane, the stretch's low and high
# values under its ends (11.5 `text_dim`); or why there are none.
function draw_style_legend!(app, dl, g::StyleFlow, c::StyleCache)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    st = c.style
    r = snap(Box(g.x0, g.y, g.x1, g.y + f(STYLE_RAMP_H)))
    draw_table_ramp(dl, inset(r, hl, hl), st.colours, st.reverse)
    ig.AddRect(dl, (r.x0, r.y0), (r.x1, r.y1), u32(t.border_strong), f(2), hl)
    app.ui.style_pane.boxes["legend"] = r
    g.y = r.y1 + f(4)
    lh = f(LAYER_TEXT_SIZE * 1.4)
    mid = g.y + lh / 2
    col = u32(t.text_dim)
    if isempty(c.note)
        lo, hi = c.legend
        draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, g.x0, mid, col, lo)
        draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, g.x1 - text_width(FONT_REGULAR, LAYER_TEXT_SIZE, hi), mid, col, hi)
    else
        draw_text_mid(dl, FONT_REGULAR, LAYER_TEXT_SIZE, g.x0, mid, col,
            elide(text_width, c.note, g.x1 - g.x0; size = LAYER_TEXT_SIZE))
    end
    g.y += lh
    return nothing
end
