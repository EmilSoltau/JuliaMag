# The command list: one `Command` per core tool, importer and exporter, plus the shell's own.
#
# A command's `run` never calls code that draws. It either acts at once (undo, theme,
# line selection) or pushes a request onto `app.ui.requests`. `handle_requests!(app)`
# hands each request to `handle_request!`, and later tasks add methods for the requests
# they own. A request that nobody handles is dropped.

# --- Requests ---

"Open the settings dialog of tool `id`, for `item` when it is set."
struct OpenToolDialog
    id::String
    item::Union{Nothing,String}
end
OpenToolDialog(id::AbstractString; item::Union{Nothing,AbstractString} = nothing) =
    OpenToolDialog(String(id), item === nothing ? nothing : String(item))

"Ask for a file, then open the import dialog of importer `importer_id`."
struct OpenImport
    importer_id::String
end

"Open the export dialog of exporter `exporter_id` for item `item` (`nothing`: the first of its kind)."
struct OpenExport
    exporter_id::String
    item::Union{Nothing,String}
end
OpenExport(exporter_id::AbstractString, item::Union{Nothing,AbstractString} = nothing) =
    OpenExport(String(exporter_id), item === nothing ? nothing : String(item))

"Open the Project backstage on `page` (`:start`, `:new`, `:open`, ...)."
struct OpenBackstage
    page::Symbol
end

"Open a dialog: `:shortcuts`, `:getting_started` or `:about`."
struct OpenDialog
    which::Symbol
end

"Show a side pane: `:tools` or `:jobs`."
struct OpenPane
    which::Symbol
end

"Close the project (the close waits for running jobs)."
struct CloseProject end

"""
    handle_request!(app, request) -> Bool

Act on one request and return `true`, or return `false` when this task does not know it.
Later tasks add a method for each request type they own.
"""
handle_request!(app, @nospecialize(request)) = false

"""
    handle_requests!(app)

Hand every request of `app.ui.requests` to `handle_request!` and empty the list.
A request that no method handles is dropped with a `@debug` message.
A handler that throws is logged and shown as an error toast; the other requests still run.
When a handler changes the project (`set_session!`), the rest of the batch is dropped:
it was made for the old project.
Requests that a handler pushes wait for the next frame.
Call it on the render thread once per frame.
"""
function handle_requests!(app)
    requests = app.ui.requests
    isempty(requests) && return nothing
    batch = copy(requests)
    empty!(requests)
    session = app.session
    for (k, r) in enumerate(batch)
        if app.session !== session
            @debug "The project changed; requests for the old one are dropped" requests = batch[k:end]
            break
        end
        handled = try
            handle_request!(app, r)
        catch e
            e isa InterruptException && rethrow()
            toast!(app, :error, safe_user_message(e, catch_backtrace()))
            true
        end
        handled === true || @debug "No handler for this request, dropped" request = r
    end
    return nothing
end

request!(app, r) = (push!(app.ui.requests, r); nothing)

# --- Commands ---

"""
    Command

One thing the user can do. The ribbon, the menus, the command search and the shortcuts all
read this list.

- `name`: title case, ends with `...` when it opens a dialog; `label`: the ribbon label,
  `\\n` for two lines; `icon`: a prototype icon name.
- `places`: where the ribbon shows it; `shortcut`: such as `"Ctrl+K"`, or `""`.
- `enabled(app)`: `nothing` when the command can run, else the reason as a sentence.
  It reads only `app.session` and `app.snap`, so it is safe on the render thread.
- `run(app)`: acts at once or pushes a request. `checked(app)`: the state of a toggle.
- `searchable`: shown in the command search; `menu`: ids of the commands in the menu of a split button.
"""
struct Command
    id::String
    name::String
    label::String
    icon::String
    help::String
    places::Vector{Core.Place}
    shortcut::String
    enabled::Function
    run::Function
    checked::Function
    searchable::Bool
    menu::Vector{String}
end

