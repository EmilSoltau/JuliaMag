# A session wraps one open project. Every user action goes through it:
# it writes the data at once, records an undo step and records a history entry.
#
# The undo and redo stacks live in memory only. They are not saved,
# so closing the session ends the undo list.
# The history is saved: one JSON object per line in `jobs/history.jsonl`.
# `script_text` turns the history into a runnable Julia script.

using JSON3

"""
One step that can be undone. `undo`, `redo`, `drop` and `commit` take no arguments.
`drop` runs when an undone step leaves the redo stack for good, to free
what `undo` kept for `redo` (such as a copy of removed rows).
`commit` runs when a done step leaves the undo stack for good, which is when
the session closes (see `close_session!`), to free what the step kept for
`undo` (such as the files of a removed item). It defaults to doing nothing.
`items` are the ids of the project items the step changes. `undo!` and `redo!`
refuse the step with `ItemBusyError` while an import or an export uses one of them.

`undo` and `redo` run without `s.lock`, so a step may copy large files while
the session goes on. While one runs, its items carry a busy mark with reason
`"undo is running"`, so no other change or reader touches them. A step that
reads or changes other session state, such as the item list, takes `s.lock`
for that part only.

`recorded` is false for a change that is not in the history, such as the rows
a failed job kept (see `undo_noted!`). Then its undo and redo are not recorded
either, so a script does not undo some other step in its place.
"""
struct UndoStep
    label::String
    undo::Function
    redo::Function
    drop::Function
    items::Vector{String}
    recorded::Bool
    commit::Function
end

"The default `commit` of an `UndoStep` and of `note_job_undo!`: the step keeps nothing for undo."
nothing_to_commit() = nothing

UndoStep(label, undo, redo) = UndoStep(label, undo, redo, () -> nothing, String[])
UndoStep(label, undo, redo, drop) = UndoStep(label, undo, redo, drop, String[])
UndoStep(label, undo, redo, drop, items; commit::Function = nothing_to_commit) =
    UndoStep(label, undo, redo, drop, items, true; commit)
UndoStep(label, undo, redo, drop, items, recorded::Bool; commit::Function = nothing_to_commit) =
    UndoStep(String(label), undo, redo, drop, collect(String, items), recorded, commit)

"""
One recorded action. `time` is local time as text. `job` is a job id or `\"\"`.
`outputs` are the ids of the items the action made, such as the database of an
import. A job run again with `rerun!(...; replace = true)` names the job it
replaces in `replaces`, and the items that it took out of the project in
`replaced`. Else they are empty.
"""
struct HistoryEntry
    time::String
    command::String
    args::Dict{String,Any}
    job::String
    outputs::Vector{String}
    replaces::String
    replaced::Vector{String}
end

HistoryEntry(time, command, args, job) = HistoryEntry(time, command, args, job, String[], "", String[])

"Where the user is working: an item, a line and a row."
mutable struct Cursor
    item::String
    line::LineId
    row::Int
end

"Refused change of a protected channel."
struct ProtectedError <: Exception
    channel::String
end

Base.showerror(io::IO, e::ProtectedError) =
    print(io, "ProtectedError: channel ", e.channel, " is protected and cannot be edited")

"""
Refused change of an item that an import writes to or an export reads.
`reason` says which, such as `"an import is running"`.
"""
struct ItemBusyError <: Exception
    item::String
    reason::String
end

ItemBusyError(item::AbstractString) = ItemBusyError(String(item), "an import is running")

Base.showerror(io::IO, e::ItemBusyError) = print(io, "ItemBusyError: ", e.item, " is busy: ", e.reason)

"""
Who uses a busy item: a job that writes to it (`writing`, with `why` such as
`"an import is running"`), and the number of readers, such as exports (`reading`).
`kind` says how the writer writes: `:append` adds rows past the commit point
only, so readers of the committed rows may share the item; `:write` changes
rows in place, so readers must wait. See `mark_busy!` and `mark_reading!`.
`owner` is the task of a running undo or redo step that holds the mark, else
`nothing`. `check_not_busy` lets that task pass, since the step is the writer.
"""
mutable struct BusyMark
    writing::Bool
    reading::Int
    why::String
    kind::Symbol
    owner::Union{Nothing,Task}
end

BusyMark(writing::Bool, reading::Int, why::String, kind::Symbol) = BusyMark(writing, reading, why, kind, nothing)

"The reason of the busy mark of a running undo or redo step."
const UNDO_RUNNING = "undo is running"

"The reason of a mark that only readers hold."
const READING = "an export is running"

busy_reason(m::BusyMark) = m.writing ? m.why : READING

"True when readers may share the item with the mark `m`: no writer, or one that only appends."
readers_allowed(m::BusyMark) = !m.writing || m.kind == :append

