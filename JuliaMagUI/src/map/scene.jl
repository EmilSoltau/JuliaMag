# The scene of the map: what both renderers draw. The CPU renderer (cpu.jl) is the
# fallback and the reference image for the GL one. No window, no GL.

"""
    lut_rgba!(out, name, reverse) -> out

Fill `out` with the 256 entries of the colour table `name` as RGBA bytes (alpha 255),
last to first when `reverse`. `Core.colour_table` takes a lock and allocates, so the caller
keeps the result per `(name, reverse)` and never calls this while the map draws.
"""
function lut_rgba!(out::Vector{UInt8}, name::AbstractString, reverse::Bool)::Vector{UInt8}
    table = Core.colour_table(name)
    n = length(table)
    resize!(out, 4n)
    for k in 1:n
        r, g, b = table[reverse ? n + 1 - k : k]
        out[4k-3] = r
        out[4k-2] = g
        out[4k-1] = b
        out[4k] = 0xff
    end
    return out
end

"""
A line layer to draw: its data, the level (an index into `data.levels`), the look-up table
(`lut_rgba!`), the limits, an equalization table or `nothing`, the colour of a point with no
value (and of every point when the layer has no channel) and the opacity. Mutable, so the map
keeps one per layer and changes it in place each frame (`build_scene!`).
"""
mutable struct LineDraw
    data::LineLayerData
    level::Int
    lut::Vector{UInt8}
    lo::Float32
    hi::Float32
    table::Union{Nothing,Vector{Float32}}
    plain::NTuple{4,UInt8}
    opacity::Float32
end

"""
A grid layer to draw: its data, the level (0 is the grid), the look-up table, the limits, an
equalization table or `nothing`, the opacity, hillshade (`shade`, the `sun` vector towards the
sun as east, north, up, and the resolved vertical scale `zfactor`) and nearest or bilinear sampling.
Mutable, as `LineDraw` is.
"""
mutable struct GridDraw
    data::GridLayerData
    level::Int
    lut::Vector{UInt8}
    lo::Float32
    hi::Float32
    table::Union{Nothing,Vector{Float32}}
    opacity::Float32
    shade::Bool
    sun::NTuple{3,Float32}
    zfactor::Float32
    nearest::Bool
end

"""
    Scene(camera, width, height, background, layers, key)

What to draw: the camera, the size in device pixels, the background and the layers in draw
order. `key` is a place for the caller's `scene_key`. The scene also owns the draw lists the
CPU renderer reuses, so one scene is not rendered by two threads at once.
"""
mutable struct Scene
    camera::Camera
    width::Int
    height::Int
    background::NTuple{4,UInt8}
    layers::Vector{Union{LineDraw,GridDraw}}
    key::UInt64
    firsts::Vector{Int32}
    counts::Vector{Int32}
    function Scene(camera::Camera, width::Integer, height::Integer, background::NTuple{4,UInt8},
                   layers::AbstractVector, key::Integer)
        return new(camera, width, height, background, Vector{Union{LineDraw,GridDraw}}(layers), key, Int32[], Int32[])
    end
end

# The hash of every entry of `v` (`Base.hash` of an array may read only some entries of a big one).
hash_all(::Nothing, h::UInt)::UInt = hash(nothing, h)
function hash_all(v::Vector{T}, h::UInt)::UInt where {T}
    h = hash(length(v), h)
    @inbounds for x in v
        h = hash(x, h)
    end
    return h
end

# The hash of the style values of a layer, after its data's identity, version and level.
function layer_key(l::LineDraw, h::UInt)::UInt
    h = hash(:line, h)
    h = hash(objectid(l.data), h)
    h = hash(l.data.version, h)
    h = hash(l.level, h)
    h = hash_all(l.lut, h)
    h = hash(l.lo, h)
    h = hash(l.hi, h)
    h = hash_all(l.table, h)
    h = hash(l.plain, h)
    return hash(l.opacity, h)
end

