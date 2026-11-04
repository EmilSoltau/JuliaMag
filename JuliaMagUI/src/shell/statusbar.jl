# The status bar: the current database on the left, or while a map is shown its coordinate
# system, the pointer and the readout; selected lines, jobs, the worker's busy text and the
# render mode on the right.

plural(n::Integer, word::AbstractString) = string(n, " ", word, n == 1 ? "" : "s")

"""
    StatusTexts

What the status bar shows: `database` ("Survey: 60 lines, 24 channels" or "No database"),
`selected` ("Selected lines: 12 of 60", or `""` without a database), the number of
`running` jobs, the worker's `busy` text (or `nothing`), and the `render` item ("GPU",
"Software" or "CPU map", see `render_item`) with its tooltip `render_help`.
"""
struct StatusTexts
    database::String
    selected::String
    running::Int
    busy::Union{Nothing,String}
    render::String
    render_help::String
end

"""
    status_texts(app) -> StatusTexts

The status bar texts, from the snapshot, the live job status, the window and the map
renderer: the mode the next map frame draws in (`choose_mode`).
"""
function status_texts(app)::StatusTexts
    snap = app.snap
    w = app.window
    software = w !== nothing && software_renderer(w.renderer)
    r = app.map.renderer
    render, help = render_item(software, choose_mode(app.config.map_drawing, r.gl_problem), r.gl_problem)
    v = snap === nothing ? nothing : get(snap.databases, app.ui.current_db, nothing)
    running = running_jobs(snap)
    if v === nothing
        return StatusTexts("No database", "", running, app.busy, render, help)
    end
    i = findfirst(it -> it.id == v.id, snap.items)
    name = i === nothing ? v.id : snap.items[i].name
    isempty(v.error) ||
        return StatusTexts(name * ": it cannot be read", "", running, app.busy, render, help)
    n = length(v.lines)
    database = string(name, ": ", plural(n, "line"), ", ", plural(length(v.channels), "channel"))
    selected = string("Selected lines: ", count(l -> l.selected, v.lines), " of ", n)
    return StatusTexts(database, selected, running, app.busy, render, help)
end

jobs_text(running::Integer) = running == 0 ? "No jobs running" :
    string(running, running == 1 ? " job" : " jobs", " running")

"""
    StatusLayout

Where the status bar parts go, in device pixels: the `left` text (cut short with "..."
when it would reach the right side), the left edge `x` of each right item (`nothing`
when it is not shown), the separators' `seps`, the spinner and text widths of the jobs
item, and `right_x`, where the right side starts. While a map is shown, `left` is its
coordinate system (`left_w` wide), then the pointer text at `pointer_x` (`pointer_w` wide;
`nothing` when it is not shown) and the readout's `parts` at `part_x`, a separator before each.
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
    left_w::Float32
    pointer_x::Union{Nothing,Float32}
    pointer_w::Float32
    parts::Vector{String}
    part_x::Vector{Float32}
end

"""
    status_layout(b, scale, measure, texts; on_map = nothing, parts = String[]) -> StatusLayout

Lay out the status bar in box `b`, as the prototype's `#status`: padding 10, 10 px
between the items and around the 1 px separators. The right side is laid out from the
right edge; the left text gets the room that is left, at least 10 px from the right side.
With the texts of a shown map (`map_status`) and its readout's `parts`, the left side is its
coordinate system, a separator, the pointer in mono, and each part after a separator. When
the room runs out, the readout's parts go first (the last one that fits is cut short), then
the pointer; then the coordinate system is cut short. Nothing reaches the right side.
`measure(role, size, text)` is the text width in device pixels.
"""
function status_layout(b::Box, scale::Real, measure, texts::StatusTexts;
        on_map::Union{Nothing,NTuple{3,String}} = nothing, parts::Vector{String} = String[])::StatusLayout
    p(v) = px(scale, v)
    hl = hairline(scale)
    seps = Float32[]
    x = b.x1 - p(10)
    x -= measure(FONT_MONO, 11, texts.render)
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
    x0 = b.x0 + p(10)
    room = max(0f0, x - p(10) - x0)   # the left side ends 10 px before the right side
    x1 = x0 + room
    shown, shown_x = String[], Float32[]
    if on_map === nothing
        left = elide(measure, texts.database, room; role = FONT_REGULAR, size = 11.5)
        return StatusLayout(left, mode_x, busy_x, jobs_x, spin, jobs_w, selected_x, seps, x,
            measure(FONT_REGULAR, 11.5, left), nothing, 0f0, shown, shown_x)
    end
    crs, pointer, _ = on_map
    crs_w = measure(FONT_REGULAR, 11.5, crs)
    pointer_w = measure(FONT_MONO, 11.5, pointer)
    if crs_w + p(10) + hl + p(10) + pointer_w > room   # no room for the pointer
        left = elide(measure, crs, room; role = FONT_REGULAR, size = 11.5)
        return StatusLayout(left, mode_x, busy_x, jobs_x, spin, jobs_w, selected_x, seps, x,
            measure(FONT_REGULAR, 11.5, left), nothing, 0f0, shown, shown_x)
    end
    sep = rnd(x0 + crs_w + p(10))
    push!(seps, sep)
    pointer_x = sep + hl + p(10)
    at = pointer_x + pointer_w   # where the last item ends
    for part in parts
        sep = rnd(at + p(10))
        start = sep + hl + p(10)
        text = elide(measure, part, x1 - start; role = FONT_REGULAR, size = 11.5)
        isempty(text) && break
        push!(seps, sep)
        push!(shown, text)
        push!(shown_x, start)
        text === part || break   # cut short: nothing fits after it
        at = start + measure(FONT_REGULAR, 11.5, text)
    end
    return StatusLayout(crs, mode_x, busy_x, jobs_x, spin, jobs_w, selected_x, seps, x,
        crs_w, pointer_x, pointer_w, shown, shown_x)
end

"""
    StatusCache

