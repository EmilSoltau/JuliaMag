# The Settings and Help tabs: the app settings commands, the Defaults combos and the Show
# Tabs menu button of the Settings ribbon, and the Getting Started dialog of the Help tab.
# The theme commands, Command Search, Keyboard Shortcuts, All Tools and About are shell
# commands (commands.jl); this file gives the Help dialogs their requests.
#
# Every change to a setting saves the settings (`save_settings!`, on the worker).

const PINNED_TAB_REASON = "Settings and Help always show."
const SOFTWARE_TOAST = "Takes effect the next time JuliaMag starts."
const DISTANCE_LABELS = ("m" => "Metres", "km" => "Kilometres", "ft" => "Feet")

"The commands of the Settings tab (the theme commands are the shell's)."
function settings_commands()::Vector{Command}
    return Command[
        Command("settings.defaults", "Defaults", app -> nothing;
            help = "The distance units and the colour table for new grids.",
            places = [Core.Place("Settings", "Defaults")], searchable = false),
        Command("settings.temp_folder", "Temp Folder...", pick_temp_folder!;
            icon = "folder", help = "Where large jobs keep their working files. It needs room: some jobs use gigabytes.",
            places = [Core.Place("Settings", "Defaults"; size = :small)]),
        Command("settings.open_last", "Open Last Project at Start", toggle_open_last!;
            label = "Open Last Project", icon = "open", help = "Open the last project when JuliaMag starts.",
            places = [Core.Place("Settings", "Startup"; size = :small)],
            checked = app -> app.config.open_last),
        Command("settings.software", "Software Rendering", toggle_software!;
            label = "Software\nRendering", icon = "chip",
            help = "Draw without the graphics card, for laptops with weak graphics drivers. Takes effect at the next start.",
            places = [Core.Place("Settings", "Rendering")], checked = app -> app.config.software_rendering),
        map_drawing_command("auto", "Auto", "Draw maps with the graphics card when it can, else on the CPU."),
        map_drawing_command("gpu", "Graphics Card",
            "Draw maps with the graphics card. If it cannot draw them here, the CPU does."),
        map_drawing_command("cpu", "CPU", "Draw maps on the CPU, without the graphics card."),
        Command("settings.tabs", "Show Tabs", app -> nothing;
            label = "Show\nTabs", icon = "eye", help = "Hide tabs you do not use. Settings and Help always show.",
            places = [Core.Place("Settings", "Ribbon")], searchable = false),
    ]
end

# A small toggle of the Rendering group for the Map Drawing setting `value`.
map_drawing_command(value::String, label::String, help::String)::Command =
    Command("settings.map_" * value, "Map Drawing: " * label, app -> set_map_drawing!(app, value);
        label = "Map: " * label, icon = "map", help,
        places = [Core.Place("Settings", "Rendering"; size = :small)],
        checked = app -> app.config.map_drawing == value)

# --- The settings ---

function toggle_open_last!(app)
    app.config.open_last = !app.config.open_last
    save_settings!(app)
    return nothing
end

function toggle_software!(app)
    app.config.software_rendering = !app.config.software_rendering
    save_settings!(app)
    toast!(app, :info, SOFTWARE_TOAST)
    return nothing
end

"""
    rendering_env(config) -> Vector{Pair{String,String}}

The environment the window needs for the Software Rendering setting, set before the
window opens (see `main`). On Linux, Mesa's `LIBGL_ALWAYS_SOFTWARE` makes OpenGL use its
software renderer (llvmpipe). On Windows no setting inside the process changes the
OpenGL driver, so it is empty there.
"""
function rendering_env(c::AppConfig)::Vector{Pair{String,String}}
    (c.software_rendering && !Sys.iswindows()) || return Pair{String,String}[]
    return ["LIBGL_ALWAYS_SOFTWARE" => "1"]
end

"""
    set_map_drawing!(app, value)

Draw the maps as `value` says (`"auto"`, `"gpu"` or `"cpu"`, see `choose_mode`) and save the
settings. It takes effect on the next frame (`sync_mode!`).
"""
function set_map_drawing!(app, value::AbstractString)
    value in MAP_DRAWINGS ||
        throw(ArgumentError("map drawing must be \"auto\", \"gpu\" or \"cpu\", not $(repr(value))"))
    app.config.map_drawing = String(value)
    save_settings!(app)
    return nothing
