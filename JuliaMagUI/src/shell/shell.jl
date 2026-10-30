# The app frame: one full-window ImGui window that holds the header, the tab strip, the
# ribbon band, the main row (left pane, central area) and the status bar. The panes are in
# panes/. Dialogs, the ribbon peek, the open menu, toasts and the tooltip come after it,
# in that order.

# Heights and widths of the shell, in logical pixels (prototype CSS).
const HEADER_H = 34
const TABS_H = 32
const RIBBON_H = 102
const STATUS_H = 26
const TOOLTIP_DELAY = 0.48   # s

"""
    ShellLayout

Where the parts of the shell go, in device pixels. `ribbon` is the ribbon band; it is
`docked` under the tab strip, or else floats over the main row (the peek of a collapsed
ribbon).
"""
struct ShellLayout
    header::Box
    tabs::Box
    ribbon::Box
    docked::Bool
    left::Box
    center::Box
    status::Box
end

"""
    shell_layout(x, y, width, height, scale, left_width, collapsed) -> ShellLayout

Lay out the shell in the window rectangle (device pixels) at content `scale`.
`left_width` is the left pane width in logical pixels, clamped to $(LEFT_RANGE).
"""
function shell_layout(x::Real, y::Real, w::Real, h::Real, scale::Real, left_width,
        collapsed::Bool)::ShellLayout
    p(v) = px(scale, v)
    x0, y0, x1, y1 = Float32(x), Float32(y), Float32(x + w), Float32(y + h)
    header = Box(x0, y0, x1, y0 + p(HEADER_H))
    tabs = Box(x0, header.y1, x1, header.y1 + p(TABS_H))
    ribbon = Box(x0, tabs.y1, x1, tabs.y1 + p(RIBBON_H))
    main_top = collapsed ? tabs.y1 : ribbon.y1
    status = Box(x0, max(main_top, y1 - p(STATUS_H)), x1, y1)
    lw = min(p(pane_width(left_width, LEFT_RANGE, LEFT_DEFAULT)), Float32(w))
    left = Box(x0, main_top, x0 + lw, status.y0)
    center = Box(left.x1, main_top, x1, status.y0)
    return ShellLayout(header, tabs, ribbon, !collapsed, left, center, status)
end

const HOST_FLAGS = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
    ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoBringToFrontOnFocus |
    ig.ImGuiWindowFlags_NoNavFocus | ig.ImGuiWindowFlags_NoScrollWithMouse |
    ig.ImGuiWindowFlags_NoBackground

const PEEK_FLAGS = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
    ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoScrollWithMouse |
    ig.ImGuiWindowFlags_NoBackground

"""
    draw_app(app)

Draw one frame of the app: the shell, then the dialogs, the ribbon peek, the open menu,
the toasts and the tooltip. It handles the requests of the last frame first and the
shortcuts last.
Call it on the render thread once per frame, after `drain!` and `refresh!`.
"""
function draw_app(app)
    w = app.window::Window
    ui = app.ui
    handle_requests!(app)
    prune_toasts!(app)
    sync_current_db!(app)
    begin_menu_frame!(app)
    ui.tip = nothing
    ui.tip_hovered = false
    modal = !isempty(ui.dialogs)
    collapsed = app.config.ribbon_collapsed
    collapsed || (ui.ribbon_peek = false)

    vp = unsafe_load(ig.GetMainViewport())
    layout = shell_layout(vp.Pos.x, vp.Pos.y, vp.Size.x, vp.Size.y, w.scale,
        app.config.left_width, collapsed)
    ig.SetNextWindowPos(vp.Pos)
    ig.SetNextWindowSize(vp.Size)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowRounding, 0)
    ig.Begin("JuliaMag", C_NULL, HOST_FLAGS)
    ig.PopStyleVar(3)
    dl = ig.GetWindowDrawList()
    hot = draw_left_pane(app, dl, layout.left)
    draw_central(app, dl, layout.center)
    hot && paint_splitter(app, dl, layout.left.x1, layout.left.y0, layout.left.y1)
    draw_status_bar(app, dl, layout.status)
    layout.docked && draw_ribbon_band(app, dl, layout.ribbon)
    draw_header(app, dl, layout.header)
    draw_tab_strip(app, dl, layout.tabs)
    draw_dialogs(app)
    ig.End()

    collapsed && ui.ribbon_peek && draw_ribbon_peek(app, layout.ribbon)
    # A click on the menu of a peeking ribbon keeps the peek; Esc closes the menu first.
    mouse = unsafe_load(ig.GetIO().MousePos)
    on_menu = inside_menu(app, mouse.x, mouse.y)
    had_menu = draw_menu(app)
    if collapsed && ui.ribbon_peek
        clicked = ig.IsMouseClicked(0)
        if clicked && !on_menu && !inside(layout.tabs, mouse.x, mouse.y) &&
                !inside(layout.ribbon, mouse.x, mouse.y)
            ui.ribbon_peek = false
        end
        !modal && !had_menu && ig.IsKeyPressed(lib.ImGuiKey_Escape, false) && (ui.ribbon_peek = false)
    end
    draw_toasts(app)
    handle_shortcuts!(app)
    ui.tip_hovered || (ui.tooltip_id = 0)
    draw_tooltip(app)
    return nothing
