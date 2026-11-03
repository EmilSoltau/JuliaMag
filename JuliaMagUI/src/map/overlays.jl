# What the map view draws over the map image with the ImDrawList: the coordinate ticks, the
# nav buttons, the scale bar, the legends, the line labels, the box of a box zoom and the
# hint, as the prototype's `.mapnav`, `.scalebar`, `.legends` and `.maphint`. Device pixels;
# sizes in logical pixels through `px`; colours from the tokens.

const BAND = 20          # the coordinate bands along the top and left edges
const TICK = 6           # tick length
const TICK_GAP = 90      # the least space between ticks
const EDGE = 10          # overlays sit this far in from the edges (and the bands)
const NAV_SIZE = 26
const NAV_GAP = 4
const SCALE_TARGET = 130 # the scale bar's longest length
const LEGEND_W = 228
const RAMP_W = 210
const OVERLAY_ALPHA = 0.88   # the bands and the scale bar
const CARD_ALPHA = 0.92      # the legends and the hint

const EMPTY_MAP_LINES = ["This map has no layers.", "Show a database or grid on it from the Data tab."]

"""
    draw_overlays(app, dl, b, mv, st)

Draw the overlays of map view `mv` in box `b`: with a camera, the line labels, the box of a box
zoom, the coordinate bands, the scale bar, the legends (while Colour Bars is on) and the nav
buttons; and always the hint.
"""
function draw_overlays(app, dl, b::Box, mv, st::MapViewState)
    cam = st.camera
    if cam !== nothing
        draw_line_labels(app, dl, b, cam)
        draw_zoom_box(app, dl, b, st)
        draw_coordinate_bands(app, dl, b, cam)
        draw_scale_bar(app, dl, b, mv, cam)
        app.ui.colour_bars && draw_legends(app, dl, b, mv)
        draw_nav_buttons(app, b, mv, st)
    end
    draw_map_hint(app, dl, b, mv, st)
    return nothing
end

# The part of `b` inside the coordinate bands.
inner_box(b::Box, s::Real) = Box(b.x0 + px(s, BAND), b.y0 + px(s, BAND), b.x1, b.y1)

"The empty map: two lines in `text_dim`, centred, 1.6 times the font size apart, as `.empty`."
function draw_empty_map(app, dl, b::Box)
    s = app.window.scale
    line_h = px(s, BODY_FONT_SIZE * 1.6)
    cx = (b.x0 + b.x1) / 2
    y = round((b.y0 + b.y1 - line_h * length(EMPTY_MAP_LINES)) / 2)
    for line in EMPTY_MAP_LINES
        lw = text_width(FONT_REGULAR, BODY_FONT_SIZE, line)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, cx - lw / 2, y + line_h / 2, u32(app.tokens.text_dim), line;
            line = 1.6)
        y += line_h
    end
    return nothing
end

# --- Coordinate bands ---

