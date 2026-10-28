# Jobs: long work (imports now; gridding and filters later) that runs on a
# worker thread, with progress, cancel, undo and "run again" (spec 8.5, 13.4).
#
# Rules:
# - Nothing a job does throws to the caller. An error becomes `JOB_FAILED` with
#   its message. An error after `cancel!` becomes `JOB_CANCELLED`.
# - A failed or cancelled job leaves no new item: it takes out the items its
#   work added, removes the temp folders it noted with `note_job_folder!`, and
#   runs the undo actions it noted with `note_job_undo!`.
# - A finished job is recorded in the history once, with its id, and gets an
#   undo step. Undo takes its outputs out of the project but keeps their files,
#   so redo can put them back. When redo is no longer possible, the files of
#   outputs that are out of the project are deleted.
# - Items the work marked busy with `mark_busy!` stay busy until the job ends:
#   after its undo step is in place, or before a failed job undoes its work.
# - Each job is saved in `jobs/<id>.json` with its report text.
#   `jobs/counter.json` holds the next job number, so an id is never used twice.
# - Status and progress are atomics. Project changes happen under `s.lock`, held
#   only for short times. The job list, the counter and the job records are
#   guarded by `s.jobs_lock`, so they never wait for project work.

using JSON3

"Most bytes of report text saved with a job. Longer text is cut, with a note."
const MAX_REPORT_BYTES = 1 << 20

const JOB_COUNTER_FILE = "counter.json"

const JOB_STATUS_NAMES = Dict(string(st) => st for st in instances(JobStatus))

"Thrown inside a job that was cancelled before its work started."
struct JobCancelled <: Exception end

Base.showerror(io::IO, ::JobCancelled) = print(io, "JobCancelled: the job was cancelled")

jobs_folder(s::Session) = joinpath(s.project.folder, "jobs")
job_path(s::Session, id::AbstractString) = joinpath(jobs_folder(s), "$id.json")
function job_number(id::AbstractString)::Union{Nothing,Int}
    m = match(r"^job-(\d+)$", id)
    return m === nothing ? nothing : tryparse(Int, something(m[1]))
end

# ---- start, cancel, wait ---------------------------------------------------

"""
    start_job!(s, command, args, work)::Job

Run `work(progress::Progress, report::IO)` on a worker thread and return the job at once.
`work` returns a vector of the new `ProjectItem`s it made (it may add them to the
project itself). It should check `is_cancelled(progress)` now and then.

When the work is done, its new items are in the project, the job is recorded in
the history as `command` with `args`, and an undo step takes the items out again.
With `undoable = false` the job gets no undo step. Use it for work that does
not change the project, such as an export.
An error becomes `JOB_FAILED`; nothing is thrown.
"""
start_job!(s::Session, command::AbstractString, args::AbstractDict, work::Function; undoable::Bool = true)::Job =
    start_job!(s, command, args, work, nothing; undoable)

function start_job!(s::Session, command::AbstractString, args::AbstractDict, work::Function,
                    replaces::Union{Nothing,Job}; undoable::Bool = true)::Job
    a = Dict{String,Any}(String(k) => v for (k, v) in args)
    before = lock(() -> Set{String}(i.id for i in s.project.items), s.lock)
    # The lock makes `job.task` set before any other thread can see the job.
    lock(s.jobs_lock) do
        job = Job(reserve_job_id!(s), String(command), a, Threads.Atomic{Int}(Int(JOB_RUNNING)),
                  Threads.Atomic{Float64}(0.0), Threads.Atomic{Bool}(false), now_text(), "",
                  IOBuffer(), String[], "", nothing)
        push!(s.jobs, job)
        save_job_quietly(s, job)
        job.task = Threads.@spawn run_job!(s, job, work, before, replaces, undoable)
        return job
    end
end

"Ask the job to stop. It stops at its next check of `is_cancelled`."
cancel!(job::Job) = (job.cancel[] = true; nothing)

"""
    wait_job(job)::Job
    wait_job(result::Tuple)

Wait until the job has ended. Never throws. Returns the job.

`run_tool` returns a tuple `(ok, message, outputs)`, not a job, for a `:quick`
tool and for a tool it refused. `wait_job` returns such a tuple when `ok`, and
throws a `ToolError` with the message when not. So a script line
`wait_job(run_tool(...))` stops the script at a tool that did not run.
"""
function wait_job(r::Tuple{Bool,AbstractString,Any})
    r[1] || throw(ToolError(String(r[2])))
    return r
end

