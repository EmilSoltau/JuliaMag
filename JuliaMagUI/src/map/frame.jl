# Which renderer draws the map, the last full picture of it, and when a new one is drawn.
#
# The map draws with OpenGL (`MAP_GL`, gl.jl) when it can, and on the CPU (`MAP_CPU`,
# cpu.jl) when it cannot or the user asks. Either way the last full picture goes into one
# texture, the map image, which the view shows (`draw_map_view`). While the view moves and a
# full picture costs more than a frame, the view moves and scales that image instead
# (`image_rect`), and the full picture is drawn once the gesture settles. A CPU picture is
# drawn by a task on the default pool and comes back through the worker results.
# A GL failure moves the map to the CPU for the rest of the session (`fall_back!`).

@enum MapMode MAP_GL MAP_CPU

const FALLBACK_TOAST = "The map could not draw with the graphics card, so it draws on the CPU now."
const GPU_PROBLEM_TOAST = "The graphics card cannot draw the map here, so it draws on the CPU."

"""
    choose_mode(setting, gl_problem) -> MapMode

`MAP_CPU` for the Map Drawing setting `"cpu"` or when GL cannot draw the map here
(`gl_problem` is not empty); else `MAP_GL`.
"""
choose_mode(setting::AbstractString, gl_problem::String)::MapMode =
    (setting == "cpu" || !isempty(gl_problem)) ? MAP_CPU : MAP_GL

"""
    should_transform(moving, cost) -> Bool

Move the last image instead of drawing a full picture? While the view `moving` and a full
picture costs more than a frame (`cost` seconds over `FRAME_BUDGET`).
"""
should_transform(moving::Bool, cost::Float64)::Bool = moving && cost > FRAME_BUDGET

"""
    MapImage(texture, camera, size, key, cost)

The last full picture of the map: its RGBA8 `texture` (rows bottom first, as GL draws them;
0 before the first), the `camera` and `size` in device pixels it was drawn for, its scene
`key` (0 for none: the next frame draws a full picture), the `cost` in seconds of drawing it
(the GPU time from the query for GL, the wall time for the CPU) and the id of its `map`.
"""
mutable struct MapImage
    texture::UInt32
    camera::Camera
    size::NTuple{2,Int}
    key::UInt64
    cost::Float64
    map::String
end

MapImage(texture::Integer, camera::Camera, size::NTuple{2,Int}, key::Integer, cost::Real) =
    MapImage(texture, camera, size, key, cost, "")
MapImage() = MapImage(0, Camera(0, 0, 1), (0, 0), 0, 0.0)

has_picture(img::MapImage)::Bool = img.texture != 0 && img.size[1] > 0 && img.size[2] > 0

"""
    image_rect(img, cam, w, h) -> NTuple{4,Float32}

Where the picture `img` lies on a `w` by `h` view under camera `cam`: `(x0, y0, x1, y1)` in
view pixels. The same camera and size give exactly `(0, 0, w, h)`.
"""
function image_rect(img::MapImage, cam::Camera, w, h)::NTuple{4,Float32}
    k = img.camera.res / cam.res
    hw, hh = img.size[1] / 2 * k, img.size[2] / 2 * k
    cx = w / 2 + (img.camera.cx - cam.cx) / cam.res
    cy = h / 2 + (cam.cy - img.camera.cy) / cam.res
    return (Float32(cx - hw), Float32(cy - hh), Float32(cx + hw), Float32(cy + hh))
end

"""
A CPU picture that came back: its scene `key`, the `buffer` it is in (the first `size`
pixels, rows bottom first), how long it took (`seconds`), the `camera` and `size` it was
drawn for, the id of its `map`, the renderer's `generation` when it started and the
`error` that stopped it, or `nothing`.
"""
struct CpuFrameDone
    key::UInt64
    buffer::Matrix{UInt32}
    seconds::Float64
    camera::Camera
    size::NTuple{2,Int}
    map::String
    generation::Int
    error::Union{Nothing,CapturedException}
end

