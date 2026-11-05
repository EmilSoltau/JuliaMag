# The `.gdb` import on real files (research sections 13 and 14).
#
# These files are not in the repo: the larger public files are too big, the
# Geoscience BC files have no licence that allows sharing, and AirMag.gdb is
# Geosoft's tutorial file. A machine without them prints one SKIP line per
# file and runs no test for it.

using Test, JuliaMagCore
using JuliaMagCore: channel, channel_position

const GDB_SAMPLES = get(ENV, "JULIAMAG_GDB_SAMPLES", "/home/ems/data/juliamag-samples/gdb")

"""
Run `f(paths...)` with the sample files `rels` (relative to `GDB_SAMPLES`), or
print one SKIP line when one of them is missing.
"""
function with_gdb_samples(f, rels::String...)
    paths = [joinpath(GDB_SAMPLES, r) for r in rels]
    k = findfirst(!isfile, paths)
    if k !== nothing
        println("SKIP gdb real file: $(rels[k]) not found (set JULIAMAG_GDB_SAMPLES)")
        return nothing
    end
    return f(paths...)
end

"Import `path` with `import_file` into a new project; returns the session, the job and the database."
function import_real_gdb(path)
    s = new_session(joinpath(mktempdir(), "p"), "p")
    j = wait_job(import_file(s, path))
    @test status(j) == JOB_DONE
    status(j) == JOB_DONE || error("the import of $path failed: $(j.error)")
    return s, j, database(s.project, only(j.outputs))
end

"The values of channel `name` on all lines, as one vector."
all_values(db, name) = reduce(vcat, [vec(collect(read_channel(db, l.id, name))) for l in db.lines])

"The missing values in every channel and line of `db`."
count_missing(db) = sum(count(JuliaMagCore.ismissingvalue, all_values(db, c.name)) for c in db.channels)

"True when every line has the Oasis default fiducial start 0 and step 1 (research risk 1)."
default_fiducials(db) = all(l -> l.fid_start == 0.0 && l.fid_step == 1.0, db.lines)

