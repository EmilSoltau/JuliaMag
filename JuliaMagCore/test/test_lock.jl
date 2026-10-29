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