end

"Use distance units `u` (`\"m\"`, `\"km\"` or `\"ft\"`) and save the settings."
function set_distance_units!(app, u::AbstractString)
    u in DISTANCE_UNITS || throw(ArgumentError("distance units must be \"m\", \"km\" or \"ft\", not $(repr(u))"))
    app.config.distance_units = String(u)
    save_settings!(app)
    return nothing
end

"""
Keep colour table `name` for grids and save the settings. Nothing draws grids yet (the
grid views come in plan 4), so the toast says only that it is saved.
"""
function set_grid_colours!(app, name::AbstractString)
    k = findfirst(p -> first(p) == name, Core.colour_tables())
    k === nothing && throw(ArgumentError("there is no colour table $(repr(name))"))
    app.config.grid_colours = String(name)
    save_settings!(app)
    toast!(app, :info, "Saved: $(last(Core.colour_tables()[k])) for grids.";
        sub = "Grid views use it once JuliaMag has them.")
    return nothing
end

"""
    temp_folder_report(folder) -> (free, text)

Check that JuliaMag can write in `folder` (it writes and removes a small file) and how
much room the drive has: `free` bytes and a text such as `"214.3 GB free"`. Throws an
`ArgumentError` with a plain message when the folder is not there or cannot be written.
Runs on the worker.
"""
function temp_folder_report(folder::AbstractString)
    isdir(folder) || throw(ArgumentError("The folder $folder was not found."))
    try
        path, io = mktemp(folder)
        close(io)
        rm(path; force = true)
    catch e
        e isa InterruptException && rethrow()
        throw(ArgumentError("JuliaMag cannot write in the folder $folder."))
    end
    free = Int(Base.diskstat(folder).available)
    return (free = free, text = file_size_text(free) * " free")
end

"Temp Folder...: pick a folder, check it on the worker, keep it and say how much room it has."
function pick_temp_folder!(app)
    start = isempty(app.config.temp_folder) ? tempdir() : app.config.temp_folder
    folder = ask_folder(app; title = "Temp Folder", start)
    isempty(folder) && return nothing
    submit!(app, "Check the temp folder", _ -> temp_folder_report(folder);
        done = (a, r) -> begin
            a.config.temp_folder = folder
            save_settings!(a)
            toast!(a, :ok, "Temp folder set. $(r.text)."; sub = folder)
            nothing
        end)
    return nothing
end

# --- Show Tabs ---

"""
    toggle_tab!(app, name)

Hide ribbon tab `name`, or show it again, and save the settings. Settings and Help cannot
be hidden.
"""
function toggle_tab!(app, name::AbstractString)
    name in PINNED_TABS && return nothing
    hidden = app.config.hidden_tabs
    name in hidden ? filter!(!=(name), hidden) : push!(hidden, String(name))
    save_settings!(app)
    return nothing
end

"""
    tabs_menu_items(app) -> Vector{MenuItem}

The rows of the Show Tabs menu: the head "Tabs", then a checked row per tab that is shown.
Settings and Help are checked and greyed: they cannot be hidden. A click keeps the menu open.
"""
function tabs_menu_items(app)::Vector{MenuItem}
    hidden = app.config.hidden_tabs
    items = MenuItem[menu_head("Tabs")]
    for name in tab_order(commands(app), String[])
        push!(items, MenuItem(name; checked = !(name in hidden), stay = true,
            action = a -> toggle_tab!(a, name)))
    end
    for name in PINNED_TABS
        push!(items, MenuItem(name; checked = true, reason = PINNED_TAB_REASON, stay = true))
    end
    return items
end

# --- The custom ribbon items ---

const DEFAULTS_LABEL_W = 84
const DEFAULTS_COMBO_W = 118
const DEFAULTS_ROW_H = 22

