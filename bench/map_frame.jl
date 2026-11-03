# Map view frame times with a survey-sized project (docs/bench.md, "Map view").
#
# Usage, from the repo root, on a virtual display (never on the desktop):
#   julia --project=JuliaMagUI/tools -e 'using Pkg; Pkg.instantiate()'   # once
#   xvfb-run -a -s "-screen 0 1920x1080x24" env -u WAYLAND_DISPLAY \
#       julia -t auto,1 --project=JuliaMagUI bench/map_frame.jl [--software]
#
# It writes a temp project with a survey database of 2000 lines of 10,000 points (20 M
# points, 10 m apart, lines 50 m apart, a MAG channel) and an 8000 by 8000 Float32 grid with
# a NaN edge, as the spike's `gen.jl` did. It shows them on three maps (lines and grid, lines
# only, grid only) in a map view of 1584 by 955 pixels, and prints:
#
# - the load time to the first full picture of both layers (read, build, upload);
# - the median and p95 frame times of full pictures: the whole survey, zoomed 10x and 100x,
#   the grid only, and the grid and lines;
# - the frame times of a pan with the mouse, through the adaptive path (the last picture moves
#   while a full one costs more than a frame);
# - the CPU renderer (Map Drawing: CPU) for the whole survey and for the grid.
#
# A full frame moves the camera by one pixel each frame, so each frame draws a full picture.
# "GPU" is the map pass's GL_TIME_ELAPSED query; "frame" is the time from one app frame to the
# next. `--software` sets LIBGL_ALWAYS_SOFTWARE=1 (Mesa llvmpipe). The temp project is deleted
# at the end. It uses the window test harness, so ImGuiTestEngine comes from JuliaMagUI/tools.

const SOFTWARE = "--software" in ARGS
SOFTWARE && (ENV["LIBGL_ALWAYS_SOFTWARE"] = "1")

Base.find_package("ImGuiTestEngine") === nothing &&
    push!(LOAD_PATH, joinpath(dirname(@__DIR__), "JuliaMagUI", "tools"))

module MapFrameBench

using Statistics: median
import ModernGL as GL
const TEST = joinpath(dirname(@__DIR__), "JuliaMagUI", "test")
include(joinpath(TEST, "support", "app.jl"))
include(joinpath(TEST, "support", "state.jl"))

const LINES = 2000
const POINTS = 10_000
const CELLS = 8000
const VIEW = (1584, 955)   # the map view, device pixels
const FRAMES = 120
const CPU_FRAMES = 15
const X0, Y0 = 400_000.0, 7_000_000.0
const CRS = "EPSG:32755"

# A smooth "magnetic" field, about -200 to 300 nT, as in the spike.
function field(x, y)
    v = 120 * sin(x / 7000) * cos(y / 9000)
    v += 250 * exp(-((x - 30_000)^2 + (y - 60_000)^2) / (2 * 4000^2))
    v -= 180 * exp(-((x - 70_000)^2 + (y - 30_000)^2) / (2 * 2500^2))
    v += 40 * sin((x + 0.6y) / 900)
    return v
end

# About normal noise of spread 1, from four uniform numbers.
noise(rng) = (next_unit!(rng) + next_unit!(rng) + next_unit!(rng) + next_unit!(rng) - 2) * sqrt(3)

# Fill one line's X, Y and MAG: east-west, every other line run back, with a small wander.
function fill_line!(xs::Vector{Float64}, ys::Vector{Float64}, ms::Vector{Float32}, k::Int, rng::TestRng)
    yy = (k - 1) * 50.0 + 20noise(rng)
    dy = 0.0
    n = length(xs)
    for i in 1:n
        dy = 0.98dy + 0.6noise(rng)
        xx = (isodd(k) ? (i - 1) : (n - i)) * 10.0 + 0.5noise(rng)
        xs[i] = X0 + xx
        ys[i] = Y0 + yy + dy
        ms[i] = Float32(field(xx, yy + dy) + 0.5noise(rng) + (next_unit!(rng) < 1e-4 ? 400 : 0))
    end
    return nothing
end