"""
    draw_coordinate_bands(app, dl, b, cam)

X along the top edge and Y along the left edge: a `ribbon` band at $(OVERLAY_ALPHA) alpha with a
1 px `border` on its inner side, ticks $(TICK) px long at its inner side at `tick_values!`
spaced at least $(TICK_GAP) px, and labels (`coord_text`) in 10.5 `text_dim`, the Y labels
turned to read upwards.
"""
function draw_coordinate_bands(app, dl, b::Box, cam::Camera)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    band, tick = px(s, BAND), px(s, TICK)
    w, h = width(b), height(b)
    ix, iy = b.x0 + band, b.y0 + band
    fill = u32(t.ribbon, OVERLAY_ALPHA)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, iy), fill)
    ig.AddRectFilled(dl, (b.x0, iy), (ix, b.y1), fill)
    ig.AddRectFilled(dl, (ix - hl, iy - hl), (b.x1, iy), u32(t.border))
    ig.AddRectFilled(dl, (ix - hl, iy), (ix, b.y1), u32(t.border))
    ticks = Float64[]
    col = u32(t.text_dim)
    gap = px(s, TICK_GAP)
    label_mid = b.y0 + (band - tick) / 2   # the labels sit in the band outside the ticks
    # X along the top.
    lo = screen_to_world(cam, w, h, band, 0)[1]
    hi = screen_to_world(cam, w, h, w, 0)[1]
    step = tick_values!(ticks, lo, hi, gap, cam.res)
    for v in ticks
        x = rnd(b.x0 + world_to_screen(cam, w, h, v, 0.0)[1])
        text = coord_text(v, step)
        tw = text_width(FONT_REGULAR, 10.5, text)
        x0 = x - tw / 2
        (x0 >= ix && x0 + tw <= b.x1) || continue   # a tick only with its label
        ig.AddRectFilled(dl, (x, iy - hl - tick), (x + hl, iy - hl), col)
        draw_text_mid(dl, FONT_REGULAR, 10.5, x0, label_mid, col, text)
    end
    # Y along the left, read upwards.
    lo = screen_to_world(cam, w, h, 0, h)[2]
    hi = screen_to_world(cam, w, h, 0, band)[2]
    step = tick_values!(ticks, lo, hi, gap, cam.res)
    for v in ticks
        y = rnd(b.y0 + world_to_screen(cam, w, h, 0.0, v)[2])
        text = coord_text(v, step)
        tw = text_width(FONT_REGULAR, 10.5, text)
        (y - tw / 2 >= iy && y + tw / 2 <= b.y1) || continue   # a tick only with its label
        ig.AddRectFilled(dl, (ix - hl - tick, y), (ix - hl, y + hl), col)
        # Drawn inside the view, where the clip rectangle keeps every glyph, then turned into the band.
        x0 = rnd(ix + px(s, 1))
        first = vertex_count(dl)
        draw_text_mid(dl, FONT_REGULAR, 10.5, x0, y, col, text)
        turn_since!(dl, first, (x0 + tw / 2, y), (rnd(b.x0 + (band - tick) / 2), y))
    end
    return nothing
end

# Turn the vertices added to `dl` since `first` a quarter turn about `from` and move them so
# that `from` lands on `to`: text that read to the right reads upwards.
function turn_since!(dl, first::Int, from::NTuple{2,Real}, to::NTuple{2,Real})
    buf = unsafe_load(dl.VtxBuffer)
    data = Ptr{ig.lib.ImDrawVert}(buf.Data)
    fx, fy, tx, ty = Float32(from[1]), Float32(from[2]), Float32(to[1]), Float32(to[2])
    for i in first+1:Int(buf.Size)
        v = unsafe_load(data, i)
        pos = ig.ImVec2(tx + (v.pos.y - fy), ty - (v.pos.x - fx))
        unsafe_store!(data, ig.lib.ImDrawVert(pos, v.uv, v.col), i)
    end
    return nothing
end

# --- Scale bar ---

"""
    draw_scale_bar(app, dl, b, mv, cam)

The prototype's `.scalebar` at the bottom left, $(EDGE) px in: on `ribbon` at $(OVERLAY_ALPHA) alpha with
a 1 px `border`, radius 5, padding 4 8 3; the length (`scale_bar`, at most $(SCALE_TARGET) px) in 11
`text`, 2 px above the bar: 6 px high, a 1.5 px `text` line on its left, right and bottom.
"""
function draw_scale_bar(app, dl, b::Box, mv, cam::Camera)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    info = get(app.snap.crs, mv.crs, nothing)
    sb = scale_bar(cam.res, px(s, SCALE_TARGET), info === nothing ? "" : info.unit)
    bar_w = round(Float32(sb.px))
    tw = text_width(FONT_REGULAR, 11, sb.label)
    bottom = b.y1 - f(EDGE)
    left = inner_box(b, s).x0 + f(EDGE)
    # As a browser lays it out: borders in whole device pixels, the parts at fractions of a
    # pixel from the box's own (unrounded) top, each part's edges rounded.
    box = Box(left, bottom - 2hl - f(4 + 13.75 + 2 + 6 + 3), left + max(tw, bar_w) + 2hl + f(16), bottom)
    frame = snap(box)
    ig.AddRectFilled(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.ribbon, OVERLAY_ALPHA), f(5))
    ig.AddRect(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.border), f(5), hl)
    draw_text_mid(dl, FONT_REGULAR, 11, box.x0 + hl + f(8), box.y0 + hl + f(4) + f(13.75) / 2, u32(t.text), sb.label)
    bt = max(1f0, floor(f(1.5)))   # a browser draws a 1.5 px border in whole device pixels
    bx = rnd(box.x0 + hl + f(8))
    by = rnd(box.y0 + hl + f(4 + 13.75 + 2))
    by1 = rnd(box.y0 + hl + f(4 + 13.75 + 2 + 6))
    col = u32(t.text)
    ig.AddRectFilled(dl, (bx, by), (bx + bt, by1), col)
    ig.AddRectFilled(dl, (bx + bar_w - bt, by), (bx + bar_w, by1), col)
    ig.AddRectFilled(dl, (bx, by1 - bt), (bx + bar_w, by1), col)
    return nothing
