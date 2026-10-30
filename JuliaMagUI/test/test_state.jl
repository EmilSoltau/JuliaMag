using Test
import JuliaMagCore as Core
using JuliaMagUI: snapshot, Snapshot, AppState, UiState, set_session!

@testset "state" begin
    @testset "snapshot of a session" begin
        with_test_session(fresh_session()) do s
            id = make_test_database!(s)
            snap = snapshot(s)
            @test snap.revision == Core.revision(s) && only(snap.items).id == id
            db = Core.database(s.project, id)
            view = snap.databases[id]
            @test length(view.lines) == length(db.lines) && view.error == ""
            @test only(view.lines).name == "L1001" && only(view.lines).nrows == 5
            @test [c.name for c in view.channels] == ["MAG", "MAGP"]
            @test [c.protected for c in view.channels] == [false, true]
            @test first(view.channels).eltype == "Float64" && view.rows == 5
            @test snap.project_name == "p" && snap.folder == s.project.folder
            row = only(snap.items)
            @test row.kind == Core.ITEM_DATABASE && !row.missing && row.busy == "" && row.made_by == ""
            @test snap.undo_label === nothing && snap.redo_label === nothing
            @test snap.cursor === nothing && snap.marked === nothing && isempty(snap.jobs)
            @test isempty(snap.grids) && isempty(snap.warnings)
        end
    end

    @testset "undo label, cursor and marked range" begin
        with_test_session(fresh_session()) do s
            id = make_test_database!(s)
            Core.rename_item!(s, id, "Survey")
            L = Core.LineId(Core.LINE, 1001, 0)
            Core.set_cursor!(s, Core.Cursor(id, L, 3))
            Core.set_marked!(s, (2, 4))
            snap = snapshot(s)
            @test snap.undo_label isa String && !isempty(snap.undo_label) && snap.redo_label === nothing
            @test only(snap.items).name == "Survey"
            @test snap.cursor.item == id && snap.cursor.line == L && snap.cursor.row == 3
            @test snap.cursor !== s.cursor   # a copy, so a later cursor move leaves it alone
            @test snap.marked == (2, 4)
            Core.undo!(s)
            snap2 = snapshot(s)
            @test snap2.redo_label == snap.undo_label && only(snap2.items).name != "Survey"
            @test snap2.revision > snap.revision
        end
    end

    @testset "busy item" begin
        with_test_session(fresh_session()) do s
            id = make_test_database!(s)
            lock(() -> s.busy[id] = Core.BusyMark(true, 0, "an import is running", :append), s.lock)
            try
                @test only(snapshot(s).items).busy == "an import is running"
            finally
                lock(() -> delete!(s.busy, id), s.lock)
            end
        end
    end

    @testset "missing and broken items do not throw" begin
        with_test_session(fresh_session()) do s
            gone = make_test_database!(s)
            broken = make_test_database!(s)
            rm(joinpath(s.project.folder, "databases", gone); recursive = true)
            write(joinpath(s.project.folder, "databases", broken, "database.json"), "{ not json")
            snap = snapshot(s)
            rows = Dict(r.id => r for r in snap.items)
            @test rows[gone].missing && !rows[broken].missing
            @test isempty(snap.databases[gone].lines) && occursin("missing", snap.databases[gone].error)
            @test isempty(snap.databases[broken].channels)
            @test occursin("broken", snap.databases[broken].error)
            @test !startswith(snap.databases[broken].error, "DatabaseError")
        end
    end

    @testset "a read during a file move is tried again under the session lock" begin
        with_test_session(fresh_session()) do s
            id = make_test_database!(s)
            p = s.project
            it = only(p.items)
            dir = joinpath(p.folder, "databases", id, "channels")
            path = joinpath(dir, only(filter(f -> startswith(f, "MAG."), readdir(dir))))
            mv(path, path * ".moving")   # as a channel rename does, before database.json follows
            retried = Ref(false)
            # The retry runs inside `relock`; here the "edit" ends just before it.
            relock = f -> (retried[] = true; mv(path * ".moving", path); lock(f, s.lock))
            view = UI.database_view(p, it, false, relock)
            @test retried[] && view.error == "" && length(view.channels) == 2
            # A database that stays broken still shows its error.
            mv(path, path * ".gone")
            view = UI.database_view(p, it, false, f -> lock(f, s.lock))
            @test occursin("missing", view.error) && isempty(view.channels)
            mv(path * ".gone", path)
            @test snapshot(s).databases[id].error == ""
        end
    end

    @testset "grids" begin
        with_test_session(fresh_session()) do s
            p = s.project
            id = Core.new_item_id(p, Core.ITEM_GRID)
            Core.create_grid(joinpath(p.folder, "grids", id), "Mag", Float32, 3, 2;
                dx = 10.0, dy = 20.0, x0 = 100.0, y0 = 200.0, crs = "EPSG:32633", units = "nT")
            Core.add_item!(p, Core.ProjectItem(id, Core.ITEM_GRID, "Mag grid", "grids/$id", "", ""))
            gone = Core.new_item_id(p, Core.ITEM_GRID)
            Core.add_item!(p, Core.ProjectItem(gone, Core.ITEM_GRID, "Lost", "grids/$gone", "", ""))
            snap = snapshot(s)
            v = snap.grids[id]
            @test (v.nx, v.ny, v.dx, v.dy, v.x0, v.y0) == (3, 2, 10.0, 20.0, 100.0, 200.0)
            @test v.crs == "EPSG:32633" && v.units == "nT" && v.eltype == "Float32" && v.error == ""
            @test snap.grids[gone].error != "" && only(filter(r -> r.id == gone, snap.items)).missing
            @test isempty(snap.databases)
        end
    end

    @testset "jobs" begin
        with_test_session(fresh_session()) do s
            id = make_test_database!(s)
            Core.rename_item!(s, id, "Survey")
            job = Core.start_job!(s, "test.snapshot_job", Dict{String,Any}("item" => id),
                (progress, io) -> Core.ProjectItem[])
            Core.wait_job(job)
            failed = Core.start_job!(s, "test.failing_job",
                Dict{String,Any}("path" => joinpath("some", "folder", "data.xyz")),
                (progress, io) -> error("the file is bad"))
            Core.wait_job(failed)
            snap = snapshot(s)
            @test [j.id for j in snap.jobs] == [failed.id, job.id]   # newest first
            done, bad = snap.jobs[2], snap.jobs[1]
            @test done.job === job && done.status == Core.JOB_DONE && done.target == "Survey"
            @test done.title == "test.snapshot_job" && done.finished != "" && done.error == ""
            @test bad.status == Core.JOB_FAILED && occursin("the file is bad", bad.error)
            @test bad.target == "data.xyz"
        end
    end

    @testset "session_with" begin
        with_test_session(session_with(lines = 40, channels = 7, name = "x"^200)) do s
            snap = snapshot(s)
            @test only(snap.items).name == "x"^200
            view = only(values(snap.databases))
            @test length(view.lines) == 40 && length(view.channels) == 7 && view.rows == 80
            @test view.lines[end].name == "L1040"
        end
    end

    @testset "set_session! drops what belonged to the old project" begin
        with_app(app_with_database()) do app
            old = app.session
            app.ui.selected = (:channel, app.ui.current_db, "MAG")
            push!(app.ui.expanded, app.ui.current_db)
            app.ui.filter = "MA"
            app.seen_warnings = 2
            push!(app.ui.dialogs, :a_dialog_of_the_old_project)
            push!(app.ui.requests, UI.OpenDialog(:about))
            with_test_session(fresh_session()) do other
                # The same revision number, but another project: it must be read anew.
                @test Core.revision(other) == app.snap.revision
                set_session!(app, other)
                @test app.session === other && app.snap === nothing && app.seen_warnings == 0
                @test app.ui.current_db == "" && app.ui.selected === nothing
                @test isempty(app.ui.expanded) && app.ui.filter == ""
                # Dialogs and requests of the old project do not outlive it.
                @test isempty(app.ui.dialogs) && isempty(app.ui.requests)
                refresh_now!(app)
                @test isempty(app.snap.items) && app.snap.folder == other.project.folder
                set_session!(app, old)
            end
        end
    end

    @testset "UiState defaults" begin
        ui = UiState()
        @test ui.left_tab == :data && !ui.backstage && ui.current_db == "" && ui.selected === nothing
        @test isempty(ui.dialogs) && isempty(ui.requests) && ui.search === nothing
    end
end
