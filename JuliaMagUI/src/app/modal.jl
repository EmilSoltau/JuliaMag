# Modal dialogs: the stack, the dialog frame and the confirm box.
#
# `app.ui.dialogs` holds the open dialogs, bottom first. Each frame `draw_dialogs` draws
# them as nested ImGui modal popups: dialog k+1 opens inside dialog k, as ImGui wants.
# A dialog type adds a method to `draw_modal(app, d)`, which calls `draw_dialog`.

"""
    push_dialog!(app, d)

Open dialog `d` on top of the others. Only modal dialogs go on the stack: while it is
not empty, shortcuts other than Ctrl+K and Esc do nothing.
"""
push_dialog!(app, d) = (push!(app.ui.dialogs, d); d)

"""
    pop_dialog!(app)

Close the top dialog. Does nothing when no dialog is open.
"""
pop_dialog!(app) = (isempty(app.ui.dialogs) || pop!(app.ui.dialogs); nothing)

"""
    draw_modal(app, d)

Draw dialog `d` with `draw_dialog`. Each dialog type adds a method.
"""
function draw_modal(app, @nospecialize(d))
    @error "This dialog cannot be drawn, so it is closed" dialog = d
    filter!(x -> x !== d, app.ui.dialogs)
    return nothing
end

"""
    draw_dialogs(app)

Draw the dialog stack. Call it once per frame, inside the app window, after the shell.
A dialog that left the stack since the last frame also leaves ImGui's popup stack here.
"""
function draw_dialogs(app)
    close_stale_popups!(app)
    isempty(app.ui.dialogs) || draw_modal(app, first(app.ui.dialogs))
    return nothing
end

# Close the ImGui popups of dialogs that were drawn last frame and are no longer on the
# stack (closed by a button, by `set_session!` or by a test), with every popup above them.
function close_stale_popups!(app)
    drawn = app.ui.drawn_dialogs
    dialogs = app.ui.dialogs
    k = 0
    while k < length(drawn) && k < length(dialogs) && first(drawn[k+1]) === dialogs[k+1]
        k += 1
    end
    k == length(drawn) && return nothing
    level = popup_level(last(drawn[k+1]))
    level >= 0 && lib.igClosePopupToLevel(level, true)
    resize!(drawn, k)
    return nothing
end

# The place of popup `id` in ImGui's open popup stack (0 is the bottom), or -1.
function popup_level(id::UInt32)::Int
    ctx = Ptr{lib.ImGuiContext}(ig.GetCurrentContext())
    stack = unsafe_load(ctx.OpenPopupStack)
    for i in 1:stack.Size
        unsafe_load(stack.Data, i).PopupId == id && return i - 1
    end
    return -1
end

"""
    dialog_ref(level) -> String

The ImGui window name of the dialog at `level` of the stack (1 is the bottom).
Test engine references to its items start with `"//" * dialog_ref(level) * "/"`.
"""
dialog_ref(level::Integer) = "###dialog$level"

const DIALOG_FLAGS = ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize |
    ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings |
    ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoScrollbar

"""
    draw_dialog(f, app, d; title, icon = "", subtitle = "", width = 520, ok_label = "OK",
                ok_enabled = true, ok_busy = false, on_ok, on_cancel = () -> pop_dialog!(app),
                footer_left = nothing, cancel_label = "Cancel") -> Union{Nothing,Box}

The frame of modal dialog `d`, as the prototype's `openDialog`: centred over the
`backdrop`, `width` px wide, radius 10, `menu` fill, 1 px `border_strong`, shadow.
The header is 46 high: a 22 px `icon`, the `title` (15 semibold), the `subtitle` (mono 11
`text_disabled`, such as a tool id) at the right, and a close x; drag it to move the
dialog. `f()` draws the body, padded 14 by 16. The footer holds what `footer_left()`
draws on the left, then Cancel and the primary button (`ok_label`, greyed when
`ok_enabled` is false, a spinner and no clicks while `ok_busy`). With
`cancel_label = nothing` there is no Cancel button (Esc and the close x still call
`on_cancel`).

Esc, Cancel and the close x call `on_cancel()`; the primary button calls `on_ok()`, and so
does Enter while a one-line text field of the dialog is active (Enter in a multi-line field
makes a new line). While a menu of the dialog or the command search is open over it, Esc
and Enter belong to that.
`on_ok` decides whether the dialog closes (`pop_dialog!`). Errors in the callbacks become
error toasts. Returns the box of the primary button, or `nothing` when nothing was drawn.
"""
function draw_dialog(f, app, d; title::AbstractString, icon::AbstractString = "",
        subtitle::AbstractString = "", width::Real = 520, ok_label::AbstractString = "OK",
        ok_enabled::Bool = true, ok_busy::Bool = false, on_ok::Function,
        on_cancel::Function = () -> pop_dialog!(app),
        footer_left::Union{Nothing,Function} = nothing,
        cancel_label::Union{Nothing,AbstractString} = "Cancel")
    dialogs = app.ui.dialogs
    level = findfirst(x -> x === d, dialogs)
    level === nothing && return nothing
    w = app.window::Window
    s = w.scale
    t = app.tokens
    p(x) = px(s, x)
    hl = hairline(s)
    name = dialog_ref(level)
    id = ig.GetID(name)
    drawn = app.ui.drawn_dialogs
    length(drawn) >= level ? (drawn[level] = (d, id)) : push!(drawn, (d, id))
    ig.IsPopupOpen(name) || ig.OpenPopup(name)

    vp = unsafe_load(ig.GetMainViewport())
    dw = p(width)
    # Centred, 30 px above the middle, as the prototype's `Math.round((innerHeight - h) / 2 - 30)`:
    # ImGui truncates the top left, so the extra half pixel makes it round half up.
    ig.SetNextWindowPos((vp.Pos.x + vp.Size.x / 2 + 0.5f0, vp.Pos.y + vp.Size.y / 2 - p(30) + 0.5f0),
        ig.ImGuiCond_Appearing, (0.5, 0.5))
    ig.SetNextWindowSizeConstraints((dw, 0f0), (dw, max(vp.Size.y - p(40), p(100))))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowRounding, p(10))
    ig.PushStyleColor(ig.ImGuiCol_PopupBg, (0f0, 0f0, 0f0, 0f0))   # the frame below draws the fill
    open = ig.BeginPopupModal(name, C_NULL, DIALOG_FLAGS)
    ig.PopStyleColor()
    ig.PopStyleVar(3)
    open || return nothing
    keep_on_screen!(app, d, level, vp, s)

    top = level == length(dialogs)
    typing = unsafe_load(ig.GetIO()).WantTextInput
    m = app.ui.menu
    menu_here = m isa OpenMenu && m.level == level   # Esc and Enter go to the menu
    search_here = app.ui.search !== nothing && app.ui.search_level == level   # or to the search
    pos = ig.GetWindowPos()
    size = ig.GetWindowSize()
    b = Box(pos.x, pos.y, pos.x + dw, pos.y + size.y)
    dl = ig.GetWindowDrawList()
    ig.PushClipRect(dl, (vp.Pos.x, vp.Pos.y), (vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y), false)
    ig.AddRectFilled(dl, (vp.Pos.x, vp.Pos.y), (vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y),
        u32(t.backdrop))
    draw_shadow(dl, b, p(10), p(10), p(28), t.shadow)
    ig.PopClipRect(dl)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.menu), p(10))

    # Header: icon, title, close x; a drag on it moves the dialog.
    head = Box(b.x0 + hl, b.y0 + hl, b.x1 - hl, b.y0 + hl + p(46))
    mid = (head.y0 + head.y1 - hl) / 2
    close = Box(head.x1 - p(10 + 22), mid - p(11), head.x1 - p(10), mid + p(11))
    _, _, dragging = hit("##move", Box(head.x0, head.y0, close.x0, head.y1))
    dragging && move_dialog!(vp, b, s)
    x = head.x0 + p(16)
    if !isempty(icon)
        draw_icon(dl, icon, (x, mid - p(11)), 22)
        x += p(22 + 10)
    end
    title_end = close.x0 - p(10)
    if !isempty(subtitle)   # `.dlg-h .mono`: right of the title, 10 px before the close x
        sw = text_width(FONT_MONO, 11, subtitle)
        sx = max(x, title_end - sw)
        draw_text_mid(dl, FONT_MONO, 11, sx, mid, u32(t.text_disabled), subtitle)
        title_end = sx - p(10)
    end
    ig.PushClipRect(dl, (x, head.y0), (title_end, head.y1), true)
    draw_text_mid(dl, FONT_SEMIBOLD, 15, x, mid, u32(t.text), title)
    ig.PopClipRect(dl)
    cancel = false
    # Its id is not "Close", which a primary button may use (the result dialog).
    clicked, hovered = icon_button(app, "Close dialog", "close", close; size = 22)   # `.dlg-h .ic` is 22 px
    hovered && item_tip!(app, "Close"; shortcut = "Esc")
    cancel |= clicked
    ig.AddRectFilled(dl, (head.x0, head.y1 - hl), (head.x1, head.y1), u32(t.border))

    # Body: a child window, padded 14 by 16, as high as what it holds. When the dialog
    # would be taller than the window less 40 px it scrolls, and the header and footer stay
    # (the prototype's `.dlg` `max-height: calc(100vh - 40px)` and `.dlg-b` `overflow: auto`).
    footer_h = hl + p(12 + 26 + 12) + hl
    max_body = max(vp.Size.y - p(40) - (head.y1 - b.y0) - footer_h, p(60))
    seed = unsafe_load(lib.igGetCurrentWindow().ID)
    ig.SetCursorScreenPos((head.x0, head.y1))
    ig.SetNextWindowSizeConstraints((0f0, 0f0), (dw - 2 * hl, max_body))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (p(16), p(14)))
    ig.BeginChild("body", (dw - 2 * hl, 0f0),
        lib.ImGuiChildFlags_AutoResizeY | lib.ImGuiChildFlags_AlwaysUseWindowPadding,
        ig.ImGuiWindowFlags_NoBackground)
    ig.PopStyleVar()
    lib.igPushOverrideID(seed)   # the body's items keep the dialog's ids
    body_w = Float32(ig.GetContentRegionAvail().x)   # less the scrollbar when it shows
    ig.PushTextWrapPos(ig.GetCursorPos().x + body_w)
    ig.PushItemWidth(body_w)   # `paragraph` and the forms wrap to it
    broken = run_body(f, app)
    broken && filter!(x -> x !== d, dialogs)
    content_end = ig.GetItemRectMax().y + fpx(s, 14)   # unless it scrolls: ImGui truncates the child's height
    scrolls = ig.GetScrollMaxY() >= 1
    ig.PopItemWidth()
    ig.PopTextWrapPos()
    ig.PopID()
    ig.EndChild()
    # A body of fractional height (hint lines are 14.85 px) puts the footer line on a
    # whole pixel, as a browser snaps the border it paints.
    body_end = rnd(scrolls ? ig.GetItemRectMax().y : content_end)

    # Footer: the left buttons, then Cancel and the primary button on the right.
    ig.AddRectFilled(dl, (head.x0, body_end), (head.x1, body_end + hl), u32(t.border))
    by = body_end + hl + p(12)
    if footer_left !== nothing
        ig.SetCursorScreenPos((head.x0 + p(16), by))
        ig.BeginGroup()
        footer_left()
        ig.EndGroup()
    end
    ok_w = round(button_width(app, ok_label; primary = true))
    ok_x = head.x1 - p(16) - ok_w
    if cancel_label !== nothing
        cancel_w = round(button_width(app, cancel_label))
        cancel |= button(app, cancel_label, cancel_label, ok_x - p(8) - cancel_w, by)
    end
    ok = button(app, ok_label, ok_label, ok_x, by; primary = true, enabled = ok_enabled, busy = ok_busy)
    ok_box = Box(ok_x, by, ok_x + ok_w, by + p(26))
    footer_end = by + p(26 + 12) + hl
    ig.SetCursorScreenPos((b.x0, footer_end))
    ig.Dummy((dw, 0f0))
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, footer_end), u32(t.border_strong), p(10), hl)

    if top && !broken && !menu_here && !search_here
        cancel |= ig.IsKeyPressed(lib.ImGuiKey_Escape, false)
        enter = ig.IsKeyPressed(lib.ImGuiKey_Enter, false) || ig.IsKeyPressed(lib.ImGuiKey_KeypadEnter, false)
        ok |= typing && enter && ok_enabled && !ok_busy && !multiline_active()
    end
    # The next dialog opens inside this one; the top one holds its open menu.
    !broken && level < length(dialogs) && draw_modal(app, dialogs[level+1])
    !broken && top && draw_dialog_menu(app, level)
    !broken && top && draw_search(app, level)   # the command search opens over the top dialog
    ig.EndPopup()
    broken && return nothing
    if cancel
        guarded(app, _ -> on_cancel())
    elseif ok
        guarded(app, _ -> on_ok())
    end
    return ok_box
