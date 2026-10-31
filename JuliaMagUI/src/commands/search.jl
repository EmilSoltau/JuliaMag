# The command search (Ctrl+K): every searchable command, found by name, id, location or help.
#
# `search_commands` is pure. The overlay is an ImGui modal popup named `SEARCH_WINDOW`. With
# no dialog open it opens in the app window; over a dialog it opens inside the top dialog's
# modal (as that dialog's menus do), so it sits above the dialog and takes the keys. It
# closes when a dialog opens or closes under it.

const SEARCH_LIMIT = 80
const SEARCH_WINDOW = "###search"
const SEARCH_HINT = "Search commands, for example import, channel math, statistics"

# Sizes in logical pixels (prototype CSS `.palette`).
const SEARCH_W = 560
const SEARCH_TOP = 84
const SEARCH_SIDE = 24       # the overlay is at most the window width less 48
const SEARCH_HEAD_H = 42     # with its 1 px bottom line
const SEARCH_LIST_MAX = 380
const SEARCH_PAD = 4
const SEARCH_ROW_H = 28
const SEARCH_EMPTY_H = 80
const SEARCH_FOOT_H = 28     # with its 1 px top line
const SEARCH_KEYS_W = 54     # the shortcut column is at least this wide

"The command's name without the `...` of a command that opens a dialog."
plain_name(c::Command) = replace(c.name, r"\.\.\.$" => "")

"""
    search_score(c, q) -> Int

How well command `c` matches the lower-case query `q`: 4 when its name starts with `q`,
3 when its name holds `q`, 2 when its id does, 1 when its location or help does, else 0.
An empty query gives 1.
"""
function search_score(c::Command, q::AbstractString)::Int
    isempty(q) && return 1
    name = lowercase(plain_name(c))
    startswith(name, q) && return 4
    occursin(q, name) && return 3
    occursin(q, lowercase(c.id)) && return 2
    (occursin(q, lowercase(location(c))) || occursin(q, lowercase(c.help))) && return 1
    return 0
end

"""
    search_commands(cmds, query; limit = $SEARCH_LIMIT, enabled = c -> true) -> Vector{Command}

The searchable commands that match `query`, best first (see `search_score`). The query is
trimmed and case does not matter; an empty one lists every searchable command. Commands of
the same score keep their order in `cmds`, except that those for which `enabled(c)` is false
come after the others. At most `limit` commands.
"""
function search_commands(cmds::AbstractVector{Command}, query::AbstractString;
        limit::Integer = SEARCH_LIMIT, enabled = c -> true)::Vector{Command}
    q = lowercase(strip(query))
    found = Tuple{Int,Bool,Int}[]
    for (i, c) in enumerate(cmds)
        c.searchable || continue
        score = search_score(c, q)
        score > 0 && push!(found, (-score, !enabled(c), i))
    end
    sort!(found)
    return Command[cmds[i] for (_, _, i) in first(found, limit)]
end

# --- State ---

"""
    open_search!(app)

Open the command search over whatever is open now, with an empty query and the first row
highlighted. Any open menu closes. Does nothing when the search is open already.
"""
function open_search!(app)
    ui = app.ui
    ui.search === nothing || return nothing
    ui.search = ""
    fill!(ui.search_buffer, 0x00)
    ui.search_index = 1
    ui.search_scroll = 0f0
    ui.search_level = length(ui.dialogs)
    ui.search_focus = true
    close_menu!(app)
    return nothing
end

"Close the command search."
close_search!(app) = (app.ui.search = nothing; nothing)

"""
    set_search_query!(app, text)

Search for `text`: the first row is highlighted and the list scrolls to the top.
"""
function set_search_query!(app, text::AbstractString)
    ui = app.ui
    ui.search = String(text)
    ui.search_index = 1
    ui.search_scroll = 0f0
    return nothing
end

"Does an open dialog or the command search hold the keys, so most shortcuts wait?"
blocks_shortcuts(app) = !isempty(app.ui.dialogs) || app.ui.search !== nothing

"What `search_hits!` found last, and for what."
struct SearchCache
    query::String
    commands::Vector{Command}
    enabled::BitVector
    hits::Vector{Command}
end

"""
    search_hits!(app) -> Vector{Command}

The results of the open search. They are kept and found again only when the query, the
command list or a command's enabled state changes.
"""
function search_hits!(app)::Vector{Command}
    ui = app.ui
    q = something(ui.search, "")
    cmds = commands(app)
    on = BitVector(c.enabled(app) === nothing for c in cmds)
    c = ui.search_cache
    c isa SearchCache && c.query == q && c.commands === cmds && c.enabled == on && return c.hits
    index = Dict(cmd.id => k for (k, cmd) in enumerate(cmds))
    hits = search_commands(cmds, q; enabled = cmd -> on[index[cmd.id]])
    ui.search_cache = SearchCache(q, cmds, on, hits)
    return hits
