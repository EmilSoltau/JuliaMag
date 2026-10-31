# The project backstage: a page over the whole window, as the prototype's `#backstage`.
# A purple nav on the left (Back, the pages, the version) and the page on the right:
# Start, New, Open, Run Script and About. Esc or Back returns to the shell.
#
# Sizes are the prototype's CSS in logical px. Lengths add up unrounded (`fpx`); only the
# edges that are painted are rounded (`snap`, `rnd`), as a browser does (ruling T10-R2).

const NAV_W = 210
const NAV_PAD_Y = 16
const NAV_ROW_H = 40
const NAV_ICON_X = 21
const NAV_TEXT_X = 53
const NAV_TEXT_SIZE = 14
const NAV_HOVER = 0.086f0      # white over the brand colour, as `rgba(255,255,255,.086)`
const NAV_ON = 0.18f0
const NAV_SEPARATOR = 0.2f0
const NAV_VERSION = 0.75f0     # the version text's opacity

const PAGE_PAD_X = 48
const PAGE_PAD_Y = 36
const H1_SIZE = 26
const H2_SIZE = 15
const LOGO_SIZE = 44
const CARD_W = 200
const CARD_GAP = 18
const RECENT_MAX_W = 860
const RECENT_ROW_H = 44
const INFO_LABEL_W = 140
const FORM_MAX_W = 640
const SCRIPT_MAX_W = 860
const SCRIPT_H = 300
const SCRIPT_LINE = 18          # mono 12, line height 1.5
const OUTPUT_MAX_H = 260
const HELP_MAX_W = 480          # `.help`: max-width 60ch

# The pages of the nav, in order; `:sep` is a separator line.
const NAV_PAGES = Any[(:start, "Start", "folder"), (:new, "New", "new"), (:open, "Open", "open"), :sep,
    (:script, "Run Script", "script"), :sep, (:about, "About", "about")]

const START_LEAD = "Process airborne magnetic line data: import, correct, level, grid and map."
const NEW_LEAD = "A project is a folder. It holds a small text file listing the items, and one folder of data files per item."
const OPEN_LEAD = "Open a project folder. Items whose files are missing show greyed out, and the project still opens."
const SCRIPT_LEAD = "Every change is a command. This is the history of the project as a plain Julia script you can save and run again."
const SCRIPT_REPL = "The same script runs from the Julia REPL, without the app: include(\"script.jl\")."
const RUN_SCRIPT_TEXT = "Running a script closes this project, runs the script, then opens the project again."
const ABOUT_TEXT = "JuliaMag processes airborne magnetic survey data. It is written in Julia. Its tools follow Oasis montaj, and its structure follows RustGIS: a ribbon in the order of the work, side panes, light and dark themes, command search, undo for every change, and background jobs."
const ABOUT_NOTE = "This version builds the foundation: projects, import and export, the tool system and background jobs. Views and maps come in a later version."
const SAVED_NOTE = "Data is written at once. There is nothing to save."

"JuliaMag and its version, as the nav's footer shows it."
version_text() = "JuliaMag " * string(something(pkgversion(@__MODULE__), v"0.0.0"))

# --- Opening and leaving ---

"""
    open_backstage!(app, page)

Show the backstage on `page` (`:start`, `:new`, `:open`, `:script`, `:about`). The menu
and the command search close, and the recent folders are read again on the worker.
"""
function open_backstage!(app, page::Symbol)
    ui = app.ui
    ui.backstage = true
    set_page!(app, page)
    close_menu!(app)
    close_search!(app)
    refresh_recent!(app)
    return nothing
end

"Leave the backstage for the shell."
function close_backstage!(app)
    app.ui.backstage = false
    close_menu!(app)
    return nothing
end

function set_page!(app, page::Symbol)
    page in (:start, :new, :open, :script, :about) || (page = :start)
    ui = app.ui
    ui.backstage_page = page
    ui.bs.scroll = 0f0
    page === :new && fill_new_form!(app)
    return nothing
end

handle_request!(app, r::OpenBackstage) = (open_backstage!(app, r.page); true)

# The New page starts with the name "New Survey" in the folder of the last project.
function fill_new_form!(app)
    bs = app.ui.bs
    bs.filled && return nothing
    bs.filled = true
    recent = app.config.recent
    parent = isempty(recent) ? homedir() : dirname(first(recent))
    set_field!(bs.name_buffer, "New Survey")
    set_field!(bs.folder_buffer, parent)
    return nothing
