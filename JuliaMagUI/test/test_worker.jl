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
            @test length(app.draw_errors) == 1   # a bug: the window tests fail on it

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

    @testset "a user error in done becomes a toast" begin
        with_app(test_app_state(fresh_session())) do app
            # The core throws this `ArgumentError` on purpose: a user error.
            submit!(app, "ok", s -> 1; done = (app, r) -> Core.tool("no.such.tool"))
            wait_drained(app)
            @test last(app.toasts).kind == :error && last(app.toasts).text == "There is no tool \"no.such.tool\"."
            @test isempty(app.draw_errors)
        end
    end

    # A bug in an action, in `done`, or one that an action turns into a message is noted
    # as a draw error, so the window tests fail on it (final review I3).
    @testset "a bug in done, in an action, or made a message is a draw error" begin
        # The worker logs from its own task, so the logger is set before the app starts.
        logger = Test.TestLogger()
        Base.CoreLogging.with_logger(logger) do
            with_app(test_app_state(fresh_session())) do app
                submit!(app, "ok", s -> 1; done = (app, r) -> [1][2])
                wait_drained(app)
                e = only(app.draw_errors)
                @test startswith(e.key, "BoundsError at ") && e.count == 1 && e.reports == 1
                @test startswith(last(app.toasts).text, "Something went wrong: BoundsError")
                # Base throws `ArgumentError` for bugs too: it is not a user error.
                submit!(app, "parse", s -> parse(Int, "x"))
                wait_drained(app)
                @test length(app.draw_errors) == 2 && startswith(app.draw_errors[2].key, "ArgumentError at ")
                # An action that turns a bug into a message: shown once, and noted.
                n = length(app.toasts)
                submit!(app, "message", s -> UI.safe_user_message(KeyError("k"), backtrace());
                    done = (app, r) -> toast!(app, :error, r))
                wait_drained(app)
                @test length(app.toasts) == n + 1 &&
                      last(app.toasts).text == "Something went wrong: KeyError: key \"k\" not found"
                @test length(app.draw_errors) == 3 && app.draw_errors[3].reports == 0 &&
                      app.draw_errors[3].count == 1
            end
        end
        # Each bug is logged once.
        @test count(r -> r.level == Base.CoreLogging.Error && r.message == "Unexpected error", logger.logs) == 3
    end

    @testset "is_user_error" begin
        caught(f) = try
            f(); nothing
        catch e
            (e, catch_backtrace())
        end
        @test UI.is_user_error(caught(() -> Core.tool("no.such.tool"))...)
        @test !UI.is_user_error(caught(() -> parse(Int, "x"))...)
        @test UI.is_user_error(Core.ToolError("Pick a channel."))
        @test !UI.is_user_error(KeyError("k"))
        @test UI.is_user_error(ArgumentError("no backtrace: as before"))
        t = Threads.@spawn Core.tool("no.such.tool")
        @test UI.is_user_error(caught(() -> wait(t))...)
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
        idle = Threads.@spawn nothing
        w = UI.Worker(Channel{UI.WorkerAction}(Inf), Channel{Any}(Inf), dead, Channel{Any}(Inf), idle, UI.ConvertBuffer(), 0, nothing)
        @test_logs (:error, "The worker task failed") UI.stop_worker!(w)
        dead_loader = Threads.@spawn error("the loader died")
        w = UI.Worker(Channel{UI.WorkerAction}(Inf), Channel{Any}(Inf), idle, Channel{Any}(Inf), dead_loader, UI.ConvertBuffer(), 0, nothing)
        @test_logs (:error, "The map loader task failed") UI.stop_worker!(w)
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

    @testset "a sticky toast is not pushed out by ordinary toasts" begin
        with_app(test_app_state(nothing)) do app
            sticky = toast!(app, :error, "A bug."; ms = typemax(Int))
            for k in 1:4
                toast!(app, :info, "Toast $k")
            end
            @test [t.text for t in app.toasts] == ["A bug.", "Toast 3", "Toast 4"]
            # Three sticky toasts: a new ordinary one does not push them out.
            toast!(app, :error, "Bug 2."; ms = typemax(Int))
            toast!(app, :error, "Bug 3."; ms = typemax(Int))
            toast!(app, :info, "Toast 5")
            @test [t.text for t in app.toasts] == ["A bug.", "Bug 2.", "Bug 3."]
            # A fourth sticky one pushes out the oldest sticky one.
            toast!(app, :error, "Bug 4."; ms = typemax(Int))
            @test [t.text for t in app.toasts] == ["Bug 2.", "Bug 3.", "Bug 4."] && sticky ∉ app.toasts
        end
    end
end
