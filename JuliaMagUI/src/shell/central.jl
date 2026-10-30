# The central area. Until views come (plan 4) it shows an empty state in the middle.

"""
    CentralState

What the empty central area says: a `title` line (or `""`), dim `lines`, and `buttons`
as label => command id; the first button is the primary one when `primary` is true.
"""
struct CentralState
    title::String
    lines::Vector{String}
    buttons::Vector{Pair{String,String}}
    primary::Bool
end

"""
    central_state(app) -> CentralState

Without a project: the first lines of the Start page with New Project and Open Project.
With a project that has no items: the hint to import, with the two import buttons.
Else: no view is open yet.
"""
function central_state(app)::CentralState
    if app.session === nothing
        return CentralState("Welcome to JuliaMag",
            ["Process airborne magnetic line data: import, correct, level, grid and map."],
            ["New Project" => "project.new", "Open Project" => "project.open"], true)
    elseif app.snap !== nothing && isempty(app.snap.items)
        return CentralState("", ["Import line data or a grid to start."],
            ["Import Line Data..." => "import.database", "Import Grid..." => "import.grid"], false)
    end
    return CentralState("", ["No view is open.", "Views of databases and grids come in a later version."],
        Pair{String,String}[], false)
end

"""
    draw_central(app, dl, b)

Draw the central area in box `b`: `canvas` fill and the empty state, centred, with
lines 1.6 times the font size apart as the prototype's `.empty`.
"""
function draw_central(app, dl, b::Box)
    s = app.window.scale
    t = app.tokens
    p(v) = px(s, v)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.canvas))
    st = central_state(app)
    line_h = p(BODY_FONT_SIZE * 1.6)
    title_h = isempty(st.title) ? 0f0 : p(15 * 1.6)
    widths = [button_width(app, label; primary = st.primary && k == 1)
              for (k, (label, _)) in enumerate(st.buttons)]
    buttons_h = isempty(widths) ? 0f0 : p(12 + 26)
    total = title_h + line_h * length(st.lines) + buttons_h
    cx = (b.x0 + b.x1) / 2
    y = round((b.y0 + b.y1 - total) / 2)
    if !isempty(st.title)
        tw = text_width(FONT_SEMIBOLD, 15, st.title)
        draw_text_mid(dl, FONT_SEMIBOLD, 15, cx - tw / 2, y + title_h / 2, u32(t.text), st.title;
            line = 1.6)
        y += title_h
    end
    for line in st.lines
        lw = text_width(FONT_REGULAR, BODY_FONT_SIZE, line)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, cx - lw / 2, y + line_h / 2, u32(t.text_dim), line;
            line = 1.6)
        y += line_h
    end
    isempty(widths) && return nothing
    ig.PushID("central")
    x = round(cx - (sum(widths) + p(8) * (length(widths) - 1)) / 2)
    y += p(12)
    for (k, (label, id)) in enumerate(st.buttons)
        cmd = find_command(app, id)
        enabled = cmd !== nothing && cmd.enabled(app) === nothing
        button(app, label, label, x, y; primary = st.primary && k == 1, enabled, dl) &&
            run_command!(app, id)
        cmd === nothing || command_tip!(app, cmd)
        x += round(widths[k]) + p(8)
    end
    ig.PopID()
    return nothing
end
