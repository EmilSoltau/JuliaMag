# Plan 4a research: drawing the map view in JuliaMag

Repo: `/home/ems/work/_projects/coding-workspace/Mag processing tool/JuliaMag` (branch `dev`, commit `00bb3e7`).
Paths below are relative to the repo root.
Nothing in the repo was changed.
Spike code: `/tmp/claude-1000/-home-ems-work--projects-coding-workspace--sh--Mag-processing-tool/6fff0214-f69e-4305-96ef-73fefd074d74/scratchpad/spike4a/` (`gen.jl`, `spike.jl`, `corereads.jl`).
Spike output: `spike4a/out/results.txt`, `results_bg.txt`, `results_imdraw.txt` and the PNG screenshots in `spike4a/out/`.
Machine: Intel i9-13900 (32 threads), 23 GB RAM, WSL2.
GL: "D3D12 (Intel(R) UHD Graphics 770)", Mesa 23.2.1, OpenGL 4.1 core, under Xvfb.
So the GPU numbers are for an integrated Intel GPU behind a translation layer.
The file reads were from a warm page cache.

## 1. Core data access today

### 1.1 Line databases

- A database is a folder with `database.json` and one raw file per channel (`JuliaMagCore/src/storage/columns.jl:1-28`).
- All lines sit end to end in each channel file; a line is rows `offset+1 : offset+nrows` (`JuliaMagCore/src/storage/database.jl:1-3`, `LineInfo` in `JuliaMagCore/src/model/types.jl:32-44`).
- So X of all lines is one contiguous array on disk.
  A map can read it with one sequential read per channel, not 2000 small ones.
- `read_channel(db, id, name)` returns a view into a memory map of the whole channel file (`database.jl:514-529`, `mapped` at `database.jl:478-493`).
  The maps are cached in `db.maps` per channel (`database.jl:46-47`).
- The declared return type is `::AbstractArray`, and inference gives a large `Union` (measured with `Base.return_types`).
  A loop over its result without a function barrier is type-unstable.
  In the spike the same 20 M point pack took 6.3 s without a barrier and 0.13 s with one.
- `block_reader` / `read_block` read rows with plain file reads into a reused buffer, no map (`database.jl:550-652`).
  The comment there says why: on Windows a mapped file cannot be grown, cut or renamed (`database.jl:440-457`, `release_map!` runs `GC.gc()` on Windows).
- Measured (`corereads.jl`, warm cache): X of all 20 M rows took 14.8 ms through `read_channel` and 24.8 ms through `block_reader`.
- Positions: a `PositionPair` names the x and y channels and their CRS (`types.jl:66-72`); `db.current_pair` picks one (`database.jl:41-42`).
- Reprojection: `Reprojector` and `reproject!` (`JuliaMagCore/src/crs/crs.jl:405-513`).
  Measured: 8.6 M points/s on one thread (lon/lat to UTM).
  So 20 M lon/lat points take about 2.3 s on one thread; this must be cached, not done per view change.
- `database(p, id)` opens a new `LineDatabase` each call (`JuliaMagCore/src/project/project.jl:211-216`).
  The snapshot opens each database once per build (`JuliaMagUI/src/app/state.jl:160-174`).

### 1.2 Grids

- A grid is a folder with `grid.json` and one raw `values.f32` or `values.f64` file, row 1 first, as a Julia `(nx, ny)` matrix (`JuliaMagCore/src/storage/grid.jl:1-12`).
- `read_rows(g, j1, n)` and `read_rows!` read whole rows with plain reads (`grid.jl:224-249`).
  There is no read of a column window, so a tile means reading a band of full rows.
- `with_grid_values` maps the whole file (`grid.jl:267-312`).
- `GRID_BLOCK_BYTES` is 16 MiB per block (`grid.jl:90`, `block_rows` at `grid.jl:211-216`).
- Georeference: `x0, y0` is the centre of the lower-left cell, `dx, dy`, `rotation` in degrees (`grid.jl:7-9`, `cell_centre` and `grid_corners` at `grid.jl:322-342`).
- `GridStyle` holds `colours`, `method` (`:linear`, `:histeq`, `:normal`, `:loglinear`), `min`, `max`, `reverse`, `shade`, `azimuth`, `altitude`, `zfactor` (`grid.jl:23-37`).
  Every field maps to a shader uniform.
