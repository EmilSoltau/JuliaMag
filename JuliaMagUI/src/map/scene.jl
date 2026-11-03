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
value (and of every point when the layer has no channel) and the opacity.
"""
struct LineDraw
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
"""
struct GridDraw
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

# The hash of the style values of a layer, after its data's identity, version and level.
function layer_key(l::LineDraw, h::UInt)::UInt
    h = hash(:line, h)
    h = hash(objectid(l.data), h)
    h = hash(l.data.version, h)
    h = hash(l.level, h)
    h = hash(l.lut, h)
    h = hash(l.lo, h)
    h = hash(l.hi, h)
    h = hash(l.table, h)
    h = hash(l.plain, h)
    return hash(l.opacity, h)
end

function layer_key(l::GridDraw, h::UInt)::UInt
    h = hash(:grid, h)
    h = hash(objectid(l.data), h)
    h = hash(l.data.version, h)
    h = hash(l.level, h)
    h = hash(l.lut, h)
    h = hash(l.lo, h)
    h = hash(l.hi, h)
    h = hash(l.table, h)
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