end

# --- The frame ---

"""
    draw_backstage(app)

Draw the backstage over the whole window: the nav (`brand` fill, 210 wide) and the page
(`ribbon` fill, padding 48 by 36, scrolls), then the dialogs and the command search over
it. Esc returns to the shell when no dialog, menu, search or text field has it.
"""
function draw_backstage(app)
    w = app.window::Window
    s = w.scale
    t = app.tokens
    ui = app.ui
    vp = unsafe_load(ig.GetMainViewport())
    ig.SetNextWindowPos(vp.Pos)
    ig.SetNextWindowSize(vp.Size)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowRounding, 0)
    ig.Begin("Backstage", C_NULL, HOST_FLAGS)
    ig.PopStyleVar(3)
    dl = ig.GetWindowDrawList()
    x0, y0 = vp.Pos.x, vp.Pos.y
    x1, y1 = x0 + vp.Size.x, y0 + vp.Size.y
    nav = Box(x0, y0, rnd(x0 + fpx(s, NAV_W)), y1)
    body = Box(nav.x1, y0, x1, y1)
    ig.AddRectFilled(dl, (body.x0, body.y0), (body.x1, body.y1), u32(t.ribbon))
    ig.AddRectFilled(dl, (nav.x0, nav.y0), (nav.x1, nav.y1), u32(t.brand))
    ig.PushID("nav")
    draw_nav(app, dl, nav)
    ig.PopID()
    ig.PushID("body")
    draw_page(app, dl, body)
    ig.PopID()
    draw_dialogs(app)
    isempty(ui.dialogs) && draw_search(app, 0)
    typing = unsafe_load(ig.GetIO()).WantTextInput
    if isempty(ui.dialogs) && ui.search === nothing && ui.menu === nothing && !typing &&
            ig.IsKeyPressed(lib.ImGuiKey_Escape, false)
        close_backstage!(app)
    end
    ig.End()
    return nothing
end

# The nav: Back, a 12 px gap, the pages with separators, and the version at the bottom.
function draw_nav(app, dl, nav::Box)
    s = app.window.scale
    t = app.tokens
    ui = app.ui
    f(v) = fpx(s, v)
    hl = hairline(s)
    white = t.on_accent
    y = nav.y0 + f(NAV_PAD_Y)
    back = snap(Box(nav.x0, y, nav.x1, y + f(NAV_ROW_H)))
    clicked, hovered, _ = hit("Back", back)
    hovered && ig.AddRectFilled(dl, (back.x0, back.y0), (back.x1, back.y1), u32(white, NAV_HOVER))
    draw_icon(dl, "back", (rnd(nav.x0 + f(NAV_ICON_X)), rnd(y + f(9))), 22; style = :nav)
    hovered && item_tip!(app, "Back"; help = "Back to the project", shortcut = "Esc")
    clicked && close_backstage!(app)
    y += f(NAV_ROW_H + 12)
    for entry in NAV_PAGES
        if entry === :sep
            ly = rnd(y + f(8))
            ig.AddRectFilled(dl, (rnd(nav.x0 + f(20)), ly), (rnd(nav.x1 - f(20)), ly + hl),
                u32(white, NAV_SEPARATOR))
            y += f(8 + 1 + 8)
            continue
        end
        page, label, icon = entry
        row = snap(Box(nav.x0, y, nav.x1, y + f(NAV_ROW_H)))
        on = ui.backstage_page === page
        clicked, hovered, _ = hit(label, row)
        (on || hovered) && ig.AddRectFilled(dl, (row.x0, row.y0), (row.x1, row.y1),
            u32(white, on ? NAV_ON : NAV_HOVER))
        draw_icon(dl, icon, (rnd(nav.x0 + f(NAV_ICON_X)), rnd(y + f(11))), 18; style = :nav)
        draw_text_mid(dl, on ? FONT_SEMIBOLD : FONT_REGULAR, NAV_TEXT_SIZE, nav.x0 + f(NAV_TEXT_X),
            y + f(NAV_ROW_H) / 2, u32(white), label)
        clicked && set_page!(app, page)
        y += f(NAV_ROW_H)
    end
    line = f(11 * 1.25)
    draw_text_mid(dl, FONT_REGULAR, 11, nav.x0 + f(NAV_ICON_X), nav.y1 - f(NAV_PAD_Y) - line / 2,
        u32(white, NAV_VERSION), version_text())
    return nothing
