# App state and project snapshots.
#
# The render thread draws from a `Snapshot`: an immutable copy of what the UI shows of the
# session. `snapshot(s)` builds it off the render thread (see `refresh!` in worker.jl),
# and `app.snap` is replaced whole when a new one is ready.

"An item of the project, as the Data tree shows it."
struct ItemRow
    id::String
    kind::Core.ItemKind
    name::String
    "True when the item's folder or file is gone."
    missing::Bool
    "The id of the job that made it, or `\"\"`."
    made_by::String
    "Why the item is busy (the core's busy reason), or `\"\"`."
    busy::String
end

"A line of a database."
struct LineRow
    id::Core.LineId
    name::String
    selected::Bool
    flight::Int
    nrows::Int
end

"A channel of a database. `eltype` is the element type's name, such as `\"Float64\"`."
struct ChannelRow
    name::String
    label::String
    units::String
    role::Core.ChannelRole
    eltype::String
    protected::Bool
    arraylen::Int
    decimals::Int
    format::Symbol
    width::Int
end

"""
A database item, read once per snapshot. When it cannot be read, `error` holds the
message and the lists are empty.
"""
struct DatabaseView
    id::String
    lines::Vector{LineRow}
    channels::Vector{ChannelRow}
    pairs::Vector{Core.PositionPair}
    "Index into `pairs`, 0 for none."
    current_pair::Int
    rows::Int
    error::String
end

DatabaseView(id::String, error::String) =
    DatabaseView(id, LineRow[], ChannelRow[], Core.PositionPair[], 0, 0, error)

"""
A grid item, read once per snapshot. When it cannot be read, `error` holds the
message and the numbers are 0.
"""
struct GridView
    id::String
    nx::Int
    ny::Int
    dx::Float64
    dy::Float64
    x0::Float64
    y0::Float64
    rotation::Float64
    crs::String
    units::String
    eltype::String
    vmin::Float64
    vmax::Float64
    count::Int
    error::String
end

GridView(id::String, error::String) =
    GridView(id, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, "", "", "", NaN, NaN, 0, error)

"""
A job of the session.

`status` is the status at snapshot time; a job card reads the live `Core.status(job)`
and `job.progress[]`. `error` and `outputs` are empty while the job runs.
`title` is the name of the tool, importer or exporter; `target` names what the job
works on: an item name or a file name, or `\"\"`.
"""
struct JobRow
    job::Core.Job
    id::String
    command::String
    title::String
    target::String
    started::String
    finished::String
    status::Core.JobStatus
    error::String
    outputs::Vector{String}
    warnings::Vector{String}
end

"""
What the UI shows of a session at one revision. Never changed after it is built.

- `revision`: `Core.revision(s)` when the build started. A change during the build
  makes the next `refresh!` build again.
- `items`: in project order. `databases` and `grids`: by item id.
- `jobs`: newest first.
- `undo_label`, `redo_label`: the label of the step `undo!` or `redo!` would run, or `nothing`.
- `cursor`: a copy of the session cursor, or `nothing`; `marked`: `(first, last)` or `nothing`.
"""
struct Snapshot
    revision::Int
    project_name::String
    folder::String
    items::Vector{ItemRow}
    databases::Dict{String,DatabaseView}
    grids::Dict{String,GridView}
    jobs::Vector{JobRow}
    undo_label::Union{Nothing,String}
    redo_label::Union{Nothing,String}
    warnings::Vector{String}
    cursor::Union{Nothing,Core.Cursor}
    marked::Union{Nothing,Tuple{Int,Int}}
end

copy_item(it::Core.ProjectItem) =
    Core.ProjectItem(it.id, it.kind, it.name, it.path, it.description, it.made_by)

"""
    snapshot(s)::Snapshot

Copy what the UI shows of session `s`. Call it off the render thread.

It holds `s.lock` (and inside it `s.jobs_lock`, in the core's lock order) only while it
copies lists. It opens each database and grid after the locks are released, once each.
A missing or broken item gives `missing = true` or an `error` text; it never throws.

An open that fails is tried once more while holding `s.lock`. Session edits that move an
item's files (renaming or deleting a channel, and their undo) hold `s.lock`, so a read
in the middle of one is not shown as an error. Appends cannot cause such a failure: the
core writes the rows before `database.json` names them.
"""
function snapshot(s::Core.Session)::Snapshot
    rev = Core.revision(s)   # first, so a change during the build is seen as new
    p = s.project
    name, items, busy, undo_label, redo_label, cursor, marked, jobs = lock(s.lock) do
        busy = Dict{String,String}(id => Core.busy_reason(m) for (id, m) in s.busy)
        c = s.cursor
        (p.name, map(copy_item, p.items), busy,
            isempty(s.undo_stack) ? nothing : last(s.undo_stack).label,
            isempty(s.redo_stack) ? nothing : last(s.redo_stack).label,
            c === nothing ? nothing : Core.Cursor(c.item, c.line, c.row),
            s.marked, Core.jobs(s))
    end
    warns = Core.warnings(s)

    relock = f -> lock(f, s.lock)
    rows = ItemRow[]
    databases = Dict{String,DatabaseView}()
    grids = Dict{String,GridView}()
    for it in items
        gone = Core.item_missing(p, it)
        push!(rows, ItemRow(it.id, it.kind, it.name, gone, it.made_by, get(busy, it.id, "")))
        if it.kind == Core.ITEM_DATABASE
            databases[it.id] = database_view(p, it, gone, relock)
        elseif it.kind == Core.ITEM_GRID
            grids[it.id] = grid_view(p, it, gone, relock)
        end
    end
    names = Dict{String,String}(it.id => it.name for it in items)
    titles = command_titles()
    job_rows = JobRow[job_row(j, titles, names) for j in jobs]
    return Snapshot(rev, name, p.folder, rows, databases, grids, job_rows, undo_label,
        redo_label, warns, cursor, marked)
