# The map view: its camera and gestures (pure, no window), the GL pass that draws the shown
# map into its texture, and the view in the central area. The overlays are in overlays.jl.

"""
    MapViewState(camera = nothing)

The view of one map. Changed on the render thread only.

- `camera`: `nothing` until the first layer has an extent; then the full extent.
- `fitted`: the camera the full extent last gave (the first camera, Full Extent), or `nothing`.
  While the camera is still that one, it follows the full extent (`view_camera`): data that
  comes in later, a new size or scale, and the legends showing or not fit it again. Any other
  move of the view ends that; Full Extent starts it again.
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
    fitted::Union{Nothing,Camera}
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
    MapViewState(camera, nothing, ExtentHistory(), :none, nothing, (0.0, 0.0), (0f0, 0f0), false, false, 0.0,
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

"""
    end_gesture!(st)

End a gesture that is under way or has not settled yet, now: the camera before it goes into
the history, if the camera changed. A drag whose button is still down starts again from the
camera in the next frame. A command runs this first, so the history walk stays exact.
"""
function end_gesture!(st::MapViewState)
    before = st.before
    before === nothing || st.camera == before || record_extent!(st.history, before)
    st.gesture = :none
    st.before = nothing
    st.box = nothing
    st.moved = false
    return nothing
end

# End a gesture, then record the camera: the step of a command.
function record_command!(st::MapViewState)
    end_gesture!(st)
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
    fit_clear(ext, w, h, inset, corners) -> Camera

`fit_inner`, kept clear of the overlays at the bottom corners of the view: `corners =
(left, right)`, each `(width, height)` in device pixels, the left one from the band (the scale
bar), the right one from the right edge (the legend cards); `(0.0, 0.0)` is none. When the
extent fitted inside the bands reaches into one of them, it fits instead into the largest of
these that keeps it clear: left of the right box, right of the left box, between them, or above
both.
"""
function fit_clear(ext::NTuple{4,Float64}, w, h, inset, corners::NTuple{2,NTuple{2,Float64}})::Camera
    (lw, lh), (rw, rh) = corners
    best = fit_inner(ext, w, h, inset)
    keeps_clear(best, ext, w, h, inset, corners) && return best
    best = fit_box(ext, w, h, (inset, inset, w, h - max(lh, rh)))   # above both: always clear
    for b in ((inset, inset, w - rw, h), (inset + lw, inset, w, h), (inset + lw, inset, w - rw, h))
        c = fit_box(ext, w, h, b)
        c.res < best.res && keeps_clear(c, ext, w, h, inset, corners) && (best = c)
    end
    return best
end

# Does `ext` under camera `c` keep out of the corner boxes of `fit_clear`?
function keeps_clear(c::Camera, ext::NTuple{4,Float64}, w, h, inset, corners::NTuple{2,NTuple{2,Float64}})::Bool
    x0, y1 = world_to_screen(c, w, h, ext[1], ext[2])   # the bottom left of the extent
    x1, _ = world_to_screen(c, w, h, ext[3], ext[2])
    (lw, lh), (rw, rh) = corners
    meets(bx0, bx1, by0) = bx1 > bx0 && by0 < h && x1 > bx0 && x0 < bx1 && y1 > by0
    return !meets(inset, inset + lw, h - lh) && !meets(w - rw, w, h - rh)
end

const NO_CORNERS = ((0.0, 0.0), (0.0, 0.0))

# `fit_extent` into the box `(x0, y0, x1, y1)` (view px) of a `w` by `h` view, centred in it.
function fit_box(ext::NTuple{4,Float64}, w, h, b)::Camera
    c = fit_extent(ext, max(b[3] - b[1], 1), max(b[4] - b[2], 1))
    return Camera(c.cx - ((b[1] + b[3]) / 2 - w / 2) * c.res, c.cy + ((b[2] + b[4]) / 2 - h / 2) * c.res, c.res)
end

"""
    full_extent!(st, ext, w, h; inset = 0, corners = NO_CORNERS)

Fit the extent `ext` of all the map's layers into a view of `w` by `h` device pixels, inside
`inset` px of coordinate bands at the left and top and clear of the `corners` boxes at the
bottom (`fit_clear`). Records one extent (none for the first camera). The camera follows the
full extent from now on (`fitted`).
"""
function full_extent!(st::MapViewState, ext::NTuple{4,Float64}, w, h; inset::Real = 0,
                      corners::NTuple{2,NTuple{2,Float64}} = NO_CORNERS)
    record_command!(st)
    st.camera = fit_clear(ext, w, h, inset, corners)
    st.fitted = st.camera
    return nothing
end

"""
    zoom_layer!(st, ext, w, h; inset = 0, corners = NO_CORNERS)

Fit the extent `ext` of one layer, as `full_extent!` does, but the camera does not follow the
full extent. Records one extent.
"""
function zoom_layer!(st::MapViewState, ext::NTuple{4,Float64}, w, h; inset::Real = 0,
                     corners::NTuple{2,NTuple{2,Float64}} = NO_CORNERS)
    record_command!(st)
    st.camera = fit_clear(ext, w, h, inset, corners)
    return nothing
end

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

Go back or forward in the extent history, after ending a gesture that has not settled
(`end_gesture!`). Nothing happens at its end.
"""
function previous!(st::MapViewState)
    cam = st.camera
    cam === nothing && return nothing
    end_gesture!(st)
    p = previous_extent!(st.history, cam)
    p === nothing || (st.camera = p)
    return nothing
end

function next!(st::MapViewState)
    cam = st.camera
    cam === nothing && return nothing
    end_gesture!(st)
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

"Is a layer of the plan (`refresh_plan!`) still loading: no entry yet, a load out, or no data and no error?"
function plan_loading(ms)::Bool
    for p in ms.plan
        e = p.entry
        (e === nothing || e.loading || (e.data === nothing && isempty(e.error))) && return true
    end
    return false
end

"""
    view_camera(app, mv, ext, w, h) -> Camera

