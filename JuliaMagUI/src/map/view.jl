# The map view: its camera and gestures (pure, no window), the GL pass that draws the shown
# map into its texture, and the view in the central area. The overlays are in overlays.jl.

"""
    MapViewState(camera = nothing)

The view of one map. Changed on the render thread only.

- `camera`: `nothing` until the first layer has an extent; then the full extent.
- `history`: the extents to go back and forward to.
- `gesture`: `:none`, `:pan` (a left or middle drag), `:box` (a Shift and left drag) or `:wheel`.
- `before`: the camera when the gesture started, until the gesture has settled.
- `grab`: the world point under the mouse at the press; `press`: the mouse there (view px).
- `left`: the press was the left button; `moved`: it has moved 3 px or more, so it pans and
  is not a pick.
- `last_input`: the time of the last input of the gesture.
- `box`: the box of a box zoom, `(x0, y0, x1, y1)` in view px, or `nothing`.
- `mouse`: the last valid mouse position (view px), used while the mouse is outside the window.
- `size`: the view's size in device pixels at the last step.
"""
mutable struct MapViewState
    camera::Union{Nothing,Camera}
    history::ExtentHistory
    gesture::Symbol
    before::Union{Nothing,Camera}
    grab::NTuple{2,Float64}
    press::NTuple{2,Float32}
    left::Bool
    moved::Bool
    last_input::Float64
    box::Union{Nothing,NTuple{4,Float32}}
    size::NTuple{2,Int}
    mouse::NTuple{2,Float32}
end

MapViewState(camera::Union{Nothing,Camera} = nothing) =
    MapViewState(camera, ExtentHistory(), :none, nothing, (0.0, 0.0), (0f0, 0f0), false, false, 0.0,
                 nothing, (0, 0), (0f0, 0f0))

"""
The input of one frame: the `mouse` in view px, whether it is over the view (`hovered`), the
buttons held for the view, `shift`, the `wheel` in notches (up is positive), the view `size`
in device pixels and the time `now`.
"""
struct MapInput
    mouse::NTuple{2,Float32}
    hovered::Bool
    left_down::Bool
    middle_down::Bool
    shift::Bool
    wheel::Float32
    size::NTuple{2,Int}
    now::Float64
end

const CLICK_PX = 3   # a press that moves less is a click, not a pan
const BOX_PX = 4     # a box zoom smaller than this each way is a click
const MOUSE_FAR = -256000f0   # a mouse position below this is no position (ImGui's `IsMousePosValid`)

# A mouse position that ImGui would call valid. Out of the window the GLFW backend sets -FLT_MAX.
valid_mouse(m::NTuple{2,Float32})::Bool = isfinite(m[1]) && isfinite(m[2]) && m[1] >= MOUSE_FAR && m[2] >= MOUSE_FAR

"""
    step_view!(st, input) -> Union{Nothing,Tuple{Symbol,NTuple{2,Float64}}}

Move the view by one frame of input. Pure: no window.

- A left or middle drag pans: the world point under the press stays under the mouse.
- Shift and a left drag draws a box, and fits it on release (no padding).
- A left press and release that moved under $(CLICK_PX) px, or a box under $(BOX_PX) px, returns
  `(:pick, world_point)`; else `nothing`.
- The wheel zooms about the mouse by `wheel_factor`.
- A size change keeps the centre and, during a pan, the grabbed point under the mouse.
- A mouse that is no position (it left the window) counts as the last valid one.

When a gesture has ended and `SETTLE` s have passed since its last input, the camera before
it goes into the history once, if the camera changed.
"""
function step_view!(st::MapViewState, input::MapInput)::Union{Nothing,Tuple{Symbol,NTuple{2,Float64}}}
    if valid_mouse(input.mouse)
        st.mouse = input.mouse
    else
        input = MapInput(st.mouse, false, input.left_down, input.middle_down, input.shift, 0f0, input.size, input.now)
    end
    st.size = input.size
    cam = st.camera
    cam === nothing && return nothing
    w, h = input.size
    mx, my = Float64(input.mouse[1]), Float64(input.mouse[2])
    down = input.left_down || input.middle_down
    result = nothing
    g = st.gesture
    if g == :pan || g == :box
        if down
            moved_px = max(abs(input.mouse[1] - st.press[1]), abs(input.mouse[2] - st.press[2]))
            moved_px >= CLICK_PX && (st.moved = true)
            if g == :box
                st.box = (st.press[1], st.press[2], input.mouse[1], input.mouse[2])
            elseif st.moved
                st.camera = pan_to(cam, st.grab, mx, my, w, h)
            end
            st.last_input = input.now
        else
            result = end_drag!(st, cam, input)
        end
    elseif down && input.hovered
        start_drag!(st, cam, input)
    end
    c = st.camera
    if input.wheel != 0 && input.hovered && c !== nothing
        st.gesture == :none && (st.gesture = :wheel)
        st.before === nothing && (st.before = c)
        st.camera = zoom_at(c, wheel_factor(input.wheel), mx, my, w, h)
        st.last_input = input.now
    end
    settle!(st, input.now)
    return result
