using Test, JuliaMagCore
import ArchGDAL as AG

# `ArchGDAL.setgeotransform!` passes a bare pointer to the vector, so keep it alive.
function set_gt!(ds, gt)
    v = collect(Float64, gt)
    GC.@preserve v AG.setgeotransform!(ds, v)
    return ds
end

# Write a one-band file with GDAL. `A` is in file order: `A[col, row]`, row 1 is the first stored row.
function write_gdal(path, A::Matrix{T}, gt; driver = "GTiff", epsg = 32633, nodata = nothing,
                    scale = 1.0, offset = 0.0, bands = 1) where {T}
    AG.create(path; driver = AG.getdriver(driver), width = size(A, 1), height = size(A, 2),
              nbands = bands, dtype = T) do ds
        set_gt!(ds, gt)
        epsg === nothing || AG.setproj!(ds, AG.toWKT(AG.importEPSG(epsg)))
        for b in 1:bands
            band = AG.getband(ds, b)
            nodata === nothing || AG.setnodatavalue!(band, nodata)
            scale == 1 || AG.setscale!(band, scale)
            offset == 0 || AG.setoffset!(band, offset)
            AG.write!(band, b == 1 ? A : A .+ T(100 * (b - 1)))
        end
    end
    return path
end

# The ground position of the centre of file cell `(col, row)`, both counted from 1.
pixel_centre(gt, col, row) = (gt[1] + (col - 0.5) * gt[2] + (row - 0.5) * gt[3],
                              gt[4] + (col - 0.5) * gt[5] + (row - 0.5) * gt[6])

@testset "georeference converters" begin
    nt = georef_from_affine((1000.0, 10.0, 0.0, 2030.0, 0.0, -10.0), 4, 3)
    @test nt.dx == 10 && nt.dy == 10 && nt.x0 == 1005 && nt.y0 == 2005 && nt.rotation == 0 && !nt.bottom_up

    nt = georef_from_affine((1000.0, 10.0, 0.0, 2000.0, 0.0, 10.0), 4, 3)
    @test nt.bottom_up && nt.x0 == 1005 && nt.y0 == 2005 && nt.rotation == 0

    nt = georef_from_affine((0.0, 2.0, 0.0, 0.0, 0.0, -5.0), 4, 3)
    @test nt.dx == 2 && nt.dy == 5 && nt.x0 == 1 && nt.y0 == -12.5

    @test_throws GridError georef_from_affine((1000.0, 10.0, 1.0, 2030.0, 0.0, -10.0), 4, 3)
    e = try georef_from_affine((1000.0, 10.0, 1.0, 2030.0, 0.0, -10.0), 4, 3) catch e; e end
    @test occursin("skewed", e.msg)

    # Round trip through a rotated grid: every corner keeps its ground position.
    mktempdir() do tmp
        g = JuliaMagCore.create_grid(joinpath(tmp, "g"), "g", Float32, 5, 4; dx = 10.0, dy = 20.0,
                                     x0 = 100.0, y0 = 200.0, rotation = 30.0)
        gt = affine_from_grid(g)
        nt = georef_from_affine(gt, 5, 4)
        @test !nt.bottom_up
        @test nt.dx ≈ 10 && nt.dy ≈ 20 && nt.x0 ≈ 100 && nt.y0 ≈ 200 && nt.rotation ≈ 30
        # The first stored row is the north row: file cell (1, 1) is grid cell (1, ny).
        @test all(pixel_centre(gt, 1, 1) .≈ cell_centre(g, 1, 4))
        @test all(pixel_centre(gt, 5, 4) .≈ cell_centre(g, 5, 1))
    end
end

@testset "GDAL is quiet" begin
    # The package's `__init__` sets JuliaMag's quiet error handler.
    @test JuliaMagCore.QUIET_GDAL_HANDLER[] != C_NULL
    @test AG.GDAL.cplgeterrorhandler(C_NULL) == JuliaMagCore.QUIET_GDAL_HANDLER[]
end