end

"""
    sync_current_db!(app)

Keep `app.ui.current_db` on a database of the snapshot: the first one when it names none.
"""
function sync_current_db!(app)
    snap = app.snap
    snap === nothing && return nothing
    haskey(snap.databases, app.ui.current_db) && return nothing
    i = findfirst(it -> it.kind == Core.ITEM_DATABASE, snap.items)
    app.ui.current_db = i === nothing ? "" : snap.items[i].id
    return nothing
end

"""
    guarded(app, f)

Call `f(app)`. An error becomes an error toast with `user_message`, so a button whose
action fails never ends the frame.
"""
function guarded(app, f)
    try
        f(app)
    catch e
        e isa InterruptException && rethrow()
        toast!(app, :error, safe_user_message(e, catch_backtrace()))
    end
    return nothing
end

"The command with this id, or `nothing`."
function find_command(app, id::AbstractString)
    cmds = commands(app)
    i = findfirst(c -> c.id == id, cmds)
    return i === nothing ? nothing : cmds[i]
end

"""
    run_command!(app, id)

Run command `id` when it can run now. Errors become toasts.
"""
function run_command!(app, id::AbstractString)
    cmd = find_command(app, id)
    cmd === nothing && return nothing
    cmd.enabled(app) === nothing || return nothing
    guarded(app, cmd.run)
    return nothing
end

# --- The ribbon band ---

"""
    draw_ribbon_band(app, dl, b)

The ribbon band: `ribbon` fill with a 1 px `border` line at the bottom, and the groups of
the active tab (`draw_ribbon`).
"""
function draw_ribbon_band(app, dl, b::Box)
    t = app.tokens
    hl = hairline(app.window.scale)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.ribbon))
    ig.AddRectFilled(dl, (b.x0, b.y1 - hl), (b.x1, b.y1), u32(t.border))
    draw_ribbon(app, dl, b)
    return nothing
end

# The ribbon of a collapsed ribbon, shown for a moment over the main row with a shadow.
function draw_ribbon_peek(app, b::Box)
    s = app.window.scale
    ig.SetNextWindowPos((b.x0, b.y0))
    ig.SetNextWindowSize((width(b), height(b)))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowRounding, 0)
    ig.Begin("Ribbon", C_NULL, PEEK_FLAGS)
    ig.PopStyleVar(3)
    dl = ig.GetWindowDrawList()
    vp = unsafe_load(ig.GetMainViewport())
    ig.PushClipRect(dl, (vp.Pos.x, vp.Pos.y), (vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y), false)
    draw_shadow(dl, b, 0, px(s, 6), px(s, 18), app.tokens.shadow)
    ig.PopClipRect(dl)
    draw_ribbon_band(app, dl, b)
    ig.End()
    return nothing
end

# --- Tooltips ---

"""
    Tip

The tooltip to draw: a `title` with the `shortcut` in brackets, a `help` line, the
`reason` a command cannot run (or `nothing`), and the command `id`. `anchor` is the box of
the item it belongs to.
"""
struct Tip
    title::String
    shortcut::String
    help::String
    reason::Union{Nothing,String}
    id::String
    anchor::Box
end

