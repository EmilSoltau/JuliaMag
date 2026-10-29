# The project lock file: one session at a time per project folder.
#
# `open_session` and `new_session` write `project.lock` in the project folder,
# and `close_session!` removes it. An `atexit` hook removes the locks of
# sessions that are still open when the program ends.
#
# A lock that is there already is refused with `ProjectLockedError`, unless it
# is stale: written on this computer by a process that has ended. A stale lock
# is taken over with a session warning. `force = true` opens a locked project
# anyway, also with a warning.
#
# The lock file is not listed in `project.jmag.json`, so it is never an item.

using JSON3

const LOCK_FILE = "project.lock"

"""
The project in `folder` is open in another session: by `user` on the computer
`host`, since `started`. `open_session(folder; force = true)` opens it anyway.
"""
struct ProjectLockedError <: Exception
    folder::String
    host::String
    user::String
    started::String
end

function Base.showerror(io::IO, e::ProjectLockedError)
    who = isempty(e.user) ? "another user" : e.user
    print(io, "ProjectLockedError: the project in ", e.folder, " is open by ", who, " on ", e.host,
          " since ", e.started, ". Close it there first, or use force = true to open it anyway.")
end

"What a lock file holds."
struct LockRecord
    pid::Int
    host::String
    user::String
    started::String
end

"A lock that this process holds. `key` is the `folder_key` of `path`."
struct HeldLock
    path::String
    key::String
    record::LockRecord
end

# The locks this process holds, for the `atexit` hook. Guarded by `HELD_LOCKS_LOCK`.
const HELD_LOCKS = HeldLock[]
const HELD_LOCKS_LOCK = ReentrantLock()

function user_name()::String
    try
        return Sys.username()
    catch e
        e isa InterruptException && rethrow()
        return get(ENV, Sys.iswindows() ? "USERNAME" : "USER", "")
    end
end

"Read a lock file. `nothing` when there is none. Throws when it is broken."
function read_lock(path::String)::Union{Nothing,LockRecord}
    isfile(path) || return nothing
    d = plain(JSON3.read(read(path, String)))::Dict{String,Any}
    return LockRecord(d["pid"]::Int, d["host"]::String, d["user"]::String, d["started"]::String)
end

function write_lock(path::String, r::LockRecord)
    write_json_atomic(path, Dict("pid" => r.pid, "host" => r.host, "user" => r.user, "started" => r.started))
    return nothing
end

"True when the process `pid` on this computer still runs."
function pid_running(pid::Int)::Bool
    pid > 0 || return false
    @static if Sys.iswindows()
        return windows_pid_running(pid)
    elseif Sys.islinux()
        return isdir("/proc/$pid")
    else
        ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0 && return true
        return Libc.errno() == Libc.EPERM          # it runs, under another user
    end
end

@static if Sys.iswindows()
    function windows_pid_running(pid::Int)::Bool
        PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000
        h = ccall((:OpenProcess, "kernel32"), stdcall, Ptr{Cvoid}, (UInt32, Cint, UInt32),
                  PROCESS_QUERY_LIMITED_INFORMATION, 0, pid % UInt32)
        h == C_NULL && return Libc.GetLastError() == 5      # ERROR_ACCESS_DENIED: it runs, under another user
        # A process that has ended can still be opened while a handle to it is open.
        code = Ref{UInt32}(0)
        ok = ccall((:GetExitCodeProcess, "kernel32"), stdcall, Cint, (Ptr{Cvoid}, Ref{UInt32}), h, code)
        ccall((:CloseHandle, "kernel32"), stdcall, Cint, (Ptr{Cvoid},), h)
        return ok == 0 || code[] == 259                      # STILL_ACTIVE
    end
end

"True when this process holds a lock with this key."
holds_lock(key::String)::Bool = lock(() -> any(h -> h.key == key, HELD_LOCKS), HELD_LOCKS_LOCK)

"""
True when the session that wrote `r` may still be open. A lock from another
computer cannot be checked, so it counts as open. A lock this process wrote
is open only while this process holds it for this folder; one that came with
a copied folder is not.
"""
function lock_alive(r::LockRecord, key::String)::Bool
    r.host == gethostname() || return true
    r.pid == getpid() && return holds_lock(key)
    return pid_running(r.pid)
end

"""
    take_lock!(folder, force, warnings)::HeldLock

Write the lock file of the project in `folder`, or throw `ProjectLockedError`.
Notes about a lock that was there go to `warnings`.
"""
function take_lock!(folder::String, force::Bool, warnings::Vector{String})::HeldLock
    path = joinpath(folder, LOCK_FILE)
    key = folder_key(path)
    old = try
        read_lock(path)
    catch e
        e isa InterruptException && rethrow()
        push!(warnings, "$path was broken; it was replaced: $(sprint(showerror, e))")
        nothing
    end
    if old !== nothing
        who = isempty(old.user) ? "another user" : old.user
        if !lock_alive(old, key)
            push!(warnings, "$path: the session of $who on this computer (process $(old.pid)), " *
                            "open since $(old.started), has ended; its lock was taken over")
        elseif force
            push!(warnings, "$path: the project is open by $who on $(old.host) since $(old.started); " *
                            "it was opened anyway (force = true)")
        else
            throw(ProjectLockedError(folder, old.host, old.user, old.started))
        end
    end
    h = HeldLock(path, key, LockRecord(getpid(), gethostname(), user_name(), now_text()))
    write_lock(path, h.record)
    lock(() -> push!(HELD_LOCKS, h), HELD_LOCKS_LOCK)
    return h
end

"""
Remove a lock that this process holds. The file is kept when it is no longer
ours, such as after another session opened the project with `force = true`,
or when it cannot be read.
"""
function release_lock!(h::HeldLock)
    lock(() -> filter!(x -> x !== h, HELD_LOCKS), HELD_LOCKS_LOCK)
    r = try
        read_lock(h.path)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    r == h.record && rm(h.path; force = true)
    return nothing
end

"""
The `atexit` hook: remove the locks of sessions that are still open.
Never throws and prints nothing, also when a lock or its folder is gone.
"""
function release_held_locks()
    held = try
        lock(() -> copy(HELD_LOCKS), HELD_LOCKS_LOCK)
    catch
        return nothing
    end
    for h in held
        try
            release_lock!(h)
        catch
            # The program is ending; a lock that cannot be removed is stale for the next session.
        end
    end
    return nothing
end
