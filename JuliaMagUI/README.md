# JuliaMagUI

JuliaMagUI is the desktop app of JuliaMag.
It is a window built with CImGui and GLFW on top of `JuliaMagCore`.
Windows is the main platform; Linux works too.

## Start the app

Install Julia 1.12 or newer first.
From the repository root, run the launcher for your system:

```
bin/juliamag.sh [project folder]
bin\juliamag.cmd [project folder]
```

- The optional argument is a project folder to open.
- Without it, the app opens the last project when the setting "Open Last Project" is on.
- Set `JULIA` to use another Julia than the one on the `PATH`.
- The first start installs and precompiles the packages and takes a few minutes.
  Later starts take about 2.5 s on a fast machine.

The launchers run this command, which also works by hand:

```
julia -t auto,1 --project=JuliaMagUI bin/start.jl [project folder]
```

`bin/start.jl` checks that every package of the manifest is installed.
The check takes a few milliseconds.
When a package is missing, it runs `Pkg.instantiate()` in a separate Julia process first.
Then it starts the app with `JuliaMagUI.main(ARGS)`.

`-t auto,1` gives the jobs one thread per core and keeps one interactive thread for the window.
Without it, the app shows a warning: "JuliaMag runs with one worker thread. Start it with -t auto for faster jobs."
Until the app is packaged (plan 5), the launchers are how to start it.

On Linux, the file and folder dialogs need GTK 3.

App settings are in a JSON file in the user's config folder: `%APPDATA%\JuliaMag` on Windows, `~/.config/juliamag` on Linux.
`JULIAMAG_CONFIG_DIR` sets another folder.
The log file `juliamag.log` is in the same folder.

## What the shell does

The shell is the frame the tools live in.

- The header has the app name, the quick access buttons (New, Open, Undo, Redo, theme), the project name and the command search (Ctrl+K).
- The ribbon has the tabs Database, Database Tools, Coordinates, Grid and Image, Map, Settings and Help.
  Project opens the backstage: Start, New, Open, Close, Run Script and About.
- The left pane has the Data tab (the project tree with its context menus and the properties of the selected row), the Layers tab and the Jobs tab.
- The central area shows the current map.
- The right pane has the Tools pane and the Layer Style pane.
- The status bar shows the current database, the selected lines, the running jobs and the renderer.
  While a map is shown, it also shows the map's coordinate system, the pointer's position and the values under the pointer.
- Tool, import and export dialogs are built from the settings of each tool.
- Toasts tell what happened; a failed job keeps its toast longer.

Every change goes through an undoable core call, so Ctrl+Z and Ctrl+Y work for all of them.
The render loop draws from a snapshot of the project.
On the render thread, the app calls only core functions that are pure or read the global registries (tool, importer and exporter lookups), and reads a job's status and progress.
Every core call that touches a session, a file or a database runs on one worker queue.
So a slow tool, an undo of a big channel or a close that waits for jobs never freezes the window.

## The map view

A map shows databases as lines and grids as coloured images, in layers.

### Show data on a map

- Right click a database or grid in the Data tab and choose Show on Map.
  With no map shown, this makes a new map ("Map 1") with the item on it.
  With a map shown, the item goes on that map as a new layer.
  When the item is on the shown map already, its layer is selected and the map zooms to it.
- Add Item in the Map tab adds any database or grid of the project to the shown map.
- New Map makes an empty map.
- A line layer goes on top; a grid layer goes above the other grids and below the lines.
- A line layer is coloured by the first plain data channel, such as MAG.
  A fiducial channel (`FIDUCIAL`, `FID`) colours it only when there is no other.
- A map's layers and styles are saved at once in the project, in `maps/<id>/map.json`.
  Every change of a map is one undo step.
  The view (where you look) is not saved: a map opens at its full extent.

### Move around