end

# --- Nav buttons ---

const NAV_BUTTONS = (("zoom_in", "zoomIn", "Zoom In"), ("zoom_out", "zoomOut", "Zoom Out"),
    ("full_extent", "fullExtent", "Full Extent"), ("go_cursor", "crosshair", "Go To Cursor"))

const NOT_ON_MAP_TEXT = "The current point is not on this map."

"""
    draw_nav_buttons(app, b, mv, st)

The prototype's `.mapnav`: at the top right, $(EDGE) px in, a column of $(NAV_SIZE) by $(NAV_SIZE)
buttons $(NAV_GAP) px apart: `ribbon` with a 1 px `border`, radius 5 and a shadow, `hover` under
the mouse, a 16 px icon. Zoom In and Zoom Out zoom by $(ZOOM_STEP) about the centre, Full
Extent fits all layers, Go To Cursor centres the shared cursor.
"""
function draw_nav_buttons(app, b::Box, mv, st::MapViewState)
    s = app.window.scale
    t = app.tokens
    dl = ig.GetWindowDrawList()
    hl = hairline(s)
    size, gap = px(s, NAV_SIZE), px(s, NAV_GAP)
    x1 = b.x1 - px(s, EDGE)
    y = inner_box(b, s).y0 + px(s, EDGE)
    vw, vh = round(Int, width(b)), round(Int, height(b))
    ig.PushID("mapnav")
    for (id, icon, title) in NAV_BUTTONS
        nb = Box(x1 - size, y, x1, y + size)
        target = id == "go_cursor" ? cursor_target(app, mv) : nothing
        enabled = id != "go_cursor" || target !== nothing
        clicked, hovered, held = hit(id, nb)
        draw_shadow(dl, nb, px(s, 5), px(s, 1), px(s, 2), t.shadow)
        fill = enabled && hovered ? (held ? t.pressed : t.hover) : t.ribbon
        ig.AddRectFilled(dl, (nb.x0, nb.y0), (nb.x1, nb.y1), u32(fill), px(s, 5))
        ig.AddRect(dl, (nb.x0, nb.y0), (nb.x1, nb.y1), u32(t.border), px(s, 5), hl)
        d = px(s, 16)
        draw_icon(dl, icon, (nb.x0 + (size - d) / 2, nb.y0 + (size - d) / 2), 16; style = enabled ? :normal : :disabled)
        item_tip!(app, title; reason = enabled ? nothing : NOT_ON_MAP_TEXT)
        hovered && request_frames!(app.window::Window)
        if clicked && enabled
            if id == "zoom_in"
                zoom_by!(st, ZOOM_STEP)
            elseif id == "zoom_out"
                zoom_by!(st, 1 / ZOOM_STEP)
            elseif id == "full_extent"
                ext = map_extent(app, mv)
                ext === nothing || full_extent!(st, ext, vw, vh; inset = px(s, BAND))
            elseif target !== nothing
                go_to!(st, target)
            end
        end
        y += size + gap
    end
    ig.PopID()
    return nothing
end

"""
    cursor_target(app, mv) -> Union{Nothing,NTuple{2,Float64}}

The world position of the shared cursor when its database is a loaded line layer of the map
and its row is a good point; else `nothing`.
"""
function cursor_target(app, mv)::Union{Nothing,NTuple{2,Float64}}
    c = app.snap.cursor
    c === nothing && return nothing
    for p in app.map.plan
        e = p.entry
        (p.layer.item == c.item && p.layer.kind == :lines && e !== nothing) || continue
        d = e.data
        d isa LineLayerData || continue
        k = findfirst(==(c.line), d.points.lines)
        k === nothing && continue
        pt = cursor_point(d, k, c.row)
        pt === nothing || return pt
    end
    return nothing