"""
    MapRenderer()

What draws the map. Changed on the render thread only.

- `mode`: `MAP_GL` or `MAP_CPU`, from the setting and `gl_problem` (`sync_mode!`).
- `gl`: the GL objects (`nothing` before the first GL frame and after a move to the CPU).
- `gl_problem`: why GL cannot draw the map here (a failed `probe_gl!` or a GL failure), or `""`.
- `image`: the last full picture; `texture_size`: the size of its texture.
- `cpu_buffers`: the two pictures CPU frames draw into, in turn (`cpu_next`). Each is made
  again only when the view grows past it.
- `cpu_task`: the CPU frame in flight, or `nothing`; `cpu_scene`, `cpu_lines`, `cpu_grids`:
  the copy of the scene it draws, which the render thread does not touch until it is back.
- `done`: a CPU picture back but not uploaded yet (`upload_cpu_frame!`, in the pass).
- `back_texture`, `back_size`: the second texture, which a CPU picture is uploaded into;
  `ready`: the picture in it, which the next frame's view swaps in (`take_cpu_frame!`).
- `full`: the view planned a full picture this frame (`plan_frame!`).
- `handover`: the picture is of the other renderer; GL keeps it until its uploads are done.
- `drawn_pending`: the uploads that were waiting when GL drew the picture; `drawn_at`: the
  `time()` of that GL picture.
- `generation`: one more each project; a CPU picture of another one is dropped.
- `failed_key`: the scene a CPU frame failed on; it is not drawn again.
- `gpu_noted`: the Graphics Card setting that cannot be had was said in a toast.
- `full_draws`: the full pictures drawn so far (tests count them).
- `fail_next`, `cost_override`, `cpu_hold`, `fail_upload`, `gl_error_next`: test hooks.
  `fail_next` makes the next GL frame throw; `cost_override` replaces the cost of the
  picture; while `cpu_hold` is set, a CPU frame waits for a `put!` on it; `fail_upload`
  makes the next CPU picture upload fail as on a GL error; `gl_error_next` makes the next
  copy of a GL picture meet a real GL error.
"""
mutable struct MapRenderer
    mode::MapMode
    gl::Union{Nothing,GlMap}
    gl_problem::String
    image::MapImage
    texture_size::NTuple{2,Int}
    cpu_buffers::NTuple{2,Matrix{UInt32}}
    cpu_next::Int
    cpu_task::Union{Nothing,Task}
    cpu_scene::Scene
    cpu_lines::Vector{LineDraw}
    cpu_grids::Vector{GridDraw}
    done::Union{Nothing,CpuFrameDone}
    back_texture::UInt32
    back_size::NTuple{2,Int}
    ready::Union{Nothing,CpuFrameDone}
    full::Bool
    handover::Bool
    drawn_pending::Int
    drawn_at::Float64
    generation::Int
    failed_key::UInt64
    gpu_noted::Bool
    full_draws::Int
    fail_next::Bool
    cost_override::Union{Nothing,Float64}
    cpu_hold::Union{Nothing,Channel{Nothing}}
    fail_upload::Bool
    gl_error_next::Bool
end

MapRenderer() = MapRenderer(MAP_GL, nothing, "", MapImage(), (0, 0),
    (Matrix{UInt32}(undef, 0, 0), Matrix{UInt32}(undef, 0, 0)), 1, nothing,
    Scene(Camera(0, 0, 1), 1, 1, (0x00, 0x00, 0x00, 0xff), LineDraw[], 0), LineDraw[], GridDraw[],
    nothing, 0, (0, 0), nothing, false, false, 0, 0.0, 0, 0, false, 0, false, nothing, nothing, false, false)

"The cost of the last full picture, or the test hook's."
frame_cost(r::MapRenderer)::Float64 = something(r.cost_override, r.image.cost)

# Is GL ready to replace a picture of the other renderer: made, with every upload done?
gl_ready(r::MapRenderer)::Bool = (gl = r.gl; gl !== nothing && isempty(gl.pending))

