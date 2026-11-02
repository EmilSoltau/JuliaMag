# JuliaMag

JuliaMag is a tool for processing airborne magnetic data.
The processing lives in `JuliaMagCore`, a headless Julia package.
The desktop app is `JuliaMagUI`, a window on top of the core (see `JuliaMagUI/README.md`).

## Run the app

Install Julia 1.12 first.
Then start the app from the repository root:

```
bin/juliamag.sh [project folder]
bin\juliamag.cmd [project folder]
```

The first is for Linux, the second for Windows.
The optional argument is a project folder to open.
The first start installs and precompiles the packages and takes a few minutes.
Later starts check that the packages are there, which takes a few milliseconds.
Until the app is packaged, this is how to start it.

## Run the tests

Run this from the repository root:

```
julia --project=JuliaMagCore -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia -t auto,1 --project=JuliaMagUI -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The first runs the core tests, the second the app tests.
The app's window tests need a display; without one they are skipped.

## Try it

`examples/quickstart.jl` shows the main steps from the Julia REPL.
It makes a small file, imports it, reprojects it, adds a channel, edits and undoes a cell, and exports a CSV.
Then it imports a public grid, describes it, sets its coordinate system, exports it to GeoTIFF and undoes the change.
At the end it saves the script.
It takes about 15 seconds the first time, since Julia compiles the code first.

```
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore examples/quickstart.jl
```

## Grids

A grid item holds a regular grid of `Float32` or `Float64` values, with `NaN` for missing cells.
`import_file` reads Geosoft `.grd` (plain or zlib, with the coordinate system from `.grd.xml` or `.gi`), Surfer `.grd`, GeoTIFF and ER Mapper `.ers`.
`export_file` writes a grid to Geosoft `.grd` (with a `.grd.xml`), GeoTIFF or ER Mapper `.ers`, chosen by the file extension.
The `grid.statistics` tool describes the values.
`set_grid_crs!`, `set_grid_georef!` and `set_grid_style!` change the grid's properties, and `undo!` takes a change back.

```julia
job = wait_job(import_file(s, "mag.grd"))
id = only(job.outputs)
run_tool(s, "grid.statistics"; inputs = Dict("grid" => id))
set_grid_crs!(s, id, "EPSG:32633")
wait_job(export_file(s, id, "mag.tif"))
```

Grids are read and written in blocks of rows, so a grid of any size needs little memory.
A 1.6 GB grid imports in 2 to 10 seconds, with under 300 MB of memory growth (see `docs/bench.md`).
ER Mapper has names for fewer coordinate systems than GeoTIFF.
When it has no name for the grid's one, the `.ers` file has none, and the export report says so.
The tests check the readers on public sample files in `JuliaMagCore/test/data/grids`, listed with their licences in `LICENSE.md` there.

## Saved scripts

`script_text(s)` turns the history of a session into a Julia script.
The script keeps the items each job makes in variables named after their ids, such as `db_1 = only(wait_job(import_file(s, "..."; ...); check = true).outputs)`.
The lines after it name the item by the variable.
So a script replays on the same project too, not only on a copy of the project as it was when the session started.
Each run makes new items with new ids.
Items that were in the project before the first history entry are named by their ids, such as `"db-1"`.
A job run again with `rerun!(...; replace = true)` replays as its command, followed by `remove_item!` for each item it replaced.
`check = true` makes the script stop with a plain message at a job that failed or was cancelled.
The lines run inside `try ... finally close_session!(s) end`, so the script does not leave the project locked, also when it stops part-way.
The script opens its own session.
So close the current session on the same project before you run the script in the same Julia process, or the script stops with `ProjectLockedError`.
The variables of the script are local to its `try` block, so they are gone when the script ends.

`docs/bench.md` has the import and export speed and memory numbers for big files and grids.
