# The ribbon: the groups of the active tab, built from the command places.
#
# `ribbon_layout` turns the commands into groups of items (pure, no fonts). `item_width`
# and `group_width` size them with an injected text measure. `draw_ribbon` draws them in
# the ribbon band, as the prototype's `#ribbon`, and scrolls them sideways when they do
# not fit.

# --- Layout model ---

"One item of a ribbon group."
abstract type RibbonItem end

"A big button (70 high, 32 px icon, label under it) for command `cmd_id`."
struct BigButton <: RibbonItem
    cmd_id::String
end

"A big button with a 20 px arrow that opens the menu of command `cmd_id` (its `menu`)."
struct SplitButton <: RibbonItem
    cmd_id::String
end

"""
A big button whose last label line ends with a caret. A click opens the drop-down menu of
command `cmd_id` (its `items`), such as Add Item to Map or Show Tabs.
"""
struct MenuButton <: RibbonItem
    cmd_id::String
end

"A column of one to three small buttons (22 high, 18 px icon, label on the right)."
struct SmallColumn <: RibbonItem
    cmd_ids::Vector{String}
    function SmallColumn(ids::AbstractVector{<:AbstractString})
        1 <= length(ids) <= 3 ||
            throw(ArgumentError("a small column holds one to three buttons, not $(length(ids))"))
        return new(Vector{String}(ids))
    end
end

"An item the ribbon draws by hand: `:db_chooser` (the \"Acts on\" chooser) or `:defaults`."
struct Custom <: RibbonItem
    kind::Symbol
end

"A group of the ribbon: its `name` (the label under it) and its items, left to right."
struct RibbonGroup
    name::String
    items::Vector{RibbonItem}
end
RibbonGroup(name::AbstractString, items::AbstractVector{<:RibbonItem}) =
    RibbonGroup(String(name), Vector{RibbonItem}(items))

Base.:(==)(a::BigButton, b::BigButton) = a.cmd_id == b.cmd_id
Base.:(==)(a::SplitButton, b::SplitButton) = a.cmd_id == b.cmd_id
Base.:(==)(a::MenuButton, b::MenuButton) = a.cmd_id == b.cmd_id
Base.:(==)(a::SmallColumn, b::SmallColumn) = a.cmd_ids == b.cmd_ids
Base.:(==)(a::Custom, b::Custom) = a.kind == b.kind
Base.:(==)(a::RibbonGroup, b::RibbonGroup) = a.name == b.name && a.items == b.items
Base.hash(a::BigButton, h::UInt) = hash(a.cmd_id, hash(:BigButton, h))
Base.hash(a::SplitButton, h::UInt) = hash(a.cmd_id, hash(:SplitButton, h))
Base.hash(a::MenuButton, h::UInt) = hash(a.cmd_id, hash(:MenuButton, h))
Base.hash(a::SmallColumn, h::UInt) = hash(a.cmd_ids, hash(:SmallColumn, h))
Base.hash(a::Custom, h::UInt) = hash(a.kind, hash(:Custom, h))
Base.hash(a::RibbonGroup, h::UInt) = hash(a.items, hash(a.name, hash(:RibbonGroup, h)))

# Commands that the ribbon draws as a custom item: the "Acts on" chooser and the Defaults
# combos of the Settings tab (settings_tab.jl).
const RIBBON_CUSTOM = Dict("database.choose" => :db_chooser, "settings.defaults" => :defaults)

# The shell's own groups come first on these tabs, in this order. Other groups follow in
# the order their first command was placed.
const RIBBON_FIRST_GROUPS = Dict(
    "Database" => ["Database", "Import", "Export", "Lines", "Channels"],
    "Grid and Image" => ["Import", "Export"],
    "Settings" => ["Theme", "Defaults", "Startup", "Rendering", "Ribbon"],
    "Help" => ["Help", "About"],
)

# Does `c` at place `p` become a split button?
is_split(c::Command, p::Core.Place) =
    p.size !== :small && !haskey(RIBBON_CUSTOM, c.id) && !isempty(c.menu)