"""
    render_item(software, mode, gl_problem) -> (text, help)

The render item of the status bar and its tooltip: `"CPU map"` when the map draws on the
CPU, with the reason; else `"Software"` on a software OpenGL renderer, or `"GPU"`.
"""
function render_item(software::Bool, mode::MapMode, gl_problem::String)::Tuple{String,String}
    if mode == MAP_CPU
        isempty(gl_problem) && return ("CPU map", "The CPU draws the maps, as Map Drawing is set to CPU.")
        return ("CPU map", "The CPU draws the maps. " * gl_problem)
    end
    software && return ("Software", "Software rendering: the graphics card is not used.")
    return ("GPU", "The graphics card draws the maps.")
end

# --- Mode ---

"""
    sync_mode!(app, r)

Take the Map Drawing setting: change the mode when `choose_mode` says another one, and say
once in a toast when the Graphics Card setting cannot be had. Render thread only.
"""
function sync_mode!(app, r::MapRenderer)
    setting = app.config.map_drawing
    want = choose_mode(setting, r.gl_problem)
    want == r.mode || switch_mode!(r, want)
    if setting == "gpu" && !isempty(r.gl_problem)
        r.gpu_noted || toast!(app, :warn, GPU_PROBLEM_TOAST; sub = r.gl_problem)
        r.gpu_noted = true
    else
        r.gpu_noted = false
    end
    return nothing
end

# Draw with `mode` from now on. The CPU frees the GL objects. The picture stays shown until
# the new renderer has drawn the scene again; the view plans that from the next frame on.
function switch_mode!(r::MapRenderer, mode::MapMode)
    mode == MAP_CPU && free_gl!(r)
    r.mode = mode
    r.full = false
    r.handover = has_picture(r.image)
    r.image.key = 0
    return nothing
end

# Delete the GL objects of the map. Nothing queues uploads to them after this.
function free_gl!(r::MapRenderer)
    gl = r.gl
    gl === nothing && return nothing
    r.gl = nothing
    free_all!(gl)
    clear_gl_errors()
    return nothing
end

"""
    fall_back!(app, r, e, bt)

GL failed with `e`: draw on the CPU from now on. The reason goes into `gl_problem`, the GL
objects are freed, the error is logged once and a toast says so. The GL state comes back in
the same frame (`run_gl_pass`).
"""
function fall_back!(app, r::MapRenderer, @nospecialize(e), bt)
    reason = safe_plain_message(e)
    r.gl_problem = reason
    switch_mode!(r, MAP_CPU)
    r.gpu_noted = true   # this toast says it
    @error "The map could not draw with the graphics card; it draws on the CPU now" exception = (e, bt)
    toast!(app, :warn, FALLBACK_TOAST; sub = reason)
    return nothing
end

"""
    clear_image!(r)

Forget the picture and any CPU picture still to come, as for another project.
"""
function clear_image!(r::MapRenderer)
    r.generation += 1
    r.done = nothing
    r.ready = nothing
    r.image.key = 0
    r.image.size = (0, 0)
    r.image.map = ""
    r.handover = false
    r.failed_key = 0
    return nothing
end

# --- The frame ---

"""
    plan_frame!(r, st, w, h, map) -> Union{Nothing,NTuple{4,Float32}}

Plan this frame of map `map` in a `w` by `h` view: may it draw a full picture (`r.full`),
and where the picture goes (`image_rect`), or `nothing` when there is none to show. GL
draws in full in this frame's pass, so a full GL frame fills the view; only when the GL
objects are there, so the pass can draw. Call it while the view draws, before the pass.
"""
function plan_frame!(r::MapRenderer, st::MapViewState, w::Int, h::Int, map::String)::Union{Nothing,NTuple{4,Float32}}
    cam = st.camera
    r.full = false
    cam === nothing && return nothing
    gl = r.mode == MAP_GL
    r.full = !should_transform(pending_gesture(st), frame_cost(r)) && !(gl && r.handover && !gl_ready(r))
    img = r.image
    gl && r.full && r.gl !== nothing && img.texture != 0 && return (0f0, 0f0, Float32(w), Float32(h))
    (has_picture(img) && img.map == map) || return nothing
    return image_rect(img, cam, w, h)
