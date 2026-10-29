# JuliaMag

JuliaMag is a tool for processing airborne magnetic data.
The code lives in `JuliaMagCore`, a headless Julia package.
It has no user interface.

## Run the tests

Install Julia 1.12 first.
Then run this from the repository root:

```
julia --project=JuliaMagCore -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

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
The script names items by the ids they had in the session, such as `db-1`.
So it replays on a copy of the project as it was when the session started.
Run it again on the same project and the imports make new items with new ids.
The lines after them then change the old items or fail.

`docs/bench.md` has the import and export speed and memory numbers for big files and grids.
