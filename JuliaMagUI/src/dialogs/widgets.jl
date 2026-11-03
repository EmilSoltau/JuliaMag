# The widgets of a tool form, one per setting type, in the prototype's `.form` grid: a
# 150 px label column, 12 px between the columns, 8 px between rows, hints under the
# control in 11 px `text_dim` (an error in `red`, and a red frame on the control).
# Every function draws into the dialog body at absolute device positions; a `FormFlow`
# says where the next row goes.

const FORM_HINT_SIZE = 11
const FORM_HINT_LINE = 1.35
const LABEL_LINE = 1.25          # the body's line height: a label row is 15.625 px high
const NUMBER_MAX_W = 140         # `.inp` of a number: max-width 140
const COMBO_H = 24

"""
    FormFlow

Where the rows of a `.form` grid go: the label column starts at `x0`, the control column
at `cx`, both end at `x1`; `y` is the bottom of what was placed last (device px, not
rounded), `last` its kind (`:start`, `:row`, `:hint` or `:chips`).
"""
mutable struct FormFlow
    x0::Float32
    cx::Float32
    x1::Float32
    y::Float32
    last::Symbol
end

form_flow(app, x0::Real, x1::Real, y::Real) =
    FormFlow(Float32(x0), Float32(x0) + fpx(app.window.scale, FORM_LABEL_W + FORM_GAP_X),
        Float32(x1), Float32(y), :start)

"""
    next_box!(app, g, kind, h) -> Box

Place the next part of the grid, `h` device px high: a `:row` (both columns), a `:hint` or
`:chips` (the control column). The gap before it is the grid's 8 px row gap, less the
prototype's negative margins: 4 before a hint, 6 before the chips; none at the start.
"""
function next_box!(app, g::FormFlow, kind::Symbol, h::Real)::Box
    gap = g.last === :start ? 0 : kind === :hint ? 4 : kind === :chips ? 6 : FORM_GAP_Y
    y0 = g.y + fpx(app.window.scale, gap)
    g.y = y0 + Float32(h)
    g.last = kind
    return kind === :row ? Box(g.x0, y0, g.x1, g.y) : Box(g.cx, y0, g.x1, g.y)
end

"The control column of row `b`."
control(g::FormFlow, b::Box) = Box(g.cx, b.y0, g.x1, b.y1)

# The label of a row, elided to the label column, centred on the row.
function row_label!(app, b::Box, text::AbstractString)
    isempty(text) && return nothing
    s = app.window.scale
    draw_text_mid(ig.GetWindowDrawList(), FONT_REGULAR, BODY_FONT_SIZE, b.x0, centre_y(b),
        u32(app.tokens.text), elide(text_width, text, fpx(s, FORM_LABEL_W)))
    return nothing
end

"""
    hint!(app, d, g, key, text; error = false)

A hint under the control of `key`: 11 px on lines 1.35 high, wrapped to the control
column, `text_dim` (or `red` for an error). Remembers where it went (`d.hint_boxes`).
"""
function hint!(app, d, g::FormFlow, key::AbstractString, text::AbstractString; error::Bool = false)
    isempty(text) && return nothing
    s = app.window.scale
    lines = wrap_lines(FONT_REGULAR, FORM_HINT_SIZE, text, g.x1 - g.cx)
    lh = fpx(s, FORM_HINT_SIZE * FORM_HINT_LINE)
    b = next_box!(app, g, :hint, lh * length(lines))
    dl = ig.GetWindowDrawList()
    col = u32(error ? app.tokens.red : app.tokens.text_dim)
    for (k, l) in enumerate(lines)
        draw_text_mid(dl, FONT_REGULAR, FORM_HINT_SIZE, b.x0, b.y0 + (k - 0.5f0) * lh, col, l;
            line = FORM_HINT_LINE)
    end
    d.hint_boxes[String(key)] = b
    return nothing
end

# The hint of setting `st`: its error, else `text` (by default its help).
setting_hint!(app, d, g, st::Core.SettingSpec, text::AbstractString = st.help) =
    (e = get(d.form.errors, st.key, nothing);
     e === nothing ? hint!(app, d, g, st.key, text) : hint!(app, d, g, st.key, e; error = true))

# --- Text fields ---

"""
    field!(app, d, key, b, text; kwargs...) -> Union{Nothing,String}

A text field for `key` in box `b` (see `text_field!`), its buffer kept by the dialog and
filled from `text` when the dialog has none. Returns the new text when it changed.
"""
function field!(app, d, key::AbstractString, b::Box, text::AbstractString; kwargs...)
    buf = get!(() -> set_field!(zeros(UInt8, FIELD_BYTES), text), d.buffers, key)
    focus = d.focus == key
    focus && (d.focus = "")
    changed = text_field!(app, "##" * key, buf, snap(b); focus, kwargs...)
    id = ig.GetItemID()
    d.field_ids[String(key)] = id
    c = d.caret
    if c !== nothing && first(c) == key && ig.IsItemActive()   # after a chip put a name in
        st = lib.igGetInputTextState(id)
        st == C_NULL || lib.ImGuiInputTextState_SetSelection(st, last(c), last(c))
        d.caret = nothing
    end
    return changed ? field_text(buf) : nothing
