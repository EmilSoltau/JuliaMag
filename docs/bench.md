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
It imports each file with `import_file`, and exports the grid of the uncompressed `.grd` to `.grd`, `.ers` and `.tif` with `export_file`.
Each step is a job, timed up to the end of `wait_job`.
The machine and threads are the same as above.

### What is measured

- Each step runs in a new Julia process.
  A process keeps the memory an earlier step freed, so a later step in the same process would reuse it and show almost no growth.
- Before the step, the process imports and exports a 64 by 64 grid of every kind, so compile time is not in the numbers, and then collects its garbage.
- Speed is the 1.6 GB of values divided by the time of the step, for every format.
  The compressed file is 1.45 GB.
- Each memory column is the peak during the step, sampled every 50 ms, minus the value just before the step:
  - RSS: the resident memory of the process.
  - Julia heap: `Base.gc_live_bytes()`, the Julia memory in use plus garbage not yet collected.
  - GDAL cache: the GDAL block cache in use (`GDALGetCacheUsed64`).
  - maxrss: the growth of `Sys.maxrss()`, the high-water mark of RSS since the process started.
    The warm-up already set a mark, so this can be lower than the RSS growth.
- The resident memory before a step is about 1 GB: Julia, the compiled code, GDAL and PROJ.

### Results

Run of 2026-10-29, after the fixes below (`JULIA_NUM_THREADS=4 julia --project=JuliaMagCore bench/import_grid.jl 20000`).
Memory in MiB.

| Step | Time | Speed | RSS | Julia heap | GDAL cache | maxrss |
|---|---|---|---|---|---|---|
| Import Geosoft `.grd` | 2.1 s | 779 MB/s | 35 | 44 | 0 | 31 |
| Import Geosoft `.grd`, zlib | 8.2 s | 195 MB/s | 119 | 148 | 0 | 119 |
| Import GeoTIFF | 2.3 s | 710 MB/s | 102 | 55 | 64 | 14 |
| Export to `.grd` | 3.8 s | 420 MB/s | 15 | 28 | 0 | 15 |
| Export to `.ers` | 1.0 s | 1545 MB/s | 85 | 28 | 64 | 0 |
| Export to `.tif` | 3.6 s | 443 MB/s | 121 | 28 | 64 | 8 |

Writing the inputs took 5 s for the `.grd`, 47 s for the zlib `.grd` and 5 s for the GeoTIFF.

Memory growth is under 300 MB for every step.
It does not grow with the grid: the GDAL cache stops at 64 MiB, and the Julia heap holds one or two blocks of 16 MiB.
A run just before this one gave the same picture, with RSS growth of 40, 97, 86, 17, 79 and 125 MiB.

### Before the fixes

The same script, run on the code as it was before this work (commit `7e20bef`), gave:

| Step | Time | Speed | RSS | Julia heap | GDAL cache | maxrss |
|---|---|---|---|---|---|---|
| Import Geosoft `.grd` | 3.7 s | 439 MB/s | 139 | 129 | 0 | 139 |
| Import Geosoft `.grd`, zlib | 8.9 s | 180 MB/s | 101 | 149 | 0 | 94 |
| Import GeoTIFF | 3.2 s | 497 MB/s | 1254 | 129 | 1201 | 1247 |
| Export to `.grd` | 3.6 s | 448 MB/s | 141 | 129 | 0 | 141 |
| Export to `.ers` | 1.9 s | 848 MB/s | 1290 | 113 | 1201 | 1192 |
| Export to `.tif` | 41.8 s | 38 MB/s | 1279 | 129 | 1201 | 1271 |

### Findings

- GDAL keeps the blocks it reads and writes in a cache.
  Its default size is 5 % of the memory, here 1.2 GB.
  A GeoTIFF import, an `.ers` export and a `.tif` export filled it: about 1.25 GB of growth.
  The fix: JuliaMagCore sets the cache to 64 MiB when it loads (`GDAL_CACHE_FLOOR`).
  A job that reads or writes a band raises it by two rows of the band's blocks while it runs (`with_gdal_cache`), so a wide tiled file still fits.
  The raise stops at 1 GiB or an eighth of the memory, whichever is smaller (`gdal_cache_cap`).
  When the user sets the environment variable `GDAL_CACHEMAX`, JuliaMag leaves the cache alone.
