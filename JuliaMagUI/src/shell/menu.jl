# Drop-down menus, as the prototype's `.menu`: the menu of a split button, the list of a
# combo. One menu is open at a time (`app.ui.menu`). The control that opened it is its
# owner: it calls `keep_menu!` in every frame it is drawn, and the menu closes when the
# owner is not drawn, on a click outside, on Esc and when a dialog opens or closes.
#
# A menu opened from a dialog (a combo in a form) belongs to that dialog: the dialog
# draws it as an ImGui popup of its own modal, so it sits above the dialog and takes
# input while the modal blocks everything under it (`draw_dialog_menu`).

const MENU_MIN_WIDTH = 200
const MENU_MAX_WIDTH = 360

"""
    MenuItem(label; icon = "", shortcut = "", checked = nothing, reason = nothing, help = "",
             id = "", danger = false, stay = false, ramp = "", action = app -> nothing)

One row of a menu. `checked` is `nothing` for a plain row, else the row shows a check
mark or a blank. `ramp` names a colour table the row shows as a strip before its label (the
rows of a Colour table combo). `reason` is why the row cannot run (it is greyed), or `nothing`.
`shortcut` is the dim text at the right: a key chord, or a hint such as a channel's units.
`help` and `id` go into its tooltip. A `danger` row (such as Remove) is red.
`action(app)` runs on a click; the menu then closes, unless the row says `stay` (the rows
of a checklist). `menu_separator()` makes the line between groups of rows, and
`menu_head(label)` a small title over a group (`head`).
"""
struct MenuItem
    label::String
    icon::String
    shortcut::String
    checked::Union{Nothing,Bool}
    reason::Union{Nothing,String}
    help::String
    id::String
    danger::Bool
    separator::Bool
    stay::Bool
    action::Function
    head::Bool
    ramp::String
end

MenuItem(label::AbstractString; icon::AbstractString = "", shortcut::AbstractString = "",
        checked::Union{Nothing,Bool} = nothing, reason::Union{Nothing,AbstractString} = nothing,
        help::AbstractString = "", id::AbstractString = "", danger::Bool = false,
        stay::Bool = false, ramp::AbstractString = "", action::Function = app -> nothing) =
    MenuItem(String(label), String(icon), String(shortcut), checked,
        reason === nothing ? nothing : String(reason), String(help), String(id), danger, false,
        stay, action, false, String(ramp))

"The line between two groups of menu rows (the prototype's `.msep`)."
menu_separator() = MenuItem("", "", "", nothing, nothing, "", "", false, true, false, app -> nothing, false, "")

"A small title over a group of menu rows (the prototype's `.mhead`), such as \"Tabs\"."
menu_head(label::AbstractString) =
    MenuItem(String(label), "", "", nothing, nothing, "", "", false, false, false, app -> nothing, true, "")

const MENU_ROW_H = 24
const MENU_SEPARATOR_H = 9   # 1 px line, 4 px above and below
const MENU_HEAD_H = 22
const MENU_HEAD_SIZE = 10.5f0   # semibold, upper case, 0.03 em apart
const MENU_RAMP_W = 48          # a row's colour table strip, 10 high, 8 px before the label
const MENU_RAMP_H = 10

"""
    OpenMenu

The open menu: its `owner` (an id of the control that opened it), the `anchor` box of
that control, the `items`, the smallest width and the `gap` to the anchor in logical
pixels, and whether the owner was drawn in this frame (`seen`). `box` is where the menu was drawn last.
`level` is the number of dialogs open when it opened: 0 for a menu of the shell, k for a
menu of the dialog at level k. `ref` is the ImGui name of its window, where test engine
references to its rows start (`"###menu"` for the shell's menu).
A menu taller than the window scrolls: `scroll` is how far, in device px. `key` is the row
the keyboard highlights (0 for none); `reveal` scrolls the checked row into view once.
`mouse_lit`: the mouse, not the keyboard, lit the row `key`.
"""
mutable struct OpenMenu
    owner::String
    anchor::Box
    items::Vector{MenuItem}
    min_width::Float32
    gap::Float32
    seen::Bool
    fresh::Bool
    box::Box
    level::Int
    ref::String
    scroll::Float32
    key::Int
    reveal::Bool
    mouse_lit::Bool