"""
    Session(project)

The state of one working session. Use `open_session` or `new_session`.
Take `lock` for every change, but only for a short time.
`jobs_lock` guards `jobs` and `next_job`.
`undo_lock` lets one `undo!` or `redo!` run at a time. It is held while the
step runs, which may take long; `lock` is not.

Locks are taken in this order only: `undo_lock`, then `lock`, then `jobs_lock`.
A task that holds one of them may take a later one, never an earlier one.
So never call `undo!` or `redo!` while holding `lock` or `jobs_lock`.
The lock of a job report, `HELD_LOCKS_LOCK`, `GDAL_CACHE_LOCK` and `XML_LOCK`
are leaf locks: no other lock is taken while one of them is held.
"""
mutable struct Session
    project::Project
    undo_stack::Vector{UndoStep}
    redo_stack::Vector{UndoStep}
    history::Vector{HistoryEntry}
    cursor::Union{Nothing,Cursor}
    marked::Union{Nothing,Tuple{Int,Int}}
    "Last settings per tool id. Saved in `project.jmag.json` under `settings.tools`."
    remembered::Dict{String,Dict{String,Any}}
    lock::ReentrantLock
    "Problems found while loading, such as skipped history lines."
    warnings::Vector{String}
    "Jobs of the project, oldest first. Use `jobs(s)` for a copy, newest first."
    jobs::Vector{Job}
    "Number of the next job id. Saved, so a job id is never used twice."
    next_job::Int
    jobs_lock::ReentrantLock
    "Items an import writes to or an export reads, by id. Guarded by `lock`."
    busy::Dict{String,BusyMark}
    "The project lock file this session holds, or `nothing` once it is closed."
    held_lock::Union{Nothing,HeldLock}
    undo_lock::ReentrantLock
    """
    While an undo or redo step runs: the undo steps and history entries that
    other changes made meanwhile, in order. They are pushed and recorded after
    the step, so they follow it. Else `nothing`. Guarded by `lock`.
    """
    held_edits::Union{Nothing,Vector{Union{UndoStep,HistoryEntry}}}
    "Counts every change a UI shows (see `revision`). Read without a lock."
    revision::Threads.Atomic{Int}
    "0 open, 1 closing, 2 closed (see `isopen`)."
    state::Threads.Atomic{Int}
end

"Thrown by an edit, `undo!`, `redo!` or `start_job!` on a session that is closing or closed."
struct SessionClosedError <: Exception
    folder::String
end

Base.showerror(io::IO, e::SessionClosedError) = print(io, "The project ", e.folder, " is closed.")

const SESSION_OPEN = 0
const SESSION_CLOSING = 1
const SESSION_CLOSED = 2

"""
    revision(s)::Int

A counter that goes up by at least one after every change a UI shows: an
edit, an undo or redo, a cursor or marked range move, a warning, and a job
starting or leaving `JOB_RUNNING`. Reading it takes no lock.
"""
revision(s::Session)::Int = s.revision[]

bump!(s::Session) = (Threads.atomic_add!(s.revision, 1); nothing)

"""
    isopen(s)::Bool

False from the moment `close_session!` starts.
"""
Base.isopen(s::Session)::Bool = s.state[] == SESSION_OPEN

"Throw `SessionClosedError` unless the session is open. Call it before taking any lock."
check_open(s::Session) = isopen(s) ? nothing : throw(SessionClosedError(s.project.folder))

"""
    warnings(s)::Vector{String}

A copy of the session's warnings. It still works after `close_session!`,
so a UI can show the warnings of the close.
"""
warnings(s::Session)::Vector{String} = lock(() -> copy(s.warnings), s.jobs_lock)

const HISTORY_FILE = "history.jsonl"

history_path(p::Project) = joinpath(p.folder, "jobs", HISTORY_FILE)

function Session(p::Project)
    warnings = String[]
    history = load_history(p, warnings)
    s = Session(p, UndoStep[], UndoStep[], history, nothing, nothing,
                load_remembered(p, warnings), ReentrantLock(), warnings, Job[], 1,
                ReentrantLock(), Dict{String,BusyMark}(), nothing, ReentrantLock(), nothing,
                Threads.Atomic{Int}(0), Threads.Atomic{Int}(SESSION_OPEN))
    load_jobs!(s)
    return s
end

"""
    open_session(folder; force = false)

Open the project in `folder`, lock it (see `LOCK_FILE`) and read its saved history.
Throws `ProjectLockedError` when another session has the project open.
With `force = true` it opens the project anyway, with a warning in `s.warnings`.
Call `close_session!` when done.
"""
function open_session(folder::AbstractString; force::Bool = false)::Session
    f = String(folder)
    isfile(project_path(f)) || open_project(f)          # throws the ProjectError
    return locked_session(() -> open_project(f), f, force)
end

"""
    new_session(folder, name; force = false)

Make a new project in `folder`, lock it and make a session for it.
Throws `ProjectLockedError`, and changes nothing, when another session has a
project in `folder` open. Call `close_session!` when done.
"""
function new_session(folder::AbstractString, name::AbstractString; force::Bool = false)::Session
    f = String(folder)
    mkpath(f)
    return locked_session(() -> create_project(f, String(name)), f, force)
end

# Take the lock before the project is read or written, so a session that has it
# open is never disturbed (loading marks its running jobs as failed).
function locked_session(make::Function, folder::String, force::Bool)::Session
    warnings = String[]
    h, replaced = take_lock!(folder, force, warnings)
    s = try
        Session(make())
    catch
        replaced === nothing ? release_lock!(h) : restore_lock!(h, replaced)
        rethrow()
    end
    s.held_lock = h
    prepend!(s.warnings, warnings)
    sweep_leftovers!(s, replaced !== nothing)
    return s
end

"""
    sweep_leftovers!(s, forced)

Remove the side folders that a crash left in the project, each with a session
warning: `.importing-*` and `.undo-*` folders in `databases/` and `grids/`, and
`.undo-*` folders inside a database or a grid. They are of no use once the
session that made them has ended.
A side folder in a database that does not open is kept: it may hold the bytes
that an undo cut from its channel files.
With `forced` (another session may still have the project open), nothing is
removed, since that session may be using them.
"""
function sweep_leftovers!(s::Session, forced::Bool)
    found = try
        side_folders(s.project.folder)
    catch e
        e isa InterruptException && rethrow()
        session_warning!(s, "the project could not be checked for side folders left after a crash: " *
                            sprint(showerror, e))
        return nothing
    end
    isempty(found) && return nothing
    if forced
        session_warning!(s, "side folders left after a crash were not removed, since another session may " *
                            "use them (the project was opened with force = true): $(join(first.(found), ", "))")
        return nothing
    end
    free_stray_maps()          # Windows does not delete a mapped file
    opens = Dict{String,Bool}()
    for (path, db) in found
        if !isempty(db) && !get!(() -> database_opens(db), opens, db)
            session_warning!(s, "the side folder $path, left after a crash, was kept: its database does " *
                                "not open, and the folder may hold bytes cut from its channel files")
            continue
        end
        try
            rm(path; recursive = true)
            session_warning!(s, "the side folder $path, left after a crash, was removed")
        catch e
            e isa InterruptException && rethrow()
            session_warning!(s, "the side folder $path, left after a crash, could not be removed: " *
                                sprint(showerror, e))
        end
    end
    return nothing
