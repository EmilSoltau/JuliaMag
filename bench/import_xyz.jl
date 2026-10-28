# Import benchmark (docs/bench.md).
#
# Usage:
#   JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_xyz.jl SIZE_MB [--lines N] [--csv] [--dir DIR] [--keep]
#
# It writes a synthetic file of about SIZE_MB megabytes (12 channels), imports it
# with `import_file` and `wait_job`, and prints speed and memory growth.
# With `--csv` it writes and imports a CSV of the same shape instead of an XYZ.
# It then opens the project again and reads one channel of one line.

using JuliaMagCore

const CHANNELS = ["X", "Y", "FIDUCIAL", "MAG", "ALT", "RAD1", "RAD2", "RAD3", "RAD4", "RAD5", "GPSH", "BARO"]

# Small random number source (xorshift64).
mutable struct Rng
    x::UInt64
end
@inline function nextu!(r::Rng)
    x = r.x
    x ⊻= x << 13; x ⊻= x >> 7; x ⊻= x << 17
    r.x = x
    return x
end

# A pool of value texts, so writing needs no number formatting. Every 97th is "*".
function value_pool(rng::Rng, n::Int)
    pool = Vector{Vector{UInt8}}(undef, n)
    for i in 1:n
        v = round(50000.0 + 100.0 * ((nextu!(rng) >> 11) * 2.0^-53); digits = 3)
        pool[i] = Vector{UInt8}(string(v))
    end
    return pool
end

# Output buffer with fast byte and integer writes.
mutable struct Out
    io::IOStream
    buf::Vector{UInt8}
    n::Int
    total::Int
end

@inline function room!(o::Out, k::Int)
    if o.n + k > length(o.buf)
        write(o.io, view(o.buf, 1:o.n)); o.total += o.n; o.n = 0
    end
end

@inline function putbytes!(o::Out, v::AbstractVector{UInt8})
    room!(o, length(v))
    @inbounds for i in eachindex(v)
        o.buf[o.n + i] = v[i]
    end
    o.n += length(v)
end

@inline function putbyte!(o::Out, b::UInt8)
    room!(o, 1)
    @inbounds o.buf[o.n += 1] = b
end

# Write the integer `x >= 0` followed by ".0", like Julia prints a whole Float64.
@inline function putwhole!(o::Out, x::Int)
    room!(o, 24)
    d = ndigits(x)
    y = x
    @inbounds for k in d:-1:1
        o.buf[o.n + k] = UInt8('0') + UInt8(y % 10)
        y ÷= 10
    end
    o.n += d
    putbyte!(o, UInt8('.')); putbyte!(o, UInt8('0'))
end

total_bytes(o::Out) = o.total + o.n

"""
Write a synthetic file of about `mb` megabytes in `lines` line blocks. For XYZ the
file has a `/` header and `Line n` records; for CSV it has a heading row and a LINE
column. Returns `(rows, lines, bytes)`.
"""
function write_fast(path::String, mb::Real, lines::Int, csv::Bool)
    sep = csv ? UInt8(',') : UInt8(' ')
    rng = Rng(0x2545f4914f6cdd1d)
    pool = value_pool(rng, 4096)
    star = UInt8[UInt8('*')]
    target = round(Int, mb * 1e6)
    per_line = target ÷ lines
    rows = 0
    open(path, "w") do io
        o = Out(io, Vector{UInt8}(undef, 1 << 20), 0, 0)
        if csv
            putbytes!(o, Vector{UInt8}("LINE," * join(CHANNELS, ",") * "\n"))
        else
            putbytes!(o, Vector{UInt8}("/ synthetic benchmark data\n/ " * join(CHANNELS, " ") * "\n//Flight 7\n//Date 2024/05/01\n"))
        end
        for b in 1:lines
            csv || putbytes!(o, Vector{UInt8}("Line $(1000 + b)\n"))
            lab = Vector{UInt8}("L$(1000 + b),")
            ytext = Vector{UInt8}(string(7.0e6 + 100.0 * b))
            line_start = total_bytes(o)
            row = 0
            while total_bytes(o) - line_start < per_line
                row += 1
                csv && putbytes!(o, lab)
                putwhole!(o, 500000 + 10 * row)
                putbyte!(o, sep); putbytes!(o, ytext)
                putbyte!(o, sep); putwhole!(o, row - 1)
                for k in 4:length(CHANNELS)
                    putbyte!(o, sep)
                    r = nextu!(rng)
                    putbytes!(o, (r >> 40) % 97 == 0 ? star : pool[(r >> 20) % 4096 + 1])
                end
                putbyte!(o, UInt8('\n'))
            end
            rows += row
        end
        write(io, view(o.buf, 1:o.n))
    end
    return (rows = rows, lines = lines, bytes = filesize(path))
