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
grid "Regional_TMI_GA2019" whose folder is missing. `vmin` and `vmax` are the value
range the grid reports.
"""
function kangaroo_data(; vmin::Real = -260.3, vmax::Real = 607.1)
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
    g.vmin, g.vmax, g.count = vmin, vmax, 320_000
    Core.save_grid_meta(g)
    Core.add_item!(p, Core.ProjectItem(gid, Core.ITEM_GRID, "KH2024_MAG_IGRF", "grids/$gid", "", ""))
    Core.add_item!(p, Core.ProjectItem(Core.new_item_id(p, Core.ITEM_GRID), Core.ITEM_GRID,
        "Regional_TMI_GA2019", "grids/gone", "", ""))
    Core.save_project(p)
    return s
end

"""
    with_tools(f, specs)

Register the test tools `specs`, run `f()`, and take them out again, all of them, also
when a register or an unregister throws (the first error is thrown again at the end).
"""
function with_tools(f, specs::Vector{Core.ToolSpec})
    try
        foreach(Core.register_tool!, specs)
        return f()
    finally
        failure = nothing
        for spec in specs
            try
                Core.unregister_tool!(spec.id)
            catch e
                failure === nothing && (failure = e)
            end
        end
        failure === nothing || throw(failure)
    end
end

"""
    open_form_now(app, owner; kwargs...) -> Form

`open_form(app, owner; kwargs...)`, then wait for the worker, so the dialog is open.
Returns the form of the new top dialog.
"""
function open_form_now(app::UI.AppState, owner; kwargs...)
    n = length(app.ui.dialogs)
    UI.open_form(app, owner; kwargs...)
    wait_drained(app)
    length(app.ui.dialogs) == n + 1 || error("open_form_now: no dialog opened")
    return last(app.ui.dialogs).form
end

"""
    every_setting_tool(; id = "test.every_setting", mode = :quick) -> ToolSpec

A test tool with one setting of every type, for the widget shots. Its run writes one
line of report text.
"""
every_setting_tool(; id::AbstractString = "test.every_setting", mode::Symbol = :quick) =
    Core.ToolSpec(id, "Every setting", "A test tool with one setting of every type.", "tools",
        [Core.Place("Test", "Test")], ["database" => Core.ITEM_DATABASE],
        Core.SettingSpec[
            Core.NumberSetting("factor", "Factor"; default = 2.5, min = 0, unit = "nT",
                help = "A number with a unit."),
            Core.NumberSetting("cell", "Cell size"; default = nothing, auto = true, unit = "m"),
            Core.TextSetting("note", "Note"; default = "Survey 2024", help = "Free text."),
            Core.ExprSetting("expr", "Expression"; default = "OUT = MAG * 2"),
            Core.ChoiceSetting("method", "Method", ["near", "linear"]; labels = ["Nearest", "Linear"]),
            Core.ChoiceSetting("table", "Colour table", ["rainbow", "geosoft", "grey", "clra"];
                labels = ["Rainbow", "Geosoft", "Grey", "Clra"]),
            Core.BoolSetting("protect", "Protect the output"; default = true),
            Core.FileSetting("file", "File"; extensions = [".xyz"], default = "/data/survey.xyz"),
            Core.ChannelSetting("channel", "Channel"),
            Core.ChannelSetting("out", "Output channel"; allow_new = true, default = "MAG_OUT"),
            Core.ChannelListSetting("channels", "Channels"),
            Core.LinesSetting("lines", "Lines"),
            Core.CRSSetting("crs", "Coordinate system"; default = "EPSG:7855"),
            Core.PairSetting("pair", "Position pair"),
            Core.ExtentSetting("area", "Area"; default = [1.0, 2.0, 3.0, 4.0]),
            Core.PointSetting("origin", "Origin"),
            Core.ItemSetting("grid", "Grid", Core.ITEM_GRID; optional = true),
        ], mode, (s, ins, st, progress, report) -> (println(report, "Every setting ran."); nothing))

"""
    sleep_tool(seconds; id = "test.sleep") -> ToolSpec

