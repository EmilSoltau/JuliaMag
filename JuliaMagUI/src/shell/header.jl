# The header: logo, app name, quick access toolbar, project title and the command search pill.

# The quick access toolbar: command id and icon. The theme button's icon follows the theme.
const QAT = ("project.new" => "new", "project.open" => "open", "session.undo" => "undo",
    "session.redo" => "redo", "ui.theme.toggle" => "moon")

const PILL_WIDTH = 248
const PILL_MIN_WIDTH = 150
const DOC_TITLE_SIZE = 12   # the shown document's part of the title
const DOC_TITLE_SEP = " - "

"""
    HeaderLayout

Where the header parts go, in device pixels. `title` is `nothing` when the title does
not fit between the toolbar and the pill; `doc` is the box of the shown document's part of
the title, `nothing` when there is none or it does not fit. `pill_round` means the pill
shrank to a round search button.
"""
struct HeaderLayout
    logo::Box
    name_x::Float32
    qat::Vector{Box}
    title::Union{Nothing,Box}
    doc::Union{Nothing,Box}
    pill::Box
    pill_round::Bool
end

"""
    header_layout(b, scale, measure, title, n_qat; doc = "") -> HeaderLayout

Lay out the header in box `b` as the prototype's `#header`: padding 10, a 24 px logo,
8 px, the app name (13 semibold), 12 px, `n_qat` toolbar buttons of 26 by 22 with 2 px
between, the title centred in the window, and the search pill (248 by 24) at the right.
The title is the project name (12.5 semibold), then `" - "` and `doc`, the shown document's
name such as `"Map 1"` (12 regular), as the prototype's `renderTitle`.
The pill shrinks to 150 px, then to a 26 px round button, rather than touch the toolbar.
The title is dropped when it would come within 12 px of the toolbar or the pill: first its
document part, then all of it.
`measure(role, size, text)` is the text width in device pixels.
"""
function header_layout(b::Box, scale::Real, measure, title::AbstractString,
        n_qat::Integer; doc::AbstractString = "")::HeaderLayout
    p(v) = px(scale, v)
    mid = centre_y(b)
    logo = Box(b.x0 + p(10), round(mid - p(12)), b.x0 + p(34), round(mid - p(12)) + p(24))
    name_x = logo.x1 + p(8)
    x = round(name_x + measure(FONT_SEMIBOLD, 13, APP_NAME) + p(12))
    qat = Box[]
    for _ in 1:n_qat
        push!(qat, Box(x, round(mid - p(11)), x + p(26), round(mid - p(11)) + p(22)))
        x += p(28)
    end
    qat_end = isempty(qat) ? name_x : last(qat).x1
    right = b.x1 - p(10)
    room = right - qat_end - p(12)
    pw = room >= p(PILL_WIDTH) ? p(PILL_WIDTH) : room >= p(PILL_MIN_WIDTH) ? round(room) : p(26)
    pill = Box(right - pw, round(mid - p(12)), right, round(mid - p(12)) + p(24))
    pill_round = pw < p(PILL_MIN_WIDTH)
    tbox = dbox = nothing
    if !isempty(title)
        tw = measure(FONT_SEMIBOLD, BODY_FONT_SIZE, title)
        dw = isempty(doc) ? 0f0 :
            measure(FONT_REGULAR, DOC_TITLE_SIZE, DOC_TITLE_SEP) + measure(FONT_REGULAR, DOC_TITLE_SIZE, doc)
        fits(w) = (x = round((b.x0 + b.x1 - w) / 2); x >= qat_end + p(12) && x + w <= pill.x0 - p(12))
        dw > 0 && !fits(tw + dw) && (dw = 0f0)
        if fits(tw + dw)
            tx = round((b.x0 + b.x1 - tw - dw) / 2)
            tbox = Box(tx, b.y0, tx + tw, b.y1)
            dw > 0 && (dbox = Box(tx + tw, b.y0, tx + tw + dw, b.y1))
        end
    end
    return HeaderLayout(logo, name_x, qat, tbox, dbox, pill, pill_round)
end

"The project title of the header: the project name, or `\"\"` without a project."
header_title(app) = app.snap === nothing ? "" : app.snap.project_name

"The shown document of the header title: the shown map's name, or `\"\"`."
function header_doc(app)::String
    mv = shown_map(app)
    return mv === nothing ? "" : mv.name