function wait_job(job::Job)::Job
    t = job.task
    t === nothing && return job
    try
        wait(t)
    catch
        # `run_job!` catches everything; this is only a safety net.
    end
    return job
end

"The jobs of the session, newest first."
function jobs(s::Session)::Vector{Job}
    lock(s.jobs_lock) do
        return sort(s.jobs; by = j -> something(job_number(j.id), 0), rev = true)
    end
end

# ---- running ---------------------------------------------------------------

function run_job!(s::Session, job::Job, work::Function, before::Set{String}, replaces::Union{Nothing,Job},
                  undoable::Bool)
    ctx = JobContext()
    try
        progress = Progress(f -> (job.progress[] = clamp(Float64(f), 0.0, 1.0); nothing), () -> job.cancel[])
        result = task_local_storage(JOB_CONTEXT_KEY, ctx) do
            job.cancel[] && throw(JobCancelled())
            return work(progress, job.report)
        end
        finish_job!(s, job, job_outputs(result), before, replaces, ctx, undoable)
    catch e
        fail_job!(s, job, e, ctx)
    end
    return nothing
end

"The items that the work of a job or a tool returned: `nothing` or a vector of `ProjectItem`, checked."
function job_outputs(result)::Vector{ProjectItem}
    result === nothing && return ProjectItem[]
    (result isa AbstractVector && all(x -> x isa ProjectItem, result)) || throw(ArgumentError(
        "the work returned a $(typeof(result)), not nothing or a vector of ProjectItem"))
    return ProjectItem[x for x in result]
end

"""
Add the outputs, record the job and push its undo step (when `undoable`).
Undoes its own changes on error. Ends the busy marks of the work last, so no
edit can land between the work and its undo step.
"""
function finish_job!(s::Session, job::Job, items::Vector{ProjectItem}, before::Set{String},
                     replaces::Union{Nothing,Job}, ctx::JobContext, undoable::Bool)
    lock(s.lock) do
        try
            finish_locked!(s, job, items, before, replaces, ctx, undoable)
        finally
            end_job_marks!(s, ctx)
        end
    end
    return nothing
end

function finish_locked!(s::Session, job::Job, items::Vector{ProjectItem}, before::Set{String},
                        replaces::Union{Nothing,Job}, ctx::JobContext, undoable::Bool)
    p = s.project
    new = ProjectItem[it for it in items if !(it.id in before)]
    # Items the work added but did not return are outputs too.
    for it in p.items
        it.id in ctx.items && !any(n -> n.id == it.id, new) && push!(new, it)
    end
    old = ProjectItem[]
    if replaces !== nothing
        old = ProjectItem[it for it in p.items if it.id in replaces.outputs]
        # An import or an export uses a busy item: keep it, and say so.
        for it in filter(it -> is_busy(s, it.id), old)
            why = busy_reason(s.busy[it.id])
            println(job.report, "not replaced: ", it.id, " is busy: ", why)
            session_warning!(s, "$(job.id) did not replace $(it.id): it is busy: $why")
        end
        filter!(it -> !is_busy(s, it.id), old)
    end
    merge!(job.args, ctx.args)
    try
        foreach(it -> isempty(it.made_by) && (it.made_by = job.id), new)
        swap_items!(p, old, new)
        record!(s, job.command, job.args; job = job.id)
    catch
        # Leave no half-made item: take the new ones out, delete their files,
        # and undo the other changes the work noted.
        quietly(() -> swap_items!(p, new, old))
        foreach(it -> quietly(() -> rm(item_path(p, it); recursive = true, force = true)), new)
        end_job_marks!(s, ctx)          # the noted undos refuse busy items
        undo_noted!(ctx)
        rethrow()
    end
    old_status = replaces === nothing ? JOB_DONE : status(replaces)
    job.outputs = String[it.id for it in new]
    job.progress[] = 1.0
    job.finished = now_text()
    set_status!(job, JOB_DONE)
    save_job_quietly(s, job)
    kept_old = replaces !== nothing && any(id -> any(i -> i.id == id, p.items), replaces.outputs)
    if replaces !== nothing && old_status == JOB_DONE && !kept_old
        set_status!(replaces, JOB_UNDONE)
        save_job_quietly(s, replaces)
    end
    undoable || return nothing
    noted = copy(ctx.undos)
    replaced_all = !kept_old
    undo = () -> begin
        foreach(u -> u[1](), reverse(noted))
        swap_items!(p, new, old)
        set_job_status!(s, job, JOB_UNDONE)
        replaces === nothing || set_job_status!(s, replaces, old_status)
        nothing
    end
    redo = () -> begin
        foreach(u -> u[2](), noted)
        swap_items!(p, old, new)
        set_job_status!(s, job, JOB_DONE)
        (replaces === nothing || old_status != JOB_DONE || !replaced_all) ||
            set_job_status!(s, replaces, JOB_UNDONE)
        nothing
    end
    # Redo is no longer possible: free what the noted steps kept, and delete the
    # files of outputs that undo took out of the project.
    drop = () -> begin
        foreach(u -> u[3](), noted)
        remove_unused_folders!(p, vcat(new, old))
        nothing
    end
    # `undo!` and `redo!` refuse the step while one of these items is busy.
    touched = unique!(vcat(String[it.id for it in new], String[it.id for it in old], ctx.touched))
    push_undo!(s, UndoStep("$(job.command) ($(job.id))", undo, redo, drop, touched))
    return nothing