function layer_key(l::GridDraw, h::UInt)::UInt
    h = hash(:grid, h)
    h = hash(objectid(l.data), h)
    h = hash(l.data.version, h)
    h = hash(l.level, h)
    h = hash_all(l.lut, h)
    h = hash(l.lo, h)
    h = hash(l.hi, h)
    h = hash_all(l.table, h)
    h = hash(l.opacity, h)
    h = hash(l.shade, h)
    h = hash(l.sun, h)
    h = hash(l.zfactor, h)
    return hash(l.nearest, h)
end

"""
    scene_key(sc) -> UInt64

A hash of the camera, the size, the background and, per layer in order, its data and
`version`, its level and every style value. Equal keys mean equal pictures. Does not allocate.
"""
function scene_key(sc::Scene)::UInt64
    c = sc.camera
    h = hash(c.cx, hash(c.cy, hash(c.res, UInt(0x6a09e667))))
    h = hash(sc.width, hash(sc.height, h))
    h = hash(sc.background, h)
    for l in sc.layers
        h = layer_key(l, h)
    end
    return UInt64(h)
end

# --- The scene of the shown map ---

"A token colour as RGBA bytes, for the scene's background and plain line colour."
rgba_bytes(c::NTuple{4,Float32})::NTuple{4,UInt8} =
    (round(UInt8, 255 * clamp(c[1], 0f0, 1f0)), round(UInt8, 255 * clamp(c[2], 0f0, 1f0)),
     round(UInt8, 255 * clamp(c[3], 0f0, 1f0)), round(UInt8, 255 * clamp(c[4], 0f0, 1f0)))

"""
    LayerLook()

What a layer of a map keeps between frames so that drawing it allocates nothing: its draw,
changed in place (`line` or `grid`), its look-up table with the colour table and direction it
was made for, its equalization table with the data build it was made for, and its line labels
(the first point, name and direction of each line) with the build they were read from.
"""
mutable struct LayerLook
    line::Union{Nothing,LineDraw}
    grid::Union{Nothing,GridDraw}
    lut::Vector{UInt8}
    lut_name::String
    lut_reverse::Bool
    eq::Vector{Float32}
    eq_data::Any
    eq_version::Int
    label_data::Any
    label_version::Int
    label_points::Vector{Tuple{Int,Float64,Float64}}
    label_names::Vector{String}
    label_dirs::Vector{NTuple{2,Float64}}
end

LayerLook() = LayerLook(nothing, nothing, UInt8[], "", false, zeros(Float32, 1024), nothing, -1, nothing, -1,
                        Tuple{Int,Float64,Float64}[], String[], NTuple{2,Float64}[])

"""
    build_scene!(sc, app, mv::MapView, st::MapViewState, w, h) -> sc

Fill `sc` with the scene of map view `mv` at the camera of `st` and `w` by `h` device pixels.
On the render thread, from the snapshot and the loaded layer entries only. The visible layers
whose data has levels go in, in draw order, each with its level (`choose_level`, `grid_level`),
look-up table, stretch (`Core.stretch_range` on the layer's histogram, and `Core.equalize_table!`
for `:histeq`), opacity (or `ui.opacity_preview` for its layer) and resolved hillshade. Then
`sc.key = scene_key(sc)`. `st.camera` must be set.

Allocates nothing after warm-up: each layer keeps one draw, changed in place, and its look-up
and equalization tables, made again only when the style or the data changes (`refresh_plan!`).
"""
function build_scene!(sc::Scene, app, mv, st::MapViewState, w::Integer, h::Integer)::Scene
    ms = app.map
    refresh_plan!(ms, app, mv)
    cam = st.camera::Camera
    t = app.tokens
    sc.camera = cam
    sc.width = Int(w)
    sc.height = Int(h)
    sc.background = rgba_bytes(t.canvas)
    plain = rgba_bytes(t.text)
    preview = app.ui.opacity_preview
    empty!(sc.layers)
    for p in ms.plan
        e = p.entry
        e === nothing && continue
        d = e.data
        (d === nothing || isempty(d.levels)) && continue
        opacity = Float32(p.layer.opacity)
        preview !== nothing && preview[1] == p.layer.id && (opacity = Float32(preview[2]))
        if d isa LineLayerData
            push!(sc.layers, line_draw!(p.look, p.style, d, cam, sc.width, sc.height, plain, opacity))
        else
            push!(sc.layers, grid_draw!(p.look, p.style, d::GridLayerData, cam, opacity))
        end
    end
    sc.key = scene_key(sc)
    return sc
