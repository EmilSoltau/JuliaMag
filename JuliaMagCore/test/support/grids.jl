# Helpers for the grid tests. Later tasks add more here.

"Make a small Float32 grid in `folder` and fill it with 1, 2, 3, ... (row 1 first)."
function small_grid(folder; nx = 3, ny = 2)
    g = create_grid(folder, "Mag", Float32, nx, ny; dx = 10.0, dy = 20.0, x0 = 100.0, y0 = 200.0)
    write_rows!(g, 1, Float32[(j - 1) * nx + i for i in 1:nx, j in 1:ny])
    return g
end

using CodecZlib: ZlibCompressor

"""
The 512-byte header of a Geosoft grid with the given fields, little-endian,
made by the header writer of the exporter. The statistics fields stay zero;
readers ignore them.
"""
function grd_header_bytes(; es = 4, sf = 2, ne = 3, nv = 2, kx = 1, de = 1.0, dv = 1.0, x0 = 0.0, y0 = 0.0,
                          rot = 0.0, zbase = 0.0, zmult = 1.0, label = "")
    h = GrdHeader(es, sf, ne, nv, kx, de, dv, x0, y0, rot, zbase, zmult, label, es & 1024 != 0)
    return JuliaMagCore.grd_header_bytes(h)
end

"The 16-byte header Oasis writes before each compressed block (research section 4)."
const GRD_BLOCK_HEADER = UInt8[0x0f, 0x0e, 0xff, 0xfe, 0x12, 0x34, 0x56, 0x78, 0x02, 0, 0, 0, 0x01, 0, 0, 0]

"""
    write_test_grd(path, A::Matrix; T = Float32, kx = 1, compress = false, rot = 0.0, x0, y0, de, dv,
                   zbase = 0.0, zmult = 1.0)

Write the grid `A` (`A[i, j]` is column `i`, row `j`, row 1 south) as a Geosoft
grid of stored type `T`. `NaN` becomes the dummy. Stored value =
`(value - zbase) * zmult`, rounded for an integer `T`. With `kx = 1` a vector
is a row; with `kx = -1` it is a column, and `de` is then the Y spacing.
`de` and `dv` are the header fields DE and DV.

With `compress = true` the values go in zlib blocks of 65,536 bytes of whole
vectors (one vector when one does not fit), in the layout of research section 4.
The grid is written a vector at a time, so any size works.
"""
function write_test_grd(path, A::Matrix; T::Type = Float32, kx = 1, compress = false, rot = 0.0, x0, y0, de, dv,
                        zbase = 0.0, zmult = 1.0)
    kx in (1, -1) || throw(ArgumentError("kx must be 1 or -1"))
    es = sizeof(T)
    sf = T <: AbstractFloat ? 2 : T <: Signed ? 1 : 0
    ne, nv = kx == 1 ? size(A) : reverse(size(A))
    stored(v) = isnan(v) ? grd_dummy(T) : T <: Integer ? round(T, (v - zbase) * zmult) : T((v - zbase) * zmult)
    vector(k) = htol.(stored.(kx == 1 ? view(A, :, k) : view(A, k, :)))
    h = grd_header_bytes(; es = compress ? es + 1024 : es, sf, ne, nv, kx, de, dv, x0, y0, rot, zbase, zmult)
    open(path, "w") do io
        write(io, h)
        if !compress
            for k in 1:nv
                write(io, vector(k))
            end
            return
        end
        vpb = max(1, 65536 ÷ (ne * es))
        nb = cld(nv, vpb)
        write(io, htol(0xF8E7D8C7), htol(Int32(2)), htol(Int32(nb)), htol(Int32(vpb)))
        table = position(io)
        write(io, zeros(UInt8, 12 * nb))      # filled in below
        offsets, sizes = Int64[], Int32[]
        for b in 1:nb
            ks = (b - 1) * vpb + 1:min(b * vpb, nv)
            raw = UInt8[]
            foreach(k -> append!(raw, reinterpret(UInt8, vector(k))), ks)
            payload = transcode(ZlibCompressor, raw)
            push!(offsets, position(io))
            push!(sizes, 16 + length(payload))
            write(io, GRD_BLOCK_HEADER, payload)
        end
        seek(io, table)
        write(io, htol.(offsets), htol.(sizes))
    end
    return path
end