end

# The page in `body`: scrolled, clipped, padded 48 by 36.
function draw_page(app, dl, body::Box)
    s = app.window.scale
    bs = app.ui.bs
    f(v) = fpx(s, v)
    bs.scroll, _ = scroll_area!(app, "scroll", body, bs.content_h, bs.scroll)
    x = body.x0 + f(PAGE_PAD_X)
    top = body.y0 - bs.scroll
    w = max(width(body) - f(2 * PAGE_PAD_X), f(100))
    ig.PushClipRect((body.x0, body.y0), (body.x1, body.y1), true)
    page = app.ui.backstage_page
    y = top + f(PAGE_PAD_Y)
    y = page === :new ? draw_new_page(app, dl, x, y, w) :
        page === :open ? draw_open_page(app, dl, x, y, w) :
        page === :script ? draw_script_page(app, dl, x, y, w) :
        page === :about ? draw_about_page(app, dl, x, y, w) :
        draw_start_page(app, dl, x, y, w)
    ig.PopClipRect()
    bs.content_h = y + f(PAGE_PAD_Y) - top
    return nothing
end

# --- Page parts ---

# A page title (h1, 26 semibold), with the 44 px logo before it when `logo`. Returns its bottom.
function draw_h1(app, dl, x::Float32, y::Float32, text::AbstractString; logo::Bool = false)::Float32
    s = app.window.scale
    f(v) = fpx(s, v)
    h = logo ? f(LOGO_SIZE) : f(H1_SIZE * 1.25)
    tx = x
    if logo
        draw_icon(dl, "logo", (rnd(x), rnd(y)), LOGO_SIZE; style = :nav)
        tx += f(LOGO_SIZE + 12)
    end
    draw_text_mid(dl, FONT_SEMIBOLD, H1_SIZE, tx, y + h / 2, u32(app.tokens.text), text)
    return y + h
end

# A section title (h2, 15 semibold), 28 px under `y`. Returns where its content starts (10 px under it).
function draw_h2(app, dl, x::Float32, y::Float32, text::AbstractString)::Float32
    s = app.window.scale
    f(v) = fpx(s, v)
    y += f(28)
    draw_text_mid(dl, FONT_SEMIBOLD, H2_SIZE, x, y + f(H2_SIZE * 1.25) / 2, u32(app.tokens.text), text)
    return y + f(H2_SIZE * 1.25 + 10)
end

"""
    draw_lines(app, dl, x, y, w, text; size = 12.5, pitch = 1.25, colour = :text_dim) -> Float32

`text` wrapped to `w` device px from `(x, y)`, each line `pitch` times `size` high (the
lead line and the paragraphs of a page). Returns the bottom.
"""
function draw_lines(app, dl, x::Float32, y::Float32, w::Real, text::AbstractString;
        size::Real = BODY_FONT_SIZE, pitch::Real = 1.25, colour::Symbol = :text_dim)::Float32
    s = app.window.scale
    lh = fpx(s, size * pitch)
    col = u32(getfield(app.tokens, colour))
    for line in wrap_lines(FONT_REGULAR, size, text, w)
        draw_text_mid(dl, FONT_REGULAR, size, x, y + lh / 2, col, line; line = pitch)
        y += lh
    end
    return y
end

# A card (`.card`): 200 wide, the 86 px thumbnail with a 48 px icon, the title and a line.
function draw_card(app, dl, b::Box, id::String, title::String, sub::String, icon::String)::Bool
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    sb = snap(b)
    clicked, hovered, held = hit(id, sb)
    ig.AddRectFilled(dl, (sb.x0, sb.y0), (sb.x1, sb.y1), u32(hovered ? (held ? t.pressed : t.hover) : t.pane), f(10))
    ig.AddRect(dl, (sb.x0, sb.y0), (sb.x1, sb.y1), u32(hovered ? t.accent : t.border), f(10), hl)
    th = snap(Box(b.x0 + hl + f(12), b.y0 + hl + f(12), b.x1 - hl - f(12), b.y0 + hl + f(12 + 86)))
    ig.AddRectFilled(dl, (th.x0, th.y0), (th.x1, th.y1), u32(t.canvas), f(6))
    draw_icon(dl, icon, (rnd((th.x0 + th.x1) / 2 - f(24)), rnd(centre_y(th) - f(24))), 48)
    ty = th.y1 + f(12)
    draw_text_mid(dl, FONT_SEMIBOLD, 13.5, th.x0 + f(2), ty + f(13.5 * 1.25) / 2, u32(t.text), title)
    ty += f(13.5 * 1.25 + 5)
    draw_text_mid(dl, FONT_REGULAR, 11.5, th.x0 + f(2), ty + f(11.5 * 1.25) / 2, u32(t.text_dim), sub)
    return clicked