end

"Centre the view on world point `p`. Records one extent."
function go_to!(st::MapViewState, p::NTuple{2,Float64})
    cam = st.camera
    cam === nothing && return nothing
    record_command!(st)
    st.camera = Camera(p[1], p[2], cam.res)
    return nothing
end

# --- Legends ---

"""
    draw_legends(app, dl, b, mv)

The prototype's `.legends` at the bottom right, $(EDGE) px in: one $(LEGEND_W) px card per coloured
visible layer with data (a grid, or lines with a colour channel), $(6) px apart, the top layer on top.
A card is `ribbon` at $(CARD_ALPHA) alpha with a 1 px `border`, radius 6, padding 6 8 5: the layer's
name (and channel) in semibold 11 with its units and stretch in `text_dim` at the right, the
colour table in a $(RAMP_W) by 10 strip with a 1 px `border_strong`, and its low, middle and high
values in 10.5 `text_dim`. A layer with no values says "No values".
"""
function draw_legends(app, dl, b::Box, mv)
    s = app.window.scale
    f(v) = fpx(s, v)
    bottom = b.y1 - f(EDGE)
    x1 = b.x1 - f(EDGE)
    for p in app.map.plan
        legend = legend_of(app, p)
        legend === nothing && continue
        title, units, d = legend
        empty = d.hist.total == 0
        h = 2hairline(s) + f(6 + 13.75 + 4 + (empty ? 13 : 10 + 2 + 13) + 5)
        card = Box(x1 - f(LEGEND_W), bottom - h, x1, bottom)
        draw_legend(app, dl, card, p, title, units, d)
        bottom -= h + f(6)
    end
    return nothing
end

# The title, the units text and the data of a coloured layer's legend, or `nothing`.
function legend_of(app, p)
    e = p.entry
    (e === nothing || e.data === nothing) && return nothing
    d = e.data
    isempty(d.levels) && return nothing
    snap = app.snap
    k = findfirst(it -> it.id == p.layer.item, snap.items)
    name = k === nothing ? p.layer.item : snap.items[k].name
    units = ""
    if p.layer.kind == :lines
        isempty(p.layer.channel) && return nothing
        name = string(name, ": ", p.layer.channel)
        v = get(snap.databases, p.layer.item, nothing)
        if v !== nothing
            c = findfirst(ch -> ch.name == p.layer.channel, v.channels)
            c === nothing || (units = v.channels[c].units)
        end
    else
        g = get(snap.grids, p.layer.item, nothing)
        g === nothing || (units = g.units)
    end
    p.style.stretch === :histeq && (units = isempty(units) ? "hist. eq." : units * ", hist. eq.")
    return name, units, d
end

# One legend card in the unrounded box `card`, laid out as `draw_scale_bar` lays out its box.
function draw_legend(app, dl, card::Box, p, title::String, units::String, d)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    frame = snap(card)
    ig.AddRectFilled(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.ribbon, CARD_ALPHA), f(6))
    ig.AddRect(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.border), f(6), hl)
    x = card.x0 + hl + f(8)
    inner = f(RAMP_W)
    y = card.y0 + hl + f(6)
    mid = y + f(13.75) / 2
    uw = text_width(FONT_REGULAR, 11, units)
    gap = isempty(units) ? 0f0 : f(8)
    name = elide(text_width, title, inner - uw - gap; role = FONT_SEMIBOLD, size = 11)
    draw_text_mid(dl, FONT_SEMIBOLD, 11, x, mid, u32(t.text), name)
    draw_text_mid(dl, FONT_REGULAR, 11, x + inner - uw, mid, u32(t.text_dim), units)
    y += f(13.75 + 4)
    if d.hist.total == 0
        draw_text_mid(dl, FONT_REGULAR, 10.5, x, y + f(13) / 2, u32(t.text_dim), "No values")
        return nothing
    end
    ramp = snap(Box(x, y, x + inner, y + f(10)))
    draw_ramp(dl, Box(ramp.x0 + hl, ramp.y0 + hl, ramp.x1 - hl, ramp.y1 - hl), p.look.lut)
    ig.AddRect(dl, (ramp.x0, ramp.y0), (ramp.x1, ramp.y1), u32(t.border_strong), f(2), hl)
    lo, hi = Core.stretch_range(p.style, d.hist)
    middle = p.style.stretch === :histeq ? Core.quantile_value(d.hist, 0.5) : (lo + hi) / 2
    y += f(10 + 2)
    mid = y + f(13) / 2
    col = u32(t.text_dim)
    for (k, v) in enumerate((lo, middle, hi))
        text = legend_number(v)
        tw = text_width(FONT_REGULAR, 10.5, text)
        tx = k == 1 ? x : k == 2 ? x + inner / 2 - tw / 2 : x + inner - tw
        draw_text_mid(dl, FONT_REGULAR, 10.5, tx, mid, col, text)
    end
    return nothing