- `grid.json` stores `vmin`, `vmax`, `count` (`grid.jl:61-85`); the snapshot copies them into `GridView` (`JuliaMagUI/src/app/state.jl:63-86`).
- Measured: reading the 8000 x 8000 Float32 grid with `read_rows` took about 0.1 s.

### 1.3 Statistics and colour tables

- `channel_stats` and `grid_stats` give count, min, max, mean, std, exact median, p5, p95 and a 64-bin histogram (`JuliaMagCore/src/builtin/statistics.jl:28-47`, `:334-366`).
- They read the data three or more times (`statistics.jl:1-24`).
  Measured: `grid_stats` on 8000 x 8000 took 3.1 s; `channel_stats` on 20 M rows took 1.05 s.
- `colour_tables()` returns names and labels only (`grid.jl:39-46`).
  There are no colour values anywhere in the core or the UI.

### 1.4 What a map needs that the core lacks

1. A map item.
   `ITEM_MAP` exists as a kind (`project.jl:21-24`), but there is no map struct, layer list, layer style, create or edit call, or undo step for it.
2. Extents.
   No line, database or channel stores a bounding box.
   The map needs a per-line bbox of the current pair for culling and "zoom to".
   The import sink can compute it while it writes, as it does `vmin`/`vmax` for grids.
   Edits to X or Y (`set_cell!`, Channel Math, Set Current X,Y, reprojection) must update or drop it.
3. A typed bulk read for the map.
   Something like `read_xy_values(db, x, y, value; lines) -> (Vector{Float32}, ...)` that reads whole channel files with plain reads into caller buffers, packs to Float32 relative to an origin, and returns line offsets and bboxes.
   It should not hand out mmap views: a view held by a map cache would block undo, append and rename on Windows (`database.jl:440-448`).
4. Grid overviews.
   No overview or pyramid exists.
   For grids larger than about 4 x the screen, the map needs NaN-aware reduced levels (see 3.2).
5. Fine histograms for stretches.
   Histogram equalization needs a fine CDF (1024-4096 bins), not the 64 bins of `ChannelStats`.
   Linear stretch defaults (p2-p98 or p5-p95) can come from the same CDF.
   One pass gives both; the exact-quantile passes are not needed for display.
6. Colour table values.
   A pure function such as `colour_table(name) -> Vector{NTuple{3,UInt8}}` (256 entries) next to `colour_tables()`, so the render thread can build a LUT texture without the worker.
7. Change tracking per item.
   `Core.revision(s)` is one counter for the whole session (`JuliaMagCore/src/session/session.jl:172-198`).
   A map cache needs to know which item or channel changed, so it reloads only that layer.
   A per-item data generation number (bumped on any write to its files) would do it.

## 2. Drawing approach in this stack

### 2.1 What the loop does now

- The app has its own copy of the CImGui GLFW/OpenGL3 loop (`JuliaMagUI/src/app/loop.jl:1-4`).
- `draw_frame!` runs `NewFrame`, `ui(w)`, `ig.Render()`, then `glViewport`, `glClear` and `ImGui_ImplOpenGL3_RenderDrawData` on the default framebuffer (`loop.jl:225-262`).
- It idles with `glfwWaitEventsTimeout` when nothing changes, and `wake!` makes it draw (`loop.jl:75-84`, `:415-435`).
- `guarded_frame` wraps the whole UI draw; an error restores ImGui's stacks and becomes a toast (`JuliaMagUI/src/JuliaMagUI.jl:207-224`).
  It does not restore any GL state.
- The icon atlas shows how textures are already handled: `glTexImage2D` with error checks against `GL_MAX_TEXTURE_SIZE`, shown through `ig.ImTextureRef(ig.ImTextureID(id))` (`JuliaMagUI/src/theme/icons.jl:280-322`, `:421-425`).

