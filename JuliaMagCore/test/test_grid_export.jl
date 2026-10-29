using Test, JuliaMagCore
import ArchGDAL as AG

@testset "GeoTIFF and ER Mapper export" begin
    report_text(job) = String(take!(copy(job.report)))
    temps(dir) = filter(f -> occursin(".tmp", f), readdir(dir))
    function load(s, f)
        job = wait_job(import_file(s, f))
        status(job) == JOB_DONE || error("import of $f failed: $(job.error)")
        g = grid(s.project, only(job.outputs))
        return g, read_rows(g, 1, g.ny)
    end
    # A 5 by 4 grid with value 10 * column + row and one NaN.
    A = Float64[10i + j for i in 1:5, j in 1:4]
    A[2, 3] = NaN
    function make(s, T; rotation = 15.0, crs = "EPSG:32633", nx = 5, ny = 4, values = T.(A))
        h = GridHeader(nx, ny, 25.0, 50.0, 500000.25, 7000000.5, rotation, crs, "nT", T, GridSource())
        return import_grid(sink -> put_rows!(sink, 1, values), s, "Mag", h).item.id
    end
    same(a, b) = isapprox(a, b; rtol = 1e-12)
    # The data file of an ER Mapper header `x.ers` is `x`.
    data_file(f) = first(splitext(f))

    mktempdir() do tmp
        s = new_session(joinpath(tmp, "p"), "p")

        @testset "registered exporters" begin
            for (ext, id, name) in ((".tif", "export.geotiff", "GeoTIFF"), (".ers", "export.ers", "ER Mapper"))
                e = exporter_for("x$ext", ITEM_GRID)
                @test e !== nothing && e.id == id && e.name == name && isempty(e.settings)
                @test exporter_for(id).extension == ext
            end
        end

        @testset "round trip to $ext of a $T grid rotated $rot degrees" for ext in (".tif", ".ers"),
                                                                              T in (Float32, Float64),
                                                                              rot in (15.0, -33.3)
            id = make(s, T; rotation = rot)
            f = joinpath(tmp, "rt_$(T)_$(rot)$ext")
            job = wait_job(export_file(s, id, f))
            @test status(job) == JOB_DONE
            @test job.command == (ext == ".tif" ? "export.geotiff" : "export.ers")
            @test occursin("to $f: 20 cells", report_text(job))
            @test isfile(f) && isempty(temps(tmp))
            ext == ".ers" && @test isfile(data_file(f))
            @test !isfile(f * ".aux.xml")
            g, B = load(s, f)
            src = grid(s.project, id)
            @test isequal(B, T.(A))
            @test g.eltype == T
            @test (g.nx, g.ny) == (src.nx, src.ny)
            @test all(same.((g.dx, g.dy, g.x0, g.y0, g.rotation), (src.dx, src.dy, src.x0, src.y0, src.rotation)))
            @test g.crs == "EPSG:32633"
            # Each corner value stays at the same ground position.
            for (i, j) in ((1, 1), (5, 1), (1, 4), (5, 4))
                @test all(same.(cell_centre(g, i, j), cell_centre(src, i, j)))
                @test B[i, j] == 10i + j
            end
        end

        @testset "the GeoTIFF file" begin
            id = make(s, Float32)
            f = joinpath(tmp, "opts.tif")
            @test status(wait_job(export_file(s, id, f))) == JOB_DONE
            AG.read(f) do ds
                @test AG.metadataitem(ds, "COMPRESSION"; domain = "IMAGE_STRUCTURE") == "DEFLATE"
                @test AG.metadataitem(ds, "PREDICTOR"; domain = "IMAGE_STRUCTURE") == "3"
                band = AG.getband(ds, 1)
                @test AG.blocksize(band) == [256, 256]          # tiled; a strip would be 5 wide
                @test AG.pixeltype(band) == Float32
                @test isnan(AG.getnodatavalue(band))
                # The first stored row is the north row, and the NaN cell holds NaN.
                M = AG.read(band)
                @test M[:, 1] == Float32[10i + 4 for i in 1:5]
                @test isnan(M[2, 2])
            end
        end

        @testset "the ER Mapper files" begin
            for T in (Float32, Float64)
                id = make(s, T)
                f = joinpath(tmp, "hdr_$T.ers")
                @test status(wait_job(export_file(s, id, f))) == JOB_DONE
                text = read(f, String)
                @test occursin(r"^\t\tRotation\t= 15:0:0\.0$"m, text)
                @test occursin(r"NullCellValue\s*=\s*-1e\+32\s*$"m, text)
                @test occursin("Name\t= \"hdr_$T.ers\"", text)
                @test !occursin(".tmp", text)
                @test occursin(T == Float32 ? "IEEE4ByteReal" : "IEEE8ByteReal", text)
                # The data file holds the north row first, and -1.0e32 for NaN.
                v = reinterpret(T, read(data_file(f)))
                @test length(v) == 20
                @test v[1:5] == T[10i + 4 for i in 1:5]
                @test v[5 + 2] == T(-1.0e32)                     # column 2 of row 3, the second stored row
            end
        end

        @testset "a target without .ers is refused" begin
            id = make(s, Float32)
            r = try
                export_ers(s, id, joinpath(tmp, "noext.dat"))
            catch e
                e
            end
            @test r isa ToolError && occursin("must end in .ers", r.msg)
            @test isempty(temps(tmp)) && !isfile(joinpath(tmp, "noext.dat"))
        end

        @testset "an old .aux.xml next to the target is removed" begin
            for ext in (".tif", ".ers")
                f = joinpath(tmp, "aux$ext")
                write(f * ".aux.xml", "<PAMDataset><SRS>stale</SRS></PAMDataset>")
                job = wait_job(export_file(s, make(s, Float32), f))
                @test status(job) == JOB_DONE && !isfile(f * ".aux.xml")
                @test occursin("Removed aux$ext.aux.xml", report_text(job))
                g, _ = load(s, f)
                @test g.crs == "EPSG:32633"
            end
        end

        @testset "a cancelled $ext export leaves no files" for ext in (".tif", ".ers")
            d = mkpath(joinpath(tmp, "cancel$ext"))
            f = joinpath(d, "c$ext")
            exp = ext == ".tif" ? export_geotiff : export_ers
            # 4096 by 1100 Float32 cells are 17.2 MiB: two blocks of at most 16 MiB.
            h = GridHeader(4096, 1100, 1.0, 1.0, 0.0, 0.0, 0.0, "", "", Float32, GridSource())
            big = import_grid(sink -> put_rows!(sink, 1, ones(Float32, 4096, 1100)), s, "big", h).item.id
            @test block_rows(grid(s.project, big)) < 1100
            seen = Ref{Vector{String}}(String[])
            busy = Ref{Any}(nothing)
            id = "export.test_cancel$(ext[2:end])"
            register_exporter!(ExporterSpec(id, "Cancel test", ".cancel_test$(ext[2:end])", ITEM_GRID, SettingSpec[],
                (s, item_id, path, settings, progress) -> begin
                    stop = Ref(false)
                    p = Progress(x -> begin
                                     if x > 0 && !stop[]
                                         seen[] = readdir(d)
                                         # An edit of the grid is refused while the export runs.
                                         busy[] = try
                                             JuliaMagCore.mark_busy!(s, item_id; reason = "an edit")
                                             :marked
                                         catch e
                                             e
                                         end
                                         stop[] = true
                                     end
                                     nothing
                                 end, () -> stop[])
                    exp(s, item_id, path; progress = p, record = false)
                end))
            n = length(s.history)
            j = wait_job(export_file(s, big, f; exporter = id))
            @test status(j) == JOB_CANCELLED
            @test !isempty(seen[]) && all(n -> occursin(".tmp-", n), seen[])   # half-written temp files
            @test busy[] isa ItemBusyError
            @test isempty(readdir(d))
            @test lock(() -> check_not_busy(s, big), s.lock) === nothing     # the read mark is released

            # An old target is kept as it was.
            write(f, "old")
            j = wait_job(export_file(s, big, f; exporter = id))
            @test status(j) == JOB_CANCELLED
            @test readdir(d) == ["c$ext"] && read(f, String) == "old"
            @test length(s.history) == n
        end

        @testset "a direct call records the export" begin
            id = make(s, Float32)
            for (exp, ext, cmd) in ((export_geotiff, ".tif", "export.geotiff"), (export_ers, ".ers", "export.ers"))
                n = length(s.history)
                r = exp(s, id, joinpath(tmp, "direct$ext"))
                @test (r.rows, r.lines) == (20, 0) && r.path == joinpath(tmp, "direct$ext")
                @test length(s.history) == n + 1 && s.history[end].command == cmd
            end
        end

        @testset "ER Mapper names of coordinate systems" begin
            # GDAL gives an ER Mapper header with Datum "WGS84" and Projection "NUTM33" as this WKT.
            wkt(cm) = "PROJCS[\"NUTM33\",GEOGCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137," *
                      "298.257223563],TOWGS84[0,0,0,0,0,0,0]],PRIMEM[\"Greenwich\",0]," *
                      "UNIT[\"degree\",0.0174532925199433]],PROJECTION[\"Transverse_Mercator\"]," *
                      "PARAMETER[\"latitude_of_origin\",0],PARAMETER[\"central_meridian\",$cm]," *
                      "PARAMETER[\"scale_factor\",0.9996],PARAMETER[\"false_easting\",500000]," *
                      "PARAMETER[\"false_northing\",0],UNIT[\"Metre\",1]]"
            @test crs_from_wkt(wkt(15)) == wkt(15)                     # another name: not sure by default
            @test crs_from_wkt(wkt(15); any_name = true) == "EPSG:32633"
            @test crs_from_wkt(wkt(16); any_name = true) == wkt(16)    # no EPSG code has this definition
            # A geographic grid.
            f = joinpath(tmp, "geo.ers")
            @test status(wait_job(export_file(s, make(s, Float32; rotation = 0.0, crs = "EPSG:4326"), f))) == JOB_DONE
            g, B = load(s, f)
            @test g.crs == "EPSG:4326" && isequal(B, Float32.(A))
        end

        @testset "a coordinate system ER Mapper has no name for is a note" begin
            crs = "+proj=tmerc +lat_0=0 +lon_0=17 +k=0.9996 +x_0=500000 +y_0=0 +ellps=GRS80 +units=m +type=crs"
            f = joinpath(tmp, "raw.ers")
            job = wait_job(export_file(s, make(s, Float32; crs), f))
            @test status(job) == JOB_DONE
            @test occursin("ER Mapper has no name for the coordinate system of the grid, so raw.ers has none. " *
                           "Export to GeoTIFF to keep it.", report_text(job))
            g, _ = load(s, f)
            @test g.crs == ""
            # GeoTIFF keeps it as WKT.
            f = joinpath(tmp, "raw.tif")
            job = wait_job(export_file(s, make(s, Float32; crs), f))
            @test status(job) == JOB_DONE && !occursin("has none", report_text(job))
            g, _ = load(s, f)
            @test occursin("Transverse_Mercator", g.crs) && occursin("17", g.crs)
        end

        @testset "a grid with no coordinate system" begin
            for ext in (".tif", ".ers")
                f = joinpath(tmp, "nocrs$ext")
                @test status(wait_job(export_file(s, make(s, Float32; crs = ""), f))) == JOB_DONE
                g, B = load(s, f)
                @test g.crs == "" && isequal(B, Float32.(A))
                @test all(same.((g.x0, g.y0, g.rotation), (500000.25, 7000000.5, 15.0)))
            end
            # ER Mapper needs a CoordinateSpace block, which GDAL leaves out here.
            text = read(joinpath(tmp, "nocrs.ers"), String)
            @test occursin("\tCoordinateSpace Begin\n\t\tDatum\t= \"RAW\"\n\t\tProjection\t= \"RAW\"\n" *
                           "\t\tCoordinateType\t= EN\n\t\tRotation\t= 15:0:0.0\n\tCoordinateSpace End\n" *
                           "\tRasterInfo Begin", text)
        end
    end
end