The status bar's texts (`texts`, see `status_texts`) and the snapshot, current database,
running jobs, busy text and render inputs they were made from; and its `layout` and the
box `box`, scale and texts (`shown`, `on_map`) it was laid out for. A steady frame makes neither again, so it
allocates nothing.
"""
mutable struct StatusCache
    snap::Any
    db::String
    running::Int
    busy::Union{Nothing,String}
    software::Bool
    mode::MapMode
    problem::String
    texts::Union{Nothing,StatusTexts}
    box::Box
    scale::Float32
    shown::Union{Nothing,StatusTexts}
    on_map::Union{Nothing,NTuple{3,String}}
    layout::Union{Nothing,StatusLayout}
end

StatusCache() = StatusCache(nothing, "", 0, nothing, false, MAP_GL, "", nothing, Box(0, 0, 0, 0), 0f0,
                            nothing, nothing, nothing)

"""
    status_view(app, b) -> StatusCache

The status bar's texts (`shown`), the shown map's texts (`on_map`: `map_status`, or `nothing`
while no map is shown) and their `layout` in box `b`, in `app.ui.status_cache`. Each is made
again only when what it is made from changed.
"""
function status_view(app, b::Box)::StatusCache
    c = app.ui.status_cache
    c isa StatusCache || (c = app.ui.status_cache = StatusCache())
    snap = app.snap
    w = app.window
    software = w !== nothing && software_renderer(w.renderer)
    r = app.map.renderer
    mode = choose_mode(app.config.map_drawing, r.gl_problem)
    running = running_jobs(snap)
    if c.texts === nothing || c.snap !== snap || c.db != app.ui.current_db || c.running != running ||
            c.busy !== app.busy || c.software != software || c.mode != mode || c.problem !== r.gl_problem
        c.texts = status_texts(app)
        c.snap, c.db, c.running, c.busy = snap, app.ui.current_db, running, app.busy
        c.software, c.mode, c.problem = software, mode, r.gl_problem
    end
    texts = c.texts::StatusTexts
    scale = w === nothing ? 1f0 : Float32(w.scale)
    same = c.layout !== nothing && c.box == b && c.scale == scale && c.shown === texts
    # The map's texts compared as a concrete tuple: a `Union` of them would be boxed.
    if snap !== nothing && haskey(snap.maps, app.ui.current_map)
        m = map_status(app)
        prev = c.on_map
        if !(same && prev isa NTuple{3,String} && prev === m)
            c.layout = status_layout(b, scale, text_width, texts; on_map = m, parts = app.ui.map_status.parts)
            c.box, c.scale, c.shown, c.on_map = b, scale, texts, m
        end
    elseif !(same && c.on_map === nothing)
        c.layout = status_layout(b, scale, text_width, texts)
        c.box, c.scale, c.shown, c.on_map = b, scale, texts, nothing
    end
    return c
end

"""
    draw_status_bar(app, dl, b)

Draw the status bar in box `b` (see `status_layout`): 26 high, `status_bar` fill, a 1 px
`border` line on top, text 11.5 `text_dim`, 1 by 14 separators in `border_strong`.
While a map is shown: its coordinate system, the pointer in mono 11.5 and the readout's
parts in `text`, each after a separator. A click on the jobs text opens the Jobs tab.
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
    c = status_view(app, b)
    texts = c.shown::StatusTexts
    on_map = c.on_map
    l = c.layout::StatusLayout
    dim = u32(t.text_dim)
    for x in l.seps
        ig.AddRectFilled(dl, (x, round(mid - p(7))), (x + hl, round(mid - p(7)) + p(14)),
            u32(t.border_strong))
    end
    ig.PushID("status")
    x0 = b.x0 + p(10)
    draw_text_mid(dl, FONT_REGULAR, 11.5, x0, mid, dim, l.left)
    if on_map !== nothing
        hit("Coordinate System", Box(x0, b.y0 + hl, x0 + l.left_w, b.y1))
        ig.IsItemHovered() && item_tip!(app, "Map coordinate system"; help = "The coordinate system the map is drawn in.")
        pointer_x = l.pointer_x
        if pointer_x !== nothing
            draw_text_mid(dl, FONT_MONO, 11.5, pointer_x, mid, dim, on_map[2])
            hit("Pointer", Box(pointer_x, b.y0 + hl, pointer_x + l.pointer_w, b.y1))
            ig.IsItemHovered() && item_tip!(app, "Pointer position"; help = "X and Y of the pointer in the map's coordinate system.")
        end
        for (k, part) in enumerate(l.parts)
            draw_text_mid(dl, FONT_REGULAR, 11.5, l.part_x[k], mid, u32(t.text), part)
        end
    end

    # "GPU" in `accent_text`; "Software" and "CPU map" in `amber`.
    mw = draw_text_mid(dl, FONT_MONO, 11, l.mode_x, mid,
        u32(texts.render == "GPU" ? t.accent_text : t.amber), texts.render)
    hit("Render Mode", Box(l.mode_x, b.y0, l.mode_x + mw, b.y1))
    ig.IsItemHovered() && item_tip!(app, "Map rendering"; help = texts.render_help)
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
