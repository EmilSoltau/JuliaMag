# Helpers for tests of the app state, the worker queue and snapshots. No window needed,
# except for `with_project_app`, which runs the app in a window (support/app.jl).

using Test
import JuliaMagCore as Core
import JuliaMagUI as UI

# `fresh_session`, `make_test_database!`, `add_test_database!`, `testdata`, `write_synthetic_xyz`.
include(joinpath(@__DIR__, "..", "..", "..", "JuliaMagCore", "test", "support", "synthetic.jl"))

"""
    test_app_state(s) -> AppState

An `AppState` on session `s` with the default settings, the light theme, no window
and a running worker. Stop it with `stop_app!`.
"""
test_app_state(s::Union{Nothing,Core.Session}) =
    UI.AppState(UI.AppConfig(), UI.LIGHT; session = s, config_dir = mktempdir())

"""
    stop_app!(app)

Stop the worker and close the session, if it is still open.
"""
function stop_app!(app::UI.AppState)
    UI.stop_worker!(app.queue)
    s = app.session
    s === nothing || !isopen(s) || Core.close_session!(s)
    return nothing
end

"""
    with_app(f, app)

`f(app)`, then `stop_app!(app)`, also when `f` throws, so a failed test leaks no worker
and no open session.
"""
function with_app(f, app::UI.AppState)
    try
        return f(app)
    finally
        stop_app!(app)
    end
end

"""
    with_test_session(f, s)

`f(s)`, then close session `s` if it is still open, also when `f` throws.
"""
function with_test_session(f, s::Core.Session)
    try
        return f(s)
    finally
        isopen(s) && Core.close_session!(s)
    end
end

"""
    wait_drained(app; timeout = 10)

Drain worker results until every submitted action has come back and been handled.
An error after `timeout` seconds.
"""
function wait_drained(app::UI.AppState; timeout::Real = 10)
    deadline = time() + timeout
    while true
        UI.drain!(app)
        app.queue.pending == 0 && return nothing
        left = deadline - time()
        left > 0 || error("wait_drained: $(app.queue.pending) actions still pending after $timeout s")
        timedwait(() -> isready(app.queue.results), left; pollint = 0.002)
    end
end

"""
    refresh_now!(app; timeout = 10)

Run `refresh!` and wait until `app.snap` holds the session's current revision.
"""
function refresh_now!(app::UI.AppState; timeout::Real = 10)
    s = app.session::Core.Session
    deadline = time() + timeout
    while true
        UI.drain!(app)
        UI.refresh!(app)
        !app.refreshing && app.snap !== nothing && app.snap.revision == Core.revision(s) &&
            return nothing
        left = deadline - time()
        left > 0 || error("refresh_now!: no snapshot of revision $(Core.revision(s)) after $timeout s")
        timedwait(() -> isready(app.queue.results), left; pollint = 0.002)
    end
end

"""
    app_with_database() -> AppState

`test_app_state` on a fresh session with `make_test_database!`, the snapshot taken and
`app.ui.current_db` set to the database id.
"""
function app_with_database()
    s = fresh_session()
    id = make_test_database!(s)
    app = test_app_state(s)
    refresh_now!(app)
    app.ui.current_db = id
    return app
end

"""
    session_with(; lines = 3, channels = 2, name = "Survey", rows = 2, project = "p") -> Session

A fresh session of a project called `project` with one database item called `name` that
has `lines` lines (L1001, L1002, ...) of `rows` rows each and `channels` Float64 channels
(C1, C2, ...). The item is the only one in the project.
"""
function session_with(; lines::Integer = 3, channels::Integer = 2, name::AbstractString = "Survey",
        rows::Integer = 2, project::AbstractString = "p")
    s = Core.new_session(joinpath(mktempdir(), "p"), project)
    p = s.project
    id = Core.new_item_id(p, Core.ITEM_DATABASE)
    db = Core.create_database(joinpath(p.folder, "databases", id), id)
    names = ["C$k" for k in 1:channels]
    for n in names
        Core.add_channel!(db, Core.ChannelInfo(n, n, Float64, "nT", Core.ROLE_NONE, :normal, 10,
            -1, false, 1))
    end
    apps = Core.open_appenders(db, names)
    for l in 1:lines
        Core.add_line!(db, Core.LineInfo(Core.LineId(Core.LINE, 1000 + l, 0), 1, "2024-05-01",
            0.0, 0.1, rows, 0, true))
        for a in values(apps), r in 1:rows
            Core.append_value!(a, Float64(l * r))
        end
    end
    Core.close_appenders!(apps)
    Core.save_meta(db)
    Core.add_item!(p, Core.ProjectItem(id, Core.ITEM_DATABASE, String(name), "databases/$id", "", ""))
    Core.save_project(p)
    return s
end

