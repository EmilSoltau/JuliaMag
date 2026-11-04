# The OpenGL map pass: draws a `Scene` into a colour texture, which ImGui then shows with
# `ig.Image`. It follows the CPU renderer (cpu.jl), the reference image.
# Everything here runs on the render thread, between `ig.Render()` and ImGui's draw data
# (`run_gl_pass`). Layer data goes up in steps (`upload_step!`): one line batch or one grid
# tile per frame, coarse levels first; a level that is not up yet draws the finest one that is.

const GL_ROOM_TEXT = "The graphics card has no room for this layer."
const BATCH_POINTS = UPLOAD_BYTES ÷ 12   # x, y and value as Float32
const LUT_UNIT_LINES = 0                # texture units of each program
const TABLE_UNIT_LINES = 1
const CELLS_UNIT = 0
const LUT_UNIT_GRID = 1
const TABLE_UNIT_GRID = 2

"The uniform locations of a map program; -1 for one it does not have."
struct MapUniforms
    c::Int32
    s::Int32
    lut::Int32
    table::Int32
    table_n::Int32
    flat::Int32
    lo::Int32
    hi::Int32
    opacity::Int32
    plain::Int32
    corner::Int32
    cells::Int32
    cells_tex::Int32
    last::Int32
    nearest::Int32
    shade::Int32
    cell_size::Int32
    rot::Int32
    sun::Int32
    z::Int32
end

MapUniforms() = MapUniforms(ntuple(_ -> Int32(-1), fieldcount(MapUniforms))...)

function MapUniforms(prog::UInt32)
    loc(name) = Int32(GL.glGetUniformLocation(prog, name))
    return MapUniforms(loc("u_c"), loc("u_s"), loc("u_lut"), loc("u_table"), loc("u_table_n"), loc("u_flat"),
                       loc("u_lo"), loc("u_hi"), loc("u_opacity"), loc("u_plain"), loc("u_corner"), loc("u_cells"),
                       loc("u_cells_tex"), loc("u_last"), loc("u_nearest"), loc("u_shade"), loc("u_cell_size"),
                       loc("u_rot"), loc("u_sun"), loc("u_z"))
end

"""
One level of a line layer on the GPU. Batch `b` holds the level's points `starts[b]` to
`stops[b] - 1` (0-based) in one vertex buffer, interleaved `x, y, v`. Batches hold whole
parts; a part longer than a batch is split, and the next batch starts again at the last
point of the one before, so the line has no gap.
"""
mutable struct GlLineLevel
    starts::Vector{Int}
    stops::Vector{Int}
    vaos::Vector{UInt32}
    vbos::Vector{UInt32}
    uploaded::Int
end

"One level of a grid layer on the GPU: an `R32F` texture per tile (0 until it is up)."
mutable struct GlGridLevel
    textures::Matrix{UInt32}
    uploaded::Int
end

"""
A layer on the GPU: its `key` (the caller's), the data and its `version` when it was queued,
its levels, its look-up and equalization table textures with the values they hold, and
`error` (`GL_ROOM_TEXT` after a failed upload; then it holds no GL objects and draws nothing).
`remaining` counts the uploads still to do. `previous` is the layer it replaces under the same
key: that one is fully up and draws instead, until this one is fully up too; then it is freed.
"""
mutable struct GlLayer
    key::Any
    data::Union{LineLayerData,GridLayerData}
    version::Int
    error::String
    lines::Vector{GlLineLevel}
    grids::Vector{GlGridLevel}
    lut::UInt32
    table::UInt32
    lut_bytes::Vector{UInt8}
    table_values::Vector{Float32}
    remaining::Int
    previous::Union{Nothing,GlLayer}
end

"One upload: batch or tile `item` (a linear tile index) of level `level` (an index into `lines` or `grids`)."
struct Upload
    layer::GlLayer
    level::Int
    item::Int
end

