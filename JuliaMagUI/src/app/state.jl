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
    "The item's folder, relative to the project folder, such as `\"databases/db-1\"`."
    path::String
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
A job of the session, as the Jobs tab shows it.

- `status` is the status at snapshot time. A job card reads the live `Core.status(job)` and
  `job.progress[]` for its bar. `error`, `outputs` and `finished` are empty while it runs.
- `kind`: `:import`, `:export`, `:tool` (a job tool), or `:other` (a command no registry knows).
- `title`: the tool, importer or exporter name in title case, such as "Import Geosoft XYZ";
  the command id when no registry knows it.
- `args`: a copy of the job's args (the settings it ran with).
- `names`: the item names of the project by id, to name the job's items and outputs.
  Every row of a snapshot shares it.
- `expression`: the value of the tool's expression setting (Channel Math), or `""`.
- `started`, `finished`: times such as `"2026-10-30T10:43:02.123+1000"`.
"""
struct JobRow
    job::Core.Job
    id::String
    command::String
    kind::Symbol
    title::String
    args::Dict{String,Any}
    names::Dict{String,String}
    expression::String
    started::String
    finished::String
    status::Core.JobStatus
    error::String
    outputs::Vector{String}
    warnings::Vector{String}
end

"""
    CrsInfo

What the UI shows of a coordinate system code: its `name` (`\"\"` when the code is not
known) and the short `unit` of its first axis, such as `\"m\"` or `\"deg\"` (or `\"\"`).
"""
struct CrsInfo
    name::String
    unit::String
end

"""
What the UI shows of a session at one revision. Never changed after it is built.

- `revision`: `Core.revision(s)` when the build started. A change during the build
  makes the next `refresh!` build again.
- `items`: in project order. `databases` and `grids`: by item id.
- `jobs`: newest first.
- `undo_label`, `redo_label`: the label of the step `undo!` or `redo!` would run, or `nothing`.
- `cursor`: a copy of the session cursor, or `nothing`; `marked`: `(first, last)` or `nothing`.
- `crs`: a `CrsInfo` for every coordinate system code of the pairs and grids.
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
    crs::Dict{String,CrsInfo}
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
            s.marked, [(j, deepcopy(j.args)) for j in Core.jobs(s)])
    end
    warns = Core.warnings(s)

    relock = f -> lock(f, s.lock)
    rows = ItemRow[]
    databases = Dict{String,DatabaseView}()
    grids = Dict{String,GridView}()
    for it in items
        gone = Core.item_missing(p, it)
        push!(rows, ItemRow(it.id, it.kind, it.name, it.path, gone, it.made_by, get(busy, it.id, "")))
        if it.kind == Core.ITEM_DATABASE
            databases[it.id] = database_view(p, it, gone, relock)
        elseif it.kind == Core.ITEM_GRID
            grids[it.id] = grid_view(p, it, gone, relock)
        end
    end
    names = Dict{String,String}(it.id => it.name for it in items)
    infos = command_infos()
    job_rows = JobRow[job_row(j, args, infos, names) for (j, args) in jobs]
    return Snapshot(rev, name, p.folder, rows, databases, grids, job_rows, undo_label,
        redo_label, warns, cursor, marked, crs_infos(databases, grids))
end

# The name and unit of every coordinate system the pairs and grids use.
function crs_infos(databases::Dict{String,DatabaseView}, grids::Dict{String,GridView})
    codes = Set{String}()
    for v in values(databases), q in v.pairs
        push!(codes, q.crs)
    end
    for g in values(grids)
        push!(codes, g.crs)
    end
    out = Dict{String,CrsInfo}()
    for code in codes
        isempty(code) && continue
        out[code] = crs_info(code)
    end
    return out
end

const UNIT_SHORT = Dict("metre" => "m", "meter" => "m", "degree" => "deg", "foot" => "ft",
    "US survey foot" => "ft")

function crs_info(code::String)::CrsInfo
    try
        Core.valid_crs(code) || return CrsInfo("", "")
        unit = Core.crs_axis_unit(code)
        short = unit === nothing ? "" : get(UNIT_SHORT, unit[1], unit[1])
        return CrsInfo(Core.crs_name(code), short)
    catch e
        e isa InterruptException && rethrow()
        return CrsInfo("", "")
    end
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

"""
What a snapshot needs to know of a command: its title, its kind (see `JobRow`) and the
key of its expression setting, or `""`.
"""
struct CommandInfo
    title::String
    kind::Symbol
    expression::String
end

