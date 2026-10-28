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
