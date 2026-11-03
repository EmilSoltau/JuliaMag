# RustGIS map view: research for JuliaMag plan 4a

All paths are under `RustGIS/crates/` unless noted.
This extends `JuliaMag/docs/research/ui-rustgis.md`.
That study already covers the shell, theme, ribbon, side panes, status bar layout and the Layers row look.
It is not repeated here.
Short names: `mapview.rs` = `ui-egui/src/mapview.rs`, `mapgpu.rs` = `ui-egui/src/mapgpu.rs`, `panes.rs` = `ui-egui/src/panes.rs`.

## 1. Map view architecture

### Two drawing paths, CPU is the default

- The default path is a CPU rasteriser (tiny-skia).
- It draws the whole map into a pixmap.
- The pixmap is uploaded as one egui texture named "map" with LINEAR filtering (`mapview.rs:1183-1195`, `show_frame`).
- The texture is painted into the central panel with `painter.image` (`mapview.rs:1090-1092`).
- The GPU path is optional and off by default (`docs/user-guide/maps.md:417-427`).
- The GPU path is called "beta" in the docs.
- `RUSTGIS_GPU=1` forces it on.
- The architecture doc calls the GPU backend "optional" (`docs/architecture.md:17`).
- So the production-proven path is a CPU frame, not wgpu.

### How the GPU path sits in egui

- It is an `egui_wgpu::Callback` paint callback (`mapview.rs:1060-1078`, `mapgpu.rs:1463-1476`, struct `SceneCallback`).
- The scene is first drawn into an offscreen 4x MSAA colour target plus a resolve texture (`mapgpu.rs:815-830`, `SceneTarget`).
- The offscreen draw happens in `prepare` using egui's command encoder (`mapgpu.rs:1560-1580`).
- Then `paint` blits the resolved texture into egui's pass with a blit pipeline (`mapgpu.rs:1589-1600`).
- The target is recreated when the physical size changes (`mapgpu.rs:1562-1566`).
- Pipelines are built once in `GpuMapRenderer::new` (`mapgpu.rs:241-275`).
- The module header calls it "the SpatialOS VectorCallback pattern" (`mapgpu.rs:1`).

### How it fits the central panel

- `main_view` takes `ui.available_rect_before_wrap()` and allocates it with `Sense::click_and_drag()` (`mapview.rs:602-606`).
- Everything else (overlays, labels, popups) is drawn with `ui.painter_at(rect)` on top (`mapview.rs:1038`).
- Labels are drawn by egui text, not baked into the texture (`mapview.rs:1100-1130`).
- Tabs above the map are one per map in the project (`mapview.rs:3353`, `view_tabs`).
- The split view puts a second read-only map on the right half (`mapview.rs:456-466`).

### Camera

- The camera is `Camera { center, res, bearing, pitch }` (`map/src/camera.rs`, struct near line 40).
- `res` is map units per pixel in Web Mercator, not a zoom level.
- Zoom limits: `MIN_RES = 1e-4`, `MAX_RES = 160_000.0` (`map/src/camera.rs:11-12`).
- Pitch limit is 85 degrees (`camera.rs:23`).
- `clamp()` limits the centre to the Mercator world box (`camera.rs:290-303`).
- `zoom_at(factor, sx, sy, w, h)` keeps the screen point under the pointer fixed (`camera.rs:305-319`).
- Wheel zoom: `scroll = smooth_scroll_delta.y + zoom_delta().ln() * 300`, then `factor = exp(scroll * 0.0028)` (`mapview.rs:2016-2025`).
- So one wheel notch of about 50 px gives a factor of about 1.15.
- Pinch zoom goes through the same line via `zoom_delta`.
- Double click zooms in by 2 about the click (`mapview.rs:2311-2325`, tool Explore).
- Drag pans with `resp.drag_delta()` (`mapview.rs:2233-2253`).
- On a flat view the drag moves the centre by `delta * res` (`camera.rs:321-331`, `pan_px`).
- Drag mappings in the Explore tool: left drag pans, Shift+drag draws a zoom/select box, Ctrl+drag (or right drag) turns and tilts, middle drag pans (`mapview.rs:2140-2160`).
- Turn is `delta.x * 0.8` degrees and tilt is `-delta.y * 0.5` degrees (`mapview.rs:2225-2231`).
- There is no inertia or fling.
- A grep for inertia, momentum and fling in `map/` and `ui-egui/` finds nothing.
- There is no animated zoom either.
- `map.zoomToExtent` and `layer.zoomTo` jump at once (`engine/src/lib.rs:1755-1764`).
- Only the scripted keyframe "animation" feature interpolates the camera (`mapview.rs:475-496`).
- Zoom to extent: `fit_lonlat` pads the extent by 6 percent (min pad 1e-6 degrees, 0.02 for a point) and then `fit_extent` picks `res` so both axes fit, never below `2 * MIN_RES` (`camera.rs:418-431`).
- Full Extent (`Home` key) fits `shown_extent()`, or a world box when empty (`engine/src/cmd/navigate.rs:310-315`).
- Previous and Next extent are commands (`navigate.rs:17-26`).
- `record_extent()` is called only after a gesture settles (`mapview.rs:945-947`), so history gets one entry per gesture.

