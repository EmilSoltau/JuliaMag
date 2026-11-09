using Test, JuliaMagCore
using JuliaMagCore: GdbChannelRecord, GdbLineRecord, GdbMeta, GdbIpj, gdb_type, WarningLog, with_gdb, read_gdb_channels,
                    read_gdb_lines, read_gdb_blob_symbols, read_gdb_meta, create_database, LineInfo, LineId, line_name,
                    gdb_line_type, gdb_date, plan_gdb_lines, plan_gdb_channels

"A live channel record in slot `slot`; type 5 is Float64."
chan_rec(slot, name; type = 5, format = 0, width = 10, decimals = 2, arraylen = 1) =
    GdbChannelRecord(slot, name, type, 2, format, width, decimals, arraylen)

"A line record in slot `slot`: type 0 is `L`, category 100 a normal line."
line_rec(slot, name, number; type = 0, category = 100, date = 0.0, flight = 0, version = 0) =
    GdbLineRecord(slot, name, category, date, number, type, flight, version)

"Metadata with a database registry, channel registries by slot and IPJ entries."
meta_with(; dbreg = Dict{String,String}(), reg = Dict{Int,Dict{String,String}}(), ipj = Tuple{String,String,GdbIpj}[]) =
    GdbMeta(dbreg, reg, ipj)

const UTM10 = GdbIpj("NAD83 / UTM zone 10N", 11, "NAD83", "m")
const WGS84 = GdbIpj("WGS 84", 1, "WGS 84", "dega")
const CUSTOM_TM = GdbIpj("WGS 84 / *tm_afghan", 11, "WGS 84", "m")

"An empty database in a temporary folder."
empty_db() = create_database(joinpath(mktempdir(), "db"), "db")

"`plan_gdb_channels` with a fresh log: the plans, pairs, current index and warning texts."
function channel_plans(records, m; crs = "")
    log = WarningLog()
    plans, pairs, current = plan_gdb_channels(records, m, crs, log)
    return (plans = plans, pairs = pairs, current = current, warns = [w.message for w in log.list])
end

"The plan of the channel named `name` (JuliaMag name)."
plan_named(plans, name) = only(p for p in plans if p.name == name)

"The pairs as `(x, y, crs)` tuples; `PositionPair` is mutable and has no `==`."
pt(pairs) = [(p.x, p.y, p.crs) for p in pairs]