end

"The side folders of `sweep_leftovers!` in the project in `folder`, each with its database folder, or `\"\"`."
function side_folders(folder::String)::Vector{Pair{String,String}}
    found = Pair{String,String}[]
    for top in ("databases", "grids")
        dir = joinpath(folder, top)
        isdir(dir) || continue
        for name in readdir(dir)
            path = joinpath(dir, name)
            isdir(path) || continue
            if startswith(name, ".importing-") || startswith(name, ".undo-")
                push!(found, path => "")
            elseif !startswith(name, ".")
                for n in readdir(path)
                    side = joinpath(path, n)
                    startswith(n, ".undo-") && isdir(side) && push!(found, side => (top == "databases" ? path : ""))
                end
            end
        end
    end
    return found
end

"True when the database in `folder` opens."
function database_opens(folder::String)::Bool
    try
        open_database(folder)
        return true
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

"""
    close_session!(s)

Cancel the running jobs of the session, wait for them to end, end the undo and
redo stacks, then remove the project lock. A second call does nothing.

Ending the stacks frees what their steps kept: `commit` runs for each step on
the undo stack, oldest first, and `drop` for each step on the redo stack. Such
as the folder of a removed item, the files of a deleted channel, or the folders
of the outputs that a rerun replaced. An error
there becomes a warning in `s.warnings`; the close goes on.
A session that is never closed (a crash, or an exit without close) keeps
those files.
The `commit` actions run only while the project lock is still ours. When
another session opened the project with `force = true`, its project file may
list those folders again, so they are kept, with a warning.
The lock is removed also when ending the stacks is interrupted.
"""
function close_session!(s::Session)
    s.state[] = SESSION_CLOSING
    bump!(s)
    running = filter(j -> status(j) == JOB_RUNNING, jobs(s))
    foreach(cancel!, running)
    foreach(wait_job, running)
    held = lock(() -> s.held_lock, s.jobs_lock)
    try
        end_stacks!(s; commit = held !== nothing && lock_is_ours(held))
    finally
        lock(() -> s.held_lock = nothing, s.jobs_lock)
        held === nothing || release_lock!(held)
        s.state[] = SESSION_CLOSED
        bump!(s)
    end
    return nothing
end

"""
Empty the undo and redo stacks for good: run `commit` of each undo step, oldest
first, and `drop` of each redo step. Errors become session warnings.
With `commit = false`, the undo steps keep what they kept, with one warning.
Waits for a running `undo!` or `redo!` first.
"""
function end_stacks!(s::Session; commit::Bool = true)
    done, undone = lock(s.undo_lock) do
        lock(s.lock) do
            stacks = (copy(s.undo_stack), copy(s.redo_stack))
            empty!(s.undo_stack)
            empty!(s.redo_stack)
            return stacks
        end
    end
    run_quietly(f, what, step) =
        try
            f()
        catch e
            e isa InterruptException && rethrow()
            session_warning!(s, "undo step \"$(step.label)\" could not $what at close: $(sprint(showerror, e))")
        end
    filter!(step -> step.commit !== nothing_to_commit, done)
    if commit
        foreach(step -> run_quietly(step.commit, "free its files", step), done)
    elseif !isempty(done)
        session_warning!(s, "the project lock is no longer held by this session (another session may " *
                            "have opened the project with force = true), so the files that these undo " *
                            "steps kept were not deleted: " * join((step.label for step in done), ", "))
    end
    foreach(step -> run_quietly(step.drop, "free its data", step), undone)
    return nothing
end

# Read the remembered tool settings from `settings.tools` of the project.
# A bad entry is skipped and reported in `warnings`.
function load_remembered(p::Project, warnings::Vector{String})::Dict{String,Dict{String,Any}}
    out = Dict{String,Dict{String,Any}}()
    t = get(p.settings, "tools", nothing)
    t === nothing && return out
    if !(t isa AbstractDict)
        push!(warnings, "$(project_path(p.folder)): settings.tools is not an object; it was ignored")
        return out
    end
    for (id, v) in t
        if v isa AbstractDict
            out[String(id)] = Dict{String,Any}(String(k) => x for (k, x) in v)
        else
            push!(warnings, "$(project_path(p.folder)): settings.tools.$id is not an object; it was ignored")
        end
    end
    return out
end

# ---- history ---------------------------------------------------------------

