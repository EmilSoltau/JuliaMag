using Test, JuliaMagCore
import ArchGDAL as AG

const GRD_DATA = joinpath(@__DIR__, "data", "grids")

grd_data(name) = joinpath(GRD_DATA, name)

"A small fixed sequence of pseudo-random bytes, so a test gives the same bytes every run."
function lcg_bytes(n, seed)
    x = UInt64(seed)
    out = Vector{UInt8}(undef, n)
    for k in 1:n
        x = x * 6364136223846793005 + 1442695040888963407
        out[k] = UInt8(x >> 56)
    end
    return out
end

"Copy grid files from the test data into `folder`."
copy_grids(folder, names...) = foreach(n -> cp(grd_data(n), joinpath(folder, n)), names)

cfb_error(f, name = "ipj") = try
    JuliaMagCore.read_cfb_stream(f, name)
    nothing
catch e
    e isa GridError ? e.msg : rethrow()
end

le32(b, off) = Int(ltoh(only(reinterpret(UInt32, b[off + 1:off + 4]))))
set_le32!(b, off, v) = (b[off + 1:off + 4] .= reinterpret(UInt8, [htol(UInt32(v))]); b)

@testset "compound file reader" begin
    ipj = JuliaMagCore.read_cfb_stream(grd_data("test_uncompressed.grd.gi"), "ipj")
    @test length(ipj) == 1044                       # 4096-byte sectors, mini stream
    @test ipj[1:4] == UInt8[0xff, 0x00, 0xf0, 0x0f]
    @test String(ipj[973:976]) == "EPSG"
    ipj = JuliaMagCore.read_cfb_stream(grd_data("mag_4126.grd.gi"), "ipj")
    @test length(ipj) == 844                        # 512-byte sectors
    @test String(ipj[77:95]) == "NAD27 / *lcc_or_ofr"
    reg = JuliaMagCore.read_cfb_stream(grd_data("mag_4126.grd.gi"), "reg")
    @test length(reg) == 3432
    meta = JuliaMagCore.read_cfb_stream(grd_data("mag_4126.grd.gi"), "meta_ext")
    @test length(meta) == 11223                     # above the cutoff: in normal sectors
    @test JuliaMagCore.read_cfb_stream(grd_data("mag_4126.grd.gi"), "IPJ") == ipj   # names ignore case
    @test JuliaMagCore.read_cfb_stream(grd_data("mag_4126.grd.gi"), "nothing") === nothing

    mktempdir() do tmp
        f = joinpath(tmp, "x.gi")
        b = read(grd_data("test_uncompressed.grd.gi"))
        write(f, b[1:100])
        @test occursin("shorter than", cfb_error(f))
        write(f, lcg_bytes(600, 1))
        @test occursin("not a compound file", cfb_error(f))

        # The FAT entry of the first directory sector points at itself: a loop.
        ss = 4096
        dir = le32(b, 0x30)
        fat = le32(b, 0x4C)
        c = copy(b)
        set_le32!(c, (fat + 1) * ss + 4dir, dir)
        write(f, c)
        @test occursin("loop", cfb_error(f))
        # A sector number past the end of the file.
        c = copy(b)
        set_le32!(c, (fat + 1) * ss + 4dir, 0x00ffffff)
        write(f, c)
        @test occursin("past the end", cfb_error(f))
        # A stream size larger than the file.
        c = copy(b)
        root = (dir + 1) * ss
        for k in 1:8                                  # find the "ipj" entry
            e = root + 128 * (k - 1)
            String(c[e + 1:e + 6]) == "i\0p\0j\0" && set_le32!(c, e + 120, 10^9)
        end
        write(f, c)
        @test occursin("past the end", cfb_error(f))

        # Random damage gives a stream, nothing or GridError, never another error.
        for (name, seed) in (("test_uncompressed.grd.gi", 10), ("mag_4126.grd.gi", 20))
            good = read(grd_data(name))
            bad = 0
            for k in 1:150
                c = copy(good)
                r = lcg_bytes(16, seed + k)
                for j in 1:4
                    pos = 1 + (Int(r[2j - 1]) << 8 | Int(r[2j])) * length(c) ÷ 65536
                    c[pos] = r[8 + j]
                end
                write(f, c)
                try
                    JuliaMagCore.read_cfb_stream(f, "ipj")
                catch e
                    e isa GridError || (bad += 1)
                end
            end
            @test bad == 0
        end
    end
end

@testset "coordinate system names" begin
    @test crs_from_name("WGS 84") == "EPSG:4326"
    @test crs_from_name("GDA94 / MGA zone 55") == "EPSG:28355"
    @test crs_from_name("NAD27 / *lcc_or_ofr") === nothing
    @test crs_from_name("WGS") === nothing                 # exact names only
    @test crs_from_name("") === nothing
    @test crs_from_name("a\0b") === nothing
