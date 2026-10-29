# Converters between JuliaMag's georeference and the corner based affine
# transform of GDAL and other formats. Every grid reader and writer uses these.
#
# JuliaMag (Geosoft): `x0, y0` is the centre of the lower-left cell, `dx, dy`
# are the cell sizes, `rotation` is in degrees counter-clockwise about
# `(x0, y0)`. Row 1 is the row through `y0`.
#
# GDAL: `gt = (gx, a, b, gy, c, d)`. The ground position of pixel corner
# `(col, row)`, counted from 0 and from the first stored row, is
# `x = gx + col * a + row * b`, `y = gy + col * c + row * d`.

"How far the columns of an affine matrix may be from right angles, relative to the cell sizes."
const SKEW_TOLERANCE = 1e-9

"""
    georef_from_affine(gt, nx, ny) -> (; dx, dy, x0, y0, rotation, bottom_up)

The georeference of a grid of `nx` by `ny` cells stored with GDAL's affine
transform `gt = (gx, a, b, gy, c, d)`.

- `dx = hypot(a, c)`, `dy = hypot(b, d)`, `rotation = atan(c, a)` in degrees.
- `bottom_up` is true when the first stored row is the south row
  (`a * d - b * c > 0`). Else the first stored row is the north row, and it
  becomes the last row (`ny`) of the grid.
- `x0, y0` is the centre of the lower-left cell.

Throws `GridError` when the grid is skewed: its columns and rows are not at
right angles.
"""
function georef_from_affine(gt::NTuple{6,Float64}, nx::Integer, ny::Integer)
    gx, a, b, gy, c, d = gt
    dx = hypot(a, c)
    dy = hypot(b, d)
    (dx > 0 && dy > 0 && isfinite(dx) && isfinite(dy)) ||
        throw(GridError("the cell size of the grid is not a positive number (affine transform $gt)"))
    abs(a * b + c * d) <= SKEW_TOLERANCE * dx * dy ||
        throw(GridError("the grid is skewed: its rows and columns are not at right angles " *
                        "(affine transform $gt). JuliaMag reads only grids with square corners."))
    bottom_up = a * d - b * c > 0
    # The centre of the lower-left cell: column 0, and the first stored row
    # when it is the south row, else the last one.
    r = bottom_up ? 0.5 : ny - 0.5
    x0 = gx + 0.5 * a + r * b
    y0 = gy + 0.5 * c + r * d
    rotation = atand(c, a)
    return (; dx, dy, x0, y0, rotation, bottom_up)
end

"""
    affine_from_grid(g) -> NTuple{6,Float64}

GDAL's affine transform `(gx, a, b, gy, c, d)` of grid `g` stored top-down:
the first stored row is the north row (row `ny` of the grid).
The inverse of `georef_from_affine`.
"""
function affine_from_grid(g::Grid)::NTuple{6,Float64}
    c = cosd(g.rotation)
    s = sind(g.rotation)
    # One step along a row (column direction) and one step to the next stored row (south).
    a, cc = g.dx * c, g.dx * s
    b, d = g.dy * s, -g.dy * c
    # The outer north-west corner, in the grid frame from (x0, y0): half a cell
    # west of column 1 and half a cell north of the centre of row ny.
    u = -0.5 * g.dx
    v = (g.ny - 0.5) * g.dy
    gx = g.x0 + u * c - v * s
    gy = g.y0 + u * s + v * c
    return (gx, a, b, gy, cc, d)
end
