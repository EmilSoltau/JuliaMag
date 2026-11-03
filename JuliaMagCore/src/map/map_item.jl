# A map item: a folder with `map.json`. It holds the layers of a map and how
# each is styled. The data of a layer stays in its database or grid.
#
# Layers are in draw order: `layers[1]` draws first, at the bottom.

using JSON3, StructTypes

"An error in a map: a missing or broken file."
struct MapError <: Exception
    msg::String
end

Base.showerror(io::IO, e::MapError) = print(io, "MapError: ", e.msg)

const MAP_FILE = "map.json"
const MAP_VERSION = 1
const LAYER_KINDS = (:lines, :grid)
const STRETCHES = (:linear, :clip, :histeq)
const RESAMPLES = (:nearest, :bilinear)

"""
How a layer is coloured. A line layer uses `colours`, `stretch` and the limits only.

- `stretch` is `:linear` (from `min` to `max`, `NaN` means the data's), `:clip`
  (cut `clip_low` and `clip_high` percent, each 0 to 49) or `:histeq`.
- `inclination` (0 to 90) and `declination` (degrees clockwise from north) give the
  sun of the shading. `zfactor` is `NaN` for automatic, else above 0.
"""
Base.@kwdef mutable struct LayerStyle
    colours::String = "geosoft"
    stretch::Symbol = :histeq
    min::Float64 = NaN
    max::Float64 = NaN
    clip_low::Float64 = 0.5
    clip_high::Float64 = 0.5
    reverse::Bool = false
    shade::Bool = false
    inclination::Float64 = 45.0
    declination::Float64 = 45.0
    zfactor::Float64 = NaN
    resample::Symbol = :bilinear
end

Base.:(==)(a::LayerStyle, b::LayerStyle) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(LayerStyle))
Base.hash(a::LayerStyle, h::UInt) = hash(Tuple(getfield(a, f) for f in fieldnames(LayerStyle)), h)

"A copy of a style."
Base.copy(st::LayerStyle) = LayerStyle((getfield(st, f) for f in fieldnames(LayerStyle))...)

"""
One layer of a map. `item` is a database (`:lines`) or a grid (`:grid`).
`channel` is the colour channel of a line layer, `""` for one plain colour.
A grid layer with `own_style = false` uses the default style of its grid.
"""
mutable struct MapLayer
    id::String
    item::String
    kind::Symbol
    channel::String
    visible::Bool
    opacity::Float64
    labels::Bool
    own_style::Bool
    style::LayerStyle
end

Base.:(==)(a::MapLayer, b::MapLayer) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(MapLayer))
Base.hash(a::MapLayer, h::UInt) = hash(Tuple(getfield(a, f) for f in fieldnames(MapLayer)), h)

"A copy of a layer, with its own style."
function Base.copy(l::MapLayer)
    return MapLayer(l.id, l.item, l.kind, l.channel, l.visible, l.opacity, l.labels, l.own_style, copy(l.style))
end

"A map: its coordinate system and its layers. `next_layer` numbers the next layer id."
mutable struct MapItem
    folder::String
    name::String
    crs::String
    layers::Vector{MapLayer}
    next_layer::Int
end

Base.show(io::IO, m::MapItem) = print(io, "MapItem(", repr(m.name), ", ", length(m.layers), " layers)")

"""
Throw `ArgumentError` when `st` is not a style a layer can have: a colour table
that does not exist, a stretch or resample method that is not known, or a number
out of its range.
"""
function check_style(st::LayerStyle)
    st.colours in first.(colour_tables()) ||
        throw(ArgumentError("the colour table \"$(st.colours)\" is not known"))
    st.stretch in STRETCHES ||
        throw(ArgumentError("the stretch must be one of $(join(STRETCHES, ", ")), not $(repr(st.stretch))"))
    st.resample in RESAMPLES ||
        throw(ArgumentError("the resample method must be one of $(join(RESAMPLES, ", ")), not $(repr(st.resample))"))
    for (k, v) in (("clip_low", st.clip_low), ("clip_high", st.clip_high))
        (isfinite(v) && 0 <= v <= 49) || throw(ArgumentError("$k must be from 0 to 49 percent, not $v"))
    end
    (isfinite(st.inclination) && 0 <= st.inclination <= 90) ||
        throw(ArgumentError("inclination must be from 0 to 90 degrees, not $(st.inclination)"))
    isfinite(st.declination) || throw(ArgumentError("declination must be a finite number, not $(st.declination)"))
    (isnan(st.zfactor) || (isfinite(st.zfactor) && st.zfactor > 0)) ||
        throw(ArgumentError("zfactor must be above 0 or NaN for automatic, not $(st.zfactor)"))
    for (k, v) in (("min", st.min), ("max", st.max))
        (isnan(v) || isfinite(v)) || throw(ArgumentError("$k must be a finite number or NaN, not $v"))
    end
    return nothing
end

# ---- map.json ----------------------------------------------------------------