"The width of the Defaults item (`.rb-col` with padding 4): label 84, gap 6, combo 118."
defaults_width(scale::Real)::Float32 = fpx(scale, 4 + DEFAULTS_LABEL_W + 6 + DEFAULTS_COMBO_W + 4)

"""
    tabs_menu_width(measure, label; scale = 1) -> Float32

The width of the Show Tabs button: a big button whose last label line ends with a caret
(4 px gap, 8 px caret).
"""
function tabs_menu_width(measure, label::AbstractString; scale::Real = 1)::Float32
    lines = split(label, '\n')
    widths = [measure(String(l), RIBBON_LABEL_SIZE) for l in lines]
    widths[end] += fpx(scale, 4 + 8)
    return max(maximum(widths) + fpx(scale, 14), fpx(scale, 50))
end

"""
    draw_defaults(app, dl, x, top, frame)

The Defaults item: two rows 22 high, 1 px apart, each with a dim label 84 wide and a
small combo 118 wide: "Distance units" (Metres, Kilometres, Feet) and "Grid colours"
(the core's colour tables).
"""
function draw_defaults(app, dl, x::Real, top::Real, frame)
    s = app.window.scale
    f(v) = fpx(s, v)
    c = app.config
    units = [MenuItem(label; checked = c.distance_units == u, action = a -> set_distance_units!(a, u))
             for (u, label) in DISTANCE_LABELS]
    unit_label = something(findfirst(p -> first(p) == c.distance_units, collect(DISTANCE_LABELS)), 1)
    tables = Core.colour_tables()
    colours = [MenuItem(label; checked = c.grid_colours == name, action = a -> set_grid_colours!(a, name))
               for (name, label) in tables]
    k = findfirst(p -> first(p) == c.grid_colours, tables)
    rows = (("Distance units", "Used for scale bars, distances and new settings.",
             last(DISTANCE_LABELS[unit_label]), units),
            ("Grid colours", "The default colour table for new grids.",
             k === nothing ? c.grid_colours : last(tables[k]), colours))
    y = Float32(top) + f(1)
    for (label, help, value, items) in rows
        rx = Float32(x) + f(4)
        mid = y + f(DEFAULTS_ROW_H) / 2
        draw_text_mid(dl, FONT_REGULAR, RIBBON_LABEL_SIZE, rx, mid, u32(app.tokens.text_dim), label)
        cb = snap(Box(rx + f(DEFAULTS_LABEL_W + 6), y, rx + f(DEFAULTS_LABEL_W + 6 + DEFAULTS_COMBO_W),
            y + f(DEFAULTS_ROW_H)))
        small_combo!(app, dl, cb, unique_id!(frame, label), "settings.defaults/" * label, value, items; help)
        y += f(DEFAULTS_ROW_H + 1)
    end
    return nothing
end

"""
    small_combo!(app, dl, b, id, owner, value, items; help = "")

A small combo of the ribbon (`.combo.small`) in box `b`: `input` fill, 1 px
`input_border` (`border_strong` and `hover` on hover, an `accent` ring while its menu is
open), radius 5, `value` in 11.5 px 8 px in, a caret 7 px from the right. A click opens
`items` under it.
"""
function small_combo!(app, dl, b::Box, id::String, owner::String, value::AbstractString,
        items::Vector{MenuItem}; help::AbstractString = "")
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    hl = hairline(s)
    open = menu_open(app, owner)
    clicked, hovered, _ = hit(id, b)
    open && keep_menu!(app, owner, b; items)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(hovered ? t.hover : t.input), f(5))
    edge = open ? t.accent : hovered ? t.border_strong : t.input_border
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(edge), f(5), hl)
    open && ig.AddRect(dl, (b.x0 - hl, b.y0 - hl), (b.x1 + hl, b.y1 + hl), u32(t.accent), f(5) + hl, hl)
    mid = centre_y(b)
    caret_x = b.x1 - hl - f(7 + 8)
    draw_caret(dl, caret_x, mid - f(5) / 2, s, u32(t.text_dim))
    tx = b.x0 + hl + f(8)
    draw_text_mid(dl, FONT_REGULAR, RIBBON_LABEL_SIZE, tx, mid, u32(t.text),
        elide(text_width, value, caret_x - f(6) - tx; size = RIBBON_LABEL_SIZE))
    clicked && toggle_menu!(app, owner, b, () -> items; min_width = width(b) / s)
    hovered && item_tip!(app, id; help)
    return nothing
