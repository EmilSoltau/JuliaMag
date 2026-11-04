# The map camera and its pure helpers: no window, no GL.
# World units are metres (or degrees). Screen units are device pixels from the top-left
# of the view, y down.

"""
    Camera(cx, cy, res)

The view centre `(cx, cy)` in world units and `res` world units per device pixel.
`res` is clamped to `MIN_RES:MAX_RES`; a `NaN` res is 1.
"""
struct Camera
    cx::Float64
    cy::Float64
    res::Float64
    Camera(cx::Real, cy::Real, res::Real) = new(cx, cy, isnan(res) ? 1.0 : clamp(res, MIN_RES, MAX_RES))
end

world_to_screen(c::Camera, w, h, x, y)::NTuple{2,Float64} =
    (w / 2 + (x - c.cx) / c.res, h / 2 - (y - c.cy) / c.res)

screen_to_world(c::Camera, w, h, sx, sy)::NTuple{2,Float64} =
    (c.cx + (sx - w / 2) * c.res, c.cy - (sy - h / 2) * c.res)

wheel_factor(notches::Real)::Float64 = exp(notches * WHEEL_POINTS * 0.0028)

# Zoom by `factor` with the world point under `(sx, sy)` kept in place.
function zoom_at(c::Camera, factor, sx, sy, w, h)::Camera
    grab = screen_to_world(c, w, h, sx, sy)
    return pan_to(Camera(c.cx, c.cy, c.res / factor), grab, sx, sy, w, h)
end

pan_px(c::Camera, dx, dy)::Camera = Camera(c.cx - dx * c.res, c.cy + dy * c.res, c.res)

# The camera of the same `res` that puts the world point `grab` under `(sx, sy)`.
pan_to(c::Camera, grab::NTuple{2,Float64}, sx, sy, w, h)::Camera =
    Camera(grab[1] - (sx - w / 2) * c.res, grab[2] + (sy - h / 2) * c.res, c.res)

# The camera that shows `ext = (xmin, ymin, xmax, ymax)` with `pad` of the span on each side.
function fit_extent(ext::NTuple{4,Float64}, w, h; pad = EXTENT_PAD)::Camera
    sw = max(ext[3] - ext[1], 1.0)
    sh = max(ext[4] - ext[2], 1.0)
    res = max(sw * (1 + 2pad) / w, sh * (1 + 2pad) / h)
    return Camera((ext[1] + ext[3]) / 2, (ext[2] + ext[4]) / 2, res)
end

# The extent that holds both, skipping an empty (NaN) one. `nothing` if both are empty.
function union_extent(a::NTuple{4,Float64}, b::NTuple{4,Float64})::Union{Nothing,NTuple{4,Float64}}
    ea = any(isnan, a)
    eb = any(isnan, b)
    ea && eb && return nothing
    ea && return b
    eb && return a
    return (min(a[1], b[1]), min(a[2], b[2]), max(a[3], b[3]), max(a[4], b[4]))
end

# `(cx, cy, sx, sy)` for the shader rule `ndc = (pos - c) * s`, where `pos` is the
# Float32 offset of a point from the layer `origin`.
gl_transform(c::Camera, origin::NTuple{2,Float64}, w, h)::NTuple{4,Float32} =
    (Float32(c.cx - origin[1]), Float32(c.cy - origin[2]), Float32(2 / (w * c.res)), Float32(2 / (h * c.res)))

# --- Extent history (back and forward) ---

mutable struct ExtentHistory
    past::Vector{Camera}
    future::Vector{Camera}
end
ExtentHistory() = ExtentHistory(Camera[], Camera[])

# Remember `before` as a step back. A new step ends the forward trail.
function record_extent!(h::ExtentHistory, before::Camera)
    empty!(h.future)
    (isempty(h.past) || last(h.past) != before) && push!(h.past, before)
    length(h.past) > HISTORY_LIMIT && popfirst!(h.past)
    return h
end

function previous_extent!(h::ExtentHistory, current::Camera)::Union{Nothing,Camera}
    isempty(h.past) && return nothing
    push!(h.future, current)
    return pop!(h.past)
end

function next_extent!(h::ExtentHistory, current::Camera)::Union{Nothing,Camera}
    isempty(h.future) && return nothing
    push!(h.past, current)
    return pop!(h.future)
end

# --- Scale bar and axis ticks ---

# The 1, 2 or 5 times a power of ten that is at least (`up`) or at most `x`.
function nice_pick(x::Float64, up::Bool)::Float64
    (isfinite(x) && x > 0) || return 1.0
    k = floor(Int, log10(x))
    best = 0.0
    # One decade below and above covers rounding in log10.
    for kk in (k - 1, k, k + 1), m in (1, 2, 5)
        v = kk >= 0 ? m * 10.0^kk : m / 10.0^(-kk)
        if up
            v >= x && (best == 0.0 || v < best) && (best = v)
        else
            v <= x && v > best && (best = v)
        end
    end
    return best
end

nice_step(x::Float64)::Float64 = nice_pick(x, true)

function scale_bar(res, target_px, unit::AbstractString)::NamedTuple{(:world, :px, :label),Tuple{Float64,Float64,String}}
    world = nice_pick(Float64(target_px * res), false)
    label = if unit == "m"
        world >= 1000 ? string(short_num(world / 1000), " km") : string(short_num(world), " m")
    elseif isempty(unit)
        short_num(world)
    else
        string(short_num(world), " ", unit)
    end
    return (world = world, px = world / res, label = label)
end

# Fill `out` with the multiples of the step in `[lo, hi]`; none when a limit is not finite.
# Returns the step.
function tick_values!(out::Vector{Float64}, lo, hi, min_px, res)::Float64
    step = nice_step(Float64(min_px * res))
    empty!(out)
    (isfinite(lo) && isfinite(hi)) || return step
    i0 = ceil(Int, lo / step)
    i1 = floor(Int, hi / step)
    for i in i0:i1
        push!(out, i * step)
    end
    return step
end

coord_text(v, step)::String = fmt_num(v, max(0, -floor(Int, log10(step))))
