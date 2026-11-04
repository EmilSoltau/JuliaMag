# JuliaMag Plan 4a: Map View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A map view in the central area that draws line databases and grids of a project fast, with layers, styles, a shared cursor and a point readout, on the graphics card when it can and on the CPU when it cannot.

**Architecture:** The core gets a map item (a list of layers with styles, undoable and in the script), a typed plain-read bulk reader for line positions, colour table values, fine histograms and per-item change counters.
The UI prepares GPU-ready plain data (line levels, grid tiles) on a worker-owned loader task, and the render thread only uploads and draws it.
The map draws with an OpenGL pass between `ig.Render()` and `RenderDrawData` into a texture that ImGui shows; a pure Julia CPU renderer draws the same scene when that pass cannot run, and is the reference in the tests.
When a full redraw costs more than one frame, the map shows the last full image moved and scaled during a gesture and redraws once the gesture settles.

**Tech Stack:** Julia 1.12, CImGui.jl 10.1 (Dear ImGui 1.93 docking), GLFW.jl 3.4, ModernGL.jl 1 (OpenGL 3.3 core, GLSL 330), ImGuiTestEngine.jl 3, PNGFiles.jl 0.4, `JuliaMagCore` with Proj.jl, plus Aqua and JET.

**Spec:** `docs/superpowers/specs/2026-10-28-juliamag-foundation-design.md` (sections 5.3 "Selection and cursor", 5.4, 5.5, 8.2, 9.1 Map tab, 9.2 Layers tab, 9.3 Map view, 9.6, 10, 12, 13.2, 14).
UI reference: `prototype/juliamag-ui.html` (map view lines 358-375, Layers tab lines 434-438 and 2250-2300, Map tab lines 1684-1714, status bar lines 1981-2010) and `docs/research/ui-prototype.md` sections 3 "Map", 4.2, 8.5, 10.
Research for this plan (copied into the repo in Task 1, Step 1): `docs/research/map-oasis.md`, `docs/research/map-rustgis.md`, `docs/research/map-julia.md`; earlier: `docs/research/oasis-map.md`, `oasis-grid-and-image.md`, `ui-rustgis.md`, `ui-cimgui.md`, `ui-core-api.md`.
Spike (measured techniques this plan reuses): `spike4a/spike.jl` and its results for an Intel iGPU (`results.txt`) and for Mesa llvmpipe (`results-llvmpipe.txt`), copied with the research.
Follow-ups: `docs/superpowers/plans/2026-10-28-plan-1-followups.md`, section "Left for later from plan 3".

## The plans

| Plan | Delivers |
|---|---|
| 1. Core | Done |
| 2. Grids | Done |
| 3. UI shell | Done |
| **4a. Map view (this plan)** | Map items with layers and styles, the map view with pan and zoom, line and grid layers, Layers tab, Layer Style pane, shared cursor, point readout, scale bar and ticks, GPU and CPU drawing |
| 4b. Data views | Database view, profile view, statistics pane, following the shared cursor |
| 4c. Import and coordinates | CSV import wizard, coordinate system picker with EPSG search |
| 5. Packaging | Prebuilt app for Windows and Linux, loading tool packages while running |

## Global Constraints

From plan 3, unchanged:

- Julia 1.12 or newer. The app runs with `julia -t auto,1`: the render loop is on thread 1, jobs, the worker queue and the map loader on the default pool.
- `JuliaMagCore` stays free of UI and graphics packages (spec 13.3). Every UI dependency goes into `JuliaMagUI/Project.toml`.
- `JuliaMagUI` uses `import JuliaMagCore as Core`, never `using JuliaMagCore`.
- **The UI never freezes (spec 10, 12).**
- **Colours come from tokens only.** No widget code has a colour literal. Colour table values (data, not UI colours) are the one exception, and they live in the core.
- **Sizes come from the prototype**, in logical pixels, scaled by the content scale through `px`.
- UI text: plain English, short, no em dash character, sentence case for messages, title case for command names ("Show on Map", "Zoom to Layer").
- Errors from the core never end the app: they become a toast, a layer error in the Layers tab, or a failed job card, with the core's own message (spec 8.2).
- Every change to project data goes through an undoable core call. The UI keeps no project data of its own. A camera position is view state, not project data.
- Tests: `JuliaMagUI` has its own `Pkg.test()` with Aqua and JET (`target_modules = (JuliaMagUI,)`). Logic tests need no window.
- Lint, all core tests and all UI tests pass before each commit. Test output has no warnings. Tests never use the network.
- Commit messages: plain, no co-author lines.

New for plan 4a:

- **Render-thread rule (binding).** The render thread reads only the `Snapshot`, `Core.status(job)`, `job.progress[]`, plain data handed to it by the worker or the map loader, and pure or registry-only core calls (`Core.colour_table`, `Core.colour_tables`, `Core.stretch_range`, `Core.colour_position`, `Core.effective_style`, `Core.auto_zfactor`, `Core.sun_vector`, `Core.quantile_value`, `Core.equalize_table!` on a layer's own histogram and table, and `Core.line_name`). Everything that touches a `Session`, a file or item data runs through `submit!` on the serial worker, or on the worker-owned map loader task (Task 9), whose results come back through `app.queue.results`.
- **Plain reads, never memory maps, for the map.** Map data is read with `Core.block_reader`/`read_block` and `Core.read_rows!` into buffers the map owns. A map never keeps a view of a mapped file: on Windows a mapped file blocks undo, append and rename (`database.jl` "memory maps").
- **Function barriers.** Every loop over channel values runs in a function whose arguments have concrete types (`read_channel` is loosely typed; the spike measured 6.3 s without a barrier and 0.13 s with one for 20 M points).
- **No allocation while the map draws.** Building a scene, the draw lists, the GL pass and the transformed-image path allocate nothing per frame after warm-up (tests pin `@allocated == 0`). The loader reuses its buffers (two per layer: the one drawn and a spare). GC pauses from loader allocations reached 70 ms in the spike.
- **Upload budget.** The render thread uploads at most one grid tile or one line batch (at most `UPLOAD_BYTES = 8 * 2^20` bytes) per frame, coarse levels first, and draws what is ready.
- **The GL map pass** runs in `draw_frame!` between `ig.Render()` and `ImGui_ImplOpenGL3_RenderDrawData`, inside its own `try ... finally` that binds framebuffer 0 and restores the viewport, program 0, vertex array 0, texture 0 and active texture unit 0. `ImDrawList` is used only for small overlays.
- **World coordinates are Float64; GPU data is Float32 offsets from a Float64 origin per layer** (UTM northings near 7,000,000 m have 0.5 m Float32 spacing). The view transform is `ndc = (pos - c) * s` with `c` and `s` computed in Float64 and rounded once.
- **Headless UI tests only.** UI tests run only as `LIBGL_ALWAYS_SOFTWARE=1 bin/test-headless.sh` (Xvfb with Mesa llvmpipe). Never open a window on the user's desktop. Core tests: `~/.juliaup/bin/julia --project=JuliaMagCore -e 'using Pkg; Pkg.test()'`.
- Map constants (one place each, `JuliaMagUI/src/map/constants.jl` unless the task says the core):
  - wheel zoom factor `exp(notches * WHEEL_POINTS * 0.0028)` with `WHEEL_POINTS = 50` (points per wheel notch, as RustGIS's scroll delta);
  - zoom to extent pads each side by `EXTENT_PAD = 0.06` of the span; a degenerate span counts as 1 world unit;
  - `MIN_RES = 0.01`, `MAX_RES = 1e7` world units per device pixel;
  - a gesture settles `SETTLE = 0.15` s after the last input; `FRAME_BUDGET = 1/60` s;
  - extent history keeps at most 50 entries each way;
  - line levels: buckets 1, 8, 64, 512, 4096 (`LOD_FACTOR = 8`), at most `POINT_BUDGET = 0.5` drawn points per view pixel;
  - culling margin: half the view size on each side (`CULL_MARGIN = 0.5`);
  - grid tiles `TILE = 2048` cells plus a 1-cell border on each side, `GL_R32F`;
    Note: 2-cell border (`TILE_BORDER = 2`) by Task 14b ruling (2026-11-03); tiles hold only used cells plus the border.
  - histogram `HIST_BINS = 4096` (core), equalization table 1024 entries (core), colour tables 256 entries (core);
  - hillshade: Oasis defaults inclination 45, declination 45; light `(cosd(inc) sind(dec), cosd(inc) cosd(dec), sind(inc))`; vertical scale auto `2.5 / mean gradient`; colour times `0.25 + 0.75 h`;
  - percent clip default 0.5 low and 0.5 high;
  - pick and readout radius 20 logical px; at most 300 line labels per frame.

## Review Focus

These inputs are not named by the spec but will reach real users first.
Each has a test in the task that owns the code.

1. **A line whose X and Y are all missing** (a failed GPS line): the reader gives it no parts and a NaN extent, the layer draws the other lines, full extent and zoom to layer ignore it, and picking never returns it (Tasks 3, 5).
2. **A grid that is entirely dummy:** it loads, draws nothing, its legend says "No values", the readout shows "-", zoom to layer uses its corners, and no draw error is noted (Tasks 6, 10).
3. **A project with 2000 lines opened while a map is shown:** the old project's layers and GPU objects are dropped, a load of the old project that comes back late is ignored, and the new map loads without a draw error (Task 9).
4. **The window resized during a gesture:** the world point under the mouse stays under it during a pan, the map image follows the new size, and the finished gesture adds one extent to the history (Task 10).
5. **The GL map pass failing mid-session:** the map switches to the CPU renderer, says so once in a toast, framebuffer 0 and the viewport are restored in the same frame, and a full picture is back within 2 s (Task 11).

---

## File structure

```
JuliaMag/
  JuliaMagCore/src/
    map/map_item.jl              # LayerStyle, MapLayer, MapItem, map.json (Task 1)
    session/map_edits.jl         # new_map!, add_layer!, remove_layer!, move_layer!, set_layer! (Task 1)
    display/colours.jl           # colour_table, effective_style, sun_vector, auto_zfactor (Task 2)
    display/histogram.jl         # ValueHistogram, stretch_range, colour_position (Task 2)
    storage/line_points.jl       # LinePoints, read_line_points (Task 3)
  JuliaMagCore/test/
    support/maps.jl              # survey_database!, add_test_grid!
    test_maps.jl, test_display.jl, test_line_points.jl
  JuliaMagUI/src/map/
    constants.jl                 # the map constants of the Global Constraints
    camera.jl                    # Camera, transforms, ExtentHistory, nice steps (Task 4)
    lines.jl                     # LineLayerData, levels, culling, PointIndex (Task 5)
    grids.jl                     # GridLayerData, levels, tiles, sampling (Task 6)
    scene.jl                     # Scene, LineDraw, GridDraw (Task 7), build_scene! (Task 10)
    cpu.jl                       # render_cpu! (Task 7)
    shaders.jl, gl.jl            # GlMap, probe, uploads, gl_draw! (Task 8)
    loader.jl                    # LayerKey, LayerEntry, MapState, loads (Task 9)
    view.jl                      # MapViewState, gestures, map_gl_pass!, draw_map_view (Task 10)
    frame.jl                     # MapRenderer, mode choice, adaptive frames, fallback (Task 11)
    overlays.jl                  # scale bar, ticks, legends, nav buttons, labels, cursor (Tasks 10, 15)
  JuliaMagUI/src/commands/map_commands.jl   # Map tab and Show on Map (Task 12)
  JuliaMagUI/src/panes/layers.jl            # Layers tab (Task 13)
  JuliaMagUI/src/panes/style.jl             # Layer Style pane (Task 14)
  JuliaMagUI/test/test_map_*.jl, window/test_map_*.jl
  bench/map_frame.jl                         # survey-sized benchmark (Task 16)
  docs/research/map-*.md
```

---

## Part A: core

### Task 1: Map items

**Files:**
- Create: `JuliaMagCore/src/map/map_item.jl`, `JuliaMagCore/src/session/map_edits.jl`, `JuliaMagCore/test/support/maps.jl`, `JuliaMagCore/test/test_maps.jl` (added to `runtests.jl` after `test_grid_properties.jl`; `support/maps.jl` included after `support/synthetic.jl`)
- Create: `docs/research/map-oasis.md`, `map-rustgis.md`, `map-julia.md` and `docs/research/spike4a/` (`spike.jl`, `results.txt`, `results-llvmpipe.txt`)
- Modify: `JuliaMagCore/src/project/project.jl` (`PROJECT_SUBFOLDERS` gets `"maps"`, `map_item`), `src/history/script.jl`, `src/JuliaMagCore.jl`

**Interfaces:**
- Consumes: `Session`, `check_open`, `check_not_busy`, `push_undo!`, `UndoStep`, `record!`, `set_items!`, `remove_unused_folders!`, `write_json_atomic`, `new_item_id`, `add_item!`, `database`, `grid`, `colour_tables`.
- Produces:
  - `Base.@kwdef mutable struct LayerStyle` with `colours::String = "geosoft"`, `stretch::Symbol = :histeq` (`:linear`, `:clip`, `:histeq`), `min::Float64 = NaN`, `max::Float64 = NaN` (`:linear`; NaN means the data's), `clip_low::Float64 = 0.5`, `clip_high::Float64 = 0.5` (percent, `:clip`, each 0 to 49), `reverse::Bool = false`, `shade::Bool = false`, `inclination::Float64 = 45.0` (0 to 90), `declination::Float64 = 45.0` (degrees clockwise from north), `zfactor::Float64 = NaN` (NaN means auto, else above 0), `resample::Symbol = :bilinear` (`:nearest`, `:bilinear`). Lines use the colour and stretch fields only. `==` compares field by field with `isequal`.
  - `mutable struct MapLayer`: `id::String` (`"layer-N"`, unique in its map), `item::String`, `kind::Symbol` (`:lines` or `:grid`), `channel::String` (lines: the colour channel, `""` for one plain colour; grids: `""`), `visible::Bool`, `opacity::Float64` (0 to 1), `labels::Bool`, `own_style::Bool` (grids: false means the grid's default style, spec 5.4; lines: always true), `style::LayerStyle`.
  - `mutable struct MapItem`: `folder::String`, `name::String`, `crs::String`, `layers::Vector{MapLayer}` (draw order: `layers[1]` draws first, at the bottom), `next_layer::Int`.
  - `struct MapError <: Exception; msg::String; end`; `const MAP_FILE = "map.json"`; `create_map(folder, name; crs = "")::MapItem`, `open_map(folder)::MapItem` (throws `MapError` for a missing or broken file), `save_map(m)` (atomic, with `write_json_atomic`).
  - `map_item(p::Project, id)::MapItem`, as `grid(p, id)`.
  - `default_colour_channel(db::LineDatabase, pair::PositionPair)::String`: the first channel in database order that is numeric, not an array, not `pair.x` or `pair.y`, and has role `ROLE_NONE`, `ROLE_Z` or `ROLE_ELEVATION`; else `""`.
  - Session edits. Each calls `check_open`, takes `s.lock`, refuses a busy map with `ItemBusyError`, saves `map.json`, pushes one `UndoStep` whose `items` is `[map_id]`, and is recorded. Args always hold `"item" => map_id`.
    - `new_map!(s; name = "")::String`: a map item in `maps/<id>/`. A blank name becomes `"Map N"`, the lowest N no map item uses. Undo takes the item out; redo puts it back; the step's `commit` deletes the folder at close when the item is out (as `remove_item!`). Recorded as `"map.new"` with `"name"` and `outputs = [id]`.
    - `add_layer!(s, map_id, item_id; channel = nothing)::String`: a layer for a database (`:lines`) or a grid (`:grid`). For a database, `channel = nothing` takes `default_colour_channel` of its current pair; a given channel must be a numeric non-array channel, else `ArgumentError`. A database with no current pair is refused with `ArgumentError("database <name> has no current X, Y pair")`. A grid takes no channel. A new line layer goes on top; a new grid layer goes above the other grid layers and below every line layer. Line layers get `labels = true` and `style = LayerStyle()`; grid layers `own_style = false`. When the map's `crs` is `""`, it becomes the pair's or grid's coordinate system, in the same undo step. Recorded as `"map.add_layer"` with `"source" => item_id` and `"channel"` (the resolved name).
    - `remove_layer!(s, map_id, layer_id)`: recorded as `"map.remove_layer"` with `"layer"`.
    - `move_layer!(s, map_id, layer_id, position::Int)`: `position` is the new index in draw order (1 is the bottom). Recorded as `"map.move_layer"`.
    - `set_layer!(s, map_id, layer_id; visible = nothing, opacity = nothing, channel = nothing, labels = nothing, own_style = nothing, style = nothing)`: changes the given fields only. Checks: opacity in 0 to 1; a channel as in `add_layer!`; a style through `check_style(st)` (colours one of `first.(colour_tables())`, stretch, clip percents in 0 to 49, inclination in 0 to 90, declination finite, zfactor NaN or above 0, resample). A call that changes nothing pushes no step and records nothing. Recorded as `"map.set_layer"` with the given keywords; a style as a `Dict` of its fields (symbols as strings).
    - An unknown map or layer id throws `ArgumentError` with a plain message. Removing an item that layers use keeps the layers.
  - Script: the five commands are core commands: `new_map!(s; name = "Map 1")`, `add_layer!(s, map_1, db_1; channel = "MAG")`, `remove_layer!(s, map_1, "layer-2")`, `move_layer!(s, map_1, "layer-1", 2)`, `set_layer!(s, map_1, "layer-1"; opacity = 0.5, style = LayerStyle(colours = "viridis", ...))` (the style with all fields as keywords, sorted). An entry of a core command with outputs binds them as `map_1 = new_map!(s; name = "Map 1")` (not `.outputs`). `bind_items` binds `"source"` as it binds `"item"`.
  - Export: `LayerStyle, MapLayer, MapItem, MapError, MAP_FILE, create_map, open_map, save_map, map_item, default_colour_channel, new_map!, add_layer!, remove_layer!, move_layer!, set_layer!`.
  - Test helpers (`test/support/maps.jl`):
    - `survey_database!(s; lines = 3, rows = 5, x0 = 500_000.0, y0 = 7_000_000.0, dx = 10.0, dy = 50.0, crs = "EPSG:32755", nan_line = 0)::String`: lines L1001, L1002, ... with `X = x0 + (r - 1) * dx`, `Y = y0 + (l - 1) * dy`, `MAG = 100l + r`, fiducial start 0.0 and step 0.1; X and Y have roles `ROLE_X` and `ROLE_Y`; pair X, Y with `crs` is current (through `add_pair!`). No channel is protected. With `nan_line = k`, line k's X and Y are all NaN.
    - `add_test_grid!(s, A::Matrix{Float32}; dx = 10.0, x0 = 500_000.0, y0 = 7_000_000.0, crs = "EPSG:32755", name = "Grid", units = "nT")::String`: a grid item with values `A`, `vmin`, `vmax` and `count` set.

- [ ] **Step 1: Copy the research.** Copy `plan4a-research-oasis.md`, `plan4a-research-rustgis.md` and `plan4a-research-julia.md` from this session's scratchpad to `docs/research/map-oasis.md`, `map-rustgis.md` and `map-julia.md`, and `spike4a/spike.jl`, `spike4a/out/results.txt` and `spike4a/out/results-llvmpipe.txt` to `docs/research/spike4a/`. The controller gives the paths in the dispatch.
- [ ] **Step 2: Write the failing tests**

```julia
s = fresh_session()
db = survey_database!(s)
g = add_test_grid!(s, Float32[i + 10j for i in 1:4, j in 1:3])
m = new_map!(s)
@test m == "map-1" && item(s.project, m).kind == ITEM_MAP && item(s.project, m).name == "Map 1"
@test isfile(joinpath(s.project.folder, "maps", m, MAP_FILE))
@test item(s.project, new_map!(s)).name == "Map 2"
l1 = add_layer!(s, m, db)
mi = map_item(s.project, m)
@test l1 == "layer-1" && only(mi.layers).kind == :lines && only(mi.layers).channel == "MAG"
@test mi.crs == "EPSG:32755" && only(mi.layers).labels && only(mi.layers).opacity == 1.0
l2 = add_layer!(s, m, g)
@test [l.id for l in map_item(s.project, m).layers] == ["layer-2", "layer-1"]   # grid below lines
@test !map_item(s.project, m).layers[1].own_style
set_layer!(s, m, l1; opacity = 0.5, style = LayerStyle(colours = "viridis"))
L = map_item(s.project, m).layers[2]
@test L.opacity == 0.5 && L.style.colours == "viridis" && s.history[end].command == "map.set_layer"
undo!(s)
L = map_item(s.project, m).layers[2]
@test L.opacity == 1.0 && L.style.colours == "geosoft"
move_layer!(s, m, l1, 1); @test [l.id for l in map_item(s.project, m).layers] == ["layer-1", "layer-2"]
remove_layer!(s, m, l2); @test [l.id for l in map_item(s.project, m).layers] == ["layer-1"]
undo!(s); @test length(map_item(s.project, m).layers) == 2
n = length(s.undo_stack); set_layer!(s, m, l1; visible = true); @test length(s.undo_stack) == n
@test_throws ArgumentError add_layer!(s, m, db; channel = "NOPE")
@test_throws ArgumentError set_layer!(s, m, l1; opacity = 1.5)
@test_throws ArgumentError set_layer!(s, m, "layer-9"; visible = false)
@test_throws ArgumentError set_layer!(s, m, l1; style = LayerStyle(colours = "nope"))
@test_throws ArgumentError set_layer!(s, m, l1; style = LayerStyle(clip_low = 50.0))
remove_item!(s, db); @test any(l -> l.item == db, map_item(s.project, m).layers)
undo!(s)
@test default_colour_channel(database(s.project, db), PositionPair("X", "Y", "")) == "MAG"
```

Also:
- `open_map(folder)` after `save_map` gives equal fields (round trip, including NaN `min`, `max` and `zfactor`).
- `undo!` of `new_map!` takes the item out and `redo!` puts it back; closing the session with the map undone deletes `maps/map-N`.
- `script_text(s)` contains `map_1 = new_map!(s; name = "Map 1")` and `add_layer!(s, map_1, `; the script of a session that used all five calls replays on the same project (as the replay tests in `test_followups.jl`) and makes a map with the same layer ids, order and styles.
- A database with no current pair is refused by `add_layer!` with the message above.

- [ ] **Step 3: Run to see it fail.** `~/.juliaup/bin/julia --project=JuliaMagCore -e 'using Pkg; Pkg.test()'`, expected: `UndefVarError: survey_database!` or `new_map!`.
- [ ] **Step 4: Implement.** Map edits follow `edit_grid_meta!` (`builtin/grid_properties.jl`): getter, setter, `apply(v)` closures that take `s.lock` themselves, because `undo!` runs steps without it. A style is copied on every get and set.
- [ ] **Step 5: Run to see it pass**, with all earlier core tests unchanged.
- [ ] **Step 6: Commit** `git commit -m "Add map items with layers and styles, undoable and in the script"`

---

### Task 2: Colour tables, histograms and stretches

**Files:**
- Create: `JuliaMagCore/src/display/colours.jl`, `src/display/histogram.jl`, `test/test_display.jl`
- Modify: `src/storage/grid.jl` (`colour_tables` order and labels, `GridStyle()` colours), `src/JuliaMagCore.jl`, `JuliaMagUI/src/app/config.jl` (`grid_colours` default), `JuliaMagUI/test/test_config.jl`, `JuliaMagUI/test/support/state.jl` (the test tool's colour choices)

**Interfaces:**
- Consumes: Task 1 `LayerStyle`, `MapLayer`; `GridStyle`.
- Produces (all pure, safe on the render thread):
  - `colour_tables()` returns, in this order: `"geosoft" => "Geosoft (colour.tbl)"`, `"viridis" => "Viridis"`, `"turbo" => "Turbo"`, `"rainbow" => "Rainbow"`, `"blue-red" => "Blue-Red"`, `"grey" => "Grey"`. `GridStyle()` uses `"geosoft"`; `AppConfig().grid_colours == "geosoft"`.
  - `colour_table(name::AbstractString)::Vector{NTuple{3,UInt8}}` with 256 entries; `ArgumentError` for an unknown name. Entry k is at `t = (k - 1) / 255`, each channel `round(UInt8, ...)` of a linear blend between stops:
    - `"geosoft"`, stops `(0.0, (0, 0, 160))`, `(0.17, (0, 120, 255))`, `(0.33, (0, 220, 220))`, `(0.5, (60, 220, 60))`, `(0.67, (250, 240, 0))`, `(0.83, (255, 110, 0))`, `(1.0, (230, 0, 160))` (the spike's table);
    - `"viridis"`: matplotlib's 256 values (`_viridis_data`), scaled by 255 and rounded;
    - `"turbo"`: Google's 256 values (`turbo_colormap_data`), scaled and rounded;
    - `"rainbow"`: HSV with hue from 240 to 0 degrees, full saturation and value;
    - `"blue-red"`: stops `(0.0, (0, 0, 255))`, `(0.5, (255, 255, 255))`, `(1.0, (255, 0, 0))`;
    - `"grey"`: `(k - 1, k - 1, k - 1)`.
  - `mutable struct ValueHistogram`: `lo::Float64`, `hi::Float64`, `counts::Vector{Int}` (`HIST_BINS = 4096`), `total::Int`. `ValueHistogram(lo, hi)`; `ValueHistogram()` is empty with NaN limits. `reset!(h, lo, hi)` (no allocation). `add_values!(h, v::AbstractVector{<:Real})` skips NaN and `ismissingvalue` values; a value at `hi` goes in the last bin.
  - `quantile_value(h, p)::Float64`: the value below which a fraction `p` of the values lie, linear inside a bin; NaN when `total == 0`.
  - `equalize_table(h; n = 1024)::Vector{Float32}`: entry k is the fraction of values below `lo + (k - 1) / (n - 1) * (hi - lo)`, linear inside bins; non-decreasing; last entry `1f0`. `equalize_table!(out, h)` writes into `out`.
  - `stretch_range(st::LayerStyle, h)::NTuple{2,Float64}`: `:linear`: `(min, max)` with NaN replaced by `h.lo`, `h.hi`; `:clip`: `(quantile_value(h, clip_low / 100), quantile_value(h, 1 - clip_high / 100))`; `:histeq`: `(h.lo, h.hi)`.
  - `colour_position(v, lo, hi, table::Union{Nothing,AbstractVector{Float32}})::Float32`: NaN for NaN `v`; `0.5f0` when `lo == hi` or either is NaN; else `t = clamp((v - lo) / (hi - lo), 0, 1)`, then through `table` with linear interpolation at `t * (length(table) - 1)` when given.
  - `effective_style(layer::MapLayer, grid_style::Union{Nothing,GridStyle}, app_colours::AbstractString)::LayerStyle`: `layer.style` when `layer.own_style` or `grid_style === nothing`. Else from the grid style: colours (a grid style that still has the stock table `GridStyle().colours` uses `app_colours`, the app's "Grid colours" setting, spec 9.6), `method` `:linear` to `:linear` with its `min` and `max`, any other method to `:histeq`, `reverse`, `shade`, `altitude` to `inclination`, `azimuth` to `declination`, `zfactor` (the stock `GridStyle().zfactor` becomes NaN, auto), and `resample = layer.style.resample`.
  - `auto_zfactor(mean_gradient::Real)::Float64 = 2.5 / mean_gradient`, and `1.0` when the gradient is NaN or not above 0 (Oasis "2.5 over the mean of the gradient").
  - `sun_vector(inclination, declination)::NTuple{3,Float64}`.
  - Export all of the above and `HIST_BINS`.

- [ ] **Step 1: Write the failing tests**

```julia
@test first.(colour_tables()) == ["geosoft", "viridis", "turbo", "rainbow", "blue-red", "grey"]
@test GridStyle().colours == "geosoft"
g = colour_table("geosoft")
@test length(g) == 256 && g[1] == (0x00, 0x00, 0xa0) && g[129] == (62, 220, 59) && g[256] == (230, 0, 160)
@test colour_table("viridis")[1] == (68, 1, 84) && colour_table("viridis")[256] == (253, 231, 37)
@test colour_table("turbo")[1] == (48, 18, 59) && colour_table("turbo")[256] == (122, 4, 3)
@test colour_table("rainbow")[1] == (0, 0, 255) && colour_table("rainbow")[256] == (255, 0, 0)
@test colour_table("grey")[256] == (255, 255, 255) && colour_table("blue-red")[129][3] > 0xf0
@test_throws ArgumentError colour_table("nope")
h = ValueHistogram(0.0, 100.0); add_values!(h, collect(0.01:0.01:100.0)); add_values!(h, [NaN])
@test h.total == 10_000 && length(h.counts) == 4096
@test isapprox(quantile_value(h, 0.005), 0.5; atol = 0.05) && isapprox(quantile_value(h, 0.995), 99.5; atol = 0.05)
lo, hi = stretch_range(LayerStyle(stretch = :clip), h); @test isapprox(lo, 0.5; atol = 0.05) && isapprox(hi, 99.5; atol = 0.05)
@test stretch_range(LayerStyle(stretch = :linear), h) == (0.0, 100.0)
@test stretch_range(LayerStyle(stretch = :linear, min = 10.0, max = 20.0), h) == (10.0, 20.0)
t = equalize_table(h); @test length(t) == 1024 && issorted(t) && t[end] == 1f0
@test maximum(abs.(t .- range(0, 1; length = 1024))) < 0.01
k = ValueHistogram(0.0, 100.0); add_values!(k, vcat(zeros(1000), fill(100.0, 10)))
@test isapprox(equalize_table(k)[512], 1000 / 1010; atol = 0.002)
@test colour_position(50.0, 0.0, 100.0, nothing) == 0.5f0 && colour_position(150.0, 0.0, 100.0, nothing) == 1f0
@test isnan(colour_position(NaN, 0.0, 1.0, nothing)) && colour_position(3.0, 3.0, 3.0, nothing) == 0.5f0
@test isnan(quantile_value(ValueHistogram(0.0, 1.0), 0.5))
ly = MapLayer("layer-1", "grid-1", :grid, "", true, 1.0, false, false, LayerStyle())
e = effective_style(ly, GridStyle("viridis", :linear, 1.0, 9.0, true, true, 300.0, 30.0, 2.0), "geosoft")
@test (e.colours, e.stretch, e.min, e.max, e.reverse, e.shade, e.declination, e.inclination, e.zfactor) ==
      ("viridis", :linear, 1.0, 9.0, true, true, 300.0, 30.0, 2.0)
e2 = effective_style(ly, GridStyle(), "turbo"); @test e2.colours == "turbo" && e2.stretch == :histeq && isnan(e2.zfactor)
@test auto_zfactor(4.0) == 0.625 && auto_zfactor(0.0) == 1.0 && auto_zfactor(NaN) == 1.0
@test all(isapprox.(sun_vector(45, 45), (0.5, 0.5, sqrt(0.5)); atol = 1e-12))
```

Also `(@allocated reset!(h, 0.0, 1.0)) == 0` and `(@allocated equalize_table!(t, h)) == 0` after a warm-up call; the UI config test expects `grid_colours == "geosoft"`.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** The viridis and turbo values are copied once into `colours.jl` as constant tables, with their sources and licences (matplotlib: CC0; turbo: Apache 2.0) in a comment.
- [ ] **Step 4: Run to see it pass**, core and UI suites.
- [ ] **Step 5: Commit** `git commit -m "Add colour table values, fine histograms and stretches, with the Geosoft table as the default"`

---

### Task 3: Bulk line reader and item change counters

**Files:**
- Create: `JuliaMagCore/src/storage/line_points.jl`, `test/test_line_points.jl`
- Modify: `src/session/session.jl` (field and readers), `src/session/undo.jl` (bumps), `src/JuliaMagCore.jl`

**Interfaces:**
- Consumes: `block_reader`, `read_block`, `LineDatabase`, `channel`, `missing_value`, `ismissingvalue`, `Reprojector`, `reproject!`.
- Produces:
  - `mutable struct LinePoints`:
    - `origin::NTuple{2,Float64}`: the first good point, each coordinate floored;
    - `x::Vector{Float32}`, `y::Vector{Float32}`: offsets from `origin` of every point with a good X and Y;
    - `value::Vector{Float32}`: the value channel at each point, NaN for a missing value or when there is no value channel;
    - parts, one per run of good points on a line, in line order: `part_first::Vector{Int32}` (0-based index of its first point), `part_count::Vector{Int32}`, `part_line::Vector{Int32}` (index into `lines`), `part_row::Vector{Int32}` (row on the line of its first point, from 1);
    - `lines::Vector{LineId}` (every line of the database, in order) and `extents::Vector{NTuple{4,Float64}}` per line, `(xmin, ymin, xmax, ymax)` of its good points in world coordinates, all NaN for a line with none.
  - `LinePoints()`: empty.
  - `read_line_points(db::LineDatabase, x::AbstractString, y::AbstractString, value::Union{Nothing,AbstractString} = nothing; into::LinePoints = LinePoints(), reproject::Union{Nothing,Reprojector} = nothing)::LinePoints`: plain reads in blocks of `1 << 16` rows with one reader per channel; `into` is filled with `resize!` and returned (no new arrays when it is big enough). A point is good when X and Y are not missing and, after `reproject`, finite. `value` must be a numeric non-array channel, else `ArgumentError`. Lines still being appended are skipped. Closes its readers on every path.
  - `item_revision(s, id)::Int`: how many changes item `id` has had in this session, 0 for an item never changed. Goes up by one for each id in `step.items` when `push_undo!` adds a step (also a held one) and when `undo!` or `redo!` ran a step. Guarded by `s.lock`.
  - `item_revisions(s)::Dict{String,Int}`: a copy, under `s.lock`.
  - Export `LinePoints, read_line_points, item_revision, item_revisions`.

- [ ] **Step 1: Write the failing tests**

```julia
s = fresh_session(); id = survey_database!(s; nan_line = 2)
db = database(s.project, id)
p = read_line_points(db, "X", "Y", "MAG")
@test p.origin == (500_000.0, 7_000_000.0) && length(p.x) == 10
@test p.part_line == Int32[1, 3] && p.part_row == Int32[1, 1] && p.part_count == Int32[5, 5]
@test p.x[1:5] == Float32[0, 10, 20, 30, 40] && p.y[6] == 100f0 && p.value[1:5] == Float32[101, 102, 103, 104, 105]
@test all(isnan, p.extents[2]) && p.extents[1] == (500_000.0, 7_000_000.0, 500_040.0, 7_000_000.0)
L = LineId(LINE, 1001, 0)
set_cell!(s, id, L, "X", 3, NaN); set_cell!(s, id, L, "MAG", 1, NaN)
q = read_line_points(database(s.project, id), "X", "Y", "MAG"; into = p)
@test q === p && q.part_row[1:2] == Int32[1, 4] && q.part_count[1:2] == Int32[2, 2] && isnan(q.value[1])
@test all(isnan, read_line_points(database(s.project, id), "X", "Y").value)
@test_throws ArgumentError read_line_points(database(s.project, id), "X", "Y", "NOPE")
r0 = item_revision(s, id)
set_cell!(s, id, L, "MAG", 2, 7.0); @test item_revision(s, id) == r0 + 1
undo!(s); @test item_revision(s, id) == r0 + 2 && item_revisions(s)[id] == r0 + 2
@test item_revision(s, "db-99") == 0
```

Also:
- A database whose every line has all X and Y missing gives no parts and all extents NaN, and no error.
- A reprojected read (`Reprojector("EPSG:4326", "EPSG:32755")` on a lon/lat survey) gives the same points as `reproject_xy` within 1 mm.
- After a warm-up, a second read of a 200,000-point database into the same `LinePoints` allocates under 100 KB (`@allocated`; the readers and file handles only).

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** The block loop calls `pack_block!(p, xs, ys, vs, ...)` with the concrete block types (function barrier). Value channels of integer types become `Float32` with missing values as NaN.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Read line positions in bulk with plain reads, and count changes per item"`

---

## Part B: map data and drawing (no window)

### Task 4: Camera, view transform and extent history

**Files:**
- Create: `JuliaMagUI/src/map/constants.jl`, `src/map/camera.jl`, `test/test_map_camera.jl`
- Modify: `src/JuliaMagUI.jl` (includes), `test/runtests.jl`

**Interfaces:**
- Produces (pure):
  - `struct Camera; cx::Float64; cy::Float64; res::Float64; end` (centre in world units, world units per device pixel; `res` clamped to `MIN_RES:MAX_RES` by every constructor below). Screen coordinates are device pixels from the view's top-left, y down.
  - `world_to_screen(c, w, h, x, y)::NTuple{2,Float64}`, `screen_to_world(c, w, h, sx, sy)::NTuple{2,Float64}`.
  - `wheel_factor(notches::Real)::Float64 = exp(notches * WHEEL_POINTS * 0.0028)`.
  - `zoom_at(c, factor, sx, sy, w, h)::Camera`: `res / factor`, the world point under `(sx, sy)` fixed.
  - `pan_px(c, dx, dy)::Camera = Camera(c.cx - dx * c.res, c.cy + dy * c.res, c.res)`.
  - `pan_to(c, grab::NTuple{2,Float64}, sx, sy, w, h)::Camera`: the camera of the same `res` that puts world point `grab` under `(sx, sy)`. Pans use it, so a resize during a drag keeps the grabbed point under the mouse.
  - `fit_extent(ext::NTuple{4,Float64}, w, h; pad = EXTENT_PAD)::Camera`: each side padded by `pad` times the span (a span under 1 world unit counts as 1).
  - `union_extent(a, b)` with NaN extents ignored; `nothing` when both are empty.
  - `gl_transform(c, origin::NTuple{2,Float64}, w, h)::NTuple{4,Float32}`: `(Float32(c.cx - origin[1]), Float32(c.cy - origin[2]), Float32(2 / (w * c.res)), Float32(2 / (h * c.res)))`, for the shader rule `ndc = (pos - c) * s`.
  - `mutable struct ExtentHistory; past::Vector{Camera}; future::Vector{Camera}; end`, `ExtentHistory()`; `record_extent!(h, before::Camera)` (pushes `before`, clears `future`, skips a camera equal to the last, keeps 50); `previous_extent!(h, current)::Union{Nothing,Camera}` (pops `past`, pushes `current` on `future`); `next_extent!(h, current)` the other way.
  - `nice_step(x::Float64)::Float64`: the smallest 1, 2 or 5 times a power of ten that is at least `x`.
  - `scale_bar(res, target_px, unit::AbstractString)::NamedTuple{(:world, :px, :label)}`: the largest 1, 2 or 5 times a power of ten at most `target_px * res`; label `"500 m"`, `"2 km"` (from 1000 m on, for unit `"m"`), `"0.05 deg"` for `"deg"`, the bare number for `""`.
  - `tick_values!(out::Vector{Float64}, lo, hi, min_px, res)::Float64`: fills `out` with the multiples of `nice_step(min_px * res)` in `[lo, hi]` and returns the step (no allocation once `out` is big enough).
  - `coord_text(v, step)::String`: `fmt_num(v, max(0, -floor(Int, log10(step))))` (thousands separators), such as `"501,000"`.

- [ ] **Step 1: Write the failing tests**

```julia
c = Camera(500_000.0, 7_000_000.0, 10.0)
@test world_to_screen(c, 800, 600, 500_000.0, 7_000_000.0) == (400.0, 300.0)
@test world_to_screen(c, 800, 600, 500_010.0, 7_000_010.0) == (401.0, 299.0)
@test all(isapprox.(screen_to_world(c, 800, 600, 401.0, 299.0), (500_010.0, 7_000_010.0)))
z = zoom_at(c, wheel_factor(1), 0, 0, 800, 600)
@test isapprox(z.res, 8.693582; rtol = 1e-6)
@test all(isapprox.(screen_to_world(z, 800, 600, 0, 0), screen_to_world(c, 800, 600, 0, 0); atol = 1e-6))
@test pan_px(c, 10, -20) == Camera(499_900.0, 6_999_800.0, 10.0)
f = fit_extent((0.0, 0.0, 1000.0, 500.0), 800, 600)
@test f.res == 1.4 && (f.cx, f.cy) == (500.0, 250.0)
p = fit_extent((5.0, 5.0, 5.0, 5.0), 800, 600); @test p.cx == 5.0 && isfinite(p.res) && p.res > 0
h = ExtentHistory(); a = Camera(0, 0, 1); b = Camera(1, 1, 1); now = Camera(2, 2, 1)
record_extent!(h, a); record_extent!(h, b); record_extent!(h, b)
@test length(h.past) == 2 && previous_extent!(h, now) == b && previous_extent!(h, b) == a
@test next_extent!(h, a) == b && (record_extent!(h, now); isempty(h.future))
@test nice_step(1300.0) == 2000.0 && nice_step(0.034) == 0.05
@test scale_bar(10.0, 130, "m") == (world = 1000.0, px = 100.0, label = "1 km")
out = Float64[]; @test tick_values!(out, 500_000.0, 508_000.0, 90, 10.0) == 1000.0 && length(out) == 9
@test coord_text(501_000.0, 1000.0) == "501,000" && coord_text(12.25, 0.05) == "12.25"
```

Golden test of the GPU transform: for each case `(res, offset)` in `((1000.0, 200_000.0), (1.0, 100_000.0), (0.01, 1_000.0))`, with the camera centre `offset` metres east and north of the layer origin `(512_000.0, 7_012_000.0)`, a 1584 by 955 view, and 1,000 points spread over the view: the point offsets rounded to Float32, run through `ndc = (pos - c) * s` in Float32 with `gl_transform`, then to pixels (`(ndc_x + 1) / 2 * w`, `(1 - ndc_y) / 2 * h`), match `world_to_screen` within 0.01 px.

- [ ] **Step 2: Run to see it fail.** `LIBGL_ALWAYS_SOFTWARE=1 bin/test-headless.sh`, expected: `UndefVarError: Camera`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Add the map camera, its GPU transform and the extent history"`

---

### Task 5: Line layer data: levels, culling and picking

**Files:**
- Create: `JuliaMagUI/src/map/lines.jl`, `test/test_map_lines.jl`

**Interfaces:**
- Consumes: Task 3 `Core.LinePoints`, Task 2 `Core.ValueHistogram`, Task 4 `Camera`.
- Produces:
  - `struct LineLevel`: `bucket::Int`, `x`, `y`, `v::Vector{Float32}`, `first`, `count::Vector{Int32}` (one per part, in the same order as the base parts).
  - `mutable struct LineLayerData`: `points::Core.LinePoints`, `levels::Vector{LineLevel}` (`levels[1]` shares the base arrays, bucket 1), `part_box::Vector{NTuple{4,Float32}}` (per part, relative to the origin), `hist::Core.ValueHistogram` (of `points.value`), `index::PointIndex`, `extent::Union{Nothing,NTuple{4,Float64}}`, `version::Int`.
  - `LineLayerData()` empty; `build_line_layer!(d, pts)::LineLayerData`: fills `d` from `pts` in place, reusing its arrays. Level k keeps, per bucket of `bucket` points of each part, the point with the lowest value and the one with the highest, in their order, plus the part's first and last point; a part with no values uses the coordinate across its longer side instead of the value. Buckets go up by `LOD_FACTOR` while a level has under 75 % of the points of the one before and the bucket is at most the longest part.
  - `choose_level(d, cam, w, h)::Int`: the finest level whose points in view (after culling) are at most `POINT_BUDGET * w * h`, else the coarsest.
  - `draw_list!(firsts::Vector{Int32}, counts::Vector{Int32}, d, level, cam, w, h)::Int`: the parts whose box meets the view grown by `CULL_MARGIN` of its size on each side; returns the points listed. No allocation once the vectors are big enough.
  - `PointIndex`: a uniform grid over the base points (about 8 points per cell), point ids sorted by cell (two `Int32` vectors). `nearest_point(d, x, y, radius)::Union{Nothing,NearPoint}` with `struct NearPoint; line::Int; row::Int; x::Float64; y::Float64; value::Float32; dist::Float64; end`.
  - `cursor_point(d, line_index, row)::Union{Nothing,NTuple{2,Float64}}`: the world position of that row, or `nothing` when it has no good point.
  - `label_points!(out::Vector{Tuple{Int,Float64,Float64}}, d)`: the first point of each line's first part.

- [ ] **Step 1: Write the failing tests**

```julia
# line_points(lines) is a test helper: a Core.LinePoints from (x, y, value) tuples, one vector per line
pts = line_points([[(500_000.0 + 10i, 7_000_000.0, i == 5001 ? 1000.0 : sin(i / 50)) for i in 1:10_000]])
d = build_line_layer!(LineLayerData(), pts)
@test [l.bucket for l in d.levels] == [1, 8, 64, 512, 4096]
@test all(l -> maximum(l.v) == 1000f0, d.levels)
@test all(l -> l.x[1] == pts.x[1] && l.x[end] == pts.x[end], d.levels)
cam = fit_extent(something(d.extent), 100, 100)
@test choose_level(d, cam, 100, 100) == 2 && choose_level(d, cam, 1000, 1000) == 1
two = build_line_layer!(LineLayerData(), line_points([[(0.0, 0.0, 1.0), (100.0, 0.0, 2.0)], [(0.0, 1000.0, 1.0), (100.0, 1000.0, 2.0)]]))
f, k = Int32[], Int32[]
@test draw_list!(f, k, two, 1, Camera(50.0, 0.0, 1.0), 200, 200) == 2 && f == Int32[0]
@test (@allocated draw_list!(f, k, two, 1, Camera(50.0, 0.0, 1.0), 200, 200)) == 0
np = nearest_point(two, 98.0, 999.0, 5.0)
@test np.line == 2 && np.row == 2 && nearest_point(two, 50.0, 500.0, 5.0) === nothing
@test cursor_point(two, 2, 2) == (100.0, 1000.0)
```

Margin: a part whose box lies 0.4 view widths left of the view is listed; at 0.6 view widths it is not.
Review Focus 1: a layer built from `survey_database!(s; nan_line = 2)` has `extent == (500_000.0, 7_000_000.0, 500_040.0, 7_000_100.0)` (line 2 ignored), never returns a point of line 2 from `nearest_point`, and `cursor_point(d, 2, 1) === nothing`; a layer where every line is missing has `extent === nothing` and every level empty.
A second `build_line_layer!` into the same `LineLayerData` with points of the same size allocates under 1 KB.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** The level builder is the spike's `decimate` technique (min and max per bucket, in order), written into reused arrays.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Build line levels that keep spikes, cull by box and find the nearest point"`

---

### Task 6: Grid layer data: levels, tiles and sampling

**Files:**
- Create: `JuliaMagUI/src/map/grids.jl`, `test/test_map_grids.jl`

**Interfaces:**
- Consumes: Task 2 `Core.ValueHistogram`, `Core.Grid` georeference (`x0, y0` the centre of the lower-left cell, `dx, dy`, `rotation` degrees counter-clockwise).
- Produces:
  - `struct GridGeo; nx::Int; ny::Int; x0::Float64; y0::Float64; dx::Float64; dy::Float64; rotation::Float64; end`; `GridGeo(g::Core.Grid)`.
  - `struct GridLevel`: `k::Int`, `nx::Int`, `ny::Int` (`ceil` halves of the level below), `tiles::Matrix{Matrix{Float32}}`: tile `(ti, tj)` is `(tile + 2)` by `(tile + 2)` cells, with a 1-cell border taken from the neighbours at the same level, NaN outside the grid. Levels go down to 1 by 1.
    Note: 2-cell border (`TILE_BORDER = 2`) by Task 14b ruling (2026-11-03); tiles hold only used cells plus the border.
  - `mutable struct GridLayerData`: `geo::GridGeo`, `tile::Int`, `levels::Vector{GridLevel}` (level 0 is the grid; the last is 1 by 1), `hist::Core.ValueHistogram`, `count::Int` (cells not NaN), `mean_gradient::Float64` (mean of `hypot(gx, gy)` from central differences over cells whose four neighbours are not NaN, in value units per world unit; NaN when there are none), `extent::NTuple{4,Float64}` (from the four corners), `version::Int`.
  - `build_grid_layer!(d, read_band!::Function, geo; tile = TILE)::GridLayerData`: `read_band!(buf, j1)` fills `buf` (`nx` by `n`, Float32) with rows `j1` on; the builder reads bands of `tile` rows (plus one border row), cuts level-0 tiles, adds to the histogram, then builds each level from the one below with NaN-aware 2 by 2 means (a 2 by 2 block of all NaN gives NaN), and cuts it into tiles with borders from that same level. Reuses `d`'s arrays.
  - `grid_level(d, res)::Int = clamp(floor(Int, log2(res / min(dx, dy))), 0, length(d.levels) - 1)`.
  - `level_cell(d, k, x, y)::NTuple{2,Float64}`: the fractional cell position at level k of world point `(x, y)`, with rotation (cell `(i, j)` centre at position `(i, j)`).
  - `cell_value(d, k, i, j)::Float32`: from the tile that holds the cell (NaN outside).
  - `grid_value(d, x, y; nearest::Bool)::Float32` at level 0: the nearest cell, or bilinear from four cells, NaN when any of the four is NaN (the Oasis readout rule).
  - `level_matrix(d, k)::Matrix{Float32}`: the level stitched from its tiles (tests only).

- [ ] **Step 1: Write the failing tests**

```julia
A = Float32[i + 10j for i in 1:5, j in 1:4]; A[1, 1] = NaN32
geo = GridGeo(5, 4, 100.0, 200.0, 10.0, 10.0, 0.0)
d = build_grid_layer!(GridLayerData(), (buf, j1) -> (buf .= A[:, j1:j1+size(buf, 2)-1]; buf), geo; tile = 2)
@test [(l.nx, l.ny) for l in d.levels] == [(5, 4), (3, 2), (2, 1), (1, 1)]
@test isequal(level_matrix(d, 0), A)
@test level_matrix(d, 1)[1, 1] == sum(Float32[A[2, 1], A[1, 2], A[2, 2]]) / 3
@test isnan(d.levels[1].tiles[1, 1][1, 2]) && d.levels[1].tiles[1, 1][4, 2] == A[3, 1]
@test d.count == 19 && d.hist.total == 19
@test grid_value(d, 110.0, 200.0; nearest = true) == A[2, 1]
@test grid_value(d, 115.0, 205.0; nearest = false) == sum(A[2:3, 1:2]) / 4
@test isnan(grid_value(d, 105.0, 205.0; nearest = false))
@test grid_level(d, 10.0) == 0 && grid_level(d, 25.0) == 1 && grid_level(d, 1e6) == 3
P = Float32[3 * 10 * (i - 1) for i in 1:50, j in 1:40]
dp = build_grid_layer!(GridLayerData(), (b, j1) -> (b .= P[:, j1:j1+size(b, 2)-1]; b), GridGeo(50, 40, 0.0, 0.0, 10.0, 10.0, 0.0))
@test isapprox(dp.mean_gradient, 3.0; rtol = 1e-6)
```

Seam fix: for a 37 by 29 grid of random values with some NaN, built with `tile = 4`, for every level and every cell, the four neighbours read through `cell_value` (which uses the cell's own tile and its border) equal the neighbours in `level_matrix` of the same level (`isequal`, so NaN matches NaN).
Rotation: for a grid with `rotation = 30.0`, `level_cell(d, 0, Core.cell_centre(g, 3, 2)...)` is `(3.0, 2.0)` within 1e-9.
Review Focus 2: an all-NaN grid builds without error, with `count == 0`, `hist.total == 0`, NaN `mean_gradient`, NaN from `grid_value`, and an `extent` from its corners.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** Levels are built and cut from the whole level, not per tile, so a border always holds the real neighbour at that level (this fixes the spike's hillshade seams, `spike4a` `crop_seam.png`). Cutting and means run with `Threads.@threads` over tiles.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Cut grids into bordered tiles at every level, without seams"`

---

### Task 7: Scene and CPU renderer

**Files:**
- Create: `JuliaMagUI/src/map/scene.jl`, `src/map/cpu.jl`, `test/test_map_cpu.jl`

**Interfaces:**
- Consumes: Tasks 2, 4, 5, 6.
- Produces:
  - `lut_rgba!(out::Vector{UInt8}, name, reverse::Bool)`: 256 RGBA entries (alpha 255) from `Core.colour_table`, reversed when asked; cached per `(name, reverse)` by the caller.
  - `struct LineDraw`: `data::LineLayerData`, `level::Int`, `lut::Vector{UInt8}`, `lo::Float32`, `hi::Float32`, `table::Union{Nothing,Vector{Float32}}` (equalization), `plain::NTuple{4,UInt8}` (colour of a point with no value, and of every point when the layer has no channel), `opacity::Float32`.
  - `struct GridDraw`: `data::GridLayerData`, `level::Int`, `lut`, `lo`, `hi`, `table`, `opacity`, `shade::Bool`, `sun::NTuple{3,Float32}`, `zfactor::Float32` (already resolved: auto is `Core.auto_zfactor(data.mean_gradient)`), `nearest::Bool`.
  - `mutable struct Scene`: `camera::Camera`, `width::Int`, `height::Int` (device px), `background::NTuple{4,UInt8}`, `layers::Vector{Union{LineDraw,GridDraw}}` (draw order), `key::UInt64`.
  - `scene_key(sc)::UInt64`: a hash of the camera, size, background and, per layer, its data `version`, level and every style value. Equal keys mean equal pictures.
  - The colour rule, the same in the CPU renderer and the shaders: `t = Core.colour_position(v, lo, hi, table)`; LUT entry `round(Int, t * 255) + 1`; NaN `t` gives `plain` for lines and transparent for grids.
  - Grid pixel rule: pixel centre `(px - 0.5, py - 0.5)` to world to `level_cell`; nearest: the cell's value; bilinear: four cells, NaN when any is NaN. Hillshade (when `shade`): central differences of the nearest cell's neighbours at the drawn level (a NaN neighbour counts as the centre value), divided by `2 * cell size at that level`, times `zfactor`; normal `normalize((-gx, -gy, 1))`; `h = max(dot(normal, sun), 0)`; colour times `0.25 + 0.75 * h`.
  - Line rule: each segment between two points of a part, 1 px wide, pixel centres on the segment by a DDA along the major axis; the value is interpolated along the segment and coloured per pixel.
  - Blending: `out = src * opacity + dst * (1 - opacity)` per channel, rounded with `round(UInt8, x)`.
  - `render_cpu!(img::Matrix{UInt32}, sc::Scene)`: RGBA8 packed little-endian (R in the low byte), `img[x, y]` with row 1 at the top. Rows are split over threads for grids. Allocates nothing but the threads' tasks.

- [ ] **Step 1: Write the failing tests**

```julia
A = Float32[i + 4(j - 1) for i in 1:4, j in 1:3]  # 4 by 3 cells, row 3 at the top
g = grid_data(A; x0 = 0.5, y0 = 0.5, dx = 1.0)    # test helper: build_grid_layer! on A
# rgba(u) is a test helper that unpacks a pixel into four UInt8
grey = lut_rgba!(zeros(UInt8, 1024), "grey", false)
sc = Scene(Camera(2.0, 1.5, 1.0), 4, 3, (0x00, 0x00, 0x00, 0xff),
    [GridDraw(g, 0, grey, 1f0, 12f0, nothing, 1f0, false, (0f0, 0f0, 1f0), 1f0, true)], 0)
img = zeros(UInt32, 4, 3); render_cpu!(img, sc)
@test rgba(img[1, 1]) == (0xb9, 0xb9, 0xb9, 0xff)      # cell (1, 3), value 9: round(8 / 11 * 255) = 185
@test rgba(img[4, 3]) == (0x46, 0x46, 0x46, 0xff)      # cell (4, 1), value 4: round(3 / 11 * 255) = 70
flat = grid_data(fill(5f0, 4, 3); x0 = 0.5, y0 = 0.5, dx = 1.0)
sh = Scene(Camera(2.0, 1.5, 1.0), 4, 3, (0x00, 0x00, 0x00, 0xff),
    [GridDraw(flat, 0, grey, 0f0, 10f0, nothing, 1f0, true, Float32.(Core.sun_vector(45, 45)), 1f0, true)], 0)
render_cpu!(img, sh); @test rgba(img[2, 2]) == (0x64, 0x64, 0x64, 0xff)   # 128 * (0.25 + 0.75 * 0.7071) = 99.9
half = Scene(sc.camera, 4, 3, sc.background, [GridDraw(g, 0, grey, 1f0, 12f0, nothing, 0.5f0, false, (0f0, 0f0, 1f0), 1f0, true)], 0)
render_cpu!(img, half); @test rgba(img[1, 1])[1] == 0x5c                  # 185 * 0.5 = 92.5 rounds to 92
```

Also:
- A NaN cell shows the background; a line of constant value across row 2 of a 4 by 3 view lights exactly the four pixels of row 2.
- A line value interpolates along the segment: a segment from value 0 to value 1 over 255 pixels with the grey table gives pixel k the grey `k - 1` within 1.
- The same scene rendered with 1 thread and with 4 threads gives equal images.
- `scene_key` changes with the camera, the size, a layer's `version` and each style value, and not otherwise.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Draw a map scene on the CPU, the reference for the GPU"`

---

## Part C: the map in the window

### Task 8: GL map pass

**Files:**
- Create: `JuliaMagUI/src/map/shaders.jl`, `src/map/gl.jl`, `test/window/test_map_gl.jl`
- Modify: `src/app/loop.jl` (the hook in `draw_frame!`)

**Interfaces:**
- Consumes: Task 7 `Scene`, `LineDraw`, `GridDraw`; the icon atlas upload pattern (`upload!` in `theme/icons.jl`: error checks against `GL_MAX_TEXTURE_SIZE` and `glGetError`).
- Produces:
  - `gl_pass(ui, w::Window)`: called by `draw_frame!` after `ig.Render()` and before `RenderDrawData`; `gl_pass(::Any, w) = nothing`; `gl_pass(f::AppFrame, w) = map_gl_pass!(f.app, w)` (Task 10). `draw_frame!` wraps the call in `try ... finally restore_gl_state(fb_w, fb_h)`, which binds framebuffer 0, sets the viewport to the framebuffer, and unbinds program, vertex array, array buffer and texture, with `GL_TEXTURE0` active.
  - `mutable struct GlMap`: programs (lines and grid), a colour texture and its FBO (resized in place with `glTexImage2D` on the same id, so ImGui's recorded id stays valid), LUT textures (256 by 1 RGBA8, `GL_NEAREST`) and table textures (1024 by 1 `GL_R32F`, `GL_LINEAR`) per layer, line buffers per layer and level (one VBO per batch of whole parts, at most `UPLOAD_BYTES`, interleaved `x, y, v` Float32), grid tile textures (`GL_R32F`, `GL_NEAREST`, base level only), two `GL_TIME_ELAPSED` queries in a ring, `pending::Vector{Upload}`, `uploaded_last_frame::Int` (bytes), `last_gpu_s::Float64`.
  - `probe_gl!(r::GlMap)::String`: `""` when the pass can run; else the reason, such as `"The framebuffer for the map is not complete."`, `"This graphics driver has no R32F textures."` or `"A map shader did not compile: <log>"`.
  - Shaders, GLSL `#version 330 core`:
    - lines: vertex `ndc = (pos - c) * s`; fragment colour by the shared colour rule from the interpolated value; `isnan(v)` gives `plain`.
    - grid: one quad per tile in grid-cell space, rotated by the grid rotation; the fragment fetches cells with `texelFetch` (nearest, or four cells for bilinear with the NaN rule), `discard` for NaN, colour and hillshade by Task 7's rules, alpha `opacity`.
    - Blending `GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA`; no MSAA; line width 1.
  - `queue_uploads!(r, layer_id, data)`: queues the layer's line batches (coarsest level first) or grid tiles (coarsest level first). `upload_step!(r)`: uploads at most one tile or one batch (at most `UPLOAD_BYTES`) per call; a `GL_OUT_OF_MEMORY` or other GL error makes the layer's error `"The graphics card has no room for this layer."` and frees what it uploaded.
  - `gl_draw!(r, sc)::UInt32`: draws the layers that are uploaded (a level not uploaded yet draws the finest level that is), returns the colour texture id. No allocation after warm-up: draw lists and uniform locations are kept in `r`.
  - `free_layer!(r, layer_id)`, `free_all!(r)`: delete GL objects; only on the render thread.
  - `read_texture(r)::Matrix{UInt32}` (tests): the colour texture in `render_cpu!`'s layout.

- [ ] **Step 1: Write the failing tests** (window tests in `window_testset`, GL work inside `on_render`)

- `probe_gl!` returns `""` on llvmpipe.
- Parity: a 300 by 200 view of a 600 by 400 grid (a plane plus a sine pattern, 2 % NaN cells, histeq with the geosoft table, hillshade on, bilinear) under 50 lines coloured by value: GL and CPU images have a mean absolute RGB error under 1.5/255, and zero structural outliers. A structural outlier is a pixel at least 1 px from the view edge that differs by more than 64/255 in a channel and has no pixel within 1 px in the other image that differs by at most 64/255. `PARITY_DUMP=<dir>` writes `cpu.png`, `gpu.png` and `diff.png`.
- The same parity check with nearest sampling and no shade, and with a level-2 view (zoomed out).
- After the pass, `GL_FRAMEBUFFER_BINDING` is 0 and `GL_VIEWPORT` is the framebuffer size; also after a pass that throws on purpose (a test hook that throws inside `gl_draw!`).
- `@allocated gl_draw!(r, sc)` is 0 after three warm-up calls.
- A line layer of 40 MB uploads over at least 5 frames with `uploaded_last_frame <= UPLOAD_BYTES` each frame, and the first batch uploaded belongs to the coarsest level; a grid's first tile uploaded belongs to its coarsest level.
- A test hook that makes `glTexImage2D` report `GL_OUT_OF_MEMORY` gives the layer error text above and no exception.

- [ ] **Step 2: Run to see it fail.** `LIBGL_ALWAYS_SOFTWARE=1 bin/test-headless.sh`.
- [ ] **Step 3: Implement.** Techniques from the spike: an FBO colour texture shown with `ig.Image`; `glMultiDrawArrays` with `GL_LINE_STRIP` per level; a new buffer per batch with `glBufferData` (the spike measured 25 to 50 ms per `glBufferSubData` into one big buffer on the Intel driver, and 1.5 to 2.5 ms per 4 to 8 MB new buffer); `GL_TIME_ELAPSED` queries read two frames later, so no stall.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Draw the map with an OpenGL pass between ImGui's render and draw"`

---

### Task 9: Map snapshot and layer loader

**Files:**
- Create: `JuliaMagUI/src/map/loader.jl`, `test/test_map_loader.jl`
- Modify: `src/app/state.jl` (snapshot types, `AppState.map`, `UiState.current_map::String = ""` (the map shown in the central area), `set_session!`), `src/app/worker.jl` (the loader task in `Worker`, `handle_result!` for its messages), `src/JuliaMagUI.jl` (the app frame calls `update_layers!` after `drain!` and `refresh!`), `test/support/state.jl` (`wait_layers`)

**Interfaces:**
- Consumes: Tasks 1, 3, 5, 6, 8; `cached_view`, `view_cache`, `user_message`, `wake!`.
- Produces:
  - Snapshot changes: `GridView` gets `style::Core.GridStyle` (a copy); `LineRow` gets `fid_start::Float64` and `fid_step::Float64`; new `MapView(id, name, crs, layers::Vector{Core.MapLayer} (copies), error::String)`; `Snapshot` gets `maps::Dict{String,MapView}` (read through `cached_view` on `Core.MAP_FILE`) and `item_revisions::Dict{String,Int}` (from `Core.item_revisions(s)`). Every construction of these types is updated.
  - `struct LayerKey; item::String; kind::Symbol; channel::String; x::String; y::String; crs::String; end` (`x`, `y`: the database's current pair; `crs`: the map's).
  - `mutable struct LayerEntry`: `key`, `revision::Int` (of `data`), `wanted::Int`, `data`, `spare` (`Union{Nothing,LineLayerData,GridLayerData}` each), `loading::Bool`, `error::String`, `seconds::Float64`.
  - `mutable struct MapState`: `entries::Dict{LayerKey,LayerEntry}`, `gl::Union{Nothing,GlMap}` (made on the render thread by the first map pass; Task 11 moves it into `MapRenderer`), `session::Union{Nothing,Core.Session}`. `AppState` gets `map::MapState`.
  - The loader is a second task of `Worker` (`map_inbox::Channel{Any}`, `map_task::Task`), stopped by `stop_worker!`. It runs one load at a time. It opens the item with `Core.open_database(folder)` or `Core.open_grid(folder)` from the absolute folder (`snap.folder` and `ItemRow.path`, read on the render thread), reads with `Core.read_line_points(...; into = spare.points, reproject)` or `Core.read_rows!` into a reused band, builds with `build_line_layer!` or `build_grid_layer!` into the spare, and sends `LayerLoaded(session, key, revision, data_or_nothing, error, seconds)`, then `wake!`. It touches no `Session`. A line layer in another coordinate system than the map's (both known) is reprojected with a `Core.Reprojector`; a grid in another system is drawn as it is, with the layer error "This grid is in <crs>, not in the map's <crs>. It is drawn without reprojection." (as text, so it shows in the Layers tab).
  - `update_layers!(app)`: on the render thread each frame, for the shown map: every visible layer whose entry is missing, or whose `wanted` differs from `snap.item_revisions[item]`, gets a load when none runs for it; the entry keeps drawing its old `data` meanwhile. When a load comes back with a revision older than the snapshot's, it is used and loaded again. Entries no map uses are dropped and their GL objects freed.
  - `handle_result!(app, m::LayerLoaded)`: drops a message whose `session` is not `app.map.session`; else swaps `data` and `spare`, bumps `data.version`, sets `error` (`""` on success, else the `user_message`), and queues the uploads (Task 8).
  - `set_session!` empties `app.map.entries` (their GL objects freed on the next render frame) and sets `app.map.session`.
  - Test helper `wait_layers(app; timeout = 20)`: drains and calls `update_layers!` until no load runs and every visible layer of the shown map has an entry.

- [ ] **Step 1: Write the failing tests** (logic, no window: the renderer is not started)

```julia
s = fresh_session(); db = survey_database!(s); m = Core.new_map!(s); Core.add_layer!(s, m, db)
app = test_app_state(s); refresh_now!(app); app.ui.current_map = m
wait_layers(app)
e = only(values(app.map.entries))
@test e.data isa LineLayerData && e.error == "" && e.revision == app.snap.item_revisions[db]
first_x = e.data.points.x
submit!(app, "edit", s -> Core.set_cell!(s, db, Core.LineId(Core.LINE, 1001, 0), "MAG", 1, 9.0))
wait_drained(app); refresh_now!(app); wait_layers(app)
@test e.revision == app.snap.item_revisions[db] && e.data.points.value[1] == 9f0
submit!(app, "edit", s -> Core.set_cell!(s, db, Core.LineId(Core.LINE, 1001, 0), "MAG", 2, 8.0))
wait_drained(app); refresh_now!(app); wait_layers(app)
@test e.data.points.x === first_x                      # two buffers, swapped
```

Also:
- A database whose folder was deleted gives the entry an error text and no exception; the other layers still load.
- A layer whose channel was deleted gives the error "Channel MAG is not in <name>."
- A grid layer of an all-NaN grid loads with `count == 0` and no error.
- Review Focus 3: with a map of `survey_database!` loaded, `set_session!` to a new session of a project with 2000 lines of 50 rows that has a map with that database; a load of the old session held back by a test hook and released afterwards is dropped (no entry of the old keys after it is handled); the new layer loads; `app.map.entries` holds only new keys.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Load map layers on a worker-owned task into reused buffers"`

---

### Task 10: The map view: gestures and overlays

**Files:**
- Create: `JuliaMagUI/src/map/view.jl`, `src/map/overlays.jl`, `test/test_map_view.jl`, `test/window/test_map_view.jl`
- Modify: `src/shell/central.jl` (`draw_central` draws the map view when `app.ui.current_map` names a map), `src/app/state.jl` (`MapState.views::Dict{String,MapViewState}`, cleared by `set_session!`; `UiState.opacity_preview::Union{Nothing,Tuple{String,Float64}} = nothing`, a live opacity for one layer id, set by the Layers tab in Task 13), `src/JuliaMagUI.jl` (`gl_pass` for `AppFrame`), `src/map/scene.jl` (`build_scene!`), `test/support/app.jl` (mouse helpers)

**Interfaces:**
- Consumes: Tasks 4 to 9.
- Produces:
  - `mutable struct MapViewState`: `camera::Union{Nothing,Camera}` (nothing until the first layer has an extent; then full extent), `history::ExtentHistory`, `gesture::Symbol` (`:none`, `:pan`, `:box`, `:wheel`), `before::Union{Nothing,Camera}` (the camera when the gesture started), `grab::NTuple{2,Float64}` (world point under the mouse at the press), `press::NTuple{2,Float32}`, `last_input::Float64`, `box::Union{Nothing,NTuple{4,Float32}}`, `size::NTuple{2,Int}`.
  - `struct MapInput`: `mouse::NTuple{2,Float32}` (view px), `hovered::Bool`, `left_down`, `middle_down`, `shift::Bool`, `wheel::Float32` (notches), `size::NTuple{2,Int}`, `now::Float64`.
  - `step_view!(st, input)::Union{Nothing,Tuple{Symbol,NTuple{2,Float64}}}` (pure): left drag or middle drag pans with `pan_to`; Shift and left drag draws a box and fits it on release (`pad = 0`); a box under 4 px, or a press and release that moved under 3 px, returns `(:pick, world_point)`; the wheel zooms about the mouse by `wheel_factor`; a size change keeps the centre and, during a pan, the grabbed point under the mouse. When a gesture has ended and `SETTLE` has passed since the last input, `record_extent!(history, before)` runs once.
  - `full_extent!(st, ext, w, h)`, `zoom_layer!(st, ext, w, h)`, `previous!(st)`, `next!(st)`, `zoom_by!(st, factor)`: each records one extent.
  - `build_scene!(sc::Scene, app, mv::MapView, st::MapViewState, w, h)::Scene`: on the render thread, from the snapshot and the loaded entries only: the visible layers with data, in draw order, each with its level (`choose_level`, `grid_level`), LUT, stretch (`Core.stretch_range` on the layer's histogram, `Core.equalize_table!` for `:histeq`), opacity (or `ui.opacity_preview`), and the resolved hillshade; then `sc.key = scene_key(sc)`. No allocation after warm-up: LUTs and tables are cached per layer and style.
  - `map_gl_pass!(app, w)`: builds the scene of the shown map and, when its key differs from the last drawn one, draws it with `gl_draw!`; runs `upload_step!` once per frame and calls `request_frames!` while uploads are pending.
  - `draw_map_view(app, dl, b::Box)`: an invisible button over `b` takes the mouse; the map image (`ig.Image` of the map texture; Task 11 adds the moved image while a slow view moves); then the overlays.
  - Overlays (`overlays.jl`, look from the prototype `.mapnav`, `.scalebar`, `.legends`, `.maphint`):
    - nav buttons at the top right, 10 px in, 26 by 26, 4 px apart: Zoom In, Zoom Out, Full Extent, Go To Cursor;
    - scale bar at the bottom left, 10 px in, target 130 px, label 11 on a `ribbon` panel at 88 % alpha with a 1 px `border`;
    - coordinate ticks: along the top edge for X and the left edge for Y, ticks 6 px long, at `tick_values!` spaced at least 90 px, labels 10.5 `text_dim` with `coord_text`, on a `ribbon` band at 88 % alpha;
    - legends at the bottom right, 228 px cards, one per coloured visible layer, newest on top: title (layer name and channel), the ramp strip 210 by 10 with the low, middle and high values; a layer with no values says "No values";
    - line labels at the start of each line in view, `text` with a `canvas` halo, skipped when they would overlap one already placed, at most 300;
    - the box rectangle while box zooming (`accent` at 12 % fill, 1 px `accent` border);
    - a hint at the top left (`.maphint`): "Loading <name>..." while a layer loads, or the first layer error;
    - an empty map: "This map has no layers." and "Show a database or grid on it from the Data tab." centred in `text_dim`.
  - Harness: `drag(ctx, from, to; button = 0, mods = "", steps = 6)`, `wheel(ctx, pos, notches)`, `mouse_to(ctx, pos)` in `test/support/app.jl` with `te.MouseMoveToPos`, `te.MouseDown`, `te.MouseUp`, `te.MouseWheelY`, `te.KeyDown` and `te.KeyUp`, added to `TEST_ACTIONS`.

- [ ] **Step 1: Write the failing tests**

```julia
# MapViewState(cam) starts with no gesture; idle_input(t) and release_at(input, pos) are test helpers
st = MapViewState(Camera(500_000.0, 7_000_000.0, 10.0))
w0 = screen_to_world(st.camera, 800, 600, 100.0, 100.0)
step_view!(st, MapInput((100f0, 100f0), true, false, false, false, 1f0, (800, 600), 0.0))
@test all(isapprox.(screen_to_world(st.camera, 800, 600, 100.0, 100.0), w0; atol = 1e-6))
step_view!(st, idle_input(0.2)); @test length(st.history.past) == 1          # one entry per finished gesture
press = MapInput((400f0, 300f0), true, true, false, false, 0f0, (800, 600), 1.0)
step_view!(st, press); r = step_view!(st, release_at(press, (401f0, 301f0)))
@test r[1] == :pick && length(st.history.past) == 1
st2 = MapViewState(Camera(0.0, 0.0, 1.0))
step_view!(st2, MapInput((100f0, 100f0), true, true, false, true, 0f0, (800, 600), 0.0))
step_view!(st2, MapInput((300f0, 250f0), true, true, false, true, 0f0, (800, 600), 0.1))
step_view!(st2, MapInput((300f0, 250f0), true, false, false, true, 0f0, (800, 600), 0.2))
@test st2.camera.res == 0.25 && (st2.camera.cx, st2.camera.cy) == (-200.0, 125.0)
```

Review Focus 4: a pan from (400, 300) that moves 10 px per frame for 10 frames, with the size changed from 800 by 600 to 600 by 600 at frame 5, keeps the grabbed world point within 1 px of the mouse at every frame, and adds exactly one history entry after the release and `SETTLE`.
Window tests (a project with `survey_database!` of 40 lines and an `add_test_grid!` grid, both on one map):
- Show the map: within 5 s the image is drawn and the layer shows; shots light and dark at scale 1 and 1.5.
- `drag` moves the camera by the drag times `res`; `wheel` at a point keeps that point; `Home` (key) fits the full extent; Shift drag zooms to the box.
- Resize the window with `GLFW.SetWindowSize` during a `drag`: no draw error, and the camera after the release equals the pure test's rule.
- Review Focus 2: an all-NaN grid on the map draws nothing, its legend says "No values", Zoom to Layer fits its corners, and `app.draw_errors` stays empty.
- The empty map message shows for a map with no layers.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review.** Compare the shots with the prototype's map view (`prototype/juliamag-ui.html`, map document) in light and dark. Fix every visible difference in size, spacing, colour or alignment of the overlays.
- [ ] **Step 6: Commit** `git commit -m "Show the map in the central area with pan, zoom, box zoom and its overlays"`

---

### Task 11: Renderer choice, adaptive frames and fallback

**Files:**
- Create: `JuliaMagUI/src/map/frame.jl`, `test/test_map_frame.jl`, `test/window/test_map_fallback.jl`
- Modify: `src/app/config.jl` (`map_drawing`), `src/map/view.jl` (`map_gl_pass!`, the moved image), `src/app/state.jl` (`MapState.gl` becomes `MapState.renderer::MapRenderer`), `src/ribbon_tabs/settings_tab.jl`, `src/shell/statusbar.jl` (render item), `test/test_config.jl`

**Interfaces:**
- Consumes: Tasks 7 to 10; `toast!`, `save_settings!`, `wake!`, `request_frames!`, `note_draw_error!`.
- Produces:
  - `AppConfig.map_drawing::String = "auto"` (`"auto"`, `"gpu"`, `"cpu"`; another value loads as `"auto"`).
  - `@enum MapMode MAP_GL MAP_CPU`; `choose_mode(setting, gl_problem::String)::MapMode`: `MAP_CPU` for `"cpu"` or a non-empty `gl_problem`, else `MAP_GL`.
  - `mutable struct MapImage`: texture id, `camera::Camera`, `size::NTuple{2,Int}`, `key::UInt64`, `cost::Float64` (seconds of its full draw: GPU time from the query for GL, wall time for CPU).
  - `mutable struct MapRenderer`: `mode::MapMode`, `gl::Union{Nothing,GlMap}`, `gl_problem::String`, `image::MapImage`, `cpu_buffers::NTuple{2,Matrix{UInt32}}` (reused, resized only when the view grows), `cpu_task::Union{Nothing,Task}`, `full_draws::Int` (tests count it), `fail_next::Bool` and `cost_override::Union{Nothing,Float64}` (test hooks).
  - `should_transform(moving::Bool, cost::Float64)::Bool = moving && cost > FRAME_BUDGET`.
  - `image_rect(img::MapImage, cam::Camera, w, h)::NTuple{4,Float32}`: where the last full image lies on screen under `cam` (`x0, y0, x1, y1`).
  - `map_gl_pass!(app, w)` (Task 10's, extended): on the render thread, after ImGui's render. When the current map's scene key differs from `image.key` and the view is not moving with `should_transform`, it draws the scene in full (GL: `gl_draw!`; CPU: hands the scene to a frame task that runs `render_cpu!` into the free buffer and sends `CpuFrameDone(key, buffer, seconds)` through `app.queue.results`; the render thread uploads it with `glTexSubImage2D`). Else `draw_map_view` draws the last image at `image_rect`, with the uncovered part in `canvas`. It runs `upload_step!` once per frame and calls `request_frames!` while uploads or a CPU frame are pending.
  - Fallback: any exception or GL error in the GL part of the pass sets `gl_problem` to a plain reason, `mode = MAP_CPU`, frees the GL map objects, logs the error once, and shows the toast `:warn` "The map could not draw with the graphics card, so it draws on the CPU now." with the reason as `sub`. The same frame restores the GL state (Task 8 `finally`).
  - Setting "Graphics card" with a `gl_problem` draws on the CPU and toasts "The graphics card cannot draw the map here, so it draws on the CPU." once.
  - Settings tab, group `Rendering`, three small toggles after Software Rendering: commands `settings.map_auto` "Map Drawing: Auto", `settings.map_gpu` "Map Drawing: Graphics Card", `settings.map_cpu` "Map Drawing: CPU", checked for the current value; `set_map_drawing!(app, value)` saves the config and takes effect on the next frame.
  - Status bar render item: `"GPU"` in `accent_text` when the map draws with GL on a hardware renderer, `"Software"` in `amber` for a software OpenGL renderer, `"CPU map"` in `amber` when the map draws on the CPU; the tooltip names the reason from `gl_problem`.

- [ ] **Step 1: Write the failing tests**

```julia
@test choose_mode("auto", "") == MAP_GL && choose_mode("auto", "no FBO") == MAP_CPU
@test choose_mode("cpu", "") == MAP_CPU && choose_mode("gpu", "no R32F") == MAP_CPU
@test should_transform(true, 0.030) && !should_transform(true, 0.010) && !should_transform(false, 0.5)
img = MapImage(UInt32(1), Camera(0.0, 0.0, 1.0), (800, 600), UInt64(0), 0.05)
@test image_rect(img, Camera(-10.0, 0.0, 1.0), 800, 600) == (10f0, 0f0, 810f0, 600f0)
@test image_rect(img, Camera(0.0, 0.0, 0.5), 800, 600) == (-400f0, -300f0, 1200f0, 900f0)
c, _ = load_config(dir_with("""{"map_drawing": "bogus"}""")); @test c.map_drawing == "auto"   # dir_with: a temp dir with that settings.json
```

Window tests (`test/window/test_map_fallback.jl`, a project with `survey_database!` and `add_test_grid!` on one map):
- Review Focus 5: with the map drawn on GL, set `renderer.fail_next = true`; within that frame `mode == MAP_CPU`, `GL_FRAMEBUFFER_BINDING == 0`, the toast above is the last toast, and within 2 s `renderer.image.key` equals the current scene key; one log entry and no draw error toast.
- `set_map_drawing!(app, "cpu")` draws the next full image on the CPU; `"auto"` brings GL back.
- Adaptive: with `cost_override = 0.05`, five frames of a left drag do not change `full_draws`, and one full draw follows within 0.3 s of the release; with `cost_override = 0.005`, every drag frame draws in full.
- Shots of the map in GL and in CPU mode, light and dark, for the pixel review.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** The transformed image is the RustGIS pattern (`map-rustgis.md` section 1 "Redraw policy"), without mid-motion frames: the full picture is drawn once the gesture settles.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Choose GPU or CPU map drawing, move the last image while slow, and fall back on failure"`

---

### Task 12: Map commands, the Map tab and Show on Map

**Files:**
- Create: `JuliaMagUI/src/commands/map_commands.jl`, `test/test_map_commands.jl`, `test/window/test_map_commands.jl`
- Modify: `src/commands/commands.jl` (add the map commands to `commands(app)`), `src/panes/data.jl` (Maps folder, map rows, menu items), `src/app/state.jl` (`UiState.layer_selected::String`, `colour_bars::Bool = true`; `set_session!` resets them and `current_map`; opening a project shows its first map), `test/test_data_tree.jl`

**Interfaces:**
- Consumes: Task 1 core edits through `submit!`; Task 10 view functions.
- Produces:
  - Commands (title case names, icons from `assets/icons`, places as the prototype's Map tab, `ui-prototype.md` section 3):
    - `Map / Map`: `map.new` "New Map" (`:big`, icon `newMap`): `new_map!`, then shows it; `map.add_item` "Add Item to Map" (`:big`, icon `addItem`, a menu of the project's databases and grids; makes a map when there is none); `map.remove_layer` "Remove Layer" (`:small`, icon `removeLayer`, the selected layer).
    - `Map / Navigate`: `map.full_extent` "Full Extent" (`:big`, icon `fullExtent`, shortcut `Home`); `map.zoom_in` "Zoom In", `map.zoom_out` "Zoom Out" (factor 2 about the centre), `map.zoom_layer` "Zoom to Layer", `map.prev_extent` "Previous Extent", `map.next_extent` "Next Extent", `map.go_cursor` "Go To Cursor" (all `:small`).
    - `Map / Display`: `map.layer_style` "Layer Style" (`:big`, icon `brush`, opens the Layer Style pane, Task 14); `map.hillshade` "Hillshade" (toggle `shade` of the selected grid layer, or of the top grid layer); `map.colour_bars` "Colour Bars" (toggles `ui.colour_bars`); `map.line_labels` "Line Labels" (toggle `labels` of the selected line layer, or of the top line layer) (all `:small`, `checked` from the state).
    - `enabled` reasons: "Open a project first.", "Open a map first.", "Select a layer first.", "The map has no grid layer.", "The map has no line layer.", "There is no earlier extent.", "There is no later extent.", "The current point is not on this map.".
  - `show_on_map!(app, item_id)`: when there is a current map and the item is a layer of it, selects that layer and zooms to it; when there is a current map, adds the item to it; else makes a new map with it. A first layer zooms to full extent once its data is in. All through `submit!`, no questions.
  - Data tree: a `Maps (n)` folder after `Grids` (`FOLDER_KEYS` gets `maps = "maps"`); map rows with icon `map` and right text from `plural(n, "layer")` ("1 layer", "2 layers"); the Enter or double-click action shows the map; map menu: Open, Rename..., Remove from Project. Database and grid rows get "Show on Map" (icon `map`) at the top of their menu, and "Add to Current Map" (icon `addItem`) when a map is shown: it always adds a new layer, so one database can show twice with two channels.

- [ ] **Step 1: Write the failing tests**

```julia
s = fresh_session(); db = survey_database!(s); app = test_app_state(s); refresh_now!(app)
ids = Set(c.id for c in commands(app))
@test issubset(["map.new", "map.add_item", "map.full_extent", "map.prev_extent", "map.layer_style"], ids)
@test "Map" in tab_order(commands(app), String[])
@test only(filter(c -> c.id == "map.full_extent", commands(app))).shortcut == "Home"
@test only(filter(c -> c.id == "map.remove_layer", commands(app))).enabled(app) == "Open a map first."
show_on_map!(app, db); wait_drained(app); refresh_now!(app)
m = app.ui.current_map
@test length(app.snap.maps[m].layers) == 1
rows = tree_rows(app.snap, Set(["maps"]), "")
@test any(r -> r.label == "Maps (1)", rows) && any(r -> r.label == "Map 1" && r.right == "1 layer", rows)
show_on_map!(app, db); wait_drained(app); refresh_now!(app)
@test length(app.snap.maps[m].layers) == 1                     # already there: no second layer
```

Window tests: the Map tab shows the three groups; New Map makes "Map 1" and shows the empty map; Show on Map from a database row's menu adds a layer and the map shows it; Home fits the extent; Previous Extent and Next Extent walk the history; Ctrl+Z after Show on Map takes the layer out; shots of the Map tab in light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** of the Map tab against the prototype's Map tab.
- [ ] **Step 6: Commit** `git commit -m "Add the Map tab, the map commands and Show on Map"`

---

### Task 13: Layers tab

**Files:**
- Create: `JuliaMagUI/src/panes/layers.jl`, `test/test_layers.jl`, `test/window/test_layers.jl`
- Modify: `src/panes/panes.jl` (`LEFT_TABS` becomes Data, Layers, Jobs), `src/dialogs/widgets.jl` (`slider!`)

**Interfaces:**
- Consumes: Tasks 1, 9, 12.
- Produces (prototype section 4.2):
  - `struct LayerRow`: `id`, `name`, `icon` (`"lines"` or `"grid"`), `sub::String` (the colour channel, "One colour", "Grid colours" or "Own colours"), `colours::String`, `method::String` ("hist. eq.", "linear", "clip"), `opacity_text::String` ("50 %" when below 100 %, else `""`), `visible::Bool`, `missing::Bool`, `error::String`, `loading::Bool`.
  - `layer_rows(snap, map_id, entries, app_colours)::Vector{LayerRow}`: top layer first.
  - `drop_position(from::Int, to_row::Int, n::Int)::Int`: the `move_layer!` position for dropping row `from` before row `to_row` (rows top first, positions bottom first).
  - `slider!(app, id, b::Box, value, lo, hi; format)::Tuple{Float64,Bool,Bool}` (value, changed while dragging, released).
  - Drawing: toolbar 32 high (Add Item menu, Remove Layer, Move Up, Move Down, Layer Style, and a 112 px map chooser combo at the right); rows 26 high with a drag grip, the visibility checkbox, the 16 px icon, the name (`text_disabled` when hidden, `red` when the item is missing with right text "not found", an `amber` warning icon with the error as tooltip), and the opacity text; a 22 px sub-line with the channel or style text, a 60 by 8 ramp strip and the method; the selected layer's 28 px opacity slider row; a 2 px `accent` drop line while dragging; the footer "Drag rows to change the drawing order. The top layer draws last."; an empty map shows "This map has no layers." and an "Add Item" button.
  - Actions (all through `submit!`): the checkbox runs `set_layer!(...; visible)`; a drop runs `move_layer!`; the opacity slider draws live through `ui.opacity_preview` (Task 10) and runs one `set_layer!(...; opacity)` on release; context menu: Zoom to Layer, Layer Style..., Move Up, Move Down, Remove Layer; a double click opens the Layer Style pane.

- [ ] **Step 1: Write the failing tests**

```julia
rows = layer_rows(snap, m, entries, "geosoft")      # a map with a grid layer below a line layer
@test [r.icon for r in rows] == ["lines", "grid"] && rows[1].sub == "MAG" && rows[2].sub == "Grid colours"
@test rows[2].method == "hist. eq." && rows[1].opacity_text == ""
@test drop_position(1, 3, 2) == 1 && drop_position(2, 1, 2) == 2
```

Window tests: unticking a layer hides it on the map and Ctrl+Z shows it again; dragging the line layer below the grid changes the order (and the map); an opacity drag makes exactly one undo step; Remove Layer then Ctrl+Z puts it back; a layer whose item was removed shows "not found" in `red`; a layer with a load error shows the warning tooltip; shots light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's Layers tab.
- [ ] **Step 6: Commit** `git commit -m "Add the Layers tab with visibility, order, opacity and removal"`

---

### Task 14: Layer Style pane

**Files:**
- Create: `JuliaMagUI/src/panes/style.jl`, `test/test_style_pane.jl`, `test/window/test_style_pane.jl`
- Modify: `src/panes/panes.jl` (`RIGHT_TABS` gets `:style => "Layer Style"`)

**Interfaces:**
- Consumes: Tasks 1, 2, 9, 13 (`slider!`); `combo!`, `segmented!`, `checkbox!`, `field!` from `dialogs/widgets.jl`.
- Produces:
  - A right-pane tab for the selected layer of the current map; changes apply at once, each as one `set_layer!` step; sliders draw live through `ui.style_preview::Union{Nothing,Tuple{String,Core.LayerStyle}}` and commit on release.
  - Line layer: "Colour by" (combo: "One colour" and the database's numeric, non-array channels), "Colour table" (combo whose rows show a ramp strip and the label), "Reverse colours", "Stretch" (segmented Linear, Clip, Equalize), "Minimum" and "Maximum" (number fields, blank means the data's; shown for Linear), "Low clip %" and "High clip %" (for Clip, 0 to 49), "Line labels", "Opacity".
  - Grid layer: "Use the grid's default colours" (`own_style`; when on, the colour fields show the effective style greyed with the hint "Untick to give this layer its own colours."), then the same colour fields, "Hillshade", "Sun inclination" (slider 0 to 90), "Sun declination" (slider 0 to 360), "Vertical scale" (blank means auto; the hint reads "Auto: 2.5 over the mean gradient = <value>" with the value from the layer data), "Cells" (segmented Nearest, Bilinear), "Opacity".
  - A legend preview under the fields: ramp strip with the low and high values of `Core.stretch_range`.
  - `style_edit(layer, field::Symbol, value)::NamedTuple`: the keywords for `set_layer!` for one edit (pure; clamps clip percents to 0 to 49 and inclination to 0 to 90; an edit of a colour field on a grid layer with `own_style = false` is refused).

- [ ] **Step 1: Write the failing tests**

```julia
L = Core.MapLayer("layer-1", "db-1", :lines, "MAG", true, 1.0, true, true, Core.LayerStyle())
@test style_edit(L, :colours, "viridis").style.colours == "viridis"
@test style_edit(L, :clip_low, 70.0).style.clip_low == 49.0
@test style_edit(L, :inclination, -5.0).style.inclination == 0.0
@test style_edit(L, :channel, "").channel == ""
G = Core.MapLayer("layer-2", "grid-1", :grid, "", true, 1.0, false, false, Core.LayerStyle())
@test_throws ArgumentError style_edit(G, :colours, "turbo")
@test style_edit(G, :own_style, true).own_style
```

Window tests: choosing Viridis recolours the map and records `"map.set_layer"`; turning on Hillshade and dragging the inclination slider redraws while dragging and leaves one undo step; a blank vertical scale shows the auto hint with the value `2.5 / mean_gradient` to 3 significant digits; Nearest shows square cells when zoomed in (shot); shots light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's Layer Style dialog fields (as a pane) and RustGIS's Symbology pane spacing (`ui-rustgis.md`).
- [ ] **Step 6: Commit** `git commit -m "Add the Layer Style pane with stretches, colour tables and a live sun"`

---

### Task 15: Point readout and the shared cursor

**Files:**
- Modify: `JuliaMagUI/src/shell/statusbar.jl`, `src/map/view.jl` (hover and pick), `src/map/overlays.jl` (cursor marker), `src/app/state.jl` (`UiState.hover`)
- Test: `test/test_map_readout.jl`, `test/window/test_map_cursor.jl`

**Interfaces:**
- Consumes: Tasks 5, 6, 9, 10; `Core.set_cursor!`, `Core.Cursor`, `snap.cursor`, `fmt_num`.
- Produces:
  - `struct MapHover; x::Float64; y::Float64; grids::Vector{Tuple{String,Float32,String}}; near::Union{Nothing,Tuple{String,NearPoint}}; end` (grid name, value, units; database item id and point), built on the render thread from loaded layer data only. `UiState.hover::Union{Nothing,MapHover}`.
  - `map_hover(app, x, y)::MapHover`: every visible grid layer, top first, with `grid_value(...; nearest = style.resample == :nearest)`; the nearest point of any visible line layer within 20 logical px.
  - `map_status(app)::NTuple{3,String}`: the map's coordinate system name (from `snap.crs`, or "No coordinate system"), the pointer text `"X 500,123.4  Y 7,000,056.0"` (1 decimal; 6 for a `deg` unit; `"X -  Y -"` off the map), and the readout: each grid `"<name> 12.35 nT"` (2 decimals with `fmt_num`; `"<name> -"` for NaN), then `"L1002 fid 0.3 MAG 203.00"` (fiducial `fid_start + (row - 1) * fid_step`, value with the channel's decimals, 2 when unset), parts two spaces apart.
  - Status bar: while a map is shown, the left side shows the three parts with separators instead of the database text (prototype section 8.5); the right side stays.
  - Pick: a `:pick` from `step_view!` with a nearest point runs `submit!(app, "Move the cursor", s -> Core.set_cursor!(s, Core.Cursor(db, line, row)))`; no point within 20 px leaves the cursor.
  - Marker: when `snap.cursor` names a database on the map, a 12 px circle with a 2 px `accent` ring and a 1 px `on_accent` halo at `cursor_point`, drawn over the map. `map.go_cursor` centres the camera on it.

- [ ] **Step 1: Write the failing tests**

```julia
# a map of survey_database!(s; lines = 3) and a 10 by 10 grid of value 12.345f0 named "TMI" in nT, loaded
h = map_hover(app, 500_010.0, 7_000_050.0)
@test h.grids == [("TMI", 12.345f0, "nT")] && h.near[2].line == 2 && h.near[2].row == 2
@test map_status(app)[2] == "X 500,010.0  Y 7,000,050.0"
@test map_status(app)[3] == "TMI 12.35 nT  L1002 fid 0.1 MAG 202.00"
```

Window tests: a click near line L1002 row 3 sets `snap.cursor` to that line and row, and the marker shows there (shot); a click far from every line leaves the cursor; Go To Cursor centres the camera within 0.5 px; with the cursor on a database that is not on the map, Go To Cursor is greyed with "The current point is not on this map."; the status bar texts show while the mouse moves over the map; shots light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** of the status bar against the prototype's.
- [ ] **Step 6: Commit** `git commit -m "Read values under the pointer and move the shared cursor from the map"`

---

### Task 16: Benchmark, end to end and docs

**Files:**
- Create: `bench/map_frame.jl`, `JuliaMagUI/test/window/test_map_end_to_end.jl`
- Modify: `docs/bench.md`, `JuliaMagUI/README.md`, `README.md`, `docs/superpowers/plans/2026-10-28-plan-1-followups.md`

**Interfaces:**
- Produces:
  - `bench/map_frame.jl`, run headless as `xvfb-run -a -s "-screen 0 1920x1080x24" env -u WAYLAND_DISPLAY julia -t auto,1 --project=JuliaMagUI bench/map_frame.jl [--software]`: makes a temp project with a survey database of 2000 lines of 10,000 points (20 M points; 10 m spacing, 50 m line spacing, a MAG channel) and an 8000 by 8000 Float32 grid with a NaN edge, as the spike's `gen.jl` did; shows both on one map at 1584 by 955; prints the load time to the first full picture (read, build, upload), and median and p95 frame times for: whole survey, zoom 10x, zoom 100x, grid only, grid and lines, a pan with the adaptive path, and the CPU renderer for the whole survey and for the grid.
  - `docs/bench.md`: a section "Map view" with the machine, the GL renderer, the numbers on the Intel GPU (D3D12) and on llvmpipe, and how to run it.

- [ ] **Step 1: Write the end-to-end test.** One window session, at scale 1 and 1.5, light then dark:
  1. A new project; import `small.xyz` and the core's small `.grd` grid.
  2. Show on Map for the database, then for the grid: one map, two layers, grid below lines.
  3. Wheel zoom, drag, Home, Previous Extent; the camera follows.
  4. Layer Style: Viridis on the line layer, Hillshade on the grid; Ctrl+Z twice undoes both.
  5. Click a line: the cursor moves, the marker shows, the status bar shows the line and fiducial.
  6. Settings: Map Drawing: CPU, then Auto; the map draws each time.
  7. Close the project, open it again: the map, its layers and styles are there; the map shows at full extent.
  Shots between steps for the review.
- [ ] **Step 2: Run it,** fix what breaks, and run every core and UI test.
- [ ] **Step 3: Run the benchmark** on the Intel GPU (D3D12) and with `LIBGL_ALWAYS_SOFTWARE=1`, and write `docs/bench.md`. Targets on the dev machine: the first full picture of the 20 M points and the grid in under 3 s; whole-survey full frame on the Intel GPU under 16 ms; pan frames p95 under 33 ms on llvmpipe (through the adaptive path); grid-only full frame on llvmpipe under 16 ms. A target that is missed is reported with its number, not hidden.
- [ ] **Step 4: Final pixel review** of all map shots in light and dark at scale 1 and 1.5 against the prototype. Fix what looks off.
- [ ] **Step 5: Docs.** `JuliaMagUI/README.md`: the map view (how to show data, gestures, layers, styles, the Map Drawing setting, GPU and CPU drawing) and the map tests. Root `README.md`: one line on maps. Follow-ups doc: a section "Left for later from plan 4a" with the list below, and in "Checks on real systems" the Windows checks below.
- [ ] **Step 6: Commit** `git commit -m "Check the map end to end, measure it with a survey-sized benchmark and document it"`

---

## Left for later (not in this plan)

- Measure and identify tools, Oasis keyboard shortcuts (P, B, Z, X, F, S, L, O), a log colour scale, contours, layouts and printing, map export, bookmarks, auto recolour to the view, a dots mode at high zoom, direction arrows on lines.
- Reprojecting a grid on the fly to the map's coordinate system (lines are reprojected; a grid in another system draws as it is, with a layer warning).
- Changing a map's coordinate system (needs the coordinate system picker of plan 4c).
- "Add to current map" in tool dialogs for tool outputs (spec 8.2): no tool makes a grid or database yet.
- "Save as grid default" from a grid layer's own style (spec 13.4); the core has `set_grid_style!` for it.
- Line width above 1 px and a highlighted selected line (core profile OpenGL draws 1 px lines; thick lines need quads).
- Mid-gesture redraws while panning far on a slow renderer (the gap shows `canvas` until the gesture settles).
- Several maps side by side, view tabs and split views (plan 4b brings the other views).
- Stored line levels and grid overviews next to the data, if loads of 50 M points need them.
- A GPU memory budget with eviction for several large grids.

## Checks on real systems

- Windows: run `bench/map_frame.jl` on the target laptops (Intel iGPU, NVIDIA, AMD) and record `GL_RENDERER`, `GL_MAX_TEXTURE_SIZE`, frame times at 1080p and at 4K with scale 1.5, upload times per batch and per tile, and VRAM in Task Manager.
- Windows: undo, append, rename and delete of a channel while its map layer loads (the loader holds files open with plain reads for a short time).
- Windows: frame time p95 while a 20 M point layer and a 10k by 10k grid load (GC pauses).
- Windows: the CPU fallback on a machine whose driver lacks `GL_R32F` or a complete float framebuffer.

## Rulings made while writing this plan

These are my calls; each says what it costs if wrong.

- **Map items are written at once to `maps/<id>/map.json`, every change undoable and recorded**, as the approved scope says, not saved with a project Save. The app has no Save command, so spec 5.2 now says the same. The camera is view state and is not saved. Cost: a map opens at full extent each time.
- **Grid levels are separate textures per level, cut from the whole level with a 1-cell border**, not GL mipmaps per tile. This fixes the spike's seams at tile edges and keeps NaN out of coarse levels. Cost: one draw per tile per level shown; at most a few dozen tiles.
  Note: 2-cell border (`TILE_BORDER = 2`) by Task 14b ruling (2026-11-03); tiles hold only used cells plus the border.
- **Grid cells are fetched with `texelFetch` and filtered in the shader**, so the NaN rule and bilinear filtering are the same on every driver and in the CPU renderer. Cost: four fetches per pixel for bilinear, plus four for hillshade.
- **The line level is chosen by a point budget (0.5 points per view pixel)**, not by ground length per pixel, so a whole-survey view stays near the screen's pixel count; the llvmpipe numbers showed that the spike's 8-point buckets were too fine. Cost: a dense survey zoomed out shows coarser paths; min and max per bucket keep spikes.
- **The map loader is a second task of the worker**, which reads item files by folder and never touches the session. So a big load never delays an Undo click on the serial worker. Cost: a load can read while a job writes the same item; the item's revision is checked when the load comes back, and a changed item is loaded again.
- **"geosoft" becomes the first and default colour table** (`GridStyle()`, `LayerStyle()`, the app setting). Grids imported before this plan keep the table their style names. Cost: a user who had "rainbow" saved as the app setting keeps it.
- **A grid layer without its own style follows the grid's default style, and a grid style with the stock table uses the app's "Grid colours" setting** (spec 5.4 and 9.6 together). Cost: one rule to explain in the README.
- **The Layer Style editor is a right-pane tab, not a dialog**, so the sun and stretches change live (Oasis Interactive Shading, RustGIS's Symbology pane). Cost: it differs from the prototype's Layer Style dialog.
- **No mid-gesture redraw on a slow renderer.** The last full image moves and scales until the gesture settles (RustGIS draws gap frames as well). Cost: a long pan on llvmpipe shows empty canvas at the edge until release.