# The GDAL cache tests need `GDAL_CACHEMAX` unset. When a developer set it,
# they run without it, with a note, and the cache GDAL took from it is put back.
function without_gdal_cachemax(f)
    haskey(ENV, "GDAL_CACHEMAX") || return f()
    @info "GDAL_CACHEMAX is set in this shell; the GDAL cache tests run as if it were not."
    saved = AG.GDAL.gdalgetcachemax64()
    try
        return withenv("GDAL_CACHEMAX" => nothing) do
            JuliaMagCore.set_gdal_cache!()                 # what `__init__` does without the variable
            f()
        end
    finally
        AG.GDAL.gdalsetcachemax64(saved)
    end
end

@testset "the GDAL block cache is small" begin without_gdal_cachemax() do
    # GDAL's default cache is 5 % of the memory, so a big file would fill
    # over 1 GB of it. The package's `__init__` makes it small.
    cachemax() = AG.GDAL.gdalgetcachemax64()
    floor = JuliaMagCore.GDAL_CACHE_FLOOR
    @test floor == 64 * 2^20
    @test cachemax() == floor
    # A job that needs more raises it while it runs; two jobs add up.
    JuliaMagCore.with_gdal_cache(10 * 2^20) do
        @test cachemax() == floor
    end
    JuliaMagCore.with_gdal_cache(100 * 2^20) do
        @test cachemax() == 100 * 2^20
        JuliaMagCore.with_gdal_cache(50 * 2^20) do
            @test cachemax() == 150 * 2^20
        end
        @test cachemax() == 100 * 2^20
    end
    @test cachemax() == floor
    @test_throws ErrorException JuliaMagCore.with_gdal_cache(() -> error("boom"), 200 * 2^20)
    @test cachemax() == floor
    # The need of a band: two rows of its blocks.
    @test JuliaMagCore.gdal_cache_need(20_000, 256, Float32) == 2 * 20_000 * 256 * 4

    # The raise has a cap: 1 GiB or an eighth of the memory, whichever is smaller.
    cap = JuliaMagCore.gdal_cache_cap()
    @test cap == max(floor, min(2^30, Int(Sys.total_memory() ÷ 8)))
    # A wide tiled Float64 file: 3e6 cells per row, 256-row tiles, about 12 GB for two rows of tiles.
    need = JuliaMagCore.gdal_cache_need(3_000_000, 256, Float64)
    @test need > 10^10
    JuliaMagCore.with_gdal_cache(need) do
        @test cachemax() == cap
    end
    @test cachemax() == floor
end end

@testset "a GDAL_CACHEMAX the user set is kept" begin without_gdal_cachemax() do
    cachemax() = AG.GDAL.gdalgetcachemax64()
    floor = JuliaMagCore.GDAL_CACHE_FLOOR
    @test !JuliaMagCore.user_gdal_cache()                  # the test runs without the variable
    users = 300 * 2^20                                     # what GDAL took from the variable
    AG.GDAL.gdalsetcachemax64(users)
    try
        withenv("GDAL_CACHEMAX" => "300") do
            @test JuliaMagCore.user_gdal_cache()
            JuliaMagCore.set_gdal_cache!()                 # what `__init__` calls
            @test cachemax() == users
            JuliaMagCore.with_gdal_cache(500 * 2^20) do
                @test cachemax() == users
            end
            @test cachemax() == users
        end
    finally
        JuliaMagCore.set_gdal_cache!()
    end
    @test cachemax() == floor
end end

@testset "coordinate system text" begin
    @test crs_from_wkt("") == ""
    @test crs_wkt("") == ""
    wkt = crs_wkt("EPSG:32633")
    @test startswith(wkt, "PROJCS[\"WGS 84 / UTM zone 33N\"")
    @test crs_from_wkt(wkt) == "EPSG:32633"
    @test crs_from_wkt("not a coordinate system") == "not a coordinate system"
    @test crs_wkt("not a code") == ""
end