### Redraw policy

- It is event driven, not continuous.
- The frame is keyed by a `Key { rev, cam (quantised), size, draft, tiles, sources, shown }` (`mapview.rs:23`, `681-698`).
- A new frame is drawn only when the key changes (`stale = app.map.key != Some(key)`, `mapview.rs:861`).
- While the user pans or zooms ("moving" = dragging or less than 0.18 s since the last input, 0.4 s when tilted), the last frame is shifted and scaled on screen instead of redrawn (`mapview.rs:626-632`, `tex_rect` at `1275-1304`).
- A new mid-motion frame is drawn only if the old one no longer covers the view, or it is stretched more than a limit (`mapview.rs:908-935`).
- Gap frames are drawn 1.5x the view size so the next steps are covered (`GAP_SPAN`, `mapview.rs:1210-1211`).
- Mid-motion frames have a 32 ms budget and drop to as low as half resolution when slower (`MOTION_BUDGET_MS`, `motion_resolution`, `mapview.rs:1213-1242`).
- The gap between mid-motion frames is at least 33 ms, and 1.5x to 3x the draw time (`motion_gap`, `mapview.rs:1262-1267`).
- When motion stops, one exact frame is drawn.
- Resizing a pane holds the old frame for 0.15 s (`RESIZE_SETTLE`, `mapview.rs:714-731`).
- Repaints are requested by `request_repaint_after` for the settle frame, and by wakers when tiles or source reads finish (`mapview.rs:690-695`).
- An idle map costs nothing.

## 2. Big vector data

### What is documented

- There are no published benchmark numbers or fps claims for large data in the docs.
- The docs say only that GPU rendering gives "smoother navigation on large datasets" (`docs/user-guide/maps.md:417`).
- Benchmarks exist as examples that print ms per frame, but they use a basemap tile style and sample world data, not millions of features (`render/examples/vector_tile_bench.rs`, `globe_bench.rs`).
- The numbers below come from constants in the code.

### Streaming window, not full load

- Sources above 100,000 features are "streamed": the layer holds only a window of features for the current view (`map/src/source.rs:21-27`, `STREAM_ABOVE`).
- A view reads at most 250,000 features on desktop, 100,000 in the browser (`VIEW_LIMIT`, `source.rs:27`).
- Over the limit, an evenly spread sample is kept (`source.rs:3-7`, and `retain_evenly` at `source/window.rs:24-39`).
- Remote files: 60,000 per view (`REMOTE_VIEW_LIMIT`).
- Memory budget for streamed rows plus caches: 128 MB per map on desktop, 48 MB in the browser (`VIEW_BYTES`, `source.rs:24`).
- Formats that stream: GeoPackage, GeoParquet, FlatGeobuf, shapefile (with an index), PostGIS and others.
- The view is padded so small pans do not re-read (`source.rs:3-6`).
- Reads run on a background thread named "rustgis-source" (`source.rs:938`).
- The finished read is placed in a shared slot behind a `Mutex`, then a global GENERATION counter goes up and a waker calls `request_repaint` (`source.rs:927-945`).
- The UI polls the slot with `poll()` (`source.rs:960-975`).

### Level of detail for lines and polygons

- For layers over 200,000 line and ring vertices, "thinned" copies are built (`map/src/lod.rs:12-13`, `THIN_ABOVE`).
- A copy keeps a vertex only when it is far enough from the last kept one.
- The tolerance is 0.3 device pixels (`THIN_PX`).
- Copies are built per level, with tolerance `2^level` map units, on first use (`lod.rs:1-8`).
- At most 3 levels are kept per layer (`LEVELS_KEPT`).
- The extra cache is limited to 64 MB (`CACHE_BYTES`).
- A level is kept only if it removes at least 25 percent of the vertices (`MIN_SAVING`).
- The renderer picks the level just under a third of a pixel (`render/src/lib.rs:2146-2156`).
- This is "distance from last kept vertex" thinning, not Douglas-Peucker and not tile pyramids.
- Separately, the path builder drops any point closer than about 0.35 px to the previous one (`render/src/lib.rs:1049-1062`).
- Features are culled by extent with a margin (`CULL_MARGIN`, `GPU_CULL_MARGIN = 0.5`, a half view on each side, `render/src/lib.rs:140`).