"""
    GlMap()

The GL objects of the map pass. Made without GL; `probe_gl!` makes the programs, the colour
texture and its framebuffer. The colour texture is resized in place, so its id stays the one
ImGui was given. Only the render thread uses it.

- `pending`: the uploads still to do, in order; `uploaded_last_frame`: bytes of the last `upload_step!`.
- `last_gpu_s`: the GPU time of a draw, from a `GL_TIME_ELAPSED` query read two draws later.
- `error_changes`: counts the changes of the layers' errors (one failed, or one with an
  error went), so what shows them can be kept until it changes (the Layers tab).
- `throw_in_draw`, `fail_upload`: test hooks. The first makes the next `gl_draw!` throw; the
  second (a GL error code) is reported by the next upload as if GL had given it.
"""
mutable struct GlMap
    probed::Bool
    problem::String
    line_prog::UInt32
    grid_prog::UInt32
    line_u::MapUniforms
    grid_u::MapUniforms
    fbo::UInt32
    colour::UInt32
    width::Int
    height::Int
    quad_vao::UInt32
    queries::Vector{UInt32}
    query_used::Vector{Bool}
    query_next::Int
    query_ready::Vector{GL.GLint}
    query_ns::Vector{GL.GLuint64}
    layers::Vector{GlLayer}
    pending::Vector{Upload}
    uploaded_last_frame::Int
    last_gpu_s::Float64
    error_changes::Int
    firsts::Vector{Int32}     # draw list of a line level
    counts::Vector{Int32}
    batch_firsts::Vector{Int32}   # the same, split by batch
    batch_counts::Vector{Int32}
    corners::Vector{Float32}
    scratch::Vector{Float32}
    throw_in_draw::Bool
    fail_upload::UInt32
end

GlMap() = GlMap(false, "", 0, 0, MapUniforms(), MapUniforms(), 0, 0, 0, 0, 0, UInt32[0, 0], [false, false], 1,
                GL.GLint[0], GL.GLuint64[0], GlLayer[], Upload[], 0, 0.0, 0, Int32[], Int32[], Int32[], Int32[],
                zeros(Float32, 8), Float32[], false, 0)

# --- GL helpers ---

# Clear errors from earlier calls. Bounded: without a context glGetError may never return GL_NO_ERROR.
function clear_gl_errors()
    for _ in 1:GL_ERROR_CLEAR_MAX
        GL.glGetError() == GL.GL_NO_ERROR && break
    end
    return nothing
end

gl_gen(f) = (id = GL.GLuint[0]; f(1, id); id[1])
gl_delete(f, id::UInt32) = (id == 0 || f(1, GL.GLuint[id]); nothing)
gl_error_text(err) = "OpenGL error 0x" * string(err; base = 16)

# The info log of a shader or a program.
function gl_log(id::UInt32, get_iv, get_log)::String
    n = GL.GLint[0]
    get_iv(id, GL.GL_INFO_LOG_LENGTH, n)
    buf = zeros(UInt8, max(n[1], 1))
    get_log(id, length(buf), C_NULL, buf)
    return strip(String(buf[1:something(findfirst(==(0x00), buf), length(buf) + 1)-1]))
end

# A compiled shader, or the compile log as a String.
function compile_shader(src::String, kind)::Union{UInt32,String}
    s = GL.glCreateShader(kind)
    GC.@preserve src GL.glShaderSource(s, 1, Ptr{GL.GLchar}[pointer(src)], C_NULL)
    GL.glCompileShader(s)
    ok = GL.GLint[0]
    GL.glGetShaderiv(s, GL.GL_COMPILE_STATUS, ok)
    ok[1] != 0 && return s
    log = gl_log(s, GL.glGetShaderiv, GL.glGetShaderInfoLog)
    GL.glDeleteShader(s)
    return log
end

# A linked program, or why there is none.
function link_program(vs::String, fs::String)::Union{UInt32,String}
    v = compile_shader(vs, GL.GL_VERTEX_SHADER)
    v isa String && return v
    f = compile_shader(fs, GL.GL_FRAGMENT_SHADER)
    f isa String && (GL.glDeleteShader(v); return f)
    p = GL.glCreateProgram()
    GL.glAttachShader(p, v)
    GL.glAttachShader(p, f)
    GL.glLinkProgram(p)
    GL.glDeleteShader(v)   # freed with the program
    GL.glDeleteShader(f)
    ok = GL.GLint[0]
    GL.glGetProgramiv(p, GL.GL_LINK_STATUS, ok)
    ok[1] != 0 && return p
    log = gl_log(p, GL.glGetProgramiv, GL.glGetProgramInfoLog)
    GL.glDeleteProgram(p)
    return log
end

function set_texture_params!(filter)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, filter)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, filter)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_S, GL.GL_CLAMP_TO_EDGE)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_T, GL.GL_CLAMP_TO_EDGE)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_BASE_LEVEL, 0)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAX_LEVEL, 0)
    return nothing
end

# --- Set up ---