end

# --- Buttons ---

"""
    combo!(app, id, b, text; icon = "", items, error = false, owner = "dialog/" * id,
           size = 12.5, min_width = width of b) -> Bool

A prototype `.combo` in box `b`: `input` fill, 1 px `input_border` (`border_strong` and
`hover` on hover), the value `text` (with a 14 px `icon`) elided before the caret. A click
opens its menu of `items()`, at least `min_width` logical px wide (the combo's width), over
the dialog; while it is open the frame has the `accent` ring (an `error` makes it red).
`owner` names the menu; a combo outside a dialog passes its own. `size` is the text size:
11.5 for a `.combo.small`. Returns whether its menu is open.
"""
function combo!(app, id::AbstractString, b::Box, text::AbstractString; icon::AbstractString = "",
        items::Function, error::Bool = false, owner::AbstractString = "dialog/" * id,
        size::Real = BODY_FONT_SIZE, min_width::Union{Nothing,Real} = nothing)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    dl = ig.GetWindowDrawList()
    text_mid = centre_y(b)   # the text centres on the unrounded box, as Chrome's does
    b = snap(b)
    open = menu_open(app, owner)
    clicked, hovered, _ = hit(id, b)
    open && keep_menu!(app, owner, b; items = items())
    r = f(5)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(hovered ? t.hover : t.input), r)
    if open || error
        ig.AddRect(dl, (b.x0 - hl / 2, b.y0 - hl / 2), (b.x1 + hl / 2, b.y1 + hl / 2),
            u32(error ? t.red : t.accent), r + hl / 2, 2 * hl)
    else
        ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(hovered ? t.border_strong : t.input_border), r, hl)
    end
    mid = centre_y(b)
    x = b.x0 + hl + f(8)
    if !isempty(icon)
        draw_icon(dl, icon, (rnd(x), rnd(mid - f(7))), 14)
        x += f(14 + 6)
    end
    caret_x = b.x1 - hl - f(7 + 8)
    draw_caret(dl, caret_x, mid - f(5) / 2, s, u32(t.text_dim))
    draw_text_mid(dl, FONT_REGULAR, size, x, text_mid, u32(t.text),
        elide(text_width, text, caret_x - f(6) - x; size))
    clicked && toggle_menu!(app, owner, b, items; min_width = something(min_width, width(b) / s))
    return menu_open(app, owner)
end

"""
A drag of a `slider!`: its ImGui `id`, the value it is at, whether Esc `cancelled` it, the
`grab` offset of the mouse from the thumb's centre (a press on the thumb keeps it there), the
mouse x at the press, and whether the mouse has `moved` since: a press alone changes nothing.
"""
mutable struct SliderDrag
    id::UInt32
    value::Float64
    cancelled::Bool
    grab::Float32
    start_x::Float32
    moved::Bool
end

const SLIDER_THUMB = 12   # the prototype's range thumb; its track is 4 px high
const SLIDER_VALUE_W = 34 # `.opac .v`, 8 px after the track

