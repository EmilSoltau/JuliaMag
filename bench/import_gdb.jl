# Geosoft database (.gdb) import benchmark (docs/bench.md).
#
# Usage:
#   JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_gdb.jl [N_LINES] [--dir DIR] [--keep]
#   JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_gdb.jl --step LABEL PATH ROOT
#
# The first form writes a synthetic zlib .gdb with the test writer: N_LINES lines
# (default 400) of 30,000 rows and 10 Float64 channels, so 2.4 MB of values per
# line and 960 MB at 400 lines. The values are random walks, so zlib keeps most of
# that size. Then it imports the file in a new Julia process (the second form)
# with `import_file` and `wait_job`. With JULIAMAG_GDB_SAMPLES set, it also
# imports fortymile_linedata.gdb (LZRW1, 173 MB) in a process of its own.
#
# An import runs alone in its process, after a small warm-up, because
# `Sys.maxrss()` is a peak for the whole process: the writer's memory would hide
# the import's. Each import prints the time, the speed and its memory numbers.
# The files go in a temporary folder that is removed at the end.

using JuliaMagCore
using Random

# `write_test_gdb` and the types it needs.
include(joinpath(@__DIR__, "..", "JuliaMagCore", "test", "support", "gdb_writer.jl"))

const ROWS, CHANNELS = 30_000, 10

"A random walk for line `l` and channel `c`, the same on every run."
walk(l, c, rows) = cumsum(randn(Xoshiro(1000l + c), rows)) .+ 50_000.0

"Write a zlib .gdb of `n` lines of `rows` rows and `CHANNELS` Float64 channels to `path`."
function write_bench_gdb(path, n; rows = ROWS)
    chans = [TestChannel(name = "C$k") for k in 1:CHANNELS]
    lines = [TestLine(name = "L$(10 * k)", number = 10 * k) for k in 1:n]
    write_test_gdb(path; channels = chans, lines = lines, chans_max = CHANNELS, lines_max = n,
                   blob = (l, c) -> TestBlob(values = walk(l, c, rows), pack = :zlib))
    return path
end

# Resident memory, read from the kernel.
rss_bytes() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096

mutable struct Sampler
    rss::Int
    live::Int
    stop::Bool
end

sample!(smp::Sampler) = (smp.rss = max(smp.rss, rss_bytes()); smp.live = max(smp.live, Int(Base.gc_live_bytes())))

mib(b) = round(b / 2^20; digits = 1)

"The bytes of values in `db`: rows times the value size of every numeric channel."
value_bytes(db) = db.rows_written * sum((c.eltype === String ? 0 : sizeof(c.eltype) * c.arraylen for c in db.channels); init = 0)

"""
Import `path` in this process and print its numbers. The growth numbers are the
peaks during the import minus the values just before it, after a warm-up import
of a small file and a garbage collection.
"""
function run_step(label, path, root)
    redirect_stdout(devnull) do
        warm = mktempdir(root)
        s = new_session(joinpath(warm, "p"), "warm")
        wait_job(import_file(s, write_bench_gdb(joinpath(warm, "warm.gdb"), 2; rows = 100)))
        close_session!(s)
    end
    s = new_session(joinpath(mktempdir(root), "p"), "bench")
    GC.gc(); GC.gc()
    base, live, top = rss_bytes(), Int(Base.gc_live_bytes()), Sys.maxrss()
    smp = Sampler(base, live, false)
    t = Threads.@spawn :interactive while !smp.stop
        sample!(smp)
        sleep(0.05)
    end
    local job
    secs = @elapsed (job = wait_job(import_file(s, path)))
    smp.stop = true; wait(t)
    sample!(smp)
    status(job) == JuliaMagCore.JOB_DONE || error("$label ended as $(status(job)): $(job.error)")
    db = database(s.project, only(job.outputs))
    mb = value_bytes(db) / 1e6
    println(rpad(label, 24), lpad(round(secs; digits = 2), 6), " s ", lpad(round(Int, mb), 5), " MB of values ",
            lpad(round(Int, mb / secs), 5), " MB/s | file ", lpad(round(Int, filesize(path) / 1e6), 5),
            " MB | RSS ", lpad(mib(smp.rss - base), 6), " | heap ", lpad(mib(smp.live - live), 6),
            " | maxrss ", lpad(mib(Sys.maxrss() - top), 6), " | base ", round(Int, base / 2^20), " MiB")
    close_session!(s)
    return nothing
end

function main(args)
    if !isempty(args) && args[1] == "--step"
        return run_step(args[2], args[3], args[4])
    end
    n, keep, dir = 400, false, ""
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
        path = joinpath(root, "bench.gdb")
        secs = @elapsed write_bench_gdb(path, n)
        println("synthetic .gdb: $n lines, $ROWS rows, $CHANNELS Float64 channels (",
                round(n * ROWS * CHANNELS * 8 / 1e6; digits = 1), " MB of values), zlib file ",
                round(filesize(path) / 1e6; digits = 1), " MB, written in ", round(secs; digits = 1), " s; ",
                Threads.nthreads(), " threads")
        println("Each import runs in a new process. Growth during the import, in MiB:")
        println("RSS = resident memory; heap = Julia heap (live and not yet collected); maxrss = high-water mark of RSS.")
        julia = `$(Base.julia_cmd()) --project=$(dirname(Base.active_project()))`
        steps = ["synthetic, $n lines" => path]
        samples = get(ENV, "JULIAMAG_GDB_SAMPLES", "")
        forty = joinpath(samples, "dggs-gpr2015-004-fortymile", "fortymile_linedata.gdb")
        !isempty(samples) && isfile(forty) && push!(steps, "fortymile (LZRW1)" => forty)
        for (label, p) in steps
            flush(stdout)                  # keep the order of this output and the step's
            run(`$julia $(@__FILE__) --step $label $p $root`)
        end
    finally
        keep || rm(root; recursive = true, force = true)
    end
end

main(ARGS)