end

"""
    MenuLayout

The menu box and its rows, in device pixels. A menu taller than the window keeps its box
in the window and its rows move up by `scroll` (0 to `scroll_max`).
"""
struct MenuLayout
    box::Box
    rows::Vector{Box}
    scroll::Float32
    scroll_max::Float32
end

"""
    menu_layout(anchor, items, viewport, scale, measure; min_width = 200, gap = 2,
                scroll = 0) -> MenuLayout

Lay out a menu as the prototype's `openMenu`: under `anchor` with `gap` px between, or
above it when there is no room below; moved left to stay 8 px inside `viewport`. A
context menu passes the mouse point as an empty `anchor` and `gap = 0`. Padding 4, 1 px
border, rows 24 high, separators 9. A row is 6 + icon 16 + 8 + (ramp 48 + 8) + label +
(16 + shortcut) + 10 wide. The menu is `min_width` to 360 wide. `measure(text, size)` is the regular text
width in device pixels. It is at most the viewport's height less 16 px (the prototype's
`max-height: calc(100vh - 16px)`); its rows then scroll by `scroll`, clamped.
"""
function menu_layout(anchor::Box, items::AbstractVector{MenuItem}, viewport::Box, scale::Real,
        measure; min_width::Real = MENU_MIN_WIDTH, gap::Real = 2, scroll::Real = 0)::MenuLayout
    p(v) = px(scale, v)
    hl = hairline(scale)
    icons = any(it -> !isempty(it.icon) || it.checked !== nothing, items)
    row_h(it) = p(it.separator ? MENU_SEPARATOR_H : it.head ? MENU_HEAD_H : MENU_ROW_H)
    row_w = 0f0
    for it in items
        it.separator && continue
        if it.head
            row_w = max(row_w, p(16) + measure(uppercase(it.label), MENU_HEAD_SIZE))
            continue
        end
        w = p(6) + (icons ? p(24) : 0f0) + (isempty(it.ramp) ? 0f0 : p(MENU_RAMP_W + 8)) +
            measure(it.label, BODY_FONT_SIZE) + p(10)
        isempty(it.shortcut) || (w += p(16) + measure(it.shortcut, 11))
        row_w = max(row_w, w)
    end
    w = max(min(round(row_w + p(8) + 2 * hl), p(MENU_MAX_WIDTH)), p(min_width))
    content = 2 * hl + p(8) + sum(row_h, items; init = 0f0)
    h = min(content, height(viewport) - p(16))
    scroll_max = content - h
    top_scroll = clamp(Float32(scroll), 0f0, scroll_max)
    x = anchor.x0
    y = anchor.y1 + p(gap)
    y + h > viewport.y1 - p(8) && (y = max(viewport.y0 + p(8), anchor.y0 - p(gap) - h))
    x + w > viewport.x1 - p(8) && (x = viewport.x1 - p(8) - w)
    x = max(viewport.x0 + p(8), x)
    box = Box(round(x), round(y), round(x) + w, round(y) + h)
    rows = Box[]
    ry = box.y0 + hl + p(4) - top_scroll
    for it in items
        push!(rows, Box(box.x0 + hl + p(4), ry, box.x1 - hl - p(4), ry + row_h(it)))
        ry += row_h(it)
    end
    return MenuLayout(box, rows, top_scroll, scroll_max)
end

"""
    open_menu!(app, owner, anchor, items; min_width = 200, gap = 2)

Open a menu for the control `owner` under its box `anchor`, `gap` px below it. It replaces
any open menu. Opened while a dialog is open, it belongs to the top dialog.
"""
function open_menu!(app, owner::AbstractString, anchor::Box, items::Vector{MenuItem};
        min_width::Real = MENU_MIN_WIDTH, gap::Real = 2)
    app.ui.menu = OpenMenu(String(owner), anchor, items, Float32(min_width), Float32(gap), true,
        true, anchor, length(app.ui.dialogs), "###menu", 0f0, 0, true, false)
    return nothing
