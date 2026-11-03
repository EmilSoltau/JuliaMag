# Drawing helpers for the custom chrome: boxes, colours, text, shadows, hit areas and buttons.
# Everything is drawn with an ImDrawList in device pixels. Sizes come in logical pixels
# and go through `px`; colours come from the tokens.

"""
    Box(x0, y0, x1, y1)

A rectangle in device pixels: top left `(x0, y0)`, bottom right `(x1, y1)`.
"""
struct Box
    x0::Float32
    y0::Float32
    x1::Float32
    y1::Float32
end

width(b::Box) = b.x1 - b.x0
height(b::Box) = b.y1 - b.y0
centre_y(b::Box) = (b.y0 + b.y1) / 2
inside(b::Box, x::Real, y::Real) = b.x0 <= x < b.x1 && b.y0 <= y < b.y1
"Shrink `b` by `dx` on the left and right and `dy` on the top and bottom."
inset(b::Box, dx::Real, dy::Real) = Box(b.x0 + dx, b.y0 + dy, b.x1 - dx, b.y1 - dy)
"Do the two boxes share any pixel?"
overlaps(a::Box, b::Box) = a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1

"`v` logical px at `scale`, in device px, not rounded (ruling T10-R2: sum lengths unrounded)."
fpx(scale::Real, v::Real) = Float32(v) * Float32(scale)

"Round half up, as a browser snaps the edges it paints."
rnd(v::Real) = round(Float32(v), RoundNearestTiesUp)
"`b` with each edge snapped to a whole pixel (`rnd`)."
snap(b::Box) = Box(rnd(b.x0), rnd(b.y0), rnd(b.x1), rnd(b.y1))

"""
    u32(c, alpha = 1) -> UInt32

Token colour `c` as an ImGui `ImU32`, with its alpha times `alpha`.
"""
function u32(c::NTuple{4,Float32}, alpha::Real = 1)::UInt32
    byte(x) = round(UInt32, 255 * clamp(Float32(x), 0f0, 1f0))
    return byte(c[1]) | byte(c[2]) << 8 | byte(c[3]) << 16 | byte(c[4] * alpha) << 24
end

"The width of a 1 px line: whole device pixels, so lines stay sharp at any scale."
hairline(scale::Real) = max(1f0, floor(Float32(scale)))

"""
    text_width(role, size, text) -> Float32

The width of `text` in device pixels, in font `role` at `size` logical pixels.
"""
text_width(role::FontRole, size::Real, text::AbstractString)::Float32 =
    with_font(() -> Float32(ig.CalcTextSize(text).x), role, size)

"""
    draw_text(dl, role, size, x, y, col, text)

Draw `text` with its top left at `(x, y)`, rounded to whole pixels so it stays sharp.
"""
function draw_text(dl, role::FontRole, size::Real, x::Real, y::Real, col::UInt32,
        text::AbstractString)
    isempty(text) && return nothing
    with_font(role, size) do
        ig.AddText(dl, (round(Float32(x)), round(Float32(y))), col, String(text))
    end
    return nothing
end

"""
    draw_text_mid(dl, role, size, x, mid_y, col, text; line = 1.25, italic = false) -> Float32

Draw one line of `text` from `x` in a CSS line box `line` times the font size high,
centred on `mid_y`, as a browser draws it (see `text_y`). Returns the text width.
`italic` slants the glyphs about the baseline, as a browser does for a font without an
italic face (the app ships none).
"""
function draw_text_mid(dl, role::FontRole, size::Real, x::Real, mid_y::Real, col::UInt32,
        text::AbstractString; line::Real = 1.25, italic::Bool = false)::Float32
    isempty(text) && return 0f0
    return with_font(role, size) do
        y = text_y(role, size, mid_y; line)
        first_vertex = italic ? vertex_count(dl) : 0
        ig.AddText(dl, (round(Float32(x)), y), col, String(text))
        italic && slant_since!(dl, first_vertex, y + unsafe_load(ig.GetFontBaked().Ascent), SLANT)
        Float32(ig.CalcTextSize(text).x)
    end
end

const SLANT = 0.2f0   # the slant of synthetic italics, as Chromium's (about 11 degrees)

vertex_count(dl) = Int(unsafe_load(dl.VtxBuffer).Size)