end

function line_draw!(look::LayerLook, style::Core.LayerStyle, d::LineLayerData, cam::Camera, w::Int, h::Int,
                    plain::NTuple{4,UInt8}, opacity::Float32)::LineDraw
    lo, hi = Core.stretch_range(style, d.hist)
    table = style.stretch === :histeq ? equalized!(look, d) : nothing
    level = choose_level(d, cam, w, h)
    l = look.line
    if l === nothing
        l = LineDraw(d, level, look.lut, lo, hi, table, plain, opacity)
        look.line = l
        return l
    end
    l.data = d
    l.level = level
    l.lut = look.lut
    l.lo = lo
    l.hi = hi
    l.table = table
    l.plain = plain
    l.opacity = opacity
    return l
end

function grid_draw!(look::LayerLook, style::Core.LayerStyle, d::GridLayerData, cam::Camera, opacity::Float32)::GridDraw
    lo, hi = Core.stretch_range(style, d.hist)
    table = style.stretch === :histeq ? equalized!(look, d) : nothing
    level = grid_level(d, cam.res)
    sx, sy, sz = Core.sun_vector(style.inclination, style.declination)
    sun = (Float32(sx), Float32(sy), Float32(sz))
    z = Float32(isnan(style.zfactor) ? Core.auto_zfactor(d.mean_gradient) : style.zfactor)
    nearest = style.resample === :nearest
    g = look.grid
    if g === nothing
        g = GridDraw(d, level, look.lut, lo, hi, table, opacity, style.shade, sun, z, nearest)
        look.grid = g
        return g
    end
    g.data = d
    g.level = level
    g.lut = look.lut
    g.lo = lo
    g.hi = hi
    g.table = table
    g.opacity = opacity
    g.shade = style.shade
    g.sun = sun
    g.zfactor = z
    g.nearest = nearest
    return g
end

# The equalization table of `d`'s histogram, made again only for another build of the data.
function equalized!(look::LayerLook, d::Union{LineLayerData,GridLayerData})::Vector{Float32}
    if look.eq_data !== d || look.eq_version != d.version
        Core.equalize_table!(look.eq, d.hist)
        look.eq_data = d
        look.eq_version = d.version
    end
    return look.eq
end

"""
    refresh_plan!(ms, app, mv)

Make the list of the shown map's visible layers (`ms.plan`) again when the snapshot, the map
or the app's grid colours changed, or when a layer had no entry yet. Each layer gets its entry,
its effective style (`Core.effective_style`) and its `LayerLook`, whose look-up table is made
again when the colour table or its direction changed. Looks of layers not in the list go.
"""
function refresh_plan!(ms, app, mv)
    snap = app.snap
    colours = app.config.grid_colours
    (ms.plan_complete && ms.plan_snap === snap && ms.plan_map == mv.id && ms.plan_colours == colours) &&
        return nothing
    empty!(ms.plan)
    complete = true
    used = Set{String}()
    for l in mv.layers
        l.visible || continue
        e = get(ms.entries, layer_key(snap, mv, l), nothing)
        e === nothing && (complete = false)
        gv = l.kind == :grid ? get(snap.grids, l.item, nothing) : nothing
        style = Core.effective_style(l, gv === nothing ? nothing : gv.style, colours)
        id = string(mv.id, "/", l.id)
        look = get!(LayerLook, ms.looks, id)
        if look.lut_name != style.colours || look.lut_reverse != style.reverse || isempty(look.lut)
            lut_rgba!(look.lut, style.colours, style.reverse)
            look.lut_name = style.colours
            look.lut_reverse = style.reverse
        end
        push!(ms.plan, LayerPlan(l, e, look, style))
        push!(used, id)
    end
    filter!(kv -> first(kv) in used, ms.looks)
    ms.plan_snap = snap
    ms.plan_map = mv.id
    ms.plan_colours = colours
    ms.plan_complete = complete
    return nothing
end