end

"""
    draw_map_image(r, dl, b, st, vw, vh, map)

The map image in box `b`: a CPU picture uploaded in the last pass goes in first
(`take_cpu_frame!`), then `plan_frame!` says where the picture goes. It is clipped to `b`,
so a moved picture leaves `canvas` where it is not. Allocates nothing.
"""
function draw_map_image(r::MapRenderer, dl, b::Box, st::MapViewState, vw::Int, vh::Int, map::String)
    take_cpu_frame!(r)
    rect = plan_frame!(r, st, vw, vh, map)
    rect === nothing && return nothing
    # The texture's rows start at the bottom.
    tex = ig.ImTextureRef(ig.ImTextureID(r.image.texture))
    ig.PushClipRect(dl, (b.x0, b.y0), (b.x1, b.y1), true)
    ig.AddImage(dl, tex, (b.x0 + rect[1], b.y0 + rect[2]), (b.x0 + rect[3], b.y0 + rect[4]), (0f0, 1f0), (1f0, 0f0))
    ig.PopClipRect(dl)
    return nothing
end

"""
    gl_frame!(app, w, r, sc, map)

The GL part of the pass: make the GL objects once (`map_gl!`), run one `upload_step!`, and
draw a full picture of scene `sc` (`nothing` for none) when it is planned and the picture
is not of it, or uploads went on since it was drawn (`redraw_uploads`). Any error falls back
to the CPU.
"""
function gl_frame!(app, w::Window, r::MapRenderer, sc::Union{Nothing,Scene}, map::String)
    try
        gl = map_gl!(app, w, r)
        gl === nothing && return nothing
        if r.fail_next
            r.fail_next = false
            error("the test hook made the map pass fail")
        end
        upload_step!(gl)
        n = length(gl.pending)
        n > 0 && request_frames!(w)
        (sc === nothing || !r.full) && return nothing
        img = r.image
        now = time()
        (sc.key != img.key || img.map != map ||
         redraw_uploads(n, r.drawn_pending, frame_cost(r), now - r.drawn_at)) || return nothing
        gl_draw!(gl, sc)
        copy_gl_image!(r, gl)
        set_image!(r, sc.key, sc.camera, (sc.width, sc.height), gl.last_gpu_s, map)
        r.drawn_pending = n
        r.drawn_at = now
    catch e
        e isa InterruptException && rethrow()
        fall_back!(app, r, e, catch_backtrace())
    end
    return nothing
end

"""
    redraw_uploads(pending, drawn_pending, cost, since) -> Bool

Draw the same scene again because uploads went on since the picture was drawn? The picture
was drawn with `drawn_pending` uploads waiting (0: none, nothing to add) and `pending` wait
now. A picture that costs more than a frame (`cost` s) is drawn again at most every
`PENDING_REDRAW` s while uploads wait, so a slow renderer spends its frames on the uploads;
always once they are all done.
"""
redraw_uploads(pending::Int, drawn_pending::Int, cost::Float64, since::Float64)::Bool =
    drawn_pending > 0 && pending != drawn_pending && (pending == 0 || cost <= FRAME_BUDGET || since >= PENDING_REDRAW)

"""
    map_gl!(app, w, r) -> Union{Nothing,GlMap}

The GL objects of the map, made on first use; then every layer with data queues its uploads.
`nothing` when GL cannot draw the map here: the reason goes into `gl_problem` and the map
draws on the CPU, from the next frame on.
"""
function map_gl!(app, w::Window, r::MapRenderer)::Union{Nothing,GlMap}
    gl = r.gl
    gl === nothing || return gl
    gl = GlMap()
    problem = try
        probe_gl!(gl)
    catch
        free_all!(gl)
        rethrow()
    end
    if !isempty(problem)
        r.gl_problem = problem
        switch_mode!(r, MAP_CPU)
        request_frames!(w)
        @warn "The map cannot draw with OpenGL; it draws on the CPU" problem
        return nothing
    end
    r.gl = gl
    queue_all_uploads!(app.map)
    return gl
