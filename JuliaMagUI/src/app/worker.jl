# The serial worker queue. The render thread never calls the core, except to read job
# atomics. Every other core call is an action that runs here, in submit order, on one task
# of the default thread pool. Results come back through a channel that the render thread
# drains each frame (`drain!`), so app state changes only on the render thread.
#
# The functions here that take `app` take an `AppState` (state.jl, which uses the types here).

# One action for the worker.
struct WorkerAction
    label::String
    f::Function
    done::Function
    session::Union{Nothing,Core.Session}
    window::Union{Nothing,Window}   # woken when the action starts and ends
end

# Messages from the worker and the snapshot task to the render thread.
struct ActionStarted
    label::String
end

struct ActionDone
    action::WorkerAction
    value::Any
    failure::Union{Nothing,CapturedException}
end

struct SnapshotDone
    session::Core.Session
    revision::Int                  # the revision when the build started
    snap::Any                      # a `Snapshot`, or `nothing` when the build failed
    failure::Union{Nothing,CapturedException}
end

"""
    Worker()

The serial worker queue: one task on the default thread pool that runs actions one at a
time, in the order they were submitted. It survives any exception from an action.

- `inbox`: actions waiting to run.
- `results`: messages for the render thread, read by `drain!`.
- `pending`: actions submitted whose result `drain!` has not handled yet.
- `failed`: the session and revision whose snapshot build failed, so `refresh!`
  does not try it again each frame; else `nothing`.
"""
mutable struct Worker
    inbox::Channel{WorkerAction}
    results::Channel{Any}
    task::Task
    pending::Int
    failed::Union{Nothing,Tuple{Core.Session,Int}}
end

function Worker()
    inbox = Channel{WorkerAction}(Inf)
    results = Channel{Any}(Inf)
    task = Threads.@spawn :default run_worker(inbox, results)
    return Worker(inbox, results, task, 0, nothing)
end

# Wake the window, if there is one, so the loop draws the result.
notify_window(w::Union{Nothing,Window}) = (w === nothing || wake!(w); nothing)

function run_worker(inbox::Channel{WorkerAction}, results::Channel{Any})
    for a in inbox
        put!(results, ActionStarted(a.label))
        notify_window(a.window)
        msg = try
            # The worker task keeps the world of its start; an action may be newer code.
            ActionDone(a, Base.invokelatest(a.f, a.session), nothing)
        catch e
            ActionDone(a, nothing, CapturedException(e, catch_backtrace()))
        end
        put!(results, msg)
        notify_window(a.window)
    end
    return nothing
end

"""
    stop_worker!(w)

Take no more actions, let the queued ones finish, and wait for the worker task to end.
"""
function stop_worker!(w::Worker)
    close(w.inbox)
    wait(w.task)
    return nothing
end

"""
    submit!(app, label, f; done = (app, result) -> nothing)

Run `f(session)` on the worker, after the actions submitted before it.
`session` is `app.session` at the time of the call. While `f` runs, `app.busy` is `label`.
On the render thread, `drain!` then calls `done(app, result)` with what `f` returned,
or shows an error toast with `user_message` of what `f` threw.
Call it on the render thread.
"""
function submit!(app, label::AbstractString, f::Function; done::Function = (app, result) -> nothing)
    q = app.queue
    put!(q.inbox, WorkerAction(String(label), f, done, app.session, app.window))
    q.pending += 1
    return nothing
end

"""
    drain!(app)

Handle every message the worker and the snapshot task have sent so far.
Call it on the render thread once per frame. It never blocks.
"""
function drain!(app)
    results = app.queue.results
    while isready(results)
        handle_result!(app, take!(results))
    end
    return nothing
end

handle_result!(app, m::ActionStarted) = (app.busy = m.label; nothing)

function handle_result!(app, m::ActionDone)
    app.queue.pending -= 1
    app.busy = nothing   # the next action's `ActionStarted` sets it again
    if m.failure === nothing
        try
            Base.invokelatest(m.action.done, app, m.value)
        catch e
            toast!(app, :error, user_message(e, catch_backtrace()))
        end
    else
        toast!(app, :error, user_message(m.failure.ex, m.failure.processed_bt))
    end
    return nothing
