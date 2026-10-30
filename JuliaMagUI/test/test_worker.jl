using Test
import JuliaMagCore as Core
using JuliaMagUI: submit!, drain!, refresh!, user_message, toast!, prune_toasts!, Toast,
    TOAST_MS, TOAST_ACTIONS_MS, TOAST_JOB_FAILED_MS, MAX_TOASTS

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

@testset "worker" begin
    @testset "actions, errors and refresh" begin
        s = fresh_session()
        id = make_test_database!(s)
        app = test_app_state(s)
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
        stop_app!(app)
    end

    @testset "actions finish in submit order" begin
        app = test_app_state(fresh_session())
        ran = Int[]
        finished = Int[]
        for k in 1:3
            submit!(app, "step $k", s -> (push!(ran, k); k); done = (app, r) -> push!(finished, r))
        end
        @test app.queue.pending == 3
        wait_drained(app)
        @test ran == [1, 2, 3] && finished == [1, 2, 3] && app.queue.pending == 0
        stop_app!(app)
    end

    @testset "busy while an action runs" begin
        app = test_app_state(fresh_session())
        go = Base.Event()
        submit!(app, "Renaming", s -> wait(go))
        drain_until(() -> app.busy == "Renaming", app)
        notify(go)
        wait_drained(app)
        @test app.busy === nothing
        stop_app!(app)
    end

    @testset "an error in done becomes a toast" begin
        app = test_app_state(fresh_session())
        submit!(app, "ok", s -> 1; done = (app, r) -> throw(ArgumentError("no such channel")))
        wait_drained(app)
        @test last(app.toasts).kind == :error && last(app.toasts).text == "No such channel."
        stop_app!(app)
    end

    @testset "an action on a closed session" begin
        s = fresh_session()
        id = make_test_database!(s)
        app = test_app_state(s)
        Core.close_session!(s)
        submit!(app, "rename", s -> Core.rename_item!(s, id, "Late"))
        wait_drained(app)
        @test last(app.toasts).kind == :error
        @test last(app.toasts).text == "The project $(s.project.folder) is closed."
        refresh!(app)   # a closed session is not read again
        @test !app.refreshing
        UI.stop_worker!(app.queue)
    end

    @testset "session warnings show once" begin
        app = app_with_database()
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
        stop_app!(app)
    end

    @testset "refresh" begin
        app = app_with_database()
        s = app.session
        snap = app.snap
        refresh!(app)   # nothing changed
        @test !app.refreshing && app.snap === snap
        Core.rename_item!(s, app.ui.current_db, "Changed")
        refresh!(app)
        @test app.refreshing
        refresh!(app)   # one build at a time
        @test app.refreshing
        refresh_now!(app)
        @test app.snap !== snap && only(app.snap.items).name == "Changed"

        # A snapshot of a session the app no longer has is dropped.
        Core.rename_item!(s, app.ui.current_db, "Again")
        refresh!(app)
        other = fresh_session()
        app.session = other
        drain_until(() -> !app.refreshing, app)
        @test only(app.snap.items).name == "Changed"
        Core.close_session!(other)
        app.session = s

        # A build that fails is logged and not tried again until the session changes.
        refresh_now!(app)
        Core.rename_item!(s, app.ui.current_db, "Third")
        rev = Core.revision(s)
        app.refreshing = true   # as `refresh!` sets it when it starts a build
        failure = CapturedException(ErrorException("disk gone"), backtrace())
        put!(app.queue.results, UI.SnapshotDone(s, rev, nothing, failure))
        @test_logs (:error, "Could not read the project state") drain!(app)
        @test !app.refreshing && only(app.snap.items).name == "Again"
        refresh!(app)
        @test !app.refreshing
        Core.rename_item!(s, app.ui.current_db, "Fourth")
        refresh_now!(app)
        @test only(app.snap.items).name == "Fourth"
        stop_app!(app)
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
        app = test_app_state(nothing)
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
        UI.stop_worker!(app.queue)
    end
end