"""
    slider!(app, id, b, value, lo, hi; format = nothing, step = 0) -> (value, changed, released)

A prototype `input[type=range]` across box `b`: a 4 px track with radius 2, `accent` up to
the value and `well` after it, and a 12 px round thumb (`input`, a 1 px `border_strong` ring
and a small shadow) whose centre runs from 6 px in to 6 px before the end. With `format`, the
text `format(value)` sits at the right of `b` in a $(SLIDER_VALUE_W) px column (`text`,
right-aligned), and the track ends 8 px before it, as the prototype's `.opac`.

A press on the track puts the thumb there; a press on the thumb keeps the mouse where it
took it, as a native slider does. A drag then moves it; a press without a move changes
nothing. The value goes from `lo` to `hi`, rounded to `step` when it is above 0. Pass the
stored value as `value`: it is drawn while no drag runs. During a drag the dragged value is
returned, with `changed` in each frame it changes. Esc ends a drag at once: the value goes
back to `value` (with `changed`), and the release then keeps it. `released` is true in the
frame the mouse is let go after a drag, with the value of the drag.
While the mouse is over the slider (and no drag, dialog, menu or text field takes the keys),
Left and Right step the value by `step` (1 % of the range without one); each press returns
the new value with `changed` and `released`, as a drag of its own.
"""
function slider!(app, id::AbstractString, b::Box, value::Real, lo::Real, hi::Real;
        format::Union{Nothing,Function} = nothing, step::Real = 0)::Tuple{Float64,Bool,Bool}
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    dl = ig.GetWindowDrawList()
    ui = app.ui
    track_x1 = format === nothing ? b.x1 : b.x1 - f(SLIDER_VALUE_W + 8)
    area = Box(b.x0, b.y0, track_x1, b.y1)
    _, hovered, held = hit(id, area)
    key = ig.GetItemID()
    span = Float64(hi) - Float64(lo)
    run = max(width(area) - f(SLIDER_THUMB), 1f0)   # the thumb centre's travel
    snap_to(u) = step > 0 ? clamp(round(u / step) * step, Float64(lo), Float64(hi)) : clamp(u, Float64(lo), Float64(hi))
    at(x) = snap_to(Float64(lo) + clamp((x - area.x0 - f(SLIDER_THUMB / 2)) / run, 0, 1) * span)
    centre(v) = area.x0 + f(SLIDER_THUMB / 2) + (span == 0 ? 0f0 : Float32(clamp((v - lo) / span, 0, 1))) * run
    mouse_x = unsafe_load(ig.GetIO().MousePos).x
    if ig.IsItemActivated()
        on_thumb = abs(mouse_x - centre(value)) <= f(SLIDER_THUMB / 2)
        ui.drag = SliderDrag(key, Float64(value), false, on_thumb ? mouse_x - centre(value) : 0f0, mouse_x, !on_thumb)
    end
    cur = ui.drag
    d = cur isa SliderDrag && cur.id == key ? cur : nothing   # this slider's drag, or `nothing`
    changed = released = false
    if held && d !== nothing && !d.cancelled
        if ig.IsKeyPressed(lib.ImGuiKey_Escape, false)
            d.cancelled = true
            changed = d.value != value
            d.value = Float64(value)
        else
            d.moved |= mouse_x != d.start_x
            if d.moved
                v = at(mouse_x - d.grab)
                changed = v != d.value
                d.value = v
            end
        end
    end
    if ig.IsItemDeactivated() && d !== nothing
        released = true
        ui.drag = nothing
    end
    shown = d === nothing ? Float64(value) : d.value
    io = unsafe_load(ig.GetIO())
    if d === nothing && hovered && isempty(ui.dialogs) && ui.menu === nothing && ui.search === nothing &&
            !io.WantTextInput
        dir = ig.IsKeyPressed(lib.ImGuiKey_RightArrow, true) ? 1 : ig.IsKeyPressed(lib.ImGuiKey_LeftArrow, true) ? -1 : 0
        v = snap_to(Float64(value) + dir * (step > 0 ? step : span / 100))
        if dir != 0 && v != value
            shown = v
            changed = released = true
        end
    end

    frac = span == 0 ? 0f0 : Float32(clamp((shown - lo) / span, 0, 1))
    mid = centre_y(area)
    track = snap(Box(area.x0, mid - f(2), area.x1, mid + f(2)))
    ig.AddRectFilled(dl, (track.x0, track.y0), (track.x1, track.y1), u32(t.well), f(2))
    fill_x = rnd(track.x0 + frac * width(track))
    fill_x > track.x0 && ig.AddRectFilled(dl, (track.x0, track.y0), (fill_x, track.y1), u32(t.accent), f(2),
        Int(fill_x >= track.x1 ? lib.ImDrawFlags_RoundAll : lib.ImDrawFlags_RoundLeft))
    cx = area.x0 + f(SLIDER_THUMB / 2) + frac * run
    r = f(SLIDER_THUMB / 2)
    thumb = Box(cx - r, mid - r, cx + r, mid + r)
    draw_shadow(dl, thumb, r, f(1), f(2), t.shadow)
    ig.AddCircleFilled(dl, (cx, mid), r, u32(t.input), 32)
    # Stroked on its centre line, so the ring is the outer 1 px of the thumb, as a CSS border.
    ig.AddCircle(dl, (cx, mid), r - hl / 2, u32(t.border_strong), 32, hl, Int(lib.ImDrawFlags_StrokeCenter))
    if format !== nothing
        text = format(shown)
        tw = text_width(FONT_REGULAR, 11.5, text)
        draw_text_mid(dl, FONT_REGULAR, 11.5, b.x1 - tw, mid, u32(t.text), text)
    end
    return shown, changed, released
end

