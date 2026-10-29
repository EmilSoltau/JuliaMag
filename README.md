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
It makes a small file, imports it, reprojects it, adds a channel, edits and undoes a cell, exports a CSV and saves the script.
It takes about 15 seconds the first time, since Julia compiles the code first.

```
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore examples/quickstart.jl
```

## Saved scripts

`script_text(s)` turns the history of a session into a Julia script.
The script names items by the ids they had in the session, such as `db-1`.
So it replays on a copy of the project as it was when the session started.
Run it again on the same project and the imports make new items with new ids.
The lines after them then change the old items or fail.

`docs/bench.md` has the import speed and memory numbers for big files.
