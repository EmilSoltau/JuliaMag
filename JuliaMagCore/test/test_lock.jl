using JSON3

lock_path(folder) = joinpath(folder, JuliaMagCore.LOCK_FILE)
lock_record(folder) = JSON3.read(read(lock_path(folder), String), Dict{String,Any})
write_lock(folder; pid, host = gethostname(), user = "ann", started = "2026-10-01T08:00:00+0200") =
    write(lock_path(folder), JSON3.write(Dict("pid" => pid, "host" => host, "user" => user, "started" => started)))

"The pid of a process that has ended. It waits on its input, so the pid is taken while it runs."
function ended_pid()
    p = open(`$(Base.julia_cmd()) --startup-file=no -e "read(stdin)"`, "w")
    pid = getpid(p)
    close(p)
    wait(p)
    return pid
end

@testset "project lock" begin
    @testset "one session at a time" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            @test JuliaMagCore.LOCK_FILE == "project.lock"
            r = lock_record(folder)
            @test r["pid"] == getpid() && r["host"] == gethostname()
            @test r["user"] isa String && !isempty(r["started"])
            @test isempty(s.warnings)
            e = try
                open_session(folder)
            catch err
                err
            end
            @test e isa ProjectLockedError
            @test e.folder == folder && e.host == gethostname() && e.started == r["started"]
            msg = sprint(showerror, e)
            @test occursin(r["user"], msg) && occursin(gethostname(), msg) && occursin(r["started"], msg)
            @test occursin("force = true", msg)
            # the lock file is not an item
            @test isempty(s.project.items) && isempty(open_project(folder).items)
            close_session!(s)
            @test !isfile(lock_path(folder))
            close_session!(s)                     # a second close does nothing
            s2 = open_session(folder)             # works after close
            @test isfile(lock_path(folder)) && isempty(s2.warnings)
            close_session!(s2)
        end
    end

    @testset "new_session refuses a locked folder and keeps its project" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            before = read(joinpath(folder, "project.jmag.json"), String)
            @test_throws ProjectLockedError new_session(folder, "Other")
            @test read(joinpath(folder, "project.jmag.json"), String) == before
            close_session!(s)
        end
    end

    @testset "a missing project leaves no lock" begin
        mktempdir() do dir
            @test_throws ProjectError open_session(dir)
            @test !isfile(lock_path(dir))
        end
    end

    @testset "stale lock of an ended process is taken over" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            pid = ended_pid()
            write_lock(folder; pid)
            s = open_session(folder)
            @test length(s.warnings) == 1
            @test occursin("ann", s.warnings[1]) && occursin("taken over", s.warnings[1])
            @test lock_record(folder)["pid"] == getpid()
            close_session!(s)
            @test !isfile(lock_path(folder))
        end
    end

    @testset "a lock this process wrote for another folder is stale" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            cp(folder, joinpath(dir, "copy"))     # the copy has the lock of `s`
            c = open_session(joinpath(dir, "copy"))
            @test length(c.warnings) == 1 && occursin("taken over", c.warnings[1])
            close_session!(c)
            @test isfile(lock_path(folder))       # closing the copy keeps the lock of `s`
            close_session!(s)
        end
    end

    @testset "close keeps a lock that is no longer ours" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            write_lock(folder; pid = 12345, host = "other-pc", user = "bob")   # taken with force elsewhere
            close_session!(s)
            @test lock_record(folder)["host"] == "other-pc"
            s = open_session(folder; force = true)
            write(lock_path(folder), "{\"pid\":")                            # a broken lock is not ours either
            close_session!(s)
            @test isfile(lock_path(folder))
        end
    end

    @testset "a lock from another host is refused" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            write_lock(folder; pid = ended_pid(), host = "other-pc", user = "bob")
            e = try
                open_session(folder)
            catch err
                err
            end
            @test e isa ProjectLockedError && e.host == "other-pc" && e.user == "bob"
            @test lock_record(folder)["host"] == "other-pc"
        end
    end

    @testset "force opens a locked project and warns" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            write_lock(folder; pid = 12345, host = "other-pc", user = "bob")
            s = open_session(folder; force = true)
            @test length(s.warnings) == 1
            @test occursin("bob", s.warnings[1]) && occursin("other-pc", s.warnings[1])
            @test occursin("force = true", s.warnings[1])
            @test lock_record(folder)["pid"] == getpid()
            close_session!(s)
            @test !isfile(lock_path(folder))
        end
    end

    @testset "a broken lock is taken over" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            write(lock_path(folder), "{\"pid\":")
            s = open_session(folder)
            @test length(s.warnings) == 1 && occursin("broken", s.warnings[1])
            close_session!(s)
        end
    end

    @testset "close cancels and waits for running jobs" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            started = Threads.Event()
            j = start_job!(s, "test.loop", Dict{String,Any}(), (p, r) -> begin
                notify(started)
                while !is_cancelled(p)
                    sleep(0.01)
                end
                error("stopped")
            end)
            wait(started)
            close_session!(s)
            @test status(j) == JOB_CANCELLED && istaskdone(j.task)
            @test !isfile(lock_path(folder))
        end
    end

    @testset "another spelling of the folder finds the lock" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            s = new_session(folder, "P")
            link = joinpath(dir, "link")
            symlink(folder, link)
            @test_throws ProjectLockedError open_session(link)
            @test_throws ProjectLockedError open_session(joinpath(dir, ".", "p", ""))
            @test lock_record(folder)["started"] == s.held_lock.record.started
            close_session!(s)
            c = open_session(link)
            @test isempty(c.warnings)
            close_session!(c)
            @test !isfile(lock_path(folder))
        end
    end

    @testset "a failed open with force puts the other lock back" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            pfile = joinpath(folder, "project.jmag.json")
            good = read(pfile, String)
            write(pfile, "{")
            write_lock(folder; pid = 12345, host = "other-pc", user = "bob")
            before = read(lock_path(folder), String)
            @test_throws ProjectError open_session(folder; force = true)
            @test lock_record(folder) == JSON3.read(before, Dict{String,Any})
            # a stale lock that was taken over is just removed
            write_lock(folder; pid = ended_pid())
            @test_throws ProjectError open_session(folder)
            @test !isfile(lock_path(folder))
            write(pfile, good)
            close_session!(open_session(folder))
            @test !any(startswith(".project.lock"), readdir(folder))      # no temp files left
        end
    end

    @testset "the lock file is made by one creator only" begin
        mktempdir() do dir
            path = lock_path(dir)
            rec = JuliaMagCore.LockRecord(1, "h", "u", "t")
            wins = zeros(Int, 16)
            Threads.@threads for i in 1:16
                wins[i] = JuliaMagCore.create_lock(path, rec, String[]) ? 1 : 0
            end
            @test sum(wins) == 1
            @test readdir(dir) == [JuliaMagCore.LOCK_FILE]
        end
    end

    @testset "two takers of one stale lock, step by step: one wins" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            write_lock(folder; pid = ended_pid())
            path = lock_path(folder)
            raw = read(path)                                    # both takers checked this lock
            a = JuliaMagCore.LockRecord(111, gethostname(), "a", "t1")
            b = JuliaMagCore.LockRecord(222, gethostname(), "b", "t2")
            JuliaMagCore.take_over!(path, raw, folder)          # A clears it and makes its lock
            @test JuliaMagCore.create_lock(path, a, String[])
            e = try
                JuliaMagCore.take_over!(path, raw, folder)      # B moves A's lock aside, sees it is new
            catch err
                err
            end
            @test e isa ProjectLockedError && e.user == "a"
            @test lock_record(folder)["user"] == "a"            # A's lock is back
            @test !JuliaMagCore.create_lock(path, b, String[])
            rm(path)
            @test JuliaMagCore.take_over!(path, raw, folder) === nothing   # gone: nothing to clear
            @test readdir(folder) == sort(["databases", "grids", "jobs", "templates", "project.jmag.json"])
        end
    end

    @testset "putting a moved lock back without hard links, or when it cannot be" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            path = lock_path(folder)
            write_lock(folder; pid = ended_pid())
            raw = read(path)                                    # both takers checked this lock
            a = JuliaMagCore.LockRecord(111, gethostname(), "a", "t1")
            JuliaMagCore.take_over!(path, raw, folder)          # A takes it over
            @test JuliaMagCore.create_lock(path, a, String[])
            fresh = read(path)
            no_links(_, _) = throw(Base.IOError("hardlink: operation not permitted (EPERM)", Base.UV_EPERM))
            take(link) = try
                JuliaMagCore.take_over!(path, raw, folder; link)
            catch err
                err
            end
            sides() = filter(startswith(".project.lock"), readdir(folder))
            # no hard links: A's lock is renamed back and B is refused
            e = take(no_links)
            @test e isa ProjectLockedError && e.user == "a" && isempty(e.note)
            @test read(path) == fresh && isempty(sides())
            # no hard links, and a third lock took the path meanwhile: A's lock is kept aside
            third(src, dst) = (write_lock(folder; pid = 333, user = "c"); no_links(src, dst))
            e = take(third)
            @test e isa ProjectLockedError && e.user == "a"
            side = only(sides())
            @test occursin(side, e.note) && occursin(side, sprint(showerror, e))
            @test read(joinpath(folder, side)) == fresh && lock_record(folder)["user"] == "c"
            rm(joinpath(folder, side)); write(path, fresh)
            # any other error: the moved lock is kept and named
            broken(_, _) = throw(Base.IOError("hardlink: i/o error (EIO)", Base.UV_EIO))
            e = take(broken)
            @test e isa ProjectLockedError && e.user == "a"
            side = only(sides())
            @test occursin(side, e.note) && occursin("EIO", e.note)
            @test read(joinpath(folder, side)) == fresh && !isfile(path)
        end
    end

    @testset "another program takes over between the check and the take-over" begin
        hook = JuliaMagCore.TAKE_OVER_HOOK
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            path = lock_path(folder)
            a = JuliaMagCore.LockRecord(111, "other-pc", "a", "t1")
            # the other program does its whole take-over at that moment
            other() = (JuliaMagCore.take_over!(path, read(path), folder); JuliaMagCore.create_lock(path, a, String[]))
            try
                for (pid, host, force) in ((ended_pid(), gethostname(), false), (12345, "other-pc", true))
                    write_lock(folder; pid, host)
                    hook[] = other
                    e = try
                        open_session(folder; force)
                    catch err
                        err
                    end
                    @test e isa ProjectLockedError && e.user == "a"
                    @test lock_record(folder)["user"] == "a"
                end
                # the other program only removed it: this session gets the lock
                write_lock(folder; pid = ended_pid())
                hook[] = () -> rm(path)
                s = open_session(folder)
                @test lock_record(folder)["pid"] == getpid() && length(s.warnings) == 1
                close_session!(s)
            finally
                hook[] = () -> nothing
            end
            @test !any(startswith(".project.lock"), readdir(folder))
        end
    end

    @testset "only a file system without hard links gives the plain way" begin
        unsupported = JuliaMagCore.links_unsupported
        @test unsupported(Base.IOError("link", Base.UV_EPERM))
        @test unsupported(Base.IOError("link", Base.UV_ENOTSUP))
        @test unsupported(Base.IOError("link", Base.UV_ENOSYS))
        for code in (Base.UV_EACCES, Base.UV_EIO, Base.UV_ENOSPC, Base.UV_EMLINK, Base.UV_ENAMETOOLONG)
            @test !unsupported(Base.IOError("link", code))
        end
        @test !unsupported(ErrorException("x"))
        # a folder that cannot be written: the open fails, with no lock written
        Sys.iswindows() || mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            chmod(folder, 0o555)
            try
                @test_throws SystemError open_session(folder)
                @test !isfile(lock_path(folder))
            finally
                chmod(folder, 0o755)
            end
        end
    end

    @testset "two programs open a project at the same moment: one wins" begin
        mktempdir() do dir
            folder = joinpath(dir, "p")
            close_session!(new_session(folder, "P"))
            go = joinpath(dir, "go")
            code = """
                using JuliaMagCore
                println("ready"); flush(stdout)
                while !isfile($(repr(go))); sleep(0.001); end
                try
                    open_session($(repr(folder)))
                    println("won"); flush(stdout)
                    readline(stdin)                  # hold the lock until the test ends
                catch e
                    e isa ProjectLockedError || rethrow()
                    println("locked"); flush(stdout)
                end
                """
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
            procs = [open(cmd, "r+") for _ in 1:2]
            @test all(p -> readline(p) == "ready", procs)
            touch(go)
            @test sort([readline(p) for p in procs]) == ["locked", "won"]
            foreach(close, procs)
            foreach(wait, procs)
            @test all(success, procs)
            @test !isfile(lock_path(folder))
        end
    end

    @testset "locks of open sessions are removed at exit" begin
        mktempdir() do dir
            a, b = joinpath(dir, "a"), joinpath(dir, "b")
            code = """
                using JuliaMagCore
                new_session($(repr(a)), "A")
                new_session($(repr(b)), "B")
                rm($(repr(b)); recursive = true)    # a lock that is gone at exit must not print
                """
            out, err = IOBuffer(), IOBuffer()
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
            run(pipeline(cmd; stdout = out, stderr = err))
            @test isfile(joinpath(a, "project.jmag.json"))
            @test !isfile(lock_path(a))
            @test isempty(String(take!(out))) && isempty(String(take!(err)))
        end
    end
end