end

"""
    run_search_hit!(app, c)

Close the search and run command `c`, or, when it cannot run now, show why as a toast.
"""
function run_search_hit!(app, c::Command)
    close_search!(app)
    reason = c.enabled(app)
    reason === nothing ? guarded(app, c.run) : toast!(app, :info, reason)
    return nothing
end

# --- Layout ---

"""
    SearchLayout

Where the parts of the search overlay go, in device pixels: the `box` with its border, the
`top` row (with its bottom line), the `list` and the `foot` (with its top line).
"""
struct SearchLayout
    box::Box
    top::Box
    list::Box
    foot::Box
end

"""
    search_layout(viewport, scale, n) -> SearchLayout

Lay out the search overlay with `n` result rows, as the prototype's `.palette`: 560 px wide
but at most the window width less 48, centred, 84 px from the top. The top row is 42 high,
the list holds rows of 28 with 4 px padding (80 px for the "no match" text) and is at most
380 high, and the foot is 28 high. In a short window the list shrinks, down to one row, so
the overlay ends 24 px above the bottom.
"""
function search_layout(vp::Box, scale::Real, n::Integer)::SearchLayout
    f(v) = fpx(scale, v)
    hl = hairline(scale)
    w = rnd(min(f(SEARCH_W), width(vp) - f(2 * SEARCH_SIDE)))
    x0 = rnd(vp.x0 + (width(vp) - w) / 2)
    y0 = vp.y0 + rnd(f(SEARCH_TOP))
    content = n == 0 ? f(2 * SEARCH_PAD + SEARCH_EMPTY_H) : f(2 * SEARCH_PAD) + n * f(SEARCH_ROW_H)
    room = vp.y1 - f(SEARCH_SIDE) - (y0 + 2 * hl + f(SEARCH_HEAD_H + SEARCH_FOOT_H))
    list_h = rnd(max(min(content, f(SEARCH_LIST_MAX), room), min(content, f(2 * SEARCH_PAD + SEARCH_ROW_H))))
    box = Box(x0, y0, x0 + w, y0 + 2 * hl + rnd(f(SEARCH_HEAD_H)) + list_h + rnd(f(SEARCH_FOOT_H)))
    top = Box(x0 + hl, y0 + hl, box.x1 - hl, y0 + hl + rnd(f(SEARCH_HEAD_H)))
    list = Box(top.x0, top.y1, top.x1, top.y1 + list_h)
    foot = Box(top.x0, list.y1, top.x1, box.y1 - hl)
    return SearchLayout(box, top, list, foot)
end

# --- Drawing ---

const SEARCH_FLAGS = ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize |
    ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings |
    ig.ImGuiWindowFlags_NoScrollbar | ig.ImGuiWindowFlags_NoScrollWithMouse

"""
    sync_search!(app)

Close the search when a dialog opened or closed under it since it opened. Call it once per
frame before drawing.
"""
function sync_search!(app)
    ui = app.ui
    ui.search !== nothing && ui.search_level != length(ui.dialogs) && close_search!(app)
    return nothing
end

"""
    draw_search(app, level)

Draw the open command search as a modal popup at `level` (the number of dialogs under it):
call it in the app window when no dialog is open, else inside the top dialog's modal. It
closes the popup when the search is closed.
"""
function draw_search(app, level::Integer)
    ui = app.ui
    id = ig.GetID(SEARCH_WINDOW)
    if ui.search === nothing || ui.search_level != level
        k = popup_level(id)
        k >= 0 && lib.igClosePopupToLevel(k, true)
        return nothing
    end
    s = app.window.scale
    vp = unsafe_load(ig.GetMainViewport())
    view = Box(vp.Pos.x, vp.Pos.y, vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y)
    hits = search_hits!(app)
    l = search_layout(view, s, length(hits))
    popup_level(id) >= 0 || ig.OpenPopup(SEARCH_WINDOW)
    ig.SetNextWindowPos((l.box.x0, l.box.y0))
    ig.SetNextWindowSize((width(l.box), height(l.box)))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowRounding, px(s, 10))
    ig.PushStyleColor(ig.ImGuiCol_PopupBg, (0f0, 0f0, 0f0, 0f0))   # drawn below
    open = ig.BeginPopupModal(SEARCH_WINDOW, C_NULL, SEARCH_FLAGS)
    ig.PopStyleColor()
    ig.PopStyleVar(3)
    if !open
        close_search!(app)
        return nothing
    end
    run = draw_search_body(app, l, hits, view)
    ig.EndPopup()
    run === nothing || run_search_hit!(app, run)
    return nothing