A quick test tool that sleeps `seconds` and then says so.
"""
sleep_tool(seconds::Real; id::AbstractString = "test.sleep") =
    Core.ToolSpec(id, "Sleep", "Sleeps.", "clock", Core.Place[], ["database" => Core.ITEM_DATABASE],
        Core.SettingSpec[], :quick, (s, ins, st, progress, report) -> (sleep(seconds); println(report, "Slept."); nothing))

"""
    small_xyz(name = "small.xyz") -> String

A small Geosoft XYZ file in a new temp folder: 2 lines of 20 rows (T13-C1).
"""
function small_xyz(name::AbstractString = "small.xyz")
    path = joinpath(mktempdir(), name)
    write_synthetic_xyz(path; lines = 2, ties = 0, rows_per_line = 20)
    return path
end

"""
    gate_tool(gate = nothing; id = "test.gate", name = "Gate") -> ToolSpec

A test job tool of `steps` steps (a setting, 10 by default). It reports progress after
each step and writes "Step k of n" to its report. At the end it imports a small XYZ file
as the database "<name> output" and returns it, so the job makes one item.

- Without `gate` each step takes 0.3 s, so the job takes about 3 s.
- With a `Channel{Int}` gate the job waits for the test: `put!(gate, k)` lets it run up
  to step `k`. So a test sets the progress itself and never depends on timing.

It checks for cancel between steps and while it waits, unless `cancellable` is false: then
a cancel asked for is never seen, and the job ends as done.
"""
function gate_tool(gate::Union{Nothing,Channel{Int}} = nothing; id::AbstractString = "test.gate",
        name::AbstractString = "Gate", cancellable::Bool = true)
    xyz = small_xyz("gate.xyz")
    run = (s, ins, st, progress, report) -> begin
        n = Int(st["steps"])
        k = 0
        while k < n
            target = gate === nothing ? k + 1 : min(next_gate(gate, progress; cancellable), n)
            for j in k+1:target
                gate === nothing && sleep(0.3)
                cancellable && Core.is_cancelled(progress) && throw(Core.JobCancelled())
                println(report, "Step $j of $n")   # before the progress, which tests wait on
                Core.report(progress, j / n)
            end
            k = max(k, target)
        end
        r = Core.import_xyz(s, xyz; name = "$name output", record = false)
        return Core.ProjectItem[something(r.item)]
    end
    return Core.ToolSpec(id, name, "A test job that steps when the test says.", "clock", Core.Place[],
        Pair{String,Core.ItemKind}[], Core.SettingSpec[Core.NumberSetting("steps", "Steps"; default = 10, min = 1)],
        :job, run)
end

# The next step a gated job may run to. Waits for the test; stops on cancel.
function next_gate(gate::Channel{Int}, progress; cancellable::Bool = true)
    deadline = time() + 30
    while !isready(gate)
        cancellable && Core.is_cancelled(progress) && throw(Core.JobCancelled())
        time() > deadline && error("gate_tool: the test gave no step within 30 s")
        sleep(0.005)
    end
    return take!(gate)
end

"""
    fail_tool(; id = "test.fail", name = "Fail") -> ToolSpec

A test job tool that writes a report line, adds the warning "check the input file" and
then fails with "the input file is bad".
"""
fail_tool(; id::AbstractString = "test.fail", name::AbstractString = "Fail") =
    Core.ToolSpec(id, name, "A test job that fails.", "error", Core.Place[], Pair{String,Core.ItemKind}[],
        Core.SettingSpec[], :job, (s, ins, st, progress, report) -> begin
            println(report, "Reading the input file")
            Core.report(progress, 0.25)
            Core.job_warning!("check the input file")
            throw(Core.ToolError("the input file is bad"))
        end)

"""
    fake_job_row(; kwargs...) -> JobRow