end

@testset "coordinate system side files" begin
    @test crs_from_grd_xml(grd_data("test_uncompressed.grd.xml")) == "EPSG:4326"
    @test crs_from_grd_xml(grd_data("om_float.grd.xml")) === nothing    # type="UNKNOWN"
    @test crs_from_grd_xml(grd_data("om_order.grd.xml")) === nothing
    @test crs_from_grd_gi(grd_data("test_uncompressed.grd.gi")) == "EPSG:4326"
    @test crs_from_grd_gi(grd_data("mag_4126.grd.gi")) === nothing      # a name Proj does not know
    @test crs_from_grd_gi(grd_data("om_float.grd.gi")) === nothing

    mktempdir() do tmp
        # Only `dataset/georeference/projection` counts, not a copy under `lineage`.
        # Without `wellknown_epsg` the name is tried.
        f = joinpath(tmp, "a.grd.xml")
        write(f, """
            <?xml version="1.0" encoding="UTF-8"?>
            <gmd:MD_Metadata xmlns:gmd="http://www.isotc211.org/2005/gmd">
              <geosoft xmlns="http://www.geosoft.com/schema/geo">
                <dataset version="1">
                  <lineage><projection type="PROJECTED" name="WGS 84 / UTM zone 33N" wellknown_epsg="32633"/></lineage>
                  <georeference>
                    <projection type="PROJECTED" name="GDA94 / MGA zone 55"><units name="m"/></projection>
                  </georeference>
                </dataset>
              </geosoft>
            </gmd:MD_Metadata>
            """)
        @test crs_from_grd_xml(f) == "EPSG:28355"
        write(f, """<geosoft xmlns="http://www.geosoft.com/schema/geo"><dataset><georeference>
                    <projection type="UNKNOWN" name="WGS 84"/></georeference></dataset></geosoft>""")
        @test crs_from_grd_xml(f) === nothing
        write(f, """<geosoft><dataset><georeference><projection type="GEOGRAPHIC" name="WGS 84"
                    wellknown_epsg="999999999"/></georeference></dataset></geosoft>""")
        @test crs_from_grd_xml(f) == "EPSG:4326"           # an unknown code falls back to the name
        write(f, "<geosoft><dataset>")
        @test_throws GridError crs_from_grd_xml(f)
    end
end

