# Import benchmark

This page records how fast JuliaMagCore imports big files, and how much memory it needs.
Line data (XYZ and CSV) comes first; grids are in "Grids" below.
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

## Grids

`bench/import_grid.jl` measures a grid of 20,000 by 20,000 `Float32` cells (1.6 GB of values).
It writes the grid three times: as an uncompressed Geosoft `.grd`, as a compressed (zlib) Geosoft `.grd`, and as a plain GeoTIFF (strips, no compression).
It imports each file with `import_file` and exports the first grid to `.grd`, `.ers` and `.tif` with `export_file`.
Each step is a job, timed up to the end of `wait_job`.
The machine and threads are the same as above.

### What is measured

- Speed is the 1.6 GB of values divided by the time of the step, for every format.
  The compressed file is 1.45 GB.
- Memory growth is the peak resident memory, sampled every 50 ms during the step, minus the resident memory just before it, after a garbage collection.
- The script also prints the part of the growth that is not backed by a file (`RssAnon`) and the growth of `Sys.maxrss()`.
  In every run the growth was all `RssAnon`.
- A small grid of every kind is imported and exported first, so compile time is not in the numbers.
- The resident memory before the steps is about 1 GB: Julia, the compiled code, GDAL and PROJ.

### Results

Run of 2026-10-29, after the fixes below (`JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_grid.jl 20000`):

| Step | Time | Speed | Memory growth |
|---|---|---|---|
| Import Geosoft `.grd` | 2.5 s | 647 MB/s | 42 MiB |
| Import Geosoft `.grd`, zlib | 9.3 s | 172 MB/s | 150 MiB |
| Import GeoTIFF | 2.4 s | 662 MB/s | 120 MiB |
| Export to `.grd` | 3.1 s | 512 MB/s | 0 MiB |
| Export to `.ers` | 1.8 s | 888 MB/s | 0 MiB |
| Export to `.tif` | 3.8 s | 419 MB/s | 32 MiB |

Writing the inputs took 6 s for the `.grd`, 50 s for the zlib `.grd` and 5 s for the GeoTIFF.

Memory growth is under 300 MB for every step, and it does not grow with the grid.
At 10,000 by 10,000 cells (400 MB) the growth is 44, 145, 7, 0, 0 and 28 MiB.
The 0 MiB of the exports means the export reused memory that the process already had.
The numbers vary by about 100 MiB from run to run.

### Before the fixes

The first run of the same command gave:

| Step | Time | Speed | Memory growth |
|---|---|---|---|
| Import Geosoft `.grd` | 2.2 s | 715 MB/s | 206 MiB |
| Import Geosoft `.grd`, zlib | 8.7 s | 184 MB/s | 170 MiB |
| Import GeoTIFF | 2.5 s | 650 MB/s | 1184 MiB |
| Export to `.grd` | 2.8 s | 571 MB/s | 367 MiB |
| Export to `.ers` | 1.7 s | 927 MB/s | 1280 MiB |
| Export to `.tif` | 45.5 s | 35 MB/s | 973 MiB |

### Findings

- GDAL keeps the blocks it reads and writes in a cache.
  Its default size is 5 % of the memory, here 1.2 GB.
  A GeoTIFF import, an `.ers` export and a `.tif` export filled it: up to 1.3 GB of growth.
  A profile showed the GDAL cache at 383 MiB during a 400 MB GeoTIFF import.
  The fix: JuliaMagCore sets the cache to 64 MiB when it loads (`GDAL_CACHE_FLOOR`).
  A job that reads or writes a band raises it by two rows of the band's blocks while it runs (`with_gdal_cache`), so a very wide tiled file still fits.
- The Julia side made a new 16 MiB matrix for every block, and the import sink copied each block once more.
  The garbage collector let up to 370 MiB of this pile up before it ran.
  The fix: the readers and `each_row_block` fill the same matrix for every block (`read_rows!`), and the sink writes a block of the grid's type without a copy.
- The GeoTIFF export compressed its tiles on one thread, at 35 MB/s.
  The fix: it now passes `NUM_THREADS=ALL_CPUS` to GDAL, which compresses tiles in parallel.
  The same export takes 3.8 s instead of 45.5 s, and the file holds the same values.
- The zlib import still grows by about 150 MiB.
  Oasis puts few rows in each zlib block (here one row of 80 kB), and each block makes a new zlib stream with its own buffers.
  This garbage stays flat with the grid size, so it was left as it is.

### How to re-run

From the repo root:

```
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_grid.jl 20000
```

- The first argument is the number of cells per side (default 20,000).
- `--dir DIR` says where to put the temporary files; the default is the system temp folder.
  The run needs about 11 GB of free disk at 20,000.
- `--keep` keeps the files.
- The run takes about 3 minutes, most of it writing the zlib input.

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