"""
    probe_gl!(r) -> String

Make the programs, the colour texture with its framebuffer, and the queries, once. `""` when
the pass can run; else the reason, such as "The framebuffer for the map is not complete.".
After a failure `r` holds no GL objects. Call it on the render thread with the context current.
"""
function probe_gl!(r::GlMap)::String
    r.probed && return r.problem
    r.probed = true
    clear_gl_errors()
    r.problem = setup_gl!(r)
    isempty(r.problem) || free_map_objects!(r)
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0)
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    GL.glUseProgram(0)
    return r.problem
end

function setup_gl!(r::GlMap)::String
    lp = link_program(LINE_VS, LINE_FS)
    lp isa String && return "A map shader did not compile: " * lp
    r.line_prog = lp
    gp = link_program(GRID_VS, GRID_FS)
    gp isa String && return "A map shader did not compile: " * gp
    r.grid_prog = gp
    r.line_u = MapUniforms(lp)
    r.grid_u = MapUniforms(gp)
    GL.glUseProgram(lp)
    GL.glUniform1i(r.line_u.lut, LUT_UNIT_LINES)
    GL.glUniform1i(r.line_u.table, TABLE_UNIT_LINES)
    GL.glUseProgram(gp)
    GL.glUniform1i(r.grid_u.cells_tex, CELLS_UNIT)
    GL.glUniform1i(r.grid_u.lut, LUT_UNIT_GRID)
    GL.glUniform1i(r.grid_u.table, TABLE_UNIT_GRID)
    GL.glUseProgram(0)

    # An R32F texture, as the grid tiles are.
    t = gl_gen(GL.glGenTextures)
    GL.glBindTexture(GL.GL_TEXTURE_2D, t)
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_R32F, 4, 4, 0, GL.GL_RED, GL.GL_FLOAT, C_NULL)
    r32f = GL.glGetError() == GL.GL_NO_ERROR
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    gl_delete(GL.glDeleteTextures, t)
    r32f || return "This graphics driver has no R32F textures."

    r.colour = gl_gen(GL.glGenTextures)
    GL.glBindTexture(GL.GL_TEXTURE_2D, r.colour)
    set_texture_params!(GL.GL_NEAREST)
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, 1, 1, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, C_NULL)
    r.width = r.height = 1
    r.fbo = gl_gen(GL.glGenFramebuffers)
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, r.fbo)
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, r.colour, 0)
    GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) == GL.GL_FRAMEBUFFER_COMPLETE ||
        return "The framebuffer for the map is not complete."

    r.quad_vao = gl_gen(GL.glGenVertexArrays)   # the grid quads come from gl_VertexID
    GL.glGenQueries(2, r.queries)
    fill!(r.query_used, false)
    err = GL.glGetError()
    err == GL.GL_NO_ERROR || return "The map pass could not be set up: " * gl_error_text(err) * "."
    return ""
end

# Delete the programs, the colour texture, the framebuffer, the quad and the queries.
function free_map_objects!(r::GlMap)
    r.line_prog == 0 || GL.glDeleteProgram(r.line_prog)
    r.grid_prog == 0 || GL.glDeleteProgram(r.grid_prog)
    gl_delete(GL.glDeleteFramebuffers, r.fbo)
    gl_delete(GL.glDeleteTextures, r.colour)
    gl_delete(GL.glDeleteVertexArrays, r.quad_vao)
    any(!=(0), r.queries) && GL.glDeleteQueries(2, r.queries)
    r.line_prog = r.grid_prog = r.fbo = r.colour = r.quad_vao = 0
    fill!(r.queries, 0)
    fill!(r.query_used, false)
    r.width = r.height = 0
    return nothing
end

# --- Layers and uploads ---

"The GPU layer of `key`, or `nothing`."
function gl_layer(r::GlMap, key)::Union{Nothing,GlLayer}
    for g in r.layers
        isequal(g.key, key) && return g
    end
    return nothing
end

"The error of the GPU layer of `key`: `\"\"` when it has none or is not there."
layer_error(r::GlMap, key)::String = (g = gl_layer(r, key); g === nothing ? "" : g.error)

holds(g::GlLayer, data)::Bool = g.data === data && g.version == data.version

# The GPU layer to draw for this build of `data`, or `nothing`. While a new layer is still
# going up, the one it replaces draws; it may hold other data (an older build).
function find_layer(r::GlMap, data)::Union{Nothing,GlLayer}
    for g in r.layers
        p = g.previous
        holds(g, data) && return (g.remaining > 0 && p !== nothing) ? p : g
        (p !== nothing && holds(p, data)) && return p
    end
    return nothing
end