"""
    segmented!(app, id, x, b, options, current) -> Union{Nothing,String}

A prototype `.seg` from `x` in row box `b` (24 high): one segment per option
`(value, label, enabled)`, 10 px padding, 1 px `input_border` lines between; the
`current` one `checked` with semibold `accent_text`, hover `hover`, a disabled one
`text_disabled`. Returns the value clicked, or `nothing`.
"""
function segmented!(app, id::AbstractString, x::Real, b::Box, options, current)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    dl = ig.GetWindowDrawList()
    r = fpx(s, 5)
    role(v) = v == current ? FONT_SEMIBOLD : FONT_REGULAR
    widths = [text_width(role(v), BODY_FONT_SIZE, l) + fpx(s, 20) for (v, l, _) in options]
    n = length(options)
    outer = snap(Box(x, b.y0, x + 2 * hl + sum(widths) + (n - 1) * hl, b.y1))
    ig.AddRectFilled(dl, (outer.x0, outer.y0), (outer.x1, outer.y1), u32(t.input), r)
    cx = outer.x0 + hl
    picked = nothing
    ig.PushID(id)
    for (k, (v, label, enabled)) in enumerate(options)
        k > 1 && (ig.AddRectFilled(dl, (cx, outer.y0), (cx + hl, outer.y1), u32(t.input_border)); cx += hl)
        seg = Box(cx, outer.y0 + hl, k == n ? outer.x1 - hl : rnd(cx + widths[k]), outer.y1 - hl)
        clicked, hovered, _ = hit(string(v), seg)
        on = v == current
        corners = Int(n == 1 ? lib.ImDrawFlags_RoundAll : k == 1 ? lib.ImDrawFlags_RoundLeft :
            k == n ? lib.ImDrawFlags_RoundRight : lib.ImDrawFlags_RoundNone)
        (on || (hovered && enabled)) && ig.AddRectFilled(dl, (seg.x0, seg.y0), (seg.x1, seg.y1),
            u32(on ? t.checked : t.hover), r - hl, corners)
        tw = text_width(role(v), BODY_FONT_SIZE, label)
        col = !enabled ? t.text_disabled : on ? t.accent_text : t.text
        draw_text_mid(dl, role(v), BODY_FONT_SIZE, seg.x0 + (width(seg) - tw) / 2, centre_y(seg), u32(col), label)
        clicked && enabled && (picked = v)
        cx = seg.x1
    end
    ig.PopID()
    ig.AddRect(dl, (outer.x0, outer.y0), (outer.x1, outer.y1), u32(t.input_border), r, hl)
    return picked
end

"""
    checkbox!(app, id, x, mid, label, checked) -> Bool

A prototype `.chk`: a 14 px checkbox with `label` 6 px right of it, centred on `mid`.
The box and the label take the click. Returns true when clicked.
"""
function checkbox!(app, id::AbstractString, x::Real, mid::Real, label::AbstractString, checked::Bool)
    s = app.window.scale
    dl = ig.GetWindowDrawList()
    box = snap(Box(x, mid - fpx(s, 7), x + fpx(s, 14), mid + fpx(s, 7)))
    tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, label)
    lh = fpx(s, BODY_FONT_SIZE * LABEL_LINE)
    clicked, _, _ = hit(id, Box(box.x0, mid - lh / 2, box.x1 + fpx(s, 6) + tw, mid + lh / 2))
    draw_checkbox(app, dl, box, checked)
    draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, box.x1 + fpx(s, 6), mid, u32(app.tokens.text), label)
    return clicked
end

"""
    small_button!(app, id, label, x, y; mono = false) -> (clicked, box)

A chip: a prototype `.btn.small` 20 px high with 6 px padding and 11 px text (mono for a
channel name).
"""
function small_button!(app, id::AbstractString, label::AbstractString, x::Real, y::Real; mono::Bool = false)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    role = mono ? FONT_MONO : FONT_REGULAR
    w = text_width(role, 11, label) + fpx(s, 12) + 2 * hl
    b = snap(Box(x, y, x + w, y + fpx(s, 20)))
    clicked, hovered, held = hit(id, b)
    dl = ig.GetWindowDrawList()
    r = fpx(s, 5)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(held ? t.pressed : hovered ? t.hover : t.input), r)
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(hovered ? t.border_strong : t.input_border), r, hl)
    tw = text_width(role, 11, label)
    draw_text_mid(dl, role, 11, b.x0 + (width(b) - tw) / 2, centre_y(b), u32(t.text), label)
    return clicked, b
end

"""
    link_button(app, id, label, icon, x, y; on = false) -> (clicked, width)

A prototype `.btn.link`: 26 high, no frame, `accent_text`, a 14 px icon before the text,
`hover` fill on hover, `checked` fill while `on` (a toggle that is pressed).
"""
function link_button(app, id::AbstractString, label::AbstractString, icon::AbstractString, x::Real, y::Real;
        on::Bool = false)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    f(v) = fpx(s, v)
    tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, label)
    w = round(hl + f(6) + f(14) + f(6) + tw + f(6) + hl)
    b = snap(Box(x, y, x + w, y + f(26)))
    clicked, hovered, held = hit(id, b)
    dl = ig.GetWindowDrawList()
    (on || hovered) && ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1),
        u32(held ? t.pressed : on ? t.checked : t.hover), f(6))
    mid = centre_y(b)
    draw_icon(dl, icon, (rnd(b.x0 + hl + f(6)), rnd(mid - f(7))), 14)
    draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, b.x0 + hl + f(6 + 14 + 6), mid, u32(t.accent_text), label)
    return clicked, w
end

# --- One widget per setting type ---