# Slant the vertices added to `dl` since `first`: each moves right by `k` times its height
# above `baseline`.
function slant_since!(dl, first::Int, baseline::Real, k::Float32)
    buf = unsafe_load(dl.VtxBuffer)
    data = Ptr{ig.lib.ImDrawVert}(buf.Data)
    for i in first+1:Int(buf.Size)
        v = unsafe_load(data, i)
        pos = ig.ImVec2(v.pos.x + (Float32(baseline) - v.pos.y) * k, v.pos.y)
        unsafe_store!(data, ig.lib.ImDrawVert(pos, v.uv, v.col), i)
    end
    return nothing
end

"""
    spaced_width(role, size, text, spacing) -> Float32

The width of `text` drawn with `spacing` device px after each character (CSS `letter-spacing`).
"""
spaced_width(role::FontRole, size::Real, text::AbstractString, spacing::Real)::Float32 =
    text_width(role, size, text) + Float32(spacing) * length(text)

"""
    draw_spaced_text(dl, role, size, x, mid_y, col, text, spacing)

`draw_text_mid` with `spacing` device px after each character (CSS `letter-spacing`).
"""
function draw_spaced_text(dl, role::FontRole, size::Real, x::Real, mid_y::Real, col::UInt32,
        text::AbstractString, spacing::Real)
    with_font(role, size) do
        y = text_y(role, size, mid_y)
        cx = Float32(x)
        for c in text
            ch = string(c)
            ig.AddText(dl, (round(cx), y), col, ch)
            cx += Float32(ig.CalcTextSize(ch).x) + Float32(spacing)
        end
    end
    return nothing
end

"""
    field_text(buffer) -> String

The text of a text field's zero-ended byte `buffer`.
"""
function field_text(buf::Vector{UInt8})::String
    n = something(findfirst(==(0x00), buf), length(buf) + 1) - 1
    return String(buf[1:n])
end

"""
    set_field!(buffer, text)

Put `text` into a text field's byte `buffer`, cut at a character so it fits with its zero.
"""
function set_field!(buf::Vector{UInt8}, text::AbstractString)
    fill!(buf, 0x00)
    bytes = codeunits(String(text))
    n = length(bytes)
    while n > length(buf) - 1 || (n > 0 && n < length(bytes) && (bytes[n+1] & 0xc0) == 0x80)
        n -= 1
    end
    copyto!(buf, 1, bytes, 1, n)
    return buf
end

"""
    text_input!(app, id, buffer, b; flags = 0, size = 12.5, role = FONT_REGULAR,
                focus = false, input = false) -> (changed, active)

An ImGui text field for `buffer` that fills box `b` with no frame of its own: the caller
draws the frame. The text sits where a browser puts it, in font `role` (`FONT_MONO` for
code and paths): centred as a line of `b`'s height, or with `input` as the text of an
`<input>` taller than its line (`input_text_y`). `focus` gives it the keyboard focus.
While text is selected the caret is hidden, as in Chromium.
Returns whether the text changed and whether the field has the focus.
"""
function text_input!(app, id::AbstractString, buf::Vector{UInt8}, b::Box; flags::Integer = 0,
        size::Real = BODY_FONT_SIZE, role::FontRole = FONT_REGULAR, focus::Bool = false,
        input::Bool = false)
    changed = with_font(role, size) do
        top = input ? input_text_y(role, size, centre_y(b)) : text_y(role, size, centre_y(b))
        pad_y = max(top - b.y0, 0f0)
        ig.PushStyleVar(ig.ImGuiStyleVar_FramePadding, (0f0, pad_y))
        ig.PushStyleVar(ig.ImGuiStyleVar_FrameBorderSize, 0f0)
        # No frame, and no selection fill of ImGui's (it is 3 px taller than Chromium's):
        # `draw_selected_text` draws it. No caret over a selection (the state of the last frame).
        st = lib.igGetInputTextState(ig.GetID(id))
        selecting = st != C_NULL && lib.ImGuiInputTextState_HasSelection(st)
        for slot in (ig.ImGuiCol_FrameBg, ig.ImGuiCol_FrameBgHovered, ig.ImGuiCol_FrameBgActive,
                ig.ImGuiCol_TextSelectedBg)
            ig.PushStyleColor(slot, (0f0, 0f0, 0f0, 0f0))
        end
        selecting && ig.PushStyleColor(lib.ImGuiCol_InputTextCursor, (0f0, 0f0, 0f0, 0f0))
        ig.SetCursorScreenPos((b.x0, b.y0))
        ig.SetNextItemWidth(max(width(b), 1f0))
        focus && ig.SetKeyboardFocusHere()
        c = ig.InputText(id, buf, length(buf), flags)
        ig.PopStyleColor(selecting ? 5 : 4)
        ig.PopStyleVar(2)
        ig.IsItemActive() && draw_selected_text(app, buf, b, size, top; role)
        c
    end
    return changed, ig.IsItemActive()