# Read the history. A bad line is skipped and reported in `warnings`.
# A line cut by a crash (no newline at the end of the file) is cut off the file,
# so the next `record!` starts on a fresh line.
function load_history(p::Project, warnings::Vector{String})::Vector{HistoryEntry}
    path = history_path(p)
    isfile(path) || return HistoryEntry[]
    bytes = read(path)
    if !isempty(bytes) && last(bytes) != UInt8('\n')
        keep = something(findlast(==(UInt8('\n')), bytes), 0)
        push!(warnings, "$path ended in a cut line; it was removed")
        bytes = bytes[1:keep]
        write(path, bytes)
    end
    out = HistoryEntry[]
    for (n, ln) in enumerate(split(String(bytes), '\n'))
        isempty(strip(ln)) && continue
        try
            d = plain(JSON3.read(ln; allow_inf = true))::Dict{String,Any}
            # Older lines have no "outputs", "replaces" or "replaced".
            ids(key) = String[x for x in get(d, key, String[])]
            push!(out, HistoryEntry(d["time"], d["command"], d["args"], d["job"], ids("outputs"),
                                    get(d, "replaces", ""), ids("replaced")))
        catch e
            e isa InterruptException && rethrow()
            push!(warnings, "$path line $n skipped: $(sprint(showerror, e))")
        end
    end
    return out
end

now_text() = Libc.strftime("%Y-%m-%dT%H:%M:%S%z", time())

"""
    record!(s, command, args; job = "", outputs = String[], replaces = "", replaced = String[])

Add an entry to the history and append it to `jobs/history.jsonl`.
`outputs`, `replaces` and `replaced` are described at `HistoryEntry`.
Values in `args` must be plain: numbers, strings, booleans, vectors and dictionaries.
While an undo or redo step runs, the entry is held and written after the step
(see `Session`), so the history keeps the order of the stacks.
A held entry that cannot be written then does not throw: it becomes a warning
in `s.warnings`, and a job warning for the entry of a job (see `add_held!`).
"""
function record!(s::Session, command::String, args::AbstractDict; job::String = "",
                 outputs::Vector{String} = String[], replaces::String = "", replaced::Vector{String} = String[])
    lock(s.lock) do
        e = HistoryEntry(now_text(), command, Dict{String,Any}(String(k) => v for (k, v) in args), job,
                         copy(outputs), replaces, copy(replaced))
        line = history_line(e)                 # a bad value throws now, not later
        held = s.held_edits
        if held !== nothing
            push!(held, e)
            bump!(s)
            return e
        end
        write_history!(s, e, line)
        bump!(s)
        return e
    end
end

function history_line(e::HistoryEntry)::String
    d = Dict{String,Any}("time" => e.time, "command" => e.command, "args" => e.args, "job" => e.job)
    isempty(e.outputs) || (d["outputs"] = e.outputs)
    if !isempty(e.replaces)
        d["replaces"] = e.replaces
        d["replaced"] = e.replaced
    end
    return JSON3.write(d; allow_inf = true)
end

"Append the entry to the history file and to `s.history`. Call it under `s.lock`."
function write_history!(s::Session, e::HistoryEntry, line::String = history_line(e))
    mkpath(dirname(history_path(s.project)))
    open(history_path(s.project), "a") do io
        println(io, line)
    end
    push!(s.history, e)
    return nothing
end

"Add a line to `s.warnings`. Safe from any thread."
session_warning!(s::Session, msg::String) = (lock(() -> push!(s.warnings, msg), s.jobs_lock); bump!(s); nothing)

# ---- busy items ------------------------------------------------------------

# A job that writes to an item marks it with `mark_busy!`. A reader, such as an
# export, marks it with `mark_reading!`. While an item is marked, changes to it
# (edits, undo, redo, other writers) throw `ItemBusyError`. Readers may share an
# item with each other and with a writer that only appends (`kind = :append`),
# since they read only the committed rows. A writer that changes rows in place
# (`kind = :write`) keeps readers out.
#
# Inside a job, the mark of `mark_busy!` lasts until the job ends:
# `unmark_busy!` leaves it on, and the job ends it once its undo step is in
# place (or before it undoes its work, when it fails). So no edit can land
# between the work and its undo step.

"True when a writer or a reader marks the item. Call it under `s.lock`."
is_busy(s::Session, id::AbstractString)::Bool = haskey(s.busy, id)

"""
Throw `ItemBusyError` when a writer or a reader marks the item. Call it under `s.lock`.
The task of a running undo or redo step passes the marks of that step.
"""
function check_not_busy(s::Session, id::AbstractString)
    m = get(s.busy, id, nothing)
    (m === nothing || m.owner === current_task()) || throw(ItemBusyError(String(id), busy_reason(m)))
    return nothing
end

"""
    mark_busy!(s, id; reason = "an import is running", kind = :write)

Mark an item as written to by a job, or throw `ItemBusyError` when it is busy.
`reason` is what `ItemBusyError` says while the mark is on. `kind` is `:append`
for a writer that only adds rows past the commit point (readers may then share
the item), or `:write` for one that changes rows in place.
Inside a job, a mark the same job holds already is taken over.
"""
function mark_busy!(s::Session, id::AbstractString; reason::AbstractString = "an import is running",
                    kind::Symbol = :write)
    kind in (:append, :write) || throw(ArgumentError("kind must be :append or :write, not $(repr(kind))"))
    key = String(id)
    ctx = job_context()
    lock(s.lock) do
        m = get(s.busy, key, nothing)
        if m !== nothing && m.writing && m.reading == 0 && ctx !== nothing && key in ctx.busy
            m.why, m.kind = String(reason), kind       # this job holds the mark already
            return nothing
        end
        check_not_busy(s, key)
        s.busy[key] = BusyMark(true, 0, String(reason), kind)
        ctx === nothing || key in ctx.busy || push!(ctx.busy, key)
        return nothing
    end
    return nothing
end

"""
End the mark of `mark_busy!`. Inside a job that holds the mark, it stays on
until the job ends (see the notes above).
"""
function unmark_busy!(s::Session, id::AbstractString)
    ctx = job_context()
    (ctx !== nothing && String(id) in ctx.busy) && return nothing
    lock(() -> unmark!(s, String(id), true), s.lock)
    return nothing
end