end

"""
    DialogPlace

Where a dialog of the stack was placed: the `dialog` at that level, its `height` in the
last frame, and the last frame (`centre_until`) in which a change of height centres it
again (it opened, or a section opened or closed: see `recentre_dialog!`).
"""
mutable struct DialogPlace
    dialog::Any
    height::Float32
    centre_until::Int
end

# A dialog measures its body one frame late (the child window sizes itself to what it
# holds), so a new height can come up to this many frames after an open or a toggle.
const CENTRE_FRAMES = 3

# Place the dialog `d` at `level` (the current window) when its height changes. Just after
# it opened or a section toggled, it is centred, as the prototype's `place()`:
# `Math.max(20, Math.round((innerHeight - h) / 2 - 30))` in CSS px, and centred across.
# Any other change (an error line, a coordinate system name) keeps it where it is, also
# where the user dragged it, and only keeps its bottom 20 px inside the window.
function keep_on_screen!(app, d, level::Integer, vp, scale::Real)
    places = app.ui.dialog_places
    while length(places) < level
        push!(places, DialogPlace(nothing, -1f0, 0))
    end
    frame = app.window.frame
    pl = places[level]
    pl.dialog === d || (places[level] = pl = DialogPlace(d, -1f0, frame + CENTRE_FRAMES))
    # Draw the frames in which the dialog sizes itself, also when the loop would idle:
    # else its footer can stay cut off until the next input (a result from the worker).
    frame <= pl.centre_until && draw_frames!(app.window, pl.centre_until - frame + 1)
    h = Float32(ig.GetWindowSize().y)
    pl.height == h && return nothing
    pl.height = h
    s = Float32(scale)
    if frame <= pl.centre_until
        top = max(20f0, rnd((vp.Size.y - h) / (2s) - 30)) * s
        # Across, centred in device px (the window's width in CSS px need not be whole).
        left = floor(vp.Size.x / 2 + 0.5f0 - Float32(ig.GetWindowSize().x) / 2)
        ig.SetWindowPos((vp.Pos.x + left, vp.Pos.y + top))
    else
        pos = ig.GetWindowPos()
        y = max(vp.Pos.y + px(scale, 20), min(pos.y, vp.Pos.y + vp.Size.y - px(scale, 20) - h))
        y == pos.y || ig.SetWindowPos((pos.x, round(y)))
    end
    return nothing