end

const CARD_H = 1 + 12 + 86 + 12 + 13.5 * 1.25 + 5 + 11.5 * 1.25 + 12 + 1   # 160.25: more than its min-height 160

"""
    draw_recent(app, dl, x, y, w) -> Float32

The recent projects (`.recent`), up to 860 wide: one 44 px row per folder with the folder
icon, the project name and the path, and "Open now" for the open project. A folder that
was not found is greyed, with "(folder not found)". A click opens the project (the open
one: back to the shell); a right click offers "Remove from List". Returns the bottom.
"""
function draw_recent(app, dl, x::Float32, y::Float32, w::Real)::Float32
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    folders = app.config.recent
    m = app.ui.menu
    m isa OpenMenu && m.owner == "recent" && keep_menu!(app, "recent", m.anchor)
    if isempty(folders)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x, y + f(BODY_FONT_SIZE * 1.25) / 2,
            u32(t.text_dim), "Projects you open show here.")
        return y + f(BODY_FONT_SIZE * 1.25)
    end
    open_folder = app.snap === nothing ? "" : app.snap.folder
    rw = min(Float32(w), f(RECENT_MAX_W))
    n = length(folders)
    frame = snap(Box(x, y, x + rw, y + 2 * hl + n * f(RECENT_ROW_H)))
    ig.PushID("recent")
    for (k, folder) in enumerate(folders)
        info = get(app.ui.bs.recent, folder, RecentInfo(folder_label(folder), true))
        current = !isempty(open_folder) && (folder == open_folder || folder == app.ui.bs.open_path)
        top = frame.y0 + hl + (k - 1) * f(RECENT_ROW_H)
        row = snap(Box(frame.x0 + hl, top, frame.x1 - hl, top + f(RECENT_ROW_H) - (k < n ? hl : 0f0)))
        clicked, hovered, held = hit(folder, row)
        if hovered
            corners = (k == 1 ? Int(lib.ImDrawFlags_RoundTop) : 0) | (k == n ? Int(lib.ImDrawFlags_RoundBottom) : 0)
            ig.AddRectFilled(dl, (row.x0, row.y0), (row.x1, row.y1), u32(held ? t.pressed : t.hover),
                corners == 0 ? 0f0 : f(8) - hl, corners == 0 ? Int(lib.ImDrawFlags_RoundNone) : corners)
        end
        k < n && ig.AddRectFilled(dl, (row.x0, row.y1), (row.x1, row.y1 + hl), u32(t.border))
        mid = centre_y(row)
        ix = row.x0 + f(14)
        draw_icon(dl, info.found ? "folder" : "missing", (rnd(ix), rnd(mid - f(10))), 20)
        tx = ix + f(20 + 12)
        right = row.x1 - f(14)
        if current
            ww = text_width(FONT_REGULAR, 11.5, "Open now")
            draw_text_mid(dl, FONT_REGULAR, 11.5, right - ww, mid, u32(t.text_dim), "Open now")
            right -= ww + f(12)
        end
        lines_top = mid - f(12.5 * 1.25 + 2 + 11.5 * 1.25) / 2
        name = elide(text_width, info.name, right - tx; role = FONT_SEMIBOLD)
        draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, tx, lines_top + f(12.5 * 1.25) / 2,
            u32(info.found ? t.text : t.text_disabled), name)
        path = info.found ? folder : folder * "  (folder not found)"
        draw_text_mid(dl, FONT_REGULAR, 11.5, tx, lines_top + f(12.5 * 1.25 + 2) + f(11.5 * 1.25) / 2,
            u32(t.text_dim), elide(text_width, path, right - tx; size = 11.5))
        if clicked
            current ? close_backstage!(app) : open_project!(app, folder)
        end
        if hovered && ig.IsMouseClicked(1)
            mouse = unsafe_load(ig.GetIO().MousePos)
            open_menu!(app, "recent", Box(mouse.x, mouse.y, mouse.x, mouse.y),
                [MenuItem("Remove from List"; icon = "trash", action = a -> remove_recent!(a, folder))]; gap = 0)
        end
    end
    ig.PopID()
    ig.AddRect(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.border), f(8), hl)
    return frame.y1