# The title and kind of every tool, importer and exporter, by id.
function command_infos()::Dict{String,CommandInfo}
    infos = Dict{String,CommandInfo}()
    for t in Core.tools()
        k = findfirst(st -> st isa Core.ExprSetting, t.settings)
        infos[t.id] = CommandInfo(owner_title(t), :tool, k === nothing ? "" : t.settings[k].key)
    end
    for i in Core.importers()
        infos[i.id] = CommandInfo(owner_title(i), :import, "")
    end
    for e in Core.exporters()
        infos[e.id] = CommandInfo(owner_title(e), :export, "")
    end
    return infos
end

function job_row(j::Core.Job, args::Dict{String,Any}, infos::Dict{String,CommandInfo},
        names::Dict{String,String})::JobRow
    st = Core.status(j)
    running = st == Core.JOB_RUNNING
    info = get(infos, j.command, CommandInfo(j.command, :other, ""))
    e = isempty(info.expression) ? nothing : get(args, info.expression, nothing)
    # `error`, `outputs` and `finished` are written once, before the status leaves running.
    return JobRow(j, j.id, j.command, info.kind, info.title, args, names,
        e isa AbstractString ? String(e) : "", j.started, running ? "" : j.finished, st,
        running ? "" : j.error, running ? String[] : copy(j.outputs), Core.job_warnings(j))
end

# The size of a text field's buffer, in bytes: names of 200 characters and more fit.
const FIELD_BYTES = 1024

"""
    UiState

What the UI shows and where, apart from the project data. Changed on the render thread only.

- `tab`: the ribbon tab; `backstage`, `backstage_page`: the Project page and its page;
  `ribbon_peek`: a collapsed ribbon shown for a moment.
- `left_tab`: `:data` or `:jobs`; `right_tabs`, `right_active`: the open right panes (such
  as `:tools`) in the order they opened, and the one shown (`:none` when none is open).
- `current_db`: the database item the Database tab acts on, or `""`.
- `selected`: `(kind, item id, sub key)` of the selection in the Data tree, where the sub
  key is a line or channel name or `""`; or `nothing`.
- `expanded`: the keys of expanded tree nodes (see `row_key`); `filter`: the Data tree
  filter text, and `filter_buffer` the bytes its text field edits.
- `tree_scroll`, `props_scroll`: how far the Data tree and the Properties panel are
  scrolled, in device pixels. `tree_focused`: the last click was on the tree, so the
  arrow keys move in it. `tree_reveal`: scroll the selected row into view in the next frame.
  `tree_view`: where the tree was drawn last, in device pixels.
- `tree_cache`: the rows of the Data tree for the last key (a `TreeCache`, see data.jl).
- `tree_drawn`: how many tree rows the last frame drew (tests read it).
- `drag`: the splitter being dragged (a `SplitterDrag`, see panes.jl), or `nothing`.
- `search`: the command search text while it is open, else `nothing`; `search_index`: its
  highlighted row (1 is the first). `search_buffer`: the bytes its text field edits;
  `search_level`: the number of dialogs open under it; `search_scroll`: how far its list is
  scrolled, in device pixels; `search_focus`: give its text field the focus in the next frame;
  `search_cache`: its last results (a `SearchCache`, see search.jl).
- `tools_query`, `tools_buffer`, `tools_scroll`: the Tools pane's search text, the bytes its
  field edits, and how far its list is scrolled.
- `dialogs`: the modal stack, bottom first. Only modal dialogs go here: a dialog in the
  stack means "a modal is open" (see `handle_shortcuts!`). Change it with `push_dialog!`
  and `pop_dialog!`. `drawn_dialogs`: each dialog drawn in the last frame with its ImGui
  popup id, so a dialog that left the stack also leaves ImGui's popup stack.
- `tooltip_since`, `tooltip_id`: when the mouse came onto the item with that id.
  `tip`: the tooltip to draw at the end of this frame, or `nothing`; `tip_hovered`: an
  item with a tooltip is hovered in this frame.
- `requests`: what commands asked the UI to open (Task 8); each frame handles and empties it.
- `ribbon_scroll`: how far the ribbon is scrolled to the left, in device pixels, on tab
  `ribbon_scroll_tab`; another tab starts at 0.
- `menu`: the open drop-down menu (an `OpenMenu`, see menu.jl), or `nothing`.
- `ribbon_cache`: the ribbon's layout and widths for the last key (a `RibbonModel`, see
  ribbon.jl), or `nothing`.
- `jobs_shown`: a job started from a dialog has switched the left pane to Jobs in this
  session (it does that once per session).
- `dialog_places`: where each dialog of the stack was placed, by level (a `DialogPlace`,
  see modal.jl).
- `opening`: the ids of tools, importers and exporters whose dialog the worker is
  preparing; a second open of one waits for the first.
- `jobs_scroll`: how far the Jobs tab is scrolled, in device pixels; `jobs_cache`: its
  cards' layout and the cached card of each job (a `JobsView`, see jobs.jl).
- `job_bars`: where the progress bar of each running job was drawn in the last frame
  (tests read it).
- `jobs_seen`: the status of each job when a snapshot last showed it, so a job that leaves
  running gets one toast; `nothing` until the first snapshot of the project.
  `jobs_watched`: the snapshot that `watch_jobs!` looked at last.
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
    filter_buffer::Vector{UInt8} = zeros(UInt8, FIELD_BYTES)
    tree_scroll::Float32 = 0f0
    props_scroll::Float32 = 0f0
    tree_focused::Bool = false
    tree_reveal::Bool = false
    tree_view::Box = Box(0, 0, 0, 0)
    tree_cache::Any = nothing
    tree_drawn::Int = 0
    drag::Any = nothing
    search::Union{Nothing,String} = nothing
    search_index::Int = 1
    search_buffer::Vector{UInt8} = zeros(UInt8, FIELD_BYTES)
    search_level::Int = 0
    search_scroll::Float32 = 0f0
    search_focus::Bool = false
    search_cache::Any = nothing
    tools_query::String = ""
    tools_buffer::Vector{UInt8} = zeros(UInt8, FIELD_BYTES)
    tools_scroll::Float32 = 0f0
    dialogs::Vector{Any} = Any[]
    drawn_dialogs::Vector{Tuple{Any,UInt32}} = Tuple{Any,UInt32}[]
    tooltip_since::Float64 = 0.0
    tooltip_id::UInt32 = 0
    tip::Any = nothing
    tip_hovered::Bool = false
    requests::Vector{Any} = Any[]
    ribbon_scroll::Float32 = 0f0
    ribbon_scroll_tab::String = ""
    menu::Any = nothing
    ribbon_cache::Any = nothing
    jobs_shown::Bool = false
    dialog_places::Vector{Any} = Any[]
    opening::Set{String} = Set{String}()
    jobs_scroll::Float32 = 0f0
    jobs_cache::Any = nothing
    job_bars::Dict{String,Box} = Dict{String,Box}()
    jobs_seen::Union{Nothing,Dict{String,Core.JobStatus}} = nothing
    jobs_watched::Any = nothing
end

"""
    DrawError