@testset ".grd importer" begin
    importing(s) = filter(startswith(".importing-"), readdir(joinpath(s.project.folder, "grids")))
    first_line(job) = first(split(report_text(job), '\n'))
    function load(s, f)
        job = wait_job(import_file(s, f))
        status(job) == JOB_DONE || error("import of $f failed: $(job.error)")
        return grid(s.project, only(job.outputs)), job
    end
    no_crs(file) = "No coordinate system was found for $file. Set it in the grid properties."

    @test grd_kind(grd_data("om_float.grd")) == :geosoft
    @test grd_kind(grd_data("om_compress.grd")) == :geosoft
    @test grd_kind(grd_data("incomplete_grid.grd")) == :geosoft     # the header is fine

    mktempdir() do tmp
        s = new_session(joinpath(tmp, "p"), "p")

        @testset "Geosoft grids and their side files" begin
            for name in ("test_uncompressed.grd", "test_compressed.grd")
                g, job = load(s, grd_data(name))
                @test g.crs == "EPSG:4326"
                @test g.nx == 286 && g.ny == 251
                @test first_line(job) == "Geosoft or Surfer grid import of $(grd_data(name)): " *
                                         "This .grd file is a Geosoft grid. Geosoft GRD grid 286 x 251 cells, " *
                                         "$(g.count) with values"
                @test !occursin("coordinate system", report_text(job))
            end

            # Without the .xml the .gi gives the coordinate system.
            d = mkpath(joinpath(tmp, "gi_only"))
            copy_grids(d, "test_uncompressed.grd", "test_uncompressed.grd.gi")
            g, job = load(s, joinpath(d, "test_uncompressed.grd"))
            @test g.crs == "EPSG:4326"
            @test !occursin("coordinate system", report_text(job))

            # Without side files the grid imports with no coordinate system and a warning.
            d = mkpath(joinpath(tmp, "none"))
            copy_grids(d, "test_uncompressed.grd")
            g, job = load(s, joinpath(d, "test_uncompressed.grd"))
            @test g.crs == ""
            @test occursin(no_crs("test_uncompressed.grd"), report_text(job))

            # NAD27 Lambert with a Geosoft name and no EPSG code: the name is in the warning.
            g, job = load(s, grd_data("mag_4126.grd"))
            @test g.crs == ""
            @test occursin(no_crs("mag_4126.grd") * " The .gi file names it \"NAD27 / *lcc_or_ofr\", " *
                           "which Proj does not know.", report_text(job))

            # om_float.grd.xml says type="UNKNOWN", and the .gi has no name.
            g, job = load(s, grd_data("om_float.grd"))
            @test g.crs == ""
            @test occursin(no_crs("om_float.grd"), report_text(job))
            @test !occursin("names it", report_text(job))
            @test occursin("Geosoft GRD grid 50 x 49 cells", first_line(job))
        end

        @testset "the report holds the label" begin
            f = joinpath(tmp, "label.grd")
            open(io -> write(io, grd_header_bytes(; label = "Total field"), Float32[1, 2, 3, 4, 5, 6]), f, "w")
            _, job = load(s, f)
            @test occursin("Geosoft GRD grid 3 x 2 cells, 6 with values, label \"Total field\"", first_line(job))
        end

        @testset "damaged side files are warnings" begin
            # A .gi cut to 100 bytes, and no .xml.
            d = mkpath(joinpath(tmp, "cut"))
            copy_grids(d, "mag_4126.grd")
            write(joinpath(d, "mag_4126.grd.gi"), read(grd_data("mag_4126.grd.gi"))[1:100])
            g, job = load(s, joinpath(d, "mag_4126.grd"))
            @test g.crs == "" && g.nx * g.ny > 0
            r = report_text(job)
            @test occursin("The coordinate system in mag_4126.grd.gi could not be read:", r)
            @test occursin(no_crs("mag_4126.grd"), r)

            # A broken .xml, and a good .gi.
            d = mkpath(joinpath(tmp, "badxml"))
            copy_grids(d, "test_uncompressed.grd", "test_uncompressed.grd.gi")
            write(joinpath(d, "test_uncompressed.grd.xml"), "<geosoft><dataset>")
            g, job = load(s, joinpath(d, "test_uncompressed.grd"))
            @test g.crs == "EPSG:4326"
            @test occursin("The coordinate system in test_uncompressed.grd.xml could not be read:", report_text(job))
            @test !occursin("No coordinate system", report_text(job))
        end

        @testset "Surfer grids" begin
            # File order: `A[col, row]`, row 1 is the north row. 7 sits in the north-west cell.
            A = Float32[7 1 2; 3 4 5; 6 8 9; 10 11 12]
            gt = (1000.0, 10.0, 0.0, 2030.0, 0.0, -10.0)
            function check(f, kind, words)
                @test grd_kind(f) == kind
                g, job = load(s, f)
                @test first_line(job) == "Geosoft or Surfer grid import of $f: This .grd file is a $words grid. " *
                                         "$(g.source.format) grid 4 x 3 cells, 12 with values"
                B = read_rows(g, 1, 3)
                @test B[1, 3] == 7 && isequal(B, A[:, end:-1:1])
                @test g.dx ≈ 10 && g.dy ≈ 10 && g.x0 ≈ 1005 && g.y0 ≈ 2005
                @test g.name == splitext(basename(f))[1]
            end
            for (driver, kind, words) in (("GS7BG", :surfer7, "Surfer 7"), ("GSBG", :surfer6, "Surfer 6"))
                f = joinpath(tmp, "$driver.grd")
                AG.create(f; driver = AG.getdriver(driver), width = 4, height = 3, nbands = 1, dtype = Float32) do ds
                    v = collect(gt)
                    GC.@preserve v AG.setgeotransform!(ds, v)
                    AG.write!(AG.getband(ds, 1), A)
                end
                check(f, kind, words)
            end
            f = joinpath(tmp, "ascii.grd")
            AG.create(AG.getdriver("MEM"); width = 4, height = 3, nbands = 1, dtype = Float32) do mem
                v = collect(gt)
                GC.@preserve v AG.setgeotransform!(mem, v)
                AG.write!(AG.getband(mem, 1), A)
                AG.destroy(AG.unsafe_copy(mem; filename = f, driver = AG.getdriver("GSAG")))
            end
            check(f, :surfer_ascii, "Surfer ASCII")
        end

        @testset "a file that is neither" begin
            f = joinpath(tmp, "random.grd")
            write(f, vcat(UInt8[0x01, 0x02, 0xab, 0xff], lcg_bytes(596, 7)))
            @test grd_kind(f) == :unknown
            n = length(s.project.items)
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_FAILED
            @test occursin("random.grd is not a Geosoft or Surfer grid (it starts with 01 02 ab ff)", job.error)
            @test length(s.project.items) == n && isempty(importing(s))
            write(f, UInt8[])
            job = wait_job(import_file(s, f))
            @test status(job) == JOB_FAILED
            @test occursin("random.grd is not a Geosoft or Surfer grid (the file is empty)", job.error)
        end
        @test isempty(importing(s))
    end
end