@testset "GDAL grid import" begin
    importing(s) = filter(startswith(".importing-"), readdir(joinpath(s.project.folder, "grids")))

    # The reference grid: 4 by 3, north up, value 7 in the north-west cell, one nodata cell.
    north = Float32[7 1 2; 3 -9999 4; 5 6 8; 9 10 11]        # file order: column 1 holds the north row
    gt_north = (1000.0, 10.0, 0.0, 2030.0, 0.0, -10.0)

    mktempdir() do tmp
        s = new_session(joinpath(tmp, "p"), "p")

        @testset "north up GeoTIFF" begin
            f = write_gdal(joinpath(tmp, "north.tif"), north, gt_north; nodata = -9999)
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.name == "north"
            @test g.nx == 4 && g.ny == 3 && g.eltype == Float32
            @test g.dx == 10 && g.dy == 10 && g.x0 == 1005 && g.y0 == 2005 && g.rotation == 0
            @test g.crs == "EPSG:32633"
            A = read_rows(g, 1, 3)
            @test A[1, 3] == 7
            @test isnan(A[2, 2]) && count(isnan, A) == 1
            @test isequal(A, Float32.(replace(north[:, end:-1:1], -9999 => NaN)))
            @test cell_centre(g, 1, 3) == pixel_centre(gt_north, 1, 1)
            @test g.source.format == "GeoTIFF" && g.source.eltype == "float32" && g.source.file == f
            @test g.count == 11 && g.vmin == 1 && g.vmax == 11
            @test occursin("GeoTIFF import of", report_text(job))
            @test isempty(importing(s))
        end

        @testset "bottom up and rotated files keep the value at its place" begin
            # Bottom up: the first stored row is the south row.
            gt_up = (1000.0, 10.0, 0.0, 2000.0, 0.0, 10.0)
            f = write_gdal(joinpath(tmp, "up.tif"), north[:, end:-1:1], gt_up; nodata = -9999)
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            A = read_rows(g, 1, 3)
            @test A[1, 3] == 7 && g.x0 == 1005 && g.y0 == 2005 && g.rotation == 0
            @test cell_centre(g, 1, 3) == pixel_centre(gt_north, 1, 1)

            # Rotated by 30 degrees, stored top-down and bottom-up.
            c, s30 = cosd(30), sind(30)
            gt_rot = (1000.0, 10c, 10s30, 2030.0, 10s30, -10c)
            gt_rot_up = (1000.0, 10c, -10s30, 2030.0, 10s30, 10c)
            for (name, gt, F) in (("rot", gt_rot, north), ("rotup", gt_rot_up, north[:, end:-1:1]))
                f = write_gdal(joinpath(tmp, "$name.tif"), F, gt; nodata = -9999)
                job = wait_job(import_file(s, f))
                @test status(job) == JOB_DONE
                g = grid(s.project, only(job.outputs))
                @test g.rotation ≈ 30 && g.dx ≈ 10 && g.dy ≈ 10
                A = read_rows(g, 1, 3)
                i, j = Tuple(findfirst(==(7), A))
                col, row = Tuple(findfirst(==(7), F))
                @test all(cell_centre(g, i, j) .≈ pixel_centre(gt, col, row))
                # Every value sits where the file put it.
                for col in 1:4, row in 1:3
                    v = F[col, row]
                    v == -9999 && continue
                    i, j = Tuple(findfirst(==(v), A))
                    @test all(isapprox.(cell_centre(g, i, j), pixel_centre(gt, col, row); atol = 1e-9))
                end
            end
        end

        @testset "integer bands with scale and offset" begin
            # A scaled 16-bit value such as 50000.1 does not fit a Float32
            # exactly, so a scaled band becomes a Float64 grid with exact values.
            raw = Int16[1 10; -20 -32768]
            f = write_gdal(joinpath(tmp, "int.tif"), raw, gt_north; nodata = -32768, scale = 0.1, offset = 50000)
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.eltype == Float64 && g.source.eltype == "int16"
            A = read_rows(g, 1, 2)
            want = [50000 + 0.1 * raw[i, 3 - j] for i in 1:2, j in 1:2]
            want[2, 1] = NaN
            @test isequal(A, want)
            @test A[1, 1] == 50001.0 && A[2, 2] == 49998.0 && A[1, 2] == 50000 + 0.1

            # A scaled Float32 band becomes Float64 too.
            f = write_gdal(joinpath(tmp, "f32.tif"), Float32[1 2; 3 4], gt_north; scale = 0.1)
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.eltype == Float64 && read_rows(g, 1, 2) == [0.1 * 2 0.1 * 1; 0.1 * 4 0.1 * 3]

            # Each unscaled band type becomes the grid type of the rule.
            for (T, G) in ((UInt8, Float32), (Int8, Float32), (UInt16, Float32), (Int16, Float32),
                           (Int32, Float64), (UInt32, Float64), (Float32, Float32), (Float64, Float64))
                f = write_gdal(joinpath(tmp, "t_$T.tif"), T[1 2; 3 4], gt_north)
                job = wait_job(import_file(s, f))
                @test status(job) == JOB_DONE
                g = grid(s.project, only(job.outputs))
                @test g.eltype == G && g.source.eltype == lowercase(string(T))
                @test read_rows(g, 1, 2) == G[2 4; 1 3]'
            end
        end

        @testset "compression is recorded" begin
            f = joinpath(tmp, "deflate.tif")
            AG.create(f; driver = AG.getdriver("GTiff"), width = 2, height = 2, nbands = 1, dtype = Float32,
                      options = ["COMPRESS=DEFLATE"]) do ds
                set_gt!(ds, gt_north)
                AG.write!(AG.getband(ds, 1), Float32[1 2; 3 4])
            end
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            @test grid(s.project, only(job.outputs)).source.compression == "DEFLATE"
        end

        @testset "a file with two bands" begin
            f = write_gdal(joinpath(tmp, "two.tif"), north, gt_north; nodata = -9999, bands = 2)
            job = wait_job(import_file(s, f; band = 2))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test read_rows(g, 1, 3)[1, 3] == 107
            @test occursin("only band 2 of 2 was read", report_text(job))
            job = wait_job(import_file(s, f; band = 3))
            @test status(job) == JOB_FAILED && occursin("band 3", job.error)
            @test isempty(importing(s))
        end

        @testset "ER Mapper with a rotation" begin
            f = write_gdal(joinpath(tmp, "rot.ers"), north, gt_north; driver = "ERS", nodata = -9999)
            txt = read(f, String)
            @test occursin("Rotation\t= 0:0:0.0", txt)
            write(f, replace(txt, "Rotation\t= 0:0:0.0" => "Rotation\t= 30:0:0.0"))
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.source.format == "ERMapper .ers Labelled"
            @test g.rotation ≈ 30 && g.dx ≈ 10 && g.dy ≈ 10
            A = read_rows(g, 1, 3)
            @test A[1, 3] == 7 && isnan(A[2, 2])
            # ER Mapper turns the grid counter-clockwise about the registration point,
            # here the outer north-west corner (1000, 2030).
            want = (1000 + 5cosd(30) + 5sind(30), 2030 + 5sind(30) - 5cosd(30))
            @test all(cell_centre(g, 1, 3) .≈ want)
        end

        @testset "ER Mapper RAW header with MetersX, MetersY and a rotation" begin
            data = joinpath(@__DIR__, "data", "grids")
            f = joinpath(tmp, "rawrot.ers")
            cp(joinpath(data, "mag4014"), joinpath(tmp, "rawrot"))
            txt = read(joinpath(data, "mag4014.ers"), String)
            @test occursin("CoordinateType = RAW\r\n", txt)          # the sample has Windows line ends
            write(f, replace(txt, "CoordinateType = RAW\r\n" => "CoordinateType = RAW\r\n        Rotation = 30:0:0.0\r\n"))
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.rotation ≈ 30 && g.dx ≈ 200 && g.dy ≈ 200
            # The registration point (MetersX, MetersY) is the north-west corner of
            # the south row, cell (0, 165). The grid turns about it.
            want = (-301100 + 100cosd(30) + 100sind(30), -69400 + 100sind(30) - 100cosd(30))
            @test all(cell_centre(g, 1, 1) .≈ want)
        end

        @testset "a skewed file fails" begin
            f = write_gdal(joinpath(tmp, "skew.tif"), north, (1000.0, 10.0, 1.0, 2030.0, 0.0, -10.0))
            n = length(s.project.items)
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_FAILED && occursin("skewed", job.error)
            @test length(s.project.items) == n && isempty(importing(s))
        end

        @testset "an ER Mapper file without its data file fails" begin
            f = write_gdal(joinpath(tmp, "lost.ers"), north, gt_north; driver = "ERS")
            rm(joinpath(tmp, "lost"))
            n = length(s.project.items)
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_FAILED
            @test occursin(joinpath(tmp, "lost"), job.error) && occursin("missing", job.error)
            @test length(s.project.items) == n && isempty(importing(s))
        end

        @testset "broken and missing files fail with GDAL's message" begin
            f = joinpath(tmp, "cut.tif")
            AG.create(f; driver = AG.getdriver("GTiff"), width = 400, height = 300, nbands = 1, dtype = Float32) do ds
                set_gt!(ds, gt_north)
                AG.write!(AG.getband(ds, 1), rand(Float32, 400, 300))
            end
            open(io -> truncate(io, 100_000), f, "r+")
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_FAILED && startswith(job.error, "GridError: ")
            @test occursin("cut.tif", job.error) && isempty(importing(s))

            job = wait_job(import_file(s, joinpath(tmp, "nothing.tif")))
            @test status(job) == JOB_FAILED && occursin("nothing.tif", job.error)

            f = joinpath(tmp, "text.tif")
            write(f, "this is not a picture")
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_FAILED && occursin("not recognized", job.error)
        end

        @testset "a file without georeference" begin
            f = joinpath(tmp, "plain.tif")
            AG.create(f; driver = AG.getdriver("GTiff"), width = 2, height = 2, nbands = 1, dtype = Float32) do ds
                AG.write!(AG.getband(ds, 1), Float32[1 2; 3 4])
            end
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.dx == 1 && g.dy == 1 && g.x0 == 0.5 && g.y0 == 0.5 && g.crs == ""
            @test occursin("no georeference", report_text(job))
        end

        @testset "a forced driver" begin
            f = write_gdal(joinpath(tmp, "forced.tif"), north, gt_north)
            r = read_gdal_grid(s, f, Dict{String,Any}(), NO_PROGRESS; driver = "GTiff")
            @test grid(s.project, r.item.id).source.format == "GeoTIFF"
            n = length(s.project.items)
            @test_throws GridError read_gdal_grid(s, f, Dict{String,Any}(), NO_PROGRESS; driver = "GSBG")
            @test length(s.project.items) == n && isempty(importing(s))
        end

        @testset "public ER Mapper samples" begin
            data = joinpath(@__DIR__, "data", "grids")
            # GDAL's own test: the geotransform is (-301100, 200, 0, -69400 + 200 * 165, 0, -200).
            gt = (-301100.0, 200.0, 0.0, -69400.0 + 200 * 165, 0.0, -200.0)
            job = wait_job(import_file(s, joinpath(data, "mag4014.ers")))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.nx == 131 && g.ny == 166 && g.dx == 200 && g.dy == 200 && g.rotation == 0
            @test g.x0 == -301000 && g.y0 == -69500
            @test cell_centre(g, 1, 166) == pixel_centre(gt, 1, 1)
            @test g.count > 0

            # Big-endian, with 1E+20 as its null value.
            job = wait_job(import_file(s, joinpath(data, "f0540mag.ers")))
            @test status(job) == JOB_DONE
            g = grid(s.project, only(job.outputs))
            @test g.nx == 271 && g.ny == 136
            A = read_rows(g, 1, g.ny)
            @test count(isnan, A) > 0 && g.count == count(!isnan, A)
            @test maximum(filter(!isnan, A)) < 1e19
            @test isempty(importing(s))
        end

        @testset "importers" begin
            @test importer_for("a.TIF").id == "import.geotiff"
            @test importer_for("a.tiff").id == "import.geotiff"
            @test importer_for("a.ers").id == "import.ers"
            for id in ("import.geotiff", "import.ers")
                spec = only(filter(i -> i.id == id, importers()))
                @test spec.kind == ITEM_GRID
                @test default_settings(spec) == Dict{String,Any}("band" => 1)
            end
        end
    end
end