end

# --- The pages ---

function draw_start_page(app, dl, x::Float32, y::Float32, w::Float32)::Float32
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    y = draw_h1(app, dl, x, y, "Welcome to JuliaMag"; logo = true)
    y = draw_lines(app, dl, x, y + f(6), w, START_LEAD)
    y = draw_h2(app, dl, x, y, "New Project")
    cards = (("Empty Project", "A new project folder", "new", :new),
        ("Open...", "A JuliaMag project folder", "open", :open))
    cx = x
    for (title, sub, icon, page) in cards
        draw_card(app, dl, Box(cx, y, cx + f(CARD_W), y + f(CARD_H)), title, title, sub, icon) &&
            set_page!(app, page)
        cx += f(CARD_W + CARD_GAP)
    end
    y += f(CARD_H)
    y = draw_h2(app, dl, x, y, "Recent Projects")
    y = draw_recent(app, dl, x, y, w)
    sn = app.snap
    if app.session !== nothing && sn !== nothing
        y = draw_h2(app, dl, x, y, "Current Project")
        dbs = count(it -> it.kind == Core.ITEM_DATABASE, sn.items)
        grids = count(it -> it.kind == Core.ITEM_GRID, sn.items)
        rows = ("Name" => sn.project_name, "Folder" => sn.folder,
            "Items" => plural(dbs, "database") * ", " * plural(grids, "grid"),
            "Jobs" => string(length(sn.jobs), " in the history"), "Saved" => SAVED_NOTE)
        lh = f(BODY_FONT_SIZE * 1.25)
        vx = x + f(INFO_LABEL_W + 16)
        for (k, (label, value)) in enumerate(rows)
            k > 1 && (y += f(6))
            draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x, y + lh / 2, u32(t.text_dim), label)
            draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, vx, y + lh / 2, u32(t.text),
                elide(text_width, value, x + w - vx))
            y += lh
        end
    end
    return y
end

function draw_new_page(app, dl, x::Float32, y::Float32, w::Float32)::Float32
    s = app.window.scale
    t = app.tokens
    bs = app.ui.bs
    f(v) = fpx(s, v)
    fill_new_form!(app)
    y = draw_h1(app, dl, x, y, "New Project")
    y = draw_lines(app, dl, x, y + f(6), w, NEW_LEAD)
    y += f(20)
    fw = min(w, f(FORM_MAX_W))
    cx = x + f(FORM_LABEL_W + FORM_GAP_X)
    x1 = x + fw
    # Name
    row = Box(x, y, x1, y + f(FIELD_H))
    form_label(app, row, "Name")
    text_field!(app, "##name", bs.name_buffer, snap(Box(cx, row.y0, x1, row.y1));
        error = bs.new_problem !== nothing) && (bs.new_problem = nothing)
    y = row.y1
    problem = bs.new_problem
    problem === nothing || (y = form_hint(app, dl, cx, y, x1 - cx, problem; error = true))
    # Folder: the folder the project folder goes in, with Browse...
    y += f(FORM_GAP_Y)
    row = Box(x, y, x1, y + f(26))
    form_label(app, row, "Folder")
    bw = round(button_width(app, "Browse..."))
    bx = x1 - bw
    field = snap(Box(cx, row.y0 + f(1), bx - f(6), row.y1 - f(1)))
    text_field!(app, "##folder", bs.folder_buffer, field; role = FONT_MONO, size = 12,
        error = bs.folder_problem !== nothing) && (bs.folder_problem = nothing)
    if button(app, "Browse...", "Browse...", bx, row.y0)
        parent = field_text(bs.folder_buffer)
        picked = ask_folder(app; title = "Folder for the new project", start = parent)
        isempty(picked) || (set_field!(bs.folder_buffer, picked); bs.folder_problem = nothing)
    end
    y = row.y1
    name = strip(field_text(bs.name_buffer))
    parent = strip(field_text(bs.folder_buffer))
    folder_problem = bs.folder_problem
    hint = folder_problem !== nothing ? folder_problem :
        isempty(name) || isempty(parent) ? "" : "The project folder: " * joinpath(parent, name)
    isempty(hint) || (y = form_hint(app, dl, cx, y, x1 - cx, hint; error = folder_problem !== nothing))
    y += f(20)
    if button(app, "Create Project", "Create Project", x, y; primary = true)
        create_project_from_form!(app)
    end
    return y + f(26)