- The Julia side made a new 16 MiB matrix for every block, and the import sink copied each block once more.
  The fix: the readers and `each_row_block` fill the same matrix for every block (`read_rows!`), and the sink writes a block of the grid's type without a copy.
  The Julia heap growth went from about 129 MiB to 28 to 55 MiB.
- The GeoTIFF export compressed its tiles on one thread, at 38 MB/s.
  The fix: it now passes `NUM_THREADS=ALL_CPUS` to GDAL, which compresses tiles in parallel.
  The same export takes 3.6 s instead of 41.8 s, and the file holds the same values.
- The zlib import still has about 150 MiB of Julia heap growth.
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
- The run takes about 4 minutes, most of it writing the zlib input and starting a process per step.
- One step can be run alone on files made with `--keep`:
  `julia --project=JuliaMagCore bench/import_grid.jl --step import-tif 20000 DIR`.
  The steps are `import-grd`, `import-zlib`, `import-tif`, `export-grd`, `export-ers` and `export-tif`.
  The export steps need the project that `import-grd` made in `DIR`.

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

## UI startup

`bench/ui_startup.jl` measures how long the app takes to show its first frame.
It starts a fresh process `julia -t auto,1 --project=JuliaMagUI` three times.
Each process times `using JuliaMagUI` and the end of the first frame that `main()` shows, and then quits.
The first frame ends when it is drawn and its buffer is swapped; the script reads the time when the second frame starts.
The package is precompiled before the runs, so the numbers are for a warm package cache.
Each run uses an empty settings folder, so the theme follows the system.

### Results

Run of 2026-10-30 on the machine above, on WSLg (`DISPLAY=:0`), median of three runs.

| Step | Time |
|---|---|
| Process start until Julia runs the script | 0.12 s |
| `using JuliaMagUI` | 1.90 s |
| `main()` until its first frame is shown | 0.27 s |
| Process start until the first frame | 2.29 s |

The target is under 4 s from process start to the first frame.
The measured 2.29 s meets it.
Most of `using JuliaMagUI` is `JuliaMagCore`: loading the core alone takes about 1.7 s.

### Findings

- Without a precompile workload, the first frame came 1.96 s after `using`, and the total was 3.9 s.
  Almost all of it was compiling the window code on first use.
- `JuliaMagUI` now has a PrecompileTools workload.
  It draws a frame with no window (style, fonts and the empty app) and compiles the window code without running it.
  It needs no display, so it also works on a build machine.
  The first frame is now shown 0.27 s after `using`.
- The first frame is not always this fast.
  In a series of six runs it took 0.25, 0.25, 0.61, 0.95, 0.45 and 0.98 s, and the total stayed under 3 s.
  That series timed the start of the first frame, before its swap, which is about 20 ms earlier.
  The first runs of a series are the fast ones.
  The cause was not found; the WSLg window system, which opens each window, is a likely one.

### How to re-run

From the repo root, on a machine with a display:

```
julia bench/ui_startup.jl
```

- The optional argument is the number of runs (default 3).

### After the icon atlas (Task 6)

Run of 2026-10-30, same machine, median of five runs.

| Step | Time |
|---|---|
| `using JuliaMagUI` | 1.87 s |
| `main()` until its first frame is shown | 0.46 s |
| Process start until the first frame | 2.43 s |

The first frame now builds and uploads the icon atlas, which adds about 0.2 s.
The total stays under the 4 s target.

### With the whole shell (plan 3, Task 16)

Run of 2026-10-31, same machine, median of five runs.

| Step | Time |
|---|---|
| Process start until Julia runs the script | 0.12 s |
| `using JuliaMagUI` | 1.92 s |
| `main()` until its first frame is shown | 0.52 s |
| Process start until the first frame | 2.55 s |

The five totals were 2.49, 2.46, 2.55, 3.03 and 3.03 s.
The first frame took 0.45 to 0.93 s; as before, the last runs of the series were the slow ones.
The total stays under the 4 s target.

## UI frame time with a big database

