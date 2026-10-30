# The side panes: their widths, the left pane frame with its header band of text tabs,
# and the splitters that resize them. The Data tab body is in data.jl, the Jobs tab body
# in jobs.jl; the right pane comes in a later task.

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

"A splitter drag: the pane `side`, its width and the mouse x when the drag began."
struct SplitterDrag
    side::Symbol
    start_width::Float32
    start_x::Float32
end

"""
    splitter!(app, side, edge, y0, y1) -> Bool

The splitter on the inner edge of the `side` pane (`:left` or `:right`) at device x
`edge`, from `y0` to `y1`: 6 px wide over the edge, as the prototype's `.splitter`.
A drag changes the pane width in the settings at once; the release saves the settings.
Returns true while the mouse is on it or drags it; then `paint_splitter` draws its line.
Submit it before the items it overlaps, so it takes the mouse there.
"""
function splitter!(app, side::Symbol, edge::Real, y0::Real, y1::Real)::Bool
    s = app.window.scale
    half = fpx(s, SPLITTER_W / 2)
    _, hovered, held = hit("splitter", Box(edge - half, y0, edge + half, y1))
    field, range, default = pane_setting(side)
    mouse = unsafe_load(ig.GetIO().MousePos)
    if ig.IsItemActivated()
        app.ui.drag = SplitterDrag(side, pane_width(getfield(app.config, field), range, default), mouse.x)
    end
    d = app.ui.drag
    if held && d isa SplitterDrag && d.side === side
        setfield!(app.config, field, drag_width(d.start_width, mouse.x - d.start_x, s, side, range))
    end
    if ig.IsItemDeactivated() && d isa SplitterDrag && d.side === side
        app.ui.drag = nothing
        save_settings!(app)
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

const LEFT_TABS = (:data => "Data", :jobs => "Jobs")
const BADGE_FONT_SIZE = 10.5f0

# The width of the prototype's `.badge` with `text`: 16 high, at least 16 wide, padding 5.
badge_width(scale::Real, text::AbstractString) =
    max(fpx(scale, 16), text_width(FONT_SEMIBOLD, BADGE_FONT_SIZE, text) + fpx(scale, 10))

"""
    draw_left_pane(app, dl, b) -> Bool

The left pane: `pane` fill, a 1 px `border` on the right, the 34 px header band
(`pane_header`, 1 px `border` at the bottom) with the text tabs Data and Jobs, and the body
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
    hot = splitter!(app, :left, b.x1, b.y0, b.y1)
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
        clicked, hovered, _ = hit(label, tab)
        clicked && (app.ui.left_tab = key)
        if hovered && !on
            ig.AddRectFilled(dl, (tab.x0 + p(1), tab.y0 + p(5)), (tab.x1 - p(1), tab.y1 - p(5)),
                u32(t.hover), p(4))
        end
        role = on ? FONT_SEMIBOLD : FONT_REGULAR
        lw = text_width(role, BODY_FONT_SIZE, label)
        lx = tab.x0 + p(9) + (tw - lw) / 2
        draw_text_mid(dl, role, BODY_FONT_SIZE, lx, centre_y(tab), u32(on ? t.text : t.text_dim), label)
        isempty(badge) || draw_badge(app, dl, tab.x0 + p(9) + tw + fpx(s, 6), centre_y(tab), badge)
        if on
            ig.AddRectFilled(dl, (tab.x0 + p(4), tab.y1 - p(2)), (tab.x1 - p(4), tab.y1), u32(t.accent))
        end
        x = tab.x1 + p(2)
    end
    body = Box(b.x0, head.y1, b.x1 - hl, b.y1)
    app.ui.left_tab === :data ? draw_data_tab(app, dl, body) : draw_jobs_tab(app, dl, body)
    ig.PopID()
    return hot
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