### 2.2 The three options

(a) Render with GL into an offscreen FBO, show its colour texture with `ig.Image`.

- Map drawing is plain GL with its own shaders, VBOs and textures.
- ImGui sees one textured quad, so docking, clipping, overlays (scale bar, cursor, tooltips) and hit testing stay ImGui's.
- The map does not need to redraw when only the UI changes: the texture can be reused for frames where the view and layers did not change.
- Costs one extra full-panel blit (negligible in the spike).
- The spike used this, and it worked under the existing GL 3.3 core profile.

(b) An `ImDrawList` callback that issues raw GL inside `RenderDrawData`.

- Needs a `@cfunction` called from C++ during `RenderDrawData`.
- A Julia exception there cannot unwind through the C++ frames, so `guarded_frame` cannot catch it; it would crash the app.
- It must save and restore all GL state the ImGui backend expects, and it must redraw every frame.
- Not recommended.

(c) `ImDrawList` primitives (`AddPolyline`, `AddImage`).

- CPU builds the vertex data each frame, through `ccall` per call.
- Measured: 200 k points cost 1.9 ms CPU per frame, 1 M points cost 9.9 ms and 20.6 ms wall.
- 20 M points would cost about 200 ms per frame.
- Good only for small overlays: the cursor, the selected line highlight, the marked range, a scale bar.

Recommendation: (a), with (c) for small overlays on top of the image.

### 2.3 How (a) fits the loop and the frame guard

- Keep all map GL out of ImGui code.
  In `ui()` the map pane only records a "map draw request" (pane size, view, layer list) and calls `ig.Image` with the map's texture id.
- In `draw_frame!`, after `ig.Render()` and before `RenderDrawData`, run the recorded map passes (`loop.jl:246-252`).
  ImGui only stores the texture id, so the image still shows this frame's map.
- Resize the colour texture in place with `glTexImage2D` on the same id, so the id that `ui()` recorded stays valid.
- Wrap the map pass in its own `try ... finally`:
  the `finally` binds framebuffer 0, resets the viewport, unbinds the program, VAO and textures.
  If the FBO stayed bound, `RenderDrawData` would draw the whole UI into it and the window would go blank.
  An error in the map pass should be noted like a draw error (`note_draw_error!`) and leave the last good texture.
- Check `glGetError` after uploads, as `upload!` does for icons (`icons.jl:280-312`), and turn `GL_OUT_OF_MEMORY` into a layer error, not a crash.
- Shaders: compile once per GL context at first use; keep the sources as Julia strings in a `map/shaders.jl`.
  Delete GL objects only on the render thread, while the context is current (as `forget_icons!` does at `loop.jl:403`).
- Redraw policy: the map texture is redrawn only when the view, the layers, a style or the uploaded data changed.
  The idle loop then costs nothing extra.
- Precision: GL works in Float32.
  UTM northings near 7,000,000 m have about 0.5 m Float32 spacing.
  Store vertices relative to a per-layer origin (the spike used the first point, floored) and pass the view as scale and offset relative to that origin.
  Then 100 km surveys keep about 1 cm precision.

## 3. Level of detail

### 3.1 Line paths

Test data (`gen.jl`): 2000 E-W lines x 10,000 points, 10 m spacing, 50 m line spacing, a 100 x 100 km block, MAG coloured through a 256-entry LUT.
The map panel was 1584 x 955 px.
At 70 m/px the panel shows the full width and about two thirds of the height (13.4 M of 20 M points in view).
Times are medians while panning about 20 px per frame, with vsync off.
"GPU" is a `GL_TIME_ELAPSED` query around the map pass.

