# Helpers for the map tests.

"""
    survey_database!(s; lines = 3, rows = 5, x0, y0, dx, dy, crs, nan_line = 0, fid_start = 0.0) -> String

Add a database with lines L1001, L1002, ... of `rows` rows each. Line `l` has
`X = x0 + (r - 1) * dx`, `Y = y0 + (l - 1) * dy` and `MAG = 100l + r`. The pair
X, Y in `crs` is current. With `nan_line = k`, line k has `NaN` for X and Y. Each line
starts at fiducial `fid_start`, step 0.1.
"""
function survey_database!(s::Session; lines::Int = 3, rows::Int = 5, x0::Float64 = 500_000.0,
                          y0::Float64 = 7_000_000.0, dx::Float64 = 10.0, dy::Float64 = 50.0,
                          crs::String = "EPSG:32755", nan_line::Int = 0, fid_start::Float64 = 0.0)::String
    p = s.project
    id = new_item_id(p, ITEM_DATABASE)
    db = create_database(joinpath(p.folder, "databases", id), id)
    for (name, role) in (("X", ROLE_X), ("Y", ROLE_Y), ("MAG", ROLE_NONE))
        add_channel!(db, ChannelInfo(name, name, Float64, name == "MAG" ? "nT" : "m", role, :normal, 10, -1, false, 1))
    end
    for l in 1:lines
        add_line!(db, LineInfo(LineId(LINE, 1000 + l, 0), 1, "2024-05-01", fid_start, 0.1, rows, 0, true))
    end
    apps = open_appenders(db, ["X", "Y", "MAG"])
    for l in 1:lines, r in 1:rows
        bad = l == nan_line
        append_value!(apps["X"], bad ? NaN : x0 + (r - 1) * dx)
        append_value!(apps["Y"], bad ? NaN : y0 + (l - 1) * dy)
        append_value!(apps["MAG"], Float64(100l + r))
    end
    close_appenders!(apps)
    add_pair!(db, "X", "Y", crs)
    db.current_pair = 1
    save_meta(db)
    add_item!(p, ProjectItem(id, ITEM_DATABASE, id, "databases/$id", "", ""))
    save_project(p)
    return id
end

"""
    add_test_grid!(s, A::Matrix{Float32}; dx, x0, y0, crs, name, units) -> String

Add a grid item that holds `A` (`A[i, j]` is column `i`, row `j`) with its
`vmin`, `vmax` and `count` set. The cells are `dx` wide and high.
"""
function add_test_grid!(s::Session, A::Matrix{Float32}; dx::Float64 = 10.0, x0::Float64 = 500_000.0,
                        y0::Float64 = 7_000_000.0, crs::String = "EPSG:32755", name::String = "Grid",
                        units::String = "nT")::String
    p = s.project
    id = new_item_id(p, ITEM_GRID)
    g = create_grid(joinpath(p.folder, "grids", id), name, Float32, size(A)...; dx, dy = dx, x0, y0, crs, units)
    write_rows!(g, 1, A)
    good = filter(!isnan, vec(A))
    g.count = length(good)
    g.vmin = isempty(good) ? NaN : Float64(minimum(good))
    g.vmax = isempty(good) ? NaN : Float64(maximum(good))
    save_grid_meta(g)
    add_item!(p, ProjectItem(id, ITEM_GRID, name, "grids/$id", "", ""))
    save_project(p)
    return id
end