end

function handle_result!(app, m::SnapshotDone)
    app.refreshing = false
    m.session === app.session || return nothing   # the project changed meanwhile
    if m.failure !== nothing
        app.queue.failed = (m.session, m.revision)
        @error "Could not read the project state" exception = (m.failure.ex, m.failure.processed_bt)
        return nothing
    end
    snap = m.snap::Snapshot
    app.snap = snap
    for k in (app.seen_warnings + 1):length(snap.warnings)
        toast!(app, :warn, sentence(snap.warnings[k]))
    end
    app.seen_warnings = max(app.seen_warnings, length(snap.warnings))
    return nothing
end

handle_result!(app, @nospecialize(m)) = (@debug "Unknown worker message" m; nothing)

"""
    refresh!(app)

Start a new snapshot of the session when it changed. Call it on the render thread each frame.

It starts a build when a session is open, its revision differs from `app.snap`
(or there is no snapshot yet), and no build runs. The build runs on the default
thread pool and comes back through the worker results; `drain!` puts it in `app.snap`
and shows each new session warning once, as a `:warn` toast.
"""
function refresh!(app)
    s = app.session
    (s === nothing || app.refreshing || !isopen(s)) && return nothing
    rev = Core.revision(s)
    app.snap !== nothing && app.snap.revision == rev && return nothing
    failed = app.queue.failed
    failed !== nothing && failed[1] === s && failed[2] == rev && return nothing
    app.refreshing = true
    results, window = app.queue.results, app.window
    Threads.@spawn :default begin
        msg = try
            SnapshotDone(s, rev, snapshot(s), nothing)
        catch e
            SnapshotDone(s, rev, nothing, CapturedException(e, catch_backtrace()))
        end
        put!(results, msg)
        notify_window(window)
    end
    return nothing
end

# The core's errors that carry a message for the user.
const USER_ERRORS = Union{Core.ToolError,Core.ProtectedError,Core.ItemBusyError,
    Core.ProjectLockedError,Core.SessionClosedError,Core.ProjectError,Core.DatabaseError,
    Core.GridError,ArgumentError}

"""
    user_message(e, backtrace = nothing)::String

The text a toast or dialog shows for the exception `e`.

For the core's errors (`ToolError`, `ProtectedError`, `ItemBusyError`, `ProjectLockedError`,
`SessionClosedError`, `ProjectError`, `DatabaseError`, `GridError`) and `ArgumentError`,
it is the core's own message, without the type name in front.
Any other exception gives "Something went wrong: <message>", and the error with its
stack trace goes to the log.
"""
function user_message(@nospecialize(e), backtrace = nothing)::String
    if e isa TaskFailedException && e.task.exception !== nothing
        return user_message(e.task.exception, backtrace)
    end
    e isa USER_ERRORS && return plain_message(e)
    @error "Unexpected error" exception = (backtrace === nothing ? e : (e, backtrace))
    return "Something went wrong: " * sprint(showerror, e)
end

# The message of `e` without its "TypeName: " prefix, as a sentence.
function plain_message(@nospecialize(e))::String
    text = sprint(showerror, e)
    prefix = string(nameof(typeof(e)), ": ")
    startswith(text, prefix) && (text = text[(ncodeunits(prefix)+1):end])
    return sentence(text)
end

"""
    sentence(text)::String

`text` as a sentence: a capital first letter and a full stop at the end.
A first word that is a name, such as `db-1` or `database.json`, keeps its case.
"""
function sentence(text::AbstractString)::String
    t = strip(text)
    isempty(t) && return "Something went wrong."
    word = rstrip(first(split(t, ' ')), (',', ':', ';'))
    t = all(islowercase, word) ? uppercasefirst(t) : t
    return last(t) in ('.', '!', '?') ? String(t) : string(t, ".")
end