function Command(id::AbstractString, name::AbstractString, run::Function;
        label::AbstractString = ribbon_label(name), icon::AbstractString = FALLBACK_ICON,
        help::AbstractString = "", places::AbstractVector{Core.Place} = Core.Place[],
        shortcut::AbstractString = "", enabled::Function = app -> nothing,
        checked::Function = app -> false, searchable::Bool = true,
        menu::AbstractVector{<:AbstractString} = String[])
    return Command(String(id), String(name), String(label), String(icon), String(help),
        Vector{Core.Place}(places), String(shortcut), enabled, run, checked, searchable,
        Vector{String}(menu))
end

const SMALL_WORDS = ("and", "of", "to", "the", "a", "in", "on", "or", "for")

"""
    title_case(text) -> String

Capitalise each word, as in the prototype ("Set Coordinate System", "CSV and Text").
Small words stay lower case after the first word, and a word that has a capital already
(such as `UTM`) is kept.
"""
function title_case(text::AbstractString)::String
    words = split(text, ' ')
    out = String[]
    for (i, w) in enumerate(words)
        if isempty(w) || any(isuppercase, w)
            push!(out, w)
        elseif i > 1 && w in SMALL_WORDS
            push!(out, w)
        else
            push!(out, uppercasefirst(w))
        end
    end
    return join(out, ' ')
end

"""
    ribbon_label(name) -> String

The name without `...`, on two lines when it is long: the space nearest the middle becomes `\\n`.
"""
function ribbon_label(name::AbstractString)::String
    text = String(strip(replace(name, r"\.\.\.$" => "")))
    length(text) <= 11 && return text
    spaces = findall(==(' '), text)
    isempty(spaces) && return text
    mid = length(text) / 2
    i = spaces[argmin([abs(k - mid) for k in spaces])]
    return text[1:prevind(text, i)] * "\n" * text[nextind(text, i):end]
end

# --- Enabled rules (read `app.session` and `app.snap` only) ---

const NEED_PROJECT = "Open a project first."
const NEED_DATABASE = "Import line data first."
const NEED_GRID = "Import a grid first."
const NEED_MAP = "Create a map first."

has_session(app) = app.session !== nothing

snap_items(app) = app.snap === nothing ? ItemRow[] : app.snap.items
has_item(app, kind::Core.ItemKind) = any(it -> it.kind == kind, snap_items(app))

function need_text(kind::Core.ItemKind)
    kind == Core.ITEM_DATABASE && return NEED_DATABASE
    kind == Core.ITEM_GRID && return NEED_GRID
    return NEED_MAP
end

"The reason a command needing an item of each kind in `kinds` cannot run, or `nothing`."
function needs(app, kinds)
    has_session(app) || return NEED_PROJECT
    for k in kinds
        has_item(app, k) || return need_text(k)
    end
    return nothing
end

"""
    default_item(app, kind) -> Union{Nothing,String}

The item a command acts on: the current database, or the selected grid, else the first
item of that kind in the snapshot.
"""
function default_item(app, kind::Core.ItemKind)::Union{Nothing,String}
    items = snap_items(app)
    ids = [it.id for it in items if it.kind == kind]
    isempty(ids) && return nothing
    if kind == Core.ITEM_DATABASE && app.ui.current_db in ids
        return app.ui.current_db
    end
    sel = app.ui.selected
    sel !== nothing && sel[2] in ids && return sel[2]
    return first(ids)
end

# --- Commands from the core's registries ---

function tool_command(t::Core.ToolSpec)
    kinds = unique(last.(t.inputs))
    item_kind = isempty(kinds) ? nothing : first(kinds)
    return Command(t.id, title_case(t.name) * "...",
        app -> request!(app, OpenToolDialog(t.id; item = item_kind === nothing ? nothing : default_item(app, item_kind)));
        icon = icon_for(t.icon), help = t.help, places = t.places,
        enabled = app -> needs(app, kinds))
end

kind_group(k::Core.ItemKind) = k == Core.ITEM_GRID ? "Grid and Image" : "Database"