end

# Selected text of the active field (the last item) as Chromium draws it: white on
# `text_selection`, over ImGui's own text. The box is as high as the rounded ascender plus
# descender (`text_baseline`) and centred in the field, a half pixel rounded up, as the
# prototype's render shows. `top` is where ImGui put the text. Call it inside `with_font(role, size)`.
function draw_selected_text(app, buf::Vector{UInt8}, b::Box, size::Real, top::Real;
        role::FontRole = FONT_REGULAR)
    st = lib.igGetInputTextState(ig.GetItemID())
    (st == C_NULL || !lib.ImGuiInputTextState_HasSelection(st)) && return nothing
    i, j = minmax(Int(lib.ImGuiInputTextState_GetSelectionStart(st)),
        Int(lib.ImGuiInputTextState_GetSelectionEnd(st)))
    bytes = codeunits(field_text(buf))
    j = min(j, length(bytes))
    i >= j && return nothing
    scroll = unsafe_load(st).Scroll.x
    x0 = b.x0 - scroll + ig.CalcTextSize(String(bytes[1:i])).x
    x1 = b.x0 - scroll + ig.CalcTextSize(String(bytes[1:j])).x
    _, ascender, descender = text_baseline(role, size, centre_y(b))
    y0 = rnd(centre_y(b) - (ascender + descender) / 2)
    y1 = y0 + ascender + descender
    dl = ig.GetWindowDrawList()
    ig.PushClipRect((b.x0, b.y0), (b.x1, b.y1), true)
    ig.AddRectFilled(dl, (round(x0), y0), (round(x1), y1), u32(app.tokens.text_selection))
    ig.AddText(dl, (round(x0), top), u32(app.tokens.on_accent), String(bytes[i+1:j]))
    ig.PopClipRect()
    return nothing
end

"""
    elide(measure, text, max_width; role = FONT_REGULAR, size = 12.5) -> String

`text`, or as much of it as fits in `max_width` device pixels followed by "...", as CSS
`text-overflow: ellipsis` cuts it. When not even one character and "..." fit, `""`.
`measure(role, size, text)` is the text width in device pixels.
"""
function elide(measure, text::AbstractString, max_width::Real; role::FontRole = FONT_REGULAR,
        size::Real = BODY_FONT_SIZE)::String
    measure(role, size, text) <= max_width && return String(text)
    chars = collect(text)
    for n in length(chars)-1:-1:1
        cut = rstrip(String(chars[1:n])) * "..."
        measure(role, size, cut) <= max_width && return cut
    end
    return ""
end

"""
    wrap_lines(role, size, text, max_width) -> Vector{String}

Break `text` into lines no wider than `max_width` device pixels, at spaces.
A single word wider than that keeps a line of its own.
"""
function wrap_lines(role::FontRole, size::Real, text::AbstractString, max_width::Real)::Vector{String}
    lines = String[]
    with_font(role, size) do
        for para in split(text, '\n')
            line = ""
            for word in wrap_units(para)
                trial = isempty(line) ? String(word) : line * " " * word
                if isempty(line) || ig.CalcTextSize(trial).x <= max_width
                    line = trial
                else
                    push!(lines, line)
                    line = String(word)
                end
            end
            push!(lines, line)
        end
    end
    return lines
end

# An operator standing alone between two words, as in `MAG_IGRF = MAG - IGRF`.
const WRAP_OPERATORS = ("=", "-", "+", "*", "/", "^", "<", ">", "<=", ">=", "==", "!=")