end

"""
    draw_tabs_menu(app, dl, x, top, iw, frame)

The Show Tabs button: a big button (70 high, the 32 px eye, the label under it) whose
last label line ends with a caret. A click opens the Show Tabs menu, which stays open
while tabs are ticked on and off.
"""
function draw_tabs_menu(app, dl, x::Real, top::Real, iw::Real, frame)
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    cmd = frame.model.byid[TABS_MENU_ID]
    b = Box(Float32(x), Float32(top), Float32(x) + Float32(iw), Float32(top) + f(70))
    sb = snap(b)
    owner = TABS_MENU_ID
    open = menu_open(app, owner)
    clicked, hovered, held = hit(unique_id!(frame, button_name(cmd)), sb)
    open && keep_menu!(app, owner, sb; items = tabs_menu_items(app))
    draw_rb_fill(app, dl, sb; enabled = true, hovered, held, on = open)
    draw_icon(dl, cmd.icon, (rnd(b.x0 + (width(b) - px(s, 32)) / 2), rnd(b.y0 + f(5))), 32)
    pitch = f(13.5)
    lines = String.(split(cmd.label, '\n'))
    for (k, line) in enumerate(lines)
        last_line = k == length(lines)
        lw = text_width(FONT_REGULAR, RIBBON_LABEL_SIZE, line)
        full = last_line ? lw + f(4 + 8) : lw
        lx = b.x0 + (width(b) - full) / 2
        mid = b.y0 + f(42) + (k - 1) * pitch + pitch / 2
        draw_text_mid(dl, FONT_REGULAR, RIBBON_LABEL_SIZE, lx, mid, u32(t.text), line; line = 13.5 / 11.5)
        last_line && draw_caret(dl, lx + lw + f(4), mid - f(5) / 2, s, u32(t.text))
    end
    clicked && toggle_menu!(app, owner, sb, () -> tabs_menu_items(app))
    hovered && command_tip!(app, cmd)
    return nothing
end

const TABS_MENU_ID = "settings.tabs"

# --- Getting Started ---

"""
    GETTING_STARTED

The processing chain of airborne magnetic line data, in order: each step's `name`,
`where` it lives in the ribbon, and whether it is in this version (`now`).
"""
const GETTING_STARTED = [
    (name = "Import", where = "Database > Import", now = true),
    (name = "Check the data", where = "Database Tools > Statistics", now = true),
    (name = "Lag correction", where = "Magnetics > Corrections", now = false),
    (name = "Heading correction", where = "Magnetics > Corrections", now = false),
    (name = "Base station correction", where = "Magnetics > Corrections", now = false),
    (name = "Levelling", where = "Magnetics > Levelling", now = false),
    (name = "IGRF removal", where = "Database Tools > Channel Math for now, Magnetics > IGRF later", now = true),
    (name = "Gridding", where = "Grid and Image > Gridding", now = false),
    (name = "Filters", where = "Magnetics > Filters", now = false),
    (name = "Reduction to pole", where = "Magnetics > Filters", now = false),
]

const GETTING_STARTED_TEXT = "The usual chain for airborne magnetic line data, and where each step lives. This first version builds the foundation: import, the tool system and background jobs."

"The Getting Started dialog (Help > Getting Started)."
struct GettingStartedDialog end