"""
    ribbon_layout(cmds, tab) -> Vector{RibbonGroup}

The groups of ribbon tab `tab`. Groups come in the order their first command was placed,
after the fixed shell groups of `RIBBON_FIRST_GROUPS`. In a group, commands go by their
place's `order`, then by their position in `cmds`. A `:big` place is a `BigButton` (a
`SplitButton` when the command has a `menu`, a `MenuButton` when it has `items`); runs of `:small` places make `SmallColumn`s
of up to three. A command in the menu of a split button of the same group is left out:
it shows through that menu.
"""
function ribbon_layout(cmds::AbstractVector{Command}, tab::AbstractString)::Vector{RibbonGroup}
    entries = Tuple{Command,Core.Place,Int}[]
    for (k, c) in enumerate(cmds), p in c.places
        p.tab == tab && push!(entries, (c, p, k))
    end
    seen = String[]
    for (_, p, _) in entries
        p.group in seen || push!(seen, p.group)
    end
    fixed = get(RIBBON_FIRST_GROUPS, tab, String[])
    order = [[g for g in fixed if g in seen]; [g for g in seen if !(g in fixed)]]
    groups = RibbonGroup[]
    for name in order
        mine = [e for e in entries if e[2].group == name]
        # Only the menu of a command that becomes a split button hides commands.
        in_menu = Set(id for (c, p, _) in mine if is_split(c, p) for id in c.menu)
        filter!(e -> !(e[1].id in in_menu), mine)
        sort!(mine; by = e -> (e[2].order, e[3]))
        items = RibbonItem[]
        column = String[]
        flush() = isempty(column) || (push!(items, SmallColumn(copy(column))); empty!(column))
        for (c, p, _) in mine
            custom = get(RIBBON_CUSTOM, c.id, nothing)
            if custom !== nothing
                flush()
                push!(items, Custom(custom))
            elseif p.size === :small
                length(column) == 3 && flush()
                push!(column, c.id)
            else
                flush()
                push!(items, is_split(c, p) ? SplitButton(c.id) :
                             c.items !== nothing ? MenuButton(c.id) : BigButton(c.id))
            end
        end
        flush()
        isempty(items) || push!(groups, RibbonGroup(name, items))
    end
    return groups
end

# --- Sizes ---
#
# Widths and drawing offsets both use logical px times the scale with no rounding per
# constant (`fpx`, draw.jl). A browser adds such lengths up as fractions and snaps only the
# edges it paints; the drawing does the same with `snap`. So a width is exactly the drawn width.

const RIBBON_LABEL_SIZE = 11.5f0
const GROUP_LABEL_SIZE = 11f0
const CHOOSER_LABEL = "Acts on"

# The text of a small button: the label on one line.
small_label(label::AbstractString) = replace(label, '\n' => ' ')

# The widest line of a big button label.
widest_line(measure, label::AbstractString) =
    maximum(measure(String(l), RIBBON_LABEL_SIZE) for l in split(label, '\n'))

"""
    item_width(item, measure; label = identity, scale = 1, note = "") -> Float32

The width of a ribbon item in device pixels. `measure(text, size)` is the width of regular
text at `size` logical pixels, in device pixels. `label(cmd_id)` is the command's ribbon
label. `note` is the text under the "Acts on" chooser.

- big: max(widest label line + 14, 50); split: big + 20; menu: big with the last line
  4 + 8 px longer (the caret);
- small: 26 + label + 8, and a column is as wide as its widest button;
- chooser: 4 + max(170, "Acts on" + 1, note up to 180) + 4.
"""
function item_width(item::BigButton, measure; label = identity, scale::Real = 1, note = "")::Float32
    return max(widest_line(measure, label(item.cmd_id)) + fpx(scale, 14), fpx(scale, 50))
end

item_width(item::SplitButton, measure; label = identity, scale::Real = 1, note = "")::Float32 =
    item_width(BigButton(item.cmd_id), measure; label, scale) + fpx(scale, 20)

function item_width(item::MenuButton, measure; label = identity, scale::Real = 1, note = "")::Float32
    lines = split(label(item.cmd_id), '\n')
    widths = [measure(String(l), RIBBON_LABEL_SIZE) for l in lines]
    widths[end] += fpx(scale, 4 + 8)
    return max(maximum(widths) + fpx(scale, 14), fpx(scale, 50))
end

item_width(item::SmallColumn, measure; label = identity, scale::Real = 1, note = "")::Float32 =
    maximum(fpx(scale, 26) + measure(small_label(label(id)), RIBBON_LABEL_SIZE) + fpx(scale, 8)
            for id in item.cmd_ids)

