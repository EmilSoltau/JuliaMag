using Test
import JuliaMagCore as Core
using JuliaMagUI: submit!, drain!, refresh!, user_message, toast!, prune_toasts!, Toast,
    TOAST_MS, TOAST_ACTIONS_MS, TOAST_JOB_FAILED_MS, MAX_TOASTS, set_session!

# Drain until `pred()` holds; an error after `timeout` s.
function drain_until(pred, app; timeout = 10)
    deadline = time() + timeout
    while true
        drain!(app)
        pred() && return nothing
        left = deadline - time()
        left > 0 || error("drain_until: the condition did not hold within $timeout s")
        timedwait(() -> isready(app.queue.results), left; pollint = 0.002)
    end
end

# A window whose wake fails, as `wake!` does when GLFW throws.
struct BrokenWaker end
UI.wake!(::BrokenWaker) = error("no display to wake")

# An exception that cannot even print itself.
struct UnprintableError <: Exception end
Base.showerror(::IO, ::UnprintableError) = error("cannot print this error")

@testset "worker" begin
    @testset "actions, errors and refresh" begin
        s = fresh_session()
        id = make_test_database!(s)
        with_app(test_app_state(s)) do app
            submit!(app, "rename", s -> Core.rename_item!(s, id, "New"))
            wait_drained(app)
            refresh_now!(app)
            @test only(app.snap.items).name == "New"
            @test isempty(app.toasts) && app.busy === nothing

            submit!(app, "bad", s -> Core.set_channel_protected!(s, id, "NOPE", true))
            wait_drained(app)
            @test last(app.toasts).kind == :error
            @test !occursin("Something went wrong", last(app.toasts).text)

            @test_logs (:error, "Unexpected error") begin
                submit!(app, "boom", s -> error("x"))
                wait_drained(app)
            end
            @test startswith(last(app.toasts).text, "Something went wrong")
            @test occursin("x", last(app.toasts).text)

            # The worker lives on after an error.
            result = Ref{Any}(nothing)
            submit!(app, "after", s -> 41 + 1; done = (app, r) -> (result[] = r))
            wait_drained(app)
            @test result[] == 42
        end
    end

    @testset "actions finish in submit order" begin
        with_app(test_app_state(fresh_session())) do app
            ran = Int[]
            finished = Int[]
            for k in 1:3
                submit!(app, "step $k", s -> (push!(ran, k); k); done = (app, r) -> push!(finished, r))
            end
            @test app.queue.pending == 3
            wait_drained(app)
            @test ran == [1, 2, 3] && finished == [1, 2, 3] && app.queue.pending == 0
        end
    end

    @testset "busy while an action runs" begin
        with_app(test_app_state(fresh_session())) do app
            go = Base.Event()
            submit!(app, "Renaming", s -> wait(go))
            try
                drain_until(() -> app.busy == "Renaming", app)
            finally
                notify(go)   # so the worker can stop, also when the wait failed
            end
            wait_drained(app)
            @test app.busy === nothing
        end
    end

    @testset "an error in done becomes a toast" begin
        with_app(test_app_state(fresh_session())) do app
            submit!(app, "ok", s -> 1; done = (app, r) -> throw(ArgumentError("no such channel")))
            wait_drained(app)
            @test last(app.toasts).kind == :error && last(app.toasts).text == "No such channel."
        end
    end

    @testset "an error that cannot print itself" begin
        with_app(test_app_state(fresh_session())) do app
            @test_logs (:error, "Unexpected error") begin
                submit!(app, "odd", s -> throw(UnprintableError()))
                wait_drained(app)
            end
            @test last(app.toasts).kind == :error && last(app.toasts).text == "Something went wrong."
        end
    end

    @testset "a failing wake does not end the worker" begin
        with_app(test_app_state(fresh_session())) do app
            # The action as `submit!` makes it, with a window whose wake throws.
            action = UI.WorkerAction("wake", s -> 7, (app, r) -> nothing, app.session, BrokenWaker())
            app.queue.pending += 1
            UI.run_action(action, app.queue.results)
            @test_logs (:error, "Could not wake the window") (:error, "Could not wake the window") wait_drained(app)
            @test app.busy === nothing
            # The snapshot task survives it too.
            UI.build_snapshot(app.session, Core.revision(app.session), app.queue.results, BrokenWaker())
            app.refreshing = true
            @test_logs (:error, "Could not wake the window") drain_until(() -> !app.refreshing, app)
            @test app.snap !== nothing
            # And the worker task still runs actions.
            submit!(app, "after", s -> 1)
            wait_drained(app)
            @test !istaskdone(app.queue.task)
        end
    end

    @testset "stop_worker! logs a failed worker task" begin
        dead = Threads.@spawn error("the worker died")
        w = UI.Worker(Channel{UI.WorkerAction}(Inf), Channel{Any}(Inf), dead, 0, nothing)
        @test_logs (:error, "The worker task failed") UI.stop_worker!(w)
        UI.stop_worker!(UI.Worker())   # a healthy worker stops quietly
    end

    @testset "an action on a closed session" begin
        s = fresh_session()
        id = make_test_database!(s)
        with_app(test_app_state(s)) do app
            Core.close_session!(s)
            submit!(app, "rename", s -> Core.rename_item!(s, id, "Late"))
            wait_drained(app)
            @test last(app.toasts).kind == :error
            @test last(app.toasts).text == "The project $(s.project.folder) is closed."
            refresh!(app)   # a closed session is not read again
            @test !app.refreshing
        end
    end

    @testset "session warnings show once" begin
        with_app(app_with_database()) do app
            s = app.session
            @test isempty(app.toasts)
            Core.session_warning!(s, "The history file has a broken line.")
            refresh_now!(app)
            @test count(t -> t.kind == :warn, app.toasts) == 1
            @test last(app.toasts).text == "The history file has a broken line."
            Core.session_warning!(s, "a side folder was kept")   # the core writes lower case
            refresh_now!(app)
            @test last(app.toasts).text == "A side folder was kept."
            Core.rename_item!(s, only(app.snap.items).id, "Other")
            refresh_now!(app)
            @test count(t -> t.kind == :warn, app.toasts) == 2 && app.seen_warnings == 2
        end
    end

    @testset "refresh" begin
        with_app(app_with_database()) do app
            s = app.session
            db = app.ui.current_db
            snap = app.snap
            refresh!(app)   # nothing changed
            @test !app.refreshing && app.snap === snap
            Core.rename_item!(s, db, "Changed")
            refresh!(app)
            @test app.refreshing
            refresh!(app)   # one build at a time
            @test app.refreshing
            refresh_now!(app)
            @test app.snap !== snap && only(app.snap.items).name == "Changed"

            # A build of a session the app no longer has is dropped, and does not end
            # the build of the new session.
            Core.rename_item!(s, db, "Again")
            late = UI.SnapshotDone(s, Core.revision(s), UI.snapshot(s), nothing)
            with_test_session(fresh_session()) do other
                set_session!(app, other)
                refresh!(app)
                @test app.refreshing
                put!(app.queue.results, late)   # the old build comes back first
                drain!(app)
                @test app.snap === nothing || app.snap.folder == other.project.folder
                refresh_now!(app)
                @test isempty(app.snap.items) && app.snap.folder == other.project.folder
            end
            set_session!(app, s)
            app.ui.current_db = db
            refresh_now!(app)
            @test only(app.snap.items).name == "Again"

            # A build that fails is logged and not tried again until the session changes.
            Core.rename_item!(s, db, "Third")
            rev = Core.revision(s)
            app.refreshing = true   # as `refresh!` sets it when it starts a build
            failure = CapturedException(ErrorException("disk gone"), backtrace())
            put!(app.queue.results, UI.SnapshotDone(s, rev, nothing, failure))
            @test_logs (:error, "Could not read the project state") drain!(app)
            @test !app.refreshing && only(app.snap.items).name == "Again"
            refresh!(app)
            @test !app.refreshing
            Core.rename_item!(s, db, "Fourth")
            refresh_now!(app)
            @test only(app.snap.items).name == "Fourth"
        end
    end

    @testset "user_message" begin
        @test user_message(Core.ToolError("Pick a channel.")) == "Pick a channel."
        @test user_message(Core.ProtectedError("MAGP")) ==
              "Channel MAGP is protected and cannot be edited."
        @test user_message(Core.ItemBusyError("db-1", "an import is running")) ==
              "db-1 is busy: an import is running."
        @test startswith(user_message(Core.ProjectLockedError("/p", "host", "anna", "today")),
            "The project in /p is open by anna on host since today.")
        @test user_message(Core.SessionClosedError("/p")) == "The project /p is closed."
        @test user_message(Core.ProjectError("no item db-9")) == "No item db-9."
        @test user_message(Core.DatabaseError("database.json is broken")) ==
              "database.json is broken."
        @test user_message(Core.GridError("bad grid")) == "Bad grid."
        @test user_message(ArgumentError("blank name")) == "Blank name."
        failed = Threads.@spawn throw(Core.ToolError("Inner."))
        e = try
            wait(failed)
        catch err
            err
        end
        @test e isa TaskFailedException && user_message(e) == "Inner."
        msg = @test_logs (:error, "Unexpected error") user_message(BoundsError([1], 3))
        @test startswith(msg, "Something went wrong: BoundsError")
    end

    @testset "toasts" begin
        with_app(test_app_state(nothing)) do app
            @test Toast(:ok, "Done.").ms == TOAST_MS == 4200
            @test Toast(:info, "Hi"; actions = ["Undo" => app -> nothing]).ms == TOAST_ACTIONS_MS == 9000
            @test Toast(:error, "Failed."; ms = TOAST_JOB_FAILED_MS).ms == 12000
            @test_throws ArgumentError Toast(:bad, "x")
            for k in 1:4
                toast!(app, :info, "Toast $k"; sub = "more")
            end
            @test MAX_TOASTS == 3 && [t.text for t in app.toasts] == ["Toast 2", "Toast 3", "Toast 4"]
            @test all(t -> t.sub == "more", app.toasts)
            prune_toasts!(app, time() + 4.3)
            @test isempty(app.toasts)
            toast!(app, :warn, "Stays"; actions = ["Open" => app -> nothing])
            prune_toasts!(app, time() + 4.3)
            @test length(app.toasts) == 1
        end
    end
end