function survey_database(s::Core.Session)::String
    p = s.project
    id = new_item_id(p, ITEM_DATABASE)
    db = create_database(joinpath(p.folder, "databases", id), "Survey")
    for (n, T, r, u) in (("X", Float64, ROLE_X, "m"), ("Y", Float64, ROLE_Y, "m"), ("MAG", Float32, ROLE_NONE, "nT"))
        add_channel!(db, ChannelInfo(n, n, T, u, r, :normal, 10, -1, false, 1))
    end
    rng = TestRng(1)
    apps = open_appenders(db, ["X", "Y", "MAG"])
    xs, ys, ms = Vector{Float64}(undef, POINTS), Vector{Float64}(undef, POINTS), Vector{Float32}(undef, POINTS)
    for k in 1:LINES
        add_line!(db, LineInfo(LineId(LINE, 1000 + k, 0), 1, "2026-11-03", 0.0, 0.1, POINTS, 0, true))
        fill_line!(xs, ys, ms, k, rng)
        append_value!(apps["X"], xs)
        append_value!(apps["Y"], ys)
        append_value!(apps["MAG"], ms)
    end
    close_appenders!(apps)
    add_pair!(db, "X", "Y", CRS)
    db.current_pair = 1
    save_meta(db)
    add_item!(p, ProjectItem(id, ITEM_DATABASE, "Survey", "databases/$id", "", ""))
    save_project(p)
    return id
end

# Rows j1 to j1 + n - 1 of the grid: the field inside an irregular survey edge, NaN outside.
function fill_rows!(b::Matrix{Float32}, j1::Int, n::Int, dx::Float64)
    Threads.@threads for jj in 1:n
        y = (j1 + jj - 2) * dx
        for i in 1:CELLS
            x = (i - 1) * dx
            inside = (x - 50_000)^2 / 48_000^2 + (y - 50_000)^2 / 46_000^2 + 0.05sin(x / 3000) < 1
            b[i, jj] = inside ? Float32(field(x, y)) : NaN32
        end
    end
    return nothing
end

function survey_grid(s::Core.Session)::String
    p = s.project
    id = new_item_id(p, ITEM_GRID)
    dx = 100_000 / CELLS
    g = create_grid(joinpath(p.folder, "grids", id), "TMI", Float32, CELLS, CELLS; dx, dy = dx,
        x0 = X0 + dx / 2, y0 = Y0 + dx / 2, crs = CRS, units = "nT")
    rows = 256
    b = Matrix{Float32}(undef, CELLS, rows)
    vmin, vmax, count = Inf, -Inf, 0
    for j1 in 1:rows:CELLS
        n = min(rows, CELLS - j1 + 1)
        blk = n == rows ? b : Matrix{Float32}(undef, CELLS, n)
        fill_rows!(blk, j1, n, dx)
        for v in blk
            isnan(v) && continue
            vmin, vmax, count = min(vmin, v), max(vmax, v), count + 1
        end
        write_rows!(g, j1, blk)
    end
    g.vmin, g.vmax, g.count = vmin, vmax, count
    save_grid_meta(g)
    add_item!(p, ProjectItem(id, ITEM_GRID, "TMI", "grids/$id", "", ""))
    save_project(p)
    return id
end

# --- Measuring ---

const STAMPS = UInt64[]          # the time of each app frame, while `RECORD` is on
const RECORD = Ref(false)
record_frame(w) = (RECORD[] && push!(STAMPS, time_ns()); nothing)

function recorded(f)
    empty!(STAMPS)
    RECORD[] = true
    try
        f()
    finally
        RECORD[] = false
    end
    return diff(STAMPS) ./ 1e6   # ms from frame to frame
end

p95(v) = (s = sort(v); s[clamp(round(Int, 0.95 * length(s)), 1, length(s))])
stats(v) = isempty(v) ? (NaN, NaN) : (median(v), p95(v))

# Is map `m` shown with every layer loaded, uploaded and drawn in the current picture?
function drawn(app, m)
    ms = app.map
    r = ms.renderer
    ms.plan_map == m && !isempty(ms.plan) &&
        all(p -> p.entry !== nothing && p.entry.data !== nothing && !p.entry.loading, ms.plan) &&
        (r.mode == UI.MAP_CPU || (r.gl !== nothing && isempty(r.gl.pending))) &&
        r.image.map == m && r.image.key == ms.scene.key