`bench/ui_frame.jl` measures how long a frame takes with a database of 5,000 lines and 300 channels, with its Lines and Channels folders open in the Data tree.
It runs the app with the window test harness (`with_project_app`), with the bundled fonts.
Each case draws 200 frames, first with the tree still, then scrolled to a new place in every frame.
"Draw" is `draw_app` alone, on the CPU.
"Wall" is the time from frame to frame, with the test engine, the GPU and the buffer swap.

### Results

Run of 2026-10-31 on the machine above, on WSLg.

| Case | Draw, median | Draw, 95th percentile | Wall per frame | Tree rows drawn |
|---|---|---|---|---|
| Scale 1, still | 0.24 ms | 0.29 ms | 10.0 ms | 25 |
| Scale 1, scrolling | 0.25 ms | 0.28 ms | 10.1 ms | 26 |
| Scale 1.5, still | 0.27 ms | 0.32 ms | 12.0 ms | 25 |
| Scale 1.5, scrolling | 0.27 ms | 0.32 ms | 12.3 ms | 26 |

The tree draws only the rows in view, so the draw time does not depend on the number of lines.
The window test `5,000 lines: only the rows in view are drawn` in `JuliaMagUI/test/window/test_data.jl` checks that the median draw stays under 16 ms.
A second run with `bench/ui_frame.jl` gave the same numbers within 0.1 ms of draw time.

### How to re-run

From the repo root, on a machine with a display:

```
julia --project=JuliaMagUI/tools -e 'using Pkg; Pkg.instantiate()'
julia -t auto,1 --project=JuliaMagUI bench/ui_frame.jl
```

- The first command is needed once: the script uses the window test harness, which needs ImGuiTestEngine.
- The optional argument is the number of frames per case (default 200).

## UI idle CPU

`bench/ui_idle.jl` measures how much CPU the app uses when nobody touches it.
It starts the app with no project, waits 5 s for the start to pass, then reads the process's CPU time over 20 s with no input.
While idle, the loop still draws a frame every 0.1 s at the latest: `refresh!` polls the project's revision, and the sticky toasts and the theme need a frame now and then.

### Results

Run of 2026-10-31 on the machine above, on WSLg, two runs.

| Run | CPU while idle | Frames per second |
|---|---|---|
| 1 | 2.6 % of one core | 9.2 |
| 2 | 2.5 % of one core | 9.2 |

The idle cost is small, but not zero.
A later plan can let the core wake the loop when its revision goes up, so the idle wait can be longer.

### How to re-run

From the repo root, on Linux with a display:

```
julia bench/ui_idle.jl [SECONDS]
```

- `SECONDS` is the idle time measured (default 20).
- The script reads `/proc/self/stat`, so it runs on Linux only.

## Icon atlas

`bench/ui_icons.jl` times how long the icon atlas takes to build.
The atlas holds 119 icons drawn with Rsvg and Cairo.
The normal style has 8 sizes; the disabled, nav and on-accent styles have only the sizes the UI uses (3, 2 and 2).
The window builds it at the start and again when the theme or the scale changes.
The target is under 300 ms at scale 2.

### Results

Run of 2026-10-30 on the machine above, on WSLg (`DISPLAY=:0`), five runs after a warm-up.

| Case | Best | Median | Atlas size |
|---|---|---|---|
| Build, scale 1 | 60 ms | 61 ms | 4096 x 325 |
| Build, scale 1.5 | 70 ms | 97 ms | 4096 x 724 |
| Build, scale 2 | 112 ms | 114 ms | 4096 x 1237 |
| Build and upload in a window, scale 2 | 109 ms | 114 ms | 4096 x 1237 |
| Build, scale 4 | 191 ms | - | 4096 x 4777 |

The rebuild at scale 2 takes 114 ms, under the 300 ms target.
At scale 4 the atlas is 4777 px high, well under the 8192 px texture limit of older cards.
The window does not draw while the atlas builds, so a theme or scale change shows one slow frame.
Almost all of the time is Rsvg drawing 1,785 small images.
A first version drew every style at every size: 3,808 images, 231 ms and 2394 px high at scale 2.

### How to re-run

From the repo root:

```
julia -t auto,1 --project=JuliaMagUI bench/ui_icons.jl
```

- The optional argument is the number of runs (default 5).
- The window part needs a display; without one, only the build is timed.

## Map view