end

# A legend value as the prototype writes it: 2 decimals under 10, else none.
legend_number(v::Real)::String = fmt_num(v, abs(v) < 10 ? 2 : 0)

# The look-up table `lut` (RGBA bytes) across box `b`, one device pixel column at a time.
function draw_ramp(dl, b::Box, lut::Vector{UInt8})
    n = round(Int, width(b))
    (n > 0 && length(lut) >= 1024) || return nothing
    for i in 0:n-1
        k = n == 1 ? 0 : round(Int, i / (n - 1) * 255)
        c = UInt32(lut[4k+1]) | UInt32(lut[4k+2]) << 8 | UInt32(lut[4k+3]) << 16 | 0xff000000
        ig.AddRectFilled(dl, (b.x0 + i, b.y0), (b.x0 + i + 1, b.y1), c)
    end
    return nothing
end

# --- Line labels ---

"""
    draw_line_labels(app, dl, b, cam)

The name of each line at its first point, for the visible line layers with labels on: semibold
10.5 `text` with a `canvas` halo, 4 px before the line's start along its direction (left of a line
that runs to the right, under a line that runs up). A label that would overlap one already placed
is left out, and at most $(LABEL_LIMIT) are drawn.
"""
function draw_line_labels(app, dl, b::Box, cam::Camera)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    w, h = width(b), height(b)
    placed = Box[]
    lh = fpx(s, 10.5 * 1.25)
    g = px(s, 4)
    halo = ((-hl, 0f0), (hl, 0f0), (0f0, -hl), (0f0, hl), (-hl, -hl), (hl, hl), (-hl, hl), (hl, -hl))
    for p in app.map.plan
        e = p.entry
        (p.layer.kind == :lines && p.layer.labels && e !== nothing) || continue
        d = e.data
        d isa LineLayerData || continue
        look = line_labels!(p.look, d)
        for (k, (_, x, y)) in enumerate(look.label_points)
            length(placed) >= LABEL_LIMIT && return nothing
            sx, sy = world_to_screen(cam, w, h, x, y)
            (0 <= sx <= w && 0 <= sy <= h) || continue
            text = look.label_names[k]
            tw = text_width(FONT_SEMIBOLD, 10.5, text)
            dx, dy = look.label_dirs[k]
            if abs(dx) >= abs(dy)
                x0 = dx >= 0 ? sx - g - tw : sx + g
                mid = sy
            else
                x0 = sx - tw / 2
                mid = dy >= 0 ? sy + g + lh / 2 : sy - g - lh / 2
            end
            x0, mid = rnd(b.x0 + x0), b.y0 + mid
            lb = Box(x0 - hl, mid - lh / 2 - hl, x0 + tw + hl, mid + lh / 2 + hl)
            any(q -> overlaps(q, lb), placed) && continue
            push!(placed, lb)
            for (ox, oy) in halo
                draw_text_mid(dl, FONT_SEMIBOLD, 10.5, x0 + ox, mid + oy, u32(t.canvas), text)
            end
            draw_text_mid(dl, FONT_SEMIBOLD, 10.5, x0, mid, u32(t.text), text)
        end
    end
    return nothing