end

"Is the menu of `owner` open?"
menu_open(app, owner::AbstractString) =
    (m = app.ui.menu; m isa OpenMenu && m.owner == owner)

close_menu!(app) = (app.ui.menu = nothing; nothing)

"""
    toggle_menu!(app, owner, anchor, items; min_width = 200)

Open the menu of `owner`, or close it when it is open. `items()` makes the rows.
"""
function toggle_menu!(app, owner::AbstractString, anchor::Box, items; min_width::Real = MENU_MIN_WIDTH)
    menu_open(app, owner) ? close_menu!(app) : open_menu!(app, owner, anchor, items(); min_width)
    return nothing
end

"""
    keep_menu!(app, owner, anchor; items = nothing)

Called by a control in each frame it is drawn: when its menu is open, the menu stays open
and follows the control's box `anchor` (a scrolled ribbon moves it). `items` replaces the
rows, so a menu whose rows come from the project stays current while it is open.
"""
function keep_menu!(app, owner::AbstractString, anchor::Box;
        items::Union{Nothing,Vector{MenuItem}} = nothing)
    m = app.ui.menu
    if m isa OpenMenu && m.owner == owner
        m.anchor = anchor
        m.seen = true
        items === nothing || (m.items = items)
    end
    return nothing
end

"Is device point `(x, y)` on the open menu?"
inside_menu(app, x::Real, y::Real) = (m = app.ui.menu; m isa OpenMenu && inside(m.box, x, y))

# Call at the start of a frame: the owner must show itself again.
function begin_menu_frame!(app)
    m = app.ui.menu
    m isa OpenMenu && (m.seen = false)
    return nothing
end

const MENU_FLAGS = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
    ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoScrollWithMouse |
    ig.ImGuiWindowFlags_NoBackground

"""
    draw_menu(app) -> Bool

Draw the open menu of the shell as its own window "###menu" on top of the shell, and act on
its clicks. A menu of a dialog is drawn by the dialog (`draw_dialog_menu`). A menu closes
when its owner was not drawn or when a dialog opened or closed since it opened.
Returns true when a menu was open at the start of the call.
"""
function draw_menu(app)::Bool
    m = app.ui.menu
    m isa OpenMenu || return false
    if !m.seen || m.level != length(app.ui.dialogs)
        close_menu!(app)
        return true
    end
    m.level > 0 && return false   # the top dialog drew it
    l = place_menu!(app, m)
    b = l.box
    m.fresh && ig.SetNextWindowFocus()
    m.fresh = false
    ig.SetNextWindowPos((b.x0, b.y0))
    ig.SetNextWindowSize((width(b), height(b)))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowRounding, 0)
    ig.Begin("###menu", C_NULL, MENU_FLAGS)
    ig.PopStyleVar(3)
    chosen = draw_menu_rows(app, m, l)
    ig.End()
    act_on_menu!(app, m, chosen, l)
    return true
end

"""
    draw_dialog_menu(app, level)

Draw the open menu of the dialog at `level` as an ImGui popup of its modal, and act on its
clicks. Call it inside the modal of the top dialog, after its body. With no menu of this
dialog open, it closes the popup if ImGui still has it.
"""
function draw_dialog_menu(app, level::Integer)
    m = app.ui.menu
    id = ig.GetID("###menu")
    if !(m isa OpenMenu && m.level == level && m.seen)
        m isa OpenMenu && m.level == level && close_menu!(app)   # its owner was not drawn
        k = popup_level(id)
        k >= 0 && lib.igClosePopupToLevel(k, true)
        return nothing
    end
    l = place_menu!(app, m)
    b = l.box
    popup_level(id) >= 0 || ig.OpenPopup("###menu")
    ig.SetNextWindowPos((b.x0, b.y0))
    ig.SetNextWindowSize((width(b), height(b)))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_PopupBorderSize, 0)
    ig.PushStyleVar(ig.ImGuiStyleVar_PopupRounding, 0)
    ig.PushStyleColor(ig.ImGuiCol_PopupBg, (0f0, 0f0, 0f0, 0f0))   # the rows draw the fill
    open = ig.BeginPopup("###menu", MENU_FLAGS)
    ig.PopStyleColor()
    ig.PopStyleVar(3)
    if !open   # ImGui closed it: a click outside
        close_menu!(app)
        return nothing
    end
    m.ref = unsafe_string(unsafe_load(lib.igGetCurrentWindow().Name))
    m.fresh = false
    chosen = draw_menu_rows(app, m, l)
    # The window keeps the size of the whole menu (a popup sizes itself to what is in it).
    ig.SetCursorScreenPos((b.x0, b.y0))
    ig.Dummy((width(b), height(b)))
    ig.EndPopup()
    act_on_menu!(app, m, chosen, l)
    return nothing
