# Drop-down menus, as the prototype's `.menu`: the menu of a split button, the list of a
# combo. One menu is open at a time (`app.ui.menu`). The control that opened it is its
# owner: it calls `keep_menu!` in every frame it is drawn, and the menu closes when the
# owner is not drawn, on a click outside, on Esc and when a dialog opens.

const MENU_MIN_WIDTH = 200
const MENU_MAX_WIDTH = 360

"""
    MenuItem(label; icon = "", shortcut = "", checked = nothing, reason = nothing, help = "",
             id = "", danger = false, action = app -> nothing)

One row of a menu. `checked` is `nothing` for a plain row, else the row shows a check
mark or a blank. `reason` is why the row cannot run (it is greyed), or `nothing`.
`help` and `id` go into its tooltip. A `danger` row (such as Remove) is red.
`action(app)` runs on a click. `menu_separator()` makes the line between groups of rows.
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
    action::Function
end

MenuItem(label::AbstractString; icon::AbstractString = "", shortcut::AbstractString = "",
        checked::Union{Nothing,Bool} = nothing, reason::Union{Nothing,AbstractString} = nothing,
        help::AbstractString = "", id::AbstractString = "", danger::Bool = false,
        action::Function = app -> nothing) =
    MenuItem(String(label), String(icon), String(shortcut), checked,
        reason === nothing ? nothing : String(reason), String(help), String(id), danger, false,
        action)

"The line between two groups of menu rows (the prototype's `.msep`)."
menu_separator() = MenuItem("", "", "", nothing, nothing, "", "", false, true, app -> nothing)

const MENU_ROW_H = 24
const MENU_SEPARATOR_H = 9   # 1 px line, 4 px above and below

"""
    OpenMenu

The open menu: its `owner` (an id of the control that opened it), the `anchor` box of
that control, the `items`, the smallest width and the `gap` to the anchor in logical
pixels, and whether the owner was drawn in this frame (`seen`). `box` is where the menu was drawn last.
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
end

"""
    MenuLayout

The menu box and its rows, in device pixels.
"""
struct MenuLayout
    box::Box
    rows::Vector{Box}
end

"""
    menu_layout(anchor, items, viewport, scale, measure; min_width = 200, gap = 2) -> MenuLayout

Lay out a menu as the prototype's `openMenu`: under `anchor` with `gap` px between, or
above it when there is no room below; moved left to stay 8 px inside `viewport`. A
context menu passes the mouse point as an empty `anchor` and `gap = 0`. Padding 4, 1 px
border, rows 24 high, separators 9. A row is 6 + icon 16 + 8 + label + (16 + shortcut) +
10 wide. The menu is `min_width` to 360 wide. `measure(text, size)` is the regular text
width in device pixels.
"""
function menu_layout(anchor::Box, items::AbstractVector{MenuItem}, viewport::Box, scale::Real,
        measure; min_width::Real = MENU_MIN_WIDTH, gap::Real = 2)::MenuLayout
    p(v) = px(scale, v)
    hl = hairline(scale)
    icons = any(it -> !isempty(it.icon) || it.checked !== nothing, items)
    row_h(it) = p(it.separator ? MENU_SEPARATOR_H : MENU_ROW_H)
    row_w = 0f0
    for it in items
        it.separator && continue
        w = p(6) + (icons ? p(24) : 0f0) + measure(it.label, BODY_FONT_SIZE) + p(10)
        isempty(it.shortcut) || (w += p(16) + measure(it.shortcut, 11))
        row_w = max(row_w, w)
    end
    w = max(min(round(row_w + p(8) + 2 * hl), p(MENU_MAX_WIDTH)), p(min_width))
    h = 2 * hl + p(8) + sum(row_h, items; init = 0f0)
    x = anchor.x0
    y = anchor.y1 + p(gap)
    y + h > viewport.y1 - p(8) && (y = max(viewport.y0 + p(8), anchor.y0 - p(gap) - h))
    x + w > viewport.x1 - p(8) && (x = viewport.x1 - p(8) - w)
    x = max(viewport.x0 + p(8), x)
    box = Box(round(x), round(y), round(x) + w, round(y) + h)
    rows = Box[]
    ry = box.y0 + hl + p(4)
    for it in items
        push!(rows, Box(box.x0 + hl + p(4), ry, box.x1 - hl - p(4), ry + row_h(it)))
        ry += row_h(it)
    end
    return MenuLayout(box, rows)
end

"""
    open_menu!(app, owner, anchor, items; min_width = 200, gap = 2)

Open a menu for the control `owner` under its box `anchor`, `gap` px below it. It replaces
any open menu.
"""
function open_menu!(app, owner::AbstractString, anchor::Box, items::Vector{MenuItem};
        min_width::Real = MENU_MIN_WIDTH, gap::Real = 2)
    app.ui.menu = OpenMenu(String(owner), anchor, items, Float32(min_width), Float32(gap), true,
        true, anchor)
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

Draw the open menu as its own window "###menu" on top of the shell, and act on its clicks.
Returns true when a menu was open at the start of the call.
"""
function draw_menu(app)::Bool
    m = app.ui.menu
    m isa OpenMenu || return false
    if !m.seen || !isempty(app.ui.dialogs)
        close_menu!(app)
        return true
    end
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    hl = hairline(s)
    vp = unsafe_load(ig.GetMainViewport())
    view = Box(vp.Pos.x, vp.Pos.y, vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y)
    l = menu_layout(m.anchor, m.items, view, s, (text, size) -> text_width(FONT_REGULAR, size, text);
        min_width = m.min_width, gap = m.gap)
    m.box = l.box
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
    dl = ig.GetWindowDrawList()
    ig.PushClipRect(dl, (view.x0, view.y0), (view.x1, view.y1), false)
    draw_shadow(dl, b, p(8), p(6), p(18), t.shadow)
    ig.PopClipRect(dl)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.menu), p(8))
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.border_strong), p(8), hl)
    icons = any(it -> !isempty(it.icon) || it.checked !== nothing, m.items)
    chosen = nothing
    seen_ids = Set{String}()
    for (k, (it, row)) in enumerate(zip(m.items, l.rows))
        if it.separator
            ig.AddRectFilled(dl, (row.x0 + p(2), row.y0 + p(4)), (row.x1 - p(2), row.y0 + p(4) + hl),
                u32(t.border))
            continue
        end
        enabled = it.reason === nothing
        id = it.label in seen_ids ? it.label * "##" * string(k) : it.label
        push!(seen_ids, it.label)
        clicked, hovered, held = hit(id, row)
        enabled && hovered && ig.AddRectFilled(dl, (row.x0, row.y0), (row.x1, row.y1),
            u32(held ? t.pressed : t.hover), p(5))
        x = row.x0 + p(6)
        mid = centre_y(row)
        icon = it.checked === nothing ? it.icon : it.checked ? "check" : ""
        isempty(icon) || draw_icon(dl, icon, (x, round(mid - p(8))), 16;
            style = !enabled ? :disabled : it.danger ? :danger : :normal)
        icons && (x += p(24))
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
    ig.End()

    if chosen !== nothing
        close_menu!(app)
        guarded(app, chosen.action)
    elseif ig.IsKeyPressed(lib.ImGuiKey_Escape, false)
        close_menu!(app)
    elseif any(i -> ig.IsMouseClicked(i), 0:2)
        mouse = unsafe_load(ig.GetIO().MousePos)
        inside(b, mouse.x, mouse.y) || inside(m.anchor, mouse.x, mouse.y) || close_menu!(app)
    end
    return true
end
