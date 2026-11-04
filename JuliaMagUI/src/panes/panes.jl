# The side panes: their widths, the frames of the left and right pane with their header
# bands of text tabs, the splitters that resize them, and the search box they share. The
# Data tab body is in data.jl, the Layers tab body in layers.jl, the Jobs tab body in jobs.jl,
# the Tools pane in tools.jl, the Layer Style pane in style.jl.

# Sizes in logical pixels (prototype CSS).
const PANE_HEAD_H = 34
const LEFT_DEFAULT = 272
const LEFT_RANGE = (200, 480)
const RIGHT_DEFAULT = 300
const RIGHT_RANGE = (240, 480)
const SPLITTER_W = 6

"""
    pane_width(x, range, default) -> Float32

A pane width from the settings, clamped to `range`. A width that is not a finite
number (a hand-edited settings file) gives `default`.
"""
function pane_width(x, range::Tuple{Real,Real}, default::Real)::Float32
    (x isa Real && !(x isa Bool) && isfinite(x)) || return Float32(default)
    return Float32(clamp(x, range[1], range[2]))
end

"""
    drag_width(start, dx, scale, side, range) -> Float32

The width in logical pixels of a pane that was `start` wide when the drag began, after the
mouse moved `dx` device pixels at content `scale`. The `:left` pane grows when the mouse
moves right, the `:right` pane when it moves left. Clamped to `range`.
"""
function drag_width(start::Real, dx::Real, scale::Real, side::Symbol, range::Tuple{Real,Real})::Float32
    delta = Float32(dx) / Float32(scale)
    w = side === :left ? Float32(start) + delta : Float32(start) - delta
    return Float32(clamp(round(w), range[1], range[2]))
end

# The width setting, range and default of each side pane.
pane_setting(side::Symbol) = side === :left ? (:left_width, LEFT_RANGE, LEFT_DEFAULT) :
    (:right_width, RIGHT_RANGE, RIGHT_DEFAULT)

"""
A splitter drag: the pane `side`, its width and the mouse x when the drag began, and whether
the mouse has `moved` since (a plain click changes nothing).
"""
mutable struct SplitterDrag
    side::Symbol
    start_width::Float32
    start_x::Float32
    moved::Bool
end

"""
    splitter!(app, side, edge, y0, y1; shown = nothing) -> Bool

The splitter on the inner edge of the `side` pane (`:left` or `:right`) at device x
`edge`, from `y0` to `y1`: 6 px wide over the edge, as the prototype's `.splitter`.
A drag changes the pane width in the settings at once once the mouse moved; the release
then saves the settings. A plain click changes nothing.
It starts from the width the pane is `shown` at, in logical pixels (in a narrow window
that can be less than the setting), so the edge follows the mouse.
Returns true while the mouse is on it or drags it; then `paint_splitter` draws its line.
Submit it before the items it overlaps, so it takes the mouse there.
"""
function splitter!(app, side::Symbol, edge::Real, y0::Real, y1::Real;
        shown::Union{Nothing,Real} = nothing)::Bool
    s = app.window.scale
    half = fpx(s, SPLITTER_W / 2)
    _, hovered, held = hit("splitter", Box(edge - half, y0, edge + half, y1))
    field, range, default = pane_setting(side)
    mouse = unsafe_load(ig.GetIO().MousePos)
    if ig.IsItemActivated()
        start = shown === nothing ? pane_width(getfield(app.config, field), range, default) :
            Float32(clamp(shown, range[1], range[2]))
        app.ui.drag = SplitterDrag(side, start, mouse.x, false)
    end
    d = app.ui.drag
    if held && d isa SplitterDrag && d.side === side
        # Only a real move writes the width: a click on a squeezed pane keeps the saved one.
        d.moved |= mouse.x != d.start_x
        d.moved && setfield!(app.config, field, drag_width(d.start_width, mouse.x - d.start_x, s, side, range))
    end
    if ig.IsItemDeactivated() && d isa SplitterDrag && d.side === side
        app.ui.drag = nothing
        d.moved && save_settings!(app)
    end
    (hovered || held) && ig.SetMouseCursor(ig.ImGuiMouseCursor_ResizeEW)
    return hovered || held
end

"""
    paint_splitter(app, dl, edge, y0, y1)

The line of a hot splitter: 2 px of `accent` at 70 % over the pane edge at `edge`.
Draw it after what lies under the splitter.
"""
function paint_splitter(app, dl, edge::Real, y0::Real, y1::Real)
    s = app.window.scale
    ig.AddRectFilled(dl, (rnd(edge - fpx(s, 1)), y0), (rnd(edge + fpx(s, 1)), y1),
        u32(app.tokens.accent, 0.7))
    return nothing
end

const SCROLLBAR_W = 10