end

"""
Delete the folders of the items in `items` that are out of the project, unless
an item of the project still uses the same folder.
"""
function remove_unused_folders!(p::Project, items::Vector{ProjectItem})
    used = Set{String}(normpath(item_path(p, i)) for i in p.items)
    gone = String[]
    for it in items
        any(i -> i.id == it.id, p.items) && continue
        path = normpath(item_path(p, it))
        path in used || !ispath(path) || push!(gone, path)
    end
    isempty(gone) && return nothing
    free_stray_maps()          # Windows does not delete a mapped file
    foreach(path -> rm(path; recursive = true, force = true), gone)
    return nothing
end

"Run `f`; drop any error. For clean-up after a failure, where the first error counts."
function quietly(f::Function)
    try
        f()
    catch e
        e isa InterruptException && rethrow()
    end
    return nothing
end

"Undo, then drop, the changes the work noted with `note_job_undo!`, newest first."
function undo_noted!(ctx::JobContext)
    for u in reverse(ctx.undos)
        quietly(u[1])
        quietly(u[3])
    end
    empty!(ctx.undos)
    return nothing
end

"""
Take the items `out` out of the project, put the items `put` in, and save.
Items already out or in are skipped. On a save error the list is put back and the error thrown.
"""
function swap_items!(p::Project, out::Vector{ProjectItem}, put::Vector{ProjectItem})
    saved = copy(p.items)
    try
        filter!(i -> !any(o -> o.id == i.id, out), p.items)
        for it in put
            any(i -> i.id == it.id, p.items) || add_item!(p, it)
        end
        save_project(p)
    catch
        empty!(p.items)
        append!(p.items, saved)
        rethrow()
    end
    return nothing
end

function set_job_status!(s::Session, job::Job, st::JobStatus)
    set_status!(job, st)
    save_job_quietly(s, job)
    return nothing
end

"End a job that threw. Never throws."
function fail_job!(s::Session, job::Job, e, ctx::JobContext)
    cancel_error = e isa ImportCancelled || e isa ExportCancelled || e isa JobCancelled
    cancelled = job.cancel[] || cancel_error
    try
        lock(s.lock) do
            end_job_marks!(s, ctx)      # the noted undos refuse busy items
            undo_noted!(ctx)
            # Take out the items the work added, and delete their files.
            p = s.project
            gone = filter(it -> it.id in ctx.items, p.items)
            if !isempty(gone)
                filter!(it -> !(it.id in ctx.items), p.items)
                quietly(() -> save_project(p))
                foreach(it -> quietly(() -> rm(item_path(p, it); recursive = true, force = true)), gone)
            end
        end
    catch
    end
    foreach(f -> quietly(() -> rm(f; recursive = true, force = true)), ctx.folders)
    msg = try
        sprint(showerror, e)
    catch
        string(typeof(e))
    end
    job.error = cancel_error ? "the job was cancelled" :
                cancelled ? "the job was cancelled: " * first(msg, 10_000) : first(msg, 10_000)
    job.finished = now_text()
    set_status!(job, cancelled ? JOB_CANCELLED : JOB_FAILED)
    quietly(() -> save_job_quietly(s, job))
    return nothing
end

# ---- saving and loading ----------------------------------------------------

"The report text to save: at most `MAX_REPORT_BYTES`, with a note when cut."
function report_text(job::Job)::String
    bytes = take!(copy(job.report))
    n = length(bytes)
    n <= MAX_REPORT_BYTES && return String(bytes)
    k = MAX_REPORT_BYTES
    while k > 0 && (bytes[k+1] & 0xc0) == 0x80     # do not cut a character in two
        k -= 1
    end
    return String(bytes[1:k]) * "\n[the report was cut at 1 MB; $(n - k) more bytes were not saved]\n"
end