A `JobRow` for logic tests, with a `Core.Job` of its own (no session, no task).
`progress` sets the job's live progress; `status` its live status.
"""
function fake_job_row(; id::AbstractString = "job-1", command::AbstractString = "test.tool",
        kind::Symbol = :tool, title::AbstractString = "Test Tool",
        args::AbstractDict = Dict{String,Any}(), names::AbstractDict = Dict{String,String}(),
        expression::AbstractString = "", started::AbstractString = "2026-10-30T10:43:02.100+1000",
        finished::AbstractString = "2026-10-30T10:43:04.200+1000", status::Core.JobStatus = Core.JOB_DONE,
        error::AbstractString = "", outputs::Vector{String} = String[], warnings::Vector{String} = String[],
        progress::Real = status == Core.JOB_RUNNING ? 0.0 : 1.0)
    a = Dict{String,Any}(String(k) => v for (k, v) in args)
    job = Core.Job(String(id), String(command), a, Threads.Atomic{Int}(Int(status)),
        Threads.Atomic{Float64}(Float64(progress)), Threads.Atomic{Bool}(false), String(started),
        status == Core.JOB_RUNNING ? "" : String(finished), Core.JobReport(), copy(warnings), copy(outputs),
        String(error), nothing)
    return UI.JobRow(job, String(id), String(command), kind, String(title), copy(a),
        Dict{String,String}(String(k) => String(v) for (k, v) in names), String(expression), job.started,
        job.finished, status, String(error), copy(outputs), copy(warnings))
end

"""
    add_finished_jobs!(s, n)

Put `n` finished XYZ import jobs into session `s` at once, as a long job history loaded
from disk: every 50th failed with two warnings, the rest done. No work runs.
"""
function add_finished_jobs!(s::Core.Session, n::Integer)
    lock(s.jobs_lock) do
        for k in 1:n
            id = "job-$(s.next_job)"
            s.next_job += 1
            failed = k % 50 == 0
            args = Dict{String,Any}("path" => "/data/line_$k.xyz", "mode" => "new", "name" => "")
            error = failed ? "the file ended in the middle of line $k, so nothing was read from it" : ""
            push!(s.jobs, Core.Job(id, "import.geosoft_xyz", args,
                Threads.Atomic{Int}(Int(failed ? Core.JOB_FAILED : Core.JOB_DONE)), Threads.Atomic{Float64}(1.0),
                Threads.Atomic{Bool}(false), "2026-10-31T09:15:02.100Z", "2026-10-31T09:15:04.200Z",
                Core.JobReport(), failed ? ["line 3 is short", "no CRS"] : String[], String[], error, nothing))
        end
    end
    Core.bump!(s)
    return nothing
end

"""
    add_warning_jobs!(s, n, word)

Put `n` done jobs into session `s`, each with three warnings of `word` 40 times. Narrow
letters ("ii") wrap to fewer lines than a card's estimate, wide ones ("WW") to more.
"""
function add_warning_jobs!(s::Core.Session, n::Integer, word::AbstractString)
    warning = join(fill(word, 40), " ")
    lock(s.jobs_lock) do
        for _ in 1:n
            id = "job-$(s.next_job)"
            s.next_job += 1
            push!(s.jobs, Core.Job(id, "import.geosoft_xyz", Dict{String,Any}("path" => "/data/$id.xyz"),
                Threads.Atomic{Int}(Int(Core.JOB_DONE)), Threads.Atomic{Float64}(1.0), Threads.Atomic{Bool}(false),
                "2026-10-31T09:15:02.100Z", "2026-10-31T09:15:04.200Z", Core.JobReport(),
                [warning, warning, warning], String[], "", nothing))
        end
    end
    Core.bump!(s)
    return nothing
end

"Take the jobs whose ids are in `ids` out of session `s`, as clearing finished jobs would."
function drop_jobs!(s::Core.Session, ids)
    lock(() -> filter!(j -> !(j.id in ids), s.jobs), s.jobs_lock)
    Core.bump!(s)
    return nothing
end