function item_width(item::Custom, measure; label = identity, scale::Real = 1, note = "")::Float32
    check_custom(item)
    item.kind === :defaults && return defaults_width(scale)
    note_w = isempty(note) ? 0f0 : min(Float32(measure(note, GROUP_LABEL_SIZE)), fpx(scale, 180))
    inner = max(fpx(scale, 170), measure(CHOOSER_LABEL, GROUP_LABEL_SIZE) + fpx(scale, 1), note_w)
    return inner + fpx(scale, 8)
end

# The custom items the ribbon knows. Another kind is an error, when sized and when drawn.
check_custom(item::Custom) =
    item.kind in (:db_chooser, :defaults) || throw(ArgumentError("no ribbon item :$(item.kind)"))

"""
    group_content_width(g, measure; label = identity, scale = 1, note = "") -> Float32

The width of the items of group `g` with 2 px between, or of its label + 12 when that is wider.
"""
group_content_width(g::RibbonGroup, measure; label = identity, scale::Real = 1, note = "")::Float32 =
    content_width(g, [item_width(it, measure; label, scale, note) for it in g.items], measure, scale)

function content_width(g::RibbonGroup, widths::AbstractVector{Float32}, measure, scale::Real)::Float32
    items = sum(widths) + fpx(scale, 2) * (length(widths) - 1)
    return max(items, measure(g.name, GROUP_LABEL_SIZE) + fpx(scale, 12))
end

"""
    group_width(g, measure; label = identity, scale = 1, note = "") -> Float32

The width a group takes in the ribbon: its content, 7 px, the 1 px separator, 6 px, and
2 px to the next group (the prototype's `.rg` padding and margin).
"""
group_width(g::RibbonGroup, measure; label = identity, scale::Real = 1, note = "")::Float32 =
    group_content_width(g, measure; label, scale, note) + fpx(scale, 16)

"How far the ribbon can scroll: the groups' width past the view, or 0."
ribbon_scroll_max(total::Real, view::Real)::Float32 = max(0f0, Float32(total) - Float32(view))

"""
    ribbon_arrows(scroll, scroll_max) -> (left, right)

Which scroll arrows show: left when the ribbon is scrolled, right when more is to the right.
"""
ribbon_arrows(scroll::Real, scroll_max::Real) =
    (scroll_max >= 1 && scroll > 0.5, scroll_max >= 1 && scroll < scroll_max - 0.5)

"The distance an arrow click scrolls: 60 % of the view, at least 120 px."
ribbon_scroll_step(view::Real, scale::Real)::Float32 = max(fpx(scale, 120), Float32(view) * 0.6f0)

"""
    chooser_note(app) -> String

The note under the "Acts on" chooser: "60 lines, 24 channels" for the current database,
or `""`.
"""
function chooser_note(app)::String
    snap = app.snap
    snap === nothing && return ""
    v = get(snap.databases, app.ui.current_db, nothing)
    v === nothing && return ""
    n, m = length(v.lines), length(v.channels)
    return string(n, n == 1 ? " line, " : " lines, ", m, m == 1 ? " channel" : " channels")
end

"""
    choose_database!(app, id) -> Bool

Make database `id` the one the Database tab acts on, when the snapshot has it.
A pick from a menu made before the database went away does nothing.
"""
function choose_database!(app, id::AbstractString)::Bool
    any(it -> it.kind == Core.ITEM_DATABASE && it.id == id, snap_items(app)) || return false
    app.ui.current_db = String(id)
    return true
end

"The rows of the chooser's menu: the project's databases, the current one checked."
chooser_items(app)::Vector{MenuItem} =
    [MenuItem(it.name; checked = it.id == app.ui.current_db,
              action = a -> (choose_database!(a, it.id); nothing))
     for it in snap_items(app) if it.kind == Core.ITEM_DATABASE]

# --- The cached model ---