end

missing_text(it::Core.ProjectItem) = "The folder of $(it.name) is missing."

# The message for an item that cannot be read. Unlike `user_message` it does not log:
# a broken item stays broken, and the snapshot is built again after every change.
function read_error(@nospecialize(e))::String
    e isa USER_ERRORS && return plain_message(e)
    return "It cannot be read: " * sprint(showerror, e)
end

"""
    open_item(open, p, it, relock)

`open(folder)` for item `it`, or the exception it threw. A failed open is tried once
more inside `relock(f)`, which runs `f()` while holding the session lock.
"""
function open_item(open::Function, p::Core.Project, it::Core.ProjectItem, relock::Function)
    # `item_path` is internal to the core: the item's folder from its relative path.
    folder = Core.item_path(p, it)
    try
        return open(folder)
    catch e
        e isa InterruptException && rethrow()
    end
    try
        return relock(() -> open(folder))
    catch e
        e isa InterruptException && rethrow()
        return e
    end
end

function database_view(p::Core.Project, it::Core.ProjectItem, gone::Bool,
        relock::Function)::DatabaseView
    gone && return DatabaseView(it.id, missing_text(it))
    db = open_item(Core.open_database, p, it, relock)
    db isa Core.LineDatabase || return DatabaseView(it.id, read_error(db))
    lines = LineRow[LineRow(l.id, Core.line_name(l.id), l.selected, l.flight, l.nrows)
                    for l in db.lines]
    channels = ChannelRow[ChannelRow(c.name, c.label, c.units, c.role, string(c.eltype),
        c.protected, c.arraylen, c.decimals, c.format, c.width) for c in db.channels]
    pairs = Core.PositionPair[Core.PositionPair(q.x, q.y, q.crs) for q in db.pairs]
    return DatabaseView(it.id, lines, channels, pairs, db.current_pair, Core.total_rows(db), "")
end

function grid_view(p::Core.Project, it::Core.ProjectItem, gone::Bool, relock::Function)::GridView
    gone && return GridView(it.id, missing_text(it))
    g = open_item(Core.open_grid, p, it, relock)
    g isa Core.Grid || return GridView(it.id, read_error(g))
    return GridView(it.id, g.nx, g.ny, g.dx, g.dy, g.x0, g.y0, g.rotation, g.crs, g.units,
        string(g.eltype), g.vmin, g.vmax, g.count, "")
end

# The names of every tool, importer and exporter, by id.
function command_titles()::Dict{String,String}
    titles = Dict{String,String}()
    for t in Core.tools()
        titles[t.id] = t.name
    end
    for i in Core.importers()
        titles[i.id] = i.name
    end
    for e in Core.exporters()
        titles[e.id] = e.name
    end
    return titles
end

# What a job works on: its item, else its first input item, else its file.
function job_target(args::AbstractDict, names::Dict{String,String})::String
    id = get(args, "item", nothing)
    id isa AbstractString && return get(names, id, String(id))
    inputs = get(args, "inputs", nothing)
    if inputs isa AbstractDict && !isempty(inputs)
        id = inputs[minimum(keys(inputs))]
        id isa AbstractString && return get(names, id, String(id))
    end
    path = get(args, "path", nothing)
    path isa AbstractString && return basename(path)
    return ""
end

function job_row(j::Core.Job, titles::Dict{String,String}, names::Dict{String,String})::JobRow
    st = Core.status(j)
    running = st == Core.JOB_RUNNING
    # `error`, `outputs` and `finished` are written once, before the status leaves running.
    return JobRow(j, j.id, j.command, get(titles, j.command, j.command),
        job_target(j.args, names), j.started, running ? "" : j.finished, st,
        running ? "" : j.error, running ? String[] : copy(j.outputs), Core.job_warnings(j))
end