### GPU buffers

- Positions are f32 offsets from a per-command f64 origin, so f32 holds sub-pixel accuracy (`render/src/gpu_scene.rs:1-30`, `mapgpu.rs:1-13`).
- The limit is 2^23 physical pixels from the origin (`F32_REACH_PX`, `gpu_scene.rs:13`).
- Zoomed in past that, features are drawn on the CPU (`gpu_scene.rs:12`).
- Points are instanced markers using a bank of 5 shape templates, 72 vertices each (`mapgpu.rs:68-110`).
- Lines and polygons are tessellated on the CPU into meshes (`DrawCmd::Mesh`), drawn with the painter's algorithm and no depth (`gpu_scene.rs:46-70`).
- Camera fast path: while panning or zooming a pure-vector scene, only a per-draw uniform matrix is rewritten (`GpuFrame::set_camera`, `mapgpu.rs:1432-1450`; use at `mapview.rs:889-905`).
- The scene is rebuilt when motion settles, because culling and thinning depend on the camera (`ui-egui/tests/gpu_fastpath.rs:1-4`).
- The fast path works only if the camera still stays within the culled margin (`scene_covers`, `mapview.rs:3623`).
- Uploaded GPU memory caps: 64 MB of kept tile textures, 256 MB of kept meshes (`mapgpu.rs:626`, `734`).
- Scenes over device limits are refused and fall back to the CPU (`cmd_fits`, `mapgpu.rs:1096`).

### Threads for frames

- Flat tiled, tilted and globe frames are built on a worker named "rustgis-map-frame" (`ui-egui/src/tilt_settle.rs:88-109`).
- The worker gets a clone of the whole `Map` (its big caches are `Arc`).
- The result goes back through an `mpsc` channel and the worker calls `ctx.request_repaint()` (`tilt_settle.rs:101-109`).
- A frame that finishes during a new gesture is thrown away (`mapview.rs:760-766`).
- Plain flat vector frames are drawn on the UI thread, in `render(...)` inside `main_view` (`mapview.rs:945`).
- So a slow vector draw can still block the UI thread.
- That is why the mid-motion budget and shift-and-scale tricks exist.

## 3. Rasters

Raster styling is in `map/src/raster.rs`.
Drawing is in `render/src/raster.rs`.

### Renderers

- Six kinds: Stretch (one band, colour ramp), RGB, Classify (class breaks), Unique Values (max 256), Colormap (file palette), Shaded Relief (`raster.rs:478-500`, `587`).
- Default for a single continuous band: Stretch with grey ramp, resampling Nearest by default unless the app defaults say otherwise (`raster.rs:555-565`, `711-737`).
- Few-category integer bands (16 or fewer values) default to Unique Values (`raster.rs:728-731`).

### Stretch

- Kinds: None, Min/Max, Custom Min/Max, Percent Clip, Standard Deviation, Histogram Equalize (`raster.rs:359-445`).
- The default is Percent Clip with 0.5 percent low and 0.5 percent high (`raster.rs:386-389`).
- The clip parameter is clamped to 0..49 percent (`raster.rs:432`).
- Percentiles come from a 256-bin histogram, with bin step `(max-min)/255` (`data/src/raster/mod.rs:94`, `189-205`).
- Std dev stretch: mean +/- n sigma (default 2, range 0.1 to 10), limited to min..max (`raster.rs:836`).
- Histogram equalise: a cumulative histogram of the same 256 bins used as the lookup curve (`raster.rs:838-851`).
- DRA ("dynamic range adjustment") recomputes the stats from the pixels currently in view each frame (`raster.rs:1`, `render/src/raster.rs:236-239`).
- Brightness (-100..100), contrast (-100..100) and gamma (0.1..10) are a 256-entry LUT applied after colouring (`raster.rs:868-880`).
- Normalised value is quantised to 0..255 and then looked up in a 256-entry ramp LUT (`raster.rs:895-918`).
- So the colour ramp has only 256 levels per draw.

### Ramps