"""
    RibbonModel

What the ribbon of one tab needs that does not change from frame to frame: the commands
by id, the groups and the widths of every item and group (device px). Its key is the
command list (a new list when the registry or the project changes), the tab, the scale,
the loaded fonts, the theme and the chooser note (the only text that comes from the
snapshot). Whether a command can run is not cached: the drawing asks every frame.
"""
struct RibbonModel
    cmds::Vector{Command}
    tab::String
    scale::Float32
    fonts::Any
    tokens::Any
    note::String
    byid::Dict{String,Command}
    groups::Vector{RibbonGroup}
    item_widths::Vector{Vector{Float32}}
    group_widths::Vector{Float32}
end

"""
    ribbon_model!(app, cmds, tab, scale, fonts, note, measure) -> RibbonModel

The model for this key, from `app.ui.ribbon_cache` when the key is the same, else built
with `measure(text, size)` and cached.
"""
function ribbon_model!(app, cmds::Vector{Command}, tab::AbstractString, scale::Real, fonts,
        note::AbstractString, measure)::RibbonModel
    m = app.ui.ribbon_cache
    if m isa RibbonModel && m.cmds === cmds && m.tab == tab && m.scale == scale &&
            m.fonts === fonts && m.tokens === app.tokens && m.note == note
        return m
    end
    byid = Dict(c.id => c for c in cmds)
    groups = ribbon_layout(cmds, tab)
    label(id) = byid[id].label
    item_widths = [[item_width(it, measure; label, scale, note) for it in g.items] for g in groups]
    group_widths = [content_width(g, w, measure, scale) + fpx(scale, 16)
                    for (g, w) in zip(groups, item_widths)]
    m = RibbonModel(cmds, String(tab), Float32(scale), fonts, app.tokens, String(note), byid,
        groups, item_widths, group_widths)
    app.ui.ribbon_cache = m
    return m
end

# --- Drawing ---

const RIBBON_WHEEL_STEP = 100   # logical px per wheel step, as a browser scrolls

# What the items of one frame share: the model, and the ids given out so far, so a command
# placed twice on a tab gets "Name" and then "Name##2"; and the command whose menu opens at
# its button in this frame (`app.ui.menu_request`), or `""`.
struct RibbonFrame
    model::RibbonModel
    ids::Dict{String,Int}
    menu_request::String
end

function unique_id!(frame::RibbonFrame, name::String)::String
    n = get(frame.ids, name, 0) + 1
    frame.ids[name] = n
    return n == 1 ? name : name * "##" * string(n)
end

"""
    draw_ribbon(app, dl, b)

Draw the groups of the active tab in the ribbon band `b`: padding 5 at the top and 8 at
the sides, 72 px of items and an 18 px group label, a 1 px separator after each group but
the last. When the groups are wider than the band, 18 px arrow buttons at the edges and
the mouse wheel scroll them sideways.
"""
function draw_ribbon(app, dl, b::Box)
    w = app.window::Window
    s = w.scale
    t = app.tokens
    ui = app.ui
    f(v) = fpx(s, v)
    hl = hairline(s)
    fonts = get(LOADED_FONTS, ig.GetCurrentContext(), nothing)
    model = ribbon_model!(app, commands(app), ui.tab, s, fonts, chooser_note(app),
        (text, size) -> text_width(FONT_REGULAR, size, text))
    frame = RibbonFrame(model, Dict{String,Int}(), ui.menu_request)
    ui.menu_request = ""   # asked once: a menu button out of view does not open later
    view = Box(b.x0 + f(8), b.y0, b.x1 - f(8), b.y1 - hl)
    smax = ribbon_scroll_max(sum(model.group_widths; init = 0f0), width(view))

    # The scroll position: kept on the same tab, 0 on another, and moved by the wheel.
    if ui.ribbon_scroll_tab != ui.tab
        ui.ribbon_scroll = 0f0
        ui.ribbon_scroll_tab = ui.tab
    end
    if smax > 0 && ig.IsWindowHovered()
        mouse = unsafe_load(ig.GetIO().MousePos)
        if inside(b, mouse.x, mouse.y)
            io = ig.GetIO()
            wheel = unsafe_load(io.MouseWheel)
            wheel == 0 && (wheel = unsafe_load(io.MouseWheelH))
            ui.ribbon_scroll -= wheel * f(RIBBON_WHEEL_STEP)
        end
    end
    ui.ribbon_scroll = clamp(ui.ribbon_scroll, 0f0, smax)

    ig.PushID("ribbon")
    # The arrows sit over the groups, so they take the mouse first.
    show_left, show_right = ribbon_arrows(ui.ribbon_scroll, smax)
    arrows = Tuple{Box,Bool,Bool}[]   # box, left, hovered
    step = ribbon_scroll_step(width(view), s)
    for (left, shown) in ((true, show_left), (false, show_right))
        shown || continue
        x0 = left ? b.x0 + f(8) : b.x1 - f(8 + 18)
        ab = snap(Box(x0, b.y0 + f(5), x0 + f(18), b.y1 - hl - f(4)))
        name = left ? "Scroll the ribbon left" : "Scroll the ribbon right"
        clicked, hovered, _ = hit(name, ab)
        clicked && (ui.ribbon_scroll = clamp(ui.ribbon_scroll + (left ? -step : step), 0f0, smax))
        hovered && item_tip!(app, name)
        push!(arrows, (ab, left, hovered))
    end

    ig.PushClipRect((view.x0, view.y0), (view.x1, view.y1), true)
    x = view.x0 - ui.ribbon_scroll
    top = b.y0 + f(5)
    n = length(model.groups)
    for k in 1:n
        gw = model.group_widths[k]
        if x + gw > view.x0 && x < view.x1   # only groups in view
            draw_group(app, dl, frame, k, x, top; last = k == n)
        end
        x += gw
    end
    ig.PopClipRect()

    for (ab, left, hovered) in arrows
        ig.AddRectFilled(dl, (ab.x0, ab.y0), (ab.x1, ab.y1), u32(hovered ? t.hover : t.ribbon), f(4))
        ig.AddRect(dl, (ab.x0, ab.y0), (ab.x1, ab.y1), u32(t.border), f(4), hl)
        draw_icon(dl, left ? "chevLeft" : "chevRight",
            (ab.x0 + (width(ab) - px(s, 16)) / 2, ab.y0 + (height(ab) - px(s, 16)) / 2), 16;
            style = :dim)
    end
    ig.PopID()
    return nothing