end

# A hint line under a form row (`.form .hint`): 11 px, 4 px higher than the row gap.
function form_hint(app, dl, x::Float32, y::Float32, w::Real, text::AbstractString; error::Bool = false)::Float32
    s = app.window.scale
    return draw_lines(app, dl, x, y + fpx(s, FORM_GAP_Y - 4), w, text; size = FORM_HINT_SIZE,
        pitch = FORM_HINT_LINE, colour = error ? :red : :text_dim)
end

"Create Project on the New page: check the form, then `new_project!`."
function create_project_from_form!(app)
    bs = app.ui.bs
    name = field_text(bs.name_buffer)
    parent = String(strip(field_text(bs.folder_buffer)))
    bs.folder_problem = isempty(parent) ? "Choose a folder." :
        !isabspath(parent) ? "Type the full path of a folder." : nothing
    bs.new_problem = project_name_problem(name)
    (bs.new_problem === nothing && bs.folder_problem === nothing) || return nothing
    bs.new_problem = new_project!(app, parent, name)
    return nothing
end

function draw_open_page(app, dl, x::Float32, y::Float32, w::Float32)::Float32
    s = app.window.scale
    f(v) = fpx(s, v)
    y = draw_h1(app, dl, x, y, "Open")
    y = draw_lines(app, dl, x, y + f(6), w, OPEN_LEAD)
    y += f(20)
    if button(app, "Browse for a Project...", "Browse for a Project...", x, y; primary = true)
        recent = app.config.recent
        start = isempty(recent) ? app.config.last_folder : dirname(first(recent))
        folder = ask_folder(app; title = "Open a project", start)
        isempty(folder) || open_project!(app, folder)
    end
    y = draw_h2(app, dl, x, y + f(26), "Recent Projects")
    return draw_recent(app, dl, x, y, w)
end

# Ask the worker for the project's script when the page shows a project whose script was
# not read at this revision.
function want_script!(app)
    s = app.session
    snap = app.snap
    (s === nothing || snap === nothing) && return nothing
    bs = app.ui.bs
    key = (s, snap.revision)
    bs.script_of == key && return nothing
    bs.script_of = key
    submit!(app, "Read the script", _ -> script_or_problem(s);
        done = (a, text) -> (a.session === s && (a.ui.bs.script = text; a.ui.bs.script_wrap = nothing); nothing))
    return nothing
end

# The script of `s`, or a comment that says why it cannot be written. On the worker.
function script_or_problem(s::Core.Session)::String
    try
        return Core.script_text(s)
    catch e
        e isa InterruptException && rethrow()
        return "# The script cannot be written: " * plain_message(e)
    end
end

"""
    wrap_mono(text, n) -> Vector{String}

The lines of `text` cut to at most `n` characters, at the last space that fits, else
anywhere (a textarea's soft wrap). Spaces at the start of a line stay, for the indents.
"""
function wrap_mono(text::AbstractString, n::Integer)::Vector{String}
    n = max(n, 1)
    out = String[]
    for line in split(text, '\n')
        chars = collect(line)
        while length(chars) > n
            cut = findlast(==(' '), chars[1:n])
            k = cut === nothing || cut == 1 ? n : cut
            push!(out, String(chars[1:k]))
            chars = chars[k+1:end]
        end
        push!(out, String(chars))
    end
    return out
end