"""
    draw_setting!(app, d, g, st)

Draw the row (and its hint) of setting `st` of the dialog's form, and put what the user
changes into the form.
"""
function draw_setting! end

set_value!(d, key::AbstractString, v) = (d.form.values[key] = v; delete!(d.form.errors, key); nothing)

function draw_setting!(app, d, g::FormFlow, st::Core.NumberSetting)
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, FIELD_H))
    row_label!(app, b, st.label)
    c = control(g, b)
    w = min(width(c) - (isempty(st.unit) ? 0f0 : fpx(s, 6 + 22)), fpx(s, NUMBER_MAX_W))
    box = Box(c.x0, c.y0, c.x0 + w, c.y1)
    new = field!(app, d, st.key, box, get(f.texts, st.key, ""); right = true,
        placeholder = st.auto ? "auto" : "", error = haskey(f.errors, st.key))
    if new !== nothing
        f.texts[st.key] = new
        delete!(f.errors, st.key)
        x = parse_number(new)
        x !== nothing && (f.values[st.key] = setting_number(st, x))
        isempty(strip(new)) && st.auto && (f.values[st.key] = nothing)
    end
    # The unit (`.unit`, 11.5 px) is centred on the row as the field's text is: Chromium puts
    # its baseline 16 px under the field's top, 1 px above the field's text (measured).
    isempty(st.unit) || with_font(FONT_REGULAR, 11.5) do
        ig.AddText(ig.GetWindowDrawList(), (round(box.x1 + fpx(s, 6)), input_text_y(FONT_REGULAR, 11.5, centre_y(snap(box)))),
            u32(app.tokens.text_dim), st.unit)
    end
    auto_hint = "Blank means auto, worked out from the data."
    setting_hint!(app, d, g, st, st.auto && isempty(st.help) ? auto_hint : st.help)
    return nothing
end

function draw_setting!(app, d, g::FormFlow, st::Union{Core.TextSetting,Core.ExprSetting})
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, FIELD_H))
    row_label!(app, b, st.label)
    mono = st isa Core.ExprSetting
    placeholder = f.owner isa Core.ImporterSpec && st.key == "name" && !isempty(f.path) ?
        "auto: " * splitext(basename(f.path))[1] : ""
    value = get(f.values, st.key, "")
    new = field!(app, d, st.key, control(g, b), value isa AbstractString ? value : string(value);
        role = mono ? FONT_MONO : FONT_REGULAR, size = mono ? 12 : BODY_FONT_SIZE, placeholder,
        error = haskey(f.errors, st.key))
    new === nothing || set_value!(d, st.key, new)
    mono && channel_chips!(app, d, g, st)
    setting_hint!(app, d, g, st)
    return nothing
end

# The channels of the input database as chips under an expression; a click puts the name
# in the expression where the caret was.
function channel_chips!(app, d, g::FormFlow, st::Core.ExprSetting)
    view = input_view(d.form, app.snap, database_input(d.form))
    view === nothing && return nothing
    s = app.window.scale
    gap = fpx(s, 4)
    h = fpx(s, 20)
    # Lay out the rows first: chips wrap like the prototype's flex row.
    widths = [text_width(FONT_MONO, 11, c.name) + fpx(s, 12) + 2 * hairline(s) for c in view.channels]
    rows = Int[]
    x = 0f0
    for w in widths
        if isempty(rows) || x + w > g.x1 - g.cx + 0.5f0
            push!(rows, 0)
            x = 0f0
        end
        rows[end] += 1
        x += w + gap
    end
    isempty(rows) && return nothing
    b = next_box!(app, g, :chips, length(rows) * h + (length(rows) - 1) * gap)
    ig.PushID(st.key)
    k = 0
    for (r, n) in enumerate(rows)
        x = b.x0
        y = b.y0 + (r - 1) * (h + gap)
        for _ in 1:n
            k += 1
            name = view.channels[k].name
            clicked, cb = small_button!(app, name, name, x, y; mono = true)
            clicked && insert_name!(app, d, st.key, name)
            ig.IsItemHovered() && item_tip!(app, "Insert " * name;
                help = join(filter(!isempty, [view.channels[k].label, view.channels[k].units]), ", "))
            x = cb.x1 + gap
        end
    end
    ig.PopID()
    return nothing
end

# Put `name` into the text of field `key` at its caret (or over its selection), then give
# the field the focus with the caret after the name.
function insert_name!(app, d, key::AbstractString, name::AbstractString)
    text = string(get(d.form.values, key, ""))
    i = j = ncodeunits(text)
    id = get(d.field_ids, key, UInt32(0))
    st = id == 0 ? C_NULL : lib.igGetInputTextState(id)
    if st != C_NULL   # the field's last caret or selection, kept after it lost the focus
        i, j = if lib.ImGuiInputTextState_HasSelection(st)
            minmax(Int(lib.ImGuiInputTextState_GetSelectionStart(st)),
                Int(lib.ImGuiInputTextState_GetSelectionEnd(st)))
        else
            k = Int(lib.ImGuiInputTextState_GetCursorPos(st))
            (k, k)
        end
        i, j = clamp(i, 0, ncodeunits(text)), clamp(j, 0, ncodeunits(text))
    end
    bytes = codeunits(text)
    new = String(bytes[1:i]) * name * String(bytes[j+1:end])
    set_value!(d, key, new)
    delete!(d.buffers, key)
    d.focus = String(key)
    d.caret = (String(key), i + ncodeunits(name))
    return nothing