- Ramp stops are linear interpolated, sequential, diverging or qualitative (`map/src/color.rs:73-82`).
- 24 built-in ramps: Ember, Lagoon, Forest, Dusk, Thermal, Diverging, Greys, Terrain, Aurora, Harbour, Viridis, Plasma, Inferno, Magma, Cividis, Batlow, Turbo, Haline, Vik, Roma, Balance, Oleron, Topo, Deep (`color.rs:393-418`).
- Plus the matplotlib library as extra ramps, plus user ramps (`color.rs:230-270`, up to 256 stops, saved as `.rgisramp`).
- Scientific ramps are stored as 33-stop tables, interpolated (`color/scientific.rs`).
- Groups in the picker: Perceptually Uniform, Sequential, Diverging, Topographic, Qualitative, Matplotlib, Custom (`color.rs:232-270`).
- An "invert" flag flips a Stretch ramp (`raster.rs:480`).

### Hillshade

- `ShadedRelief { band, ramp: Option<Ramp>, azimuth, altitude, z_factor }` with defaults 315 degrees, 45 degrees, z factor 1.0 (`render/src/raster.rs:522`, `540`).
- It uses Horn's 3x3 method on the CPU, per screen pixel (`raster.rs:1000-1011`).
- Cell size for slope comes from the raster's own cell size in metres (`render/src/raster.rs:215`, `cell_size_m`).
- The 3x3 window is taken from the source raster around the sampled position, not from the screen neighbours (`render/src/raster.rs:389-400`).
- Blend: `colour * (0.25 + 0.75 * h)`, with h = hillshade 0..1, so the ambient light is 25 percent (`raster.rs:988-994`).
- With no ramp the base is white, giving a grey shade (`raster.rs:990`).
- There is no separate colour+shade opacity and no multiply/overlay choice.

### Nodata, transparency, opacity

- NaN is nodata, and a nodata pixel is transparent (`raster.rs:962`, `paint`).
- A mask can hide extra values, or values inside or outside a range, without changing data (`raster.rs:615-680`).
- Stats are recomputed for the unmasked pixels, sampled to at most 4M (`MASK_STATS_SAMPLE = 1 << 22`, `raster.rs:644`).
- RGBA images and gray-alpha use the alpha band (`render/src/raster.rs:200-205`).
- Layer opacity is the layer "transparency" 0..1, a live slider that applies once on release for a single undo step (`panes.rs:3908-3930`).
- Opacity applies at the final blit, with `PixmapPaint { opacity }` (`render/src/raster.rs:318-321`).
- Layers also have blend modes (`engine/src/cmd/effects.rs:31`, `layer.blend`).

### Resampling and pyramids

- Only two modes: Nearest and Bilinear (`raster.rs:451-475`).
- Unique Values and Colormap force Nearest (`render/src/raster.rs:196-199`).
- The renderer works per screen pixel: each screen pixel is traced back to the grid, then sampled (`render/src/raster.rs:1-6`).
- The exact inverse transform runs on every 8th pixel (`STEP = 8`) and is interpolated between (`render/src/raster.rs:20`, `157-163`).
- So cost grows with screen pixels, not raster size.
- There are no mipmaps and no overview levels used at draw time.
- Zoomed out, Nearest picks one source cell per screen pixel and aliases.
- Bilinear zoomed out also reads only 4 cells, so it aliases too.
- Rows are spread over up to 8 threads when the box is over 64k pixels (`threads_for`, `render/src/raster.rs:418-423`).
- On HiDPI (>= 1.5) it computes at logical resolution and scales up, which saves 4x work (`render/src/raster.rs:94-97`).
- Pyramids exist only at load: a GeoTIFF over `MAX_SAMPLES` is read from its largest fitting overview, or decimated while reading (`data/src/raster/geotiff.rs:725-900`).
- `MAX_SAMPLES` is 120 million samples on desktop, 32 million in the browser (`data/src/raster/mod.rs:32-34`).
- A 10k x 10k single band raster is 100 million samples, which just fits on desktop.
- Pixels are held as f32 per band (`data/src/raster/mod.rs:3`).

### Raster with the GPU path

- Rasters stay "images" in a GPU scene and are shifted and scaled as a cached picture, not re-projected (`mapview.rs:871-875`).
- Colouring is still done on the CPU.

## 4. Styling points and lines by attribute