"""
    gpu_uses(r, data) -> Bool

Does a GPU layer, current or the one it replaces, still draw from the object `data`? While it
does, the object must not be built into (a line layer needs its levels to draw).
"""
function gpu_uses(r::GlMap, data)::Bool
    for g in r.layers
        g.data === data && return true
        p = g.previous
        (p !== nothing && p.data === data) && return true
    end
    return false
end

# The batches of a line level: whole parts up to `max_points` each.
function line_batches(lv::LineLevel, max_points::Int)::GlLineLevel
    starts, stops = Int[], Int[]
    s = e = 0
    for k in eachindex(lv.first)
        z = Int(lv.first[k]) + Int(lv.count[k])
        if z - s > max_points && e > s
            push!(starts, s)
            push!(stops, e)
            s = e
        end
        while z - s > max_points   # a part longer than a batch
            push!(starts, s)
            push!(stops, s + max_points)
            s += max_points - 1
        end
        e = z
    end
    e > s && (push!(starts, s); push!(stops, e))
    n = length(starts)
    return GlLineLevel(starts, stops, zeros(UInt32, n), zeros(UInt32, n), 0)
end

"""
    queue_uploads!(r, key, data)

Queue the uploads of a line layer's batches or a grid layer's tiles, coarsest level first,
as the layer `key`. A layer already under `key` that is fully up keeps drawing until the new
one is fully up, and is freed then; one that was still going up is freed now (the layer it
replaced keeps drawing). Data with no levels queues nothing. No GL calls but frees; `upload_step!`
does the uploads.
"""
function queue_uploads!(r::GlMap, key, data::Union{LineLayerData,GridLayerData})
    keep = take_drawn!(r, key)
    g = GlLayer(key, data, data.version, "", GlLineLevel[], GlGridLevel[], 0, 0, UInt8[], Float32[], 0, keep)
    push!(r.layers, g)
    if data isa LineLayerData
        for lv in data.levels
            push!(g.lines, line_batches(lv, BATCH_POINTS))
        end
        for k in reverse(eachindex(g.lines)), b in eachindex(g.lines[k].starts)
            push!(r.pending, Upload(g, k, b))
        end
    else
        for lv in data.levels
            push!(g.grids, GlGridLevel(zeros(UInt32, size(lv.tiles)), 0))
        end
        for k in reverse(eachindex(g.grids)), t in eachindex(g.grids[k].textures)
            push!(r.pending, Upload(g, k, t))
        end
    end
    g.remaining = count(u -> u.layer === g, r.pending)
    g.remaining == 0 && free_previous!(r, g)
    return nothing
end

# Take the layer under `key` out of the list. Return the one that is fully up and can draw
# until a new one is (`nothing` if none); free the rest.
function take_drawn!(r::GlMap, key)::Union{Nothing,GlLayer}
    old = gl_layer(r, key)
    old === nothing && return nothing
    filter!(x -> x !== old, r.layers)
    isempty(old.error) || (r.error_changes += 1)
    if isempty(old.error) && old.remaining == 0
        free_previous!(r, old)
        return old
    end
    keep = old.previous
    old.previous = nothing
    free_layer_objects!(r, old)
    return keep
end

function free_previous!(r::GlMap, g::GlLayer)
    p = g.previous
    p === nothing && return nothing
    free_layer_objects!(r, p)
    g.previous = nothing
    return nothing
end

"""
    upload_step!(r)

Do the next queued upload: one line batch (at most `UPLOAD_BYTES`) or one grid tile. Sets
`r.uploaded_last_frame` to its bytes. A GL error (such as `GL_OUT_OF_MEMORY`) gives the layer
the error "$(GL_ROOM_TEXT)" and frees what it had uploaded; it throws nothing.
"""
function upload_step!(r::GlMap)
    r.uploaded_last_frame = 0
    while !isempty(r.pending)
        u = popfirst!(r.pending)
        g = u.layer
        (isempty(g.error) && g.version == g.data.version) || continue
        clear_gl_errors()
        ok = g.data isa LineLayerData ? upload_batch!(r, g, u.level, u.item) : upload_tile!(r, g, u.level, u.item)
        if ok
            g.remaining -= 1
            g.remaining == 0 && free_previous!(r, g)
        else
            fail_layer!(r, g)
        end
        return nothing
    end
    return nothing
end

# The GL error after an upload, or the one the test hook gives.
function upload_error(r::GlMap)::UInt32
    err = GL.glGetError()
    if r.fail_upload != 0
        err = r.fail_upload
        r.fail_upload = 0
    end
    return err