end

# The overlay's frame, top row, list and foot. Returns the command to run, or `nothing`.
function draw_search_body(app, l::SearchLayout, hits::Vector{Command}, view::Box)
    ui = app.ui
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    dl = ig.GetWindowDrawList()
    b = l.box
    # The backdrop, as the prototype's `.backdrop` under the palette, and the shadow.
    ig.PushClipRect(dl, (view.x0, view.y0), (view.x1, view.y1), false)
    ig.AddRectFilled(dl, (view.x0, view.y0), (view.x1, view.y1), u32(t.backdrop))
    draw_shadow(dl, b, f(10), f(10), f(28), t.shadow)
    ig.PopClipRect(dl)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.menu), f(10))
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.border_strong), f(10), hl)

    # Top: icon, text field, close x; a line under it.
    top = l.top
    mid = (top.y0 + top.y1 - hl) / 2
    icon_x = top.x0 + f(14)
    draw_icon(dl, "search", (rnd(icon_x), rnd(mid - f(9))), 18; style = :dim)
    close = Box(top.x1 - f(10 + 22), rnd(mid - f(11)), top.x1 - f(10), rnd(mid - f(11)) + f(22))
    # The `<input>`: 32 high, with Chromium's own padding of 1 by 2 px, on whole pixels as
    # Chromium paints it.
    field = snap(Box(icon_x + f(18 + 8 + 2), mid - f(15), close.x0 - f(8 + 2), mid + f(15)))
    # The field keeps the keys: it takes the focus back after a click elsewhere in the box.
    focus = ui.search_focus || (!ig.IsAnyItemActive() && !ig.IsMouseDown(0))
    ui.search_focus = false
    _, active = text_input!(app, "##query", ui.search_buffer, field; size = 13, focus, input = true)
    text = field_text(ui.search_buffer)
    text == ui.search || set_search_query!(app, text)
    if isempty(text)
        hint = elide(text_width, SEARCH_HINT, width(field); size = 13)
        with_font(FONT_REGULAR, 13) do
            ig.AddText(dl, (round(field.x0), input_text_y(FONT_REGULAR, 13, centre_y(field))),
                u32(t.placeholder), hint)
        end
    end
    clicked, hovered = icon_button(app, "Close search", "close", close; dl)
    hovered && item_tip!(app, "Close"; shortcut = "Esc")
    ig.AddRectFilled(dl, (top.x0, top.y1 - hl), (top.x1, top.y1), u32(t.border))
    clicked && (close_search!(app); return nothing)

    chosen = draw_search_list(app, dl, l.list, hits)
    draw_search_foot(app, dl, l.foot)

    # Keys: Up and Down move the highlight, Enter runs it, Esc closes. A click on the
    # backdrop closes too.
    n = length(hits)
    ui.search_index = clamp(ui.search_index, 1, max(n, 1))
    step = ig.IsKeyPressed(lib.ImGuiKey_DownArrow, true) ? 1 :
        ig.IsKeyPressed(lib.ImGuiKey_UpArrow, true) ? -1 : 0
    if step != 0 && n > 0
        ui.search_index = clamp(ui.search_index + step, 1, n)
        reveal_search_row!(app, l.list, n)
    end
    enter = ig.IsKeyPressed(lib.ImGuiKey_Enter, false) || ig.IsKeyPressed(lib.ImGuiKey_KeypadEnter, false)
    if chosen === nothing && enter
        n > 0 ? (chosen = hits[ui.search_index]) : close_search!(app)
    end
    mouse = unsafe_load(ig.GetIO().MousePos)
    if chosen === nothing && (ig.IsKeyPressed(lib.ImGuiKey_Escape, false) ||
            (ig.IsMouseClicked(0) && !inside(b, mouse.x, mouse.y)))
        close_search!(app)
    end
    (active || ig.IsMouseDown(0)) || request_frames!(app.window::Window)   # focus the field again
    return chosen
end

# Scroll the list so the highlighted row is wholly in view.
function reveal_search_row!(app, list::Box, n::Integer)
    ui = app.ui
    s = app.window.scale
    rh = fpx(s, SEARCH_ROW_H)
    content = fpx(s, 2 * SEARCH_PAD) + n * rh
    top = fpx(s, SEARCH_PAD) + (ui.search_index - 1) * rh - ui.search_scroll
    top < 0 && (ui.search_scroll += top)
    top + rh > height(list) && (ui.search_scroll += top + rh - height(list))
    ui.search_scroll = clamp(ui.search_scroll, 0f0, max(content - height(list), 0f0))
    return nothing