`bench/map_frame.jl` measures the map view with a survey-sized project.
It writes a temp project with a survey database of 2000 lines of 10,000 points (20 M points, 10 m apart, lines 50 m apart, a MAG channel) and an 8000 by 8000 Float32 grid with a NaN edge, as the spike's `gen.jl` did.
It shows them on three maps (grid and lines, lines only, grid only) in a map view of 1584 by 955 device pixels.
It uses the app's own code paths: the loader, the uploads, the scene, the GL pass, the adaptive path and the CPU renderer.

- "Load" runs from showing the map until the first full picture with both layers: read and build on the loader, then the uploads, one per frame.
- "Full frames" move the camera by one pixel each frame, so each of the 120 frames draws a full picture.
- "Frame" is the time from one app frame to the next, with ImGui, the test engine and the buffer swap.
- "GPU" is the map pass's `GL_TIME_ELAPSED` query.
- "Pan" drags the map with the mouse, 120 moves of (6, 3) px; the frames while it moves.
- "CPU renderer" is Map Drawing: CPU. "Draw" is `render_cpu!` on the worker threads; "shown" runs from the camera change until the picture shows.

### Machine

The machine of the import benchmark above: Intel Core i9-13900, 32 logical CPUs, Linux 6.18 on WSL2, Julia 1.12.7, `-t auto,1` (32 worker threads and 1 interactive).
Both runs are on a virtual display (Xvfb, 1920 by 1080):

- Intel GPU: `GL_RENDERER` "D3D12 (Intel(R) UHD Graphics 770)", Mesa's D3D12 driver on WSL2.
- llvmpipe: `GL_RENDERER` "llvmpipe (LLVM 15.0.7, 256 bits)", with `LIBGL_ALWAYS_SOFTWARE=1`.

`GL_MAX_TEXTURE_SIZE` is 16384 on both.

### Results

Run of 2026-11-04, the second of two runs on each renderer. Times in ms unless marked.
A slow renderer redraws at most every 0.25 s while uploads wait (`PENDING_REDRAW`), and once when they are done.

| Case | Intel GPU, median | Intel GPU, p95 | llvmpipe, median | llvmpipe, p95 |
|---|---|---|---|---|
| Load: read and build the grid | 0.84 s | | 0.76 s | |
| Load: read and build the lines | 0.92 s | | 1.21 s | |
| Load: all layers in | 1.78 s | | 1.98 s | |
| Load: first full picture (40 uploads) | 2.50 s | | 2.82 s | |
| Whole survey, frame | 11.9 | 12.3 | 58.5 | 66.2 |
| Whole survey, GPU | 2.9 | 3.0 | 49.9 | 55.5 |
| Zoom 10x, frame | 9.3 | 9.7 | 14.9 | 19.8 |
| Zoom 10x, GPU | 0.6 | 0.6 | 9.1 | 9.4 |
| Zoom 100x, frame | 9.6 | 14.6 | 43.0 | 47.6 |
| Zoom 100x, GPU | 1.2 | 1.2 | 37.0 | 39.4 |
| Grid only, frame | 9.0 | 9.5 | 9.4 | 15.1 |
| Grid only, GPU | 0.7 | 0.7 | 2.7 | 2.8 |
| Grid and lines, frame | 13.9 | 19.1 | 59.3 | 66.3 |
| Grid and lines, GPU | 4.0 | 4.0 | 51.0 | 55.6 |
| Pan, grid and lines, frame | 11.4 | 14.3 | 9.9 | 10.6 |
| CPU renderer, whole survey, draw | 49.7 | 50.4 | 67.5 | 72.7 |
| CPU renderer, whole survey, shown | 68.0 | 69.2 | 84.1 | 93.8 |
| CPU renderer, grid, draw | 10.8 | 13.5 | 8.7 | 10.2 |
| CPU renderer, grid, shown | 28.0 | 29.8 | 21.3 | 30.7 |

On the Intel GPU every pan frame drew a full picture (120 of 120).
On llvmpipe none did: a full picture costs more than a frame, so the last picture moved, and the full one came when the pan settled.
The CPU renderer draws without OpenGL, but its whole survey draw is about 35 % slower in the llvmpipe run (67.5 ms against 49.7 ms).
Most likely llvmpipe's own threads compete with the CPU renderer's threads for the cores.