function importer_command(i::Core.ImporterSpec)
    return Command(i.id, "Import " * title_case(i.name) * "...", app -> request!(app, OpenImport(i.id));
        label = "Import", icon = icon_for(i.id), help = "Import " * i.name * " from a file.",
        places = [Core.Place(kind_group(i.kind), "Import"; size = :small)],
        enabled = app -> has_session(app) ? nothing : NEED_PROJECT)
end

function exporter_command(e::Core.ExporterSpec)
    return Command(e.id, "Export " * title_case(e.name) * "...",
        app -> request!(app, OpenExport(e.id, default_item(app, e.kind)));
        label = "Export", icon = icon_for(e.id), help = "Export to a " * e.extension * " file.",
        places = [Core.Place(kind_group(e.kind), "Export"; size = :small)],
        enabled = app -> needs(app, (e.kind,)))
end

function import_split(kind::Core.ItemKind, importers)
    mine = [i for i in importers if i.kind == kind]
    id = kind == Core.ITEM_GRID ? "import.grid" : "import.database"
    noun = kind == Core.ITEM_GRID ? "a grid" : "line data"
    first_id = isempty(mine) ? "" : first(mine).id
    return Command(id, "Import", app -> isempty(first_id) || request!(app, OpenImport(first_id));
        label = "Import", icon = "import", help = "Import $noun from a file.",
        places = [Core.Place(kind_group(kind), "Import")],
        enabled = app -> isempty(first_id) ? "No importer is installed." :
                         has_session(app) ? nothing : NEED_PROJECT,
        searchable = false, menu = [i.id for i in mine])
end

function export_split(kind::Core.ItemKind, exporters)
    mine = [e for e in exporters if e.kind == kind]
    id = kind == Core.ITEM_GRID ? "export.grid" : "export.database"
    noun = kind == Core.ITEM_GRID ? "a grid" : "line data"
    first_id = isempty(mine) ? "" : first(mine).id
    return Command(id, "Export", app -> isempty(first_id) || request!(app, OpenExport(first_id, default_item(app, kind)));
        label = "Export", icon = "export", help = "Export $noun to a file.",
        places = [Core.Place(kind_group(kind), "Export")],
        enabled = app -> isempty(first_id) ? "No exporter is installed." : needs(app, (kind,)),
        searchable = false, menu = [e.id for e in mine])
end

# --- Shell commands ---

function undo_enabled(app, redo::Bool)
    has_session(app) || return NEED_PROJECT
    label = app.snap === nothing ? nothing : (redo ? app.snap.redo_label : app.snap.undo_label)
    label === nothing && return redo ? "Nothing to redo." : "Nothing to undo."
    return nothing
end

function run_undo(app, redo::Bool)
    submit!(app, redo ? "Redo" : "Undo", s -> redo ? Core.redo!(s) : Core.undo!(s))
    return nothing
end

"Save the settings on the worker, from a copy, so the render thread keeps changing the original."
function save_settings!(app)
    cfg = deepcopy(app.config)
    dir = app.config_dir
    submit!(app, "Save settings", _ -> save_config(cfg, dir))
    return nothing
end

function apply_tokens!(app, tokens::Tokens)
    app.tokens = tokens
    w = app.window
    w === nothing || set_theme!(w, tokens)
    return nothing
end

"""
    set_theme_mode!(app, mode)

Use theme `mode` now and save the settings. The system theme asks the system on the
worker (it can take a moment), then applies the answer.
"""
function set_theme_mode!(app, mode::ThemeMode)
    app.config.theme = mode
    if mode == THEME_SYSTEM
        submit!(app, "Read system theme", _ -> system_dark();
            done = (app, dark) -> app.config.theme == THEME_SYSTEM &&
                                  apply_tokens!(app, tokens_for(THEME_SYSTEM, dark)))
    else
        apply_tokens!(app, tokens_for(mode, false))
    end
    save_settings!(app)
    return nothing
end