end

# Group `k` of the model at `x` (device px), then its label and separator. `top` is the
# top of the items, not rounded.
function draw_group(app, dl, frame::RibbonFrame, k::Int, x::Float32, top::Float32; last::Bool)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    g = frame.model.groups[k]
    widths = frame.model.item_widths[k]
    content = frame.model.group_widths[k] - f(16)
    cx = x
    for (item, iw) in zip(g.items, widths)
        draw_item(app, dl, item, rnd(cx), top, rnd(cx + iw) - rnd(cx), frame)
        cx += iw + f(2)
    end
    lw = text_width(FONT_REGULAR, GROUP_LABEL_SIZE, g.name)
    draw_text_mid(dl, FONT_REGULAR, GROUP_LABEL_SIZE, x + (content - lw) / 2, top + f(72 + 8),
        u32(t.group_label), g.name; line = 16 / 11)
    if !last
        sx = rnd(x + content + f(7))
        ig.AddRectFilled(dl, (sx, rnd(top + f(6))), (sx + hl, rnd(top + f(86))), u32(t.border))
    end
    return nothing
end

# The id of a command's button: its name without "...", such as "Channel Math".
button_name(cmd::Command) = replace(cmd.name, r"\.\.\.$" => "")

# Each item is drawn at `x` (rounded) and `top` (not rounded), `iw` wide (rounded).
function draw_item(app, dl, item::BigButton, x, top, iw, frame::RibbonFrame)
    cmd = frame.model.byid[item.cmd_id]
    draw_big_button(app, dl, cmd, Box(x, top, x + iw, top + fpx(app.window.scale, 70)),
        unique_id!(frame, button_name(cmd)))
    return nothing
end