"End the marks that the work of a job made with `mark_busy!`. Call it under `s.lock`."
function end_job_marks!(s::Session, ctx::JobContext)
    foreach(id -> unmark!(s, id, true), ctx.busy)
    empty!(ctx.busy)
    return nothing
end

"""
Mark an item as read, such as by an export. Readers may share the item with each
other and with a writer that only appends. Throws `ItemBusyError` while a writer
changes its rows in place.
"""
function mark_reading!(s::Session, id::AbstractString)
    lock(s.lock) do
        m = get!(() -> BusyMark(false, 0, "", :write), s.busy, String(id))
        readers_allowed(m) || throw(ItemBusyError(String(id), busy_reason(m)))
        m.reading += 1
    end
    return nothing
end

"End one mark of `mark_reading!`."
unmark_reading!(s::Session, id::AbstractString) = (lock(() -> unmark!(s, String(id), false), s.lock); nothing)

function unmark!(s::Session, id::String, writer::Bool)
    m = get(s.busy, id, nothing)
    m === nothing && return nothing
    writer ? (m.writing = false) : (m.reading = max(m.reading - 1, 0))
    (m.writing || m.reading > 0) || delete!(s.busy, id)
    return nothing
end

# ---- edits -----------------------------------------------------------------

line_args(id::LineId) = Dict{String,Any}("type" => string(id.type), "number" => id.number, "version" => id.version)

"""
    set_cell!(s, item_id, line, channel, row, x)

Write one value now, make it undoable and record `"database.set_cell"`.
Throws `ProtectedError` before anything is written if the channel is protected.
"""
function set_cell!(s::Session, item_id::AbstractString, id::LineId, name::AbstractString, row::Integer, x)
    check_open(s)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, item_id)
        db = database(s.project, item_id)
        channel(db, name).protected && throw(ProtectedError(String(name)))
        old = write_value!(db, id, String(name), Int(row), x)
        write_back(v) = () -> lock(s.lock) do
            write_value!(database(s.project, item_id), id, String(name), Int(row), v)
            nothing
        end
        push_undo!(s, UndoStep("set $(name) row $row on $(line_name(id))", write_back(old), write_back(x),
                               () -> nothing, [String(item_id)]))
        record!(s, "database.set_cell", Dict("item" => String(item_id), "line" => line_args(id),
                                            "channel" => String(name), "row" => Int(row), "value" => x))
        return nothing
    end
end

"""
    set_line_selected!(s, item_id, line, flag)

Select or deselect a line and save `database.json`. Undoable and recorded.
"""
function set_line_selected!(s::Session, item_id::AbstractString, id::LineId, flag::Bool)
    check_open(s)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, item_id)
        old = line(database(s.project, item_id), id).selected
        put(v::Bool) = () -> lock(s.lock) do
            db = database(s.project, item_id)
            line(db, id).selected = v
            save_meta(db)
            nothing
        end
        put(flag)()
        push_undo!(s, UndoStep("select $(line_name(id))", put(old), put(flag), () -> nothing, [String(item_id)]))
        record!(s, "database.set_line_selected", Dict("item" => String(item_id), "line" => line_args(id),
                                                      "selected" => flag))
        return nothing
    end
end

"""
    set_lines_selected!(s, item_id, lines, flag)

Select or deselect many lines at once and save `database.json`. One undo step and
one history entry, `"database.set_lines_selected"`, for all of them. Lines that are
in that state already are left out, and nothing is pushed when none is left.
Throws `ItemBusyError` while a job or an export uses the database, and
`DatabaseError` for a line that is not in it.
"""
function set_lines_selected!(s::Session, item_id::AbstractString, ids::AbstractVector{LineId}, flag::Bool)
    check_open(s)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, item_id)
        db = database(s.project, item_id)
        changing = LineId[id for id in unique(ids) if line(db, id).selected != flag]
        isempty(changing) && return nothing
        put(v::Bool) = () -> lock(s.lock) do
            d = database(s.project, item_id)
            foreach(id -> line(d, id).selected = v, changing)
            save_meta(d)
            nothing
        end
        put(flag)()
        n = length(changing)
        push_undo!(s, UndoStep("select $n lines", put(!flag), put(flag), () -> nothing, [String(item_id)]))
        record!(s, "database.set_lines_selected", Dict("item" => String(item_id),
                                                       "lines" => [line_args(id) for id in changing],
                                                       "selected" => flag))
        return nothing
    end
end

# ---- position pairs ----------------------------------------------------------

"A copy of the position pairs, so that an undo step is not changed by later edits."
copy_pairs(ps) = PositionPair[PositionPair(p.x, p.y, p.crs) for p in ps]

"""
Change the position pairs of database `key` to `pairs` and `current` now, as one undo step
that goes back to the pairs and current pair as they are now. The caller holds `s.lock`.
"""
function change_pairs!(s::Session, key::String, label::String, pairs::Vector{PositionPair}, current::Int)
    db = database(s.project, key)
    before, was = copy_pairs(db.pairs), db.current_pair
    apply(ps, cur) = () -> lock(s.lock) do      # `undo!` runs it without the lock
        d = database(s.project, key)
        empty!(d.pairs)
        append!(d.pairs, copy_pairs(ps))
        d.current_pair = cur
        save_meta(d)
        nothing
    end
    step = UndoStep(label, apply(before, was), apply(pairs, current), () -> nothing, [key])
    step.redo()
    push_undo!(s, step)
    return nothing
end