end

rss_bytes() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096

mutable struct Sampler
    peak::Int
    stop::Bool
end

# Run a small import first, so compile time is not in the numbers.
function warm_up(root::String, csv::Bool)
    f = joinpath(root, csv ? "warm.csv" : "warm.xyz")
    write_fast(f, 1, 2, csv)
    s = new_session(joinpath(root, "warm"), "warm")
    wait_job(import_file(s, f))
    s2 = open_session(s.project.folder)
    db = database(s2.project, s2.project.items[end].id)
    sum(read_channel(db, first(db.lines).id, "MAG"))
    return nothing
end

function main(args)
    mb = 500.0
    lines = 0
    csv = false
    keep = false
    dir = ""
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--lines"; lines = parse(Int, args[i += 1])
        elseif a == "--csv"; csv = true
        elseif a == "--keep"; keep = true
        elseif a == "--dir"; dir = args[i += 1]
        else mb = parse(Float64, a)
        end
        i += 1
    end
    lines == 0 && (lines = max(1, round(Int, mb / 8)))   # about 8 MB per line
    root = mktempdir(isempty(dir) ? tempdir() : dir; cleanup = false)
    try
        warm_up(root, csv)
        file = joinpath(root, csv ? "bench.csv" : "bench.xyz")
        tw = @elapsed info = write_fast(file, mb, lines, csv)
        println("wrote ", round(info.bytes / 1e6; digits = 1), " MB, ", info.rows, " rows, ", info.lines,
                " lines, in ", round(tw; digits = 1), " s (", Threads.nthreads(), " threads)")
        s = new_session(joinpath(root, "p"), "bench")
        GC.gc(); GC.gc()
        base = rss_bytes()
        smp = Sampler(base, false)
        t = Threads.@spawn :interactive while !smp.stop
            smp.peak = max(smp.peak, rss_bytes())
            sleep(0.05)
        end
        secs = @elapsed begin
            job = import_file(s, file)
            wait_job(job)
        end
        smp.stop = true; wait(t)
        smp.peak = max(smp.peak, rss_bytes())
        st = status(job)
        st == JuliaMagCore.JOB_DONE || error("import ended as $st: $(job.error)")
        mbytes = info.bytes / 1e6
        println("import:  ", round(secs; digits = 2), " s, ", round(mbytes / secs; digits = 1), " MB/s, ",
                round(info.rows / secs / 1e6; digits = 2), " M rows/s")
        println("memory growth during import: ", round((smp.peak - base) / 2^20; digits = 1), " MiB",
                " (baseline ", round(base / 2^20; digits = 0), " MiB, peak ", round(smp.peak / 2^20; digits = 0), " MiB)")
        # Open the project again and read one channel of one line.
        item_id = s.project.items[end].id
        tr = @elapsed (s2 = open_session(s.project.folder))
        td = @elapsed (db = database(s2.project, item_id))
        l1 = first(db.lines).id
        tc1 = @elapsed (v = read_channel(db, l1, "MAG"))
        tc2 = @elapsed (v = read_channel(db, l1, "MAG"))
        ts = @elapsed (x = sum(v))
        println("open_session: ", round(tr * 1000; digits = 2), " ms; open database ", round(td * 1000; digits = 2), " ms; read_channel first call ",
                round(tc1 * 1000; digits = 3), " ms, second ", round(tc2 * 1000; digits = 3), " ms (",
                length(v), " rows); sum of it ", round(ts * 1000; digits = 3), " ms")
    finally
        keep || rm(root; recursive = true, force = true)
    end
end

main(ARGS)