end

"""
    draw_header(app, dl, b)

Draw the header in box `b` (34 high, `header` fill).
"""
function draw_header(app, dl, b::Box)
    w = app.window::Window
    s = w.scale
    t = app.tokens
    p(v) = px(s, v)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.header))
    title = header_title(app)
    doc = header_doc(app)
    l = header_layout(b, s, text_width, title, length(QAT); doc)
    mid = centre_y(b)
    draw_icon(dl, "logo", (l.logo.x0, l.logo.y0), 24)
    draw_text_mid(dl, FONT_SEMIBOLD, 13, l.name_x, mid, u32(t.text), APP_NAME)
    l.title === nothing ||
        draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, l.title.x0, mid, u32(t.text), title)
    if l.doc !== nothing
        col = u32(t.text_dim)
        draw_text_mid(dl, FONT_REGULAR, DOC_TITLE_SIZE, l.doc.x0, mid, col, DOC_TITLE_SEP)
        draw_text_mid(dl, FONT_REGULAR, DOC_TITLE_SIZE, l.doc.x0 + text_width(FONT_REGULAR, DOC_TITLE_SIZE, DOC_TITLE_SEP),
            mid, col, doc)
    end

    ig.PushID("header")
    dark = t === DARK
    for ((id, icon), box) in zip(QAT, l.qat)
        cmd = find_command(app, id)
        cmd === nothing && continue
        enabled = cmd.enabled(app) === nothing
        name = id == "ui.theme.toggle" ? "Theme" : replace(cmd.name, r"\.\.\.$" => "")
        clicked, hovered, held = hit(name, box)
        if enabled && hovered
            ig.AddRectFilled(dl, (box.x0, box.y0), (box.x1, box.y1),
                u32(held ? t.pressed : t.hover), p(6))
        end
        icon = id == "ui.theme.toggle" ? (dark ? "sun" : "moon") : icon
        draw_icon(dl, icon, (box.x0 + p(4), box.y0 + p(2)), 18; style = enabled ? :normal : :disabled)
        clicked && enabled && guarded(app, cmd.run)
        hovered && command_tip!(app, cmd; title = qat_title(app, id, cmd))
    end
    draw_search_pill(app, dl, l.pill, l.pill_round)
    ig.PopID()
    return nothing
end

# The tooltip title of a toolbar button, as the prototype's `renderQat`.
function qat_title(app, id::AbstractString, cmd::Command)::String
    snap = app.snap
    if id == "session.undo" && snap !== nothing && snap.undo_label !== nothing
        return "Undo " * snap.undo_label
    elseif id == "session.redo" && snap !== nothing && snap.redo_label !== nothing
        return "Redo " * snap.redo_label
    elseif id == "ui.theme.toggle"
        return app.tokens === DARK ? "Switch to the light theme" : "Switch to the dark theme"
    end
    return replace(cmd.name, r"\.\.\.$" => "")
end

# The command search pill: a click opens the command search.
function draw_search_pill(app, dl, b::Box, round_button::Bool)
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    hl = hairline(s)
    clicked, hovered, _ = hit("Command Search", b)
    r = height(b) / 2
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(hovered ? t.hover : t.input), r)
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.border), r, hl)
    mid = centre_y(b)
    if round_button
        draw_icon(dl, "search", (b.x0 + (width(b) - p(14)) / 2, mid - p(7)), 14; style = :dim)
        hovered && item_tip!(app, "Command Search"; shortcut = "Ctrl+K")
    else
        x = b.x0 + hl + p(9)
        draw_icon(dl, "search", (x, round(mid - p(7))), 14; style = :dim)
        hint = "Ctrl+K"
        hint_w = text_width(FONT_REGULAR, 11, hint)
        hint_x = b.x1 - hl - p(12) - hint_w
        draw_text_mid(dl, FONT_REGULAR, 11, hint_x, mid, u32(t.text_disabled), hint)
        label = "Command Search"
        label_x = x + p(14 + 7)
        label_x + text_width(FONT_REGULAR, 12, label) <= hint_x - p(7) &&
            draw_text_mid(dl, FONT_REGULAR, 12, label_x, mid, u32(t.text_dim), label)
    end
    clicked && run_command!(app, "ui.command_search")
    return nothing
end