end

"""
    recentre_dialog!(app, d)

A section of dialog `d` opened or closed (Advanced, Tool Description): centre it again
when its height changes in the next frames.
"""
function recentre_dialog!(app, d)
    for pl in app.ui.dialog_places
        pl.dialog === d && (pl.centre_until = app.window.frame + CENTRE_FRAMES)
    end
    return nothing
end

# Is a multi-line text field active? Enter there makes a new line (review finding 8 of Task 9).
function multiline_active()::Bool
    id = lib.igGetActiveID()
    id == 0 && return false
    st = lib.igGetInputTextState(id)
    st == C_NULL && return false
    return (unsafe_load(st).Flags & Int(lib.ImGuiInputTextFlags_Multiline)) != 0
end

"""
    run_body(f, app) -> Bool

Run the dialog body `f()`. When it throws, put back the ImGui stacks (windows, ids,
groups, styles, fonts) as they were before it, note the error as a draw error (a toast,
one log entry, and a failed test in the harness: T13-C6) and return true; the dialog then
closes. So a broken form never ends the app.
"""
function run_body(f, app)::Bool
    state = Ref{lib.ImGuiErrorRecoveryState}()
    lib.igErrorRecoveryStoreState(state)
    try
        f()
        return false
    catch e
        e isa InterruptException && rethrow()
        bt = catch_backtrace()
        recover_imgui_state(state)
        note_draw_error!(app, e, bt)
        return true
    end