end

function upload_batch!(r::GlMap, g::GlLayer, k::Int, b::Int)::Bool
    lv = (g.data::LineLayerData).levels[k]
    gll = g.lines[k]
    s, e = gll.starts[b], gll.stops[b]
    n = e - s
    buf = resize!(r.scratch, 3n)
    @inbounds for i in 1:n
        buf[3i-2] = lv.x[s+i]
        buf[3i-1] = lv.y[s+i]
        buf[3i] = lv.v[s+i]
    end
    vbo = gl_gen(GL.glGenBuffers)
    gll.vbos[b] = vbo   # freed with the layer if the upload fails
    vao = gl_gen(GL.glGenVertexArrays)
    gll.vaos[b] = vao
    GL.glBindVertexArray(vao)
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, vbo)
    GL.glBufferData(GL.GL_ARRAY_BUFFER, sizeof(buf), buf, GL.GL_STATIC_DRAW)
    GL.glVertexAttribPointer(0, 2, GL.GL_FLOAT, GL.GL_FALSE, 12, C_NULL)
    GL.glEnableVertexAttribArray(0)
    GL.glVertexAttribPointer(1, 1, GL.GL_FLOAT, GL.GL_FALSE, 12, Ptr{Cvoid}(8))
    GL.glEnableVertexAttribArray(1)
    GL.glBindVertexArray(0)
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0)
    upload_error(r) == GL.GL_NO_ERROR || return false
    gll.uploaded += 1
    r.uploaded_last_frame = sizeof(buf)
    return true
end

function upload_tile!(r::GlMap, g::GlLayer, k::Int, t::Int)::Bool
    d = g.data::GridLayerData
    cells = d.levels[k].tiles[t]
    maximum(size(cells)) <= gl_max_texture_size() || return false
    tex = gl_gen(GL.glGenTextures)
    g.grids[k].textures[t] = tex
    GL.glActiveTexture(GL.GL_TEXTURE0)
    GL.glBindTexture(GL.GL_TEXTURE_2D, tex)
    set_texture_params!(GL.GL_NEAREST)
    GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
    GL.glPixelStorei(GL.GL_UNPACK_ROW_LENGTH, 0)
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_R32F, size(cells, 1), size(cells, 2), 0, GL.GL_RED, GL.GL_FLOAT, cells)
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    upload_error(r) == GL.GL_NO_ERROR || return false
    g.grids[k].uploaded += 1
    r.uploaded_last_frame = sizeof(cells)
    return true
end

# Delete every GL object of a layer and drop its queued uploads.
function free_layer_objects!(r::GlMap, g::GlLayer)
    for l in g.lines
        for b in eachindex(l.vaos)
            gl_delete(GL.glDeleteVertexArrays, l.vaos[b])
            gl_delete(GL.glDeleteBuffers, l.vbos[b])
        end
        fill!(l.vaos, 0)
        fill!(l.vbos, 0)
        l.uploaded = 0
    end
    for l in g.grids
        foreach(t -> gl_delete(GL.glDeleteTextures, t), l.textures)
        fill!(l.textures, 0)
        l.uploaded = 0
    end
    gl_delete(GL.glDeleteTextures, g.lut)
    gl_delete(GL.glDeleteTextures, g.table)
    g.lut = g.table = 0
    empty!(g.lut_bytes)
    empty!(g.table_values)
    filter!(u -> u.layer !== g, r.pending)
    return nothing
end

function fail_layer!(r::GlMap, g::GlLayer)
    free_previous!(r, g)
    free_layer_objects!(r, g)
    g.error = GL_ROOM_TEXT
    r.error_changes += 1
    return nothing
end

"""
    free_layer!(r, key)

Delete the GL objects of the layer `key` and forget it. Render thread only.
"""
function free_layer!(r::GlMap, key)
    g = gl_layer(r, key)
    g === nothing && return nothing
    free_previous!(r, g)
    free_layer_objects!(r, g)
    filter!(x -> x !== g, r.layers)
    isempty(g.error) || (r.error_changes += 1)
    return nothing
end

"""
    free_all!(r)

Delete every GL object of the map pass, its layers too. `probe_gl!` makes them again.
Render thread only.
"""
function free_all!(r::GlMap)
    for g in r.layers
        free_previous!(r, g)
        free_layer_objects!(r, g)
        isempty(g.error) || (r.error_changes += 1)
    end
    empty!(r.layers)
    empty!(r.pending)
    free_map_objects!(r)
    r.probed = false
    r.problem = ""
    return nothing