"""
    wrap_units(text) -> Vector{String}

The words of `text` for `wrap_lines`. An operator that stands alone between two words
keeps them together, so an expression such as `MAG_IGRF = MAG - IGRF` never breaks in
its middle and no line starts with "= MAG". A unit that is wider than the line still
gets a line of its own.
"""
function wrap_units(text::AbstractString)::Vector{String}
    words = split(text, ' '; keepempty = false)
    units = String[]
    glue = false   # the last word was an operator: the next word joins its unit
    for (k, w) in enumerate(words)
        op = w in WRAP_OPERATORS && 1 < k < length(words)
        if !isempty(units) && (op || glue)
            units[end] *= " " * w
        else
            push!(units, String(w))
        end
        glue = op
    end
    return units
end

"""
    draw_shadow(dl, b, radius, dy, blur, col, alpha = 1)

A soft shadow under box `b`, like CSS `box-shadow: 0 dy blur col`. Stacked rounded
rectangles stand in for the blur. Sizes are device pixels.
"""
function draw_shadow(dl, b::Box, radius::Real, dy::Real, blur::Real, col::NTuple{4,Float32},
        alpha::Real = 1)
    n = 10
    reach = 0.625f0 * Float32(blur)   # a linear ramp of the same slope as the blur
    a = col[4] * Float32(alpha)
    a <= 0 && return nothing
    # Each of `n` layers adds the same alpha, so the stack reaches `a` under the box.
    layer = 1 - (1 - a)^(1f0 / n)
    c = (col[1], col[2], col[3], layer)
    for k in 1:n
        e = reach * (2k - n - 1) / n
        r = max(0f0, Float32(radius) + e)
        ig.AddRectFilled(dl, (b.x0 - e, b.y0 - e + dy), (b.x1 + e, b.y1 + e + dy), u32(c), r)
    end
    return nothing
end

"""
    hit(id, b; flags = 0, overlap = false) -> (clicked, hovered, held)

An invisible ImGui button over box `b`, so every control is an item with an id that the
test engine can click. Call it inside an ImGui window.

With `overlap`, items submitted after it on top of it (a row's chevron) take the mouse
over themselves, and `hovered` stays true while the mouse is on them.
"""
function hit(id::AbstractString, b::Box; flags::Integer = 0, overlap::Bool = false)
    ig.SetCursorScreenPos((b.x0, b.y0))
    overlap && lib.igSetNextItemAllowOverlap()
    clicked = ig.InvisibleButton(id, (max(width(b), 1f0), max(height(b), 1f0)), flags)
    hovered = overlap ? ig.IsItemHovered(lib.ImGuiHoveredFlags_AllowWhenOverlappedByItem) :
        ig.IsItemHovered()
    return clicked, hovered, ig.IsItemActive()
end

"""
    button_width(app, label; primary = false, small = false, link = false) -> Float32

The width of `button` for `label`, in device pixels.
"""
function button_width(app, label::AbstractString; primary::Bool = false, small::Bool = false,
        link::Bool = false)
    s = app.window.scale
    size = small ? 11.5 : BODY_FONT_SIZE
    role = primary ? FONT_SEMIBOLD : FONT_REGULAR
    pad = link ? 12 : small ? 16 : 24   # `.btn.link` has padding 0 6
    return text_width(role, size, label) + px(s, pad) + 2 * hairline(s)
end