- Drag with the left or the middle button to pan.
- Turn the wheel to zoom about the pointer.
- Hold Shift and drag a box to zoom to it.
- Home, or Full Extent, fits all layers.
  The nav buttons at the top right zoom in, zoom out, fit all layers and go to the cursor.
- Previous Extent and Next Extent walk back and forward through the views you had.
- Zoom to Layer fits the selected layer.
- Until you move the view, the map keeps to its full extent: when more data comes in, when the window or the UI scale changes, and when the colour bars show or hide.
- The full extent fits inside the coordinate bands at the top and left.
  When the data would reach under the scale bar at the bottom left or the colour bars at the bottom right, it fits beside them, between them or above them, whichever shows it largest.

### The cursor and the status bar

- A click near a line moves the shared cursor to the nearest point, within 20 px.
  A ring marks it on the map.
  Moving the cursor is not an undo step.
- Go To Cursor centres the map on the cursor.
- While the pointer is over the map, the status bar shows its position, the value of each grid under it, and the nearest line point with its line, fiducial and value.

### Layers and styles

- The Layers tab lists the layers of the shown map, the top layer first.
  Tick a layer to show or hide it, and drag rows to change the drawing order.
  The selected layer has an opacity slider.
- Double click a layer, or choose Layer Style, to open the Layer Style pane.
  Each change there applies at once and is one undo step.
  The sliders draw the map live and set the value when you let go.
- A line layer has its own colours: the channel to colour by, the colour table, reverse, and the stretch (Linear, Clip or Equalize).
- A grid layer without its own style follows the grid's default style.
  A grid style that still has the stock colour table uses the app's "Grid colours" setting (Settings tab).
  Untick "Use the grid's default colours" to give the layer its own colours.
  It starts from the colours shown, so the map does not change until you change them.
- Shading is per layer: Hillshade, the sun's inclination and declination, and the vertical scale.
  A blank vertical scale is automatic: 2.5 over the mean gradient of the grid.
  So two layers of one grid can be shaded in different ways, and shading never changes the grid's own style.
- Cells draw Nearest (square cells) or Bilinear (smooth).
- The Map tab's Hillshade, Colour Bars and Line Labels turn those on and off.
  Colour Bars shows a legend card for each coloured layer at the bottom right.

### GPU and CPU drawing

- The map draws with the graphics card (OpenGL 3.3) when it can.
  Lines go up in batches and grids in tiles of 2048 cells, one per frame, coarse levels first, so the window never freezes while a big layer loads.
- Lines draw at a level of detail that keeps at most about one point per two view pixels.
  Each level keeps the lowest and highest value of each run of points, so spikes stay visible.
- When a full picture takes longer than a frame (on a slow card or on the CPU), the last picture moves and scales while you pan or zoom.
  The full picture follows once the gesture settles.
- The Map Drawing setting in the Settings tab chooses who draws the maps:
  - Auto: the graphics card when it can, else the CPU.
  - Graphics Card: the same, but a toast says so when the card cannot draw the maps.
  - CPU: always the CPU, in a task on the worker threads.
- When OpenGL fails while drawing the map, the map moves to the CPU for the rest of the session, and a toast says why.
- The status bar says "GPU", "Software" (a software OpenGL driver such as llvmpipe) or "CPU map", with the reason in its tooltip.
- The Software Rendering setting is separate: it chooses the OpenGL driver of the whole window at the next start.

## How tools appear in the shell

A tool registers in `JuliaMagCore` with a `ToolSpec`; the shell needs no code for it.

- `places`: a list of `Place(tab, group; size, order)`.
  Each place is a button in that ribbon tab and group.
  A tab with no buttons is not shown.
- `size`: `:big` is a 70 px button with a 32 px icon; `:small` is a 22 px button, three to a column.
  `order` sorts the buttons of a group.
- `inputs`: the item kinds the tool needs.
  While the project has no such item, the button is greyed and its tooltip says why, such as "Import a grid first."
- `settings`: each setting becomes a field of the tool's dialog.
  A setting with `when = "mode" => ["append"]` shows only while the setting `mode` has one of those values.