"""
    with_project_app(f, s; kwargs...)

`with_test_app` with session `s` as the app's project: `f(ctx, app)` runs once the first
snapshot is in. The session is closed afterwards.
"""
function with_project_app(f, s::Core.Session; kwargs...)
    try
        return with_test_app(; kwargs...) do ctx
            app = ctx.app_state()
            UI.set_session!(app, s)
            ctx.wait_until(() -> app.snap !== nothing)
            ctx.frames(2)
            f(ctx, app)
        end
    finally
        isopen(s) && Core.close_session!(s)
    end
end

"The project of the prototype: 60 lines and 24 channels in \"Kangaroo Hills 2024\"."
kangaroo() = session_with(lines = 60, channels = 24, name = "Kangaroo Hills 2024",
    project = "Kangaroo Hills 2024")

const KANGAROO_CHANNELS = [
    # name, label, units, role, protected, decimals
    ("TIME", "TIME", "s", Core.ROLE_TIME, true, 1),
    ("X", "X", "m", Core.ROLE_X, true, 1),
    ("Y", "Y", "m", Core.ROLE_Y, true, 1),
    ("LON", "LONGITUDE", "deg", Core.ROLE_LON, true, 6),
    ("LAT", "LATITUDE", "deg", Core.ROLE_LAT, true, 6),
    ("ALT", "RADALT", "m", Core.ROLE_ELEVATION, true, 1),
    ("MAG", "TMI_RAW", "nT", Core.ROLE_NONE, true, 2),
    ("IGRF", "IGRF", "nT", Core.ROLE_NONE, false, 2),
    ("MAG_IGRF", "MAG_IGRF", "nT", Core.ROLE_NONE, false, 2),
]

"""
    kangaroo_data() -> Session

The project of the prototype's Data tab, with its names: the database "Kangaroo Hills 2024"
(50 lines L1001-L1050 and 10 ties T2001-T2010 of flight 12, 172,900 rows, the nine
channels TIME to MAG_IGRF with their roles and units, the pairs X,Y in EPSG:7855
(current) and LON,LAT in EPSG:7844), the grid "KH2024_MAG_IGRF" (400 x 800, 25 m) and the
grid "Regional_TMI_GA2019" whose folder is missing.
"""
function kangaroo_data()
    s = Core.new_session(joinpath(mktempdir(), "p"), "Kangaroo Hills 2024")
    p = s.project
    id = Core.new_item_id(p, Core.ITEM_DATABASE)
    db = Core.create_database(joinpath(p.folder, "databases", id), id)
    for (n, label, units, role, _, dec) in KANGAROO_CHANNELS
        Core.add_channel!(db, Core.ChannelInfo(n, label, Float64, units, role, :normal, 10, dec, false, 1))
    end
    names = first.(KANGAROO_CHANNELS)
    apps = Core.open_appenders(db, names)
    for k in 1:60
        rows = k <= 40 ? 2882 : 2881   # 172,900 rows in all, as the prototype
        lid = k <= 50 ? Core.LineId(Core.LINE, 1000 + k, 0) : Core.LineId(Core.TIE, 1950 + k, 0)
        Core.add_line!(db, Core.LineInfo(lid, 12, "2024-05-01", 0.0, 0.1, rows, 0, true))
        for a in values(apps), r in 1:rows
            Core.append_value!(a, Float64(r))
        end
    end
    Core.close_appenders!(apps)
    for c in db.channels
        c.protected = KANGAROO_CHANNELS[findfirst(x -> x[1] == c.name, KANGAROO_CHANNELS)][5]
    end
    push!(db.pairs, Core.PositionPair("X", "Y", "EPSG:7855"), Core.PositionPair("LON", "LAT", "EPSG:7844"))
    db.current_pair = 1
    Core.save_meta(db)
    Core.add_item!(p, Core.ProjectItem(id, Core.ITEM_DATABASE, "Kangaroo Hills 2024", "databases/$id", "", ""))
    gid = Core.new_item_id(p, Core.ITEM_GRID)
    g = Core.create_grid(joinpath(p.folder, "grids", gid), "KH2024_MAG_IGRF", Float32, 400, 800;
        dx = 25, dy = 25, x0 = 380_000, y0 = 7_905_000, crs = "EPSG:7855", units = "nT")
    g.vmin, g.vmax, g.count = -260.3, 607.1, 320_000
    Core.save_grid_meta(g)
    Core.add_item!(p, Core.ProjectItem(gid, Core.ITEM_GRID, "KH2024_MAG_IGRF", "grids/$gid", "", ""))
    Core.add_item!(p, Core.ProjectItem(Core.new_item_id(p, Core.ITEM_GRID), Core.ITEM_GRID,
        "Regional_TMI_GA2019", "grids/gone", "", ""))
    Core.save_project(p)
    return s
end