end

"""
    cpu_frame!(app, w, r, sc, map)

The CPU part of the pass: when no CPU frame is in flight and a full picture of scene `sc` is
planned and not there yet, start one (`start_cpu_frame!`). Frames are drawn while one is in flight.
"""
function cpu_frame!(app, w::Window, r::MapRenderer, sc::Union{Nothing,Scene}, map::String)
    if r.cpu_task !== nothing
        request_frames!(w)
        return nothing
    end
    (sc === nothing || !r.full || r.done !== nothing || r.ready !== nothing || sc.key == r.failed_key) &&
        return nothing
    img = r.image
    (sc.key == img.key && img.map == map) && return nothing
    start_cpu_frame!(app, r, sc, map)
    request_frames!(w)
    return nothing
end

"""
    start_cpu_frame!(app, r, sc, map)

Draw a copy of scene `sc` (`frame_scene!`) on the CPU, in a task on the default pool, into
the next of the two buffers. It sends a `CpuFrameDone` through `app.queue.results`. Until
that is handled, the data of the copy is not built into (`cpu_uses`).
"""
function start_cpu_frame!(app, r::MapRenderer, sc::Scene, map::AbstractString)
    k = r.cpu_next
    r.cpu_next = 3 - k
    buf = r.cpu_buffers[k]
    if length(buf) < sc.width * sc.height
        buf = Matrix{UInt32}(undef, sc.width, sc.height)
        r.cpu_buffers = k == 1 ? (buf, r.cpu_buffers[2]) : (r.cpu_buffers[1], buf)
    end
    fs = frame_scene!(r, sc)
    results, window, gen, hold, id = app.queue.results, app.window, r.generation, r.cpu_hold, String(map)
    r.cpu_task = Threads.@spawn :default run_cpu_frame(fs, buf, id, gen, hold, results, window)
    return nothing
end

# Draw the scene into the buffer, rows bottom first, and send the picture. Never throws.
function run_cpu_frame(sc::Scene, buf::Matrix{UInt32}, map::String, gen::Int, hold::Union{Nothing,Channel{Nothing}},
                       results::Channel{Any}, @nospecialize(window))
    failure = nothing
    t = time()
    w, h = sc.width, sc.height
    try
        hold === nothing || take!(hold)
        t = time()
        GC.@preserve buf begin
            img = unsafe_wrap(Matrix{UInt32}, pointer(buf), (w, h))
            render_cpu!(img, sc)
            flip_rows!(img)
        end
    catch e
        failure = CapturedException(e, catch_backtrace())
    end
    try
        put!(results, CpuFrameDone(sc.key, buf, time() - t, sc.camera, (w, h), map, gen, failure))
    catch e
        e isa InvalidStateException || @error "A CPU map frame could not be sent" exception = (e, catch_backtrace())
    end
    notify_window(window, results)
    return nothing
end

# Turn the picture upside down: GL textures start at the bottom row.
function flip_rows!(img::Matrix{UInt32})
    w, h = size(img)
    @inbounds for y in 1:h÷2, x in 1:w
        img[x, y], img[x, h+1-y] = img[x, h+1-y], img[x, y]
    end
    return img
end

"""
    frame_scene!(r, sc) -> Scene

A copy of `sc` for a CPU frame, in `r.cpu_scene`: each layer's draw and its look-up and
equalization tables are copied, so the render thread may change those of `sc` meanwhile.
The layer data is shared; `spare_free` keeps it from being built into while the frame draws.
"""
function frame_scene!(r::MapRenderer, sc::Scene)::Scene
    fs = r.cpu_scene
    fs.camera = sc.camera
    fs.width = sc.width
    fs.height = sc.height
    fs.background = sc.background
    fs.key = sc.key
    empty!(fs.layers)
    nl = ng = 0
    for l in sc.layers
        if l isa LineDraw
            nl += 1
            push!(fs.layers, copy_draw!(r.cpu_lines, nl, l))
        else
            ng += 1
            push!(fs.layers, copy_draw!(r.cpu_grids, ng, l::GridDraw))
        end
    end
    return fs