- `mode`: a `:quick` tool runs at once and shows its report; a `:job` tool runs in the background and shows in the Jobs tab.

Every tool is also in the command search and in the Tools pane.
Importers and exporters show in the Import and Export split buttons of their tab.

## Tests

From the repository root:

```
julia -t auto,1 --project=JuliaMagUI -e 'using Pkg; Pkg.test()'
```

- Logic tests need no window.
- Window tests drive the real app with ImGuiTestEngine.
  They need a display: always on Windows, and on Linux when `DISPLAY` or `WAYLAND_DISPLAY` is set.
  Without one, they are skipped and the reason is printed once.
- `test/window/test_end_to_end.jl` is a user's first day in one window, at scale 1 and 1.5: a new project, an import, Statistics, Channel Math with undo and redo, a grid and its coordinate system, line selection, the dark theme, an export from the command search, closing and opening the project again, and closing the window.
- `test/window/test_map_end_to_end.jl` is a user's first map in one window, at scale 1 and 1.5, light then dark: a new project, a line import and a grid import, Show on Map for both, wheel zoom, a drag, Home and Previous Extent, a Layer Style for each layer with undo and redo, a click that moves the cursor, Map Drawing CPU and Auto, and closing and opening the project again.
- The map logic (camera, line levels, grid tiles, the CPU renderer, the loader, the scene, the commands and the readout) is tested without a window, in `test/test_map_*.jl`.
- The map window tests (`test/window/test_map_*.jl`) check the GL pass against the CPU renderer pixel by pixel, the move to the CPU, the view and its gestures, the commands, the cursor, the Layers tab and the Layer Style pane.
  The GL parity test also checks that bilinear hillshade has no seams at tile edges, at every grid level.
- Window tests write screenshots to `test/shots/` for review by eye.
  Git ignores that folder.
  There are no golden-image tests, because pixels differ between graphics drivers.

### Headless tests on Linux

`bin/test-headless.sh` runs the UI tests on a virtual display, so no window opens on the desktop.
It uses `xvfb-run`; install it with `sudo apt-get install -y xvfb`.
Extra arguments go to Julia.
It draws with Mesa's software renderer, so the timing tests do not depend on the GPU driver.
Under WSL the GPU path can stall a frame for half a second, and the loop timing tests then fail.
Set `JULIAMAG_TEST_GPU=1` to draw on the GPU instead.
Software and GPU screenshots look the same; they differ only in a few anti-aliased edge pixels.

## The shot tool

`tools/shot.jl` runs a script of UI actions against the real app and saves screenshots.
Each line of the script is one JSON action:

```
{"theme": "dark"}
{"open": "path/to/project"}
{"click": "JuliaMag/tabs/Settings"}
{"shot": "settings-dark"}
```

The actions are `open`, `click`, `key`, `type`, `theme`, `scale`, `size`, `wait` and `shot`.
The top of `tools/shot.jl` explains each one.
Run it from the repository root, on a machine with a display:

```
julia --project=JuliaMagUI/tools -e 'using Pkg; Pkg.instantiate()'
julia -t auto,1 --project=JuliaMagUI JuliaMagUI/tools/shot.jl script.jsonl out_dir
```

The first command is needed once: it installs ImGuiTestEngine, which the app itself does not depend on.

## Benchmarks

- `bench/ui_startup.jl` times the start until the first frame.
- `bench/ui_icons.jl` times the icon atlas.
- `bench/ui_frame.jl` times the frames with a database of 5,000 lines and 300 channels in the Data tree.
- `bench/ui_idle.jl` measures the CPU the app uses while idle (Linux only).
- `bench/map_frame.jl` times the map with 20 M line points and an 8000 by 8000 grid: the load, full frames, a pan and the CPU renderer.
  Run it on a virtual display; `--software` uses Mesa llvmpipe.

`docs/bench.md` has the numbers.
