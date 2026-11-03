# The map's layer data and its loader.
#
# A second task of the worker (`run_loader`) reads and builds layer data, one load at a time.
# It opens its own database or grid from the item's folder and touches no `Session`, so a big
# load never holds up the worker's actions, such as an undo. The render thread starts loads
# (`update_layers!`) and swaps the results in (`handle_result!`).
#
# Each layer keeps two buffers: `data`, the one drawn, and `spare`, which the next load builds
# into. The spare goes to the loader only when nothing draws from it any more (`spare_free`).

"""
What a layer's data is built from: the item, its `kind` (`:lines` or `:grid`), the colour
`channel` (`\"\"` for none), the database's current pair `x`, `y` (`\"\"` for a grid or none)
and the map's coordinate system `crs`.
"""
struct LayerKey
    item::String
    kind::Symbol
    channel::String
    x::String
    y::String
    crs::String
end

"""
The data of one layer key.

- `data`: the build drawn now, or `nothing`; `revision`: the item revision it was read at
  (-1 before the first load).
- `wanted`: the item revision of the last load started (-1 for none).
- `spare`: the build the next load builds into, or `nothing`. Out on loan while `loading`.
- `error`: why the last load failed, or a note on the data, such as a grid drawn without
  reprojection; `\"\"` for none. `seconds`: how long the last load took.
"""
mutable struct LayerEntry
    key::LayerKey
    revision::Int
    wanted::Int
    data::Union{Nothing,LineLayerData,GridLayerData}
    spare::Union{Nothing,LineLayerData,GridLayerData}
    loading::Bool
    error::String
    seconds::Float64
end

LayerEntry(key::LayerKey) = LayerEntry(key, -1, -1, nothing, nothing, false, "", 0.0)

"""
    MapState(session)

The map's layer data. Changed on the render thread only.

- `entries`: the data of each layer key that a map of the snapshot uses.
- `gl`: the GL objects of the map pass, or `nothing` before the first map pass (made on the
  render thread). Uploads are queued only when it exists (see `queue_all_uploads!`).
- `session`: the session the entries belong to; a load of another session is dropped.
- `freed`: keys whose GL objects the next `update_layers!` frees (set by `set_session!`).
- `seen`: the snapshot whose maps `update_layers!` last checked for unused entries.
- `dropped`: how many loads of another session came back and were dropped (tests read it).
- `hold`: a test hook. While it is set, each load started waits for a `put!` on it.
"""
mutable struct MapState
    entries::Dict{LayerKey,LayerEntry}
    gl::Union{Nothing,GlMap}
    session::Union{Nothing,Core.Session}
    freed::Vector{LayerKey}
    seen::Any
    dropped::Int
    hold::Union{Nothing,Channel{Nothing}}
end

MapState(session::Union{Nothing,Core.Session}) =
    MapState(Dict{LayerKey,LayerEntry}(), nothing, session, LayerKey[], nothing, 0, nothing)

# A load for the loader task. `folder` is the item's absolute folder; `name` its name.
struct LayerLoad
    session::Core.Session
    key::LayerKey
    revision::Int
    folder::String
    name::String
    spare::Union{Nothing,LineLayerData,GridLayerData}
    hold::Union{Nothing,Channel{Nothing}}
    window::Any
end

"""
A load that came back: the data built (`nothing` when it failed), the error or note
(`\"\"` for none) and how long it took.
"""
struct LayerLoaded
    session::Core.Session
    key::LayerKey
    revision::Int
    data::Union{Nothing,LineLayerData,GridLayerData}
    error::String
    seconds::Float64
end

# --- The loader task ---

# Run the loads one at a time until the inbox closes. Never throws.
function run_loader(inbox::Channel{Any}, results::Channel{Any})
    bands = Matrix{Float64}[]   # read buffers of Float64 grids, kept between loads
    for req in inbox
        req isa LayerLoad && run_load(req, results, bands)
    end
    return nothing
end

function run_load(req::LayerLoad, results::Channel{Any}, bands::Vector{Matrix{Float64}})
    try
        req.hold === nothing || take!(req.hold)
        msg = with_bug_reports(results) do
            load_layer(req, bands)
        end
        put!(results, msg)
    catch e
        report_problem(results, "The map loader failed", e, catch_backtrace())
    end
    notify_window(req.window, results)
    return nothing
