# Grid import and export benchmark (docs/bench.md).
#
# Usage:
#   JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_grid.jl [N] [--dir DIR] [--keep]
#
# It writes a synthetic Float32 grid of N by N cells (default 20,000: 1.6 GB) three
# times: as an uncompressed Geosoft .grd, as a compressed Geosoft .grd and as a
# GeoTIFF. It imports each with `import_file`, exports the first grid to every
# format with `export_file`, both with `wait_job`, and prints the time, the speed
# and the memory growth of each step. The files go in a temporary folder that is removed
# at the end.

using JuliaMagCore
import ArchGDAL as AG

# `write_test_grd` and the helpers it needs.
include(joinpath(@__DIR__, "..", "JuliaMagCore", "test", "support", "grids.jl"))

# A grid whose values are made on demand, so writing it needs no memory.
# `A[i, j]` is column `i` and row `j`, row 1 south, as in `write_test_grd`.
struct SynthGrid <: AbstractMatrix{Float32}
    n::Int
end
Base.size(a::SynthGrid) = (a.n, a.n)
Base.IndexStyle(::Type{SynthGrid}) = IndexCartesian()
# A smooth field plus a little noise; about one cell in 1009 is missing.
@inline Base.getindex(a::SynthGrid, i::Int, j::Int) =
    (i + 3j) % 1009 == 0 ? NaN32 :
    Float32(100 * sin(i / 150) * cos(j / 170) + 0.001 * ((i * 7919 + j * 104729) % 1000))

const X0, Y0, CELL = 500_000.0, 7_000_000.0, 25.0

"Write the grid as a GeoTIFF with GDAL, in blocks of rows. The first stored row is the north row."
function write_geotiff(path, A::SynthGrid)
    n = A.n
    rows = max(1, (16 * 2^20) ÷ (4n))
    AG.create(path; driver = AG.getdriver("GTiff"), width = n, height = n, nbands = 1, dtype = Float32,
              options = ["BIGTIFF=IF_NEEDED"]) do ds
        gt = [X0 - CELL / 2, CELL, 0.0, Y0 - CELL / 2 + n * CELL, 0.0, -CELL]
        GC.@preserve gt AG.setgeotransform!(ds, gt)
        AG.setproj!(ds, AG.toWKT(AG.importEPSG(32633)))
        band = AG.getband(ds, 1)
        AG.setnodatavalue!(band, NaN)
        M = Matrix{Float32}(undef, n, rows)
        for r0 in 1:rows:n
            h = min(rows, n - r0 + 1)
            B = h == rows ? M : Matrix{Float32}(undef, n, h)
            for k in 1:h, i in 1:n
                B[i, k] = A[i, n - (r0 + k - 1) + 1]
            end
            AG.write!(band, B, 0, r0 - 1, n, h)
        end
    end
    return path
end

"Write the three input files into `dir`. Returns `(name, path)` pairs."
function write_inputs(dir, n)
    A = SynthGrid(n)
    files = [("Geosoft .grd", joinpath(dir, "plain.grd"), :plain),
             ("Geosoft .grd, zlib", joinpath(dir, "zlib.grd"), :zlib),
             ("GeoTIFF", joinpath(dir, "input.tif"), :tif)]
    for (name, path, kind) in files
        t = @elapsed if kind == :tif
            write_geotiff(path, A)
        else
            write_test_grd(path, A; compress = kind == :zlib, x0 = X0, y0 = Y0, de = CELL, dv = CELL)
        end
        println("wrote ", name, ": ", round(filesize(path) / 1e6; digits = 1), " MB in ", round(t; digits = 1), " s")
    end
    return [(name, path) for (name, path, _) in files]
end

# Resident memory, and the part of it that is not backed by a file.
rss_bytes() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096
function anon_bytes()
    for l in eachline("/proc/self/status")
        startswith(l, "RssAnon:") && return parse(Int, split(l)[2]) * 1024
    end
    return 0
end

mutable struct Sampler
    peak::Int
    peak_anon::Int
    stop::Bool
end

mib(b) = round(b / 2^20; digits = 1)

"""
Run `f()` (which returns a job), wait for it and print its numbers.
Growth is the peak sampled every 50 ms minus the value before the step,
after a garbage collection.
"""
function measure(f, label, bytes)
    GC.gc(); GC.gc()
    base, base_anon, base_max = rss_bytes(), anon_bytes(), Sys.maxrss()
    smp = Sampler(base, base_anon, false)
    t = Threads.@spawn :interactive while !smp.stop
        smp.peak = max(smp.peak, rss_bytes())
        smp.peak_anon = max(smp.peak_anon, anon_bytes())
        sleep(0.05)
    end
    local job
    secs = @elapsed (job = wait_job(f()))
    smp.stop = true; wait(t)
    smp.peak = max(smp.peak, rss_bytes())
    smp.peak_anon = max(smp.peak_anon, anon_bytes())
    status(job) == JuliaMagCore.JOB_DONE || error("$label ended as $(status(job)): $(job.error)")
    println(rpad(label, 34), lpad(round(secs; digits = 2), 7), " s, ", lpad(round(bytes / 1e6 / secs; digits = 0), 5),
            " MB/s, growth ", mib(smp.peak - base), " MiB (not file-backed ", mib(smp.peak_anon - base_anon),
            " MiB, maxrss ", mib(Sys.maxrss() - base_max), " MiB)")
    return job
end

"Import, export and import again a small grid of every kind, so compile time is not in the numbers."
function warm_up(root)
    dir = mkpath(joinpath(root, "warm"))
    s = new_session(joinpath(dir, "p"), "warm")
    for (_, path) in write_inputs(dir, 64)
        id = only(wait_job(import_file(s, path)).outputs)
        for ext in (".grd", ".tif", ".ers")
            wait_job(export_file(s, id, joinpath(dir, "out$ext")))
        end
    end
    rm(dir; recursive = true)
    return nothing
end

function main(args)
    n = 20_000
    keep = false
    dir = ""
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--keep"; keep = true
        elseif a == "--dir"; dir = args[i += 1]
        else n = parse(Int, a)
        end
        i += 1
    end
    root = mktempdir(isempty(dir) ? tempdir() : dir; cleanup = false)
    try
        println("grid of $n by $n Float32 cells (", round(4n^2 / 1e9; digits = 2), " GB of values), ",
                Threads.nthreads(), " threads")
        print("warm-up ... ")
        redirect_stdout(devnull) do
            warm_up(root)
        end
        println("done")
        inputs = write_inputs(root, n)
        s = new_session(joinpath(root, "p"), "bench")
        GC.gc(); GC.gc()
        println("resident memory before the steps: ", mib(rss_bytes()), " MiB")
        values = 4n^2
        # Import each file. The grids hold the same values, so export the first one to every format.
        ids = [only(measure(() -> import_file(s, path), "import $name", values).outputs) for (name, path) in inputs]
        for ext in (".grd", ".ers", ".tif")
            out = joinpath(root, "out$ext")
            measure(() -> export_file(s, ids[1], out), "export to $ext", values)
            rm(out; force = true)
            ext == ".ers" && rm(first(splitext(out)); force = true)
        end
    finally
        keep || rm(root; recursive = true, force = true)
    end
end

main(ARGS)