An error that cut frames short (see `note_draw_error!`).

- `key`: tells errors apart: the exception type and the place in JuliaMagUI it came from.
- `text`: what its toast says (from its first report, or its last after a quiet spell).
- `count`: how many frames it cut; `reports`: how often it was logged and toasted.
- `last_seen`: the `time()` it last cut a frame.
- `toast`: its sticky toast while it keeps coming, else `nothing`.
"""
mutable struct DrawError
    key::String
    text::String
    count::Int
    reports::Int
    last_seen::Float64
    toast::Union{Nothing,Toast}
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
- `draw_ns`: how long the last `draw_app` took, in nanoseconds (tests and benchmarks read it).
- `draw_errors`: each different error that cut a frame short (see `guarded_frame`), with
  how often it came. At most `MAX_DRAW_ERRORS`. Tests fail when it is not empty.
- `pick_file`: asks the user for a file, as `pick_file(; save, title, extensions, start)`
  (see `native_pick_file`): the path, or `""` when the user cancelled. Tests replace it.

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
    draw_ns::Int
    draw_errors::Vector{DrawError}
    pick_file::Function
end

AppState(config::AppConfig, tokens::Tokens; session::Union{Nothing,Core.Session} = nothing,
        config_dir::AbstractString = JuliaMagUI.config_dir()) =
    AppState(config, tokens, session, nothing, false, Worker(), UiState(), Toast[], nothing, 0,
        nothing, String(config_dir), nothing, 0, DrawError[], native_pick_file)

"""
    set_session!(app, s)

Make `s` (a session or `nothing`) the app's project. This is the only way to change
`app.session`. It drops everything that belongs to the old project: the snapshot (a
build of the old session that comes back later is dropped too), the count of shown
warnings, a failed build, the Data tree's current database, selection, expanded
nodes, filter, scroll and cached rows, the open dialogs and menu, the requests not
handled yet (they were made for the old project), whether a job has shown the Jobs pane,
and what the Jobs tab knew of the old jobs (so the new project's finished jobs make no
toasts). Call it on the render thread. It does not close the old session.
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
    fill!(ui.filter_buffer, 0x00)
    ui.tree_scroll = 0f0
    ui.props_scroll = 0f0
    ui.tree_focused = false
    ui.tree_reveal = false
    ui.tree_cache = nothing
    empty!(ui.dialogs)   # the next frame also closes their ImGui popups
    empty!(ui.requests)
    ui.menu = nothing
    ui.jobs_shown = false
    empty!(ui.opening)
    ui.jobs_scroll = 0f0
    ui.jobs_cache = nothing
    empty!(ui.job_bars)
    ui.jobs_seen = nothing
    ui.jobs_watched = nothing
    return nothing
end
