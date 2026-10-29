using Test, JuliaMagCore

const GRID_DATA = joinpath(@__DIR__, "data", "grids")

"""
Write a Geosoft grid file: a 512-byte header with the given fields, then `data`
(any array, written as its raw bytes). Little-endian, as the format says.
"""
function write_grd(path; data = Float32[], fields...)
    open(path, "w") do io
        write(io, grd_header_bytes(; fields...))
        write(io, data)
    end
    return path
end

grid_file(name) = joinpath(GRID_DATA, name)

"The block offsets and sizes in the table of a compressed Geosoft grid."
function grd_blocks(path)
    b = read(path)
    nb = Int(ltoh(only(reinterpret(Int32, b[521:524]))))
    offsets = Int.(ltoh.(reinterpret(Int64, b[529:528 + 8nb])))
    sizes = Int.(ltoh.(reinterpret(Int32, b[529 + 8nb:528 + 12nb])))
    return offsets, sizes
end

header_error(f) = try
    open(read_grd_header, f)
    nothing
catch e
    e isa GridError ? e.msg : rethrow()
end

@testset "Geosoft grid header" begin
    h = open(read_grd_header, grid_file("om_float.grd"))
    @test h.es == 4 && h.sf == 2 && h.ne == 50 && h.nv == 49 && h.kx == 1 && !h.compressed
    @test grd_eltype(h) == Float32
    @test open(read_grd_header, grid_file("om_short.grd")) |> grd_eltype == Int16
    @test open(read_grd_header, grid_file("om_byte.grd")) |> grd_eltype == Int8
    @test open(read_grd_header, grid_file("om_long.grd")) |> grd_eltype == Int32
    @test open(read_grd_header, grid_file("om_double.grd")) |> grd_eltype == Float64
    c = open(read_grd_header, grid_file("om_compress.grd"))
    @test c.compressed && c.es > 1024 && grd_eltype(c) == Float32

    @test grd_dummy(Int8) == -127 && grd_dummy(UInt8) == 255
    @test grd_dummy(Int16) == -32767 && grd_dummy(UInt16) == 65535
    @test grd_dummy(Int32) == -2147483647 && grd_dummy(UInt32) == 4294967295
    @test grd_dummy(Float32) === Float32(-1.0e32) && grd_dummy(Float64) === -1.0e32

    mktempdir() do tmp
        f = joinpath(tmp, "h.grd")
        @test occursin("colour grid holds colours, not values", header_error(write_grd(f; sf = 3)))
        @test occursin("KX = 2", header_error(write_grd(f; kx = 2)))
        @test occursin("element size of ES = 3", header_error(write_grd(f; es = 3)))
        @test occursin("element size of ES = 2052", header_error(write_grd(f; es = 2052)))
        @test occursin("element size of ES = 3076", header_error(write_grd(f; es = 3076)))
        @test occursin("not a finite number", header_error(write_grd(f; de = Inf)))
        @test occursin("not a finite number", header_error(write_grd(f; dv = Inf)))
        @test occursin("not a finite number", header_error(write_grd(f; x0 = NaN)))
        big = 2^31 - 1
        @test occursin("$big by $big cells, more than any file can hold",
                       header_error(write_grd(f; ne = big, nv = big)))
        @test occursin("not a Geosoft grid type", header_error(write_grd(f; es = 8, sf = 0)))
        @test occursin("not a Geosoft grid type", header_error(write_grd(f; es = 1, sf = 2)))
        @test occursin("NE = 0", header_error(write_grd(f; ne = 0)))
        @test occursin("NV = -1", header_error(write_grd(f; nv = -1)))
        @test occursin("DE = 0.0", header_error(write_grd(f; de = 0.0)))
        @test occursin("DV = -2.0", header_error(write_grd(f; dv = -2.0)))
        @test occursin("ZMULT = 0", header_error(write_grd(f; zmult = 0.0)))
        write(f, zeros(UInt8, 100))
        @test occursin("100 bytes", header_error(f))
        h = open(read_grd_header, write_grd(f; label = "My label  "))
        @test h.label == "My label"
        h = open(read_grd_header, write_grd(f; es = 1028))
        @test h.compressed && h.es == 1028 && grd_eltype(h) == Float32
    end