end

function start_drag!(st::MapViewState, cam::Camera, input::MapInput)
    w, h = input.size
    st.gesture = input.left_down && input.shift ? :box : :pan
    st.before === nothing && (st.before = cam)
    st.press = input.mouse
    st.left = input.left_down
    st.grab = screen_to_world(cam, w, h, input.mouse[1], input.mouse[2])
    st.moved = false
    st.box = nothing
    st.last_input = input.now
    return nothing
end

# The release: fit the box, or a pick for a left click. The gesture settles later.
function end_drag!(st::MapViewState, cam::Camera, input::MapInput)::Union{Nothing,Tuple{Symbol,NTuple{2,Float64}}}
    w, h = input.size
    mx, my = Float64(input.mouse[1]), Float64(input.mouse[2])
    was_box = st.gesture == :box
    b = (st.press[1], st.press[2], input.mouse[1], input.mouse[2])   # the box at the release
    st.gesture = :none
    st.box = nothing
    st.last_input = input.now
    pick = (:pick, screen_to_world(cam, w, h, mx, my))
    if was_box
        (abs(b[3] - b[1]) < BOX_PX && abs(b[4] - b[2]) < BOX_PX) && return pick
        p = screen_to_world(cam, w, h, b[1], b[2])
        q = screen_to_world(cam, w, h, b[3], b[4])
        st.camera = fit_extent((min(p[1], q[1]), min(p[2], q[2]), max(p[1], q[1]), max(p[2], q[2])), w, h; pad = 0)
        return nothing
    end
    max(abs(input.mouse[1] - st.press[1]), abs(input.mouse[2] - st.press[2])) >= CLICK_PX && (st.moved = true)
    st.moved && (st.camera = pan_to(cam, st.grab, mx, my, w, h))
    return st.left && !st.moved ? pick : nothing   # a middle click is no pick
end

# Put the camera before a finished gesture into the history once it has settled.
function settle!(st::MapViewState, now::Float64)
    st.gesture == :wheel && now - st.last_input >= SETTLE && (st.gesture = :none)
    before = st.before
    before === nothing && return nothing
    (st.gesture == :none && now - st.last_input >= SETTLE) || return nothing
    st.camera == before || record_extent!(st.history, before)
    st.before = nothing
    return nothing
end

"""
    pending_gesture(st) -> Bool

Is a gesture under way or still to settle? The view draws frames meanwhile.
"""
pending_gesture(st::MapViewState)::Bool = st.gesture != :none || st.before !== nothing

# Drop a gesture that has not settled, then record the camera: the step of a command.
function record_command!(st::MapViewState)
    st.gesture == :wheel && (st.gesture = :none)
    st.gesture == :none && (st.before = nothing)
    cam = st.camera
    cam === nothing || record_extent!(st.history, cam)
    return nothing
end

"""
    fit_inner(ext, w, h, inset) -> Camera

`fit_extent` into the part of a `w` by `h` view right of and below `inset` device pixels (the
coordinate bands): the extent fits `w - inset` by `h - inset`, centred in that part.
"""
function fit_inner(ext::NTuple{4,Float64}, w, h, inset)::Camera
    c = fit_extent(ext, max(w - inset, 1), max(h - inset, 1))
    return Camera(c.cx - inset / 2 * c.res, c.cy + inset / 2 * c.res, c.res)
