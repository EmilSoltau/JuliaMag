# A session wraps one open project. Every user action goes through it:
# it writes the data at once, records an undo step and records a history entry.
#
# The undo and redo stacks live in memory only. They are not saved,
# so closing the session ends the undo list.
# The history is saved: one JSON object per line in `jobs/history.jsonl`.
# `script_text` turns the history into a runnable Julia script.

using JSON3

"""
One step that can be undone. `undo`, `redo` and `drop` take no arguments.
`drop` runs when an undone step leaves the redo stack for good, to free
what `undo` kept for `redo` (such as a copy of removed rows).
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
end

UndoStep(label, undo, redo) = UndoStep(label, undo, redo, () -> nothing, String[])
UndoStep(label, undo, redo, drop) = UndoStep(label, undo, redo, drop, String[])
UndoStep(label, undo, redo, drop, items) = UndoStep(label, undo, redo, drop, items, true)

"One recorded action. `time` is local time as text. `job` is a job id or `\"\"`."
struct HistoryEntry
    time::String
    command::String
    args::Dict{String,Any}
    job::String
end

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
end

const HISTORY_FILE = "history.jsonl"

history_path(p::Project) = joinpath(p.folder, "jobs", HISTORY_FILE)

function Session(p::Project)
    warnings = String[]
    history = load_history(p, warnings)
    s = Session(p, UndoStep[], UndoStep[], history, nothing, nothing,
                load_remembered(p, warnings), ReentrantLock(), warnings, Job[], 1,
                ReentrantLock(), Dict{String,BusyMark}(), nothing, ReentrantLock(), nothing)
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

Cancel the running jobs of the session, wait for them to end, then remove the
project lock. A second call does nothing.
"""
function close_session!(s::Session)
    running = filter(j -> status(j) == JOB_RUNNING, jobs(s))
    foreach(cancel!, running)
    foreach(wait_job, running)
    held = lock(s.jobs_lock) do
        old = s.held_lock
        s.held_lock = nothing
        return old
    end
    held === nothing || release_lock!(held)
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
            push!(out, HistoryEntry(d["time"], d["command"], d["args"], d["job"]))
        catch e
            e isa InterruptException && rethrow()
            push!(warnings, "$path line $n skipped: $(sprint(showerror, e))")
        end
    end
    return out
end

now_text() = Libc.strftime("%Y-%m-%dT%H:%M:%S%z", time())

"""
    record!(s, command, args; job = "")

Add an entry to the history and append it to `jobs/history.jsonl`.
Values in `args` must be plain: numbers, strings, booleans, vectors and dictionaries.
While an undo or redo step runs, the entry is held and written after the step
(see `Session`), so the history keeps the order of the stacks.
A held entry that cannot be written then does not throw: it becomes a warning
in `s.warnings`, and a job warning for the entry of a job (see `add_held!`).
"""
function record!(s::Session, command::String, args::AbstractDict; job::String = "")
    lock(s.lock) do
        e = HistoryEntry(now_text(), command, Dict{String,Any}(String(k) => v for (k, v) in args), job)
        line = history_line(e)                 # a bad value throws now, not later
        held = s.held_edits
        if held !== nothing
            push!(held, e)
            return e
        end
        write_history!(s, e, line)
        return e
    end
end

history_line(e::HistoryEntry)::String =
    JSON3.write(Dict("time" => e.time, "command" => e.command, "args" => e.args, "job" => e.job); allow_inf = true)

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
session_warning!(s::Session, msg::String) = (lock(() -> push!(s.warnings, msg), s.jobs_lock); nothing)

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
    lock(s.lock) do
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
    lock(s.lock) do
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

"Move the cursor. Not undoable and not recorded."
function set_cursor!(s::Session, c::Cursor)
    lock(s.lock) do
        s.cursor = c
        return nothing
    end
end