The first run on each renderer gave the first full picture in 2.40 s (Intel GPU) and 2.45 s (llvmpipe).
Its other numbers were within about 15 % of these, with a few p95 spikes on the Intel GPU (zoom 10x 18.6 ms, grid only 15.9 ms, grid and lines 21.3 ms) from the app frame, not the map pass.
Before the redraw limit, the first full picture on llvmpipe took 3.97 s and 4.15 s, because the map drew a 45 ms picture after each of the 40 uploads.

### Targets

| Target | Number | Met |
|---|---|---|
| First full picture of the 20 M points and the grid under 3 s | 2.50 s and 2.40 s on the Intel GPU; 2.82 s and 2.45 s on llvmpipe | Yes |
| Whole survey full frame on the Intel GPU under 16 ms | 11.9 ms median, 12.3 ms p95; GPU 2.9 ms | Yes |
| Pan frames p95 under 33 ms on llvmpipe, through the adaptive path | 10.6 ms | Yes |
| Grid only full frame on llvmpipe under 16 ms | 9.4 ms median, 15.1 ms p95 | Yes |

### Findings

- On llvmpipe a whole-survey picture costs about 50 ms.
  While the 40 uploads run, the map redraws at most every 0.25 s, so the uploads get the frames and the first full picture comes in under 3 s.
- Zoom 100x costs more than zoom 10x: 37 ms against 9 ms on llvmpipe, and 1.2 ms against 0.6 ms on the GPU.
  Culling is by the box of a whole line part, and these lines are 100 km long.
  At 100x, about 28 lines of 10,000 points pass the cull and draw at the finest level, almost all of them outside the view.
  At 10x, the point budget picks a coarser level.
  Cutting long parts into pieces with their own boxes would fix it; it is not needed for the targets.
- The frame time on the Intel GPU is mostly the app frame itself (about 8 to 9 ms with an empty map here, with the test engine and Xvfb); the map pass adds 1 to 4 ms of GPU time.
- The spike measured 15.6 ms of GPU time for all points of the whole survey; the point budget levels bring it to 2.9 ms.

### GL and CPU parity on the Intel GPU

The parity window test (`JuliaMagUI/test/window/test_map_gl.jl`) ran once on the Intel GPU (D3D12) as well as on llvmpipe.
It compares the GL pass with the CPU renderer pixel by pixel; the bounds are a mean error under 1.5 (0-255 units) and no outliers.
All 97 tests passed on both.

| Case | Intel GPU, mean error | llvmpipe, mean error | Outliers (both) |
|---|---|---|---|
| bilinear-shade | 0.110 | 0.114 | 0 |
| nearest | 0.112 | 0.115 | 0 |
| level-2 | 0.112 | 0.089 | 0 |
| bilinear-shade-3px | 0.002 | 0.024 | 0 |
| bilinear-shade-24px | 0.00001 | 0.033 | 0 |
| nearest-shade-24px | 0.0 | 0.034 | 0 |
| rotated | 0.003 | 0.014 | 0 |

The tile seam test (11 levels at 3 and 24 px per cell) found no pixel off at the tile edges on the Intel GPU.
On llvmpipe, one case had 2 pixels off by 2 there (the bound is 5 pixels).
Away from the edges, a lone pixel may take the next colour entry: 3 of 22 cases had 1 such pixel on the Intel GPU; on llvmpipe 3 cases had 1, 3 and 5.

### How to re-run

From the repo root, on a virtual display:

```
julia --project=JuliaMagUI/tools -e 'using Pkg; Pkg.instantiate()'
xvfb-run -a -s "-screen 0 1920x1080x24" env -u WAYLAND_DISPLAY julia -t auto,1 --project=JuliaMagUI bench/map_frame.jl
xvfb-run -a -s "-screen 0 1920x1080x24" env -u WAYLAND_DISPLAY julia -t auto,1 --project=JuliaMagUI bench/map_frame.jl --software
```

- The first command is needed once: the script uses the window test harness, which needs ImGuiTestEngine.
- Without `--software`, check the printed `GL_RENDERER`: on WSL2 it is the D3D12 driver when the GPU is used.
- The temp project takes about 650 MB on disk and is deleted at the end.
- One run takes under a minute.