"""
    add_pair!(s, id, x, y; crs = "")

Add the position pair of channels `x` and `y` of database `id`, with coordinate system
`crs` (a code such as `"EPSG:7855"`, or `""` when unknown). It becomes the current pair
when there was none. Undoable and recorded as `"database.add_pair"`.
Throws `ArgumentError` when a channel is not a plain numeric channel (not text, not an
array) or the pair is there already, `DatabaseError` when a channel is missing, and
`ItemBusyError` while a job or an export uses the database.
"""
function add_pair!(s::Session, id::AbstractString, x::AbstractString, y::AbstractString; crs::AbstractString = "")
    check_open(s)
    key, xn, yn, code = String(id), String(x), String(y), String(crs)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, key)
        db = database(s.project, key)
        for n in (xn, yn)
            c = channel(db, n)
            (c.eltype <: Number && c.arraylen == 1) ||
                throw(ArgumentError("channel $n cannot be part of a position pair: it must be a numeric channel and not an array"))
        end
        any(p -> p.x == xn && p.y == yn, db.pairs) &&
            throw(ArgumentError("database $key has the position pair $xn,$yn already"))
        pairs = vcat(copy_pairs(db.pairs), PositionPair(xn, yn, code))
        change_pairs!(s, key, "add position pair $xn,$yn", pairs, db.current_pair == 0 ? length(pairs) : db.current_pair)
        record!(s, "database.add_pair", Dict{String,Any}("item" => key, "x" => xn, "y" => yn, "crs" => code))
        return nothing
    end
end

"""
    remove_pair!(s, id, x, y)

Remove the position pair of channels `x` and `y`. The channels stay. The current pair
stays the same pair, or becomes 0 when the current pair is the one removed. Undoable and
recorded as `"database.remove_pair"`.
Throws `ArgumentError` when there is no such pair, and `ItemBusyError` while a job or
an export uses the database.
"""
function remove_pair!(s::Session, id::AbstractString, x::AbstractString, y::AbstractString)
    check_open(s)
    key, xn, yn = String(id), String(x), String(y)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, key)
        db = database(s.project, key)
        k = findfirst(p -> p.x == xn && p.y == yn, db.pairs)
        k === nothing && throw(ArgumentError("database $key has no position pair $xn,$yn"))
        cur = db.current_pair
        current = cur == k ? 0 : cur > k ? cur - 1 : cur
        pairs = copy_pairs(db.pairs)
        deleteat!(pairs, k)
        change_pairs!(s, key, "remove position pair $xn,$yn", pairs, current)
        record!(s, "database.remove_pair", Dict{String,Any}("item" => key, "x" => xn, "y" => yn))
        return nothing
    end
end

# ---- cursor and marks --------------------------------------------------------

"The number of rows of `line_id` in database `item_id`, or 0 when there is no such database or line."
function line_rows(s::Session, item_id::AbstractString, line_id::LineId)::Int
    k = findfirst(i -> i.id == item_id && i.kind == ITEM_DATABASE, s.project.items)
    k === nothing && return 0
    db = database(s.project, item_id)
    p = line_position(db, line_id)
    return p == 0 ? 0 : db.lines[p].nrows
end

"""
    set_cursor!(s, c)

Move the cursor. Not undoable and not recorded.
Throws `ArgumentError` when the item is not a database of the project, the line is not
in it, or the row is not between 1 and the number of rows of the line.
"""
function set_cursor!(s::Session, c::Cursor)
    lock(s.lock) do
        k = findfirst(i -> i.id == c.item, s.project.items)
        (k !== nothing && s.project.items[k].kind == ITEM_DATABASE) ||
            throw(ArgumentError("the cursor needs a database, and $(c.item) is not one"))
        db = database(s.project, c.item)
        p = line_position(db, c.line)
        p == 0 && throw(ArgumentError("database $(c.item) has no line $(line_name(c.line))"))
        n = db.lines[p].nrows
        1 <= c.row <= n ||
            throw(ArgumentError("row $(c.row) is not on line $(line_name(c.line)), which has rows 1 to $n"))
        s.cursor = c
        bump!(s)
        return nothing
    end
end

"""
    set_marked!(s, range)

Set the marked range, a stretch of rows on the current line, as `(first, last)`,
or clear it with `nothing`. Not undoable and not recorded, like `set_cursor!`.
Throws `ArgumentError` when there is no cursor, or when the range is not
`1 <= first <= last <= nrows` of the cursor line.
"""
function set_marked!(s::Session, range::Union{Nothing,Tuple{Int,Int}})
    lock(s.lock) do
        if range !== nothing
            c = s.cursor
            c === nothing && throw(ArgumentError("rows can be marked only when the cursor is on a line"))
            range[1] <= range[2] ||
                throw(ArgumentError("the marked range must not end before it starts: $(range[1]) to $(range[2])"))
            n = line_rows(s, c.item, c.line)
            1 <= range[1] && range[2] <= n ||
                throw(ArgumentError("the marked rows $(range[1]) to $(range[2]) are not on line $(line_name(c.line)), which has rows 1 to $n"))
        end
        s.marked = range
        bump!(s)
        return nothing
    end
end

# ---- items -----------------------------------------------------------------

"Make `items` the item list of the project and save it. On an error, the old list is put back."
function set_items!(p::Project, items::Vector{ProjectItem})
    saved = copy(p.items)
    try
        empty!(p.items)
        append!(p.items, items)
        save_project(p)
    catch
        empty!(p.items)
        append!(p.items, saved)
        rethrow()
    end
    return nothing
end

