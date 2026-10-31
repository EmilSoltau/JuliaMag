# The Tools pane (All Tools): every tool, importer and exporter of the core's registries,
# grouped by ribbon tab, with a search box. A click runs the row's command: a tool opens its
# dialog (an `OpenToolDialog` request), an importer asks for a file and then opens its
# dialog, an exporter opens its dialog.

const TOOLS_HINT = "Find a tool by name or id"
const TOOLS_NOTE = "Each tool is one Julia function and a description."
const TOOLS_NO_MATCH = "No tool matches."
const OTHER_TOOLS = "Other"

# Sizes in logical pixels (prototype CSS `.toolrow`, `.sect`, `.foot`).
const TOOL_ROW_H = 42
const TOOL_SECT_H = 26
const TOOL_SECT_GAP = 4      # `.sect` margin-top
const TOOL_LIST_END = 6      # the list's padding-bottom
const TOOL_EMPTY_H = 120
const TOOL_TOP_H = 44        # 8 + 28 + 8, over a 1 px line
const TOOL_NOTE_SIZE = 11.5f0
const TOOL_NOTE_PITCH = 1.4f0

"""
    ToolEntry

A row of the Tools pane: the command of a tool, importer or exporter, and whether it runs
as a background `job` (every import and export does; a tool when its registry mode says so).
"""
struct ToolEntry
    cmd::Command
    job::Bool
end

"""
    tool_entries(cmds; tools, importers, exporters) -> Vector{ToolEntry}

The rows of the Tools pane from the command list: the importers, the exporters and the
tools, each in registry order, as the prototype lists a tab (imports, exports, tools).
The registries default to the core's.
"""
function tool_entries(cmds::AbstractVector{Command}; tools = Core.tools(),
        importers = Core.importers(), exporters = Core.exporters())::Vector{ToolEntry}
    by_id = Dict(c.id => c for c in cmds)
    out = ToolEntry[]
    add(id, job) = (c = get(by_id, id, nothing); c === nothing || push!(out, ToolEntry(c, job)))
    foreach(i -> add(i.id, true), importers)
    foreach(e -> add(e.id, true), exporters)
    foreach(t -> add(t.id, t.mode === :job), tools)
    return out
end

"""
    tool_groups(entries, query) -> Vector{Pair{String,Vector{ToolEntry}}}

The entries whose name or id holds `query` (plain text, trimmed, any case), grouped by the
ribbon tab of their command's first place: the tabs in ribbon order (`FIRST_TABS` first),
entries without a place last under "$(OTHER_TOOLS)". Each group keeps the entries' order.
Groups with no entry are left out.
"""
function tool_groups(entries::AbstractVector{ToolEntry}, query::AbstractString)
    q = lowercase(strip(query))
    tab_of(e) = isempty(e.cmd.places) ? OTHER_TOOLS : first(e.cmd.places).tab
    hits = [e for e in entries if isempty(q) || occursin(q, lowercase(plain_name(e.cmd))) ||
                                  occursin(q, lowercase(e.cmd.id))]
    seen = unique(tab_of.(hits))
    tabs = [x for x in FIRST_TABS if x in seen]
    append!(tabs, x for x in seen if !(x in FIRST_TABS) && x != OTHER_TOOLS)
    OTHER_TOOLS in seen && push!(tabs, OTHER_TOOLS)
    return [tab => [e for e in hits if tab_of(e) == tab] for tab in tabs]
end

"What `tools_rows!` built, and for what."
struct ToolsCache
    commands::Vector{Command}
    query::String
    groups::Vector{Pair{String,Vector{ToolEntry}}}
end

"""
    tools_rows!(app) -> Vector{Pair{String,Vector{ToolEntry}}}

The Tools pane's groups for its filter. They are kept and built again only when the
command list (a registry changed, a project opened) or the filter changes.
"""
function tools_rows!(app)
    ui = app.ui
    cmds = commands(app)
    c = ui.tools_cache
    c isa ToolsCache && c.commands === cmds && c.query == ui.tools_query && return c.groups
    groups = tool_groups(tool_entries(cmds), ui.tools_query)
    ui.tools_cache = ToolsCache(cmds, ui.tools_query, groups)
    return groups
end