function save_job(s::Session, job::Job)
    mkpath(jobs_folder(s))
    rec = Dict{String,Any}("id" => job.id, "command" => job.command, "args" => job.args,
                           "status" => string(status(job)), "progress" => job.progress[],
                           "started" => job.started, "finished" => job.finished,
                           "outputs" => job.outputs, "error" => job.error, "report" => report_text(job))
    write_json_atomic(job_path(s, job.id), rec; allow_inf = true)
    return nothing
end

"Save the job record. A failure is kept in `s.warnings`; it does not stop the job."
function save_job_quietly(s::Session, job::Job)
    lock(s.jobs_lock) do
        try
            save_job(s, job)
        catch e
            e isa InterruptException && rethrow()
            session_warning!(s, "the record of $(job.id) could not be saved: $(sprint(showerror, e))")
        end
    end
    return nothing
end

"A new job id. The counter is saved first, so the id is never used again. Call it under `s.jobs_lock`."
function reserve_job_id!(s::Session)::String
    n = s.next_job
    s.next_job = n + 1
    try
        mkpath(jobs_folder(s))
        write_json_atomic(joinpath(jobs_folder(s), JOB_COUNTER_FILE), Dict("next_job" => s.next_job))
    catch e
        e isa InterruptException && rethrow()
        session_warning!(s, "the job counter could not be saved: $(sprint(showerror, e))")
    end
    return "job-$n"
end

"Read the saved jobs. A bad record is skipped and reported in `s.warnings`."
function load_jobs!(s::Session)
    folder = jobs_folder(s)
    isdir(folder) || return nothing
    next = 1
    counter = joinpath(folder, JOB_COUNTER_FILE)
    if isfile(counter)
        try
            d = plain(JSON3.read(read(counter, String)))::Dict{String,Any}
            next = d["next_job"]::Int
        catch e
            e isa InterruptException && rethrow()
            push!(s.warnings, "$counter skipped: $(sprint(showerror, e))")
        end
    end
    for name in readdir(folder)
        m = match(r"^(job-\d+)\.json$", name)
        m === nothing && continue
        id = String(something(m[1]))
        n = job_number(id)
        n === nothing || (next = max(next, n + 1))
        path = joinpath(folder, name)
        try
            push!(s.jobs, read_job(path, id))
        catch e
            e isa InterruptException && rethrow()
            push!(s.warnings, "$path skipped: $(sprint(showerror, e))")
        end
    end
    sort!(s.jobs; by = j -> something(job_number(j.id), 0))
    s.next_job = next
    for job in s.jobs
        # A job that was running when the program stopped did not finish.
        if status(job) == JOB_RUNNING
            set_status!(job, JOB_FAILED)
            job.error = "the program stopped before the job finished"
            save_job_quietly(s, job)
        end
    end
    return nothing
end

function read_job(path::String, id::String)::Job
    d = plain(JSON3.read(read(path, String); allow_inf = true))::Dict{String,Any}
    d["id"] == id || throw(ArgumentError("the record has id $(repr(d["id"])), not $id"))
    st = JOB_STATUS_NAMES[d["status"]]
    report = IOBuffer()
    write(report, d["report"]::String)
    return Job(id, d["command"], d["args"], Threads.Atomic{Int}(Int(st)),
               Threads.Atomic{Float64}(Float64(d["progress"])), Threads.Atomic{Bool}(false),
               d["started"], d["finished"], report, String[x for x in d["outputs"]], d["error"], nothing)
end

# ---- imports and running again ---------------------------------------------

"Values for the history: symbols become text."
plain_arg(x::Symbol) = String(x)
plain_arg(x::AbstractChar) = string(x)
plain_arg(x) = x

"""
    import_file(s, path; settings...)::Job

Import a file as a job. The importer is picked by the file extension
(see `importer_for`). The settings go to the importer, such as `crs` for XYZ.
The job is recorded as the importer id with `path` and the settings.
An unknown file type gives a failed job; nothing is thrown.
"""
function import_file(s::Session, path::AbstractString; kwargs...)::Job
    settings = Dict{String,Any}(String(k) => plain_arg(v) for (k, v) in kwargs)
    args = merge(settings, Dict{String,Any}("path" => String(path)))
    spec = importer_for(path)
    spec === nothing && return start_job!(s, "import", args, (_, _) -> throw(ArgumentError(
        "no importer for the file type of $path")))
    return start_job!(s, spec.id, args, import_work(s, spec, String(path), settings))
end

