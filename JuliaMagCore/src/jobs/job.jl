# The job type. It comes before the session, which keeps a list of jobs.
# How jobs run is in jobs.jl.

"""
State of a job. `JOB_UNDONE` is a finished job whose outputs were taken out of
the project by undo (spec 13.4). Redo makes it `JOB_DONE` again.
"""
@enum JobStatus JOB_RUNNING JOB_DONE JOB_FAILED JOB_CANCELLED JOB_UNDONE

"""
One run of a long task, such as an import. Made by `start_job!`.

- `status`, `progress` (0 to 1) and `cancel` are atomics: other threads read them.
- `report` is the text the work wrote. It is saved with the job.
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
    report::IOBuffer
    outputs::Vector{String}
    error::String
    task::Union{Nothing,Task}
end

"The state of a job now."
status(job::Job)::JobStatus = JobStatus(job.status[])

set_status!(job::Job, st::JobStatus) = (job.status[] = Int(st); nothing)

"""
What the work of a running job noted with `note_job_folder!`, `note_job_item!`
and `note_job_undo!`. It lives in the task-local storage of the job's task.
Tasks that the work starts itself do not see it.
"""
struct JobContext
    folders::Vector{String}
    items::Vector{String}
    "Steps as (undo, redo, drop), in the order they were noted."
    undos::Vector{NTuple{3,Function}}
    "Ids of existing items that the noted steps change."
    touched::Vector{String}
end

JobContext() = JobContext(String[], String[], NTuple{3,Function}[], String[])

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
    push!(c.undos, (undo, redo, drop))
    append!(c.touched, items)
    return nothing
end