- Renderers for feature layers: Single, Unique (one colour per value), Graduated (classes), Proportional symbols (`map/src/symbology.rs:668-720`).
- Graduated is classed only: the field is binned by `breaks`, each class has a symbol coloured from a ramp (`symbology.rs:699-710`).
- The class count is 1..12 (`engine/src/cmd/layer.rs:107` params text).
- Class methods, 8 of them: Natural Breaks (Jenks, default), Equal Interval, Quantile, Geometric Interval, Standard Deviation, Arithmetic Progression, Head/Tail Breaks, Manual (`symbology.rs:607-640`).
- There is no continuous colour-by-value for lines or points.
- Colour is per feature, not per vertex.
- A flight line is one feature with one colour, so a line cannot be coloured along its length.
- The legend is a row list under the layer in the Layers pane: expand chevron, swatch and label per class (`panes.rs:1696-1720`, `legend_list` at `4111`).
- Raster legends are a ramp bar with high and low labels, or class rows (`raster.rs:1013-1060`, `RasterLegend`).
- The legend also appears in layouts (`l.shown_legend(scale)`).

## 5. Layers pane

- The panes' look is in the earlier study (section 4 and "Tree and list look").
- Row elements left to right: expand chevron at x+10 (only when there is a legend), visibility checkbox, symbol patch or type icon, name, selection badge at the right (`panes.rs:1683-1776`).
- A click on the checkbox runs `layer.visibility` (`panes.rs:1776`).
- A click on the row picks it, Ctrl/Cmd toggles, Shift picks a range (`panes.rs:1067-1097`).
- A double click on a row opens the Symbology pane on the right (`panes.rs:1783-1787`).
- The row tooltip shows "Raster - W x H - N bands - renderer" (`panes.rs:1790-1800`).
- A layer out of its scale range, hidden, or in a hidden group draws its name in `text_disabled` (`panes.rs:1745-1757`).
- Missing data draws the name in red (`panes.rs:1747`).
- Reorder: drag a row, with a `DraggedLayer` payload and a drop indicator (`panes.rs:1696-1707`, `layer_drop` at `1353`).
- Menu items "Move Up", "Move Down", "Move To Top", "Move To Bottom" exist and are disabled while the list is filtered (`panes.rs:1881-1950`, `2052-2056`).
- Right-click menu for a layer: Zoom To Layers, Show/Hide Layers, Allow/Block Feature Selection, Move, Group, Copy Layer, Paste, Rename, Define Projection, Definition Query, Export, Remove (`panes.rs:1881-2140`).
- Zoom To Layer is `layer.zoomTo`, which unions the layers' `shown_extent()` and calls `s.zoom_to` (`engine/src/cmd/layer.rs:99-108`).
- Remove is `layer.remove`.
- Opacity and all per-layer style are in the Symbology pane (a docked right pane, not a modal), with a Transparency slider (`panes.rs:3908`).
- The Layers pane has no inline opacity slider.
- Layers can be grouped, and a layer can have a min and max scale for visibility (`map/src/lib.rs:110-112`, `755`).
- A "reference scale" per layer exists (`panes.rs:~3900`).
- How layers are added: every action is a command with an id, run by the ribbon, command search and scripts.
- `layer.addData` (Home > Add), `layer.addDataBytes`, `layer.addUrl`, `layer.addSql`, `layer.addDatabase`, `layer.addPhotos`, `layer.addZarr`, `layer.addLayerFile`, `map.addTiles` (`engine/src/cmd/layer.rs:16-40`, `raster.rs:36`, `items.rs:64`, `tiles.rs:67`).
- There is no "add to map" step.
- Adding data puts the layer in the active map at once.
- Large sources are made streamed automatically above 100k features.
- A new layer's default style comes from its data (see section 3 default rules).

## 6. Cursor readout and status bar

- Pointer position is `app.map.pointer_lonlat`, set every frame from `screen_to_lonlat` for the hover position (`mapview.rs:1998-2000`, `1510-1520`).
- The status bar format is covered in the earlier study (section 6).
- The coordinates shown are lon/lat only (decimal degrees or DMS toggle), the projection name next to them.
- It never shows projected easting/northing or layer CRS coordinates.
- There is no value-under-cursor readout in the status bar, for rasters or for features.
- Raster value appears only on a click, in the identify popup, with title "Pixel", bands as attributes and a "Pixel: col, row" row (`engine/src/cmd/raster.rs:806-824`).
- The popup reads the topmost raster at the click, using nearest pixel (`pixel_at`) and not the displayed colour.
- Scale: the status bar has an editable scale box; the scale is `scale_denominator(res, lat)` at the view centre (`camera.rs:433-437`).
- Zoom level, bearing and pitch text are also in the status bar.

## 7. Overlays

What exists:

- Scale bar: bottom-left at 18 px from the left and 22 px from the bottom, target length 130 pt rounded by `scale_distance`, 4 alternating black and white segments, "0" and the distance label (10.5 pt), on a rounded translucent panel (`mapview.rs:2853-2877`).
- North arrow: top-left, 34 px circle at (30, 34) from the corner, with a "N", turns with the bearing, foreshortens with pitch, click resets north (`mapview.rs:2879-2910`, `2811-2825`).
- Navigator: a compass pad with N/S/E/W pan arrows (25 percent of the view per click) and + and - buttons, at (52, 112) from the corner, toggled by a View option (`mapview.rs:3320-3351`).
- Corner buttons: zoom in, zoom out, full extent, 32 px, at the top right (`mapview.rs:2835-2851`).
- Graticule: lon/lat lines, with step 30, 15, 5 or 1 degrees chosen by `res` thresholds 8000, 2000, 400, limited to +/-85 latitude (`render/src/lib.rs:2786-2800`).
- The graticule is drawn into the map frame, with no labels on the lines in what was read.
- Attribution strip: bottom-right (`mapview.rs:2826-2834`).
- Selection highlight: features get a selection set per layer (`l.selection`), shown with a badge count in the Layers pane and drawn by the renderer; box select with Shift+drag draws a translucent accent rectangle (`mapview.rs:2537-2542`).
- Select tools: Select, Select Polygon, Select Lasso, Select Radius (`engine/src/lib.rs:276-285`).
- Identify: a click with the Explore tool runs the `identify` command with `tolerancePx: 5` (`mapview.rs:2371-2373`).
- Identify returns features under the click in all layers by "pop-up mode" (topmost, selectable, selected-in-contents, visible), or the raster pixel when no feature is hit (`engine/src/cmd/select.rs:296-390`).
- The hit marker is a cyan circle with a popup showing attributes, with a resizable popup (`mapview.rs:3063-3270`).
- Measure tools: Measure (distance) and Measure Area, using a sketch with a live readout; clicks snap to features when snapping is on (`engine/src/lib.rs:284-285`, `mapview.rs:2704-2767`).
- Units: metric or imperial, remembered (`docs/user-guide/maps.md:30-40`).
- A magnifier lens showing twice the map under the pointer (CPU texture only, hidden under the GPU path) (`mapview.rs:2590-2620`).
- A hint line for the active tool (`mapview.rs:2768-2802`).
- First-person WASD navigation on tilted maps (`mapview.rs:2028-2065`).

What does not exist (from this read):

- No axis ticks or coordinate labels along the map frame.
- No cursor crosshair readout with value.
- No profile-along-line tool on the map was checked, but "elevation profiles" are mentioned in the units text (`maps.md:36`).

## 8. Threading

- The UI thread runs `main_view` and, for plain flat vector maps, the draw call itself (`mapview.rs:945`).
- Off the UI thread:
  - "rustgis-map-frame": exact frames for tiled flat, tilted and globe views, and CPU fallback frames, via `TiltSettle` (`tilt_settle.rs:88-109`).
  - "rustgis-source": streamed vector reads (`map/src/source.rs:938`).
  - "rustgis-tiles-N": a worker pool for tile and HTTP fetches (`tiles/src/cache.rs:921`).
  - Raster drawing uses scoped threads for rows (up to 8, `render/src/raster.rs:418-445`).
  - Plain spawns for downloads and S3 (`tiles/src/cache.rs:1060`, `1108`, `1144`).
- Results come back three ways:
  - An `mpsc` channel plus `ctx.request_repaint()` for frames (`tilt_settle.rs:101-109`).
  - A `Mutex` slot plus a global `GENERATION` counter and a global waker for source reads (`source.rs:927-945`).
  - A global tile cache keyed by URL, with a generation counter, `set_waker`, and `State::Pending/Ready/Failed` (`tiles/src/cache.rs:150-190`).
- The generation counters are part of the frame `Key`, so new data triggers a redraw (`mapview.rs:690-698`).
- Panics in workers are caught and reported as "no frame", and the key is not tried again (`tilt_settle.rs:92-107`).
- Tile pictures are drawn "at the pace" of moving or settling, a few per frame, so a frame can be a draft (`mapview.rs:1269-1273`).
- Wasm builds run the same work inline (`tilt_settle.rs:115-122`).

## 9. Testing