@testset "gdb lines and channels" begin
    @testset "dates" begin
        @test gdb_date(2023 + 59 / 365) == "2023-03-01"            # AirMag, research 14
        @test gdb_date(2007 + 276 / 365) == "2007-10-04"
        @test gdb_date(2024 + 59 / 366) == "2024-02-29"            # leap year
        @test gdb_date(2023.0) == "2023-01-01"
        @test gdb_date(2023 + 364.9 / 365) == "2023-12-31"         # rounds to day 366, clamped to 365
        @test gdb_date(0.0) == ""
        @test gdb_date(NaN) == "" && gdb_date(Inf) == "" && gdb_date(-Inf) == ""
        @test gdb_date(-1.0e32) == "" && gdb_date(-1.0e31) == ""
        @test gdb_date(1.0e30) == "" && gdb_date(-5.0) == "" && gdb_date(10000.5) == ""    # no yyyy year
    end

    @testset "line types by letter" begin
        @test gdb_line_type(0) == LINE
        @test gdb_line_type(1) == BASE && gdb_line_type(2) == TIE
        @test gdb_line_type(3) == TEST && gdb_line_type(4) == TREND
        @test gdb_line_type(5) == SPECIAL && gdb_line_type(6) == RANDOM
        @test gdb_line_type(7) === nothing && gdb_line_type(-1) === nothing
    end

    @testset "line plans" begin
        recs = [line_rec(0, "L10", 10; date = 2023 + 59 / 365, flight = 90), line_rec(1, "L28_29", -2147483647),
                line_rec(2, "L20", 20), line_rec(3, "G1", 0; category = 200), line_rec(4, "T5", 5; type = 2),
                line_rec(5, "T_x", -2147483647; type = 2)]
        log = WarningLog()
        plans = plan_gdb_lines(recs, empty_db(), log)
        @test [line_name(p.id) for p in plans] == ["L10", "L21", "L20", "T5", "T6"]
        @test [p.slot for p in plans] == [0, 1, 2, 4, 5]
        @test [p.name for p in plans] == ["L10", "L28_29", "L20", "T5", "T_x"]
        @test plans[1].flight == 90 && plans[1].date == "2023-03-01" && plans[2].date == ""
        msgs = [w.message for w in log.list]
        @test any(w -> occursin("L28_29", w) && occursin("L21", w), msgs)
        @test "line L28_29 has a name that is not a number; it was imported as L21" in msgs
        @test "line T_x has a name that is not a number; it was imported as T6" in msgs
        @test "group line G1 was skipped; JuliaMag has no group lines" in msgs
        @test all(w -> w.file_line == 0, log.list)
        @test length(msgs) == 3
    end

    @testset "line plans: types, versions and the database" begin
        db = empty_db()
        push!(db.lines, LineInfo(LineId(LINE, 40, 0), 0, "", 0.0, 1.0, 0, 0, true))
        push!(db.lines, LineInfo(LineId(TIE, 3, 0), 0, "", 0.0, 1.0, 0, 0, true))
        recs = [line_rec(0, "B7", 7; type = 1, version = 2), line_rec(1, "Q1", 1; type = 9),
                line_rec(2, "Lx", -2147483647), line_rec(3, "Ly", -2147483647), line_rec(4, "Tx", -2147483647; type = 2),
                line_rec(5, "D0", 0; type = 6)]
        log = WarningLog()
        plans = plan_gdb_lines(recs, db, log)
        # A base line keeps letter B (Geosoft 1); version from the record.
        @test plans[1].id == LineId(BASE, 7, 2)
        # Unknown type skipped; dummy numbers count up above the database's L40 and T3.
        @test [line_name(p.id) for p in plans] == ["B7.2", "L41", "L42", "T4", "D0"]
        msgs = [w.message for w in log.list]
        @test "line Q1 has the line type 9, which JuliaMag does not know; it was skipped" in msgs
        # A type with no lines at all starts at 1.
        plans = plan_gdb_lines([line_rec(0, "Sx", -2147483647; type = 3)], empty_db(), WarningLog())
        @test only(plans).id == LineId(TEST, 1, 0)
    end

    @testset "channel names, labels and units" begin
        recs = [chan_rec(0, "a/b"), chan_rec(1, "CON"), chan_rec(2, "x"), chan_rec(3, "X"), chan_rec(4, "faa"), chan_rec(5, "ba"),
                chan_rec(6, "mag")]
        reg = Dict(4 => Dict("LABEL" => "mgals", "UNITS" => "mGal"), 5 => Dict("LABEL" => "", "UNITS" => ""),
                   6 => Dict("UNITS" => "nT"), 2 => Dict("LABEL" => "  Easting "))
        r = channel_plans(recs, meta_with(; reg = reg))
        @test [p.name for p in r.plans] == ["a_b", "CON_", "x", "X_2", "faa", "ba", "mag"]
        @test [p.slot for p in r.plans] == collect(0:6)
        # Labels keep the names in the file (Review Focus 4); a LABEL with text is kept exactly.
        @test [p.label for p in r.plans] == ["a/b", "CON", "  Easting ", "X", "mgals", "ba", "mag"]
        @test [p.units for p in r.plans] == ["", "", "", "", "mGal", "", "nT"]
        @test isempty(r.pairs) && r.current == 0
    end

    @testset "types and display settings" begin
        recs = [chan_rec(0, "mag"; type = 4, format = 1, width = 12, decimals = 3), chan_rec(1, "time"; format = 2),
                chan_rec(2, "date"; format = 3), chan_rec(3, "bad"; width = 0, decimals = -5),
                chan_rec(4, "Longitude"; format = 4), chan_rec(5, "sig"; format = 5), chan_rec(6, "hex"; type = 3, format = 6),
                chan_rec(7, "odd"; format = 99), chan_rec(8, "Sf"; type = 4, arraylen = 40), chan_rec(9, "note"; type = -16),
                chan_rec(10, "notes"; type = -8, arraylen = 3), chan_rec(11, "after")]
        r = channel_plans(recs, meta_with())
        @test [p.name for p in r.plans] == ["mag", "time", "date", "bad", "Longitude", "sig", "hex", "odd", "Sf",
                                            "note", "after"]
        mag = plan_named(r.plans, "mag")
        @test mag.format == :exponential && mag.width == 12 && mag.decimals == 3
        @test mag.gtype == gdb_type(4) && mag.gtype.T === Float32
        @test plan_named(r.plans, "time").format == :time && plan_named(r.plans, "date").format == :date
        bad = plan_named(r.plans, "bad")
        @test bad.width == 10 && bad.decimals == -1 && bad.format == :normal
        @test all(n -> plan_named(r.plans, n).format == :normal, ["Longitude", "sig", "hex", "odd"])
        @test plan_named(r.plans, "Longitude").width == 10 && plan_named(r.plans, "Longitude").decimals == 2
        @test plan_named(r.plans, "Sf").arraylen == 40
        @test plan_named(r.plans, "note").gtype.T === String && plan_named(r.plans, "note").arraylen == 1
        @test "channel notes is an array of text values; JuliaMag cannot store it, so it was skipped" in r.warns
        # A value type JuliaMag does not know: skipped with a warning, not an error.
        u = channel_plans([chan_rec(0, "mag"), chan_rec(1, "Vec"; type = 12)], meta_with())
        @test [p.name for p in u.plans] == ["mag"]
        @test u.warns == ["channel Vec has the value type 12, which JuliaMag cannot read; it was skipped"]
        @test "channels bad, Longitude, sig, hex, odd: their Oasis display settings have no JuliaMag equal; " *
              "they are shown as normal numbers" in r.warns
        @test count(w -> occursin("display settings", w), r.warns) == 1
        # One changed channel reads in the singular.
        r = channel_plans([chan_rec(0, "Longitude"; format = 4)], meta_with())
        @test r.warns == ["channel Longitude: its Oasis display settings have no JuliaMag equal; " *
                          "it is shown as a normal number"]
        # Display settings JuliaMag accepts give no warning.
        @test isempty(channel_plans([chan_rec(0, "a"; width = 1, decimals = -1)], meta_with()).warns)
    end

    @testset "current pair from the registry with an IPJ" begin
        recs = [chan_rec(0, "Easting"), chan_rec(1, "Northing"), chan_rec(2, "Longitude"), chan_rec(3, "Latitude"), chan_rec(4, "Z"),
                chan_rec(5, "mag")]
        m = meta_with(; dbreg = Dict("DB_CHAN_X" => "Easting", "DB_CHAN_Y" => "Northing", "DB_CHAN_Z" => "Z"),
                 ipj = [("Easting", "Northing", UTM10), ("Longitude", "Latitude", WGS84),
                        ("GPSLon1", "GPSLat1", WGS84)])          # stale: no live channels
        r = channel_plans(recs, m)
        @test pt(r.pairs) == [("Easting", "Northing", "EPSG:26910"),
                          ("Longitude", "Latitude", "EPSG:4326")]
        @test r.current == 1
        @test [p.role for p in r.plans] == [ROLE_X, ROLE_Y, ROLE_LON, ROLE_LAT, ROLE_Z, ROLE_NONE]
        @test isempty(r.warns)
    end

    @testset "current pair by name, no coordinate system" begin
        recs = [chan_rec(0, "x"), chan_rec(1, "y"), chan_rec(2, "mag")]               # AirMag
        r = channel_plans(recs, meta_with())
        @test pt(r.pairs) == [("x", "y", "")] && r.current == 1
        @test [p.role for p in r.plans] == [ROLE_X, ROLE_Y, ROLE_NONE]
        @test r.warns == ["the file stores no coordinate system for x, y. Set it in the database."]
        r = channel_plans(recs, meta_with(); crs = "EPSG:32755")
        @test pt(r.pairs) == [("x", "y", "EPSG:32755")] && isempty(r.warns)
    end

    @testset "custom coordinate system on the current pair" begin
        recs = [chan_rec(0, "xTM"), chan_rec(1, "yTM")]
        m = meta_with(; dbreg = Dict("DB_CHAN_X" => "xTM", "DB_CHAN_Y" => "yTM"), ipj = [("xTM", "yTM", CUSTOM_TM)])
        r = channel_plans(recs, m)
        @test pt(r.pairs) == [("xTM", "yTM", "")]
        @test r.warns == ["the coordinate system WGS 84 / *tm_afghan is a Geosoft custom system with no EPSG " *
                          "code. Set the coordinate system of xTM, yTM in the database."]
        # The crs setting fills the current pair when the file's system cannot be used.
        r = channel_plans(recs, m; crs = "EPSG:32642")
        @test pt(r.pairs) == [("xTM", "yTM", "EPSG:32642")] && isempty(r.warns)
        # A system JuliaMag can use wins over the setting.
        m2 = meta_with(; dbreg = m.dbreg, ipj = [("xTM", "yTM", UTM10)])
        @test pt(channel_plans(recs, m2; crs = "EPSG:32642").pairs) == [("xTM", "yTM", "EPSG:26910")]
    end

    @testset "lon and lat by name, next to x and y" begin
        recs = [chan_rec(0, "x"), chan_rec(1, "y"), chan_rec(2, "Longitude"), chan_rec(3, "Latitude")]
        r = channel_plans(recs, meta_with())
        @test pt(r.pairs) == [("x", "y", ""), ("Longitude", "Latitude", "EPSG:4326")]
        @test r.current == 1
        @test [p.role for p in r.plans] == [ROLE_X, ROLE_Y, ROLE_LON, ROLE_LAT]
        @test r.warns == ["the file stores no coordinate system for x, y. Set it in the database."]
    end

    @testset "a second projected pair gets no roles" begin
        recs = [chan_rec(0, "Easting"), chan_rec(1, "Northing"), chan_rec(2, "xlam"), chan_rec(3, "ylam")]
        lcc = GdbIpj("WGS 84 / *lcc_afghan", 3, "WGS 84", "m")
        m = meta_with(; dbreg = Dict("DB_CHAN_X" => "Easting", "DB_CHAN_Y" => "Northing"),
                 ipj = [("Easting", "Northing", UTM10), ("xlam", "ylam", lcc)])
        r = channel_plans(recs, m)
        @test pt(r.pairs) == [("Easting", "Northing", "EPSG:26910"), ("xlam", "ylam", "")]
        @test [p.role for p in r.plans] == [ROLE_X, ROLE_Y, ROLE_NONE, ROLE_NONE]
        # Only the current pair takes the crs setting.
        r = channel_plans(recs, m; crs = "EPSG:32642")
        @test r.pairs[2].crs == "" && length(r.warns) == 1 && occursin("xlam, ylam", r.warns[1])
    end

    @testset "pair rules" begin
        # No current pair in the file: the first pair found is current, and takes the crs setting.
        recs = [chan_rec(0, "e1"), chan_rec(1, "n1"), chan_rec(2, "mag")]
        m = meta_with(; ipj = [("e1", "n1", CUSTOM_TM)])
        r = channel_plans(recs, m; crs = "EPSG:32642")
        @test pt(r.pairs) == [("e1", "n1", "EPSG:32642")] && r.current == 1 && isempty(r.warns)
        @test [p.role for p in r.plans] == [ROLE_X, ROLE_Y, ROLE_NONE]
        # An IPJ that repeats the current pair adds no pair; units dega make a pair geographic.
        recs = [chan_rec(0, "x"), chan_rec(1, "y"), chan_rec(2, "glon"), chan_rec(3, "glat")]
        dega = GdbIpj("WGS 84", 2, "WGS 84", "dega")
        m = meta_with(; ipj = [("x", "y", UTM10), ("y", "x", UTM10), ("glon", "glat", dega)])
        r = channel_plans(recs, m)
        @test pt(r.pairs) == [("x", "y", "EPSG:26910"), ("glon", "glat", "EPSG:4326")]
        @test [p.role for p in r.plans] == [ROLE_X, ROLE_Y, ROLE_LON, ROLE_LAT]
        # Step 3 is not added when an earlier pair uses lon or lat.
        recs = [chan_rec(0, "Lon"), chan_rec(1, "Lat")]
        m = meta_with(; dbreg = Dict("DB_CHAN_X" => "Lon", "DB_CHAN_Y" => "Lat"), ipj = [("Lon", "Lat", WGS84)])
        r = channel_plans(recs, m)
        @test pt(r.pairs) == [("Lon", "Lat", "EPSG:4326")]
        @test [p.role for p in r.plans] == [ROLE_LON, ROLE_LAT]
        # Pairs name the JuliaMag channel names; registry names match by case when there is no exact match.
        recs = [chan_rec(0, "E/1"), chan_rec(1, "N/1")]
        m = meta_with(; dbreg = Dict("DB_CHAN_X" => "e/1", "DB_CHAN_Y" => "N/1"), ipj = [("E/1", "N/1", UTM10)])
        r = channel_plans(recs, m)
        @test pt(r.pairs) == [("E_1", "N_1", "EPSG:26910")]
        # A registry pair whose channels are not live, a text or an array channel is not used.
        recs = [chan_rec(0, "x"; type = -8), chan_rec(1, "y"), chan_rec(2, "Easting"; arraylen = 2), chan_rec(3, "Northing")]
        m = meta_with(; dbreg = Dict("DB_CHAN_X" => "gone", "DB_CHAN_Y" => "y"), ipj = [("Easting", "Northing", UTM10)])
        r = channel_plans(recs, m)
        @test isempty(r.pairs) && r.current == 0 && all(p -> p.role == ROLE_NONE, r.plans)
        # A Z channel that is not live gives nothing.
        r = channel_plans([chan_rec(0, "mag")], meta_with(; dbreg = Dict("DB_CHAN_Z" => "elev")))
        @test only(r.plans).role == ROLE_NONE
    end

    @testset "afgrav" begin
        with_gdb(testdata("gdb/afgrav.gdb")) do g
            m, _ = read_gdb_meta(g, read_gdb_blob_symbols(g))
            log = WarningLog()
            plans, pairs, current = plan_gdb_channels(read_gdb_channels(g), m, "", log)
            warns = [w.message for w in log.list]
            @test pt(pairs) == [("xTM", "yTM", ""), ("longitude", "latitude", "EPSG:4326")]
            @test current == 1
            @test warns == ["the coordinate system WGS 84 / *tm_afghan is a Geosoft custom system with no EPSG " *
                            "code. Set the coordinate system of xTM, yTM in the database."]
            @test [p.name for p in plans] == ["xTM", "yTM", "longitude", "latitude", "obs_grav", "elev",
                                              "dod_grav_libno", "dod_rbs_no", "faa", "ba"]
            @test [p.role for p in plans][1:5] == [ROLE_X, ROLE_Y, ROLE_LON, ROLE_LAT, ROLE_NONE]
            @test all(p -> p.role == ROLE_NONE, plans[5:end])
            # The owner's label ruling: LABEL text is kept, an empty LABEL falls back to the name.
            @test plan_named(plans, "faa").label == "mgals" && plan_named(plans, "xTM").label == "degrees"
            @test plan_named(plans, "ba").label == "ba" && plan_named(plans, "elev").label == "meters"
            @test plan_named(plans, "xTM").units == "m" && plan_named(plans, "faa").units == ""
            @test plan_named(plans, "xTM").width == 11 && plan_named(plans, "xTM").decimals == 2
            @test all(p -> p.gtype.T === Float64 && p.format == :normal && p.arraylen == 1, plans)

            lines = plan_gdb_lines(read_gdb_lines(g), empty_db(), log)
            @test only(lines).id == LineId(RANDOM, 0, 0) && only(lines).name == "D0"
            @test only(lines).date == gdb_date(2005.813698630137) && only(lines).date == "2005-10-25"
            @test length(log.list) == 1
        end
    end
end