end

# --- Drawing ---

"""
    gl_draw!(r, sc) -> UInt32

Draw the scene into the colour texture (resized to the scene) and return its id. A layer
draws the level it asks for when that is up, else the finest level that is; a layer with
nothing up, an error, or data that was not queued draws nothing. Throws on a GL error.
Does not allocate after warm-up. Needs a `probe_gl!` that returned `""`.
"""
function gl_draw!(r::GlMap, sc::Scene)::UInt32
    (r.probed && isempty(r.problem)) || throw(ArgumentError("the map pass is not set up; call probe_gl! first"))
    clear_gl_errors()
    w, h = sc.width, sc.height
    (w > 0 && h > 0) || throw(ArgumentError("the map view has no pixels"))
    resize_colour!(r, w, h)
    start_timer!(r)
    try
        GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, r.fbo)
        GL.glViewport(0, 0, w, h)
        if r.throw_in_draw
            r.throw_in_draw = false
            error("the test hook made the map pass throw")
        end
        GL.glDisable(GL.GL_SCISSOR_TEST)
        GL.glDisable(GL.GL_DEPTH_TEST)
        GL.glDisable(GL.GL_STENCIL_TEST)
        GL.glDisable(GL.GL_CULL_FACE)
        GL.glEnable(GL.GL_BLEND)
        GL.glBlendEquation(GL.GL_FUNC_ADD)
        # The colour as the CPU blends it; the alpha as `blend_channel` gives it for an opaque colour.
        GL.glBlendFuncSeparate(GL.GL_SRC_ALPHA, GL.GL_ONE_MINUS_SRC_ALPHA, GL.GL_ONE, GL.GL_ONE_MINUS_SRC_ALPHA)
        GL.glLineWidth(1f0)
        bg = sc.background
        GL.glClearColor(bg[1] / 255f0, bg[2] / 255f0, bg[3] / 255f0, bg[4] / 255f0)
        GL.glClear(GL.GL_COLOR_BUFFER_BIT)
        for layer in sc.layers
            draw_gl_layer!(r, sc, layer)
        end
        GL.glDisable(GL.GL_BLEND)
    finally
        GL.glEndQuery(GL.GL_TIME_ELAPSED)
    end
    err = GL.glGetError()
    err == GL.GL_NO_ERROR || error("The map pass met " * gl_error_text(err) * ".")
    return r.colour
end

# Resize the colour texture in place: the same id, new storage.
function resize_colour!(r::GlMap, w::Int, h::Int)
    (r.width == w && r.height == h) && return nothing
    GL.glBindTexture(GL.GL_TEXTURE_2D, r.colour)
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, w, h, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, C_NULL)
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    err = GL.glGetError()
    err == GL.GL_NO_ERROR || error("The map image of $w by $h pixels could not be made: " * gl_error_text(err) * ".")
    r.width, r.height = w, h
    return nothing
end

# Read the query of two draws ago, when it is done (never wait for it), and start this one.
function start_timer!(r::GlMap)
    k = r.query_next
    q = r.queries[k]
    if r.query_used[k]
        GL.glGetQueryObjectiv(q, GL.GL_QUERY_RESULT_AVAILABLE, r.query_ready)
        if r.query_ready[1] != 0
            GL.glGetQueryObjectui64v(q, GL.GL_QUERY_RESULT, r.query_ns)
            r.last_gpu_s = r.query_ns[1] / 1e9
        end
    end
    GL.glBeginQuery(GL.GL_TIME_ELAPSED, q)
    r.query_used[k] = true
    r.query_next = 3 - k
    return nothing
end

# Upload the look-up table and the equalization table when they differ from what the layer's
# textures hold, and bind them to their units.
function bind_colours!(g::GlLayer, lut::Vector{UInt8}, table::Union{Nothing,Vector{Float32}}, lut_unit::Int, table_unit::Int)
    GL.glActiveTexture(GL.GL_TEXTURE0 + lut_unit)
    if g.lut == 0
        g.lut = gl_gen(GL.glGenTextures)
        GL.glBindTexture(GL.GL_TEXTURE_2D, g.lut)
        set_texture_params!(GL.GL_NEAREST)
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, 256, 1, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, lut)
        copy!(g.lut_bytes, lut)
    else
        GL.glBindTexture(GL.GL_TEXTURE_2D, g.lut)
        if g.lut_bytes != lut
            GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
            GL.glTexSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, 256, 1, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, lut)
            copy!(g.lut_bytes, lut)
        end
    end
    GL.glActiveTexture(GL.GL_TEXTURE0 + table_unit)
    if table === nothing
        GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    elseif g.table == 0 || length(g.table_values) != length(table)
        g.table == 0 && (g.table = gl_gen(GL.glGenTextures))
        GL.glBindTexture(GL.GL_TEXTURE_2D, g.table)
        set_texture_params!(GL.GL_LINEAR)
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_R32F, length(table), 1, 0, GL.GL_RED, GL.GL_FLOAT, table)
        copy!(g.table_values, table)
    else
        GL.glBindTexture(GL.GL_TEXTURE_2D, g.table)
        if g.table_values != table
            GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
            GL.glTexSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, length(table), 1, GL.GL_RED, GL.GL_FLOAT, table)
            copy!(g.table_values, table)
        end
    end
    GL.glActiveTexture(GL.GL_TEXTURE0)
    return nothing