end

function show!(ctx, app, m; timeout = 120)
    app.ui.current_map = m
    ctx.frames(1)
    ctx.wait_until(() -> drawn(app, m); timeout)
    ctx.frames(2)
    return app.map.views[m]
end

# Full pictures at `cam`, moved by one pixel each frame: frame times and GPU times in ms.
function full_frames(ctx, app, m, cam::UI.Camera)
    st = show!(ctx, app, m)
    r = app.map.renderer
    shift(k) = UI.Camera(cam.cx + isodd(k) * cam.res, cam.cy, cam.res)
    for k in 1:10   # warm up
        st.camera = shift(k)
        ctx.frames(1)
    end
    gpu = Float64[]
    draws = r.full_draws
    frame = recorded() do
        for k in 1:FRAMES
            st.camera = shift(k)
            ctx.frames(1)
            push!(gpu, 1000 * r.image.cost)
        end
    end
    full = r.full_draws - draws
    full == FRAMES || println("  note: $full of $FRAMES frames drew a full picture")
    st.camera = cam
    return (; frame, gpu = gpu[3:end])   # the query is read two draws late
end

# A pan with the left button, `steps` mouse moves of (6, 3) px: the frame times while it moves.
function pan_frames(ctx, app, m; steps = FRAMES)
    st = show!(ctx, app, m)
    r = app.map.renderer
    v = app.map.view
    from = (v.x0 + 400, v.y0 + 300)
    ctx.mouse_to(from)
    te.MouseDown(0)
    draws = r.full_draws
    frame = recorded() do
        for k in 1:steps
            ctx.mouse_to(from .+ (6k, 3k))
        end
    end
    full = r.full_draws - draws
    te.MouseUp(0)
    ctx.wait_until(() -> st.before === nothing; timeout = 10)
    return (; frame, full, steps)
end

# CPU pictures (Map Drawing: CPU) at `cam`, moved by one pixel each time: the time each took
# to draw (ms), and from the camera change until it shows.
function cpu_frames(ctx, app, m, cam::UI.Camera)
    st = show!(ctx, app, m)
    draw = Float64[]
    shown = Float64[]
    r = app.map.renderer
    for k in 0:CPU_FRAMES
        st.camera = UI.Camera(cam.cx + isodd(k) * cam.res, cam.cy, cam.res)
        t0 = time()
        ctx.frames(1)
        ctx.wait_until(() -> drawn(app, m); timeout = 60)
        k == 0 && continue   # warm up
        push!(draw, 1000 * r.image.cost)
        push!(shown, 1000 * (time() - t0))
    end
    st.camera = cam
    return (; draw, shown)
end

# Resize the window until the map view is `VIEW`.
function size_view!(ctx, app)
    for _ in 1:5
        v = app.map.view
        have = (round(Int, UI.width(v)), round(Int, UI.height(v)))
        have == VIEW && return nothing
        ws = Ref((0, 0))
        ctx.on_render(w -> (ws[] = Tuple(UI.GLFW.GetWindowSize(w.handle))))
        want = ws[] .+ VIEW .- have
        ctx.on_render(w -> UI.GLFW.SetWindowSize(w.handle, want...))
        ctx.frames(5)
    end
    v = app.map.view
    error("the map view is $(UI.width(v)) by $(UI.height(v)), not $(VIEW[1]) by $(VIEW[2])")
end

row(name, v; unit = "ms") = println(rpad(name, 34), rpad(round(v[1]; digits = 2), 10), rpad(round(v[2]; digits = 2), 10), unit)