function draw_script_page(app, dl, x::Float32, y::Float32, w::Float32)::Float32
    s = app.window.scale
    t = app.tokens
    bs = app.ui.bs
    f(v) = fpx(s, v)
    hl = hairline(s)
    want_script!(app)
    y = draw_h1(app, dl, x, y, "Run Script")
    y = draw_lines(app, dl, x, y + f(6), w, SCRIPT_LEAD)
    y += f(18)
    bx = x
    if button(app, "Run Script...", "Run Script...", bx, y; primary = true)
        ask_run_script!(app)
    end
    bx += round(button_width(app, "Run Script..."; primary = true)) + f(8)
    has_script = app.session !== nothing && bs.script !== nothing
    if button(app, "Save Script As...", "Save Script As...", bx, y; enabled = has_script)
        save_script_as!(app)
    end
    y += f(26 + 8)

    # The script: read-only, mono 12 on 18 px lines, in a 300 px `.inp` box that scrolls.
    bw = min(w, f(SCRIPT_MAX_W))
    box = snap(Box(x, y, x + bw, y + f(SCRIPT_H)))
    ig.AddRectFilled(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.input), f(5))
    ig.AddRect(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.input_border), f(5), hl)
    inner = Box(box.x0 + hl, box.y0 + hl, box.x1 - hl, box.y1 - hl)
    if !has_script
        text = app.session === nothing ? "Open a project to see its script." : "Reading the script..."
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, inner.x0 + f(7), inner.y0 + f(4 + 9), u32(t.text_dim), text)
    else
        lines = script_lines!(app, width(inner) - f(14 + 10))
        lh = f(SCRIPT_LINE)
        content = f(4 + 4) + length(lines) * lh
        ig.PushID("script")
        bs.script_scroll, _ = scroll_area!(app, "scroll", inner, content, bs.script_scroll)
        ig.PopID()
        ig.PushClipRect((inner.x0, inner.y0), (inner.x1, inner.y1), true)
        ly = inner.y0 + f(4) - bs.script_scroll
        for k in visible_rows(length(lines), lh, bs.script_scroll - f(4), height(inner))
            draw_text_mid(dl, FONT_MONO, 12, inner.x0 + f(7), ly + (k - 0.5f0) * lh, u32(t.text), lines[k];
                line = 1.5)
        end
        ig.PopClipRect()
    end
    y = box.y1

    if bs.output !== nothing
        y = draw_output(app, dl, x, y + f(12), bw)
    end
    return draw_lines(app, dl, x, y + f(14), min(w, f(HELP_MAX_W)), SCRIPT_REPL; pitch = 1.4)
end

# The script's lines cut to the box, cached for the text and the width.
function script_lines!(app, w::Real)::Vector{String}
    bs = app.ui.bs
    text = something(bs.script, "")
    n = max(1, floor(Int, w / max(text_width(FONT_MONO, 12, "M"), 1f0)))
    c = bs.script_wrap
    c isa Tuple{String,Int,Vector{String}} && c[1] === text && c[2] == n && return c[3]
    lines = wrap_mono(text, n)
    bs.script_wrap = (text, n, lines)
    return lines
end

# The output of the last run (`.desc`): mono 11.5 on 1.45 lines, `pane_header` fill, at most
# 260 high; it scrolls. The error at the end is red. Returns the bottom.
function draw_output(app, dl, x::Float32, y::Float32, w::Float32)::Float32
    s = app.window.scale
    t = app.tokens
    bs = app.ui.bs
    f(v) = fpx(s, v)
    hl = hairline(s)
    text = something(bs.output, "")
    lines = split(rstrip(text, '\n'), '\n')
    errors = isempty(bs.output_error) ? 0 : length(split(rstrip(bs.output_error, '\n'), '\n'))
    lh = f(11.5 * 1.45)
    pad_y = f(8)
    content = 2 * pad_y + length(lines) * lh
    h = min(content, f(OUTPUT_MAX_H) - 2 * hl)
    box = snap(Box(x, y, x + w, y + h + 2 * hl))
    ig.AddRectFilled(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.pane_header), f(6))
    ig.AddRect(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.border), f(6), hl)
    inner = Box(box.x0 + hl, box.y0 + hl, box.x1 - hl, box.y1 - hl)
    ig.PushID("output")
    bs.output_scroll, _ = scroll_area!(app, "scroll", inner, content, bs.output_scroll)
    ig.PopID()
    ig.PushClipRect((inner.x0, inner.y0), (inner.x1 - f(10), inner.y1), true)
    top = inner.y0 + pad_y - bs.output_scroll
    n = length(lines)
    for k in visible_rows(n, lh, bs.output_scroll - pad_y, height(inner))
        col = k > n - errors ? t.red : t.text
        draw_text_mid(dl, FONT_MONO, 11.5, inner.x0 + f(10), top + (k - 0.5f0) * lh, u32(col), lines[k];
            line = 1.45)
    end
    ig.PopClipRect()
    return box.y1
end