The camera that fits `ext` into a `w` by `h` view of map view `mv`: inside the coordinate bands
and clear of the scale bar and the legend cards (`fit_clear`, `overlay_corners`).
"""
view_camera(app, mv, ext::NTuple{4,Float64}, w, h)::Camera =
    fit_clear(ext, w, h, px(app.window === nothing ? 1 : app.window.scale, BAND), overlay_corners(app, mv))

"The extent of an entry's data: the good points of a line layer, the corners of a grid; `nothing` for none."
function layer_extent(e)::Union{Nothing,NTuple{4,Float64}}   # e: a LayerEntry or nothing
    e === nothing && return nothing
    d = e.data
    d === nothing && return nothing
    d isa LineLayerData && return d.extent
    ext = d.extent
    return any(isnan, ext) ? nothing : ext
end

"Is window point `(x, y)` on a legend card, the scale bar or the nav buttons drawn in the last frame?"
over_overlay(ms, x::Real, y::Real)::Bool = any(kb -> inside(last(kb), x, y), ms.overlay_boxes)

"""
    map_gl_pass!(app, w)

The GL pass of the app frame: on the render thread, after ImGui's render. It takes the Map
Drawing setting (`sync_mode!`) and uploads a CPU picture that came back (`upload_cpu_frame!`,
for the next frame to place). While a map is shown it builds the scene of the map and runs
the part of its renderer: `gl_frame!` (one `upload_step!` each frame, and a full picture with
`gl_draw!` when one is planned) or `cpu_frame!` (a full picture in a task). A GL failure moves
the map to the CPU (`fall_back!`). Any other error never ends the app: it is noted with
`note_draw_error!` and the frame goes on.
"""
function map_gl_pass!(app, w::Window)
    ms = app.map
    r = ms.renderer
    try
        sync_mode!(app, r)
        upload_cpu_frame!(app, w, r)
        snap = app.snap
        id = app.ui.current_map
        # Not `shown_map`: its `Union` result boxes the map view, and the pass allocates nothing.
        (snap === nothing || !haskey(snap.maps, id)) && return nothing
        mv = snap.maps[id]
        st = get(ms.views, mv.id, nothing)
        sc = nothing
        if st !== nothing && st.camera !== nothing && st.size[1] > 0 && st.size[2] > 0
            sc = build_scene!(ms.scene, app, mv, st, st.size[1], st.size[2])
        end
        r.mode == MAP_GL && gl_frame!(app, w, r, sc, mv.id)
        r.mode == MAP_CPU && cpu_frame!(app, w, r, sc, mv.id)
    catch e
        e isa InterruptException && rethrow()
        note_draw_error!(app, e, catch_backtrace(); log = "The map could not be drawn; the app goes on")
    finally
        r.full = false   # planned again by the next frame's view
    end
    return nothing
end

"""
    draw_map_view(app, dl, b)

The shown map in box `b` of the central area: `canvas` fill, an invisible button over `b`
that takes the mouse for `step_view!`, the map image, then the overlays (`draw_overlays`).
A click (a `:pick`) moves the shared cursor (`pick_cursor!`); while the mouse is over the
view, `map_hover` reads what is under it for the status bar.
The map image is the last full picture (`draw_map_image`); a full GL picture is drawn by
this frame's GL pass. The camera starts at the full extent once a layer has an extent, and
follows it until the view moves (`fitted`). A map
with no layers says so. The keys (`Home` for Full Extent) are the map commands' (map_commands.jl).
"""
function draw_map_view(app, dl, b::Box)
    w = app.window::Window
    t = app.tokens
    ms = app.map
    snap_ = app.snap
    id = app.ui.current_map
    # Not `shown_map`: its `Union` result boxes the map view (see `map_gl_pass!`).
    (snap_ === nothing || !haskey(snap_.maps, id)) && return clear_hover!(app)
    mv = snap_.maps[id]
    b = snap(b)
    ms.view = b
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.canvas))
    if isempty(mv.layers) && isempty(mv.error)
        clear_hover!(app)
        draw_empty_map(app, dl, b)
        return nothing
    end
    refresh_plan!(ms, app, mv)   # the overlays read the plan of this map
    vw, vh = round(Int, width(b)), round(Int, height(b))
    st = get!(MapViewState, ms.views, mv.id)
    # Until the view moves, the camera follows the full extent: of the data in so far, at this
    # size and scale, clear of the legends. After the first fit, it waits while a layer loads,
    # so a layer that loads again (a new channel, an undo) does not make the view jump.
    if (st.camera === nothing || (st.camera == st.fitted && !plan_loading(ms))) && vw > 0 && vh > 0
        ext = map_extent(app, mv)
        if ext !== nothing
            st.camera = view_camera(app, mv, ext, vw, vh)
            st.fitted = st.camera
        end
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
    pick = step_view!(st, input)
    # A legend card, the scale bar or a nav button over the map takes the mouse.
    free = !over_overlay(ms, mouse.x, mouse.y)
    pick === nothing || !free || pick_cursor!(app, mv, pick[2]...)
    # The readout of what is under the pointer, while it is over the map.
    cam = st.camera
    if hovered && free && cam !== nothing && ig.IsMousePosValid()
        map_hover(app, screen_to_world(cam, vw, vh, view_mouse[1], view_mouse[2])...)
    else
        clear_hover!(app)
    end
    pending_gesture(st) && request_frames!(w)
    draw_map_image(ms.renderer, dl, b, st, vw, vh, mv.id)
    draw_overlays(app, dl, b, mv, st)
    return nothing
end