"""
    remove_item!(s, id)

Take item `id` out of the project. Undoable: undo puts it back in its place,
and redo takes it out again. Recorded as `"project.remove_item"`.
When the cursor is on the item, the cursor and the marked range are cleared;
undo puts them back if they are still clear.
The item's files stay while the session can undo the remove. When the session
closes with the item still out, the step's `commit` deletes them (see
`close_session!`). A session that is never closed (a crash, or an exit without
close) keeps them, and no later sweep removes them: a folder the project file
does not list is never deleted on open.
Throws `ItemBusyError` while a job or an export uses the item, and
`ProjectError` when there is no such item.
"""
function remove_item!(s::Session, id::AbstractString)
    check_open(s)
    key = String(id)
    p = s.project
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, key)
        it = item(p, key)
        k = something(findfirst(i -> i === it, p.items))
        # The cursor and marked range that pointed at the item, for undo.
        kept = Ref{Union{Nothing,Tuple{Cursor,Union{Nothing,Tuple{Int,Int}}}}}(nothing)
        take_out() = lock(s.lock) do                # `undo!` runs the steps without the lock
            set_items!(p, filter(i -> i.id != key, p.items))
            c = s.cursor
            if c !== nothing && c.item == key
                kept[] = (c, s.marked)
                s.cursor = nothing
                s.marked = nothing
            end
            nothing
        end
        put_back() = lock(s.lock) do
            any(i -> i.id == key, p.items) && return nothing
            items = copy(p.items)
            insert!(items, clamp(k, 1, length(items) + 1), it)
            set_items!(p, items)
            saved = kept[]
            if saved !== nothing && s.cursor === nothing && s.marked === nothing
                s.cursor, s.marked = saved
            end
            kept[] = nothing
            nothing
        end
        # Undo is no longer possible: delete the files if the item is out.
        commit() = lock(() -> remove_unused_folders!(p, [it]), s.lock)
        take_out()
        push_undo!(s, UndoStep("remove $(it.name)", put_back, take_out, () -> nothing, [key]; commit))
        record!(s, "project.remove_item", Dict{String,Any}("item" => key))
        return nothing
    end
end

"""
    rename_item!(s, id, name)

Give item `id` a new name. Leading and trailing spaces are dropped.
Undoable and recorded as `"project.rename_item"`.
Throws `ArgumentError` for a blank name, `ItemBusyError` while a job or an
export uses the item, and `ProjectError` when there is no such item.
"""
function rename_item!(s::Session, id::AbstractString, name::AbstractString)
    check_open(s)
    key = String(id)
    new = String(strip(name))
    isempty(new) && throw(ArgumentError("the name of an item cannot be blank"))
    p = s.project
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, key)
        old = item(p, key).name
        put(v::String) = () -> lock(s.lock) do
            it = item(p, key)
            before = it.name
            it.name = v
            try
                save_project(p)
            catch
                it.name = before
                rethrow()
            end
            nothing
        end
        step = UndoStep("rename $old to $new", put(old), put(new), () -> nothing, [key])
        step.redo()
        push_undo!(s, step)
        record!(s, "project.rename_item", Dict{String,Any}("item" => key, "name" => new))
        return nothing
    end
end

# ---- channels --------------------------------------------------------------
#
# Each channel edit runs under `s.lock`, refuses a busy database with
# `ItemBusyError`, saves `database.json` atomically, pushes an undo step that
# puts back the exact old values, and is recorded in the history.

"""
Change a fact of channel `name` of database `id` to `new` with `setter!(c, value)`,
save `database.json`, and push an undo step that puts back the value `getter(c)` had.
Call it under `s.lock`. Throws `ItemBusyError` when the database is busy, before anything changes.
"""
function edit_channel_meta!(getter::Function, setter!::Function, s::Session, id::String, name::String,
                            label::String, new)
    check_not_busy(s, id)
    old = getter(channel(database(s.project, id), name))
    put(v) = () -> lock(s.lock) do               # `undo!` runs it without the lock
        db = database(s.project, id)
        c = channel(db, name)
        before = getter(c)
        setter!(c, v)
        try
            save_meta(db)
        catch
            setter!(c, before)
            rethrow()
        end
        nothing
    end
    step = UndoStep(label, put(old), put(new), () -> nothing, [id])
    step.redo()
    push_undo!(s, step)
    return nothing
end

"""
    set_channel_protected!(s, id, channel, flag)

Protect a channel of database `id` (`flag = true`) or unprotect it. The values
of a protected channel cannot be edited. Undoable and recorded as
`"database.set_channel_protected"`. Throws `ItemBusyError` while a job or an
export uses the database.
"""
function set_channel_protected!(s::Session, id::AbstractString, name::AbstractString, flag::Bool)
    check_open(s)
    key, ch = String(id), String(name)
    lock(s.lock) do
        check_open(s)
        edit_channel_meta!(c -> c.protected, (c, v) -> (c.protected = v), s, key, ch,
                           (flag ? "protect " : "unprotect ") * ch, flag)
        record!(s, "database.set_channel_protected", Dict{String,Any}("item" => key, "channel" => ch,
                                                                      "protected" => flag))
    end
    return nothing
end

const CHANNEL_INFO_FIELDS = (:label, :units, :decimals, :format, :width)