"A drag on the scrollbar `id`, `grab` px below the thumb's top (NaN: a click on the track)."
struct ScrollDrag
    id::UInt32
    grab::Float32
end

"""
    scroll_area!(app, id, view, content_h, scroll) -> (scroll, has_bar)

Scrolling for a pane list in box `view` whose content is `content_h` device px high:
the mouse wheel over it scrolls 100 px a step, and when the content is taller than the
view a 10 px scrollbar sits at its right, as the prototype's `.scroll` (a 6 px
`border_strong` thumb, radius 3). Drag the thumb, or click the track to move a page.
Returns the new scroll, clamped, and whether the bar is shown (the rows then end 10 px
earlier). Submit it before the rows, so the bar takes the mouse.
"""
function scroll_area!(app, id::AbstractString, view::Box, content_h::Real, scroll::Real)
    s = app.window.scale
    io = unsafe_load(ig.GetIO())
    mouse = io.MousePos
    max_scroll = max(Float32(content_h) - height(view), 0f0)
    if max_scroll > 0 && io.MouseWheel != 0 && inside(view, mouse.x, mouse.y) && ig.IsWindowHovered()
        scroll -= io.MouseWheel * fpx(s, TREE_WHEEL)
    end
    scroll = clamp(Float32(scroll), 0f0, max_scroll)
    max_scroll == 0 && return 0f0, false
    bar = Box(view.x1 - fpx(s, SCROLLBAR_W), view.y0, view.x1, view.y1)
    len = max(fpx(s, 20), height(view) * height(view) / Float32(content_h))
    travel = height(view) - len
    top = view.y0 + travel * scroll / max_scroll
    _, _, held = hit(id, bar)
    key = ig.GetItemID()
    if ig.IsItemActivated()
        on_thumb = top <= mouse.y < top + len
        app.ui.drag = ScrollDrag(key, on_thumb ? mouse.y - top : NaN32)
        on_thumb || (scroll = clamp(scroll + (mouse.y < top ? -1 : 1) * height(view), 0f0, max_scroll))
    end
    d = app.ui.drag
    if held && d isa ScrollDrag && d.id == key && !isnan(d.grab) && travel > 0
        scroll = clamp((mouse.y - d.grab - view.y0) / travel * max_scroll, 0f0, max_scroll)
    end
    ig.IsItemDeactivated() && d isa ScrollDrag && d.id == key && (app.ui.drag = nothing)
    top = view.y0 + travel * scroll / max_scroll
    thumb = snap(Box(bar.x0 + fpx(s, 2), top + fpx(s, 2), bar.x1 - fpx(s, 2), top + len - fpx(s, 2)))
    ig.AddRectFilled(ig.GetWindowDrawList(), (thumb.x0, thumb.y0), (thumb.x1, thumb.y1),
        u32(app.tokens.border_strong), fpx(s, 3))
    return scroll, true
end

"The number of jobs that run now. Reads the live job status."
running_jobs(snap) = snap === nothing ? 0 : count(j -> Core.status(j.job) == Core.JOB_RUNNING, snap.jobs)

const LEFT_TABS = (:data => "Data", :layers => "Layers", :jobs => "Jobs")
const BADGE_FONT_SIZE = 10.5f0

# The width of the prototype's `.badge` with `text`: 16 high, at least 16 wide, padding 5.
badge_width(scale::Real, text::AbstractString) =
    max(fpx(scale, 16), text_width(FONT_SEMIBOLD, BADGE_FONT_SIZE, text) + fpx(scale, 10))

"""
    draw_left_pane(app, dl, b) -> Bool

The left pane: `pane` fill, a 1 px `border` on the right, the 34 px header band
(`pane_header`, 1 px `border` at the bottom) with the text tabs Data, Layers and Jobs, and the body
of the open tab. The Jobs tab has a round `accent` badge with the number of running jobs.
The splitter on the right edge is submitted first. Returns true when the splitter is hot:
then call `paint_splitter` after the central area.
"""
function draw_left_pane(app, dl, b::Box)::Bool
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    hl = hairline(s)
    ig.PushID("left")
    hot = splitter!(app, :left, b.x1, b.y0, b.y1; shown = width(b) / s)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.pane))
    ig.AddRectFilled(dl, (b.x1 - hl, b.y0), (b.x1, b.y1), u32(t.border))
    head = Box(b.x0, b.y0, b.x1 - hl, b.y0 + p(PANE_HEAD_H))
    ig.AddRectFilled(dl, (head.x0, head.y0), (head.x1, head.y1), u32(t.pane_header))
    ig.AddRectFilled(dl, (head.x0, head.y1 - hl), (head.x1, head.y1), u32(t.border))
    running = running_jobs(app.snap)
    x = head.x0 + p(6)
    for (key, label) in LEFT_TABS
        on = app.ui.left_tab === key
        tw = text_width(FONT_SEMIBOLD, BODY_FONT_SIZE, label)   # the semibold width, so tabs never move
        badge = key === :jobs && running > 0 ? string(running) : ""
        bw = isempty(badge) ? 0f0 : fpx(s, 6) + badge_width(s, badge)
        tab = Box(x, head.y0, x + round(tw + bw + p(18)), head.y1 - hl)
        clicked, _ = draw_pane_tab(app, dl, tab, label, on)
        clicked && (app.ui.left_tab = key)
        isempty(badge) || draw_badge(app, dl, tab.x0 + p(9) + tw + fpx(s, 6), centre_y(tab), badge)
        x = tab.x1 + p(2)
    end
    body = Box(b.x0, head.y1, b.x1 - hl, b.y1)
    tab = app.ui.left_tab
    tab === :data ? draw_data_tab(app, dl, body) : tab === :layers ? draw_layers_tab(app, dl, body) :
        draw_jobs_tab(app, dl, body)
    ig.PopID()
    return hot