end

# Lay out menu `m` in the main viewport and remember where it goes. The first time, a
# checked row out of view is scrolled into view.
function place_menu!(app, m::OpenMenu)::MenuLayout
    s = app.window.scale
    vp = unsafe_load(ig.GetMainViewport())
    view = Box(vp.Pos.x, vp.Pos.y, vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y)
    layout() = menu_layout(m.anchor, m.items, view, s, (text, size) -> text_width(FONT_REGULAR, size, text);
        min_width = m.min_width, gap = m.gap, scroll = m.scroll)
    l = layout()
    if m.reveal
        m.reveal = false
        k = findfirst(it -> it.checked === true, m.items)
        if k !== nothing && l.scroll_max > 0
            reveal_row!(m, l, k, s)
            l = layout()
        end
    end
    m.scroll = l.scroll
    m.box = l.box
    return l
end

# Scroll so row `k` is wholly inside the menu's padding box.
function reveal_row!(m::OpenMenu, l::MenuLayout, k::Integer, scale::Real)
    inner = inset(l.box, 0, hairline(scale) + px(scale, 4))
    row = l.rows[k]
    row.y0 < inner.y0 && (m.scroll -= inner.y0 - row.y0)
    row.y1 > inner.y1 && (m.scroll += row.y1 - inner.y1)
    m.scroll = clamp(m.scroll, 0f0, l.scroll_max)
    return nothing
end

