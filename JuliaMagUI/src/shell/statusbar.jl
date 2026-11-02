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
    running = running_jobs(snap)
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
    StatusLayout

Where the status bar parts go, in device pixels: the `left` text (cut short with "..."
when it would reach the right side), the left edge `x` of each right item (`nothing`
when it is not shown), the separators' `seps`, the spinner and text widths of the jobs
item, and `right_x`, where the right side starts.
"""
struct StatusLayout
    left::String
    mode_x::Float32
    busy_x::Union{Nothing,Float32}
    jobs_x::Float32
    spin::Float32
    jobs_w::Float32
    selected_x::Union{Nothing,Float32}
    seps::Vector{Float32}
    right_x::Float32
end

"""
    status_layout(b, scale, measure, texts) -> StatusLayout

Lay out the status bar in box `b`, as the prototype's `#status`: padding 10, 10 px
between the items and around the 1 px separators. The right side is laid out from the
right edge; the left text gets the room that is left, at least 10 px from the right side.
`measure(role, size, text)` is the text width in device pixels.
"""
function status_layout(b::Box, scale::Real, measure, texts::StatusTexts)::StatusLayout
    p(v) = px(scale, v)
    hl = hairline(scale)
    seps = Float32[]
    x = b.x1 - p(10)
    mode = texts.software ? "Software" : "GPU"
    x -= measure(FONT_MONO, 11, mode)
    mode_x = x
    busy_x = nothing
    if texts.busy !== nothing
        x -= p(10) + hl
        push!(seps, x)
        x -= p(10) + measure(FONT_REGULAR, 11.5, texts.busy)
        busy_x = x
    end
    x -= p(10) + hl
    push!(seps, x)
    jobs_w = measure(FONT_REGULAR, 11.5, jobs_text(texts.running))
    spin = texts.running > 0 ? p(12 + 6) : 0f0
    x -= p(10) + jobs_w + spin
    jobs_x = x
    selected_x = nothing
    if !isempty(texts.selected)
        x -= p(10) + hl
        push!(seps, x)
        x -= p(10) + measure(FONT_REGULAR, 11.5, texts.selected)
        selected_x = x
    end
    room = x - p(10) - (b.x0 + p(10))
    left = elide(measure, texts.database, room; role = FONT_REGULAR, size = 11.5)
    return StatusLayout(left, mode_x, busy_x, jobs_x, spin, jobs_w, selected_x, seps, x)
end

"""
    draw_status_bar(app, dl, b)

Draw the status bar in box `b` (see `status_layout`): 26 high, `status_bar` fill, a 1 px
`border` line on top, text 11.5 `text_dim`, 1 by 14 separators in `border_strong`.
A click on the jobs text opens the Jobs tab.
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
    l = status_layout(b, s, text_width, texts)
    dim = u32(t.text_dim)
    for x in l.seps
        ig.AddRectFilled(dl, (x, round(mid - p(7))), (x + hl, round(mid - p(7)) + p(14)),
            u32(t.border_strong))
    end
    ig.PushID("status")
    draw_text_mid(dl, FONT_REGULAR, 11.5, b.x0 + p(10), mid, dim, l.left)

    mode = texts.software ? "Software" : "GPU"
    mw = draw_text_mid(dl, FONT_MONO, 11, l.mode_x, mid,
        u32(texts.software ? t.amber : t.accent_text), mode)
    hit("Render Mode", Box(l.mode_x, b.y0, l.mode_x + mw, b.y1))
    ig.IsItemHovered() && item_tip!(app, "Map rendering";
        help = texts.software ? "Software rendering: the graphics card is not used." :
               "The graphics card draws the maps.")
    busy = texts.busy
    (l.busy_x === nothing || busy === nothing) ||
        draw_text_mid(dl, FONT_REGULAR, 11.5, l.busy_x, mid, dim, busy)

    x = l.jobs_x
    jt = jobs_text(texts.running)
    clicked, hovered, _ = hit("Jobs", Box(x, b.y0 + hl, x + l.spin + l.jobs_w, b.y1))
    if texts.running > 0
        draw_spinner(app, dl, x + p(6), mid)
        request_frames!(w, 0.05)
    end
    jcol = texts.running > 0 ? t.accent_text : hovered ? t.text : t.text_dim
    draw_text_mid(dl, FONT_REGULAR, 11.5, x + l.spin, mid, u32(jcol), jt)
    hovered && ig.AddRectFilled(dl, (x + l.spin, round(mid + p(6))),
        (x + l.spin + l.jobs_w, round(mid + p(6)) + hl), u32(jcol))
    clicked && (app.ui.left_tab = :jobs)
    hovered && item_tip!(app, "Jobs"; help = "Click to show the Jobs pane.")
    l.selected_x === nothing || draw_text_mid(dl, FONT_REGULAR, 11.5, l.selected_x, mid, dim, texts.selected)
    ig.PopID()
    return nothing
end

# A 12 px spinner centred at (x, y): a faint ring with a turning arc, in `col`.
function draw_spinner(app, dl, x::Real, y::Real; col::NTuple{4,Float32} = app.tokens.accent)
    s = app.window.scale
    r = px(s, 5)
    th = px(s, 2)
    # ImGui strokes closed shapes inside their outline; this ring, like the arc, is
    # stroked on its centre line: from radius 4 to 6, as the CSS 2 px border of a 12 px box.
    ig.AddCircle(dl, (x, y), r, u32(col, 0.3), 24, th, Int(lib.ImDrawFlags_StrokeCenter))
    a = 2π * mod(time(), 0.9) / 0.9 - 3π / 4
    ig.PathArcTo(dl, (x, y), r, a, a + π / 2, 8)
    ig.PathStroke(dl, u32(col), th)
    return nothing
end