"""
    UiState

What the UI shows and where, apart from the project data. Changed on the render thread only.

- `tab`: the ribbon tab; `backstage`, `backstage_page`: the Project page and its page;
  `ribbon_peek`: a collapsed ribbon shown for a moment.
- `left_tab`: `:data` or `:jobs`; `right_tabs`, `right_active`: the open right panes.
- `current_db`: the database item the Database tab acts on, or `""`.
- `selected`: `(kind, item id, sub key)` of the selection in the Data tree, where the sub
  key is a line or channel name or `""`; or `nothing`.
- `expanded`: the keys of expanded tree nodes; `filter`: the Data tree filter text.
- `search`: the command search text while it is open, else `nothing`; `search_index`: its
  highlighted row.
- `dialogs`: the modal stack, bottom first. Only modal dialogs go here: a dialog in the
  stack means "a modal is open" (see `handle_shortcuts!`). Change it with `push_dialog!`
  and `pop_dialog!`. `drawn_dialogs`: each dialog drawn in the last frame with its ImGui
  popup id, so a dialog that left the stack also leaves ImGui's popup stack.
- `tooltip_since`, `tooltip_id`: when the mouse came onto the item with that id.
  `tip`: the tooltip to draw at the end of this frame, or `nothing`; `tip_hovered`: an
  item with a tooltip is hovered in this frame.
- `requests`: what commands asked the UI to open (Task 8); each frame handles and empties it.
"""
Base.@kwdef mutable struct UiState
    tab::String = "Database"
    backstage::Bool = false
    backstage_page::Symbol = :start
    ribbon_peek::Bool = false
    left_tab::Symbol = :data
    right_tabs::Vector{Symbol} = Symbol[]
    right_active::Symbol = :none
    current_db::String = ""
    selected::Union{Nothing,Tuple{Symbol,String,String}} = nothing
    expanded::Set{String} = Set{String}()
    filter::String = ""
    search::Union{Nothing,String} = nothing
    search_index::Int = 0
    dialogs::Vector{Any} = Any[]
    drawn_dialogs::Vector{Tuple{Any,UInt32}} = Tuple{Any,UInt32}[]
    tooltip_since::Float64 = 0.0
    tooltip_id::UInt32 = 0
    tip::Any = nothing
    tip_hovered::Bool = false
    requests::Vector{Any} = Any[]
end

"""
    AppState(config, tokens; session = nothing)

Everything the app holds. The render thread owns it: only the render thread changes it,
and the worker hands results back through `drain!`.

- `config`, `tokens`: the settings and the colours in use.
- `session`: the open project, or `nothing`. Change it only with `set_session!`.
- `snap`: the latest `Snapshot` of `session`, replaced whole; `refreshing`: a build runs.
- `queue`: the `Worker` that runs every core call; `busy`: the label of its running action.
- `ui`: the `UiState`; `toasts`: the toasts shown, oldest first.
- `window`: the app window once the loop has drawn a frame, else `nothing`.
- `seen_warnings`: how many session warnings have been shown as toasts.
- `config_dir`: the folder that holds `settings.json`; the app saves its settings there.
- `command_cache`: what `commands(app)` built last (see commands.jl).

The constructor starts the worker. Stop it with `stop_worker!(app.queue)`.
"""
mutable struct AppState
    config::AppConfig
    tokens::Tokens
    session::Union{Nothing,Core.Session}
    snap::Union{Nothing,Snapshot}
    refreshing::Bool
    queue::Worker
    ui::UiState
    toasts::Vector{Toast}
    window::Union{Nothing,Window}
    seen_warnings::Int
    busy::Union{Nothing,String}
    config_dir::String
    command_cache::Any
end

AppState(config::AppConfig, tokens::Tokens; session::Union{Nothing,Core.Session} = nothing,
        config_dir::AbstractString = JuliaMagUI.config_dir()) =
    AppState(config, tokens, session, nothing, false, Worker(), UiState(), Toast[], nothing, 0,
        nothing, String(config_dir), nothing)

"""
    set_session!(app, s)

Make `s` (a session or `nothing`) the app's project. This is the only way to change
`app.session`. It drops everything that belongs to the old project: the snapshot (a
build of the old session that comes back later is dropped too), the count of shown
warnings, a failed build, the Data tree's current database, selection, expanded
nodes and filter, the open dialogs and the requests not handled yet (they were made for
the old project). Call it on the render thread. It does not close the old session.
"""
function set_session!(app::AppState, s::Union{Nothing,Core.Session})
    app.session = s
    app.command_cache = nothing
    app.snap = nothing
    app.refreshing = false
    app.seen_warnings = 0
    app.queue.failed = nothing
    ui = app.ui
    ui.current_db = ""
    ui.selected = nothing
    empty!(ui.expanded)
    ui.filter = ""
    empty!(ui.dialogs)   # the next frame also closes their ImGui popups
    empty!(ui.requests)
    return nothing
end