function draw_item(app, dl, item::SplitButton, x, top, iw, frame::RibbonFrame)
    s = app.window.scale
    f(v) = fpx(s, v)
    hl = hairline(s)
    t = app.tokens
    cmd = frame.model.byid[item.cmd_id]
    main = Box(x, top, x + iw - f(20), top + f(70))
    draw_big_button(app, dl, cmd, main, unique_id!(frame, button_name(cmd));
        corners = Int(lib.ImDrawFlags_RoundLeft))

    # The arrow: opens the menu of formats.
    arrow = snap(Box(main.x1, top, x + iw, main.y1))
    reason = cmd.enabled(app)
    enabled = reason === nothing
    name = "More " * lowercase(small_label(cmd.label)) * " formats"
    id = unique_id!(frame, name)
    owner = id == name ? cmd.id : cmd.id * "/" * id   # the menu's owner, unique on the tab
    open = menu_open(app, owner)
    clicked, hovered, held = hit(id, arrow)
    open && keep_menu!(app, owner, arrow; items = split_menu_items(app, cmd, frame.model.byid))
    draw_rb_fill(app, dl, arrow; enabled, hovered, held, on = open,
        corners = Int(lib.ImDrawFlags_RoundRight))
    ig.AddRectFilled(dl, (arrow.x0, rnd(top + f(6))), (arrow.x0 + hl, rnd(top + f(70 - 6))),
        u32(t.border))
    draw_caret(dl, arrow.x0 + (width(arrow) - f(8)) / 2, top + f(70 - 5) / 2, s,
        u32(enabled ? t.text : t.text_disabled))
    if clicked && enabled
        toggle_menu!(app, owner, arrow, () -> split_menu_items(app, cmd, frame.model.byid))
    end
    hovered && item_tip!(app, name; help = "Pick another format.", reason, id = cmd.id)
    return nothing
end

# The rows of a split button's menu: one per command of its `menu`. Built again every
# frame while the menu is open, so a row's reason stays current.
function split_menu_items(app, cmd::Command, byid::Dict{String,Command})::Vector{MenuItem}
    items = MenuItem[]
    for id in cmd.menu
        c = get(byid, id, nothing)
        c === nothing && continue
        push!(items, MenuItem(c.menu_label; icon = c.icon, reason = c.enabled(app), help = c.help,
            id = c.id, action = c.run))
    end
    return items
end

"""
    draw_item(app, dl, item::MenuButton, x, top, iw, frame)

A big button (70 high, the 32 px icon, the label under it) whose last label line ends with a
caret, 4 px after the text. A click opens the command's menu (`items`), and the button
shows checked while it is open. A row can keep the menu open (`stay`), as Show Tabs does.
"""
function draw_item(app, dl, item::MenuButton, x, top, iw, frame::RibbonFrame)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    cmd = frame.model.byid[item.cmd_id]
    items = cmd.items::Function
    reason = cmd.enabled(app)
    enabled = reason === nothing
    b = Box(Float32(x), Float32(top), Float32(x) + Float32(iw), Float32(top) + f(70))
    sb = snap(b)
    name = button_name(cmd)
    id = unique_id!(frame, name)
    owner = id == name ? cmd.id : cmd.id * "/" * id   # the menu's owner, unique on the tab
    open = menu_open(app, owner)
    clicked, hovered, held = hit(id, sb)
    open && keep_menu!(app, owner, sb; items = items(app))
    draw_rb_fill(app, dl, sb; enabled, hovered, held, on = open)
    draw_icon(dl, cmd.icon, (rnd(b.x0 + (width(b) - px(s, 32)) / 2), rnd(b.y0 + f(5))), 32;
        style = enabled ? :normal : :disabled)
    col = u32(enabled ? t.text : t.text_disabled)
    pitch = f(13.5)
    lines = String.(split(cmd.label, '\n'))
    for (k, line) in enumerate(lines)
        last_line = k == length(lines)
        lw = text_width(FONT_REGULAR, RIBBON_LABEL_SIZE, line)
        full = last_line ? lw + f(4 + 8) : lw
        lx = b.x0 + (width(b) - full) / 2
        mid = b.y0 + f(42) + (k - 1) * pitch + pitch / 2
        draw_text_mid(dl, FONT_REGULAR, RIBBON_LABEL_SIZE, lx, mid, col, line; line = 13.5 / 11.5)
        last_line && draw_caret(dl, lx + lw + f(4), mid - f(5) / 2, s, col)
    end
    clicked && enabled && toggle_menu!(app, owner, sb, () -> items(app))
    enabled && !open && frame.menu_request == cmd.id && open_menu!(app, owner, sb, items(app))
    hovered && command_tip!(app, cmd)
    return nothing
end