end

# `s` copied into `pool[k]` (made when the pool is shorter), with tables of its own.
function copy_draw!(pool::Vector{LineDraw}, k::Int, s::LineDraw)::LineDraw
    k > length(pool) && push!(pool, LineDraw(s.data, s.level, UInt8[], s.lo, s.hi, nothing, s.plain, s.opacity))
    d = pool[k]
    d.data = s.data
    d.level = s.level
    d.lo = s.lo
    d.hi = s.hi
    d.plain = s.plain
    d.opacity = s.opacity
    copy_tables!(d, s)
    return d
end

function copy_draw!(pool::Vector{GridDraw}, k::Int, s::GridDraw)::GridDraw
    k > length(pool) && push!(pool, GridDraw(s.data, s.level, UInt8[], s.lo, s.hi, nothing, s.opacity, s.shade,
                                             s.sun, s.zfactor, s.nearest))
    d = pool[k]
    d.data = s.data
    d.level = s.level
    d.lo = s.lo
    d.hi = s.hi
    d.opacity = s.opacity
    d.shade = s.shade
    d.sun = s.sun
    d.zfactor = s.zfactor
    d.nearest = s.nearest
    copy_tables!(d, s)
    return d
end

# The look-up and equalization tables of `s` into those of `d`, which never are the same objects.
function copy_tables!(d::T, s::T) where {T<:Union{LineDraw,GridDraw}}
    copyto!(resize!(d.lut, length(s.lut)), s.lut)
    t = s.table
    if t === nothing
        d.table = nothing
    else
        dt = d.table
        dt === nothing && (dt = Float32[])
        d.table = copyto!(resize!(dt, length(t)), t)
    end
    return nothing
end

"""
    cpu_uses(r, data) -> Bool

Does the CPU frame in flight draw from the object `data`?
"""
function cpu_uses(r::MapRenderer, data)::Bool
    r.cpu_task === nothing && return false
    for l in r.cpu_scene.layers
        l.data === data && return true
    end
    return false
end

function handle_result!(app, m::CpuFrameDone)
    r = app.map.renderer
    r.cpu_task = nothing
    m.generation == r.generation || return nothing
    err = m.error
    if err !== nothing
        r.failed_key = m.key
        note_draw_error!(app, err.ex, err.processed_bt; log = "The map could not be drawn on the CPU; the app goes on")
        return nothing
    end
    r.done = m
    return nothing
end

"""
    upload_cpu_frame!(app, w, r)

Upload a CPU picture that came back into the back texture (`glTexSubImage2D`), in the map
pass, so `run_gl_pass` restores the GL state whatever happens. The next frame's view swaps it
in (`take_cpu_frame!`), so the picture and where it goes change in the same frame. A picture
that came back after a move to GL is dropped. When the upload fails, the error is noted once
(`note_draw_error!`) and that scene is not drawn on the CPU again.
"""
function upload_cpu_frame!(app, w::Window, r::MapRenderer)
    m = r.done
    m === nothing && return nothing
    r.done = nothing
    r.mode == MAP_CPU || return nothing
    try
        clear_gl_errors()
        w_, h_ = m.size
        r.back_texture, r.back_size = sized_texture!(r.back_texture, r.back_size, w_, h_)
        GL.glBindTexture(GL.GL_TEXTURE_2D, r.back_texture)
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
        GL.glPixelStorei(GL.GL_UNPACK_ROW_LENGTH, 0)
        buf = m.buffer
        GC.@preserve buf GL.glTexSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, w_, h_, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE,
                                            pointer(buf))
        GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
        err = GL.glGetError()
        if r.fail_upload
            r.fail_upload = false
            err = GL.GL_OUT_OF_MEMORY
        end
        err == GL.GL_NO_ERROR || error("The map picture could not be shown: " * gl_error_text(err) * ".")
        r.ready = m
        request_frames!(w)   # the next frame places it
    catch e
        e isa InterruptException && rethrow()
        r.failed_key = m.key
        note_draw_error!(app, e, catch_backtrace(); log = "The map picture could not be shown; the app goes on")
    end
    return nothing