struct StyleRecord
    colours::String
    stretch::String
    min::Float64
    max::Float64
    clip_low::Float64
    clip_high::Float64
    reverse::Bool
    shade::Bool
    inclination::Float64
    declination::Float64
    zfactor::Float64
    resample::String
end
StructTypes.StructType(::Type{StyleRecord}) = StructTypes.Struct()

struct LayerRecord
    id::String
    item::String
    kind::String
    channel::String
    visible::Bool
    opacity::Float64
    labels::Bool
    own_style::Bool
    style::StyleRecord
end
StructTypes.StructType(::Type{LayerRecord}) = StructTypes.Struct()

"The content of `map.json`."
struct MapRecord
    version::Int
    name::String
    crs::String
    next_layer::Int
    layers::Vector{LayerRecord}
end
StructTypes.StructType(::Type{MapRecord}) = StructTypes.Struct()

map_path(folder::AbstractString) = joinpath(folder, MAP_FILE)

StyleRecord(st::LayerStyle) =
    StyleRecord(st.colours, String(st.stretch), st.min, st.max, st.clip_low, st.clip_high, st.reverse, st.shade,
                st.inclination, st.declination, st.zfactor, String(st.resample))

LayerRecord(l::MapLayer) =
    LayerRecord(l.id, l.item, String(l.kind), l.channel, l.visible, l.opacity, l.labels, l.own_style,
                StyleRecord(l.style))

"""
    create_map(folder, name; crs = "") -> MapItem

Make a new map with no layers in `folder` and write `map.json`.
The folder is created when needed.
"""
function create_map(folder::AbstractString, name::AbstractString; crs::AbstractString = "")::MapItem
    m = MapItem(String(folder), String(name), String(crs), MapLayer[], 1)
    mkpath(m.folder)
    save_map(m)
    return m
end

"Write `map.json` of `m` atomically (see `write_json_atomic`)."
function save_map(m::MapItem)
    rec = MapRecord(MAP_VERSION, m.name, m.crs, m.next_layer, LayerRecord[LayerRecord(l) for l in m.layers])
    write_json_atomic(map_path(m.folder), rec; allow_inf = true)
    return nothing
end

"""
    open_map(folder) -> MapItem

Open the map in `folder`. Throws `MapError` when `map.json` is missing or broken.
"""
function open_map(folder::AbstractString)::MapItem
    path = map_path(folder)
    isfile(path) || throw(MapError("no map in $folder: $MAP_FILE is missing"))
    broken(why) = MapError("$MAP_FILE in $folder is broken: $why")
    rec = try
        JSON3.read(read(path, String), MapRecord; allow_inf = true)
    catch e
        e isa InterruptException && rethrow()
        throw(broken(sprint(showerror, e)))
    end
    rec.version == MAP_VERSION ||
        throw(MapError("$MAP_FILE in $folder has version $(rec.version); this program reads version $MAP_VERSION"))
    layers = MapLayer[]
    for r in rec.layers
        kind = Symbol(r.kind)
        kind in LAYER_KINDS || throw(broken("layer $(r.id) has the unknown kind \"$(r.kind)\""))
        s = r.style
        st = LayerStyle(s.colours, Symbol(s.stretch), s.min, s.max, s.clip_low, s.clip_high, s.reverse, s.shade,
                        s.inclination, s.declination, s.zfactor, Symbol(s.resample))
        try
            check_style(st)
        catch e
            e isa ArgumentError || rethrow()
            throw(broken("layer $(r.id): $(e.msg)"))
        end
        (0 <= r.opacity <= 1) || throw(broken("layer $(r.id) has the opacity $(r.opacity)"))
        push!(layers, MapLayer(r.id, r.item, kind, r.channel, r.visible, r.opacity, r.labels, r.own_style, st))
    end
    allunique(l.id for l in layers) || throw(broken("two layers have the same id"))
    return MapItem(String(folder), rec.name, rec.crs, layers, rec.next_layer)
end

"""
Open the map of item `id`. Its name is the name of the item.
Throws `ProjectError` if it cannot, and `MapError` for a broken file.
"""
function map_item(p::Project, id::AbstractString)::MapItem
    it = item(p, id)
    it.kind == ITEM_MAP || throw(ProjectError("item \"$id\" is not a map"))
    item_missing(p, it) && throw(ProjectError("the folder of map \"$id\" is missing: $(item_path(p, it))"))
    m = open_map(item_path(p, it))
    m.name = it.name
    return m
end

"""
    default_colour_channel(db, pair) -> String

The channel a new line layer colours by: the first channel in database order that
is numeric, not an array, not an axis of `pair`, and has role none, Z or
elevation. `""` when there is none.
"""
function default_colour_channel(db::LineDatabase, pair::PositionPair)::String
    for c in db.channels
        (c.eltype <: Number && c.arraylen == 1) || continue
        (c.name == pair.x || c.name == pair.y) && continue
        c.role in (ROLE_NONE, ROLE_Z, ROLE_ELEVATION) && return c.name
    end
    return ""
end
