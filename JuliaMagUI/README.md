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
- The first start precompiles the packages and takes a few minutes.
  Later starts take about 2.5 s on a fast machine.

The launchers run this command, which also works by hand:

```
julia -t auto,1 --project=JuliaMagUI -e "using JuliaMagUI; JuliaMagUI.main(ARGS)" [project folder]
```

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
- The ribbon has the tabs Database, Database Tools, Coordinates, Grid and Image, Settings and Help.
  Project opens the backstage: Start, New, Open, Close, Run Script and About.
- The left pane has the Data tab (the project tree with its context menus and the properties of the selected row) and the Jobs tab.
- The right pane has the Tools pane.
- The status bar shows the current database, the selected lines, the running jobs and the renderer.
- Tool, import and export dialogs are built from the settings of each tool.
- Toasts tell what happened; a failed job keeps its toast longer.

Every change goes through an undoable core call, so Ctrl+Z and Ctrl+Y work for all of them.
The render loop draws from a snapshot of the project.
On the render thread, the app calls only core functions that are pure or read the global registries (tool, importer and exporter lookups), and reads a job's status and progress.
Every core call that touches a session, a file or a database runs on one worker queue.
So a slow tool, an undo of a big channel or a close that waits for jobs never freezes the window.
Views and maps come in plan 4.

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
- Window tests write screenshots to `test/shots/` for review by eye.
  Git ignores that folder.
  There are no golden-image tests, because pixels differ between graphics drivers.

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

`bench/ui_startup.jl` times the start until the first frame, and `bench/ui_icons.jl` times the icon atlas.
`docs/bench.md` has the numbers.