end

@testset "Geosoft grid import" begin
    importing(s) = filter(startswith(".importing-"), readdir(joinpath(s.project.folder, "grids")))
    report_text(job) = String(take!(copy(job.report)))
    run_grd(s, f) = start_job!(s, "import.test_grd", Dict{String,Any}("path" => f), (p, io) -> begin
        r = read_geosoft_grd(s, f, Dict{String,Any}(), p)
        println(io, r.summary)
        [r.item]
    end)
    function load(s, f)
        job = wait_job(run_grd(s, f))
        status(job) == JOB_DONE || error("import of $f failed: $(job.error)")
        g = grid(s.project, only(job.outputs))
        return g, read_rows(g, 1, g.ny), job
    end

    mktempdir() do tmp
        s = new_session(joinpath(tmp, "p"), "p")

        @testset "integer grids match the float grid" begin
            g, F, job = load(s, grid_file("om_float.grd"))
            @test g.nx == 50 && g.ny == 49 && g.eltype == Float32
            @test g.name == "om_float"
            @test g.source.format == "Geosoft GRD" && g.source.eltype == "float32" && g.source.compression == ""
            @test g.source.file == grid_file("om_float.grd")
            @test count(isnan, F) == 655 && g.count == 50 * 49 - 655
            @test isempty(importing(s))
            # The quantisation of a scaled integer grid is 0.5 / ZMULT: about 4e-4,
            # 0.1 and 6e-9 (research section 2). For om_byte it is 0.1016.
            for (name, tol, T) in (("om_short", 4e-4, "int16"), ("om_byte", 0.102, "int8"), ("om_long", 6e-9, "int32"))
                h, A, _ = load(s, grid_file("$name.grd"))
                @test h.source.eltype == T
                hd = open(read_grd_header, grid_file("$name.grd"))
                @test 0.5 / hd.zmult <= tol
                scaled = hd.zmult != 1 || hd.zbase != 0
                # Float32 only for an 8 or 16 bit file without scaling.
                @test h.eltype == (scaled || T == "int32" ? Float64 : Float32)
                @test isequal(isnan.(A), isnan.(F))
                ok = .!isnan.(F)
                @test maximum(abs.(A[ok] .- F[ok])) <= tol
                @test (h.x0, h.y0, h.dx, h.dy, h.rotation) == (g.x0, g.y0, g.dx, g.dy, g.rotation)
            end
        end

        @testset "a grid stored by columns" begin
            g, D, _ = load(s, grid_file("om_double.grd"))
            h, O, _ = load(s, grid_file("om_order.grd"))
            @test open(read_grd_header, grid_file("om_order.grd")).kx == -1
            @test g.eltype == Float64 && h.eltype == Float64
            @test (h.nx, h.ny) == (g.nx, g.ny)
            # The two files hold the same grid. om_double's values are rounded
            # to Float32 and om_order's are not, so they differ by up to 6e-9.
            @test isequal(isnan.(O), isnan.(D))
            ok = .!isnan.(D)
            @test maximum(abs.(O[ok] .- D[ok])) < 1e-8
            @test count(isnan, D) == 655
            @test (h.x0, h.y0, h.dx, h.dy, h.rotation) == (g.x0, g.y0, g.dx, g.dy, g.rotation)
        end

        @testset "a rotated grid" begin
            g, _, _ = load(s, grid_file("om_rotate.grd"))
            @test g.rotation == -30.0
            nodes = [cell_centre(g, i, j) for i in (1, g.nx), j in (1, g.ny)]
            xs, ys = first.(nodes), last.(nodes)
            @test isapprox(minimum(xs), 1; atol = 1e-3) && isapprox(maximum(xs), 67.435; atol = 1e-3)
            @test isapprox(minimum(ys), -48.5; atol = 1e-3) && isapprox(maximum(ys), 17.569; atol = 1e-3)
        end

        @testset "a real survey grid" begin
            g, A, _ = load(s, grid_file("test_uncompressed.grd"))
            @test g.nx == 286 && g.ny == 251 && g.eltype == Float32
            @test g.count == count(!isnan, A) && g.count > 0
        end

        @testset "a cut file fails" begin
            n = length(s.project.items)
            job = wait_job(run_grd(s, grid_file("incomplete_grid.grd")))
            @test status(job) == JOB_FAILED && occursin("ends after", job.error)
            @test length(s.project.items) == n && isempty(importing(s))

            f = write_grd(joinpath(tmp, "short.grd"); ne = 3, nv = 2, data = Float32[1, 2, 3, 4])
            job = wait_job(run_grd(s, f))
            @test status(job) == JOB_FAILED
            @test occursin("the file ends after 16 of 24 data bytes", job.error)
            @test length(s.project.items) == n && isempty(importing(s))
        end

        @testset "a bad header fails the job" begin
            f = write_grd(joinpath(tmp, "kx.grd"); kx = 3, data = Float32[1, 2, 3, 4, 5, 6])
            job = wait_job(run_grd(s, f))
            @test status(job) == JOB_FAILED && occursin("KX = 3", job.error) && isempty(importing(s))
        end

        @testset "a huge header fails before any folder is made" begin
            n = length(s.project.items)
            for es in (4, 8)
                f = write_grd(joinpath(tmp, "huge$es.grd"); es, ne = 2^31 - 1, nv = 2^31 - 1, data = zeros(UInt8, 64))
                job = wait_job(run_grd(s, f))
                @test status(job) == JOB_FAILED && occursin("more than any file can hold", job.error)
                @test startswith(job.error, "GridError: ")
            end
            @test length(s.project.items) == n && isempty(importing(s))
        end

        @testset "compressed Oasis grids equal their uncompressed twins" begin
            g, C, _ = load(s, grid_file("om_compress.grd"))
            _, F, _ = load(s, grid_file("om_float.grd"))
            @test isequal(C, F)
            @test g.source.compression == "zlib" && g.source.eltype == "float32" && g.eltype == Float32

            @test length(first(grd_blocks(grid_file("test_compressed.grd")))) == 5
            _, C, _ = load(s, grid_file("test_compressed.grd"))
            _, U, _ = load(s, grid_file("test_uncompressed.grd"))
            @test size(C) == (286, 251) && isequal(C, U)

            g, A, _ = load(s, grid_file("mag_4126.grd"))
            @test g.count == count(!isnan, A) && 0 < g.count < length(A)
            @test g.source.compression == "zlib"
            @test isempty(importing(s))
        end

        @testset "written compressed grids read back" begin
            A = [Float64(i + 1000j) for i in 1:300, j in 1:700]
            A[7, 3] = NaN
            A[300, 700] = NaN
            for kx in (1, -1)
                f = joinpath(tmp, "w$kx.grd")
                write_test_grd(f, A; kx, compress = true, x0 = 10.0, y0 = 20.0, de = 2.0, dv = 3.0)
                offsets, sizes = grd_blocks(f)
                # Rows: 1200 bytes, 54 per block, 13 blocks. Columns: 2800 bytes, 23 per block, 14 blocks.
                @test length(offsets) == (kx == 1 ? 13 : 14)
                g, B, _ = load(s, f)
                @test g.eltype == Float32 && g.source.compression == "zlib"
                @test isequal(B, Float32.(A))
                @test g.count == length(A) - 2
                @test (g.x0, g.y0) == (10, 20) && (g.dx, g.dy) == (kx == 1 ? (2, 3) : (3, 2))
            end

            # A scaled integer grid: the stored values are dummy-masked, then scaled.
            Q = [i - 2.5j for i in 1:40, j in 1:30]
            Q[1, 1] = NaN
            f = write_test_grd(joinpath(tmp, "i16.grd"), Q; T = Int16, compress = true, x0 = 0.0, y0 = 0.0,
                               de = 1.0, dv = 1.0, zbase = 100.0, zmult = 2.0)
            g, B, _ = load(s, f)
            @test g.eltype == Float64 && g.source.eltype == "int16" && isequal(B, Q)

            # One vector is more than 65,536 bytes, so each block holds one vector.
            W = [Float64(i * j) for i in 1:9000, j in 1:3]
            f = write_test_grd(joinpath(tmp, "wide.grd"), W; T = Float64, compress = true, x0 = 0.0, y0 = 0.0,
                               de = 1.0, dv = 1.0)
            @test length(first(grd_blocks(f))) == 3
            _, B, _ = load(s, f)
            @test B == W
            @test isempty(importing(s))
        end

        @testset "a damaged compressed grid fails with a plain message" begin
            A = [Float64(i + j) for i in 1:300, j in 1:700]
            good = write_test_grd(joinpath(tmp, "good.grd"), A; compress = true, x0 = 0.0, y0 = 0.0, de = 1.0, dv = 1.0)
            offsets, sizes = grd_blocks(good)
            nb = length(offsets)
            n = length(s.project.items)
            function fails(edit!, want)
                b = read(good)
                edit!(b)
                f = joinpath(tmp, "bad.grd")
                write(f, b)
                job = wait_job(run_grd(s, f))
                ok = status(job) == JOB_FAILED && occursin(want, job.error)
                ok || @info "unexpected result" status(job) job.error
                return ok
            end
            # A changed byte in the middle of block 2's payload.
            @test fails(b -> (k = offsets[2] + 16 + sizes[2] ÷ 2 + 1; b[k] ⊻= 0xff), "block 2 is damaged")
            # The block table points past the end of the file.
            @test fails(b -> (b[528 + 8 * (nb - 1) + 1:528 + 8nb] .= reinterpret(UInt8, [htol(Int64(10^9))])),
                        "block $nb starts at byte 1000000000")
            @test fails(b -> (b[528 + 8nb + 1:528 + 8nb + 4] .= reinterpret(UInt8, [htol(Int32(10^8))])),
                        "block 1 starts at byte $(offsets[1]) and is 100000000 bytes long, past the end of the file")
            # A payload that is not zlib (LZRW1).
            @test fails(b -> (b[offsets[1] + 17] = 0x00),
                        "block 1 uses a compression JuliaMag cannot read yet (probably LZRW1, Oasis \"COMP=SPEED\"). " *
                        "Save the grid again in Oasis with size compression or no compression.")
            # A bad signature.
            @test fails(b -> (b[513] = 0x00), "does not start with the Geosoft compression signature")
            # The header asks for more vectors than the blocks hold.
            nv!(b, nv) = (b[13:16] .= reinterpret(UInt8, [htol(Int32(nv))]))
            @test fails(b -> nv!(b, 702), "block 13 inflates to 62400 of the 64800 bytes it must hold")
            @test fails(b -> nv!(b, 800), "the 13 blocks of 54 vectors hold 702 vectors, fewer than the 800 of the grid")
            # A block that holds more than VPB vectors.
            vpb!(b, v) = (b[525:528] .= reinterpret(UInt8, [htol(Int32(v))]))
            @test fails(b -> (nv!(b, 300); vpb!(b, 27)), "block 1 inflates to more than its 27 vectors of 300 values")
            # A tiny file that claims a huge grid fails before any grid is made.
            f = joinpath(tmp, "tiny.grd")
            payload = transcode(ZlibCompressor, zeros(UInt8, 100))
            open(f, "w") do io
                write(io, grd_header_bytes(; es = 1028, ne = 2^31 - 1, nv = 1))
                write(io, htol(0xF8E7D8C7), htol(Int32(2)), htol(Int32(1)), htol(Int32(1)))
                write(io, htol(Int64(540)), htol(Int32(16 + length(payload))), GRD_BLOCK_HEADER, payload)
            end
            job = wait_job(run_grd(s, f))
            @test status(job) == JOB_FAILED
            @test occursin("block 1 is too small to hold 1 vectors of 2147483647 values; the file is damaged", job.error)
            @test length(s.project.items) == n && isempty(importing(s))
            # Dummy padding at the end of the last block is fine.
            f = joinpath(tmp, "pad.grd")
            write(f, (b = read(good); nv!(b, 699); b))
            _, B, _ = load(s, f)
            @test isequal(B, Float32.(A[:, 1:699]))
        end

        @testset "scaling, dummies and padding" begin
            # UInt16 with ZBASE and ZMULT: real = stored / ZMULT + ZBASE, in Float64.
            raw = UInt16[0 7 65535; 1 2 3]'                # file order: vector (row) 1 first
            f = write_grd(joinpath(tmp, "u16.grd"); es = 2, sf = 0, ne = 3, nv = 2, zbase = 50000.0, zmult = 10.0,
                          label = "Total field", data = vcat(vec(raw), UInt16[0xffff, 0xffff]))   # padded
            g, A, job = load(s, f)
            @test g.eltype == Float64 && g.source.eltype == "uint16"
            want = Float64.(raw) ./ 10 .+ 50000
            want[3, 1] = NaN
            @test isequal(A, want)
            @test A[1, 1] == 50000 && A[2, 2] == 50000 + 2 / 10
            @test occursin("Total field", report_text(job))

            # Unscaled 8 and 16 bit files are Float32, 32 bit integer files are Float64.
            for (T, es, sf, G) in ((UInt8, 1, 0, Float32), (Int8, 1, 1, Float32), (Int16, 2, 1, Float32),
                                   (UInt32, 4, 0, Float64), (Int32, 4, 1, Float64))
                d = T[1, 2, grd_dummy(T), 4, 5, 6]
                f = write_grd(joinpath(tmp, "t_$T.grd"); es, sf, data = d)
                g, A, _ = load(s, f)
                @test g.eltype == G && g.source.eltype == lowercase(string(T))
                @test isequal(A, G[1 4; 2 5; NaN 6])
            end

            # Float dummies: every value at or below -1e32 in the stored type.
            f = write_grd(joinpath(tmp, "f32.grd"); data = Float32[1, -1, -9.9e31, -1.0e33, -1.0e32, 6])
            _, A, _ = load(s, f)
            @test isequal(A, Float32[1 NaN; -1 NaN; -9.9e31 6])

            # An all-dummy grid imports with no values.
            f = write_grd(joinpath(tmp, "empty.grd"); es = 8, sf = 2, data = fill(-1.0e32, 6))
            g, A, _ = load(s, f)
            @test all(isnan, A) && g.count == 0
            @test isempty(importing(s))
        end

        @testset "a rotated grid stored by columns keeps each value in place" begin
            # NE = 2 elements per vector (column, going north), NV = 3 vectors (west to east).
            d = Float64[11, 12, 21, 22, 31, 32]           # value = 10 * column + row
            f = write_grd(joinpath(tmp, "cols.grd"); es = 8, sf = 2, ne = 2, nv = 3, kx = -1, de = 5.0, dv = 10.0,
                          x0 = 100.0, y0 = 200.0, rot = 30.0, data = d)
            g, A, _ = load(s, f)
            @test g.nx == 3 && g.ny == 2 && g.dx == 10 && g.dy == 5 && g.rotation == 30
            @test A == [11 12; 21 22; 31 32]
            # Element 2 of vector 1 is DE further along the rotated north axis.
            @test all(cell_centre(g, 1, 2) .≈ (100 - 5sind(30), 200 + 5cosd(30)))
            # Vector 3 is 2 DV along the rotated east axis.
            @test all(cell_centre(g, 3, 1) .≈ (100 + 20cosd(30), 200 + 20sind(30)))
        end
    end
