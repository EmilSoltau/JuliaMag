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
# The lock file is made with an exclusive create: the record is written to a
# temp file of its own, which is then hard linked to `project.lock`. The link
# fails when the lock is there, so of two programs that open a project at the
# same moment only one gets it. On a file system without hard links the lock
# is written the plain way, with a session warning.
#
# The lock file is not listed in `project.jmag.json`, so it is never an item.

using JSON3

const LOCK_FILE = "project.lock"

"""
The project in `folder` is open in another session: by `user` on the computer
`host`, since `started`. `open_session(folder; force = true)` opens it anyway.
`note` says more when a take-over of the lock went wrong, else it is `""`.
"""
struct ProjectLockedError <: Exception
    folder::String
    host::String
    user::String
    started::String
    note::String
end

ProjectLockedError(folder, host, user, started) = ProjectLockedError(folder, host, user, started, "")

function Base.showerror(io::IO, e::ProjectLockedError)
    who = isempty(e.user) ? "another user" : e.user
    print(io, "ProjectLockedError: the project in ", e.folder, " is open by ", who, " on ", e.host,
          " since ", e.started, ". Close it there first, or use force = true to open it anyway.")
    isempty(e.note) || print(io, " ", e.note)
end

"What a lock file holds."
struct LockRecord
    pid::Int
    host::String
    user::String
    started::String
end

"A lock that this process holds. `key` is the `lock_key` of its folder."
struct HeldLock
    path::String
    key::String
    record::LockRecord
end

# The locks this process holds, for the `atexit` hook. Guarded by `HELD_LOCKS_LOCK`,
# which `take_lock!` holds from its check to the end, so two sessions of this
# process never take the same lock at once.
const HELD_LOCKS = HeldLock[]
const HELD_LOCKS_LOCK = ReentrantLock()

# For tests only: runs in `take_lock!` between the check of a lock and its
# take-over, so a test can act as another program at that moment.
const TAKE_OVER_HOOK = Ref{Function}(() -> nothing)

function user_name()::String
    try
        return Sys.username()
    catch e
        e isa InterruptException && rethrow()
        return get(ENV, Sys.iswindows() ? "USERNAME" : "USER", "")
    end
end

"The record in the bytes of a lock file. Throws when they are broken."
function parse_lock(bytes::Vector{UInt8})::LockRecord
    d = plain(JSON3.read(String(copy(bytes))))::Dict{String,Any}
    return LockRecord(d["pid"]::Int, d["host"]::String, d["user"]::String, d["started"]::String)
end

"Read a lock file. `nothing` when there is none. Throws when it is broken."
read_lock(path::String)::Union{Nothing,LockRecord} = isfile(path) ? parse_lock(read(path)) : nothing

"A file name in the folder of `path` that no other program or call uses."
side_name(path::String, ext::String) =
    joinpath(dirname(path), ".$(LOCK_FILE).$(getpid()).$(string(rand(UInt64); base = 36)).$ext")

# The errors of `hardlink` that mean the file system has no hard links. Linux
# gives EPERM on FAT. On Windows, libuv turns ERROR_INVALID_FUNCTION (FAT) into
# EISDIR and ERROR_NOT_SUPPORTED into ENOTSUP. Not checked on a real system yet.
const NO_LINK_CODES = @static Sys.iswindows() ? (Base.UV_ENOTSUP, Base.UV_ENOSYS, Base.UV_EPERM, Base.UV_EISDIR) :
                                                (Base.UV_EPERM, Base.UV_ENOTSUP, Base.UV_ENOSYS)

"True when the error `e` of `hardlink` means the file system has no hard links."
links_unsupported(e)::Bool = e isa Base.IOError && e.code in NO_LINK_CODES

lock_dict(r::LockRecord) = Dict("pid" => r.pid, "host" => r.host, "user" => r.user, "started" => r.started)

"Write a lock file over what is there (see `write_json_atomic`)."
write_lock(path::String, r::LockRecord) = (write_json_atomic(path, lock_dict(r)); nothing)

"""
    create_lock(path, r, warnings)::Bool

Make the lock file only when there is none: write the record to a temp file of
its own and hard link it to `path`. False when a lock is there.
Where the file system has no hard links, the lock is written the plain way,
with a note in `warnings`. Other errors are thrown.
"""
function create_lock(path::String, r::LockRecord, warnings::Vector{String})::Bool
    tmp = side_name(path, "tmp")
    try
        open(io -> JSON3.pretty(io, JSON3.write(lock_dict(r))), tmp, "w")
        try
            hardlink(tmp, path)
            return true
        catch e
            e isa Base.IOError && e.code == Base.UV_EEXIST && return false
            links_unsupported(e) || rethrow()
            isfile(path) && return false
            write_lock(path, r)
            push!(warnings, "$path: this file system has no hard links, so the lock was written the plain way. " *
                            "Two programs that open the project at the same moment may both get it.")
            return true
        end
    finally
        rm(tmp; force = true)
    end
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
The key of a project folder in `HELD_LOCKS`: its real path, so a link or another
spelling of the same folder gives the same key. The folder must exist.
"""
lock_key(folder::String)::String = folder_key(realpath(folder))

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

"The error for a lock that another program is making at this moment."
lock_in_making(folder::String, note::String = "") =
    ProjectLockedError(folder, "a computer not known yet", "another program", now_text(), note)

"The error for the lock file `path`, from what it holds."
function locked_error(folder::String, path::String)::ProjectLockedError
    r = try
        read_lock(path)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    return r === nothing ? lock_in_making(folder) : ProjectLockedError(folder, r.host, r.user, r.started)
end

"""
    take_over!(path, raw, folder; link = hardlink)