- `egui_kittest` harness tests drive the real app and wait for workers (`ui-egui/tests/gpu_fastpath.rs:1-60`, `smoke.rs`).
- The fast-path tests serialise on a global lock because the tile cache and source generations are global (`gpu_fastpath.rs:9-15`).
- A `wait_for_frame` helper loops steps and renders until no frame is drawing, with a 60 s hang guard (`gpu_fastpath.rs:20-45`).
- GPU vs CPU parity tests render the same map both ways offscreen and compare: raw mean under 1.5/255 and zero "structural outliers" away from edges (`mapgpu.rs:1872-1923`).
- `PARITY_DUMP=/dir` writes cpu, gpu and a diff PNG for eyeballing (`mapgpu.rs:1885-1900`).
- A golden test checks `view_proj` against `Camera::to_screen` to 1/100 px (`mapgpu.rs:5-6`, `1616-1660`).
- Tests skip when no wgpu adapter exists (`mapgpu.rs:1881`).
- Budget test: an export after a small interaction budget must equal the full-source export pixel for pixel (`render/src/budget_tests.rs`).
- Stream tests use fake chunked sources (`render/src/stream_tests.rs`).
- Benchmarks are cargo examples that print ms per frame, not criterion benches: `vector_tile_bench`, `globe_bench`, `tile_mesh_bench` (`render/examples/`), `planet_bench` (`ui-egui/examples/`).
- `ui_shot` is the headless screenshot tool, JSON-line scripted (see the earlier study section 11).
- The earlier study found no `assert_snapshot` image snapshot tests.
- The camera has pure unit tests (`map/src/camera.rs:540-600`).

## 10. What would be a mistake to copy

1. Do not copy "CPU rasterise to a texture, shift and scale while moving" for flight lines.
   It makes sense for a map with a basemap, but it adds a huge state machine (see `mapview.rs:602-1135`, over 500 lines of key, draft, hold, settle and drape logic).
   A direct GPU draw of retained buffers is simpler for survey data.
2. Do not copy the streaming window with an evenly spread sample cap (250k features, `source.rs:27`, `window.rs:24-39`).
   A flight line is one feature with thousands of vertices.
   Sampling features would drop whole lines, and the thinning is per vertex distance, which can cut real anomalies.
   Magnetic data needs min/max-preserving decimation per pixel bucket, not "drop points closer than 0.35 px" (`render/src/lib.rs:1049-1062`).
3. Do not copy per-feature colour only.
   Colouring a flight line by field value along its length needs per-vertex colour from a continuous ramp.
   RustGIS cannot do it, and its class limit is 12 (`layer.rs:107`).
4. Do not copy the raster draw loop as is.
   - It has no overviews at draw time, so zoomed-out Nearest or Bilinear aliases.
   - A 10k x 10k grid zoomed out to a 1000 px view reads one cell in ten and shows noise as sparkle.
   - Use a mipmap or block-averaged pyramid (or a GPU texture with mipmaps), with a texture on the GPU plus a ramp LUT texture.
5. Do not copy the whole-raster read limit approach (120M samples, decimate on read, `MAX_SAMPLES`).
   For a 10k x 10k grid in f32 (400 MB) it works but it is near the limit, and a decimated read changes the statistics.
   Keep full-res data and compute stats once, then pyramid levels.
6. Do not copy the 256-level ramp quantisation plus a 256-bin histogram for percentiles (`HISTOGRAM_BINS = 256`).
   For magnetics (a wide range with a heavy tail), a 0.5 percent clip from 256 bins is coarse.
   Compute exact or 4096-bin percentiles once and cache.
7. Do not copy the hillshade sampling per screen pixel on the CPU.
   Compute the shade once per grid (or per pyramid level) on load or in a shader, and keep light angle changes cheap.
   Also check units: RustGIS divides by the cell size in metres, so geographic grids need the correct cell size, and magnetic grids in nT need an explicit z factor because "z" is not metres.
8. Do not copy lon/lat-only readout.
   JuliaMag needs projected X/Y in the survey CRS, plus the grid value and the nearest line's name, fiducial and field values at the cursor.
9. Do not copy "identify on click only" for rasters.
   Geophysicists expect a live value under the cursor in the status bar.
10. Do not copy the Web Mercator camera with `res` limits of 1e-4 to 160,000.
    Surveys are in UTM or a local grid, so the camera should be in the survey CRS with no lat clamp.
11. Do not copy the scale-bar and graticule step logic tied to Mercator `res` thresholds.
    Use nice steps in the data CRS units, with labelled ticks on the frame edge, which RustGIS lacks.
12. Do not copy the mixed ownership of state where the UI runs commands by JSON through a global session.
    It is fine for a CLI/MCP product, but it adds cost for a Julia app.
    The command id idea alone is worth keeping.
