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
It runs in a few seconds.

```
JULIA_NUM_THREADS=4 julia --project=JuliaMagCore examples/quickstart.jl
```

`docs/bench.md` has the import speed and memory numbers for big files.
