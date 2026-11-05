using Test, JuliaMagCore
using JuliaMagCore: with_gdb, read_gdb_blob_symbols, blob_offset, read_gdb_object, gdb_registry, GdbIpj, gdb_ipj,
                    GdbMeta, read_gdb_meta, gdb_crs

"""
A database with two channels on one line and the admin objects in `admin`
(name => bytes). Its channel handles start at 20 (16 blob and 4 line symbols),
so `__21` is the registry of channel slot 1.
"""
function admin_gdb(admin; kw...)
    path = joinpath(mktempdir(), "admin.gdb")
    write_test_gdb(path; channels = [TestChannel(name = "x"), TestChannel(name = "Mag")],
                   lines = [TestLine(name = "L10", number = 10)],
                   blob = (l, c) -> TestBlob(values = [1.0, 2.0]), admin = admin, kw...)
end

"`read_gdb_meta` on the database at `path`: the meta, the warnings and the cp1252 flag of the file."
meta_of(path) = with_gdb(path) do g
    meta, warns = read_gdb_meta(g, read_gdb_blob_symbols(g))
    (meta, warns, g.cp1252)
end

"The bytes of the admin object of symbol `k` in the database at `path`, as `read_gdb_object` gives them."
object_of(path, k) = with_gdb(g -> read_gdb_object(g, blob_offset(g, g.header.first_admin + k)), path)

"The message of the `GdbError` that `f()` throws, or `nothing` when it throws none."
admin_error(f) = try
    f()
    nothing
catch e
    e isa GdbError ? e.msg : rethrow()
end