Clear the lock file `path` for a take-over, but only while it still holds the
bytes `raw` that were checked. It is never removed in place: it is renamed
aside first, so a lock that another program made after the check is not lost.
- The file is gone: another program took it over; nothing to do here.
- The moved file holds `raw`: it is removed.
- It holds something else: it is a new lock. It is put back and
  `ProjectLockedError` is thrown. On a file system without hard links it is
  renamed back when the path is still free. When it cannot be put back, the
  moved file is kept and the error names it, since it may be the only copy of
  a live lock.
`link` is `hardlink`; tests pass another function.
"""
function take_over!(path::String, raw::Vector{UInt8}, folder::String; link::Function = hardlink)
    aside = side_name(path, "old")
    try
        Base.rename(path, aside)
    catch e
        e isa Base.IOError && e.code == Base.UV_ENOENT && return nothing
        rethrow()
    end
    moved = read(aside)
    if moved == raw
        rm(aside; force = true)
        return nothing
    end
    note = ""
    try
        link(aside, path)
        rm(aside; force = true)
    catch e
        e isa InterruptException && rethrow()
        if links_unsupported(e) && !isfile(path)
            Base.rename(aside, path)                  # no hard links: the same weak way as the plain create
        elseif (e isa Base.IOError && e.code == Base.UV_EEXIST) || links_unsupported(e)
            note = "Another program made a lock while this one was moved aside. " *
                   "The moved lock was kept as $aside."
        else
            note = "The lock could not be put back ($(sprint(showerror, e))). It was kept as $aside."
        end
    end
    r = try
        parse_lock(moved)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    r === nothing && throw(lock_in_making(folder, note))
    throw(ProjectLockedError(folder, r.host, r.user, r.started, note))
end

"""
    take_lock!(folder, force, warnings)::Tuple{HeldLock,Union{Nothing,LockRecord}}

Make the lock file of the project in `folder`, or throw `ProjectLockedError`.
Notes about a lock that was there go to `warnings`.
Also returns the record of a live lock that `force = true` replaced, so a
failed open can put it back (see `restore_lock!`), else `nothing`.

A lock that is there is checked. When it may be taken (stale, broken, or
`force`), `take_over!` clears it and the create runs once more. Of two
programs that take over the same lock at once, one gets it and the other gets
`ProjectLockedError`. One window is left: while the second program has the
first one's new lock moved aside, a third program finds no lock and makes its
own. Then the first and the third both run, and the second one's error names
the side file that keeps the first one's lock.
"""
function take_lock!(folder::String, force::Bool, warnings::Vector{String})
    path = joinpath(folder, LOCK_FILE)
    key = lock_key(folder)
    me = LockRecord(getpid(), gethostname(), user_name(), now_text())
    lock(HELD_LOCKS_LOCK) do
        replaced = nothing
        for attempt in 1:2
            if create_lock(path, me, warnings)
                h = HeldLock(path, key, me)
                push!(HELD_LOCKS, h)
                return (h, replaced)
            end
            attempt == 2 && break
            raw = try
                read(path)
            catch e
                e isa InterruptException && rethrow()
                continue                                   # gone again: try the create once more
            end
            old = try
                parse_lock(raw)
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
                    replaced = old
                else
                    throw(ProjectLockedError(folder, old.host, old.user, old.started))
                end
            end
            TAKE_OVER_HOOK[]()
            take_over!(path, raw, folder)
        end
        throw(locked_error(folder, path))
    end
end

"""
Undo `take_lock!` after a failed open that replaced the live lock `old` with
`force = true`: put `old` back, so the other session keeps its lock.
"""
function restore_lock!(h::HeldLock, old::LockRecord)
    lock(() -> filter!(x -> x !== h, HELD_LOCKS), HELD_LOCKS_LOCK)
    r = try
        read_lock(h.path)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    r == h.record && write_lock(h.path, old)
    return nothing
end

"""
True when the lock file of `h` still holds our record. False when it is gone,
cannot be read, or holds another record, such as after another session opened
the project with `force = true`.
"""
function lock_is_ours(h::HeldLock)::Bool
    r = try
        read_lock(h.path)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    return r == h.record
end

"""
Remove a lock that this process holds. The file is kept when it is no longer
ours (see `lock_is_ours`).
"""
function release_lock!(h::HeldLock)
    lock(() -> filter!(x -> x !== h, HELD_LOCKS), HELD_LOCKS_LOCK)
    lock_is_ours(h) && rm(h.path; force = true)
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