| Case | Points drawn | GPU med | GPU p95 | Wall med | Wall p95 |
|---|---|---|---|---|---|
| All points, whole survey | 13.4 M | 15.6 ms | 29.6 ms | 19.7 ms | 34.6 ms |
| Min/max LOD (bucket 8), whole survey | 3.4 M | 5.2 ms | 5.4 ms | 9.3 ms | 9.7 ms |
| All points, MSAA 4x | 13.4 M | 29.2 ms | 31.6 ms | 33.4 ms | 35.9 ms |
| Zoom 10x, bbox culling | 1.34 M | 1.6 ms | 1.7 ms | 5.6 ms | 6.0 ms |
| Zoom 10x, no culling | 20 M | 21.4 ms | 21.4 ms | 25.7 ms | 26.2 ms |
| Zoom 100x, bbox culling | 0.15 M | 0.17 ms | 0.20 ms | 3.9 ms | 4.3 ms |

Wall time includes ImGui, the swap and Xvfb; with an almost empty map it is about 4 ms here.
CPU time for the map pass (culling 2000 bboxes, building the `glMultiDrawArrays` lists, uniforms) was 0.13-0.25 ms.

The strategies compared:

- GPU only, all points in VBOs.
  Simple, and fine when zoomed in.
  Zoomed out it is GPU bound: 15-21 ms for 13-20 M points on this iGPU, with p95 spikes to 30 ms.
  VRAM: 12 bytes per point (Float32 x, y, value), so 240 MB for 20 M points.
  At 50 M points that is 600 MB, too much for many laptop GPUs.
- Culling by line bbox.
  Nearly free on the CPU (2000 tests) and it scales the work with the zoom.
  It does nothing for the zoomed-out case, where every line is in view.
- Per-line min/max decimation by screen pixel, done each view change on the CPU.
  It keeps spikes but costs a pass over all points (about 0.1-0.15 s for 20 M) at each zoom step, plus a new upload.
  That is too slow for smooth zooming.