end

"""
    draw_pane_tab(app, dl, tab, label, on; overlap = false) -> (clicked, hovered)

A text tab of a pane header (`.ptab`) in box `tab`: the label 9 px in, centred in its
semibold width so the tabs never move, `text` and semibold when `on`, else `text_dim`; a
`hover` fill inset 5 px under the mouse; a 2 px `accent` line at the bottom when `on`.
With `overlap`, an item submitted after it on top of it (its close x) takes the mouse there.
"""
function draw_pane_tab(app, dl, tab::Box, label::AbstractString, on::Bool; overlap::Bool = false)
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    clicked, hovered, _ = hit(label, tab; overlap)
    if hovered && !on
        ig.AddRectFilled(dl, (tab.x0 + p(1), tab.y0 + p(5)), (tab.x1 - p(1), tab.y1 - p(5)),
            u32(t.hover), p(4))
    end
    tw = text_width(FONT_SEMIBOLD, BODY_FONT_SIZE, label)
    role = on ? FONT_SEMIBOLD : FONT_REGULAR
    lw = text_width(role, BODY_FONT_SIZE, label)
    lx = tab.x0 + p(9) + (tw - lw) / 2
    draw_text_mid(dl, role, BODY_FONT_SIZE, lx, centre_y(tab), u32(on ? t.text : t.text_dim), label)
    on && ig.AddRectFilled(dl, (tab.x0 + p(4), tab.y1 - p(2)), (tab.x1 - p(4), tab.y1), u32(t.accent))
    return clicked, hovered
end

# --- The right pane ---

const RIGHT_TABS = (:tools => "Tools", :style => "Layer Style")

"Show the right pane `which` (`:tools` or `:style`), opening its tab when it is not open."
function open_right_pane!(app, which::Symbol)
    ui = app.ui
    which in ui.right_tabs || push!(ui.right_tabs, which)
    ui.right_active = which
    return nothing
end

"Close the tab of the right pane `which`; the last tab left is shown. The pane hides with no tab."
function close_right_pane!(app, which::Symbol)
    ui = app.ui
    filter!(!=(which), ui.right_tabs)
    ui.right_active === which && (ui.right_active = isempty(ui.right_tabs) ? :none : last(ui.right_tabs))
    return nothing
end

"""
    toggle_right_pane!(app, which)

As the prototype's `toggleRight`: close the right pane `which` when it is shown, else ask to
show it (an `OpenPane` request).
"""
function toggle_right_pane!(app, which::Symbol)
    app.ui.right_active === which ? close_right_pane!(app, which) : request!(app, OpenPane(which))
    return nothing
end

function handle_request!(app, r::OpenPane)
    if r.which === :tools
        open_right_pane!(app, :tools)
    elseif r.which === :jobs
        app.ui.left_tab = :jobs
    else
        return false
    end
    return true
end