end

# ---- export ------------------------------------------------------------------

import EzXML

"The element paths (local names from the root) and the attribute names of each, in an XML file."
function xml_structure(path)
    out = Dict{String,Set{String}}()
    walk(n, prefix) = for e in EzXML.eachelement(n)
        p = prefix * "/" * EzXML.nodename(e)
        union!(get!(out, p, Set{String}()), (EzXML.nodename(a) for a in EzXML.attributes(e)))
        walk(e, p)
    end
    root = EzXML.root(EzXML.readxml(path))
    walk(root, "/" * EzXML.nodename(root))
    return out
end

"The attributes of the first element with this local name in an XML file."
function xml_attributes(path, name)
    e = findfirst("//*[local-name()='$name']", EzXML.readxml(path))
    return Dict(EzXML.nodename(a) => EzXML.nodecontent(a) for a in EzXML.attributes(e))
end

le(::Type{T}, b, off) where {T} = ltoh(only(reinterpret(T, b[off + 1:off + sizeof(T)])))

@testset "Geosoft grid export" begin
    report_text(job) = String(take!(copy(job.report)))
    temps(dir) = filter(f -> occursin(".tmp", f), readdir(dir))
    function load(s, f)
        job = wait_job(import_file(s, f))
        status(job) == JOB_DONE || error("import of $f failed: $(job.error)")
        g = grid(s.project, only(job.outputs))
        return g, read_rows(g, 1, g.ny), only(job.outputs)
    end
    # A 5 by 4 grid with value 10 * column + row, one NaN, rotated 15 degrees.
    A = Float64[10i + j for i in 1:5, j in 1:4]
    A[2, 3] = NaN
    function make(s, T; name = "Mag 5x4", crs = "EPSG:32633")
        h = GridHeader(5, 4, 25.0, 50.0, 500000.25, 7000000.5, 15.0, crs, "nT", T, GridSource())
        return import_grid(sink -> put_rows!(sink, 1, T.(A)), s, name, h).item.id
    end
    same_place(g, h) = all(isapprox.((g.x0, g.y0, g.dx, g.dy, g.rotation),
                                     (h.x0, h.y0, h.dx, h.dy, h.rotation); rtol = 1e-12))

    mktempdir() do tmp
        s = new_session(joinpath(tmp, "p"), "p")

        @testset "round trip of a $T grid" for T in (Float32, Float64)
            id = make(s, T)
            f = joinpath(tmp, "rt_$T.grd")
            job = wait_job(export_file(s, id, f))
            @test status(job) == JOB_DONE
            @test job.command == "export.geosoft_grd"
            @test occursin("Geosoft grid export of $id to $f: 20 cells", report_text(job))
            @test isfile(f) && isfile(f * ".xml") && !isfile(f * ".gi") && isempty(temps(tmp))
            @test crs_from_grd_xml(f * ".xml") == "EPSG:32633"
            g, B, _ = load(s, f)
            src = grid(s.project, id)
            @test isequal(B, T.(A)) && g.eltype == T
            @test same_place(g, src)
            @test g.crs == "EPSG:32633"
            # Corner values stay at the same ground position.
            @test cell_centre(g, 5, 4) == cell_centre(src, 5, 4) && B[5, 4] == 54
        end

        @testset "the header" begin
            for T in (Float32, Float64)
                id = make(s, T)
                f = joinpath(tmp, "h_$T.grd")
                @test status(wait_job(export_file(s, id, f))) == JOB_DONE
                es = sizeof(T)
                @test filesize(f) == 512 + es * 5 * 4
                h = open(read_grd_header, f)
                @test (h.es, h.sf, h.ne, h.nv, h.kx) == (es, 2, 5, 4, 1)
                @test (h.de, h.dv, h.x0, h.y0, h.rot) == (25.0, 50.0, 500000.25, 7000000.5, 15.0)
                @test (h.zbase, h.zmult, h.label, h.compressed) == (0.0, 1.0, "Mag 5x4", false)
                b = read(f)
                v = Float64.(filter(!isnan, vec(T.(A))))
                @test le(Int32, b, 156) == 19                       # NVPTS
                dummy = Float32(-1.0e32)
                iz = [le(Float32, b, off) for off in (160, 164, 168, 172)]
                if T == Float32
                    @test iz == Float32[minimum(v), maximum(v), dummy, sum(v) / 19]
                else
                    @test iz == fill(dummy, 4)                      # the format spec for double grids
                end
                @test le(Float64, b, 176) ≈ sum(abs2, v .- sum(v) / 19) / 18 rtol = 1e-12   # ZVAR
                @test le(Int32, b, 184) == 0                         # PRCS
                @test all(==(0), b[125:156]) && all(==(0), b[189:512])   # MAPNO, PROJ, UNITX-Z, user area
                # The NaN cell (column 2, row 3) holds the dummy.
                @test le(T, b, 512 + es * (2 * 5 + 1)) == T(-1.0e32)
                @test le(T, b, 512 + es * (3 * 5 + 4)) == 54          # the north-east corner is last
            end
        end

        @testset "the label is cut to 48 bytes" begin
            name = "a"^46 * "ÅÅ"                                  # 50 bytes; a cut must not split Å
            f = joinpath(tmp, "label.grd")
            @test status(wait_job(export_file(s, make(s, Float32; name), f))) == JOB_DONE
            @test open(read_grd_header, f).label == "a"^46 * "Å"
        end

        @testset "the .grd.xml" begin
            id = make(s, Float32)
            f = joinpath(tmp, "x.grd")
            @test status(wait_job(export_file(s, id, f))) == JOB_DONE
            x = f * ".xml"
            # Every element and attribute is one a real Oasis file has.
            mine, model = xml_structure(x), xml_structure(grid_file("template.grd.xml"))
            @test all(p -> haskey(model, p) && issubset(mine[p], model[p]), keys(mine))
            @test any(endswith("/georeference/dataextents/extent2d"), keys(mine))
            # extent2d holds the node extents of the rotated grid.
            g = grid(s.project, id)
            nodes = [cell_centre(g, i, j) for i in (1, 5), j in (1, 4)]
            e = xml_attributes(x, "extent2d")
            @test parse.(Float64, (e["minx"], e["miny"], e["maxx"], e["maxy"])) ==
                  (minimum(first, nodes), minimum(last, nodes), maximum(first, nodes), maximum(last, nodes))
            p = xml_attributes(x, "projection")
            @test p["wellknown_epsg"] == "32633" && p["type"] == "PROJECTED"
            @test p["name"] == "WGS 84 / UTM zone 33N"
            @test xml_attributes(x, "units") == Dict("name" => "m", "unit_scale" => "1")

            # A geographic grid.
            f = joinpath(tmp, "geo.grd")
            @test status(wait_job(export_file(s, make(s, Float32; crs = "EPSG:4326"), f))) == JOB_DONE
            p = xml_attributes(f * ".xml", "projection")
            @test p["type"] == "GEOGRAPHIC" && p["wellknown_epsg"] == "4326"
            @test xml_attributes(f * ".xml", "units") == Dict("name" => "dega", "unit_scale" => "1")

            # No coordinate system, or one with no EPSG code, gives type="UNKNOWN".
            wkt = "+proj=tmerc +lat_0=0 +lon_0=17 +k=0.9996 +x_0=500000 +y_0=0 +ellps=GRS80 +units=m +type=crs"
            for (crs, note) in (("", "The grid has no coordinate system"),
                                (wkt, "The coordinate system of the grid has no EPSG code"))
                f = joinpath(tmp, "unknown.grd")
                job = wait_job(export_file(s, make(s, Float32; crs), f))
                @test status(job) == JOB_DONE && occursin(note, report_text(job))
                @test xml_attributes(f * ".xml", "projection") == Dict("type" => "UNKNOWN")
                @test crs_from_grd_xml(f * ".xml") === nothing
            end
        end

        @testset "om_float.grd exports and imports the same" begin
            g, A1, id = load(s, grid_file("om_float.grd"))
            f = joinpath(tmp, "om_float.grd")
            job = wait_job(export_file(s, id, f))
            @test status(job) == JOB_DONE
            h, A2, _ = load(s, f)
            @test isequal(A2, A1) && h.eltype == g.eltype
            @test (h.x0, h.y0, h.dx, h.dy, h.rotation, h.crs) == (g.x0, g.y0, g.dx, g.dy, g.rotation, g.crs)
            # The statistics match those Oasis wrote.
            o, b = read(grid_file("om_float.grd")), read(f)
            @test le(Int32, b, 156) == le(Int32, o, 156)
            @test [le(Float32, b, k) for k in (160, 164, 172)] == [le(Float32, o, k) for k in (160, 164, 172)]
            @test le(Float64, b, 176) ≈ le(Float64, o, 176) rtol = 1e-9
        end

        @testset "an old .gi next to the target is removed" begin
            f = joinpath(tmp, "old.grd")
            write(f * ".gi", "stale")
            job = wait_job(export_file(s, make(s, Float32), f))
            @test status(job) == JOB_DONE && !isfile(f * ".gi")
            @test occursin("Removed old.grd.gi: it held the coordinate system of the grid that was there before.",
                                       report_text(job))
        end

        @testset "a cancelled or failed export leaves no files" begin
            id = make(s, Float32)
            d = mkpath(joinpath(tmp, "cancel"))
            f = joinpath(d, "c.grd")
            # A test exporter that cancels its own job, then writes: the cancel is seen after the first block.
            register_exporter!(ExporterSpec("export.test_grd_cancel", "Cancel test", ".grd_cancel_test", ITEM_GRID,
                SettingSpec[], (s, item_id, path, settings, progress) -> begin
                    cancel!(only(filter(j -> j.command == "export.test_grd_cancel" && status(j) == JOB_RUNNING,
                                        jobs(s))))
                    export_geosoft_grd(s, item_id, path; progress, record = false)
                end))
            n = length(s.history)
            j = wait_job(export_file(s, id, f; exporter = "export.test_grd_cancel"))
            @test status(j) == JOB_CANCELLED
            @test isempty(readdir(d))
            # An old target and its .xml are kept as they were.
            write(f, "old"); write(f * ".xml", "old xml")
            j = wait_job(export_file(s, id, f; exporter = "export.test_grd_cancel"))
            @test status(j) == JOB_CANCELLED
            @test sort(readdir(d)) == ["c.grd", "c.grd.xml"] && read(f, String) == "old"
            @test length(s.history) == n
            # The .xml target is a folder: the export fails and leaves no temp files.
            rm(f * ".xml"); mkdir(f * ".xml")
            j = wait_job(export_file(s, id, f))
            @test status(j) == JOB_FAILED && occursin("c.grd.xml is a folder", j.error)
            @test sort(readdir(d)) == ["c.grd", "c.grd.xml"] && read(f, String) == "old"
        end

        @testset "a database is not exported to .grd" begin
            @test exporter_for("x.grd").id == "export.geosoft_grd"
            @test isempty(exporter_for("export.geosoft_grd").settings)
            a = joinpath(tmp, "a.xyz")
            write_synthetic_xyz(a; lines = 1, ties = 0, rows_per_line = 5)
            r = import_xyz(s, a)
            j = wait_job(export_file(s, r.item.id, joinpath(tmp, "db.grd")))
            @test status(j) == JOB_FAILED && occursin("no exporter writes a database to a .grd file", j.error)
            j = wait_job(export_file(s, "grid-999", joinpath(tmp, "none.grd")))
            @test status(j) == JOB_FAILED && occursin("grid-999", j.error)
        end

        @testset "a direct call records the export" begin
            id = make(s, Float32)
            n = length(s.history)
            r = export_geosoft_grd(s, id, joinpath(tmp, "direct.grd"))
            @test (r.rows, r.lines) == (20, 0) && r.path == joinpath(tmp, "direct.grd")
            @test length(s.history) == n + 1 && s.history[end].command == "export.geosoft_grd"
        end
    end
end