function import_work(s::Session, spec::ImporterSpec, path::String, settings::Dict{String,Any})
    return (progress::Progress, io::IO) -> begin
        r = spec.run(s, path, settings, progress)::ImportResult
        println(io, spec.name, " import of ", path, ": ", r.rows, " rows in ", r.lines, " lines")
        for w in r.warnings
            println(io, w.file_line > 0 ? "line $(w.file_line): " : "", w.message)
        end
        return r.item === nothing ? ProjectItem[] : ProjectItem[r.item]
    end
end

"""
    rerun!(s, job; args = job.args, replace = false)::Job

Run the command of a job again, with the same or new `args` (spec 8.5).
The command is an importer, an exporter or a `:job` tool.
With `replace = true`, the outputs of the old job are taken out of the project
once the new job is done; undo puts them back. An export makes no items, so
`replace` does nothing for it, and the new export job has no undo step.
A command that cannot run again gives a failed job; nothing is thrown.
"""
function rerun!(s::Session, job::Job; args::AbstractDict = job.args, replace::Bool = false)::Job
    a = Dict{String,Any}(String(k) => plain_arg(v) for (k, v) in args)
    old = replace ? job : nothing
    known = importers()
    k = findfirst(i -> i.id == job.command, known)
    if k !== nothing
        spec = known[k]
        path = get(a, "path", "")
        if path isa AbstractString && !isempty(path)
            settings = Dict{String,Any}(key => v for (key, v) in a if key != "path")
            return start_job!(s, job.command, a, import_work(s, spec, String(path), settings), old)
        end
        return start_job!(s, job.command, a, (_, _) -> throw(ArgumentError(
            "the job args have no file path, so \"$(job.command)\" cannot run again")), old)
    end
    e = exporter_for(job.command)
    if e !== nothing && e.id == job.command
        item_id, path = get(a, "item", ""), get(a, "path", "")
        if item_id isa AbstractString && path isa AbstractString && !isempty(item_id) && !isempty(path)
            settings = Dict{String,Any}(key => v for (key, v) in a if !(key in ("item", "path")))
            return start_job!(s, job.command, a, export_work(s, e, String(item_id), String(path), settings), nothing;
                              undoable = false)
        end
        return start_job!(s, job.command, a, (_, _) -> throw(ArgumentError(
            "the job args have no item or no file path, so \"$(job.command)\" cannot run again")); undoable = false)
    end
    t = find_tool(job.command)
    t !== nothing && t.mode == :job && return start_job!(s, job.command, a, tool_rerun_work(s, t, a), old)
    return start_job!(s, job.command, a, (_, _) -> throw(ArgumentError(
        "the command \"$(job.command)\" cannot be run again")), old)
end

# ---- exports ---------------------------------------------------------------

"""
    export_file(s, item_id, path; exporter = "", settings...)::Job

Export item `item_id` to the file `path` as a job (spec 7). `exporter` is an
exporter id, such as `"export.csv"`; blank picks the exporter by the extension
of `path` (see `exporter_for`). The settings go to the exporter, such as
`lines`, `channels` or `delimiter`.

The job reports progress by rows and can be cancelled. The file is written to
`path * ".tmp"` and renamed at the end; on cancel or failure the temp file is
removed and `path` is not touched. The job makes no project item and has no
undo step. It is recorded as the exporter id with `item`, `path` and the
settings. An unknown exporter gives a failed job; nothing is thrown.
"""
function export_file(s::Session, item_id::AbstractString, path::AbstractString; exporter::AbstractString = "",
                     kwargs...)::Job
    settings = Dict{String,Any}(String(k) => plain_arg(v) for (k, v) in kwargs)
    args = merge(settings, Dict{String,Any}("item" => String(item_id), "path" => String(path)))
    spec = exporter_for(isempty(exporter) ? path : exporter)
    if spec === nothing || (!isempty(exporter) && spec.id != exporter)
        what = isempty(exporter) ? "no exporter for the file type of $path" : "no exporter with id \"$exporter\""
        return start_job!(s, "export", args, (_, _) -> throw(ArgumentError(what)); undoable = false)
    end
    return start_job!(s, spec.id, args, export_work(s, spec, String(item_id), String(path), settings);
                      undoable = false)
end

function export_work(s::Session, spec::ExporterSpec, item_id::String, path::String, settings::Dict{String,Any})
    return (progress::Progress, io::IO) -> begin
        r = spec.run(s, item_id, path, settings, progress)::ExportResult
        println(io, spec.name, " export of ", item_id, " to ", r.path, ": ", r.rows, " rows in ", r.lines, " lines")
        foreach(n -> println(io, n), r.notes)
        return ProjectItem[]
    end
end