# Run Script...: pick a .jl file, ask when a project is open, then `run_script!`.
function ask_run_script!(app)
    path = ask_file(app; save = false, title = "Run Script", extensions = [".jl"],
        start = app.config.last_folder)
    isempty(path) && return nothing
    remember_folder!(app, path)
    if app.session === nothing
        run_script!(app, path)
    else
        confirm!(app, "Run a script?", RUN_SCRIPT_TEXT; action = "Run Script",
            on_yes = a -> run_script!(a, path))
    end
    return nothing
end

# Save Script As...: a native save dialog for a .jl file; the worker writes it.
function save_script_as!(app)
    text = app.ui.bs.script
    text === nothing && return nothing
    name = app.snap === nothing ? "script.jl" : replace(app.snap.project_name, r"[<>:\"/\\|?*]" => "_") * ".jl"
    picked = ask_file(app; save = true, title = "Save Script As", extensions = [".jl"],
        start = joinpath(app.config.last_folder, name))
    isempty(picked) && return nothing
    path = with_extension(picked, ".jl")
    remember_folder!(app, path)
    submit!(app, "Save the script", _ -> (write(path, text); nothing);
        done = (a, _) -> (toast!(a, :ok, "Saved the script."; sub = path); nothing))
    return nothing
end

function draw_about_page(app, dl, x::Float32, y::Float32, w::Float32)::Float32
    s = app.window.scale
    f(v) = fpx(s, v)
    y = draw_h1(app, dl, x, y, "About JuliaMag"; logo = true)
    v = something(pkgversion(@__MODULE__), v"0.0.0")
    y = draw_lines(app, dl, x, y + f(6), w, "Version $v.")
    pw = min(w, f(FORM_MAX_W))
    y = draw_lines(app, dl, x, y + f(16), pw, ABOUT_TEXT; pitch = 1.5, colour = :text)
    y = draw_lines(app, dl, x, y + f(12.5), pw, ABOUT_NOTE; pitch = 1.5)
    y = draw_h2(app, dl, x, y, "Keyboard shortcuts")   # its 28 px margin takes in the paragraph's
    ig.SetCursorScreenPos((x, y))
    rows = shortcut_rows(commands(app))
    draw_shortcut_rows(app, rows)
    n = length(rows)
    return y + n * f(SHORTCUT_ROW_H) + (n - 1) * f(SHORTCUT_GAP[1])
end

# --- The busy state ---

const BUSY_FLAGS = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
    ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoBackground |
    ig.ImGuiWindowFlags_NoScrollWithMouse

"""
    draw_busy(app)

While a project opens or closes (`app.switching`): the `backdrop` over the whole window,
which takes every click, and in the middle a card with a spinner and what the app does,
such as "Opening Survey...".
"""
function draw_busy(app)
    text = app.switching
    text === nothing && return nothing
    w = app.window::Window
    s = w.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    vp = unsafe_load(ig.GetMainViewport())
    ig.SetNextWindowPos(vp.Pos)
    ig.SetNextWindowSize(vp.Size)
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
    ig.Begin("###busy", C_NULL, BUSY_FLAGS)
    ig.PopStyleVar(2)
    dl = ig.GetWindowDrawList()
    all = Box(vp.Pos.x, vp.Pos.y, vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y)
    hit("busy", all)
    ig.AddRectFilled(dl, (all.x0, all.y0), (all.x1, all.y1), u32(t.backdrop))
    tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, text)
    cw = round(f(14 + 12 + 8 + 14) + tw + 2 * hl)
    ch = round(f(40))
    cx = round((all.x0 + all.x1 - cw) / 2)
    cy = round((all.y0 + all.y1 - ch) / 2 - f(30))
    card = Box(cx, cy, cx + cw, cy + ch)
    draw_shadow(dl, card, f(8), f(6), f(18), t.shadow)
    ig.AddRectFilled(dl, (card.x0, card.y0), (card.x1, card.y1), u32(t.menu), f(8))
    ig.AddRect(dl, (card.x0, card.y0), (card.x1, card.y1), u32(t.border_strong), f(8), hl)
    mid = centre_y(card)
    draw_spinner(app, dl, card.x0 + hl + f(14 + 6), mid)
    draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, card.x0 + hl + f(14 + 12 + 8), mid, u32(t.text), text)
    request_frames!(w, 0.05)   # the spinner turns
    ig.End()
    return nothing
end