# Draw the menu box and its rows in the current window. Returns the row clicked, or `nothing`.
function draw_menu_rows(app, m::OpenMenu, l::MenuLayout)
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    hl = hairline(s)
    b = l.box
    vp = unsafe_load(ig.GetMainViewport())
    dl = ig.GetWindowDrawList()
    ig.PushClipRect(dl, (vp.Pos.x, vp.Pos.y), (vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y), false)
    draw_shadow(dl, b, p(8), p(6), p(18), t.shadow)
    ig.PopClipRect(dl)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.menu), p(8))
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.border_strong), p(8), hl)
    icons = any(it -> !isempty(it.icon) || it.checked !== nothing, m.items)
    chosen = nothing
    seen_ids = Set{String}()
    # Rows that scrolled out of the box are neither drawn nor clickable.
    view = inset(b, hl, hl)
    io = unsafe_load(ig.GetIO())
    moved = io.MouseDelta.x != 0 || io.MouseDelta.y != 0
    # The last input wins: a mouse that moves over the menu takes the highlight from the
    # keyboard, so one row is lit at a time. A row the mouse lit goes dark when the mouse
    # leaves; a row the keyboard picked stays lit while the mouse moves outside (a jitter
    # must not lose the row Enter picks).
    moved && !inside(view, io.MousePos.x, io.MousePos.y) && m.mouse_lit && (m.key = 0)
    # The scrollbar's thumb is dragged like the panes' (`scroll_area!`). Its button comes
    # before the rows, so it takes the mouse where it covers them.
    l.scroll_max > 0 && drag_menu_thumb!(app, m, l, menu_track(b, hl, s), view)
    ig.PushClipRect((view.x0, view.y0), (view.x1, view.y1), true)
    for (k, (it, row)) in enumerate(zip(m.items, l.rows))
        (row.y1 <= view.y0 || row.y0 >= view.y1) && continue
        if it.separator
            ig.AddRectFilled(dl, (row.x0 + p(2), row.y0 + p(4)), (row.x1 - p(2), row.y0 + p(4) + hl),
                u32(t.border))
            continue
        end
        if it.head
            draw_spaced_text(dl, FONT_SEMIBOLD, MENU_HEAD_SIZE, row.x0 + p(8), centre_y(row),
                u32(t.text_dim), uppercase(it.label), fpx(s, 0.03 * MENU_HEAD_SIZE))
            continue
        end
        enabled = it.reason === nothing
        id = it.label in seen_ids ? it.label * "##" * string(k) : it.label
        push!(seen_ids, it.label)
        clicked, hovered, held = hit(id, row)
        hovered && moved && enabled && (m.key = k; m.mouse_lit = true)
        enabled && (k == m.key || (hovered && m.key == 0)) && ig.AddRectFilled(dl,
            (row.x0, row.y0), (row.x1, row.y1), u32(held ? t.pressed : t.hover), p(5))
        x = row.x0 + p(6)
        mid = centre_y(row)
        icon = it.checked === nothing ? it.icon : it.checked ? "check" : ""
        isempty(icon) || draw_icon(dl, icon, (x, round(mid - p(8))), 16;
            style = !enabled ? :disabled : it.danger ? :danger : :normal)
        icons && (x += p(24))
        if !isempty(it.ramp)
            r = snap(Box(x, mid - fpx(s, MENU_RAMP_H / 2), x + p(MENU_RAMP_W), mid + fpx(s, MENU_RAMP_H / 2)))
            draw_table_ramp(dl, inset(r, hl, hl), it.ramp, false)
            ig.AddRect(dl, (r.x0, r.y0), (r.x1, r.y1), u32(t.border_strong), p(2), hl)
            x += p(MENU_RAMP_W + 8)
        end
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x, mid,
            u32(!enabled ? t.text_disabled : it.danger ? t.red : t.text), it.label)
        if !isempty(it.shortcut)
            kw = text_width(FONT_REGULAR, 11, it.shortcut)
            draw_text_mid(dl, FONT_REGULAR, 11, row.x1 - p(10) - kw, mid, u32(t.text_dim), it.shortcut)
        end
        hovered && item_tip!(app, replace(it.label, r"\.\.\.$" => ""); help = it.help,
            reason = it.reason, id = it.id)
        clicked && enabled && (chosen = it)
    end
    ig.PopClipRect()
    if l.scroll_max > 0   # a 6 px thumb in a 10 px bar, as the panes' scrollbars
        track = menu_track(b, hl, s)
        ty, th = menu_thumb(track, view, l.scroll, l.scroll_max, s)
        ig.AddRectFilled(dl, (track.x0, ty), (track.x1, ty + th), u32(t.border_strong), p(3))
    end
    return chosen
end

# The track of the menu's scrollbar: 6 px wide in the 10 px bar on the right of box `b`.
menu_track(b::Box, hl::Real, s::Real)::Box =
    inset(Box(b.x1 - hl - px(s, 10), b.y0 + hl, b.x1 - hl, b.y1 - hl), px(s, 2), px(s, 4))

# The top and the height of the thumb in `track` at `scroll`.
function menu_thumb(track::Box, view::Box, scroll::Real, scroll_max::Real, s::Real)::NTuple{2,Float32}
    th = max(height(track) * height(view) / (height(view) + scroll_max), px(s, 20))
    return (track.y0 + (height(track) - th) * scroll / scroll_max, th)
end

