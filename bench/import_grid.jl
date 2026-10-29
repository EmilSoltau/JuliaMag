# Grid import and export benchmark (docs/bench.md).
#
# Usage:
#   JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_grid.jl [N] [--dir DIR] [--keep]
#   JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_grid.jl --step STEP N DIR
#
# The first form writes a synthetic Float32 grid of N by N cells (default 20,000:
# 1.6 GB) three times: as an uncompressed Geosoft .grd, as a compressed Geosoft
# .grd and as a GeoTIFF. Then it runs each step in a new Julia process (the second
# form): it imports each file with `import_file`, and exports the grid of the
# uncompressed .grd to every format with `export_file`, both with `wait_job`.
#
# A step runs alone in its process, after a small warm-up, so its memory numbers
# are not hidden by memory an earlier step freed but the process kept. Each step
# prints the time, the speed and its memory numbers. The files go in a temporary
# folder that is removed at the end.

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

# Resident memory, read from the kernel.
rss_bytes() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096

mutable struct Sampler
    rss::Int
    live::Int
    gdal::Int
    stop::Bool
end

sample!(smp::Sampler) = (smp.rss = max(smp.rss, rss_bytes());
                         smp.live = max(smp.live, Int(Base.gc_live_bytes()));
                         smp.gdal = max(smp.gdal, Int(AG.GDAL.gdalgetcacheused64())))

mib(b) = round(b / 2^20; digits = 1)

"Import and export a small grid of every kind, so compile time is not in the numbers."
function warm_up(dir)
    s = new_session(joinpath(dir, "p"), "warm")
    for (_, path) in write_inputs(dir, 64)
        id = only(wait_job(import_file(s, path)).outputs)
        for ext in (".grd", ".tif", ".ers")
            wait_job(export_file(s, id, joinpath(dir, "out$ext")))
        end
    end
    return nothing
end

const STEPS = ["import-grd" => "import Geosoft .grd", "import-zlib" => "import Geosoft .grd, zlib",
               "import-tif" => "import GeoTIFF", "export-grd" => "export to .grd",
               "export-ers" => "export to .ers", "export-tif" => "export to .tif"]
const INPUTS = Dict("import-grd" => "plain.grd", "import-zlib" => "zlib.grd", "import-tif" => "input.tif")

"""
Run one step on the files in `root`, in this process, and print its numbers.
Each import makes its own project `p-<step>`; the exports use the grid of `p-import-grd`.
The growth numbers are the peaks during the step minus the values just before
it, after the warm-up and a garbage collection.
"""
function run_step(step, n, root)
    label = Dict(STEPS)[step]
    redirect_stdout(devnull) do
        warm_up(mktempdir(root))
    end
    if startswith(step, "import")
        s = new_session(joinpath(root, "p-$step"), "bench")
        go = () -> import_file(s, joinpath(root, INPUTS[step]))
        out = ""
    else
        s = open_session(joinpath(root, "p-import-grd"))
        out = joinpath(root, "out." * split(step, "-")[2])
        go = () -> export_file(s, s.project.items[end].id, out)
    end
    GC.gc(); GC.gc()
    base, live, gdal, top = rss_bytes(), Int(Base.gc_live_bytes()), Int(AG.GDAL.gdalgetcacheused64()), Sys.maxrss()
    smp = Sampler(base, live, gdal, false)
    t = Threads.@spawn :interactive while !smp.stop
        sample!(smp)
        sleep(0.05)
    end
    local job
    secs = @elapsed (job = wait_job(go()))
    smp.stop = true; wait(t)
    sample!(smp)
    status(job) == JuliaMagCore.JOB_DONE || error("$label ended as $(status(job)): $(job.error)")
    isempty(out) || (rm(out; force = true); rm(first(splitext(out)); force = true))
    println(rpad(label, 27), lpad(round(secs; digits = 2), 6), " s ", lpad(round(Int, 4n^2 / 1e6 / secs), 5),
            " MB/s | RSS ", lpad(mib(smp.rss - base), 6), " | heap ", lpad(mib(smp.live - live), 6),
            " | GDAL ", lpad(mib(smp.gdal - gdal), 5), " | maxrss ", lpad(mib(Sys.maxrss() - top), 6),
            " | base ", round(Int, base / 2^20), " MiB")
    return nothing
end

function main(args)
    if !isempty(args) && args[1] == "--step"
        return run_step(args[2], parse(Int, args[3]), args[4])
    end
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
        write_inputs(root, n)
        println("Each step runs in a new process. Growth during the step, in MiB:")
        println("RSS = resident memory; heap = Julia heap (live and not yet collected); ",
                "GDAL = GDAL block cache in use; maxrss = high-water mark of RSS.")
        julia = `$(Base.julia_cmd()) --project=$(dirname(Base.active_project()))`
        for (step, _) in STEPS
            flush(stdout)                  # keep the order of this output and the step's
            run(`$julia $(@__FILE__) --step $step $n $root`)
        end
    finally
        keep || rm(root; recursive = true, force = true)
    end
end

main(ARGS)