"""
    draw_modal(app, ::GettingStartedDialog)

As the prototype's `openGettingStarted`: a 560 px dialog with a paragraph and the steps
in a `.recent` list: rows 44 high with the step number in a round badge (`accent` for a
step of this version, else `text_disabled`), the name and where it lives, and a "works
now" (green) or "later" tag at the right. A Close button.
"""
function draw_modal(app, d::GettingStartedDialog)
    draw_dialog(app, d; title = "Getting Started", icon = "help", width = 560, ok_label = "Close",
        cancel_label = nothing, on_ok = () -> filter!(x -> x !== d, app.ui.dialogs)) do
        s = app.window.scale
        t = app.tokens
        f(v) = fpx(s, v)
        hl = hairline(s)
        w = Float32(ig.CalcItemWidth())
        ig.PushItemWidth(min(w, f(HELP_MAX_W)))
        paragraph(app, GETTING_STARTED_TEXT)
        ig.PopItemWidth()
        ig.Dummy((0f0, f(12) - unsafe_load(Ptr{lib.ImGuiStyle}(ig.GetStyle()).ItemSpacing).y))
        pos = ig.GetCursorScreenPos()
        dl = ig.GetWindowDrawList()
        n = length(GETTING_STARTED)
        frame = snap(Box(pos.x, pos.y, pos.x + w, pos.y + 2 * hl + n * f(RECENT_ROW_H)))
        for (k, step) in enumerate(GETTING_STARTED)
            top = frame.y0 + hl + (k - 1) * f(RECENT_ROW_H)
            row = snap(Box(frame.x0 + hl, top, frame.x1 - hl, top + f(RECENT_ROW_H) - (k < n ? hl : 0f0)))
            k < n && ig.AddRectFilled(dl, (row.x0, row.y1), (row.x1, row.y1 + hl), u32(t.border))
            mid = centre_y(row)
            bx = row.x0 + f(14)
            # The `.badge`: 16 high, at least 16 wide, padding 5, round ends.
            num = string(k)
            nw = text_width(FONT_SEMIBOLD, BADGE_FONT_SIZE, num)
            badge = snap(Box(bx, mid - f(8), bx + badge_width(s, num), mid + f(8)))
            ig.AddRectFilled(dl, (badge.x0, badge.y0), (badge.x1, badge.y1),
                u32(step.now ? t.accent : t.text_disabled), f(8))
            draw_text_mid(dl, FONT_SEMIBOLD, BADGE_FONT_SIZE, (badge.x0 + badge.x1 - nw) / 2, mid,
                u32(t.on_accent), num; line = 1)
            tag = step.now ? "works now" : "later"
            tw = text_width(FONT_REGULAR, 10, tag) + f(8) + 2 * hl
            tag_box = snap(Box(row.x1 - f(14) - tw, mid - f(8), row.x1 - f(14), mid + f(8)))
            tag_col = step.now ? t.green : t.text_dim
            ig.AddRect(dl, (tag_box.x0, tag_box.y0), (tag_box.x1, tag_box.y1), u32(step.now ? t.green : t.border),
                f(4), hl)
            draw_text_mid(dl, FONT_REGULAR, 10, tag_box.x0 + hl + f(4), centre_y(tag_box), u32(tag_col), tag;
                line = 1.4)
            tx = bx + widest_badge(s, n) + f(12)   # one column for every name
            lines_top = mid - f(12.5 * 1.25 + 2 + 11.5 * 1.25) / 2
            draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, tx, lines_top + f(12.5 * 1.25) / 2, u32(t.text), step.name)
            draw_text_mid(dl, FONT_REGULAR, 11.5, tx, lines_top + f(12.5 * 1.25 + 2) + f(11.5 * 1.25) / 2,
                u32(t.text_dim), elide(text_width, step.where, tag_box.x0 - f(12) - tx; size = 11.5))
        end
        ig.AddRect(dl, (frame.x0, frame.y0), (frame.x1, frame.y1), u32(t.border), f(8), hl)
        ig.Dummy((w, height(frame)))
    end
    return nothing
end

# --- The Help dialogs ---

function handle_request!(app, r::OpenDialog)
    if r.which === :shortcuts
        open_shortcuts!(app)
    elseif r.which === :getting_started
        any(d -> d isa GettingStartedDialog, app.ui.dialogs) || push_dialog!(app, GettingStartedDialog())
    elseif r.which === :about
        open_backstage!(app, :about)
    else
        return false
    end
    return true
end

"The width of the widest step badge, \"1\" to \"n\": the names start in one column after it."
widest_badge(scale::Real, n::Integer)::Float32 = maximum(k -> badge_width(scale, string(k)), 1:n)