"""
    button(app, id, label, x, y; primary = false, small = false, link = false, enabled = true,
           busy = false, dim = false, alpha = 1, dl = window draw list) -> Bool

A prototype `.btn` at `(x, y)`: 26 high (22 when `small`), radius 6 (5), 1 px
`input_border` on `input`; `hover` and `border_strong` on hover, `pressed` when held.
A `primary` button is `accent` with semibold `on_accent` text; it is lighter on hover and
half transparent when disabled. A `link` button (`.btn.link`) has no frame and no fill,
`accent_text` text and 6 px padding; it shows `hover` (`pressed` when held) under the mouse.
A `busy` button keeps its width, shows a spinner in place of its label and takes no clicks.
A `dim` button has `text_dim` text, as a button in the prototype's `.empty` state.
Returns true when clicked while enabled.
"""
function button(app, id::AbstractString, label::AbstractString, x::Real, y::Real;
        primary::Bool = false, small::Bool = false, link::Bool = false, enabled::Bool = true,
        busy::Bool = false, dim::Bool = false, alpha::Real = 1, dl = ig.GetWindowDrawList())::Bool
    w = app.window::Window
    t = app.tokens
    s = w.scale
    bw = button_width(app, label; primary, small, link)
    b = Box(round(Float32(x)), round(Float32(y)), round(Float32(x)) + round(bw),
        round(Float32(y)) + px(s, small ? 22 : 26))
    clicked, hovered, held = hit(id, b)
    a = Float32(alpha) * (primary && !enabled ? 0.5f0 : 1f0)   # busy keeps the full colour
    enabled &= !busy
    on = enabled && hovered
    radius = px(s, small ? 5 : 6)
    if primary
        fill = on ? brighter(t.accent, 1.08f0) : t.accent
        ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(fill, a), radius)
    elseif link
        on && ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(held ? t.pressed : t.hover, a), radius)
    else
        fill = on && held ? t.pressed : on ? t.hover : t.input
        ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(fill, a), radius)
        ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(on ? t.border_strong : t.input_border, a),
            radius, hairline(s))
    end
    size = small ? 11.5 : BODY_FONT_SIZE
    role = primary ? FONT_SEMIBOLD : FONT_REGULAR
    col = primary ? t.on_accent : !enabled ? t.text_disabled : link ? t.accent_text : dim ? t.text_dim : t.text
    if busy
        draw_spinner(app, dl, (b.x0 + b.x1) / 2, centre_y(b); col = primary ? t.on_accent : t.accent)
        request_frames!(w)   # the spinner turns
    else
        tw = text_width(role, size, label)
        draw_text_mid(dl, role, size, b.x0 + (width(b) - tw) / 2, centre_y(b), u32(col, a), label)
    end
    w.input_frames == 0 && hovered && request_frames!(w)
    return clicked && enabled
end

# CSS `filter: brightness(f)`: every channel times `f`.
brighter(c::NTuple{4,Float32}, f::Float32) = (min(c[1] * f, 1f0), min(c[2] * f, 1f0),
    min(c[3] * f, 1f0), c[4])

"""
    icon_button(app, id, icon, b; size = 16, radius = 4, style = :normal, alpha = 1, dl) ->
        (clicked, hovered)

A frameless icon button (`.ibtn`) over box `b`, `hover` fill on hover.
"""
function icon_button(app, id::AbstractString, icon::AbstractString, b::Box; size::Integer = 16,
        radius::Real = 4, style::Symbol = :normal, alpha::Real = 1, enabled::Bool = true,
        dl = ig.GetWindowDrawList())
    s = app.window.scale
    clicked, hovered, held = hit(id, b)
    if enabled && hovered
        ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1),
            u32(held ? app.tokens.pressed : app.tokens.hover, alpha), px(s, radius))
    end
    d = px(s, size)
    draw_icon(dl, icon, (rnd(b.x0 + (width(b) - d) / 2), rnd(b.y0 + (height(b) - d) / 2)), size;
        style = enabled ? style : :disabled, alpha)
    return clicked && enabled, hovered
end

"""
    kbd_width(app, key) -> Float32

The width of `draw_kbd` for `key`, in device pixels.
"""
kbd_width(app, key::AbstractString) =
    text_width(FONT_MONO, 11, key) + fpx(app.window.scale, 10) + 2 * hairline(app.window.scale)

"""
    draw_kbd(app, dl, x, mid, key) -> Float32

A key cap, as the prototype's `.kbd`, from `x` and centred on `mid`: mono 11 `text_dim` on
`pane`, padding 5, a 1 px `border_strong` frame that is 2 px at the bottom, radius 4, 19 high.
Returns its width.
"""
function draw_kbd(app, dl, x::Real, mid::Real, key::AbstractString)::Float32
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    w = kbd_width(app, key)
    b = snap(Box(x, mid - f(19) / 2, x + w, mid + f(19) / 2))
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.border_strong), f(4))
    ig.AddRectFilled(dl, (b.x0 + hl, b.y0 + hl), (b.x1 - hl, b.y1 - 2 * hl), u32(t.pane), f(4) - hl)
    # The text sits in the 16 px line inside the frame.
    draw_text_mid(dl, FONT_MONO, 11, b.x0 + hl + f(5), b.y0 + hl + f(8), u32(t.text_dim), key; line = 16 / 11)
    return w
end
