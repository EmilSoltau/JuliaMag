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

const JOB_FOLDERS_KEY = :juliamag_job_folders

"""
    note_job_folder!(path)

Tell the running job about a temp folder its work made, such as
`databases/.importing-<id>`. If the job fails or is cancelled, the folder is
removed. Outside a job this does nothing.
"""
function note_job_folder!(path::AbstractString)
    folders = get(task_local_storage(), JOB_FOLDERS_KEY, nothing)
    folders isa Vector{String} && push!(folders, String(path))
    return nothing
end
