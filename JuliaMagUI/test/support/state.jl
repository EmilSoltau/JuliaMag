# Helpers for tests of the app state, the worker queue and snapshots. No window needed.

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
    UI.AppState(UI.AppConfig(), UI.LIGHT; session = s)

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
    session_with(; lines = 3, channels = 2, name = "Survey", rows = 2) -> Session

A fresh session with one database item called `name` that has `lines` lines
(L1001, L1002, ...) of `rows` rows each and `channels` Float64 channels (C1, C2, ...).
The item is the only one in the project.
"""
function session_with(; lines::Integer = 3, channels::Integer = 2, name::AbstractString = "Survey",
        rows::Integer = 2)
    s = fresh_session()
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
