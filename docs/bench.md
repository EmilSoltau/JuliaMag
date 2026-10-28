# Import benchmark

This page records how fast JuliaMagCore imports big files, and how much memory it needs.
These numbers are a guard: a slow import or a crash on a large file would show here.

## Machine

- CPU: 13th Gen Intel Core i9-13900 (32 logical CPUs).
- RAM: 23 GB (WSL2), swap 8 GB.
- OS: Linux 6.18 on WSL2.
- Files were on the Linux disk.
- Julia: 1.12.7.
- Threads: `JULIA_NUM_THREADS=4`.

## What is measured

- The file has 12 channels and about 100 bytes per row.
- Every 97th value is `*` (missing).
- The import is `import_file` plus `wait_job`, in a session that is already warm.
- Memory growth is the peak resident memory sampled every 50 ms during the import, minus the resident memory after the file was written and after a garbage collection.
- The CSV file has the same rows, with a heading row and a LINE column.

## Results

| Case | File size | Lines | Rows | Import time | Speed | Memory growth |
|---|---|---|---|---|---|---|
| XYZ | 50 MB | 6 | 0.44 M | 0.34 s | 147 MB/s | 64 MiB |
| XYZ | 500 MB | 62 | 4.4 M | 3.4 s | 147 MB/s | 117 MiB |
| XYZ | 2 GB | 250 | 17.5 M | 13.4 s | 149 MB/s | 131 MiB |
| XYZ, long lines | 500 MB | 60 | 4.4 M | 3.5 s | 143 MB/s | 108 MiB |
| XYZ, many lines | 500 MB | 5,000 | 4.5 M | 3.7 s | 135 MB/s | 93 MiB |
| XYZ, very many lines | 500 MB | 50,000 | 4.5 M | 5.5 s | 91 MB/s | 130 MiB |
| CSV | 500 MB | 62 | 4.2 M | 3.6 s | 140 MB/s | 144 MiB |
| CSV | 2 GB | 250 | 16.6 M | 15.0 s | 133 MB/s | 137 MiB |

Memory growth does not grow with the file size.
It is 117 MiB at 500 MB and 131 MiB at 2 GB.

## Opening again and reading

Measured after the 500 MB XYZ import, in a fresh `open_session`.

| Step | Time |
|---|---|
| `open_session` | 0.26 ms |
| Open the database (62 lines) | 0.19 ms |
| First `read_channel` of one line (70,000 rows) | 0.04 ms |
| Second `read_channel` of the same line | under 0.01 ms |

With 50,000 lines the database opens in 45 ms and the first read takes 6 ms.
Reading is a view into a memory-mapped file, so it does not depend on the file size.
This backs the "near instant" claim in spec 6.2.

## Target

- Import speed: at least 100 MB/s for XYZ and CSV, at any size, with files of up to a few thousand lines.
- Memory growth during import: under 300 MB at any size.
- 500 MB must import in under 10 s (the spec 14 guess of 60 s was far too loose).
- Open a project and read one channel of one line: under 100 ms.

The measured numbers meet all of this.
The very-many-lines case (50,000 lines) is below 100 MB/s on purpose: it is not a real survey shape.
It still finishes in 5.5 s.

## Findings

- The first run of 50,000 lines took 98 s (5 MB/s).
  The cost grew with the number of lines.
  Two causes were found: a miss in the line index rebuilt the whole index for every new line, and `total_rows` summed all lines twice per line.
  Both were fixed in the package (`line_is_new`, and `total_rows` reads the end of the last line).
  The same case now takes 5.5 s.
- The scan itself allocates nothing per value, so no change was needed there.
- In `end_line!`, the cost is probably 12 file flushes per line, about 90 microseconds per line.
  This is an estimate, not a measurement.
  The channels that have no appender are cut and released per line.
  An XYZ import has an appender for every channel, so that path was not hit here.
  It was not measured.
- On Windows, `release_map!` runs `GC.gc()`.
  This was not measured here, because the machine is Linux.

## Limits

- The benchmark runs on Linux only.
- The memory figure is sampled every 50 ms.
  It is approximate and can miss short peaks.

## How to re-run

From the repo root:

```
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_xyz.jl 500
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_xyz.jl 2000
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_xyz.jl 500 --lines 5000
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_xyz.jl 500 --csv
```

- The first argument is the size in MB.
- `--lines N` sets the number of lines.
  The default is about one line per 8 MB.
- `--csv` writes and imports a CSV instead of an XYZ.
- `--dir DIR` says where to put the temporary files.
  The default is the system temp folder.
- `--keep` keeps the files.
- The script writes the file, imports it, prints the numbers and deletes the files.
- The file writer is in the script.
  It makes 500 MB in under a second.