end

# The label points, names and directions (the last point less the first) of the lines of
# `d`, read again only for a new build of the data.
function line_labels!(look::LayerLook, d::LineLayerData)::LayerLook
    (look.label_data === d && look.label_version == d.version) && return look
    pts = d.points
    label_points!(look.label_points, d)
    empty!(look.label_names)
    for (li, _, _) in look.label_points
        push!(look.label_names, Core.line_name(pts.lines[li]))
    end
    # A line's parts follow each other, as `label_points!` reads them.
    resize!(look.label_dirs, length(look.label_points))
    j = 0
    last_line = 0
    for k in eachindex(pts.part_line)
        li = Int(pts.part_line[k])
        li == last_line || (j += 1; last_line = li)
        i = Int(pts.part_first[k]) + Int(pts.part_count[k])
        _, x0, y0 = look.label_points[j]
        look.label_dirs[j] = (pts.origin[1] + pts.x[i] - x0, pts.origin[2] + pts.y[i] - y0)
    end
    look.label_data = d
    look.label_version = d.version
    return look
end

# --- Box zoom and hint ---

"The box of a box zoom: `accent` at 12 % with a 1 px `accent` border."
function draw_zoom_box(app, dl, b::Box, st::MapViewState)
    z = st.box
    z === nothing && return nothing
    t = app.tokens
    r = snap(Box(b.x0 + min(z[1], z[3]), b.y0 + min(z[2], z[4]), b.x0 + max(z[1], z[3]), b.y0 + max(z[2], z[4])))
    ig.AddRectFilled(dl, (r.x0, r.y0), (r.x1, r.y1), u32(t.accent, 0.12))
    ig.AddRect(dl, (r.x0, r.y0), (r.x1, r.y1), u32(t.accent), 0, hairline(app.window.scale))
    return nothing
end

"""
    map_hint(app, mv) -> String

What the hint at the top left says: the map's own error, "Loading <name>..." while a visible
layer loads, the first layer error (or note); else `""`. Why the map draws on the CPU is in
the status bar.
"""
function map_hint(app, mv)::String
    isempty(mv.error) || return mv.error
    ms = app.map
    refresh_plan!(ms, app, mv)
    snap = app.snap
    for p in ms.plan
        e = p.entry
        if e === nothing || e.loading || (e.data === nothing && isempty(e.error))
            k = findfirst(it -> it.id == p.layer.item, snap.items)
            return string("Loading ", k === nothing ? p.layer.item : snap.items[k].name, "...")
        end
    end
    gl = ms.renderer.gl
    for p in ms.plan
        e = p.entry::LayerEntry
        isempty(e.error) || return e.error
        if gl !== nothing
            err = layer_error(gl, e.key)
            isempty(err) || return err
        end
    end
    return ""
end

"""
    draw_map_hint(app, dl, b, mv, st)

The prototype's `.maphint` at the top left, $(EDGE) px in: `ribbon` at $(CARD_ALPHA) alpha with a 1 px
`border`, radius 5, padding 3 8, the text of `map_hint` in 11 `text_dim`.
"""
function draw_map_hint(app, dl, b::Box, mv, st::MapViewState)
    text = map_hint(app, mv)
    isempty(text) && return nothing
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    inner = st.camera === nothing ? b : inner_box(b, s)   # inside the coordinate bands
    x0, y0 = inner.x0 + f(EDGE), inner.y0 + f(EDGE)
    room = b.x1 - f(EDGE) - x0 - 2hl - f(16)
    text = elide(text_width, text, room; size = 11)
    tw = text_width(FONT_REGULAR, 11, text)
    hb = Box(x0, y0, x0 + tw + 2hl + f(16), y0 + 2hl + f(3 + 13.75 + 3))
    frame = snap(hb)
    ig.AddRectFilled(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.ribbon, CARD_ALPHA), f(5))
    ig.AddRect(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.border), f(5), hl)
    draw_text_mid(dl, FONT_REGULAR, 11, hb.x0 + hl + f(8), hb.y0 + hl + f(3) + f(13.75) / 2, u32(t.text_dim), text)
    return nothing
end
