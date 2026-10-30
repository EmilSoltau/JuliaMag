# The ribbon tab strip: the Project button, the tabs, the pinned Settings and Help tabs and
# the chevron that collapses the ribbon.

"""
    TabLayout

Where the tab strip parts go, in device pixels. `tabs` and `pinned` pair each tab name
with its box. A tab that does not fit before the pinned tabs is left out.
"""
struct TabLayout
    project::Box
    tabs::Vector{Pair{String,Box}}
    pinned::Vector{Pair{String,Box}}
    chevron::Box
end

"""
    tab_layout(b, scale, measure, tabs, pinned) -> TabLayout

Lay out the strip in box `b` as the prototype's `#tabs`: padding 8, the Project button
(26 high, semibold text + 26 wide), 8 px, the `tabs` 2 px apart, and at the right the
`pinned` tabs, 6 px, then the 24 by 24 chevron. A tab is as wide as its semibold text
plus 22, so it never moves when it turns active.
`measure(role, size, text)` is the text width in device pixels.
"""
function tab_layout(b::Box, scale::Real, measure, tabs::AbstractVector{<:AbstractString},
        pinned::AbstractVector{<:AbstractString})::TabLayout
    p(v) = px(scale, v)
    mid = centre_y(b)
    tab_w(name) = round(measure(FONT_SEMIBOLD, BODY_FONT_SIZE, name) + p(22))
    pw = round(measure(FONT_SEMIBOLD, BODY_FONT_SIZE, "Project") + p(26))
    project = Box(b.x0 + p(8), round(mid - p(13)), b.x0 + p(8) + pw, round(mid - p(13)) + p(26))
    chevron = Box(b.x1 - p(8 + 24), round(mid - p(12)), b.x1 - p(8), round(mid - p(12)) + p(24))
    right = chevron.x0 - p(6)
    fixed = Pair{String,Box}[]
    for name in reverse(pinned)
        tw = tab_w(name)
        pushfirst!(fixed, String(name) => Box(right - tw, b.y0, right, b.y1))
        right -= tw + p(2)
    end
    x = project.x1 + p(8)
    placed = Pair{String,Box}[]
    for name in tabs
        tw = tab_w(name)
        x + tw > right && break
        push!(placed, String(name) => Box(x, b.y0, x + tw, b.y1))
        x += tw + p(2)
    end
    return TabLayout(project, placed, fixed, chevron)
end

"""
    draw_tab_strip(app, dl, b)

Draw the tab strip in box `b` (32 high, `tab_strip` fill). A click on a tab makes it the
ribbon tab; while the ribbon is collapsed it shows the ribbon for a moment (the peek),
and a second click on the same tab hides it. A double click collapses or expands the
ribbon, like the chevron and Ctrl+F1.
"""
function draw_tab_strip(app, dl, b::Box)
    s = app.window.scale
    t = app.tokens
    ui = app.ui
    p(v) = px(s, v)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.tab_strip))
    tabs = tab_order(commands(app), app.config.hidden_tabs)
    ui.tab in tabs || ui.tab in PINNED_TABS ||
        (ui.tab = isempty(tabs) ? first(PINNED_TABS) : first(tabs))
    l = tab_layout(b, s, text_width, tabs, PINNED_TABS)
    ig.PushID("tabs")

    # The Project button.
    pb = l.project
    clicked, hovered, _ = hit("Project", pb)
    ig.AddRectFilled(dl, (pb.x0, pb.y0), (pb.x1, pb.y1), u32(hovered ? t.brand_dark : t.brand), p(6))
    tw = text_width(FONT_SEMIBOLD, BODY_FONT_SIZE, "Project")
    draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, pb.x0 + (width(pb) - tw) / 2, centre_y(pb),
        u32(t.on_accent), "Project")
    clicked && run_command!(app, "project.backstage")
    hovered && item_tip!(app, "Project"; help = "Open, save and create projects. Run scripts.",
        id = "project.backstage")

    for (name, tb) in Iterators.flatten((l.tabs, l.pinned))
        draw_ribbon_tab(app, dl, name, tb)
    end

    # The chevron.
    collapsed = app.config.ribbon_collapsed
    cb = l.chevron
    clicked, hovered, _ = hit("Collapse Ribbon", cb)
    hovered && ig.AddRectFilled(dl, (cb.x0, cb.y0), (cb.x1, cb.y1), u32(t.hover), p(5))
    draw_icon(dl, collapsed ? "chevDown" : "chevUp",
        (cb.x0 + (width(cb) - p(14)) / 2, cb.y0 + (height(cb) - p(14)) / 2), 14; style = :dim)
    clicked && run_command!(app, "ui.ribbon")
    hovered && item_tip!(app, collapsed ? "Expand the ribbon" : "Collapse the ribbon";
        shortcut = "Ctrl+F1")
    ig.PopID()
    return nothing
end

# One ribbon tab, as the prototype's `.rtab`.
function draw_ribbon_tab(app, dl, name::String, b::Box)
    s = app.window.scale
    t = app.tokens
    ui = app.ui
    p(v) = px(s, v)
    hl = hairline(s)
    on = ui.tab == name
    # Pressed on the click itself, so a double click runs the click before the collapse,
    # as in a browser.
    clicked, hovered, _ = hit(name, b; flags = Int(ig.ImGuiButtonFlags_PressedOnClick))
    if clicked
        app.config.ribbon_collapsed && (ui.ribbon_peek = !(on && ui.ribbon_peek))
        ui.tab = name
        on = true
        ig.IsMouseDoubleClicked(0) && run_command!(app, "ui.ribbon")
    end
    if on
        body = Box(b.x0, b.y0 + p(3), b.x1, b.y1)
        top = Int(lib.ImDrawFlags_RoundTop)
        ig.AddRectFilled(dl, (body.x0, body.y0), (body.x1, body.y1), u32(t.ribbon), p(6), top)
        # The outline without its bottom edge: that edge lies below the strip, clipped away.
        ig.PushClipRect(dl, (b.x0, b.y0), (b.x1, b.y1), true)
        ig.AddRect(dl, (body.x0, body.y0), (body.x1, body.y1 + hl), u32(t.border), p(6), hl, top)
        ig.PopClipRect(dl)
        ig.AddRectFilled(dl, (body.x0 + p(8), body.y1 - p(3)), (body.x1 - p(8), body.y1 - p(1)),
            u32(t.accent), p(1))
    elseif hovered
        ig.AddRectFilled(dl, (b.x0 + p(1), b.y0 + p(5)), (b.x1 - p(1), b.y1 - p(2)), u32(t.hover), p(5))
    end
    role = on ? FONT_SEMIBOLD : FONT_REGULAR
    tw = text_width(role, BODY_FONT_SIZE, name)
    draw_text_mid(dl, role, BODY_FONT_SIZE, b.x0 + (width(b) - tw) / 2, b.y0 + p(3) + (height(b) - p(3)) / 2,
        u32(on ? t.text : t.text_dim), name)
    return nothing
end