function draw_item(app, dl, item::SmallColumn, x, top, iw, frame::RibbonFrame)
    s = app.window.scale
    y = top + fpx(s, 1)
    for id in item.cmd_ids
        cmd = frame.model.byid[id]
        draw_small_button(app, dl, cmd, Box(x, y, x + iw, y + fpx(s, 22)),
            unique_id!(frame, button_name(cmd)))
        y += fpx(s, 23)
    end
    return nothing
end

function draw_item(app, dl, item::Custom, x, top, iw, frame)
    check_custom(item)
    if item.kind === :defaults
        draw_defaults(app, dl, x, top, frame::RibbonFrame)
    else
        draw_db_chooser(app, dl, x, top, frame::RibbonFrame)
    end
    return nothing
end

"""
    draw_rb_fill(app, dl, b; enabled, hovered, held, on, corners = all)

The look of a ribbon button (`.rb`) in box `b` (whole pixels): `hover` fill on hover,
`pressed` while held, and `checked` fill with a 1 px `accent` outline at 0.55 alpha when it
is on (a checked toggle or an open menu). Hover wins over the checked fill, as in the
prototype. Radius 6.
"""
function draw_rb_fill(app, dl, b::Box; enabled::Bool, hovered::Bool, held::Bool, on::Bool,
        corners::Integer = Int(lib.ImDrawFlags_RoundAll))
    s = app.window.scale
    t = app.tokens
    r = px(s, 6)
    fill = enabled && hovered ? (held ? t.pressed : t.hover) : on ? t.checked : nothing
    fill === nothing || ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(fill), r, corners)
    on && ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.accent, 0.55), r, hairline(s), corners)
    return nothing
end

# The prototype's 8 by 5 caret (a 7 by 4 triangle), top left at (x, y) in device px.
function draw_caret(dl, x::Real, y::Real, scale::Real, col::UInt32)
    x, y, s = Float32(x), Float32(y), Float32(scale)
    ig.AddTriangleFilled(dl, (x + 0.5f0s, y + 0.6f0s), (x + 7.5f0s, y + 0.6f0s),
        (x + 4f0s, y + 4.6f0s), col)
    return nothing
end

"""
    draw_big_button(app, dl, cmd, b, id; corners = all)

A big button (`.rb-big`) for `cmd` in box `b`, with ImGui id `id`: the 32 px icon centred
at the top + 21, the label from the top + 42 in lines 13.5 px apart, centred. A click runs
the command.
"""
function draw_big_button(app, dl, cmd::Command, b::Box, id::String;
        corners::Integer = Int(lib.ImDrawFlags_RoundAll))
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    reason = cmd.enabled(app)
    enabled = reason === nothing
    sb = snap(b)
    clicked, hovered, held = hit(id, sb)
    draw_rb_fill(app, dl, sb; enabled, hovered, held, on = cmd.checked(app), corners)
    draw_icon(dl, cmd.icon, (rnd(b.x0 + (width(b) - px(s, 32)) / 2), rnd(b.y0 + f(5))), 32;
        style = enabled ? :normal : :disabled)
    pitch = f(13.5)
    col = u32(enabled ? t.text : t.text_disabled)
    for (k, line) in enumerate(String.(split(cmd.label, '\n')))
        lw = text_width(FONT_REGULAR, RIBBON_LABEL_SIZE, line)
        draw_text_mid(dl, FONT_REGULAR, RIBBON_LABEL_SIZE, b.x0 + (width(b) - lw) / 2,
            b.y0 + f(42) + (k - 1) * pitch + pitch / 2, col, line; line = 13.5 / 11.5)
    end
    clicked && enabled && guarded(app, cmd.run)
    hovered && command_tip!(app, cmd)
    return nothing
end

"""
    draw_small_button(app, dl, cmd, b, id)

A small button (`.rb-small`) for `cmd` in box `b`, with ImGui id `id`: the 18 px icon
centred 13 px from the left, the label from the left + 26. A click runs the command.
"""
function draw_small_button(app, dl, cmd::Command, b::Box, id::String)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    reason = cmd.enabled(app)
    enabled = reason === nothing
    sb = snap(b)
    clicked, hovered, held = hit(id, sb)
    draw_rb_fill(app, dl, sb; enabled, hovered, held, on = cmd.checked(app))
    draw_icon(dl, cmd.icon, (rnd(b.x0 + f(4)), rnd(b.y0 + f(2))), 18;
        style = enabled ? :normal : :disabled)
    draw_text_mid(dl, FONT_REGULAR, RIBBON_LABEL_SIZE, b.x0 + f(26), centre_y(b),
        u32(enabled ? t.text : t.text_disabled), small_label(cmd.label))
    clicked && enabled && guarded(app, cmd.run)
    hovered && command_tip!(app, cmd)
    return nothing