function toggle_theme!(app)
    set_theme_mode!(app, app.tokens === DARK ? THEME_LIGHT : THEME_DARK)
end

function toggle_ribbon!(app)
    app.config.ribbon_collapsed = !app.config.ribbon_collapsed
    save_settings!(app)
    return nothing
end

# The lines of the current database in the snapshot, or `nothing` with the reason.
function current_lines(app)
    has_session(app) || return nothing, NEED_PROJECT
    v = app.snap === nothing ? nothing : get(app.snap.databases, app.ui.current_db, nothing)
    v === nothing && return nothing, NEED_DATABASE
    return v, nothing
end

lines_enabled(app) = last(current_lines(app))

function select_lines(app, flag::Bool)
    v, _ = current_lines(app)
    v === nothing && return nothing
    id = v.id
    ids = Core.LineId[l.id for l in v.lines]
    submit!(app, flag ? "Select all lines" : "Select no lines",
        s -> Core.set_lines_selected!(s, id, ids, flag))
    return nothing
end

theme_command(id, name, mode, icon, help) =
    Command(id, name, app -> set_theme_mode!(app, mode); icon, help,
        places = [Core.Place("Settings", "Theme")],
        checked = app -> app.config.theme == mode)

function shell_commands()::Vector{Command}
    c = Command[]
    push!(c, Command("project.backstage", "Project", app -> request!(app, OpenBackstage(:start));
        icon = "folder", help = "Open the Project page."))
    push!(c, Command("project.new", "New Project...", app -> request!(app, OpenBackstage(:new));
        icon = "new", help = "Make a new project.", shortcut = "Ctrl+N"))
    push!(c, Command("project.open", "Open Project...", app -> request!(app, OpenBackstage(:open));
        icon = "open", help = "Open a project folder.", shortcut = "Ctrl+O"))
    push!(c, Command("project.close", "Close Project", app -> request!(app, CloseProject());
        icon = "close", help = "Close the project.", enabled = app -> has_session(app) ? nothing : NEED_PROJECT))
    push!(c, Command("session.undo", "Undo", app -> run_undo(app, false);
        icon = "undo", help = "Undo the last change.", shortcut = "Ctrl+Z",
        enabled = app -> undo_enabled(app, false)))
    push!(c, Command("session.redo", "Redo", app -> run_undo(app, true);
        icon = "redo", help = "Redo the change that was undone.", shortcut = "Ctrl+Y",
        enabled = app -> undo_enabled(app, true)))
    push!(c, Command("ui.command_search", "Command Search", app -> (app.ui.search = ""; app.ui.search_index = 0; nothing);
        icon = "search", help = "Find a command by name.", shortcut = "Ctrl+K",
        places = [Core.Place("Help", "Help")]))
    push!(c, Command("ui.ribbon", "Collapse Ribbon", toggle_ribbon!;
        icon = "chevUp", help = "Hide or show the ribbon.", shortcut = "Ctrl+F1",
        checked = app -> app.config.ribbon_collapsed))
    push!(c, theme_command("ui.theme.light", "Light Theme", THEME_LIGHT, "sun", "Use the light theme."))
    push!(c, theme_command("ui.theme.dark", "Dark Theme", THEME_DARK, "moon", "Use the dark theme."))
    push!(c, theme_command("ui.theme.system", "System Theme", THEME_SYSTEM, "monitor", "Follow the system theme."))
    push!(c, Command("ui.theme.toggle", "Toggle Light and Dark Theme", toggle_theme!;
        icon = "moon", help = "Switch between the light and dark theme.", shortcut = "Ctrl+Shift+L"))
    push!(c, Command("ui.tools_pane", "All Tools", app -> request!(app, OpenPane(:tools));
        icon = "tools", help = "Show the list of all tools.",
        places = [Core.Place("Database Tools", "Find"), Core.Place("Help", "About")],
        checked = app -> :tools in app.ui.right_tabs))
    push!(c, Command("ui.jobs_pane", "Jobs", app -> request!(app, OpenPane(:jobs));
        icon = "play", help = "Show the jobs of the project.",
        checked = app -> :jobs in app.ui.right_tabs))
    push!(c, Command("ui.shortcuts", "Keyboard Shortcuts...", app -> request!(app, OpenDialog(:shortcuts));
        icon = "keyboard", help = "Show the keyboard shortcuts.", places = [Core.Place("Help", "Help")]))
    push!(c, Command("ui.getting_started", "Getting Started...", app -> request!(app, OpenDialog(:getting_started));
        icon = "help", help = "Show the steps from data to map.", places = [Core.Place("Help", "Help")]))
    push!(c, Command("ui.about", "About JuliaMag...", app -> request!(app, OpenDialog(:about));
        label = "About", icon = "about", help = "Show the version and credits.",
        places = [Core.Place("Help", "About")]))
    push!(c, Command("database.select_all_lines", "Select All Lines", app -> select_lines(app, true);
        label = "Select All", icon = "selAll", help = "Select every line of the current database.",
        places = [Core.Place("Database", "Lines"; size = :small, order = 10)], enabled = lines_enabled))
    push!(c, Command("database.select_no_lines", "Select No Lines", app -> select_lines(app, false);
        label = "Select None", icon = "selNone", help = "Deselect every line of the current database.",
        places = [Core.Place("Database", "Lines"; size = :small, order = 11)], enabled = lines_enabled))
    push!(c, Command("database.choose", "Choose Database", app -> nothing;
        label = "Acts on", icon = "database", help = "The database the Database tab acts on.",
        places = [Core.Place("Database", "Database"; order = -100)], searchable = false))
    return c