function main()
    has_display() || (println(stderr, "map_frame.jl: there is no display"); return 1)
    root = mktempdir()
    try
        s = Core.new_session(joinpath(root, "bench"), "Map bench")
        t = @elapsed (db = survey_database(s))
        println("Wrote the database ($(LINES * POINTS ÷ 10^6) M points) in $(round(t; digits = 1)) s.")
        t = @elapsed (g = survey_grid(s))
        println("Wrote the grid ($CELLS by $CELLS) in $(round(t; digits = 1)) s.")
        sizer = Core.new_map!(s; name = "Sizer")
        both = Core.new_map!(s; name = "Grid and lines")
        Core.add_layer!(s, both, g)
        Core.add_layer!(s, both, db)
        lines = Core.new_map!(s; name = "Lines")
        Core.add_layer!(s, lines, db)
        grid = Core.new_map!(s; name = "Grid")
        Core.add_layer!(s, grid, g)
        with_project_app(s; size = (2300, 1250), timeout = 3600, extra_ui = record_frame) do ctx, app
            app.ui.current_map = sizer
            ctx.frames(3)
            size_view!(ctx, app)
            info = Ref{Any}(nothing)
            ctx.on_render(w -> begin
                n = GL.GLint[0]
                GL.glGetIntegerv(GL.GL_MAX_TEXTURE_SIZE, n)
                info[] = (w.renderer, n[1])
            end)
            println("GL_RENDERER: ", info[][1], "; GL_MAX_TEXTURE_SIZE: ", info[][2])
            println("Map view: $(VIEW[1]) by $(VIEW[2]) px; Julia threads: $(Threads.nthreads(:default)) + $(Threads.nthreads(:interactive)).")
            println()

            # The load: the map shown, both layers read and built, uploaded and drawn.
            ms = app.map
            t0 = time()
            app.ui.current_map = both
            t_loaded = t_uploaded = NaN
            uploads = 0
            while !drawn(app, both)
                time() - t0 > 300 && error("the map did not load within 300 s")
                ctx.frames(1)
                plan_in = ms.plan_map == both && !isempty(ms.plan) &&
                          all(p -> p.entry !== nothing && p.entry.data !== nothing && !p.entry.loading, ms.plan)
                gl = ms.renderer.gl
                gl === nothing || (uploads = max(uploads, length(gl.pending)))
                isnan(t_loaded) && plan_in && (t_loaded = time() - t0)
                isnan(t_uploaded) && plan_in && gl !== nothing && isempty(gl.pending) && (t_uploaded = time() - t0)
            end
            t_first = time() - t0
            println("Load (s)")
            for p in ms.plan
                println("  ", rpad(p.layer.kind == :lines ? "read and build the lines" : "read and build the grid", 32),
                    round(p.entry.seconds; digits = 2))
            end
            println("  ", rpad("all layers in", 32), round(t_loaded; digits = 2))
            println("  ", rpad("uploads done", 32), round(t_uploaded; digits = 2), " ($uploads uploads queued at most)")
            println("  ", rpad("first full picture", 32), round(t_first; digits = 2))
            println()

            full = Dict(m => show!(ctx, app, m).camera for m in (both, lines, grid))
            zoom(c, f) = UI.Camera(c.cx, c.cy, c.res / f)
            println("Full frames                       median    p95")
            for (name, m, cam) in (("whole survey", lines, full[lines]), ("zoom 10x", lines, zoom(full[lines], 10)),
                    ("zoom 100x", lines, zoom(full[lines], 100)), ("grid only", grid, full[grid]),
                    ("grid and lines", both, full[both]))
                r = full_frames(ctx, app, m, cam)
                row("  $name: frame", stats(r.frame))
                row("  $name: GPU", stats(r.gpu))
            end
            println()

            r = pan_frames(ctx, app, both)
            println("Pan, grid and lines               median    p95")
            row("  frame", stats(r.frame))
            println("  full pictures while panning: $(r.full) of $(r.steps) moves")
            println()

            UI.set_map_drawing!(app, "cpu")
            ctx.wait_until(() -> app.map.renderer.mode == UI.MAP_CPU)
            println("CPU renderer                      median    p95")
            for (name, m) in (("whole survey", lines), ("grid", grid))
                r = cpu_frames(ctx, app, m, full[m])
                row("  $name: draw", stats(r.draw))
                row("  $name: shown", stats(r.shown))
            end
            UI.set_map_drawing!(app, "auto")
            ctx.frames(2)
            println()
        end
    finally
        rm(root; recursive = true, force = true)
    end
    return 0
end

end

exit(MapFrameBench.main())