"""
    draw_right_pane(app, dl, b) -> Bool

The right pane, as the prototype's `#right`: `pane` fill, a 1 px `border` on the left, the
34 px header band with a tab per open pane (each with a 16 px close x) and "Close all
panes" at the right, and the body of the shown pane. The splitter on its left edge is
submitted first. Returns true when the splitter is hot: then call `paint_splitter` after.
"""
function draw_right_pane(app, dl, b::Box)::Bool
    ui = app.ui
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.PushID("right")
    hot = splitter!(app, :right, b.x0, b.y0, b.y1; shown = width(b) / s)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.pane))
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x0 + hl, b.y1), u32(t.border))
    head = Box(b.x0 + hl, b.y0, b.x1, b.y0 + p(PANE_HEAD_H))
    ig.AddRectFilled(dl, (head.x0, head.y0), (head.x1, head.y1), u32(t.pane_header))
    ig.AddRectFilled(dl, (head.x0, head.y1 - hl), (head.x1, head.y1), u32(t.border))
    x = head.x0 + p(6)
    closing = nothing
    for key in copy(ui.right_tabs)
        label = something(lookup_tab(key), string(key))
        tw = text_width(FONT_SEMIBOLD, BODY_FONT_SIZE, label)
        tab = Box(x, head.y0, x + round(tw + p(9 + 6 + 16 + 9)), head.y1 - hl)
        cb = Box(tab.x1 - p(9 + 16), round(centre_y(tab) - f(8)), tab.x1 - p(9), round(centre_y(tab) - f(8)) + p(16))
        # The close x comes after the tab: it takes the mouse there and is drawn on top.
        clicked, _ = draw_pane_tab(app, dl, tab, label, ui.right_active === key; overlap = true)
        clicked && (ui.right_active = key)
        closed, close_hot = icon_button(app, "Close " * label, "close", cb; size = 10, radius = 3,
            style = :dim, dl)
        close_hot && item_tip!(app, "Close " * label)
        closed && (closing = key)
        x = tab.x1 + p(2)
    end
    all_box = Box(head.x1 - p(6 + 22), round(centre_y(head) - hl / 2 - f(11)), head.x1 - p(6),
        round(centre_y(head) - hl / 2 - f(11)) + p(22))
    close_all, all_hot = icon_button(app, "Close all panes", "close", all_box; style = :dim)
    all_hot && item_tip!(app, "Close all panes")
    body = Box(head.x0, head.y1, b.x1, b.y1)
    ui.right_active === :tools && draw_tools_pane(app, dl, body)
    ui.right_active === :style && draw_style_pane(app, dl, body)
    ig.PopID()
    closing === nothing || close_right_pane!(app, closing)
    close_all && (empty!(ui.right_tabs); ui.right_active = :none)
    return hot
end

lookup_tab(key::Symbol) = (k = findfirst(p -> first(p) === key, RIGHT_TABS); k === nothing ? nothing : last(RIGHT_TABS[k]))

"""
    search_box!(app, dl, box, id, buffer, hint; flags = 0) -> (text, active)

A search box, as the prototype's `.search`, in `box` (28 high): `input` fill, 1 px
`border`, radius 6, the 15 px dim search icon 7 px in, and the text field `id` for
`buffer` 6 px after it (with the 1 by 2 px padding of an `<input>`); `hint` in
`placeholder` grey while it is empty. While the field has the
focus its border is a 2 px `accent` ring. Returns the text and whether the field is active.
"""
function search_box!(app, dl, box::Box, id::AbstractString, buf::Vector{UInt8}, hint::AbstractString;
        flags::Integer = 0)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.AddRectFilled(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.input), f(6))
    icon_x = box.x0 + hl + f(7)
    draw_icon(dl, "search", (rnd(icon_x), rnd(centre_y(box) - f(7.5))), 15; style = :dim)
    # The `<input>` keeps Chromium's own padding of 1 by 2 px.
    field = Box(icon_x + f(15 + 6 + 2), box.y0 + hl + f(1), box.x1 - hl - f(8 + 2), box.y1 - hl - f(1))
    changed, active = text_input!(app, id, buf, field; flags, input = true)
    text = field_text(buf)
    if isempty(text)
        shown = elide(text_width, hint, width(field))
        with_font(FONT_REGULAR, BODY_FONT_SIZE) do
            ig.AddText(dl, (round(field.x0), input_text_y(FONT_REGULAR, BODY_FONT_SIZE, centre_y(field))),
                u32(t.placeholder), shown)
        end
    end
    if active
        ig.AddRect(dl, (box.x0 - hl / 2, box.y0 - hl / 2), (box.x1 + hl / 2, box.y1 + hl / 2),
            u32(t.accent), f(6) + hl / 2, 2 * hl)
    else
        ig.AddRect(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.border), f(6), hl)
    end
    changed && request_frames!(app.window::Window)
    return text, active
end

# The prototype's `.badge`: a 16 px round `accent` pill with `on_accent` text, from `x`.
function draw_badge(app, dl, x::Real, mid::Real, text::AbstractString)
    s = app.window.scale
    t = app.tokens
    w = badge_width(s, text)
    h = fpx(s, 16)
    b = snap(Box(x, mid - h / 2, x + w, mid + h / 2))
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.accent), height(b) / 2)
    tw = text_width(FONT_SEMIBOLD, BADGE_FONT_SIZE, text)
    draw_text_mid(dl, FONT_SEMIBOLD, BADGE_FONT_SIZE, b.x0 + (width(b) - tw) / 2, centre_y(b),
        u32(t.on_accent), text; line = 1)
    return nothing
end