@testset "gdb real files" begin
    @testset "long_valley_ed (plain blobs)" begin
        with_gdb_samples("usgs-ofr2004-1096-long-valley/long_valley_ed.gdb",
                         "usgs-ofr2004-1096-long-valley/long_valley_ed.XYZ") do gdb, xyz
            s, j, db = import_real_gdb(gdb)
            @test length(db.channels) == 15 && length(db.lines) == 30
            @test "line L28_29 has a name that is not a number; it was imported as L30" in job_warnings(j)
            @test channel(db, "TIME").format == :time && channel(db, "DATE").format == :date
            @test count_missing(db) == 11_316
            @test default_fiducials(db)
            # The export has no names line. The column order is the channel list of the
            # USGS report, "Data processing steps" (Anderson and Finn, 2004, OFR 2004-1096,
            # https://pubs.usgs.gov/of/2004/1096/lv_data_proc.html). The report spells the
            # gradient VRT_GRAD; the channel in the .gdb is VERT_GRAD.
            names = ["long", "lat", "X_UTM", "Y_UTM", "elevation", "TOP_RDG_RAW", "TOP_RDG", "TOP_DNL",
                     "BOTTOM_RDG_RAW", "BOTTOM_RDG", "BOTTOM_DNL", "VRT_GRAD", "base_mag", "TIME", "DATE"]
            # The block "Line 28_29" is line L30, as the warning above says.
            n, bad = compare_gdb_xyz(db, xyz; names, rename = Dict("VRT_GRAD" => "VERT_GRAD"),
                                     lines = Dict("Line 28_29" => "L30"))
            @test isempty(bad) && n == 191_580
            close_session!(s)
        end
    end

    @testset "GDR_clmag (plain, one long line)" begin
        with_gdb_samples("usgs-ofr2006-1204-gdr-clmag/GDR_clmag.gdb",
                         "usgs-ofr2006-1204-gdr-clmag/GDR_clmag.XYZ") do gdb, xyz
            s, j, db = import_real_gdb(gdb)
            @test length(db.lines) == 1 && db.lines[1].nrows == 1_023_807
            @test channel(db, "resmag").label == "mag"
            @test default_fiducials(db)
            n, bad = compare_gdb_xyz(db, xyz; skip_all_missing_rows = true)
            @test isempty(bad) && n == 5_119_025
            close_session!(s)
        end
    end

    @testset "fortymile (LZRW1, many chunks)" begin
        with_gdb_samples("dggs-gpr2015-004-fortymile/fortymile_linedata.gdb",
                         "dggs-gpr2015-004-fortymile/fortymile_linedata_final.xyz") do gdb, xyz
            s, j, db = import_real_gdb(gdb)
            @test length(db.lines) == 288
            @test db.pairs[db.current_pair].crs == "EPSG:26707"
            # All 28 columns of 2,113,249 rows. Research 13 counts 57,057,723 because its
            # script left out the BIRDHITE column; with the rename it is compared too.
            n, bad = compare_gdb_xyz(db, xyz; rename = Dict("BIRDHITE" => "BIRDHIT"))
            @test isempty(bad) && n == 59_170_972 == 28 * 2_113_249
            close_session!(s)
        end
    end

    @testset "7042_106_wform (plain, GS_FLOAT)" begin
        with_gdb_samples("geosciencebc-quest-7042/7042_106_wform.gdb",
                         "geosciencebc-quest-7042/7042_106_wform.xyz") do gdb, xyz
            s, j, db = import_real_gdb(gdb)
            @test channel(db, "fiducial").eltype === Float32
            @test all(l -> l.flight == 106, db.lines)
            @test default_fiducials(db)
            n, bad = compare_gdb_xyz(db, xyz)
            @test isempty(bad) && n == 10_000
            close_session!(s)
        end
    end

    @testset "7042-MtMill (zlib, arrays, integers, text, fiducial starts)" begin
        with_gdb_samples("geosciencebc-quest-7042/7042-MtMill.gdb") do gdb
            s, j, db = import_real_gdb(gdb)
            @test channel(db, "Sf").arraylen == 40 && channel(db, "Bf").arraylen == 40
            @test channel(db, "FltNo").eltype === Int32 && channel(db, "Date").eltype === String
            for l in db.lines
                flt = collect(read_channel(db, l.id, "FltNo"))
                @test all(v -> JuliaMagCore.ismissingvalue(v) || v == l.flight, flt)
                dates = collect(read_channel(db, l.id, "Date"))
                @test all(d -> isempty(d) || d == replace(l.date, '-' => '/'), dates)
                @test l.fid_start > 0 && l.fid_step == 1.0
            end
            xy = only(p for p in db.pairs if (p.x, p.y) == ("x", "y"))
            @test xy.crs == "EPSG:26910" && db.pairs[db.current_pair] === xy
            # The stale IPJ objects name channels that are gone, so they give no pair.
            @test all(p -> channel_position(db, p.x) > 0 && channel_position(db, p.y) > 0, db.pairs)
            @test length(db.pairs) == 2
            close_session!(s)
        end
    end

    @testset "AirMag (Oasis tutorial)" begin
        path = get(ENV, "JULIAMAG_AIRMAG_GDB", "")
        if isempty(path) || !isfile(path)
            println("SKIP AirMag.gdb: set JULIAMAG_AIRMAG_GDB")
        else
            s, j, db = import_real_gdb(path)
            @test length(db.lines) == 127
            lines = [l.id for l in db.lines if l.id.type == LINE]
            ties = [l.id for l in db.lines if l.id.type == TIE]
            @test length(lines) == 117 && extrema(l.number for l in lines) == (10160, 11320)
            @test length(ties) == 10 && extrema(l.number for l in ties) == (90060, 90150)
            @test [c.name for c in db.channels] == ["Mag", "x", "y"] && all(c -> c.eltype === Float64, db.channels)
            @test db.rows_written == 83_466
            mag, x, y = all_values(db, "Mag"), all_values(db, "x"), all_values(db, "y")
            @test !any(isnan, mag) && !any(isnan, x) && !any(isnan, y)
            near(v, want, d) = abs(v - want) <= 0.5 * 10.0^-d
            @test near(minimum(mag), 55990.98, 2) && near(maximum(mag), 58295.42, 2)
            @test near(minimum(x), 582834.9, 1) && near(maximum(x), 612106.6, 1)
            @test near(minimum(y), 6849898.5, 1) && near(maximum(y), 6873483.0, 1)
            @test all(l -> l.date == "2023-03-01", db.lines)
            p = db.pairs[db.current_pair]
            @test (p.x, p.y, p.crs) == ("x", "y", "")
            @test "the file stores no coordinate system for x, y. Set it in the database." in job_warnings(j)
            close_session!(s)
        end
    end
end