end

"""
    take_cpu_frame!(r)

Swap a CPU picture uploaded in the last pass into the map image: its texture and what it
shows. No GL calls. Call it in the view, before the image is placed.
"""
function take_cpu_frame!(r::MapRenderer)
    m = r.ready
    m === nothing && return nothing
    r.ready = nothing
    r.mode == MAP_CPU || return nothing
    img = r.image
    img.texture, r.back_texture = r.back_texture, img.texture
    r.texture_size, r.back_size = r.back_size, r.texture_size
    set_image!(r, m.key, m.camera, m.size, m.seconds, m.map)
    r.drawn_pending = 0
    return nothing
end

# The picture is now that of scene `key`.
function set_image!(r::MapRenderer, key::UInt64, cam::Camera, size::NTuple{2,Int}, cost::Float64, map::String)
    img = r.image
    img.key = key
    img.camera = cam
    img.size = size
    img.cost = cost
    img.map = map
    r.handover = false
    r.full_draws += 1
    return nothing
end

# A texture `tex` (made when 0) of `size`, sized again to `w` by `h` when it differs: the
# texture and its size. Linear, so a moved and scaled picture is smooth; drawn at its own size
# it shows each pixel as it is. A texture made here is deleted again when it cannot be sized.
function sized_texture!(tex::UInt32, size::NTuple{2,Int}, w::Int, h::Int)::Tuple{UInt32,NTuple{2,Int}}
    made = tex == 0
    if made
        tex = gl_gen(GL.glGenTextures)
        GL.glBindTexture(GL.GL_TEXTURE_2D, tex)
        set_texture_params!(GL.GL_LINEAR)
        GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
        size = (0, 0)
    end
    if size != (w, h)
        GL.glBindTexture(GL.GL_TEXTURE_2D, tex)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, w, h, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, C_NULL)
        GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
        err = GL.glGetError()
        if err != GL.GL_NO_ERROR
            made && gl_delete(GL.glDeleteTextures, tex)
            error("The map image of $w by $h pixels could not be made: " * gl_error_text(err) * ".")
        end
        size = (w, h)
    end
    return tex, size
end

# Copy the colour texture GL just drew into the map image.
function copy_gl_image!(r::MapRenderer, gl::GlMap)
    w, h = gl.width, gl.height
    img = r.image
    img.texture, r.texture_size = sized_texture!(img.texture, r.texture_size, w, h)
    GL.glBindFramebuffer(GL.GL_READ_FRAMEBUFFER, gl.fbo)
    GL.glBindTexture(GL.GL_TEXTURE_2D, img.texture)
    GL.glCopyTexSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, 0, 0, w, h)
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    if r.gl_error_next
        r.gl_error_next = false
        GL.glEnable(GL.GLenum(0xffff))   # not a capability: GL_INVALID_ENUM
    end
    err = GL.glGetError()
    err == GL.GL_NO_ERROR || error("The map picture could not be copied: " * gl_error_text(err) * ".")
    return nothing
end

"""
    read_image(r) -> Matrix{UInt32}

The map image as `render_cpu!` lays out a picture: packed RGBA8, `img[x, y]`, row 1 at the
top. For tests.
"""
function read_image(r::MapRenderer)::Matrix{UInt32}
    w, h = r.texture_size
    buf = Vector{UInt32}(undef, w * h)
    GL.glBindTexture(GL.GL_TEXTURE_2D, r.image.texture)
    GL.glPixelStorei(GL.GL_PACK_ALIGNMENT, 4)
    GL.glGetTexImage(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, buf)
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    img = Matrix{UInt32}(undef, w, h)
    for y in 1:h, x in 1:w
        img[x, y] = buf[(h-y)*w+x]
    end
    return img
end