end

# Build the layer. An error becomes the message's text, as `user_message` gives it.
function load_layer(req::LayerLoad, bands::Vector{Matrix{Float64}})::LayerLoaded
    t = time()
    data, note = try
        build_layer(req, bands)
    catch e
        e isa InterruptException && rethrow()
        nothing, safe_user_message(e, catch_backtrace())
    end
    return LayerLoaded(req.session, req.key, req.revision, data, note, time() - t)
end

function build_layer(req::LayerLoad, bands::Vector{Matrix{Float64}})
    isdir(req.folder) || throw(ArgumentError("The folder of $(req.name) is missing."))
    k = req.key
    if k.kind == :lines
        d = req.spare isa LineLayerData ? req.spare : LineLayerData()
        return build_lines!(d, Core.open_database(req.folder), k, req.name), ""
    end
    d = req.spare isa GridLayerData ? req.spare : GridLayerData()
    g = Core.open_grid(req.folder)
    build_grid!(d, g, bands)
    note = (isempty(g.crs) || isempty(k.crs) || g.crs == k.crs) ? "" :
        "This grid is in $(g.crs), not in the map's $(k.crs). It is drawn without reprojection."
    return d, note
end

function build_lines!(d::LineLayerData, db::Core.LineDatabase, k::LayerKey, name::String)::LineLayerData
    (isempty(k.x) || isempty(k.y)) && throw(ArgumentError("$name has no current X, Y pair."))
    for c in (k.x, k.y, k.channel)
        (isempty(c) || Core.channel_position(db, c) != 0) || throw(ArgumentError("Channel $c is not in $name."))
    end
    q = findfirst(p -> p.x == k.x && p.y == k.y, db.pairs)
    from = q === nothing ? "" : db.pairs[q].crs
    r = (isempty(from) || isempty(k.crs) || from == k.crs) ? nothing : Core.Reprojector(from, k.crs)
    try
        value = isempty(k.channel) ? nothing : k.channel
        pts = Core.read_line_points(db, k.x, k.y, value; into = d.points, reproject = r)
        return build_line_layer!(d, pts)
    finally
        r === nothing || close(r)
    end
end

function build_grid!(d::GridLayerData, g::Core.Grid, bands::Vector{Matrix{Float64}})
    geo = GridGeo(g)
    if g.eltype === Float32
        build_grid_layer!(d, (buf, j1) -> Core.read_rows!(buf, g, j1), geo)
    else
        build_grid_layer!(d, (buf, j1) -> read_converted!(buf, g, j1, bands), geo)
    end
    return d
end

# Read rows `j1` on of a Float64 grid into the Float32 band `buf`, through a kept buffer.
function read_converted!(buf::Matrix{Float32}, g::Core.Grid, j1::Int, bands::Vector{Matrix{Float64}})
    k = findfirst(b -> size(b) == size(buf), bands)
    k === nothing && (push!(bands, Matrix{Float64}(undef, size(buf))); k = length(bands))
    src = Core.read_rows!(bands[k], g, j1)
    copy_values!(buf, src)
    return buf
end

function copy_values!(dst::Matrix{Float32}, src::Matrix{Float64})
    @inbounds for i in eachindex(dst, src)
        dst[i] = Float32(src[i])
    end
    return dst
end

# --- The render thread ---

"""
    layer_key(snap, mv, layer) -> LayerKey

The key of a layer of map view `mv`: for lines, with the database's current pair from the snapshot.
"""
function layer_key(snap, mv, l::Core.MapLayer)::LayerKey
    l.kind == :grid && return LayerKey(l.item, :grid, "", "", "", mv.crs)
    x = y = ""
    v = get(snap.databases, l.item, nothing)
    if v !== nothing && 1 <= v.current_pair <= length(v.pairs)
        q = v.pairs[v.current_pair]
        x, y = q.x, q.y
    end
    return LayerKey(l.item, l.kind, l.channel, x, y, mv.crs)
end

