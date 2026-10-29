# The job type. It comes before the session, which keeps a list of jobs.
# How jobs run is in jobs.jl.

"""
State of a job. `JOB_UNDONE` is a finished job whose outputs were taken out of
the project by undo (spec 13.4). Redo makes it `JOB_DONE` again.
"""
@enum JobStatus JOB_RUNNING JOB_DONE JOB_FAILED JOB_CANCELLED JOB_UNDONE

"""
The report of a job: the text its work writes. Other threads read it while the
job runs, such as the Jobs tab, so each write and each read takes `lock`.
`print(report, a, b, ...)` and `println` write their parts as one piece.
Read it with `report_text(job)`.
"""
struct JobReport <: IO
    buf::IOBuffer
    lock::ReentrantLock
end

JobReport() = JobReport(IOBuffer(), ReentrantLock())

function JobReport(text::AbstractString)
    r = JobReport()
    write(r.buf, text)
    return r
end

# `print` and `println` with several parts hold the lock of the IO for all parts.
Base.lock(r::JobReport) = lock(r.lock)
Base.unlock(r::JobReport) = unlock(r.lock)
Base.unsafe_write(r::JobReport, p::Ptr{UInt8}, n::UInt) = @lock r.lock unsafe_write(r.buf, p, n)
Base.write(r::JobReport, b::UInt8) = @lock r.lock write(r.buf, b)
Base.isopen(::JobReport) = true
Base.iswritable(::JobReport) = true
Base.isreadable(::JobReport) = false

"""
One run of a long task, such as an import. Made by `start_job!`.

- `status`, `progress` (0 to 1) and `cancel` are atomics: other threads read them.
- `report` is the text the work wrote (a `JobReport`). It is saved with the job.
  Read it with `report_text(job)`, which is safe while the job runs.
- `warnings` are things the user should check, from `job_warning!`. They are
  saved with the job. Read them with `job_warnings(job)`.
- `outputs` are the ids of the project items the job made.
- `error` is the message of a failed or cancelled job.
- `task` runs the work. It is `nothing` for a job loaded from disk.
"""
mutable struct Job
    id::String
    command::String
    args::Dict{String,Any}
    status::Threads.Atomic{Int}
    progress::Threads.Atomic{Float64}
    cancel::Threads.Atomic{Bool}
    started::String
    finished::String
    report::JobReport
    "Guarded by the lock of `report`."
    warnings::Vector{String}
    outputs::Vector{String}
    error::String
    task::Union{Nothing,Task}
end

"""
    job_warnings(job)::Vector{String}

The warnings of a job, as a copy. Safe from any thread while the job runs.
"""
job_warnings(job::Job)::Vector{String} = @lock job.report.lock copy(job.warnings)

"Add a warning to the job and a line for it to its report. Safe from any thread."
function add_job_warning!(job::Job, text::AbstractString)
    @lock job.report.lock begin
        push!(job.warnings, String(text))
        println(job.report, "Warning: ", text)
    end
    return nothing
end

"The state of a job now."
status(job::Job)::JobStatus = JobStatus(job.status[])

set_status!(job::Job, st::JobStatus) = (job.status[] = Int(st); nothing)

"""
A change noted with `note_job_undo!`: how to undo, redo and drop it, and the
ids of the existing items it touches.
"""
struct NotedUndo
    undo::Function
    redo::Function
    drop::Function
    items::Vector{String}
end

"""
What the work of a running job noted with `note_job_folder!`, `note_job_item!`
and `note_job_undo!`. It lives in the task-local storage of the job's task.
Tasks that the work starts itself do not see it.
"""
struct JobContext
    "The job, or `nothing` in tests that run work without one."
    job::Union{Nothing,Job}
    folders::Vector{String}
    items::Vector{String}
    "Steps from `note_job_undo!`, in the order they were noted."
    undos::Vector{NotedUndo}
    "Ids of existing items that the noted steps change."
    touched::Vector{String}
    "Args to add to the job's record, from `note_job_args!`."
    args::Dict{String,Any}
    "Items the work marked busy with `mark_busy!`. The job ends these marks when it ends."
    busy::Vector{String}
end

JobContext(job::Union{Nothing,Job} = nothing) =
    JobContext(job, String[], String[], NotedUndo[], String[], Dict{String,Any}(), String[])

const JOB_CONTEXT_KEY = :juliamag_job_context

function job_context()::Union{Nothing,JobContext}
    c = get(task_local_storage(), JOB_CONTEXT_KEY, nothing)
    return c isa JobContext ? c : nothing
end

"""
    note_job_folder!(path)

Tell the running job about a temp folder its work made, such as
`databases/.importing-<id>`. If the job fails or is cancelled, the folder is
removed. Outside a job this does nothing.
"""
function note_job_folder!(path::AbstractString)
    c = job_context()
    c === nothing || push!(c.folders, String(path))
    return nothing
end

"""
    note_job_item!(id)

Tell the running job that its work added item `id` to the project.
If the job fails, the item is taken out and its files are deleted.
`add_item!` calls this. Outside a job this does nothing.
"""
function note_job_item!(id::AbstractString)
    c = job_context()
    c === nothing || push!(c.items, String(id))
    return nothing
end

"""
    note_job_args!(args)

Tell the running job to add `args` to the args it records, when it is done.
An importer uses it to record what it worked out, such as the layout it read
from a template, so the job can run again the same way. Outside a job this
does nothing.
"""
function note_job_args!(args::AbstractDict)
    c = job_context()
    c === nothing || merge!(c.args, Dict{String,Any}(String(k) => v for (k, v) in args))
    return nothing
end

"""
    note_job_undo!(undo, redo, drop; items = String[])

Tell the running job how to undo a change its work made that is not a new item,
such as rows appended to a database. The job's undo step runs `undo`, its redo
runs `redo`, and `drop` frees what `undo` kept once redo is no longer possible.
`items` are the ids of the items the change touches; the job's undo step is
refused while one of them is busy.
If the job fails after the change, `undo` and then `drop` run at once.
Outside a job this does nothing.
"""
function note_job_undo!(undo::Function, redo::Function, drop::Function; items::Vector{String} = String[])
    c = job_context()
    c === nothing && return nothing
    push!(c.undos, NotedUndo(undo, redo, drop, copy(items)))
    append!(c.touched, items)
    return nothing
end

"""
    job_warning!(text)

Add a warning to the running job: something the user should check, although
the job did its work. `jobs(s)` and the saved job record show it, and the
report gets a line for it. Outside a job this does nothing.
"""
function job_warning!(text::AbstractString)
    c = job_context()
    (c === nothing || c.job === nothing) || add_job_warning!(something(c.job), text)
    return nothing
end