"""
    set_channel_info!(s, id, channel; label, units, decimals, format, width)

Change how a channel of database `id` is described and shown. Each keyword is
optional; the others stay. `format` is one of `:normal`, `:exponential`,
`:date` and `:time`. `decimals` is -1 (not set) or more, and `width` is 1 or more.
The values do not change. Undoable and recorded as `"database.set_channel_info"`
with the given keywords. Throws `ArgumentError` for a bad value, and
`ItemBusyError` while a job or an export uses the database.
"""
function set_channel_info!(s::Session, id::AbstractString, name::AbstractString;
                           label::Union{Nothing,AbstractString} = nothing,
                           units::Union{Nothing,AbstractString} = nothing,
                           decimals::Union{Nothing,Integer} = nothing, format::Union{Nothing,Symbol} = nothing,
                           width::Union{Nothing,Integer} = nothing)
    check_open(s)
    format === nothing || format in CHANNEL_FORMATS ||
        throw(ArgumentError("format must be one of $(join(CHANNEL_FORMATS, ", ")), not $format"))
    decimals === nothing || decimals >= -1 || throw(ArgumentError("decimals must be -1 (not set) or more, not $decimals"))
    width === nothing || width >= 1 || throw(ArgumentError("width must be 1 or more, not $width"))
    given = Dict{Symbol,Any}()
    for (k, v) in zip(CHANNEL_INFO_FIELDS, (label, units, decimals, format, width))
        v === nothing || (given[k] = v isa AbstractString ? String(v) : v isa Integer ? Int(v) : v)
    end
    key, ch = String(id), String(name)
    info(c) = Tuple(getfield(c, k) for k in CHANNEL_INFO_FIELDS)
    set_info!(c, v) = foreach((k, x) -> setfield!(c, k, x), CHANNEL_INFO_FIELDS, v)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, key)
        old = info(channel(database(s.project, key), ch))
        isempty(given) && return nothing
        new = Tuple(get(given, k, o) for (k, o) in zip(CHANNEL_INFO_FIELDS, old))
        edit_channel_meta!(info, set_info!, s, key, ch, "change channel $ch", new)
        args = Dict{String,Any}("item" => key, "channel" => ch)
        foreach(((k, v),) -> args[String(k)] = v isa Symbol ? String(v) : v, given)
        record!(s, "database.set_channel_info", args)
    end
    return nothing
end

"The position pairs of `db` as text, such as `X,Y`."
pairs_text(ps) = join(("$(p.x),$(p.y)" for p in ps), " and ")

"""
    rename_channel!(s, id, old, new)

Rename channel `old` of database `id` to `new`, with its files. A position pair
that uses `old` uses `new` after it. Undoable and recorded as
`"database.rename_channel"`.
Throws `ArgumentError` when `new` is not a valid channel name, is the name of
another channel (case is ignored), or is a name that a position pair uses;
`ItemBusyError` while a job or an export uses the database; and `DatabaseError`
when there is no channel `old`.
"""
function rename_channel!(s::Session, id::AbstractString, old::AbstractString, new::AbstractString)
    check_open(s)
    key, from, to = String(id), String(old), String(new)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, key)
        db = database(s.project, key)
        c = channel(db, from)
        from == to && return nothing
        renamed = copy_info(c)
        renamed.name = to
        try
            check_channel_info(renamed, Set{String}(lowercase(x.name) for x in db.channels if x !== c))
        catch e
            e isa DatabaseError || rethrow()
            throw(ArgumentError(e.msg))
        end
        clash = filter(p -> any(n -> n != from && lowercase(n) == lowercase(to), (p.x, p.y)), db.pairs)
        isempty(clash) || throw(ArgumentError("channel name $to is used by position pair $(pairs_text(clash))"))
        apply(a, b) = () -> lock(s.lock) do      # `undo!` runs it without the lock
            rename_channel_files!(database(s.project, key), a, b)
            nothing
        end
        step = UndoStep("rename channel $from to $to", apply(to, from), apply(from, to), () -> nothing, [key])
        step.redo()
        push_undo!(s, step)
        record!(s, "database.rename_channel", Dict{String,Any}("item" => key, "channel" => from, "name" => to))
        return nothing
    end
end

"""
    delete_channel!(s, id, channel)

Delete a channel of database `id`. Undoable: its files move to a side folder
`<database>/.undo-*`, and undo moves them back, so the values come back as
they were. Recorded as `"database.delete_channel"`.
The side folder goes when undo moves the files back, or when the session
closes with the channel still deleted (the step's `commit`, see
`close_session!`). A session that is never closed (a crash, or an exit without
close) leaves it; the next `open_session` sweeps it with a warning.
Throws `ProtectedError` for a protected channel, `ArgumentError` for a channel
that a position pair uses, `ItemBusyError` while a job or an export uses the
database, and `DatabaseError` when there is no such channel.
"""
function delete_channel!(s::Session, id::AbstractString, name::AbstractString)
    check_open(s)
    key, ch = String(id), String(name)
    lock(s.lock) do
        check_open(s)
        check_not_busy(s, key)
        db = database(s.project, key)
        c = channel(db, ch)
        c.protected && throw(ProtectedError(ch))
        used = filter(p -> ch in (p.x, p.y), db.pairs)
        isempty(used) || throw(ArgumentError("channel $ch is used by position pair $(pairs_text(used))"))
        info = copy_info(c)
        side = Ref("")                         # the side folder that holds the files, while deleted
        pos = Ref(0)
        take_out() = lock(s.lock) do           # `undo!` runs the steps without the lock
            d = database(s.project, key)
            dir = mktempdir(d.folder; prefix = ".undo-", cleanup = false)
            try
                pos[] = take_out_channel!(d, ch, dir)
            catch
                rm(dir; recursive = true, force = true)
                rethrow()
            end
            side[] = dir
            nothing
        end
        put_back() = lock(s.lock) do
            put_back_channel!(database(s.project, key), copy_info(info), pos[], side[])
            rm(side[]; recursive = true, force = true)
            side[] = ""
            nothing
        end
        # Neither undo nor redo is possible any more: remove the side folder, if any.
        free() = lock(s.lock) do
            isempty(side[]) && return nothing
            free_stray_maps()                  # Windows does not delete a mapped file
            rm(side[]; recursive = true, force = true)
            side[] = ""
            nothing
        end
        take_out()
        push_undo!(s, UndoStep("delete channel $ch", put_back, take_out, free, [key]; commit = free))
        record!(s, "database.delete_channel", Dict{String,Any}("item" => key, "channel" => ch))
        return nothing
    end
end