end

# ImGui's recovery, without its asserts, log lines and tooltip: the caller reports the error.
function recover_imgui_state(state::Ref{lib.ImGuiErrorRecoveryState})
    io = Ptr{lib.ImGuiIO}(ig.GetIO())
    old = (unsafe_load(io.ConfigErrorRecoveryEnableAssert), unsafe_load(io.ConfigErrorRecoveryEnableDebugLog),
        unsafe_load(io.ConfigErrorRecoveryEnableTooltip))
    io.ConfigErrorRecoveryEnableAssert = false
    io.ConfigErrorRecoveryEnableDebugLog = false
    io.ConfigErrorRecoveryEnableTooltip = false
    try
        lib.igErrorRecoveryTryToRecoverState(state)
    finally
        io.ConfigErrorRecoveryEnableAssert = old[1]
        io.ConfigErrorRecoveryEnableDebugLog = old[2]
        io.ConfigErrorRecoveryEnableTooltip = old[3]
    end
    return nothing
end

# Follow a drag of the dialog header, keeping a part of the dialog on the screen.
function move_dialog!(vp, b::Box, scale::Real)
    delta = unsafe_load(ig.GetIO().MouseDelta)
    x = clamp(b.x0 + delta.x, vp.Pos.x + px(scale, 8) - width(b) + px(scale, 80),
        vp.Pos.x + vp.Size.x - px(scale, 80))
    y = clamp(b.y0 + delta.y, vp.Pos.y, vp.Pos.y + vp.Size.y - px(scale, 46))
    ig.SetWindowPos((round(x), round(y)))
    return nothing
end

"""
    paragraph(app, text; colour = :text_dim, size = 12.5, pitch = 1.4)

Wrapped text in the dialog body, as the prototype's `.help` paragraph: lines `pitch`
times the font size apart, as wide as the current item width (the body width in
`draw_dialog`). Takes its space as an ImGui item.
"""
function paragraph(app, text::AbstractString; colour::Symbol = :text_dim, size::Real = BODY_FONT_SIZE,
        pitch::Real = 1.4)
    s = app.window.scale
    x0 = ig.GetCursorScreenPos().x
    max_w = max(Float32(ig.CalcItemWidth()), 1f0)
    lines = wrap_lines(FONT_REGULAR, size, text, max_w)
    line_h = Float32(size * pitch * s)   # not rounded: a browser keeps the fraction
    y = ig.GetCursorScreenPos().y
    dl = ig.GetWindowDrawList()
    col = u32(getfield(app.tokens, colour))
    for l in lines
        draw_text_mid(dl, FONT_REGULAR, size, x0, y + line_h / 2, col, l; line = pitch)
        y += line_h
    end
    ig.Dummy((max_w, round(line_h * length(lines))))
    return nothing
end

"""
    ConfirmDialog

A yes or no question; see `confirm!`.
"""
struct ConfirmDialog
    title::String
    text::String
    action::String
    danger::Bool
    on_yes::Function
    on_no::Function
end

"""
    confirm!(app, title, text; action, danger = false, on_yes, on_no = app -> nothing)

Ask before doing something, as the prototype's `confirmBox`: a 420 px dialog with `text`,
Cancel and the primary button `action`. A `danger` question has the warning icon, else
the info icon. The primary button closes the dialog and calls `on_yes(app)`; Cancel, Esc
and the close x close it and call `on_no(app)`.
"""
function confirm!(app, title::AbstractString, text::AbstractString; action::AbstractString,
        danger::Bool = false, on_yes::Function, on_no::Function = app -> nothing)
    return push_dialog!(app, ConfirmDialog(String(title), String(text), String(action), danger,
        on_yes, on_no))
end

function draw_modal(app, d::ConfirmDialog)
    draw_dialog(app, d; title = d.title, icon = d.danger ? "warn" : "info", width = 420,
        ok_label = d.action,
        on_ok = () -> (filter!(x -> x !== d, app.ui.dialogs); d.on_yes(app)),
        on_cancel = () -> (filter!(x -> x !== d, app.ui.dialogs); d.on_no(app))) do
        paragraph(app, d.text)
    end
    return nothing
end