end

# The result rows, or the "no match" text. Returns the command clicked, or `nothing`.
function draw_search_list(app, dl, list::Box, hits::Vector{Command})
    ui = app.ui
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    if isempty(hits)
        msg = "No command matches \"" * something(ui.search, "") * "\"."
        msg = elide(text_width, msg, width(list) - f(2 * SEARCH_PAD + 16))
        tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, msg)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, list.x0 + (width(list) - tw) / 2,
            centre_y(list), u32(t.text_dim), msg; line = 1.6)
        return nothing
    end
    rh = f(SEARCH_ROW_H)
    pad = f(SEARCH_PAD)
    ig.PushID("list")
    # The thumb sits in the list's right padding and the rows' own; the rows keep their width.
    ui.search_scroll, _ = scroll_area!(app, "scrollbar", list, 2 * pad + length(hits) * rh, ui.search_scroll)
    ig.PopID()
    io = unsafe_load(ig.GetIO())
    moved = io.MouseDelta.x != 0 || io.MouseDelta.y != 0
    chosen = nothing
    ig.PushClipRect((list.x0, list.y0), (list.x1, list.y1), true)
    for k in visible_rows(length(hits), rh, ui.search_scroll - pad, height(list))
        y = list.y0 + pad + (k - 1) * rh - ui.search_scroll
        row = Box(list.x0 + pad, y, list.x1 - pad, y + rh)
        c = hits[k]
        clicked, hovered, _ = hit(c.id, row)
        # The last input wins: a mouse that moves over a row takes the highlight.
        hovered && moved && (ui.search_index = k)
        k == ui.search_index && ig.AddRectFilled(dl, (row.x0, row.y0), (row.x1, row.y1), u32(t.hover), f(5))
        draw_search_row(app, dl, row, c)
        clicked && (chosen = c)
    end
    ig.PopClipRect()
    return chosen
end

# One row, as the prototype's `.prow`: icon 16, name 13, mono id (cut to fit), and at the
# right the location and the shortcut (a column at least 54 wide).
function draw_search_row(app, dl, row::Box, c::Command)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    enabled = c.enabled(app) === nothing
    mid = centre_y(row)
    x = row.x0 + f(8)
    draw_icon(dl, c.icon, (rnd(x), rnd(mid - f(8))), 16; style = enabled ? :normal : :disabled)
    x += f(16 + 8)
    x += draw_text_mid(dl, FONT_REGULAR, 13, x, mid, u32(enabled ? t.text : t.text_disabled), plain_name(c))
    keys_w = max(f(SEARCH_KEYS_W), text_width(FONT_REGULAR, 11, c.shortcut))
    keys_x1 = row.x1 - f(8)
    isempty(c.shortcut) || draw_text_mid(dl, FONT_REGULAR, 11,
        keys_x1 - text_width(FONT_REGULAR, 11, c.shortcut), mid, u32(t.text_dim), c.shortcut)
    loc = location(c)
    loc_x = keys_x1 - keys_w - f(8) - text_width(FONT_REGULAR, 11, loc)
    draw_text_mid(dl, FONT_REGULAR, 11, loc_x, mid, u32(t.text_dim), loc)
    id_x = x + f(8)
    id = elide(text_width, c.id, loc_x - f(12 + 8) - id_x; role = FONT_MONO, size = 11)
    draw_text_mid(dl, FONT_MONO, 11, id_x, mid, u32(t.text_disabled), id)
    return nothing
end

const SEARCH_FOOT_PARTS = (("Up", "Down") => "to move", ("Enter",) => "to run", ("Esc",) => "to close")

# The foot: a line on top, the key hints at the left and the number of commands at the right.
function draw_search_foot(app, dl, foot::Box)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.AddRectFilled(dl, (foot.x0, foot.y0), (foot.x1, foot.y0 + hl), u32(t.border))
    mid = (foot.y0 + hl + foot.y1) / 2
    space = text_width(FONT_REGULAR, 11, " ")
    x = foot.x0 + f(12)
    for (k, (keys, words)) in enumerate(SEARCH_FOOT_PARTS)
        k > 1 && (x += f(14))
        for key in keys
            x += draw_kbd(app, dl, x, mid, key) + space
        end
        x += draw_text_mid(dl, FONT_REGULAR, 11, x, mid, u32(t.text_dim), words)
    end
    n = count(c -> c.searchable, commands(app))
    total = string(n, n == 1 ? " command" : " commands")
    draw_text_mid(dl, FONT_REGULAR, 11, foot.x1 - f(12) - text_width(FONT_REGULAR, 11, total), mid,
        u32(t.text_dim), total)
    return nothing
end
