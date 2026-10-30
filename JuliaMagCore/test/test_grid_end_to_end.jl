using Test, JuliaMagCore

# The public grid files, read through the public API and checked against
# numbers from other readers. Then a grid goes through the whole chain:
# import, statistics, coordinate system, export to every format, import again, undo.

const E2E_GRIDS = joinpath(@__DIR__, "data", "grids")

@testset "grid end to end" begin
    function load(s, f)
        job = wait_job(import_file(s, f))
        status(job) == JOB_DONE || error("import of $f failed: $(job.error)")
        id = only(job.outputs)
        g = grid(s.project, id)
        return id, g, read_rows(g, 1, g.ny)
    end
    # In `A = read_rows(g, 1, g.ny)`, `A[i, j]` is column `i` and row `j`, row 1 south.

    mktempdir() do tmp
        s = new_session(joinpath(tmp, "p"), "p")

        @testset "public files match other readers" begin
            # om_float.grd (harmonica). Expected numbers from harmonica's own test
            # grid `test/data/om_expected.nc` (read with scipy on 2026-10-29):
            # easting 1:50, northing -24:24, 655 NaN cells.
            # Its array is (northing, easting), so `om[j, i]` there is `A[i, j]` here.
            id, g, A = load(s, joinpath(E2E_GRIDS, "om_float.grd"))
            @test (g.nx, g.ny) == (50, 49)
            @test (g.dx, g.dy, g.x0, g.y0, g.rotation) == (1.0, 1.0, 1.0, -24.0, 0.0)
            @test count(isnan, A) == 655
            @test A[21, 11] == 20.68994140625f0       # om[10, 20] (0-based)
            @test A[6, 31] == 16.936105728149414f0    # om[30, 5]
            @test A[50, 49] == 1.8248029947280884f0   # om[48, 49]
            @test isnan(A[1, 1])                      # om[0, 0] is NaN

            # test_uncompressed.grd and test_compressed.grd (Loop3D, data from CPRM).
            # Size and origin: Oasis's own `.grd.xml` gives the extent of the cell centres,
            # minx -40.46822, maxx -37.66952, miny -8.45502, maxy -6.00002.
            # (maxx - minx) / 285 = (maxy - miny) / 250 = 0.00982.
            # Cell values: decoded with numpy from the bytes after the header, as in
            # docs/research/geosoft-grd-format.md section 2 (row 1 south) and, for the
            # compressed file, section 4 (zlib blocks). No cell is a dummy.
            for name in ("test_uncompressed.grd", "test_compressed.grd")
                id, g, A = load(s, joinpath(E2E_GRIDS, name))
                @test (g.nx, g.ny) == (286, 251)
                @test (g.x0, g.y0, g.rotation) == (-40.46822, -8.45502, 0.0)
                @test g.dx == 0.00982 && g.dy == 0.00982
                @test g.x0 + 285 * g.dx ≈ -37.66952 && g.y0 + 250 * g.dy ≈ -6.00002
                @test g.crs == "EPSG:4326"                  # the .grd.xml says WGS 84
                @test count(isnan, A) == 0
                @test A[1, 1] == 62.863094329833984f0
                @test A[100, 50] == 83.15825653076172f0
                @test A[286, 251] == -75.2886962890625f0
            end

            # mag_4126.grd (USGS DS 355), zlib blocks. Header and values decoded with numpy and
            # Python zlib as in the research file, sections 1, 2 and 4: NE 85, NV 160, DE = DV = 200,
            # X0 140400, Y0 -4400, 12324 values of 13600.
            id, g, A = load(s, joinpath(E2E_GRIDS, "mag_4126.grd"))
            @test (g.nx, g.ny) == (85, 160)
            @test (g.dx, g.dy, g.x0, g.y0, g.rotation) == (200.0, 200.0, 140400.0, -4400.0, 0.0)
            @test count(!isnan, A) == 12324
            @test A[30, 120] == 302.935546875f0
            @test A[42, 80] == -78.86675262451172f0
            @test A[10, 40] == -56.291725158691406f0
            @test isnan(A[1, 1])

            # mag4014.ers (GDAL autotest). Size and values from GDAL itself through ArchGDAL
            # (GDAL 3.13.3, 2026-10-29): 131 by 166, Float32, nodata -1e32, 18611 values.
            # GDAL 3.13 gives this RAW header no geotransform, so the position is from GDAL's own
            # autotest: geotransform (-301100, 200, 0, -69400 + 200 * 165, 0, -200).
            # GDAL's file row r is grid row 167 - r here.
            id, g, A = load(s, joinpath(E2E_GRIDS, "mag4014.ers"))
            @test (g.nx, g.ny) == (131, 166)
            @test (g.dx, g.dy, g.x0, g.y0, g.rotation) == (200.0, 200.0, -301000.0, -69500.0, 0.0)
            @test count(!isnan, A) == 18611
            @test A[40, 67] == 101.31073f0             # GDAL column 40, row 100
            @test A[100, 137] == 54.045956f0           # GDAL column 100, row 30
            @test A[70, 87] == -50.058426f0            # GDAL column 70, row 80
            @test isnan(A[1, 1])                       # GDAL column 1, row 166 is nodata

            # f0540mag.ers (USGS OFR 01-0081), big-endian. From GDAL through ArchGDAL:
            # 271 by 136, geotransform (124900, 200, 0, 503100, 0, -200), nodata 1e20, 35645 values.
            # So the centre of the lower-left cell is (124900 + 100, 503100 - 136 * 200 + 100).
            id, g, A = load(s, joinpath(E2E_GRIDS, "f0540mag.ers"))
            @test (g.nx, g.ny) == (271, 136)
            @test (g.dx, g.dy, g.x0, g.y0, g.rotation) == (200.0, 200.0, 125000.0, 476000.0, 0.0)
            @test count(!isnan, A) == 35645
            @test A[40, 37] == 1082.386f0              # GDAL column 40, row 100
            @test A[100, 107] == 1057.741f0            # GDAL column 100, row 30
            @test A[70, 57] == 1095.263f0              # GDAL column 70, row 80
            @test isnan(A[1, 1])                       # GDAL column 1, row 136 is nodata
        end

        # Export to every format and import again: the same values, position and coordinate system.
        # `ers_crs` is the coordinate system the .ers file can keep.
        function round_trips(s, id, crs; tag, ers_crs = crs)
            src = grid(s.project, id)
            B = read_rows(src, 1, src.ny)
            for ext in (".grd", ".ers", ".tif")
                f = joinpath(tmp, "$tag$ext")
                job = wait_job(export_file(s, id, f))
                @test status(job) == JOB_DONE
                report = report_text(job)
                @test occursin("has no name for the coordinate system", report) == (ext == ".ers" && ers_crs != crs)
                _, g, C = load(s, f)
                @test isequal(C, B)
                @test g.eltype == src.eltype
                @test (g.nx, g.ny) == (src.nx, src.ny)
                @test all(isapprox.((g.dx, g.dy, g.x0, g.y0, g.rotation),
                                    (src.dx, src.dy, src.x0, src.y0, src.rotation); rtol = 1e-12))
                @test g.crs == (ext == ".ers" ? ers_crs : crs)
            end
        end

        @testset "the chain on a public file" begin
            n = length(s.project.items)
            id, g, A = load(s, joinpath(E2E_GRIDS, "test_uncompressed.grd"))
            @test length(s.project.items) == n + 1

            # Statistics. Min and max from the numpy decode above: -268.1118469238281 and 259.9376525878906.
            ok, msg, _ = run_tool(s, "grid.statistics"; inputs = Dict("grid" => id))
            @test ok
            @test startswith(msg, "Statistics of grid test_uncompressed:\nCount 71786, missing 0.\n" *
                                  "Min -268.112, max 259.938, ")
            st = grid_stats(grid(s.project, id))
            @test st.min == -268.1118469238281 && st.max == 259.9376525878906

            # The grid came from SIRGAS 2000 latitude and longitude (see its .grd.xml).
            # ER Mapper has no name for SIRGAS 2000 (GDAL's ecw_cs.wkt has none), so the .ers loses it with a note.
            set_grid_crs!(s, id, "EPSG:4674")
            @test grid(s.project, id).crs == "EPSG:4674"
            round_trips(s, id, "EPSG:4674"; tag = "chain", ers_crs = "")

            # Undo the three imports of the round trip, then the coordinate system, then the first import.
            for _ in 1:3
                @test undo!(s)
            end
            @test s.project.items[end].id == id
            @test grid(s.project, id).crs == "EPSG:4674"
            @test undo!(s)                                       # set_grid_crs!
            @test grid(s.project, id).crs == "EPSG:4326"
            @test undo!(s)                                       # the import
            @test !any(i -> i.id == id, s.project.items)
            @test length(s.project.items) == n
        end

        @testset "a grid of more than one block round trips" begin
            # 4096 Float32 cells per row make blocks of 1024 rows (16 MiB). With 2100 rows a
            # reader or writer fills two full blocks, the second in the buffer of the first,
            # and then a short block of 52 rows.
            nx, ny = 4096, 2100
            A = Float32[sin(i / 37) * 100 + j / 3 for i in 1:nx, j in 1:ny]
            A[1, 1] = A[nx, ny] = NaN32
            A[:, 1500] .= NaN32                                  # a whole row in the second full block
            A[7, 2090] = NaN32                                   # a cell in the short block
            f = write_test_grd(joinpath(tmp, "big.grd"), A; x0 = 500000.0, y0 = 7000000.0, de = 25.0, dv = 25.0,
                               rot = 12.5)
            id, g, B = load(s, f)
            @test block_rows(g) == 1024 && 2 * block_rows(g) < ny
            @test isequal(B, A)
            set_grid_crs!(s, id, "EPSG:32633")
            round_trips(s, id, "EPSG:32633"; tag = "big")
        end
    end
end