end

function draw_setting!(app, d, g::FormFlow, st::Core.ChoiceSetting)
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, COMBO_H))
    row_label!(app, b, st.label)
    c = control(g, b)
    current = get(f.values, st.key, st.default)
    if choice_style(st) === :segmented
        options = [(v, l, true) for (v, l) in zip(st.choices, st.labels)]
        v = segmented!(app, st.key, c.x0, c, options, current)
        v === nothing || set_value!(d, st.key, v)
    else
        k = findfirst(==(current), st.choices)
        text = k === nothing ? string(current) : st.labels[k]
        combo!(app, st.key, c, text; error = haskey(f.errors, st.key), items = () ->
            [MenuItem(l; checked = v == get(f.values, st.key, nothing), action = _ -> set_value!(d, st.key, v))
             for (v, l) in zip(st.choices, st.labels)])
    end
    setting_hint!(app, d, g, st)
    return nothing
end

function draw_setting!(app, d, g::FormFlow, st::Core.BoolSetting)
    bool_row!(app, d, g, st.key, st.label, get(d.form.values, st.key, false) === true) &&
        set_value!(d, st.key, !(get(d.form.values, st.key, false) === true))
    setting_hint!(app, d, g, st)
    return nothing
end

# A checkbox row: the label column is empty, the label is right of the box. True on a click.
function bool_row!(app, d, g::FormFlow, key::AbstractString, label::AbstractString, checked::Bool)::Bool
    s = app.window.scale
    b = next_box!(app, g, :row, fpx(s, BODY_FONT_SIZE * LABEL_LINE))
    return checkbox!(app, key, g.cx, centre_y(b), label, checked)
end

function draw_setting!(app, d, g::FormFlow, st::Core.FileSetting)
    f = d.form
    value = get(f.values, st.key, "")
    new = file_row!(app, d, g, st.key, st.label, value isa AbstractString ? value : "") do
        pick_setting_file!(app, d, st)
    end
    new === nothing || set_value!(d, st.key, new)
    setting_hint!(app, d, g, st)
    return nothing
end

"""
    file_row!(browse, app, d, g, key, label, path) -> Union{Nothing,String}

A row with a mono path field and "Browse..." after it (a `.btn`, 26 high, 6 px gap);
`browse()` runs on a click. Returns the new text when the user typed.
"""
function file_row!(browse::Function, app, d, g::FormFlow, key::AbstractString, label::AbstractString,
        path::AbstractString)
    s = app.window.scale
    b = next_box!(app, g, :row, fpx(s, 26))
    row_label!(app, b, label)
    c = control(g, b)
    bw = round(button_width(app, "Browse..."))
    field = Box(c.x0, c.y0 + fpx(s, 1), c.x1 - fpx(s, 6) - bw, c.y1 - fpx(s, 1))
    new = field!(app, d, key, field, path; role = FONT_MONO, size = 12, error = haskey(d.form.errors, key))
    ig.PushID(key)
    clicked = button(app, "Browse...", "Browse...", c.x1 - bw, c.y0)
    ig.PopID()
    clicked && guarded(app, _ -> browse())
    return new
end

function draw_setting!(app, d, g::FormFlow, st::Core.ChannelSetting)
    s = app.window.scale
    f = d.form
    view = input_view(f, app.snap, st.input)
    b = next_box!(app, g, :row, fpx(s, COMBO_H))
    row_label!(app, b, st.label)
    c = control(g, b)
    value = string(get(f.values, st.key, ""))
    items = () -> [MenuItem(n; shortcut = h, checked = n == string(get(f.values, st.key, "")),
            action = _ -> (set_value!(d, st.key, n); delete!(d.buffers, st.key)))
        for (n, h) in channel_options(st, view)]
    if st.allow_new
        # A field for a new name, with the channels as suggestions behind the caret.
        new = field!(app, d, st.key, Box(c.x0, c.y0, c.x1, c.y1), value; error = haskey(f.errors, st.key))
        new === nothing || set_value!(d, st.key, new)
        arrow = snap(Box(c.x1 - fpx(s, 24), c.y0, c.x1, c.y1))
        owner = "dialog/" * st.key
        ig.PushID(st.key)
        clicked, hovered, _ = hit("Suggestions", arrow)
        ig.PopID()
        menu_open(app, owner) && keep_menu!(app, owner, snap(c); items = items())
        hovered && ig.AddRectFilled(ig.GetWindowDrawList(), (arrow.x0, arrow.y0 + hairline(s)),
            (arrow.x1 - hairline(s), arrow.y1 - hairline(s)), u32(app.tokens.hover), fpx(s, 4))
        draw_caret(ig.GetWindowDrawList(), arrow.x1 - hairline(s) - fpx(s, 7 + 8), centre_y(c) - fpx(s, 5) / 2, s,
            u32(app.tokens.text_dim))
        clicked && toggle_menu!(app, owner, snap(c), items; min_width = width(c) / s)
    else
        combo!(app, st.key, c, value; items, error = haskey(f.errors, st.key))
    end
    setting_hint!(app, d, g, st)
    return nothing
