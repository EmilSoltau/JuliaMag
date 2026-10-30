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
    window::Any   # woken with `wake!` when the action starts and ends; the app's `Window`
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

# An error outside an action, such as in `wake!`. The render thread logs it.
struct WorkerProblem
    what::String
    failure::CapturedException
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

# Wake the window, if there is one, so the loop draws the result. Never throws:
# an error (`wake!` calls GLFW) goes to the render thread as a `WorkerProblem`.
function notify_window(@nospecialize(w), results::Channel{Any})
    w === nothing && return nothing
    try
        wake!(w)
    catch e
        report_problem(results, "Could not wake the window", e, catch_backtrace())
    end
    return nothing
end

# Send a `WorkerProblem`; if even that fails, log it here.
function report_problem(results::Channel{Any}, what::String, @nospecialize(e), bt)
    failure = CapturedException(e, bt)
    try
        put!(results, WorkerProblem(what, failure))
    catch
        @error what exception = (e, bt)
    end
    return nothing
end

function run_worker(inbox::Channel{WorkerAction}, results::Channel{Any})
    for a in inbox
        run_action(a, results)
    end
    return nothing
end

# Run one action. Never throws, so the worker never dies; every action sends an
# `ActionDone`, so `pending` always comes back to 0.
function run_action(a::WorkerAction, results::Channel{Any})
    done_sent = false
    try
        put!(results, ActionStarted(a.label))
        notify_window(a.window, results)
        msg = try
            # The worker task keeps the world of its start; an action may be newer code.
            ActionDone(a, Base.invokelatest(a.f, a.session), nothing)
        catch e
            ActionDone(a, nothing, CapturedException(e, catch_backtrace()))
        end
        put!(results, msg)
        done_sent = true
        notify_window(a.window, results)
    catch e
        bt = catch_backtrace()
        if done_sent
            report_problem(results, "The worker failed after an action", e, bt)
        else
            try
                put!(results, ActionDone(a, nothing, CapturedException(e, bt)))
            catch
                @error "The worker could not report an action" exception = (e, bt)
            end
        end
    end
    return nothing
end

"""
    stop_worker!(w)

Take no more actions, let the queued ones finish, and wait for the worker task to end.
Never throws: a worker task that failed is logged.
"""
function stop_worker!(w::Worker)
    close(w.inbox)
    try
        wait(w.task)
    catch e
        @error "The worker task failed" exception = (e, catch_backtrace())
    end
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
            toast!(app, :error, safe_user_message(e, catch_backtrace()))
        end
    else
        toast!(app, :error, safe_user_message(m.failure.ex, m.failure.processed_bt))
    end
    return nothing
end

handle_result!(app, m::WorkerProblem) =
    (@error m.what exception = (m.failure.ex, m.failure.processed_bt); nothing)

function handle_result!(app, m::SnapshotDone)
    # A build that started before `set_session!` is dropped. It does not touch
    # `refreshing`, which now belongs to a build of the new session.
    m.session === app.session || return nothing
    app.refreshing = false
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
    Threads.@spawn :default build_snapshot(s, rev, results, window)
    return nothing
end

# Build a snapshot and send it to the render thread. Never throws.
function build_snapshot(s::Core.Session, rev::Int, results::Channel{Any}, @nospecialize(window))
    msg = try
        SnapshotDone(s, rev, snapshot(s), nothing)
    catch e
        SnapshotDone(s, rev, nothing, CapturedException(e, catch_backtrace()))
    end
    try
        put!(results, msg)
    catch e
        @error "Could not hand back a snapshot" exception = (e, catch_backtrace())
    end
    notify_window(window, results)
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

# `user_message`, but it never throws: an exception whose `showerror` fails gives a fixed text.
function safe_user_message(@nospecialize(e), backtrace = nothing)::String
    try
        return user_message(e, backtrace)
    catch
        return "Something went wrong."
    end
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