- Precomputed multi-resolution levels (the spike's approach).
  Each level keeps, per bucket of `b` points, the point with the minimum value and the point with the maximum value, in order, plus the line ends.
  So a spike in the channel survives at every level.
  Built from the full set: bucket 8 in 0.14 s (25 % of points), bucket 64 in 0.07 s (3.2 %), bucket 512 in 0.04 s (0.4 %).
  All levels together add about 29 % to the base level in memory.
  The level is picked per frame: the largest bucket whose ground length is under 2 px.
  At 70 m/px this gave bucket 8 and cut the GPU time from 15.6 ms to 5.2 ms, with no visible change (`lines_full.png` vs `lines_lod.png`).
- Recommended: precomputed levels plus bbox culling, built on the worker when a layer is first shown, not at import.
  Build time is small (well under 1 s for 20 M points), so a stored pyramid file is not needed yet.
  Keep the build in the core so a later version can store it next to the channel files if 50 M point loads need it.
- Further cut for very dense views: when lines are closer than a pixel (2000 lines in 955 px here), only every n-th line in view adds nothing visible.
  Do not drop lines silently, though; the user checks for gaps by eye.
  A better later step: when more than about 2 points fall on each pixel, also choose by "points per pixel" across lines, not only along them.

Other notes for lines:

- `glLineWidth` above 1 is not allowed in a forward-compatible core profile; the range here was [1, 1].
  Thick or selected lines need quads (instancing or a geometry shader) or ImDrawList for the few selected lines.
- MSAA 4x nearly doubled GPU time.
  Keep it off for the main line layer, or offer it as a setting.
- Missing X or Y (dummy values) must split a line into parts on the CPU; a NaN vertex in a strip is undefined in GL.
- One `glMultiDrawArrays` call per level draws all visible lines; draw calls are not a cost.

### 3.2 Grids

The spike cut the 8000 x 8000 grid into 4 x 4 tiles of 2048 cells with a 1-cell border (2050 x 2050 `GL_R32F`), with NaN-aware 2 x 2 mean mip levels built on the CPU.

| Case | GPU med | GPU p95 | Wall med |
|---|---|---|---|
| Whole grid, histeq LUT + hillshade | 1.05 ms | 1.16 ms | 5.4 ms |
| Zoom 20x, histeq + hillshade | 1.17 ms | 1.23 ms | 5.8 ms |
| Whole grid, linear, no shade | 0.77 ms | 0.88 ms | 5.8 ms |
| Grid + lines (LOD), whole | 6.4 ms | 6.6 ms | 11.0 ms |
| Grid + lines (all points), whole | 16.4 ms | 16.5 ms | 20.7 ms |

- Texture tiling.
  `GL_MAX_TEXTURE_SIZE` was 16384 here, but older Intel and some Windows drivers give 8192, and a 10k x 10k grid also breaks single-buffer limits.
  Tiles of 2048 (or 4096) keep each upload small and allow loading only the tiles in view.
- Mip levels and overviews.
  `glGenerateMipmap` took 11 ms per tile, but it averages NaN into NaN, so the survey edge would erode at each level.
  CPU NaN-aware means took 35 ms for all 16 tiles on 8 threads.
  Mip sizes must follow GL's rule (floor of half, down to 1); the first spike run used ceil, the texture was incomplete and drew as one flat colour.
- Memory: R32F with mips is about 1.33 x 4 bytes per cell: 359 MB for 8000 x 8000, about 530 MB for 10k x 10k.
  That is too much to keep fully resident for several grids on an iGPU.
  Plan for: resident overview levels for the whole grid (a 1/4 level of 10k x 10k is 25 MB), plus full-resolution tiles only for the view, in an LRU with a VRAM budget.
  R16F would halve it, but it loses precision for magnetics (about 3 significant digits); keep R32F.
- Float textures and colour mapping in the shader.
  The shader samples the value, maps it to `t` with `(v - min) / (max - min)`, optionally through a 4096-entry CDF texture for histogram equalization, and then into a 256-entry RGBA LUT.
  Changing the colour table, stretch or histeq is then just a uniform or a 1 KB to 16 KB texture update, with no re-upload of the grid.
  The CDF is built on the worker in the same pass that reads the tiles (0.22 s for 64 M cells together with tile cutting).
- Hillshade in the shader vs on the CPU.
  In the shader it costs about 0.3 ms more GPU per frame here, and sun azimuth, altitude and z-factor change live.
  The spike computes the gradient from four neighbour samples at the current mip level, so it stays correct when zoomed out.
  Problem seen: faint 1-pixel seams at tile edges when zoomed out (`out/crop_seam.png`), because the 1-cell border is only half a texel at level 1 and gone below.
  Fixes: a wider border (for example 2^k cells for k levels), or sampling the neighbour tile, or shading the overview levels from one overview texture.
  A CPU hillshade would need recomputing for each sun change and doubles memory; prefer the shader.
- Rotated grids: draw each tile as a rotated quad; the shader works in cell space, so rotation is free.
- NaN cells: `discard` in the fragment shader; linear filtering makes the edge 1 cell narrower, which is acceptable.

## 4. Threading

What runs where:

- Worker (through `submit!`, `JuliaMagUI/src/app/worker.jl:165-170`), never the render thread:
  - read X, Y and the colour channel with plain reads into reused buffers; pack to Float32 relative to an origin; per-line bboxes; split at missing values;
  - reproject when the pair's CRS differs from the map's (2.3 s per 20 M points single-threaded, so cache it per layer);
  - build the LOD levels;
  - read grid bands, cut tiles with borders, build NaN-aware levels, build the fine histogram and CDF;
  - produce plain `Vector{Float32}` / `Matrix{Float32}` results, never mmap views.
- Render thread:
  - GL uploads, from the worker's buffers, in small pieces per frame;
  - the map pass, LUT and CDF textures, uniform changes.
- The serial worker is one queue for all session work (`worker.jl:1-5`).
  A 1-2 s map load there would delay an Undo click.
  Better: map loads run on their own task (or a second map queue) that reads only files of items that are not busy for writing.
  They must still respect the core's busy marks (`check_not_busy`, `JuliaMagCore/src/session/session.jl:604-615`); with `:append` marks readers may share.

Keeping frames under 16 ms while a big layer loads:

- Upload budget per frame.
  On this driver, `glBufferSubData` into one big 240 MB buffer took 25-50 ms per call even for 1 MB.
  A new buffer per chunk (`glBufferData`) took 0.85 ms for 1 MB, 1.5 ms for 4 MB, 2.5 ms for 8 MB (about 3 GB/s).
  So store lines as many VBOs of about 4-8 MB each (a batch of lines), not one huge buffer, and upload one or two per frame.
  A whole-buffer `glBufferData` of 240 MB took 120 ms: never do that in one frame.
- Grid tiles: one 2050 x 2050 R32F tile with all levels took 5.2 ms median, 16 ms max.
  Streaming one tile per frame while drawing raised the wall time from 11.0 to 14.1 ms median (15.6 ms p95).
  Streaming 8 MB of line data per frame gave 12.6 ms median, 13.3 ms p95.
  So one tile or one 4-8 MB line batch per frame fits a 16 ms frame on this machine.
- Draw what is ready.
  Show the coarsest level or overview first (uploaded in one frame), then refine as tiles and batches arrive.
- Garbage collection is the biggest risk found.
  With a worker thread reading and decimating 20 M points again and again (allocating about 300 MB per round), the render thread's wall time had p95 31 ms and max 70 ms, against p95 12 ms without it (`out/results_bg.txt`).
  Julia's GC stops all threads, including the render thread, while it runs.
  The loop's GC-safe waits help only while the render thread is waiting (`loop.jl:193-200`).
  Mitigations: the loader reuses preallocated buffers (allocation-free reads, as `read_rows!` and `read_block` already allow), frees big arrays by reuse not by garbage, and the render thread allocates nothing per frame in the map pass.
- Keep the map pass allocation-free: the spike built two small `Int32` vectors per frame for the draw lists; reuse them in the real code.

## 5. Spike

How it was run (headless only, never on the desktop):

```
cd /tmp/claude-1000/-home-ems-work--projects-coding-workspace--sh--Mag-processing-tool/6fff0214-f69e-4305-96ef-73fefd074d74/scratchpad/spike4a
~/.juliaup/bin/julia -t 8 --project=../hl/env gen.jl
xvfb-run -a -s "-screen 0 1920x1080x24" env -u WAYLAND_DISPLAY ~/.juliaup/bin/julia -t 8,1 --project=../hl/env spike.jl
```

The env is the existing `scratchpad/hl/env` (the repo Manifest with JuliaMagCore and JuliaMagUI developed).
`gen.jl` writes the test data with JuliaMagCore (`create_database`, appenders, `create_grid`, `write_rows!`): a 383 MB database and a 245 MB grid, in 2.2 s.
`spike.jl` reads them back with `read_channel` and `read_rows`, opens a GLFW + CImGui window (GL 3.3 core, as `loop.jl` asks), and draws into an FBO shown with `ig.Image`.
Options: `NF` frames per case, `SCEN` (comma list) to run some cases, `RES` result file name.

Measured numbers (see the tables in section 3 for frame times):

- CPU, as the worker would run it:
  - read 20 M points of X, Y, MAG, pack to Float32 and per-line bbox: 0.13 s (6.3 s without a function barrier);
  - LOD levels: 0.14 s, 0.07 s, 0.04 s;
  - grid tiles + fine histogram: 0.36 s in all (read 0.10 s, cut + histogram 0.22 s, mips 0.035 s).
- Uploads (with `glFinish`):
  - lines full level 240 MB: 120 ms (2.0 GB/s); all four levels 309 MB;
  - grid 16 tiles with levels, 359 MB: 102 ms in all, 5.2 ms median per tile;
  - chunked uploads: see section 4.
- GPU memory: the driver has neither `GL_NVX_gpu_memory_info` nor `GL_ATI_meminfo`, so only the allocated size is known: 309 MB lines + 359 MB grid = 668 MB.
- ImDrawList: 200 k points 1.9 ms CPU, 6.6 ms wall; 1 M points 9.9 ms CPU, 20.6 ms wall.
- Screenshots: `out/lines_full.png`, `lines_lod.png`, `lines_zoom10.png`, `lines_zoom100.png`, `grid_whole.png`, `grid_zoom.png`, `grid_linear.png`, `grid_lines_lod.png`, `imdraw_200k.png`, plus crops `crop_zoom10.png` and `crop_seam.png`.
  They show the grid with histeq colours and hillshade, the NaN survey edge, the lines coloured by MAG, and the faint tile seams of the shaded overview.

## 6. Risks, unknowns, and what to measure on Windows

Risks and unknowns:

- GC pauses from the loader thread stall the render thread (measured up to 70 ms here).
  This is the main risk for "smooth while loading".
- VRAM on laptops with iGPUs.
  Full-resolution lines plus a big grid were 668 MB here.
  Need a budget and eviction, and a clear message when `GL_OUT_OF_MEMORY` happens.
- Driver-specific upload behaviour.
  The slow `glBufferSubData` seen here may be a D3D12-on-WSL quirk; native Windows drivers may differ in either direction.
- Windows file mapping: any mmap view kept by the map blocks undo, append, rename and delete of that channel (`database.jl:440-448`).
  Use plain reads for the map loader.
- Float32 precision: always draw relative to a layer origin.
- `GL_MAX_TEXTURE_SIZE` may be 8192 on old Intel; tiles of 2048 avoid it.
- Line width 1 only in core profile; thick and selected lines need their own path.
- Hillshade seams at tile edges when zoomed out; needs a wider border or an overview texture.
- The single serial worker could make the UI feel slow if map loads queue ahead of user actions.
- Tests: pixel results differ by driver (the UI README already avoids golden images); test the map with logic tests (LOD choice, culling, tiling math, CDF) and a few screenshot reviews.
- Not measured: cold-cache reads from disk (the bench files were in the page cache), files bigger than RAM, 50 M points, HiDPI (FBO size must use the framebuffer scale, not window size).

What to measure on Windows later:

1. `GL_RENDERER`, `GL_MAX_TEXTURE_SIZE`, and which memory extensions exist, on the target laptops (Intel iGPU, NVIDIA, AMD).
2. Map pass GPU time (timer query) for 13-20 M points, all points vs LOD, at 1080p and at 4K / scale 1.5.
3. Upload cost per frame: `glBufferData` of 1/4/8 MB new buffers vs `glBufferSubData`, and `glTexSubImage2D` of one 2050^2 R32F tile.
4. Frame time p95 and max while a 20 M point layer and a 10k x 10k grid load, with the real loader on another thread (GC pauses).
5. VRAM use from Task Manager (Dedicated and Shared GPU memory) with the layers loaded.
6. Cold-cache load time of a 50 M point database and a 10k x 10k grid from an NTFS disk.
7. That an undo or append on a channel works while its map layer is shown (no mapped file left open).
8. Vsync on: that panning stays at the monitor rate with the idle loop (`wake!` per input).

## Conclusions for JuliaMag 4a

- Draw the map with plain OpenGL into an FBO and show it with `ig.Image`; use ImDrawList only for small overlays.
- Run the map GL pass in `draw_frame!` between `ig.Render()` and `RenderDrawData`, in its own `try ... finally` that restores framebuffer 0 and the viewport.
- Lines: Float32 vertices relative to a layer origin, many 4-8 MB VBOs, one `glMultiDrawArrays` per level, bbox culling, and precomputed min/max LOD levels built on a worker when the layer is first shown.
  This kept 20 M points at 5 ms GPU zoomed out and under 2 ms zoomed in on an Intel iGPU.
- Grids: R32F tiles of 2048 with NaN-aware levels built on the CPU, colour by LUT and histeq CDF textures in the shader, and hillshade in the shader.
  The grid pass took about 1 ms GPU.
- Load in the background and upload at most about one tile or one 4-8 MB batch per frame; show coarse levels first.
- Make the loader allocation-free, because GC pauses (up to 70 ms here) are the main threat to smooth frames.
- Core work needed first: a map item with layers and styles, per-line extents, a typed plain-read bulk loader for X/Y/value, colour table values, a fine CDF for stretches, per-item change counters, and later stored grid overviews.
- Measure on Windows before building on these numbers: GPU times, upload costs, VRAM and GC stalls.