end

# --- The list ---

# What `commands` built, and the registry sizes it was built for.
struct CommandCache
    sizes::NTuple{3,Int}
    commands::Vector{Command}
end

"""
    commands(app) -> Vector{Command}

Every command: the core's tools, importers and exporters, the four split buttons and the
shell's own. The list is cached. It is built again when a project opens (`set_session!`
clears the cache) and when the number of tools, importers or exporters changes.
"""
function commands(app)::Vector{Command}
    tools, importers, exporters = Core.tools(), Core.importers(), Core.exporters()
    sizes = (length(tools), length(importers), length(exporters))
    cache = app.command_cache
    cache isa CommandCache && cache.sizes == sizes && return cache.commands
    list = Command[]
    append!(list, tool_command.(tools))
    append!(list, importer_command.(importers))
    append!(list, exporter_command.(exporters))
    for kind in (Core.ITEM_DATABASE, Core.ITEM_GRID)
        push!(list, import_split(kind, importers), export_split(kind, exporters))
    end
    append!(list, shell_commands())
    app.command_cache = CommandCache(sizes, list)
    return list
end

"""
    location(cmd) -> String

`"Tab > Group"` of the command's first place, or `""`.
"""
function location(cmd::Command)::String
    isempty(cmd.places) && return ""
    p = first(cmd.places)
    return p.tab * " > " * p.group
end

const FIRST_TABS = ["Database", "Database Tools", "Coordinates", "Grid and Image", "Map"]
const PINNED_TABS = ["Settings", "Help"]

"""
    tab_order(cmds, hidden) -> Vector{String}

The ribbon tabs that hold at least one command: `Database`, `Database Tools`, `Coordinates`,
`Grid and Image`, `Map`, then the others in first-seen order. `Settings` and `Help` are
pinned elsewhere, and the `hidden` tabs are left out.
"""
function tab_order(cmds::AbstractVector{Command}, hidden::AbstractVector{<:AbstractString})::Vector{String}
    seen = String[]
    for c in cmds, p in c.places
        p.tab in seen || push!(seen, p.tab)
    end
    ordered = [t for t in FIRST_TABS if t in seen]
    append!(ordered, t for t in seen if !(t in FIRST_TABS))
    return [t for t in ordered if !(t in PINNED_TABS) && !(t in hidden)]
end