# A press on the thumb grabs it and the rows follow the mouse; a press on the track
# above or below it scrolls one page. Sets `m.scroll`; the rows move at the next frame.
function drag_menu_thumb!(app, m::OpenMenu, l::MenuLayout, track::Box, view::Box)
    s = app.window.scale
    mouse = unsafe_load(ig.GetIO()).MousePos
    bar = Box(track.x0 - px(s, 2), view.y0, track.x1 + px(s, 2), view.y1)
    _, _, held = hit("##menu_scrollbar", bar)
    id = ig.GetItemID()
    top, th = menu_thumb(track, view, m.scroll, l.scroll_max, s)
    if ig.IsItemActivated()
        on_thumb = top <= mouse.y < top + th
        app.ui.drag = ScrollDrag(id, on_thumb ? mouse.y - top : NaN32)
        on_thumb || (m.scroll = clamp(m.scroll + (mouse.y < top ? -1 : 1) * height(view), 0f0, l.scroll_max))
    end
    d = app.ui.drag
    travel = height(track) - th
    if held && d isa ScrollDrag && d.id == id && !isnan(d.grab) && travel > 0
        m.scroll = clamp((mouse.y - d.grab - track.y0) / travel * l.scroll_max, 0f0, l.scroll_max)
    end
    ig.IsItemDeactivated() && d isa ScrollDrag && d.id == id && (app.ui.drag = nothing)
    return nothing
end

# Run the row clicked, or the row the keyboard picked with Enter; scroll with the wheel
# and the keys (Up, Down, Page Up, Page Down, Home, End move the highlight); close the
# menu on Esc or a click outside it and its anchor.
function act_on_menu!(app, m::OpenMenu, chosen, l::MenuLayout)
    s = app.window.scale
    io = unsafe_load(ig.GetIO())
    if inside(m.box, io.MousePos.x, io.MousePos.y) && io.MouseWheel != 0
        m.scroll = clamp(m.scroll - io.MouseWheel * px(s, 100), 0f0, l.scroll_max)
    end
    if chosen === nothing
        k = menu_key(m, l, s)
        if k != m.key && k != 0
            m.key = k
            m.mouse_lit = false
            reveal_row!(m, l, k, s)
        end
        enter = ig.IsKeyPressed(lib.ImGuiKey_Enter, false) || ig.IsKeyPressed(lib.ImGuiKey_KeypadEnter, false)
        enter && m.key > 0 && (chosen = m.items[m.key])
    end
    if chosen !== nothing
        chosen.stay || close_menu!(app)
        guarded(app, chosen.action)
    elseif ig.IsKeyPressed(lib.ImGuiKey_Escape, false)
        close_menu!(app)
    elseif any(i -> ig.IsMouseClicked(i), 0:2)
        mouse = unsafe_load(ig.GetIO().MousePos)
        inside(m.box, mouse.x, mouse.y) || inside(m.anchor, mouse.x, mouse.y) || close_menu!(app)
    end
    return nothing
end

# The row the arrow, page and Home/End keys move the highlight to, or `m.key`.
function menu_key(m::OpenMenu, l::MenuLayout, scale::Real)::Int
    ok(k) = !m.items[k].separator && !m.items[k].head && m.items[k].reason === nothing
    n = length(m.items)
    candidates = filter(ok, 1:n)
    isempty(candidates) && return m.key
    start = m.key > 0 ? m.key : something(findfirst(it -> it.checked === true, m.items), 0)
    page = max(1, floor(Int, (height(m.box) - px(scale, 8)) / px(scale, MENU_ROW_H)) - 1)
    pressed(key) = ig.IsKeyPressed(key, true)
    step = pressed(lib.ImGuiKey_DownArrow) ? 1 : pressed(lib.ImGuiKey_UpArrow) ? -1 :
        pressed(lib.ImGuiKey_PageDown) ? page : pressed(lib.ImGuiKey_PageUp) ? -page : 0
    ig.IsKeyPressed(lib.ImGuiKey_Home, false) && return first(candidates)
    ig.IsKeyPressed(lib.ImGuiKey_End, false) && return last(candidates)
    step == 0 && return m.key
    start == 0 && return step > 0 ? first(candidates) : last(candidates)
    target = clamp(start + step, 1, n)
    if step > 0
        k = findfirst(c -> c >= target, candidates)
        return k === nothing ? last(candidates) : candidates[k]
    end
    k = findlast(c -> c <= target, candidates)
    return k === nothing ? first(candidates) : candidates[k]
end