13. Do not copy global generation counters and a global tile cache as the way to learn that data arrived.
    This forces tests to run one at a time (`gpu_fastpath.rs:9-15`).
    Pass a per-view version counter instead.
14. Do not copy the lack of inertia or animated zoom as a goal.
    It is simple, but instant jumps in Zoom to Layer feel abrupt, and a short eased zoom is cheap once the camera is a plain struct.
15. Note the 32 ms mid-motion budget and "draft then exact" design: it exists because the CPU renderer is slow.
    With a GPU draw of retained buffers, most of it is not needed.

## Conclusions for JuliaMag

1. Draw the map with one OpenGL pass on the central panel region, using retained VBOs for lines, points and one texture per raster.
   Do not copy the CPU-texture path.
   Keep a redraw-on-change policy: redraw only when the camera, data version or window size changes, as RustGIS does.
2. Keep RustGIS's camera interface but use the survey CRS: `center`, `res` (units per pixel), pan by `delta * res`, zoom about the pointer with `factor = exp(scroll * 0.0028)`, and double-click zoom 2x.
3. Copy the gesture map: left drag pans, Shift+drag box zoom or select, middle drag pans, wheel zooms about the cursor, Home = full extent.
   Pad zoom-to-extent by 6 percent.
   Add Previous and Next extent, recorded once per finished gesture.
   Consider a short eased zoom, since RustGIS has none.
4. For flight lines, use per-pixel-bucket min/max decimation (or a precomputed multi-level decimation tree) built on a worker thread.
   Pick the level by `res`.
   Cull by view extent plus a half-view margin like `GPU_CULL_MARGIN = 0.5`.
   Use f32 offsets from an f64 origin, as RustGIS does, because UTM coordinates break plain f32.
   Add colour by a field with a per-vertex scalar and a 1D ramp texture.
5. For grids, upload the grid as an f32 (or R32F) texture with mipmaps or a pyramid.
   Colour in the fragment shader using a 256-entry or larger ramp texture, with NaN as transparent.
   Draw hillshade in a shader or precompute it once.
   Copy RustGIS's defaults: azimuth 315, altitude 45, z factor 1, colour times `(0.25 + 0.75 * shade)`.
   Make z factor visible because of the nT-versus-metres issue.
6. Copy RustGIS's stretch list: None, Min/Max, Custom, Percent Clip (default 0.5/0.5), Std Dev (n = 2), Histogram Equalize, plus brightness, contrast, gamma and a DRA toggle.
   Compute percentiles from a finer histogram than 256 bins.
   Copy the Nearest/Bilinear choice and the opacity slider.
   Default ramp for magnetics: a perceptually uniform ramp (Viridis/Turbo-like), plus the 24-ramp list grouped as RustGIS groups them, plus an invert flag.
   Add a Oasis-style colour-table with equal-area (histogram) distribution as the first-class choice for TMI.
7. Copy the Layers pane behaviour: expand chevron, visibility checkbox, type icon, name, drag to reorder, right-click menu (Zoom To, Show/Hide, Move to Top/Bottom, Rename, Remove), double click opens the style pane, and a row legend (ramp bar for grids, class rows for classified lines).
   Keep layer opacity in the style pane.
   Keep per-layer min and max scale.
   Add layers by a command id (`layer.addGrid`, `layer.addLines`) that adds to the active map at once.
8. Copy the overlay set and placement: scale bar bottom-left (130 pt target, 4 segments), north arrow top-left, corner zoom buttons top-right, attribution or CRS strip bottom-right, hint line for the tool, identify popup with a resize grip.
   Add what RustGIS lacks: coordinate ticks on the frame edge, a live value-under-cursor and nearest-line readout in the status bar, and projected X/Y in the status bar.
9. Copy the tool set and keep it small for plan 4a: Explore (pan + identify with 5 px tolerance), Select (box), Measure (distance with live readout), and a zoom-box.
   Measure should use survey CRS distance, not geodesic.
10. Use worker threads for decimation builds, grid pyramids and stats.
    Return results through a channel or a shared slot plus a "wake the UI" call, as RustGIS does.
    Make the version counter per map view, not global.
    Catch worker failures and show an error, and do not retry the same key.
11. Test the map the way RustGIS does: a headless render path with a CPU reference compared to the GL output (mean error under 1.5/255 and no structural outliers), a golden test of the view transform against the CPU transform to 0.01 px, a wait-until-settled helper with a hang guard, a scripted screenshot tool, and timing examples that print ms per frame.
    Add a real benchmark with a survey-sized fixture (millions of samples, a 10k x 10k grid), which RustGIS does not have.