end

# The uniforms of the colour rule and the view transform.
function set_colour_uniforms!(u::MapUniforms, lo::Float32, hi::Float32, table, opacity::Float32,
                              t::NTuple{4,Float32})
    GL.glUniform2f(u.c, t[1], t[2])
    GL.glUniform2f(u.s, t[3], t[4])
    GL.glUniform1i(u.flat, (isnan(lo) || isnan(hi) || lo == hi) ? 1 : 0)
    GL.glUniform1f(u.lo, lo)
    GL.glUniform1f(u.hi, hi)
    GL.glUniform1i(u.table_n, table === nothing ? 0 : length(table))
    GL.glUniform1f(u.opacity, clamp(opacity, 0f0, 1f0))
    return nothing
end

level_up(l::GlLineLevel)::Bool = l.uploaded == length(l.vaos)
level_up(l::GlGridLevel)::Bool = l.uploaded == length(l.textures)

# The level to draw: `want` when all of it is up, else the finest level that is, else 0.
function ready_level(levels::Vector{T}, want::Int)::Int where {T<:Union{GlLineLevel,GlGridLevel}}
    level_up(levels[want]) && return want
    for k in eachindex(levels)
        level_up(levels[k]) && return k
    end
    return 0
end

function draw_gl_layer!(r::GlMap, sc::Scene, l::LineDraw)
    length(l.lut) >= 1024 || return nothing
    g = find_layer(r, l.data)
    (g === nothing || !isempty(g.error)) && return nothing
    d = g.data::LineLayerData   # the layer's own data: a replaced one draws its old build
    w, h = sc.width, sc.height
    want = d === l.data ? l.level : choose_level(d, sc.camera, w, h)
    (1 <= want <= length(d.levels)) || return nothing
    k = ready_level(g.lines, want)
    k == 0 && return nothing
    draw_list!(r.firsts, r.counts, d, k, sc.camera, w, h)
    isempty(r.firsts) && return nothing
    u = r.line_u
    GL.glUseProgram(r.line_prog)
    bind_colours!(g, l.lut, l.table, LUT_UNIT_LINES, TABLE_UNIT_LINES)
    set_colour_uniforms!(u, l.lo, l.hi, l.table, l.opacity, gl_transform(sc.camera, d.points.origin, w, h))
    p = l.plain
    GL.glUniform4f(u.plain, p[1] / 255f0, p[2] / 255f0, p[3] / 255f0, p[4] / 255f0)
    draw_batches!(r, g.lines[k])
    GL.glBindVertexArray(0)
    return nothing
end

# Split the draw list by batch and draw each batch's parts with one glMultiDrawArrays.
function draw_batches!(r::GlMap, gl::GlLineLevel)
    starts, stops = gl.starts, gl.stops
    nb = length(starts)
    bf, bc = r.batch_firsts, r.batch_counts
    empty!(bf)
    empty!(bc)
    b = 1
    current = 1
    from = 1
    @inbounds for p in eachindex(r.firsts)
        f = Int(r.firsts[p])
        z = f + Int(r.counts[p])
        while b < nb && stops[b] <= f
            b += 1
        end
        pos = f
        while pos < z
            if b != current
                multi_draw!(gl, current, bf, bc, from)
                current = b
                from = length(bf) + 1
            end
            hi = min(z, stops[b])
            push!(bf, Int32(pos - starts[b]))
            push!(bc, Int32(hi - pos))
            (hi == z || b == nb) && break
            b += 1
            pos = starts[b]   # the last point of the batch before
        end
    end
    multi_draw!(gl, current, bf, bc, from)
    return nothing
end

