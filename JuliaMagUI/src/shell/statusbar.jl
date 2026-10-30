# The status bar: the current database on the left; selected lines, jobs, the worker's
# busy text and the render mode on the right.

plural(n::Integer, word::AbstractString) = string(n, " ", word, n == 1 ? "" : "s")

"""
    StatusTexts

What the status bar shows: `database` ("Survey: 60 lines, 24 channels" or "No database"),
`selected` ("Selected lines: 12 of 60", or `""` without a database), the number of
`running` jobs, the worker's `busy` text (or `nothing`) and whether the renderer is
`software`.
"""
struct StatusTexts
    database::String
    selected::String
    running::Int
    busy::Union{Nothing,String}
    software::Bool
end

"""
    status_texts(app) -> StatusTexts

The status bar texts, from the snapshot, the live job status and the window.
"""
function status_texts(app)::StatusTexts
    snap = app.snap
    w = app.window
    software = w !== nothing && software_renderer(w.renderer)
    v = snap === nothing ? nothing : get(snap.databases, app.ui.current_db, nothing)
    running = snap === nothing ? 0 : count(j -> Core.status(j.job) == Core.JOB_RUNNING, snap.jobs)
    if v === nothing
        return StatusTexts("No database", "", running, app.busy, software)
    end
    i = findfirst(it -> it.id == v.id, snap.items)
    name = i === nothing ? v.id : snap.items[i].name
    isempty(v.error) ||
        return StatusTexts(name * ": it cannot be read", "", running, app.busy, software)
    n = length(v.lines)
    database = string(name, ": ", plural(n, "line"), ", ", plural(length(v.channels), "channel"))
    selected = string("Selected lines: ", count(l -> l.selected, v.lines), " of ", n)
    return StatusTexts(database, selected, running, app.busy, software)
end

jobs_text(running::Integer) = running == 0 ? "No jobs running" :
    string(running, running == 1 ? " job" : " jobs", " running")

"""
    draw_status_bar(app, dl, b)

Draw the status bar in box `b`, as the prototype's `#status`: 26 high, `status_bar` fill,
a 1 px `border` line on top, padding 10, 10 px between the items, text 11.5 `text_dim`,
1 by 14 separators in `border_strong`. A click on the jobs text opens the Jobs tab.
"""
function draw_status_bar(app, dl, b::Box)
    w = app.window::Window
    s = w.scale
    t = app.tokens
    p(v) = px(s, v)
    hl = hairline(s)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.status_bar))
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y0 + hl), u32(t.border))
    mid = (b.y0 + hl + b.y1) / 2
    texts = status_texts(app)
    dim = u32(t.text_dim)
    sep(x) = ig.AddRectFilled(dl, (x, round(mid - p(7))), (x + hl, round(mid - p(7)) + p(14)),
        u32(t.border_strong))
    ig.PushID("status")

    x = b.x0 + p(10)
    x += draw_text_mid(dl, FONT_REGULAR, 11.5, x, mid, dim, texts.database) + p(10)
    sep(x)
    left_end = x + hl

    # The right side, from the right edge leftwards.
    x = b.x1 - p(10)
    mode = texts.software ? "Software" : "GPU"
    mw = text_width(FONT_MONO, 11, mode)
    x -= mw
    draw_text_mid(dl, FONT_MONO, 11, x, mid, u32(texts.software ? t.amber : t.accent_text), mode)
    hit("Render Mode", Box(x, b.y0, x + mw, b.y1))
    ig.IsItemHovered() && item_tip!(app, "Map rendering";
        help = texts.software ? "Software rendering: the graphics card is not used." :
               "The graphics card draws the maps.")
    if texts.busy !== nothing
        x -= p(10) + hl
        sep(x)
        bw = text_width(FONT_REGULAR, 11.5, texts.busy)
        x -= p(10) + bw
        draw_text_mid(dl, FONT_REGULAR, 11.5, x, mid, dim, texts.busy)
    end
    x -= p(10) + hl
    sep(x)
    jt = jobs_text(texts.running)
    jw = text_width(FONT_REGULAR, 11.5, jt)
    spin = texts.running > 0 ? p(12 + 6) : 0f0
    x -= p(10) + jw + spin
    jobs = Box(x, b.y0 + hl, x + spin + jw, b.y1)
    clicked, hovered, _ = hit("Jobs", jobs)
    if texts.running > 0
        draw_spinner(app, dl, x + p(6), mid)
        request_frames!(w, 0.05)
    end
    jcol = texts.running > 0 ? t.accent_text : hovered ? t.text : t.text_dim
    draw_text_mid(dl, FONT_REGULAR, 11.5, x + spin, mid, u32(jcol), jt)
    hovered && ig.AddRectFilled(dl, (x + spin, round(mid + p(6))), (x + spin + jw, round(mid + p(6)) + hl),
        u32(jcol))
    clicked && (app.ui.left_tab = :jobs)
    hovered && item_tip!(app, "Jobs"; help = "Click to show the Jobs pane.")
    if !isempty(texts.selected)
        x -= p(10) + hl
        sep(x)
        sw = text_width(FONT_REGULAR, 11.5, texts.selected)
        x -= p(10) + sw
        x > left_end + p(10) && draw_text_mid(dl, FONT_REGULAR, 11.5, x, mid, dim, texts.selected)
    end
    ig.PopID()
    return nothing
end

# A 12 px spinner centred at (x, y): a faint accent ring with a turning accent arc.
function draw_spinner(app, dl, x::Real, y::Real)
    s = app.window.scale
    t = app.tokens
    r = px(s, 5)
    th = px(s, 2)
    # ImGui strokes closed shapes inside their outline; this ring, like the arc, is
    # stroked on its centre line: from radius 4 to 6, as the CSS 2 px border of a 12 px box.
    ig.AddCircle(dl, (x, y), r, u32(t.accent, 0.3), 24, th, Int(lib.ImDrawFlags_StrokeCenter))
    a = 2π * mod(time(), 0.9) / 0.9 - 3π / 4
    ig.PathArcTo(dl, (x, y), r, a, a + π / 2, 8)
    ig.PathStroke(dl, u32(t.accent), th)
    return nothing
end
