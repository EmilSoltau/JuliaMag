using Test, JuliaMagCore

@testset "grid import frame" begin
    A = Float64[1 2 NaN; 4 5 6; 7 8 9; 10 11 12]        # 4 by 3, A[i, j]
    hdr = GridHeader(4, 3, 10.0, 20.0, 100.0, 200.0, 0.0, "EPSG:32633", "nT", Float32,
                     GridSource("x.tst", "test", "float32", "none"))
    importing(s) = filter(startswith(".importing-"), readdir(joinpath(s.project.folder, "grids")))

    function run_import(s, fill, name = "T"; cancel_after = nothing)
        return start_job!(s, "import.test_grid", Dict{String,Any}("path" => "x"), (p, io) -> begin
            r = import_grid(fill, s, name, hdr; progress = p)
            println(io, r.summary)
            [r.item]
        end)
    end

    mktempdir() do tmp
        s = new_session(joinpath(tmp, "p"), "p")

        @testset "rows" begin
            job = wait_job(run_import(s, sink -> (put_rows!(sink, 1, A[:, 1:2]); put_rows!(sink, 3, A[:, 3:3]))))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test isequal(read_rows(g, 1, 3), Float32.(A))
            @test g.count == count(!isnan, A) && g.vmin == 1.0 && g.vmax == 12.0
            @test g.crs == "EPSG:32633" && g.units == "nT" && g.source.format == "test"
            @test g.dx == 10.0 && g.y0 == 200.0
            @test isempty(importing(s))
            @test occursin("test grid 4 x 3 cells, 11 with values", String(take!(copy(job.report))))
            @test grid(s.project, only(job.outputs)).count == 11   # saved with the metadata
        end

        @testset "columns give the same values" begin
            job = wait_job(run_import(s, sink -> (put_columns!(sink, 1, permutedims(A[1:2, :]));
                                                  put_columns!(sink, 3, permutedims(A[3:4, :])))))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test isequal(read_rows(g, 1, 3), Float32.(A))
            @test g.count == 11 && g.vmin == 1.0 && g.vmax == 12.0
            @test isempty(importing(s))
        end

        @testset "short file" begin
            n = length(s.project.items)
            job = wait_job(run_import(s, sink -> put_rows!(sink, 1, A[:, 1:2])))
            @test status(job) == JOB_FAILED
            @test occursin("ended before row 3", job.error)
            @test isempty(importing(s)) && length(s.project.items) == n
            job = wait_job(run_import(s, sink -> put_columns!(sink, 1, permutedims(A[1:2, :]))))
            @test status(job) == JOB_FAILED && occursin("ended before column 3", job.error)
            @test isempty(importing(s))
        end

        @testset "rows put twice" begin
            job = wait_job(run_import(s, sink -> (put_rows!(sink, 1, A[:, 1:2]); put_rows!(sink, 2, A[:, 2:3]))))
            @test status(job) == JOB_FAILED && occursin("row 2", job.error)
            @test isempty(importing(s))
        end

        @testset "bad blocks" begin
            job = wait_job(run_import(s, sink -> put_rows!(sink, 1, A[1:3, :])))
            @test status(job) == JOB_FAILED && isempty(importing(s))
            job = wait_job(run_import(s, sink -> put_rows!(sink, 3, A[:, 1:2])))
            @test status(job) == JOB_FAILED && isempty(importing(s))
        end

        @testset "cancel between blocks" begin
            n = length(s.project.items)
            first_done, go = Base.Event(), Base.Event()
            job = run_import(s, sink -> begin
                put_rows!(sink, 1, A[:, 1:2])
                notify(first_done)
                wait(go)
                put_rows!(sink, 3, A[:, 3:3])
            end)
            wait(first_done)
            cancel!(job)
            notify(go)
            wait_job(job)
            @test status(job) == JOB_CANCELLED
            @test isempty(importing(s)) && length(s.project.items) == n
        end

        @testset "progress by cells" begin
            seen = Float64[]
            p = Progress(f -> push!(seen, f), () -> false)
            r = import_grid(sink -> (put_rows!(sink, 1, A[:, 1:2]); put_rows!(sink, 3, A[:, 3:3])), s, "P", hdr;
                            progress = p)
            @test seen[1] ≈ 8 / 12 && seen[2] ≈ 1.0
            @test r.item.kind == ITEM_GRID && r.rows == 0
        end

        @testset "undo and redo" begin
            job = wait_job(run_import(s, sink -> put_rows!(sink, 1, A)))
            id = only(job.outputs)
            @test any(i -> i.id == id, s.project.items)
            @test undo!(s)
            @test !any(i -> i.id == id, s.project.items)
            @test redo!(s)
            @test any(i -> i.id == id, s.project.items)
            @test isequal(read_rows(grid(s.project, id), 1, 3), Float32.(A))
        end

        @testset "name with spaces and brackets, all-NaN grid" begin
            job = wait_job(run_import(s, sink -> put_rows!(sink, 1, fill(NaN, 4, 3)), "My grid [1] (a b)"))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.name == "My grid [1] (a b)" && g.count == 0 && isnan(g.vmin) && isnan(g.vmax)
        end

        @testset "warnings come back" begin
            r = import_grid(sink -> put_rows!(sink, 1, A), s, "W", hdr; warnings = [ImportWarning(0, "careful")])
            @test only(r.warnings).message == "careful"
        end
    end

    @testset "old ImportResult constructor" begin
        r = ImportResult(nothing, ImportWarning[], 5, 2)
        @test r.summary == ""
    end
end