function multi_draw!(gl::GlLineLevel, b::Int, bf::Vector{Int32}, bc::Vector{Int32}, from::Int)
    n = length(bf) - from + 1
    n > 0 || return nothing
    GL.glBindVertexArray(gl.vaos[b])
    GC.@preserve bf bc GL.glMultiDrawArrays(GL.GL_LINE_STRIP, pointer(bf, from), pointer(bc, from), n)
    return nothing
end

function draw_gl_layer!(r::GlMap, sc::Scene, gd::GridDraw)
    length(gd.lut) >= 1024 || return nothing
    g = find_layer(r, gd.data)
    (g === nothing || !isempty(g.error)) && return nothing
    d = g.data::GridLayerData   # the layer's own data: a replaced one draws its old build
    want = d === gd.data ? gd.level : grid_level(d, sc.camera.res)
    (0 <= want < length(d.levels)) || return nothing
    k = ready_level(g.grids, want + 1)
    k == 0 && return nothing
    geo, lv, tile = d.geo, d.levels[k], d.tile
    f = 2.0^(k - 1)
    c, s = cosd(geo.rotation), sind(geo.rotation)
    u = r.grid_u
    GL.glUseProgram(r.grid_prog)
    bind_colours!(g, gd.lut, gd.table, LUT_UNIT_GRID, TABLE_UNIT_GRID)
    set_colour_uniforms!(u, gd.lo, gd.hi, gd.table, gd.opacity, gl_transform(sc.camera, (geo.x0, geo.y0), sc.width, sc.height))
    GL.glUniform1i(u.nearest, gd.nearest ? 1 : 0)
    GL.glUniform1i(u.shade, gd.shade ? 1 : 0)
    GL.glUniform2f(u.cell_size, Float32(geo.dx * f), Float32(geo.dy * f))
    GL.glUniform2f(u.rot, Float32(c), Float32(s))
    GL.glUniform3f(u.sun, gd.sun[1], gd.sun[2], gd.sun[3])
    GL.glUniform1f(u.z, gd.zfactor)
    GL.glBindVertexArray(r.quad_vao)
    GL.glActiveTexture(GL.GL_TEXTURE0 + CELLS_UNIT)
    textures = g.grids[k].textures
    corners = r.corners
    for tj in axes(textures, 2), ti in axes(textures, 1)
        ni = min(tile, lv.nx - (ti - 1) * tile)
        nj = min(tile, lv.ny - (tj - 1) * tile)
        # The quad's corners: cell edges of the tile, as offsets from the centre of cell (1, 1) of level 0.
        for (n, (a, b)) in enumerate(((0.5, 0.5), (ni + 0.5, 0.5), (0.5, nj + 0.5), (ni + 0.5, nj + 0.5)))
            gu = ((a + (ti - 1) * tile - 0.5) * f - 0.5) * geo.dx
            gv = ((b + (tj - 1) * tile - 0.5) * f - 0.5) * geo.dy
            corners[2n-1] = Float32(gu * c - gv * s)
            corners[2n] = Float32(gu * s + gv * c)
        end
        GL.glUniform2fv(u.corner, 4, corners)
        GL.glUniform4f(u.cells, TILE_BORDER - 0.5f0, TILE_BORDER - 0.5f0, Float32(ni + TILE_BORDER - 0.5),
                       Float32(nj + TILE_BORDER - 0.5))
        GL.glUniform2i(u.last, ni + 2TILE_BORDER - 1, nj + 2TILE_BORDER - 1)
        GL.glBindTexture(GL.GL_TEXTURE_2D, textures[ti, tj])
        GL.glDrawArrays(GL.GL_TRIANGLE_STRIP, 0, 4)
    end
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    GL.glBindVertexArray(0)
    return nothing
end

"""
    read_texture(r) -> Matrix{UInt32}

The colour texture as `render_cpu!` lays out its image: packed RGBA8, `img[x, y]`, row 1 at
the top. For tests.
"""
function read_texture(r::GlMap)::Matrix{UInt32}
    w, h = r.width, r.height
    buf = Vector{UInt32}(undef, w * h)
    GL.glBindTexture(GL.GL_TEXTURE_2D, r.colour)
    GL.glPixelStorei(GL.GL_PACK_ALIGNMENT, 4)
    GL.glGetTexImage(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, buf)
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    img = Matrix{UInt32}(undef, w, h)
    for y in 1:h, x in 1:w
        img[x, y] = buf[(h-y)*w+x]   # OpenGL rows start at the bottom
    end
    return img
end