"""
    spare_free(ms, e) -> Bool

May entry `e`'s spare be built into? Only when nothing draws from it: today the GPU
(`gpu_uses`). An entry with no spare is free: the load makes a new one.
"""
function spare_free(ms::MapState, e::LayerEntry)::Bool
    sp = e.spare
    gl = ms.gl
    (sp === nothing || gl === nothing) && return true
    return !gpu_uses(gl, sp)
end

"""
    update_layers!(app)

Start the loads the shown map needs. Call it on the render thread each frame, after
`drain!` and `refresh!`.

Every visible layer of the map `app.ui.current_map` gets an entry. One whose data was read
at another item revision than the snapshot's gets a load, when none runs for it and its
spare is free (`spare_free`); else it waits for a later frame. Meanwhile it keeps
drawing its old data. When the snapshot changes, entries no map uses are dropped and their
GL objects freed.
"""
function update_layers!(app)
    ms = app.map
    if !isempty(ms.freed)
        gl = ms.gl
        gl === nothing || foreach(k -> free_layer!(gl, k), ms.freed)
        empty!(ms.freed)
    end
    snap = app.snap
    snap === nothing && return nothing
    if ms.seen !== snap
        ms.seen = snap
        drop_unused!(ms, snap)
    end
    ms.session === nothing && return nothing
    mv = get(snap.maps, app.ui.current_map, nothing)
    mv === nothing && return nothing
    for l in mv.layers
        l.visible || continue
        key = layer_key(snap, mv, l)
        e = get(ms.entries, key, nothing)
        e === nothing && (e = ms.entries[key] = LayerEntry(key))
        rev = get(snap.item_revisions, l.item, 0)
        (e.loading || e.wanted == rev || !spare_free(ms, e)) && continue
        start_load!(app, e, rev)
    end
    return nothing
end

# Drop the entries no map of the snapshot uses, and free their GL objects.
function drop_unused!(ms::MapState, snap)
    used = Set{LayerKey}()
    for mv in values(snap.maps), l in mv.layers
        push!(used, layer_key(snap, mv, l))
    end
    gl = ms.gl
    for k in collect(keys(ms.entries))
        k in used && continue
        delete!(ms.entries, k)
        gl === nothing || free_layer!(gl, k)
    end
    return nothing
end

function start_load!(app, e::LayerEntry, rev::Int)
    ms = app.map
    snap = app.snap
    k = findfirst(it -> it.id == e.key.item, snap.items)
    e.wanted = rev
    if k === nothing
        set_data!(ms, e, nothing)
        e.revision = rev
        e.error = "There is no item $(e.key.item) in the project."
        return nothing
    end
    row = snap.items[k]
    spare = e.spare
    e.spare = nothing   # on loan until the load comes back
    e.loading = true
    put!(app.queue.map_inbox, LayerLoad(ms.session, e.key, rev, joinpath(snap.folder, row.path), row.name,
        spare, ms.hold, app.window))
    return nothing
end

# Make `d` the entry's data and the old data its spare, and queue the uploads (or free the
# GPU layer when there is no data). One step, so the GPU never draws a build being rebuilt.
function set_data!(ms::MapState, e::LayerEntry, d::Union{Nothing,LineLayerData,GridLayerData})
    old = e.data
    e.data = d
    old === nothing || (e.spare = old)
    gl = ms.gl
    if d === nothing
        gl === nothing || free_layer!(gl, e.key)
    else
        d.version += 1
        gl === nothing || queue_uploads!(gl, e.key, d)
    end
    return nothing
end

"""
    queue_all_uploads!(ms)

Queue the uploads of every entry that has data. Call it when `ms.gl` is made, or made again.
"""
function queue_all_uploads!(ms::MapState)
    gl = ms.gl::GlMap
    for e in values(ms.entries)
        d = e.data
        d === nothing || queue_uploads!(gl, e.key, d)
    end
    return nothing
end

function handle_result!(app, m::LayerLoaded)
    ms = app.map
    if m.session !== ms.session
        ms.dropped += 1
        return nothing
    end
    e = get(ms.entries, m.key, nothing)
    e === nothing && return nothing   # no map uses it any more
    e.loading = false
    e.revision = m.revision
    e.error = m.error
    e.seconds = m.seconds
    set_data!(ms, e, m.data)
    return nothing
end
