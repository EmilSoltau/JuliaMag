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
refuse the step with `ItemBusyError` while an import writes to one of them.
"""
struct UndoStep
    label::String
    undo::Function
    redo::Function
    drop::Function
    items::Vector{String}
end

UndoStep(label, undo, redo) = UndoStep(label, undo, redo, () -> nothing, String[])
UndoStep(label, undo, redo, drop) = UndoStep(label, undo, redo, drop, String[])

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

"Refused change of an item that an import is writing to."
struct ItemBusyError <: Exception
    item::String
end

Base.showerror(io::IO, e::ItemBusyError) =
    print(io, "ItemBusyError: ", e.item, " is busy: an import is running")

"""
    Session(project)

The state of one working session. Use `open_session` or `new_session`.
Take `lock` for every change, but only for a short time.
`jobs_lock` guards `jobs` and `next_job`. It may be taken while `lock` is held,
never the other way round.
"""
mutable struct Session
    project::Project
    undo_stack::Vector{UndoStep}
    redo_stack::Vector{UndoStep}
    history::Vector{HistoryEntry}
    cursor::Union{Nothing,Cursor}
    marked::Union{Nothing,Tuple{Int,Int}}
    remembered::Dict{String,Dict{String,Any}}
    lock::ReentrantLock
    "Problems found while loading, such as skipped history lines."
    warnings::Vector{String}
    "Jobs of the project, oldest first. Use `jobs(s)` for a copy, newest first."
    jobs::Vector{Job}
    "Number of the next job id. Saved, so a job id is never used twice."
    next_job::Int
    jobs_lock::ReentrantLock
    "Ids of items an import is writing to. Guarded by `lock`."
    busy::Set{String}
end

const HISTORY_FILE = "history.jsonl"

history_path(p::Project) = joinpath(p.folder, "jobs", HISTORY_FILE)

function Session(p::Project)
    warnings = String[]
    history = load_history(p, warnings)
    s = Session(p, UndoStep[], UndoStep[], history, nothing, nothing,
                Dict{String,Dict{String,Any}}(), ReentrantLock(), warnings, Job[], 1,
                ReentrantLock(), Set{String}())
    load_jobs!(s)
    return s
end

"Open the project in `folder` and read its saved history."
open_session(folder::AbstractString) = Session(open_project(String(folder)))

"Make a new project in `folder` and a session for it."
new_session(folder::AbstractString, name::AbstractString) =
    Session(create_project(String(folder), String(name)))

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
"""
function record!(s::Session, command::String, args::AbstractDict; job::String = "")
    lock(s.lock) do
        e = HistoryEntry(now_text(), command, Dict{String,Any}(String(k) => v for (k, v) in args), job)
        mkpath(dirname(history_path(s.project)))
        line = JSON3.write(Dict("time" => e.time, "command" => e.command, "args" => e.args, "job" => e.job);
                           allow_inf = true)
        open(history_path(s.project), "a") do io
            println(io, line)
        end
        push!(s.history, e)
        return e
    end
end

"Add a line to `s.warnings`. Safe from any thread."
session_warning!(s::Session, msg::String) = (lock(() -> push!(s.warnings, msg), s.jobs_lock); nothing)

# ---- busy items ------------------------------------------------------------

"Throw `ItemBusyError` when an import is writing to the item. Call it under `s.lock`."
check_not_busy(s::Session, id::AbstractString) = (id in s.busy && throw(ItemBusyError(String(id))); nothing)

"Mark an item busy, or throw `ItemBusyError` when it already is."
function mark_busy!(s::Session, id::AbstractString)
    lock(s.lock) do
        check_not_busy(s, id)
        push!(s.busy, String(id))
    end
    return nothing
end

unmark_busy!(s::Session, id::AbstractString) = (lock(() -> delete!(s.busy, String(id)), s.lock); nothing)

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
        write_back(v) = () -> (write_value!(database(s.project, item_id), id, String(name), Int(row), v); nothing)
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
        put(v::Bool) = () -> begin
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