end

"""
    full_extent!(st, ext, w, h; inset = 0)

Fit the extent `ext` of all the map's layers into a view of `w` by `h` device pixels, inside
`inset` px of coordinate bands at the left and top (`fit_inner`). Records one extent (none for
the first camera).
"""
function full_extent!(st::MapViewState, ext::NTuple{4,Float64}, w, h; inset::Real = 0)
    record_command!(st)
    st.camera = fit_inner(ext, w, h, inset)
    return nothing
end

"""
    zoom_layer!(st, ext, w, h; inset = 0)

Fit the extent `ext` of one layer, as `full_extent!` does. Records one extent.
"""
zoom_layer!(st::MapViewState, ext::NTuple{4,Float64}, w, h; inset::Real = 0) = full_extent!(st, ext, w, h; inset)

"""
    zoom_by!(st, factor)

Zoom about the centre: `factor` above 1 zooms in. Records one extent.
"""
function zoom_by!(st::MapViewState, factor::Real)
    cam = st.camera
    cam === nothing && return nothing
    record_command!(st)
    st.camera = Camera(cam.cx, cam.cy, cam.res / factor)
    return nothing
end

"""
    previous!(st), next!(st)

Go back or forward in the extent history. Nothing happens at its end.
"""
function previous!(st::MapViewState)
    cam = st.camera
    cam === nothing && return nothing
    p = previous_extent!(st.history, cam)
    p === nothing || (st.camera = p)
    return nothing
end

function next!(st::MapViewState)
    cam = st.camera
    cam === nothing && return nothing
    p = next_extent!(st.history, cam)
    p === nothing || (st.camera = p)
    return nothing
end

# --- The shown map ---

"The map view of the snapshot that the central area shows, or `nothing`."
function shown_map(app)
    snap = app.snap
    (snap === nothing || isempty(app.ui.current_map)) && return nothing
    return get(snap.maps, app.ui.current_map, nothing)
end

"""
    map_extent(app, mv) -> Union{Nothing,NTuple{4,Float64}}

The extent of the loaded data of the visible layers of map view `mv` (see `refresh_plan!`),
or `nothing` when none has an extent yet.
"""
function map_extent(app, mv)::Union{Nothing,NTuple{4,Float64}}
    refresh_plan!(app.map, app, mv)
    ext = (NaN, NaN, NaN, NaN)
    for p in app.map.plan
        e = layer_extent(p.entry)
        e === nothing || (ext = something(union_extent(ext, e), ext))
    end
    return any(isnan, ext) ? nothing : ext
end

"The extent of an entry's data: the good points of a line layer, the corners of a grid; `nothing` for none."
function layer_extent(e)::Union{Nothing,NTuple{4,Float64}}   # e: a LayerEntry or nothing
    e === nothing && return nothing
    d = e.data
    d === nothing && return nothing
    d isa LineLayerData && return d.extent
    ext = d.extent
    return any(isnan, ext) ? nothing : ext
end

"""
    map_gl_pass!(app, w)

The GL pass of the app frame: on the render thread, after ImGui's render. While a map is
shown it makes the `GlMap` once (`probe_gl!`; then it queues every entry's uploads), runs one
`upload_step!` and draws frames while uploads wait. It builds the scene of the shown map and,
when its key differs from the one in the map texture (or uploads went on), draws it with
`gl_draw!`. An error never ends the app: it is noted with `note_draw_error!` and the frame goes on.
"""
function map_gl_pass!(app, w::Window)
    mv = shown_map(app)
    mv === nothing && return nothing
    ms = app.map
    try
        gl = map_gl!(ms)
        gl === nothing && return nothing
        upload_step!(gl)
        n = length(gl.pending)
        n > 0 && request_frames!(w)
        st = get(ms.views, mv.id, nothing)
        (st === nothing || st.camera === nothing) && return nothing
        vw, vh = st.size
        (vw > 0 && vh > 0) || return nothing
        sc = build_scene!(ms.scene, app, mv, st, vw, vh)
        if sc.key != ms.drawn || n > 0 || n != ms.drawn_pending
            ms.drawn = 0
            gl_draw!(gl, sc)
            ms.drawn = sc.key
            ms.drawn_pending = n
        end
    catch e
        e isa InterruptException && rethrow()
        ms.drawn = 0
        note_draw_error!(app, e, catch_backtrace(); log = "The map could not be drawn; the app goes on")
    end
    return nothing