end

const CHOOSER_ID = "database.choose"

"""
    draw_db_chooser(app, dl, x, top, frame)

The "Acts on" chooser (`.rb-combo`): a small label, a 170 px combo of the project's
databases with the database icon, and the note "N lines, M channels" in `text_dim`.
Picking a database sets `app.ui.current_db`, the field the Data tree selection sets too.
"""
function draw_db_chooser(app, dl, x::Real, top::Real, frame::RibbonFrame)
    s = app.window.scale
    t = app.tokens
    ui = app.ui
    f(v) = fpx(s, v)
    hl = hairline(s)
    x, top = Float32(x), Float32(top)
    label_h = f(11 * 1.25)   # the label's line box: `normal` line height for Inter
    draw_text_mid(dl, FONT_REGULAR, GROUP_LABEL_SIZE, x + f(5), top + f(3) + label_h / 2,
        u32(t.text_dim), CHOOSER_LABEL)

    dbs = [it for it in snap_items(app) if it.kind == Core.ITEM_DATABASE]
    reason = has_session(app) ? (isempty(dbs) ? NEED_DATABASE : nothing) : NEED_PROJECT
    enabled = reason === nothing
    cy = top + f(3) + label_h + f(3)
    cb = snap(Box(x + f(4), cy, x + f(4 + 170), cy + f(22)))
    id = unique_id!(frame, "Active database")
    owner = id == "Active database" ? CHOOSER_ID : CHOOSER_ID * "/" * id
    open = menu_open(app, owner)
    clicked, hovered, _ = hit(id, cb)
    open && keep_menu!(app, owner, cb; items = chooser_items(app))
    on = enabled && hovered
    ig.AddRectFilled(dl, (cb.x0, cb.y0), (cb.x1, cb.y1), u32(on ? t.hover : t.input), px(s, 5))
    edge = open ? t.accent : on ? t.border_strong : t.input_border
    ig.AddRect(dl, (cb.x0, cb.y0), (cb.x1, cb.y1), u32(edge), px(s, 5), hl)
    if open   # the focus ring: a second accent line outside the border
        ig.AddRect(dl, (cb.x0 - hl, cb.y0 - hl), (cb.x1 + hl, cb.y1 + hl), u32(t.accent),
            px(s, 5) + hl, hl)
    end
    mid = centre_y(cb)
    ix = cb.x0 + hl + f(8)
    draw_icon(dl, "database", (rnd(ix), rnd(mid - f(7))), 14; style = enabled ? :normal : :disabled)
    caret_x = cb.x1 - hl - f(7 + 8)
    draw_caret(dl, caret_x, mid - f(5) / 2, s, u32(enabled ? t.text_dim : t.text_disabled))
    k = findfirst(it -> it.id == ui.current_db, dbs)
    name = k === nothing ? "No database" : dbs[k].name
    tx = ix + f(14 + 6)
    name = elide(text_width, name, caret_x - f(6) - tx; size = RIBBON_LABEL_SIZE)
    draw_text_mid(dl, FONT_REGULAR, RIBBON_LABEL_SIZE, tx, mid,
        u32(enabled ? t.text : t.text_disabled), name)
    clicked && enabled && toggle_menu!(app, owner, cb, () -> chooser_items(app); min_width = 170)
    cmd = get(frame.model.byid, CHOOSER_ID, nothing)
    hovered && item_tip!(app, "Active database"; help = cmd === nothing ? "" : cmd.help, reason,
        id = CHOOSER_ID)

    note = frame.model.note
    if !isempty(note)
        note_top = cy + f(22 + 3 + 4)
        draw_text_mid(dl, FONT_REGULAR, GROUP_LABEL_SIZE, x + f(8), note_top + f(14) / 2,
            u32(t.text_dim), elide(text_width, note, f(180); size = GROUP_LABEL_SIZE); line = 14 / 11)
    end
    return nothing
end