"""
    item_tip!(app, title; shortcut = "", help = "", reason = nothing, id = "",
              hovered = ig.IsItemHovered())

Give the last ImGui item a tooltip. It shows after the mouse stays $(TOOLTIP_DELAY) s on
the item, and not again after a click until the mouse leaves the item. Pass `hovered`
when the item counts as hovered in another way (a row under its own chevron).
"""
function item_tip!(app, title::AbstractString; shortcut::AbstractString = "",
        help::AbstractString = "", reason::Union{Nothing,AbstractString} = nothing,
        id::AbstractString = "", hovered::Bool = ig.IsItemHovered())
    hovered || return nothing
    ui = app.ui
    ui.tip_hovered = true
    item = ig.GetItemID()
    now = time()
    if item != ui.tooltip_id
        ui.tooltip_id = item
        ui.tooltip_since = now
    end
    ig.IsMouseClicked(0) && (ui.tooltip_since = Inf)
    wait = TOOLTIP_DELAY - (now - ui.tooltip_since)
    if wait > 0
        isfinite(wait) && request_frames!(app.window::Window, wait + 0.02)
        return nothing
    end
    lo, hi = ig.GetItemRectMin(), ig.GetItemRectMax()
    ui.tip = Tip(String(title), String(shortcut), String(help),
        reason === nothing ? nothing : String(reason), String(id), Box(lo.x, lo.y, hi.x, hi.y))
    return nothing
end

"""
    command_tip!(app, cmd; title = cmd.name without "...")

The tooltip of a command: its name, shortcut, help, the reason it cannot run, and its id.
"""
function command_tip!(app, cmd::Command; title::AbstractString = replace(cmd.name, r"\.\.\.$" => ""))
    item_tip!(app, title; shortcut = cmd.shortcut, help = cmd.help, reason = cmd.enabled(app),
        id = cmd.id)
    return nothing
end

"""
    draw_tooltip(app)

Draw `app.ui.tip`, as the prototype's `.tip`: under its item (above it when there is no
room), at most 280 px wide, `menu` fill, 1 px `border_strong`, radius 6, shadow.
"""
function draw_tooltip(app)
    tip = app.ui.tip
    tip isa Tip || return nothing
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    hl = hairline(s)
    max_text = p(280 - 16) - 2 * hl
    title = isempty(tip.shortcut) ? tip.title : tip.title * " (" * tip.shortcut * ")"   # HTML shows the two spaces as one
    parts = Tuple{FontRole,Float32,NTuple{4,Float32},String}[]
    for l in wrap_lines(FONT_SEMIBOLD, BODY_FONT_SIZE, title, max_text)
        push!(parts, (FONT_SEMIBOLD, BODY_FONT_SIZE, t.text, l))
    end
    gaps = Int[length(parts)]
    if !isempty(tip.help)
        for l in wrap_lines(FONT_REGULAR, 11.5, tip.help, max_text)
            push!(parts, (FONT_REGULAR, 11.5f0, t.text_dim, l))
        end
        push!(gaps, length(parts))
    end
    if tip.reason !== nothing
        for l in wrap_lines(FONT_REGULAR, 11, tip.reason, max_text)
            push!(parts, (FONT_REGULAR, 11f0, t.amber, l))
        end
        push!(gaps, length(parts))
    end
    isempty(tip.id) || push!(parts, (FONT_MONO, 11f0, t.text_disabled, tip.id))
    tw = maximum(text_width(r, z, l) for (r, z, _, l) in parts)
    gap_after(i) = i in gaps && i < length(parts)   # 2 px between the blocks
    line_h(z) = Float32(z * 1.25 * s)   # CSS line height, with its fraction
    th = sum(line_h(z) for (_, z, _, _) in parts) + p(2) * count(gap_after, eachindex(parts))
    bw = round(min(tw, max_text) + p(16) + 2 * hl)
    bh = round(th + p(12) + 2 * hl)
    vp = unsafe_load(ig.GetMainViewport())
    x = min(tip.anchor.x0, vp.Pos.x + vp.Size.x - p(8) - bw)
    y = tip.anchor.y1 + p(6)
    y + bh > vp.Pos.y + vp.Size.y - p(8) && (y = tip.anchor.y0 - p(6) - bh)
    b = Box(round(max(vp.Pos.x + p(8), x)), round(y), 0, 0)
    b = Box(b.x0, b.y0, b.x0 + bw, b.y0 + bh)
    dl = ig.GetForegroundDrawList()
    draw_shadow(dl, b, p(6), p(6), p(18), t.shadow)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.menu), p(6))
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.border_strong), p(6), hl)
    y = b.y0 + hl + p(6)
    for (i, (role, size, col, line)) in enumerate(parts)
        h = line_h(size)
        draw_text_mid(dl, role, size, b.x0 + hl + p(8), y + h / 2, u32(col), line)
        y += h
        gap_after(i) && (y += p(2))
    end
    return nothing
end