"""
    draw_tools_pane(app, dl, body)

The Tools pane in the pane body `body`, as the prototype's `renderToolsPane`: a search box
(8 px around it, a line under it), the tools under their tab's name, and the note at the
bottom. A row is 42 high: the 20 px icon, the name in semibold `accent_text` over the mono
id, and a `job` tag for what runs as a background job.
"""
function draw_tools_pane(app, dl, body::Box)
    ui = app.ui
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    ig.PushID("tools")
    # The search box.
    top = Box(body.x0, body.y0, body.x1, rnd(body.y0 + f(TOOL_TOP_H)) + hl)
    ig.AddRectFilled(dl, (top.x0, top.y1 - hl), (top.x1, top.y1), u32(t.border))
    box = snap(Box(top.x0 + f(8), top.y0 + f(8), top.x1 - f(8), top.y0 + f(8 + 28)))
    text, _ = search_box!(app, dl, box, "##find", ui.tools_buffer, TOOLS_HINT;
        flags = Int(lib.ImGuiInputTextFlags_EscapeClearsAll))
    if text != ui.tools_query
        ui.tools_query = text
        ui.tools_scroll = 0f0
    end
    # The note at the bottom.
    lines = wrap_lines(FONT_REGULAR, TOOL_NOTE_SIZE, TOOLS_NOTE, width(body) - f(16))
    pitch = f(TOOL_NOTE_SIZE * TOOL_NOTE_PITCH)
    foot = Box(body.x0, rnd(body.y1 - f(16) - length(lines) * pitch) - hl, body.x1, body.y1)
    ig.AddRectFilled(dl, (foot.x0, foot.y0), (foot.x1, foot.y0 + hl), u32(t.border))
    y = foot.y0 + hl + f(8)
    for line in lines
        draw_text_mid(dl, FONT_REGULAR, TOOL_NOTE_SIZE, foot.x0 + f(8), y + pitch / 2,
            u32(t.text_dim), line; line = TOOL_NOTE_PITCH)
        y += pitch
    end
    # The list.
    view = Box(body.x0, top.y1, body.x1, max(foot.y0, top.y1))
    draw_tool_list(app, dl, view, tools_rows!(app))
    ig.PopID()
    return nothing
end

function draw_tool_list(app, dl, view::Box, groups)
    ui = app.ui
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    if isempty(groups)
        tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, TOOLS_NO_MATCH)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, view.x0 + (width(view) - tw) / 2,
            view.y0 + f(TOOL_EMPTY_H) / 2, u32(t.text_dim), TOOLS_NO_MATCH; line = 1.6)
        return nothing
    end
    n_rows = sum(length(last(g)) for g in groups)
    content = length(groups) * f(TOOL_SECT_GAP + TOOL_SECT_H) + n_rows * f(TOOL_ROW_H) + f(TOOL_LIST_END)
    ui.tools_scroll, bar = scroll_area!(app, "scrollbar", view, content, ui.tools_scroll)
    right = view.x1 - (bar ? f(SCROLLBAR_W) : 0f0)
    ig.PushClipRect((view.x0, view.y0), (right, view.y1), true)
    y = view.y0 - ui.tools_scroll
    for (tab, entries) in groups
        y += f(TOOL_SECT_GAP)
        sect = Box(view.x0, y, right, y + f(TOOL_SECT_H))
        y = sect.y1
        if sect.y1 > view.y0 && sect.y0 < view.y1
            draw_spaced_text(dl, FONT_SEMIBOLD, 11, sect.x0 + f(10), centre_y(sect), u32(t.text_dim),
                uppercase(tab), f(11 * 0.02))
        end
        for e in entries
            row = Box(view.x0, y, right, y + f(TOOL_ROW_H))
            y = row.y1
            (row.y1 <= view.y0 || row.y0 >= view.y1) && continue
            draw_tool_row(app, dl, row, e)
        end
    end
    ig.PopClipRect()
    return nothing
end

# One row, as the prototype's `.toolrow`. A click runs the command; when it cannot run now,
# a toast says why.
function draw_tool_row(app, dl, row::Box, e::ToolEntry)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    cmd = e.cmd
    reason = cmd.enabled(app)
    clicked, hovered, held = hit(cmd.id, row)
    hovered && ig.AddRectFilled(dl, (row.x0 + f(4), row.y0 + f(1)), (row.x1 - f(4), row.y1 - f(1)),
        u32(held ? t.pressed : t.hover), f(5))
    mid = centre_y(row)
    x = row.x0 + f(12)
    draw_icon(dl, cmd.icon, (rnd(x), rnd(mid - f(10))), 20; style = reason === nothing ? :normal : :disabled)
    x += f(20 + 10)
    right = row.x1 - f(12)
    if e.job   # the `.later` tag, in `accent_text`
        tag = "job"
        tw = text_width(FONT_REGULAR, 10, tag)
        tb = snap(Box(right - tw - f(8) - 2 * hl, mid - f(8), right, mid + f(8)))
        ig.AddRect(dl, (tb.x0, tb.y0), (tb.x1, tb.y1), u32(t.border), f(4), hl)
        draw_text_mid(dl, FONT_REGULAR, 10, tb.x0 + hl + f(4), centre_y(tb), u32(t.accent_text), tag;
            line = 1.4)
        right = tb.x0 - f(10)
    end
    # The name over the id, as one block centred in the row: line boxes 15.625 and 13.75, 1 px apart.
    name_h, id_h = f(BODY_FONT_SIZE * 1.25f0), f(11 * 1.25f0)
    top = mid - (name_h + f(1) + id_h) / 2
    name = elide(text_width, plain_name(cmd), right - x; role = FONT_SEMIBOLD)
    draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, x, top + name_h / 2,
        u32(reason === nothing ? t.accent_text : t.text_disabled), name)
    id = elide(text_width, cmd.id, right - x; role = FONT_MONO, size = 11)
    draw_text_mid(dl, FONT_MONO, 11, x, top + name_h + f(1) + id_h / 2, u32(t.text_dim), id)
    hovered && command_tip!(app, cmd)
    if clicked
        reason === nothing ? guarded(app, cmd.run) : toast!(app, :info, reason)
    end
    return nothing
end
