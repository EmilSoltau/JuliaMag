# Helpers for the grid tests. Later tasks add more here.

"Make a small Float32 grid in `folder` and fill it with 1, 2, 3, ... (row 1 first)."
function small_grid(folder; nx = 3, ny = 2)
    g = create_grid(folder, "Mag", Float32, nx, ny; dx = 10.0, dy = 20.0, x0 = 100.0, y0 = 200.0)
    write_rows!(g, 1, Float32[(j - 1) * nx + i for i in 1:nx, j in 1:ny])
    return g
end