@testset "gdb admin objects" begin
    @testset "afgrav" begin
        with_gdb(testdata("gdb/afgrav.gdb")) do g
            meta, warns = read_gdb_meta(g, read_gdb_blob_symbols(g))
            @test isempty(warns)
            @test meta.dbreg["DB_CHAN_X"] == "xTM" && meta.dbreg["DB_CHAN_Y"] == "yTM"
            @test Set((x, y) for (x, y, _) in meta.ipj) == Set([("xTM", "yTM"), ("lon", "lat"), ("xlam", "ylam")])
            @test only(i[3].name for i in meta.ipj if i[1] == "xTM") == "WGS 84 / *tm_afghan"    # custom TM
            @test only(i[3].name for i in meta.ipj if i[1] == "xlam") == "WGS 84 / *lcc_afghan"
            @test only(i[3].method for i in meta.ipj if i[1] == "lon") == 1
            @test [x for (x, _, _) in meta.ipj] == ["xTM", "lon", "xlam"]                           # symbol order
            # Channel registries by slot: afgrav has __550 to __554, __559, __566, __567, __572, __573,
            # its channel handles start at 550, and __350 is a line registry.
            @test sort!(collect(keys(meta.channel_reg))) == [0, 1, 2, 3, 4, 9, 16, 17, 22, 23]
            @test all(r -> r isa Dict{String,String}, values(meta.channel_reg))
            @test !g.cp1252
        end
    end

    @testset "coordinate system names" begin
        @test gdb_crs(GdbIpj("NAD27 / UTM zone 7N", 11, "NAD27", "m"), "x", "y") == ("EPSG:26707", nothing)
        @test gdb_crs(GdbIpj("NAD83 / UTM zone 10N", 11, "NAD83", "m"), "x", "y")[1] == "EPSG:26910"
        @test gdb_crs(GdbIpj("WGS 84", 1, "WGS 84", "dega"), "lon", "lat")[1] == "EPSG:4326"
        c, w = gdb_crs(GdbIpj("WGS 84 / *tm_afghan", 11, "WGS 84", "m"), "xTM", "yTM")
        @test c == "" && occursin("custom", w) && occursin("xTM, yTM", w)
        @test w == "the coordinate system WGS 84 / *tm_afghan is a Geosoft custom system with no EPSG code. " *
                   "Set the coordinate system of xTM, yTM in the database."
        c, w = gdb_crs(GdbIpj("*local_grid", 11, "WGS 84", "m"), "x", "y")
        @test c == "" && occursin("custom", w)
        c, w = gdb_crs(GdbIpj("Made up / system", 11, "WGS 84", "m"), "x", "y")
        @test c == "" && occursin("does not know", w)
        @test w == "JuliaMag does not know the coordinate system Made up / system. " *
                   "Set the coordinate system of x, y in the database."
        # A star inside a name, not at the start of the projection part, is not a custom system.
        c, w = gdb_crs(GdbIpj("Made*up", 11, "WGS 84", "m"), "x", "y")
        @test c == "" && occursin("does not know", w)
        c, w = gdb_crs(GdbIpj("", 0, "", ""), "E", "N")
        @test c == "" && w == "the coordinate system of E, N in the file has no name. " *
                              "Set the coordinate system of E, N in the database."
    end

    @testset "registries" begin
        path = admin_gdb(["__dbreg" => test_registry(["DB_CHAN_X" => "x", "DB_CHAN_Y" => "y", "DB_CHAN_Z" => ""]),
                          "__21" => test_registry(["LABEL" => "Total field", "UNITS" => "nT", "CLASS" => ""]),
                          "__20" => test_registry(["UNITS" => "m"])])
        meta, warns, cp = meta_of(path)
        @test isempty(warns) && !cp
        @test meta.dbreg == Dict("DB_CHAN_X" => "x", "DB_CHAN_Y" => "y", "DB_CHAN_Z" => "")
        @test meta.channel_reg == Dict(1 => Dict("LABEL" => "Total field", "UNITS" => "nT", "CLASS" => ""),
                                       0 => Dict("UNITS" => "m"))
        @test isempty(meta.ipj)

        # Line registries (__16 to __19), user registries (__24 on) and other names are not read.
        path = admin_gdb(["__16" => test_registry(["ASSOCIATED" => "x"]), "__24" => test_registry(["A" => "b"]),
                          "__2x" => test_registry(["A" => "b"]), "__021" => test_registry(["LABEL" => "z"]),
                          "Line Selection" => fill(0xff, 32), "OE32.View" => Vector{UInt8}("text")])
        meta, warns, _ = meta_of(path)
        @test isempty(warns) && isempty(meta.channel_reg) && isempty(meta.dbreg)

        # No __dbreg at all (AirMag) is not a warning.
        meta, warns, _ = meta_of(admin_gdb(Pair{String,Vector{UInt8}}[]))
        @test isempty(warns) && isempty(meta.dbreg) && isempty(meta.channel_reg) && isempty(meta.ipj)

        # A value that is not UTF-8 reads as Windows-1252 and marks the file.
        meta, warns, cp = meta_of(admin_gdb(["__21" => test_registry(["UNITS" => UInt8[0x80]])]))
        @test isempty(warns) && meta.channel_reg[1]["UNITS"] == "€" && cp
    end

    @testset "registry bytes" begin
        bytes = test_registry(["KEY" => "value", "EMPTY" => ""])
        @test gdb_registry(bytes) == Dict("KEY" => "value", "EMPTY" => "")
        # A slot with no NUL is a key with an empty value; an empty slot is left out.
        b = test_registry(["A" => "1", "B" => "2"])
        b[128 + 256 + 1:128 + 512] .= 0x00
        @test gdb_registry(b) == Dict("A" => "1")
        b[128 + 256 + 1:128 + 512] .= UInt8('k')
        @test gdb_registry(b) == Dict("A" => "1", "k"^256 => "")
        @test occursin("negative", admin_error(() -> gdb_registry(put_i32!(copy(bytes), 124, -1))))
        @test occursin("run past", admin_error(() -> gdb_registry(put_i32!(copy(bytes), 124, 3))))
        @test occursin("run past", admin_error(() -> gdb_registry(bytes[1:100])))
    end

    @testset "IPJ bytes" begin
        ipj = gdb_ipj(test_ipj(name = "NAD83 / UTM zone 10N", method = 11, datum = "NAD83", units = "m"))
        @test ipj == GdbIpj("NAD83 / UTM zone 10N", 11, "NAD83", "m")
        @test occursin("short", admin_error(() -> gdb_ipj(test_ipj(name = "WGS 84")[1:515])))
    end

    @testset "objects" begin
        path = admin_gdb(["__dbreg" => test_registry(["DB_CHAN_X" => "x"]), "?|IPJ_x:Mag" => test_ipj(name = "WGS 84"),
                          "Line Selection" => fill(0xff, 32)])
        class, bytes = object_of(path, 0)
        @test class == "REG" && length(bytes) == length(test_registry(["DB_CHAN_X" => "x"]))
        @test bytes[29:32] == [0xff, 0x00, 0xf0, 0x0f]
        class, bytes = object_of(path, 1)
        @test class == "IPJ" && length(bytes) == 776
        @test object_of(path, 2) === nothing                       # no object frame at +28
    end

    @testset "coordinate system objects" begin
        path = admin_gdb(["?|IPJ_Easting:Northing" => test_ipj(name = "NAD83 / UTM zone 10N", datum = "NAD83"),
                          "?|IPJ_GPSLon1:GPSLat1" => test_ipj(name = "WGS 84", method = 1, units = "dega"),
                          "?|IPJ___X:__Y" => test_ipj(name = "WGS 84")])
        meta, warns, _ = meta_of(path)
        @test isempty(warns)
        # Pairs whose channels are not live are still returned here; Task 7 drops them.
        @test [(x, y) for (x, y, _) in meta.ipj] == [("Easting", "Northing"), ("GPSLon1", "GPSLat1"), ("__X", "__Y")]
        @test meta.ipj[1][3] == GdbIpj("NAD83 / UTM zone 10N", 11, "NAD83", "m")
        @test meta.ipj[2][3] == GdbIpj("WGS 84", 1, "WGS 84", "dega")

        # A name with no colon, two colons or an empty channel name is skipped with a warning.
        path = admin_gdb(["?|IPJ_xy" => test_ipj(name = "WGS 84"), "?|IPJ_a:b:c" => test_ipj(name = "WGS 84"),
                          "?|IPJ_:y" => test_ipj(name = "WGS 84"), "?|IPJ_x:Mag" => test_ipj(name = "WGS 84")])
        meta, warns, _ = meta_of(path)
        @test [(x, y) for (x, y, _) in meta.ipj] == [("x", "Mag")]
        @test warns == ["the coordinate system object $n of the file does not name two channels; it was skipped"
                        for n in ("?|IPJ_xy", "?|IPJ_a:b:c", "?|IPJ_:y")]
    end

    @testset "damaged objects are warnings" begin
        damaged(name) = "the $name object of the file is damaged; it was skipped"
        good = test_registry(["DB_CHAN_X" => "x"])

        # A registry whose frame is broken: one warning and an empty registry.
        broken = copy(good)
        broken[29] = 0x00
        meta, warns, _ = meta_of(admin_gdb(["__dbreg" => broken]))
        @test warns == [damaged("__dbreg")] && isempty(meta.dbreg)

        # A payload length that runs past the blob.
        long = put_i32!(copy(good), 24, 4096)
        meta, warns, _ = meta_of(admin_gdb(["__21" => long]))
        @test warns == [damaged("__21")] && isempty(meta.channel_reg)

        # A registry with n = -1.
        meta, warns, _ = meta_of(admin_gdb(["__21" => put_i32!(copy(good), 124, -1)]))
        @test warns == [damaged("__21")] && isempty(meta.channel_reg)

        # An object of the wrong class.
        meta, warns, _ = meta_of(admin_gdb(["__dbreg" => test_ipj(name = "WGS 84"), "?|IPJ_x:Mag" => good]))
        @test warns == [damaged("__dbreg"), damaged("?|IPJ_x:Mag")] && isempty(meta.dbreg) && isempty(meta.ipj)

        # An IPJ object too short for its fields.
        short = test_gdb_object("IPJ", " JPI", zeros(UInt8, 100))
        meta, warns, _ = meta_of(admin_gdb(["?|IPJ_x:Mag" => short]))
        @test warns == [damaged("?|IPJ_x:Mag")] && isempty(meta.ipj)

        # A live directory slot that misses its blob gives the warning, not an error.
        # The writer puts symbol k at admin blob 4 * 4 + k (lines_max * chans_max + k).
        path = admin_gdb(["__dbreg" => good, "__21" => test_registry(["LABEL" => "Total field"])]; misdirect = [16])
        meta, warns, _ = meta_of(path)
        @test warns == [damaged("__dbreg")] && isempty(meta.dbreg)
        @test meta.channel_reg == Dict(1 => Dict("LABEL" => "Total field"))

        # A listed object with no live directory slot is missing; it gives the same warning.
        meta, warns, _ = meta_of(admin_gdb(["__dbreg" => good]; dead = [16]))
        @test warns == [damaged("__dbreg")] && isempty(meta.dbreg)

        # A stale later copy is not read: the directory decides.
        path = admin_gdb(["__dbreg" => good]; stale = [16])
        meta, warns, _ = meta_of(path)
        @test isempty(warns) && meta.dbreg == Dict("DB_CHAN_X" => "x")
    end
end