end

# The GL objects of the map pass (a `GlMap`), made on first use. `nothing` when they cannot be made here
# (the reason is in `ms.gl_problem`).
function map_gl!(ms)
    gl = ms.gl
    gl === nothing || return gl
    isempty(ms.gl_problem) || return nothing
    gl = GlMap()
    problem = probe_gl!(gl)
    if !isempty(problem)
        ms.gl_problem = problem
        @warn "The map cannot draw with OpenGL" problem
        return nothing
    end
    ms.gl = gl
    queue_all_uploads!(ms)
    return gl
end

"""
    draw_map_view(app, dl, b)

The shown map in box `b` of the central area: `canvas` fill, an invisible button over `b`
that takes the mouse for `step_view!`, the map image (the map texture, which the GL pass of
this frame fills), then the overlays (`draw_overlays`). The camera starts at the full extent
once a layer has an extent. `Home` fits the full extent. A map with no layers says so.
"""
function draw_map_view(app, dl, b::Box)
    w = app.window::Window
    t = app.tokens
    ms = app.map
    mv = shown_map(app)
    mv === nothing && return nothing
    b = snap(b)
    ms.view = b
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.canvas))
    if isempty(mv.layers) && isempty(mv.error)
        draw_empty_map(app, dl, b)
        return nothing
    end
    refresh_plan!(ms, app, mv)   # the overlays read the plan of this map
    vw, vh = round(Int, width(b)), round(Int, height(b))
    st = get!(MapViewState, ms.views, mv.id)
    if st.camera === nothing && vw > 0 && vh > 0
        ext = map_extent(app, mv)
        ext === nothing || (st.camera = fit_inner(ext, vw, vh, px(w.scale, BAND)))
    end
    ig.SetCursorScreenPos((b.x0, b.y0))
    lib.igSetNextItemAllowOverlap()   # the nav buttons on top take the mouse over themselves
    ig.InvisibleButton("map", (Float32(max(vw, 1)), Float32(max(vh, 1))),
        ig.ImGuiButtonFlags_MouseButtonLeft | ig.ImGuiButtonFlags_MouseButtonMiddle)
    hovered = ig.IsItemHovered()
    active = ig.IsItemActive()
    io = ig.GetIO()
    mouse = unsafe_load(io.MousePos)
    # Out of the window the mouse is no position; `step_view!` then keeps the last valid one.
    view_mouse = ig.IsMousePosValid() ? (Float32(mouse.x - b.x0), Float32(mouse.y - b.y0)) : (-floatmax(Float32), -floatmax(Float32))
    input = MapInput(view_mouse, hovered, active && ig.IsMouseDown(0),
        active && ig.IsMouseDown(2), unsafe_load(io.KeyShift), hovered ? Float32(unsafe_load(io.MouseWheel)) : 0f0,
        (vw, vh), time())
    step_view!(st, input)   # a pick moves the shared cursor in a later task
    pending_gesture(st) && request_frames!(w)
    if !blocks_shortcuts(app) && !unsafe_load(io.WantTextInput) && ig.IsKeyPressed(lib.ImGuiKey_Home, false)
        ext = map_extent(app, mv)
        ext === nothing || full_extent!(st, ext, vw, vh; inset = px(w.scale, BAND))
    end
    gl = ms.gl
    if gl !== nothing && st.camera !== nothing
        # The texture's rows start at the bottom.
        tex = ig.ImTextureRef(ig.ImTextureID(gl.colour))
        ig.AddImage(dl, tex, (b.x0, b.y0), (b.x0 + vw, b.y0 + vh), (0f0, 1f0), (1f0, 0f0))
    end
    draw_overlays(app, dl, b, mv, st)
    return nothing
end