end

function draw_setting!(app, d, g::FormFlow, st::Core.ChannelListSetting)
    s = app.window.scale
    f = d.form
    view = input_view(f, app.snap, st.input)
    b = next_box!(app, g, :row, fpx(s, COMBO_H))
    row_label!(app, b, st.label)
    names = first.(channel_options(st, view))
    chosen = get(f.values, st.key, String[])
    none = get(f.texts, st.key, "") == NO_CHANNELS
    text = none ? "No channels" : channel_list_text(chosen, length(names))
    combo!(app, st.key, control(g, b), text; error = haskey(f.errors, st.key),
        items = () -> checklist_items(d, st.key, first.(channel_options(st, input_view(f, app.snap, st.input)))))
    setting_hint!(app, d, g, st)
    return nothing
end

# The rows of a channel checklist: All, None, then a checked row per channel. They stay open.
function checklist_items(d, key::AbstractString, names::Vector{String})::Vector{MenuItem}
    f = d.form
    none = get(f.texts, key, "") == NO_CHANNELS
    chosen = get(f.values, key, String[])
    on(n) = !none && (isempty(chosen) || n in chosen)
    set_all = _ -> (delete!(f.texts, key); set_value!(d, key, String[]))
    set_none = _ -> (f.texts[key] = NO_CHANNELS; set_value!(d, key, String[]))
    items = [MenuItem("All"; stay = true, action = set_all), MenuItem("None"; stay = true, action = set_none),
        menu_separator()]
    for n in names
        push!(items, MenuItem(n; checked = on(n), stay = true, action = _ -> toggle_channel!(d, key, n, names)))
    end
    return items
end

function toggle_channel!(d, key::AbstractString, name::AbstractString, names::Vector{String})
    f = d.form
    none = get(f.texts, key, "") == NO_CHANNELS
    chosen = get(f.values, key, String[])
    current = none ? String[] : isempty(chosen) ? copy(names) : copy(chosen)
    name in current ? filter!(!=(name), current) : push!(current, name)
    current = [n for n in names if n in current]   # in the order of the list
    if isempty(current)
        f.texts[key] = NO_CHANNELS
        set_value!(d, key, String[])
    else
        delete!(f.texts, key)
        set_value!(d, key, current == names ? String[] : current)
    end
    return nothing
end

function draw_setting!(app, d, g::FormFlow, st::Core.LinesSetting)
    s = app.window.scale
    f = d.form
    view = input_view(f, app.snap, database_input(f))
    b = next_box!(app, g, :row, fpx(s, COMBO_H))
    row_label!(app, b, st.label)
    labels = lines_labels(view)
    some = view !== nothing && any(l -> l.selected, view.lines)
    # Current waits for the cursor of the views (plan 4); scripts can still use it.
    options = [("all", labels[1], true), ("selected", labels[2], some), ("current", labels[3], false)]
    v = segmented!(app, st.key, g.cx, b, options, get(f.values, st.key, st.default))
    v === nothing || set_value!(d, st.key, v)
    setting_hint!(app, d, g, st)
    return nothing
end

function draw_setting!(app, d, g::FormFlow, st::Core.CRSSetting)
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, FIELD_H))
    row_label!(app, b, st.label)
    value = string(get(f.values, st.key, ""))
    new = field!(app, d, st.key, control(g, b), value; error = haskey(f.errors, st.key))
    if new !== nothing
        set_value!(d, st.key, new)
        d.crs_edited[st.key] = time()
    end
    code = strip(string(get(f.values, st.key, "")))
    err = get(f.errors, st.key, nothing)
    if err !== nothing
        hint!(app, d, g, st.key, err; error = true)
    elseif isempty(code)
        hint!(app, d, g, st.key, st.help)
    else
        name = crs_name!(app, d, st.key, String(code))
        if name == ""
            hint!(app, d, g, st.key, "Not a known coordinate system."; error = true)
        elseif name !== nothing
            hint!(app, d, g, st.key, name)
        end
    end
    return nothing
end

"""
    crs_name!(app, d, key, code) -> Union{Nothing,String}

The name of coordinate system `code`: `""` when it is not known, `nothing` while it is
not looked up yet. The lookup runs on the worker, 300 ms after the last edit of `key`.
"""
function crs_name!(app, d, key::AbstractString, code::String)
    haskey(d.crs_names, code) && return d.crs_names[code]
    w = app.window
    wait = get(d.crs_edited, key, 0.0) + CRS_DEBOUNCE - time()
    if wait > 0
        request_frames!(w, wait + 0.05)
    elseif !(code in d.crs_pending)
        push!(d.crs_pending, code)
        submit!(app, "Look up $code", _ -> try
                Core.valid_crs(code) ? Core.crs_name(code) : ""
            catch e
                e isa InterruptException && rethrow()
                ""
            end; done = (app, name) -> (d.crs_names[code] = name; delete!(d.crs_pending, code)))
    end
    return nothing
end

const CRS_DEBOUNCE = 0.3   # s after the last key before the name is looked up

function draw_setting!(app, d, g::FormFlow, st::Core.PairSetting)
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, COMBO_H))
    row_label!(app, b, st.label)
    options = pair_options(input_view(f, app.snap, st.input))
    current = string(get(f.values, st.key, ""))
    k = findfirst(o -> first(o) == current, options)
    text = k === nothing ? replace(current, "," => ", ") : last(options[k])
    combo!(app, st.key, control(g, b), text; error = haskey(f.errors, st.key), items = () ->
        [MenuItem(l; checked = v == string(get(f.values, st.key, "")), action = _ -> set_value!(d, st.key, v))
         for (v, l) in pair_options(input_view(f, app.snap, st.input))])
    setting_hint!(app, d, g, st)
    return nothing
end

const EXTENT_NAMES = ("West", "South", "East", "North")
const POINT_NAMES = ("X", "Y")

function draw_setting!(app, d, g::FormFlow, st::Union{Core.ExtentSetting,Core.PointSetting})
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, FIELD_H))
    row_label!(app, b, st.label)
    c = control(g, b)
    names = st isa Core.ExtentSetting ? EXTENT_NAMES : POINT_NAMES
    n = length(names)
    gap = fpx(s, 6)
    w = min((width(c) - (n - 1) * gap) / n, fpx(s, NUMBER_MAX_W))
    err = haskey(f.errors, st.key)
    for (k, name) in enumerate(names)
        key = "$(st.key)/$k"
        x = c.x0 + (k - 1) * (w + gap)
        # A dim letter (W, S, E, N or X, Y) stays at the left, also when the field is filled.
        new = field!(app, d, "$(st.key)_$k", Box(x, c.y0, x + w, c.y1), get(f.texts, key, "");
            right = true, prefix = name[1:1], error = err)
        new === nothing || set_part_text!(f, st, k, new)
    end
    setting_hint!(app, d, g, st)
    return nothing
end

function draw_setting!(app, d, g::FormFlow, st::Core.ItemSetting)
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, COMBO_H))
    row_label!(app, b, st.label)
    options = item_options(app.snap, st.kind, st.optional)
    current = string(get(f.values, st.key, ""))
    k = findfirst(o -> first(o) == current, options)
    text = k === nothing ? current : last(options[k])
    icon = k === nothing || isempty(current) ? "" : kind_icon(st.kind)
    combo!(app, st.key, control(g, b), text; icon, error = haskey(f.errors, st.key), items = () ->
        [MenuItem(l; icon = isempty(v) ? "" : kind_icon(st.kind), checked = v == string(get(f.values, st.key, "")),
            action = _ -> set_value!(d, st.key, v)) for (v, l) in item_options(app.snap, st.kind, st.optional)])
    setting_hint!(app, d, g, st)
    return nothing
end

kind_icon(k::Core.ItemKind) = k == Core.ITEM_DATABASE ? "database" : k == Core.ITEM_GRID ? "grid" : "map"

"""
    input_row!(app, d, g, name, kind)

The combo of an input of the form (a tool's input, an export's item): the project's
items of its kind. A change keeps the channel settings on channels of the new database.
"""
function input_row!(app, d, g::FormFlow, name::AbstractString, kind::Core.ItemKind)
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, COMBO_H))
    row_label!(app, b, KIND_WORDS[kind])
    current = get(f.inputs, name, "")
    options = item_options(app.snap, kind, false)
    k = findfirst(o -> first(o) == current, options)
    text = k === nothing ? current : last(options[k])
    pick = id -> begin
        f.inputs[name] = id
        delete!(f.errors, name)
        fix_channels!(f, app.snap)
        form_changed!(app, f)
    end
    combo!(app, name, control(g, b), text; icon = kind_icon(kind), error = haskey(f.errors, name),
        items = () -> [MenuItem(l; icon = kind_icon(kind), checked = v == get(f.inputs, name, ""),
            action = _ -> pick(v)) for (v, l) in item_options(app.snap, kind, false)])
    e = get(f.errors, name, nothing)
    e === nothing || hint!(app, d, g, name, e; error = true)
    return nothing
end
