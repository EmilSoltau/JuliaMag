# JuliaMag Plan 3: UI Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A desktop app, `JuliaMagUI`, that opens a JuliaMag project in a window that looks and feels like the prototype: header, ribbon built from the tool registry, Data and Jobs panes, tool dialogs built from tool descriptions, command search, project backstage, toasts, status bar, light and dark themes.

**Architecture:** A second package in the workspace, `JuliaMagUI`, on top of `JuliaMagCore`, drawn with CImGui.jl (Dear ImGui, docking branch) through its GLFW and OpenGL 3 backend.
The render thread never calls a core function that takes a session lock or touches a file.
It draws from an immutable snapshot of the project, which a worker task rebuilds when the session's change counter moves, and it hands every action to one serial worker queue.
State and layout are plain Julia (tested without a window); drawing functions read colour tokens and never hard-code colours.

**Tech Stack:** Julia 1.12, CImGui.jl 10.1 (Dear ImGui 1.93.1 docking), GLFW.jl 3.4, ModernGL.jl 1, ImGuiTestEngine.jl 3, NativeFileDialog.jl 0.2, Rsvg.jl 1.1 and Cairo.jl 1 (icons), PNGFiles.jl 0.4 (screenshots), JSON3.jl 1, plus `JuliaMagCore` and Aqua and JET.

**Spec:** `docs/superpowers/specs/2026-10-28-juliamag-foundation-design.md` (sections 8, 9.1, 9.2, 9.5, 9.6, 10, 12, 13.3, 13.4).
UI reference: `prototype/juliamag-ui.html` (the approved look: sizes, tokens, icons, texts).
Research done for this plan (copied into the repo in Task 4, Step 1): `docs/research/ui-rustgis.md`, `docs/research/ui-prototype.md`, `docs/research/ui-cimgui.md`, `docs/research/ui-core-api.md`.
Follow-ups: `docs/superpowers/plans/2026-10-28-plan-1-followups.md`, section "Must be done before the UI depends on it".

## The plans

| Plan | Delivers |
|---|---|
| 1. Core | Done. Data model, storage, project, session and undo, tool registry, jobs, history, XYZ and CSV import, line export, first tools |
| 2. Grids | Done. Grid item, Geosoft and Surfer `.grd`, `.ers`, GeoTIFF read and write, grid statistics and properties |
| **3. UI shell (this plan)** | The app window: header, ribbon from the registries, Data and Jobs panes, Tools pane, tool, import and export dialogs, command search, backstage, settings, toasts, status bar, themes; the five core follow-ups the UI needs |
| 4. Views | Map, database, profile and statistics views, Layers tab, CSV import wizard, coordinate system picker, linked cursor |
| 5. Packaging | Prebuilt app for Windows and Linux, loading tool packages while running |

## Global Constraints

- Julia 1.12 or newer. The app runs with `julia -t auto,1`: the render loop is on thread 1, jobs and the worker queue on the default pool.
- `JuliaMagCore` stays free of UI and graphics packages (spec 13.3). Every UI dependency goes into `JuliaMagUI/Project.toml`, added in the task that first uses it.
- `JuliaMagUI` uses `import JuliaMagCore as Core`, never `using JuliaMagCore`, because the core exports names such as `status`, `report`, `line`, `item`, `tool` and `validate`.
- **The UI never freezes (spec 10, 12).** On the render thread, code may read the current `Snapshot`, `Core.status(job)` and `job.progress[]`, and nothing else from the core. Every other core call goes through the worker queue (Task 7).
- **Colours come from tokens only.** No widget code has a colour literal. The token values are the prototype's, copied exactly from `prototype/juliamag-ui.html` lines 9-46 (`:root` for light, `:root[data-theme="dark"]` for dark).
- **Sizes come from the prototype**, in logical pixels, scaled by the window's content scale (DPI):
  - header 34, tab strip 32, ribbon 102 (72 content, 18 group label, 5 top, 3 bottom padding, 1 px bottom border), status bar 26;
  - left pane 272 (resizable 200 to 480), right pane 300 (resizable 240 to 480), splitters 6 wide, pane header band 34, tree rows 26;
  - big ribbon button 70 high, at least 50 wide, 32 px icon, label 11.5 under it on up to two lines; small button 22 high, 18 px icon; three small buttons per column; group label 11 in `--group-label`, centred, 1 px separator after each group;
  - radii: buttons 6, small buttons and inputs 5, menus 8, dialogs 10, tooltips 6, toasts 8, checkbox 3;
  - fonts: body 12.5, ribbon labels 11.5, group labels 11, app name 13 semibold, dialog title 15 semibold, backstage nav 14, backstage h1 26, mono 12;
  - tooltip delay 480 ms; toasts 4.2 s (9 s with actions, 12 s for a failed job), at most 3, bottom right 12 px from the right and 38 px from the bottom.
- The window opens at 1480 by 920 and cannot be made smaller than 900 by 560.
- Brand colour is the prototype's Julia purple (`--brand` `#7D4A9B`, `--brand-dark` `#693D83`, icon accent in the backstage nav `--brand-tint` `#FFD36E`).
- UI text: plain English, short, no em dash character, sentence case for messages, title case for command names as in the prototype ("Channel Math", "Set Coordinate System").
- Errors from the core never end the app: they become a toast or a failed job card with the core's own message (spec 8.2).
- Every change to project data goes through an undoable core call. The UI keeps no project data of its own.
- Tests: `JuliaMagUI` has its own `Pkg.test()` with Aqua and JET (`target_modules = (JuliaMagUI,)`). Logic tests need no window. Window tests (Task 6 harness) need a display and run on Windows always and on Linux when `DISPLAY` or `WAYLAND_DISPLAY` is set; without one they are `@test_skip` with the reason printed once.
- Lint, all core tests and all UI tests pass before each commit. Test output has no warnings. Tests never use the network.
- Commit messages: plain, no co-author lines.

## Review Focus

These inputs are not named by the spec but will reach real users first.
Each has a test in the task that owns the code.

1. **A slow core call while the user keeps working:** a quick tool that runs for 2 s, an undo that copies a large channel, or a close that waits for a job must not stop the frame loop; the window keeps drawing at least 20 frames per second and shows a busy state (Tasks 13, 15).
2. **A project open somewhere else:** opening a locked project shows who holds it and since when, and "Open Anyway" works; a broken or missing project folder gives a plain message and the Start page stays usable (Task 15).
3. **High-DPI screens:** at content scale 1.5 and 2.0 every size and font scales, text stays sharp and nothing is cut off (Tasks 5, 9, 16).
   Task 10's width test also runs with a measure function at scale 1.5 and expects every width times 1.5.
4. **Big and long data:** a database with 5,000 lines and 300 channels, and item names of 200 characters, keep the Data tree smooth (only visible rows are drawn) and never widen the pane (Task 11).
5. **Errors from the core:** a `ProtectedError`, `ItemBusyError`, `ToolError`, `ProjectLockedError` or any other exception from a worker action becomes a toast or dialog with the core's message, and the app keeps running (Tasks 7, 13).

---

## File structure

```
JuliaMag/
  Project.toml                         # [workspace] projects = ["JuliaMagCore", "JuliaMagUI"]
  JuliaMagCore/src/...                 # Part A changes (Tasks 1-3)
  JuliaMagUI/
    Project.toml
    assets/
      fonts/                           # Inter (Regular, SemiBold), Cousine Regular, with licences
      icons/                           # one SVG per prototype icon, made by tools/extract_icons.jl
    tools/
      extract_icons.jl                 # prototype ICONS table -> assets/icons/*.svg
      shot.jl                          # run a JSON-lines script against the app and save PNGs
    src/
      JuliaMagUI.jl                    # module, includes, main()
      theme/tokens.jl                  # Tokens, LIGHT, DARK, apply_style!
      theme/fonts.jl                   # font lookup, loading, sizes
      theme/icons.jl                   # SVG -> atlas texture, draw_icon
      app/config.jl                    # AppConfig: load, save, path, system theme
      app/loop.jl                      # window, render loop, idle and wake, DPI, capture
      app/state.jl                     # AppState, UiState, Snapshot and its builder
      app/worker.jl                    # serial worker queue, results back to the render thread
      app/toasts.jl                    # Toast model and drawing
      app/modal.jl                     # dialog frame, confirm box, Esc stack
      commands/commands.jl             # Command, registry from core tools, importers, exporters, shell
      commands/search.jl               # command search scoring and overlay
      commands/keys.jl                 # shortcuts
      shell/header.jl                  # logo, quick access toolbar, title, search pill
      shell/tabs.jl                    # tab strip, Project button, collapse and peek
      shell/ribbon.jl                  # ribbon layout model and drawing
      shell/statusbar.jl
      shell/central.jl                 # central area (empty state until plan 4)
      panes/panes.jl                   # left and right pane frames, splitters
      panes/data.jl                    # Data tab: tree, context menus, properties, filter
      panes/jobs.jl                    # Jobs tab: cards, report, run again
      panes/tools.jl                   # Tools pane (right)
      dialogs/form.jl                  # Form model built from setting specs
      dialogs/widgets.jl               # one widget per setting type
      dialogs/tool_dialog.jl           # tool, import and export dialogs
      dialogs/item_dialogs.jl          # rename, channel properties, result text
      backstage/backstage.jl           # Start, New, Open, Run Script, About
      ribbon_tabs/settings_tab.jl      # Settings and Help tab contents
    test/
      runtests.jl
      support/app.jl                   # with_test_app, window test gate, shot!
      support/state.jl                 # test_app_state, app_with_database, session_with, wait_drained, refresh_now!
      test_quality.jl
      test_*.jl                        # one per task
      window/test_*.jl                 # window tests
  bench/ui_startup.jl
  docs/research/ui-*.md
```

---

## Part A: core follow-ups the UI needs

### Task 1: Change counter, warnings and closed sessions

**Files:**
- Modify: `JuliaMagCore/src/session/session.jl`, `src/session/undo.jl`, `src/jobs/jobs.jl`, `src/tools/registry.jl`, `src/JuliaMagCore.jl`
- Test: `JuliaMagCore/test/test_ui_support.jl` (new, added to `runtests.jl` after `test_followups.jl`)

**Interfaces:**
- Consumes: `Session`, `record!`, `push_undo!`, `undo!`, `redo!`, `set_cursor!`, `set_marked!`, `session_warning!`, `start_job!`, `close_session!`.
- Produces (follow-ups 1 and 2):
  - `Session` gets `revision::Threads.Atomic{Int}` and `state::Threads.Atomic{Int}` (0 open, 1 closing, 2 closed).
  - `revision(s)::Int`: goes up by at least one after every change a UI shows: `record!`, `push_undo!`, the end of `undo!` and `redo!`, `set_cursor!`, `set_marked!`, `session_warning!`, the start of a job and the moment a job's status leaves `JOB_RUNNING`, and every item or channel edit (they record, so `record!` covers them). Reading it takes no lock.
  - `warnings(s)::Vector{String}`: a copy, under `jobs_lock`. Still works after `close_session!`, so the UI can show close warnings.
  - `isopen(s::Session)::Bool` (extends `Base.isopen`): false from the moment `close_session!` starts.
  - `struct SessionClosedError <: Exception; folder::String; end`, message `"The project <folder> is closed."`.
  - `close_session!` sets `state` to closing before it lists the running jobs, so `start_job!` refuses a job that would start during the close.
  - These throw `SessionClosedError` when `!isopen(s)`: every exported edit (`set_cell!`, `set_line_selected!`, `remove_item!`, `rename_item!`, the channel edits, `set_grid_*!`), `undo!`, `redo!`, and `start_job!` (so `import_file`, `export_file` and `rerun!`).
  - `run_tool` never throws it: for a quick tool and for a job tool on a closed session it returns `(false, <the error's message>, nothing)`, as for its other refusals.
  - Export `revision`, `warnings`, `SessionClosedError`.

- [ ] **Step 1: Write the failing tests**

```julia
s = fresh_session()
r0 = revision(s)
id = make_test_database!(s)
@test revision(s) > r0
r1 = revision(s); set_line_selected!(s, id, first(database(s.project, id).lines).id, false); @test revision(s) > r1
r2 = revision(s); undo!(s); @test revision(s) > r2
r3 = revision(s); JuliaMagCore.session_warning!(s, "w1"); @test revision(s) > r3 && warnings(s)[end] == "w1"
job = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = "MAG2 = MAG * 2", lines = "all")
r4 = revision(s); wait_job(job); @test revision(s) > r4
@test isopen(s)
close_session!(s)
@test !isopen(s)
@test_throws SessionClosedError rename_item!(s, id, "x")
@test_throws SessionClosedError undo!(s)
@test_throws SessionClosedError import_file(s, testdata("small.xyz"))
ok, msg, _ = run_tool(s, "database.statistics"; inputs = Dict("database" => id), channel = "MAG")
@test !ok && occursin("is closed", msg)
ok2, msg2, _ = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = "A = MAG", lines = "all")
@test !ok2 && occursin("is closed", msg2)
@test warnings(s) isa Vector{String}
```

Also: a job tool started from another task while `close_session!` waits for a running job is refused with `SessionClosedError` (start a slow test job, call `close_session!` in a task, then `start_job!` once `!isopen(s)`), and no job is left running after the close returns.

- [ ] **Step 2: Run to see it fail.** `~/.juliaup/bin/julia --project=JuliaMagCore -e 'using Pkg; Pkg.test()'`, expected: `UndefVarError: revision`.
- [ ] **Step 3: Implement.** One helper `check_open(s)` called at the top of each guarded function, before any lock. `bump!(s) = Threads.atomic_add!(s.revision, 1)`.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Add a change counter, a warnings reader and a closed state to sessions"`

---

### Task 2: Settings that depend on other settings, per-field problems, ribbon sizes, script calls

**Files:**
- Modify: `JuliaMagCore/src/tools/settings.jl`, `src/tools/registry.jl`, `src/io/registry.jl`, `src/io/xyz_import.jl`, `src/io/csv_import.jl`, `src/history/script.jl`, `src/JuliaMagCore.jl`
- Test: `JuliaMagCore/test/test_ui_support.jl`

**Interfaces:**
- Produces (follow-up 3, spec 8.1):
  - Every `SettingSpec` type gets a field `when::Union{Nothing,Pair{String,Vector{String}}}` and a keyword `when = nothing` on its constructor: `"mode" => ["append"]` means "used only when the setting `mode` has one of these values". The other setting must exist in the same list and be a `ChoiceSetting` or `BoolSetting` (`"true"`/`"false"`); the `ToolSpec`, `ImporterSpec` and `ExporterSpec` constructors check this.
  - `is_active(spec_settings::Vector{<:SettingSpec}, st::SettingSpec, values::AbstractDict)::Bool`.
  - `setting_problems(spec, values; session = nothing)::Vector{Pair{String,String}}`: key => sentence, in setting order; inactive settings are skipped; input problems (for tools) use the input name as key; an unknown key uses the key. `validate` returns `last.(setting_problems(...))`, so its text stays the same.
  - An inactive setting is stored and recorded as its default: `run_tool`, `import_file` and `export_file` replace it before the args go into the job, the history and the remembered settings. So `target` of the XYZ and CSV importers becomes `""` when `mode == "new"`.
  - XYZ and CSV importers: `target` gets `when = "mode" => ["append"]`.
  - `Place` gets `size::Symbol` (`:big` or `:small`) and `order::Int`; `Place(tab, group; size = :big, order = 0)`. The two-argument form still works. Built-in tools: `coordinates.set_current` and `coordinates.guess_utm` are `:small`; the others `:big`.
  - `script_call(command::AbstractString, args::AbstractDict)::String`: the line `script_text` writes for one history entry without the outputs binding, for example `run_tool(s, "database.statistics"; inputs = Dict("database" => "db-1"), channel = "MAG", lines = "all", bins = 64)`. It shares the code of `script_text`. Exported. The dialog shows it (Task 13).

- [ ] **Step 1: Write the failing tests**

```julia
spec = importer_for("a.xyz")
@test is_active(spec.settings, only(filter(st -> st.key == "target", spec.settings)), Dict("mode" => "new")) == false
@test isempty(setting_problems(spec, Dict("mode" => "new", "target" => "db-99"); session = s))
@test setting_problems(spec, Dict("mode" => "append", "target" => "db-99"); session = s) == ["target" => "There is no item db-99."]
job = wait_job(import_file(s, testdata("small.xyz"); mode = "new", target = "db-99"))
@test job.args["target"] == "" && s.history[end].args["target"] == ""
@test Place("Database", "Import").size == :big
@test_throws ArgumentError ToolSpec("t.bad", "Bad", "", "", Place[], Pair{String,ItemKind}[],
    SettingSpec[NumberSetting("n", "N"; default = 1, when = "nope" => ["x"])], :quick, (a...) -> nothing)
@test script_call("database.statistics", Dict{String,Any}("inputs" => Dict("database" => "db-1"), "channel" => "MAG")) ==
      "run_tool(s, \"database.statistics\"; inputs = Dict(\"database\" => \"db-1\"), channel = \"MAG\")"
```

Use the message text the core already gives for a missing item; adjust the literal in the test to it if it differs.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.** All earlier tests pass unchanged.
- [ ] **Step 5: Commit** `git commit -m "Let settings depend on other settings and report problems per setting"`

---

### Task 3: Position pairs, checked cursor and marks, selecting many lines

**Files:**
- Modify: `JuliaMagCore/src/session/session.jl`, `src/storage/database.jl`, `src/history/script.jl`, `src/JuliaMagCore.jl`
- Test: `JuliaMagCore/test/test_ui_support.jl`

**Interfaces:**
- Produces (follow-ups 4 and 5):
  - `add_pair!(s, id, x, y; crs = "")`: adds `PositionPair(x, y, crs)`; both channels must exist, be numeric and not arrays, and the pair must be new; it becomes current when there was none. Undoable, recorded as `"database.add_pair"`.
  - `remove_pair!(s, id, x, y)`: removes the pair; `current_pair` stays on the same pair, or becomes 0 when the current one was removed. The channels stay. Undoable, recorded as `"database.remove_pair"`.
  - `set_lines_selected!(s, id, lines::Vector{LineId}, flag::Bool)`: one undo step and one history entry for all lines (`"database.set_lines_selected"`); lines already in that state are left out; an empty change pushes nothing.
  - `set_cursor!(s, c)` checks the item is a database, the line exists and `1 <= row <= nrows`; else `ArgumentError` with a plain message.
  - `set_marked!(s, range)` checks there is a cursor and `1 <= first <= last <= nrows` of the cursor line; else `ArgumentError`.
  - `script_text` writes all three new calls; replay tests cover them.
  - Export the three new functions.

- [ ] **Step 1: Write the failing tests**

```julia
id = make_test_database!(s)                       # has X, Y as pair 1
add_pair!(s, id, "MAG", "ALT"; crs = "")
@test length(database(s.project, id).pairs) == 2
remove_pair!(s, id, "X", "Y")
db = database(s.project, id); @test length(db.pairs) == 1 && db.current_pair == 0
undo!(s); @test database(s.project, id).current_pair == 1
ls = [l.id for l in database(s.project, id).lines]
set_lines_selected!(s, id, ls, false)
@test !any(l.selected for l in database(s.project, id).lines)
undo!(s); @test all(l.selected for l in database(s.project, id).lines)
@test_throws ArgumentError set_cursor!(s, Cursor(id, first(ls), 0))
set_cursor!(s, Cursor(id, first(ls), 1))
@test_throws ArgumentError set_marked!(s, (0, 3))
@test_throws ArgumentError set_marked!(s, (1, 10^9))
```

And a replay test: the script of a session that used all three calls runs on the same project.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Add and remove position pairs, select many lines at once, check the cursor"`

---

## Part B: the app

### Task 4: The JuliaMagUI package, tokens and app settings

**Files:**
- Create: `JuliaMagUI/Project.toml`, `JuliaMagUI/src/JuliaMagUI.jl`, `src/theme/tokens.jl`, `src/app/config.jl`, `test/runtests.jl`, `test/test_quality.jl`, `test/test_tokens.jl`, `test/test_config.jl`
- Create: `docs/research/ui-rustgis.md`, `ui-prototype.md`, `ui-cimgui.md`, `ui-core-api.md`
- Modify: `Project.toml` (workspace), `Manifest.toml`

**Interfaces:**
- Produces:
  - Package `JuliaMagUI` (new UUID), deps for this task: `JuliaMagCore`, `JSON3`. Test deps: `Test`, `Aqua`, `JET`.
  - `struct Tokens` with one `NTuple{4,Float32}` (straight RGBA, 0 to 1) field per prototype token, named in snake case without dashes: `header, ribbon, tab_strip, canvas, pane, pane_header, border, border_strong, text, text_dim, text_disabled, icon, hover, pressed, checked, accent, accent_text, on_accent, input, input_border, group_label, status_bar, selection, menu, shadow, green, red, amber, context, context_tint, well, stripe, backdrop, brand, brand_dark, brand_tint`.
  - `const LIGHT::Tokens`, `const DARK::Tokens`, values from the prototype lines 9-46; `rgba(a, b, c, alpha)` values keep their alpha.
  - `hex_rgba(s::AbstractString)::NTuple{4,Float32}` for `#RRGGBB`.
  - `@enum ThemeMode THEME_LIGHT THEME_DARK THEME_SYSTEM`
  - `mutable struct AppConfig`: `theme::ThemeMode = THEME_SYSTEM`, `recent::Vector{String}` (project folders, newest first, at most 10), `open_last::Bool = false`, `hidden_tabs::Vector{String}`, `distance_units::String = "m"` (`"m"`, `"km"`, `"ft"`), `grid_colours::String = "rainbow"`, `temp_folder::String = ""` (blank means the system temp folder), `software_rendering::Bool = false`, `window::NTuple{4,Int} = (0, 0, 1480, 920)` (x, y, w, h; 0, 0 means centred), `left_width::Float32 = 272`, `right_width::Float32 = 300`, `ribbon_collapsed::Bool = false`, `advanced_open::Vector{String}` (tool ids whose Advanced section was left open).
  - `config_dir()::String`: `ENV["JULIAMAG_CONFIG_DIR"]` when set; on Windows `joinpath(ENV["APPDATA"], "JuliaMag")`; else `joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "juliamag")`.
  - `load_config(dir = config_dir())::AppConfig`: a missing file gives the defaults; a broken file gives the defaults and returns its message as a second value: `load_config` returns `(AppConfig, Union{Nothing,String})`.
  - `save_config(c, dir = config_dir())`: writes `settings.json` to a temp file in `dir` and renames it.
  - `add_recent!(c, folder)`: moves or adds `realpath`-normalised `folder` to the front, keeps 10.
  - `system_dark()::Bool`: on Windows reads `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` value `AppsUseLightTheme` with `reg query` (0 means dark); on Linux runs `gsettings get org.gnome.desktop.interface color-scheme` and checks for `prefer-dark`; any failure means false. Runs once at start, with a 2 s timeout.
  - `tokens_for(mode::ThemeMode, system_dark::Bool)::Tokens`.

- [ ] **Step 1: Copy the research.** Copy the four research files from this session's scratchpad (`plan3-research-rustgis.md`, `plan3-research-prototype.md`, `plan3-research-cimgui.md`, `plan3-research-core.md`) to `docs/research/ui-rustgis.md`, `ui-prototype.md`, `ui-cimgui.md` and `ui-core-api.md`. The controller gives the paths in the dispatch.
- [ ] **Step 2: Write the failing tests**

```julia
@test LIGHT.accent == hex_rgba("#2563EB") && DARK.accent == hex_rgba("#5B8DF6")
@test LIGHT.brand == hex_rgba("#7D4A9B") && DARK.brand == LIGHT.brand
@test LIGHT.shadow == (0f0, 0f0, 0f0, 0.11f0) && DARK.backdrop == (0f0, 0f0, 0f0, 0.45f0)
@test DARK.brand_tint == hex_rgba("#FFD36E")
@test fieldcount(Tokens) == 36
withenv("JULIAMAG_CONFIG_DIR" => mktempdir()) do
    c, err = load_config(); @test err === nothing && c.theme == THEME_SYSTEM
    c.theme = THEME_DARK; add_recent!(c, pwd()); save_config(c)
    c2, _ = load_config(); @test c2.theme == THEME_DARK && c2.recent == [realpath(pwd())]
    write(joinpath(config_dir(), "settings.json"), "{broken")
    c3, err3 = load_config(); @test c3.theme == THEME_SYSTEM && err3 isa String
end
```

Also a test that reads every `--name: value;` line of the prototype's two token blocks and checks it equals the matching `Tokens` field, so the table can never drift from the prototype.

- [ ] **Step 3: Run to see it fail.** `~/.juliaup/bin/julia --project=JuliaMagUI -e 'using Pkg; Pkg.test()'`.
- [ ] **Step 4: Implement.** Add `"JuliaMagUI"` to the workspace `projects`. `test_quality.jl` runs `Aqua.test_all(JuliaMagUI)` and `JET.test_package(JuliaMagUI; target_modules = (JuliaMagUI,))`.
- [ ] **Step 5: Run to see it pass**, and the core suite too.
- [ ] **Step 6: Commit** `git commit -m "Start the JuliaMagUI package with theme tokens and app settings"`

---

### Task 5: Window, render loop, fonts and DPI

**Files:**
- Create: `JuliaMagUI/src/app/loop.jl`, `src/theme/fonts.jl`, `JuliaMagUI/assets/fonts/` (Inter-Regular.ttf, Inter-SemiBold.ttf, Cousine-Regular.ttf, `LICENSE-Inter.txt` (OFL 1.1), `LICENSE-Cousine.txt` (Apache 2.0)), `bench/ui_startup.jl`
- Modify: `src/JuliaMagUI.jl`, `src/theme/tokens.jl` (add `apply_style!`), `docs/bench.md`
- Test: `JuliaMagUI/test/test_loop.jl`

**Interfaces:**
- Consumes: Task 4 tokens and config.
- Produces:
  - Deps: `CImGui = "10.1"`, `GLFW = "3.4"`, `ModernGL = "1"`, `PNGFiles = "0.4"`.
  - `mutable struct Window` holding the GLFW window, the ImGui context, `scale::Float32` (content scale), `frame::Int`, `wake::Threads.Atomic{Bool}`, `animating_until::Float64`.
  - `run_window(ui::Function; title = "JuliaMag", size = (1480, 920), min_size = (900, 560), scale = nothing, fonts = :system, on_close = () -> true, engine = nothing)`: own render loop (a copy of the CImGui GLFW and OpenGL 3 extension loop, research `ui-cimgui.md` sections 1, 6, 8), OpenGL 3.3 core. `ui(w::Window)` draws one frame. `on_close()` returning false keeps the window open (Task 15 uses it).
    - Idle: when nothing animates, the loop calls `GLFW.WaitEventsTimeout(0.1)`, so the CPU idles and libuv still runs every 100 ms. It polls while `time() < w.animating_until` or `w.wake[]` is set.
    - `request_frames!(w, seconds = 0.25)`: keep drawing for a while (hover, tooltips, toasts, progress bars call it).
    - `wake!(w)`: thread safe; sets `w.wake` and calls `GLFW.PostEmptyEvent()`. Worker results call it.
    - DPI: `scale` is `GLFW.GetWindowContentScale` unless given; it sets `style.FontScaleDpi` and scales the style sizes once; a change of monitor scale (content-scale callback not used; checked each frame) rescales.
  - `px(w, x) = round(x * w.scale)`: every layout size goes through it.
  - Fonts (`fonts.jl`): `load_fonts!(w, source::Symbol)`. `:system` looks for, in order: Windows `segoeui.ttf` and `seguisb.ttf` in `C:\Windows\Fonts`; Linux `Ubuntu-R.ttf`/`Ubuntu-M.ttf`, `NotoSans-Regular.ttf`/`NotoSans-SemiBold.ttf`, `DejaVuSans.ttf`/`DejaVuSans-Bold.ttf` under `/usr/share/fonts`; else the bundled Inter. Mono: `CascadiaMono.ttf`, `consola.ttf`, `DejaVuSansMono.ttf`, else bundled Cousine. `:bundled` always uses Inter and Cousine (tests and screenshots use it, so they look the same on every machine).
  - `const FONT_REGULAR, FONT_SEMIBOLD, FONT_MONO` handles; `with_font(f, which, size)` pushes the font at `size * scale`.
  - `apply_style!(t::Tokens, scale)`: maps tokens onto `ImGuiStyle` colours (window bg `pane`, frame bg `input`, border `input_border`, button `ribbon`/`hover`/`pressed`, header `hover`/`pressed`/`selection`, text `text`/`text_disabled`, popup bg `menu`, modal dim `backdrop`, check mark and slider grab `accent`, tab `tab_strip`/`ribbon`, separator `border`, scrollbar grab `border_strong`, nav highlight `accent`) and the sizes (frame padding (8, 4), item spacing (6, 5), frame rounding 5, popup rounding 8, window rounding 10, scrollbar 10, grab rounding 5, borders 1).
  - `capture_png(w, path)`: reads the back buffer after `ImGui_ImplOpenGL3_RenderDrawData` and before the swap, flips rows, writes PNG.
  - `main(; project = nothing)`: entry point. In this task it opens an empty window filled with `canvas` that shows the app name; Task 8 fills it.

- [ ] **Step 1: Write the failing tests**

Logic: `px` rounds; `apply_style!(LIGHT, 2f0)` doubles the frame padding and sets `ImGuiCol_WindowBg` to `LIGHT.pane` (check with `ig.c_get` on a context made without a window).
Window test: `run_window` with `fonts = :bundled` draws 30 frames and quits; `capture_png` writes a 1480 by 920 PNG whose centre pixel equals `canvas` within 1/255; with `scale = 2f0` the PNG is still the window's framebuffer size and the text height measured by `CalcTextSize("Hg")` is twice the scale 1 height (within 1 px).
Idle: with no input for 2 s the loop draws at most 25 frames; `wake!` from a `Threads.@spawn` task makes it draw a frame within 150 ms.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** Fonts: download nothing at test time; the TTF files are committed (Inter 4.x from the official release, Cousine from `CImGui.jl/fonts`). `bench/ui_startup.jl` starts a fresh process (`julia -t auto,1 --project=JuliaMagUI`) that times `using JuliaMagUI` and the first drawn frame of `main()`, three times, and prints the median. Add the numbers to `docs/bench.md`.
- [ ] **Step 4: Run to see it pass.** Startup to the first frame after precompile must be under 4 s on the dev machine; record the number.
- [ ] **Step 5: Commit** `git commit -m "Open the app window with an idle render loop, fonts and DPI scaling"`

---

### Task 6: Icons and the window test harness

**Files:**
- Create: `JuliaMagUI/tools/extract_icons.jl`, `JuliaMagUI/assets/icons/*.svg`, `src/theme/icons.jl`, `test/support/app.jl`, `tools/shot.jl`
- Test: `test/test_icons.jl`, `test/window/test_harness.jl`

**Interfaces:**
- Produces:
  - Deps: `Rsvg = "1.1"`, `Cairo = "1"`; test dep `ImGuiTestEngine = "3"`.
  - `tools/extract_icons.jl`: reads the `ICONS` table of `prototype/juliamag-ui.html` (lines 584-707) and writes one `<name>.svg` per icon on a 24 by 24 view box, with the ink colour as `#000001` and the accent colour as `#000002`, so they can be swapped. Run once; the SVGs are committed. Add the logo (the prototype header logo) as `logo.svg`.
  - `IconAtlas`: all icons drawn with Rsvg into one RGBA texture, for one theme and one scale, at the sizes 10, 12, 14, 16, 18, 22, 32 and 48 (logical px times scale). Ink is `t.icon`, accent `t.accent`; a disabled copy uses `t.text_disabled` for both; the backstage nav copy uses white ink and `t.brand_tint` accent. Rebuilt when the theme or scale changes.
  - `draw_icon(dl, name::String, pos, size::Int; style = :normal)` with `style` in `:normal`, `:disabled`, `:nav`, `:on_accent` (white ink and accent). An unknown name draws the icon `tool`.
  - `icon_for(core_icon::String)::String`: maps the core's icon words (`"crs"`, `"statistics"`, `"math"`, `"globe"`, `"pair"`, `"reproject"`, and the importer and exporter ids) to prototype icon names; the table lives here.
  - `test/support/app.jl`:
    - `has_display()::Bool` (Windows true; Linux `DISPLAY` or `WAYLAND_DISPLAY`).
    - `window_testset(f, name)`: runs `f()` inside `@testset name` when there is a display, else `@test_skip` with "no display".
    - `with_test_app(f; project = nothing, theme = THEME_LIGHT, size = (1480, 920), scale = 1f0, config_dir = mktempdir())`: starts the real app (`main` of Task 8 onwards) with bundled fonts and an ImGuiTestEngine context, runs `f(ctx::TestContext)` as one registered test, then closes the app. `TestContext` gives `click(ref)`, `type(ref, text)`, `key(chord)`, `frames(n)`, `shot(path)`, `app_state()` (the live `AppState` for checks) and `wait_until(pred; timeout = 10)` (draws frames until `pred()`, fails on timeout).
  - `tools/shot.jl`: `julia -t auto,1 --project=JuliaMagUI JuliaMagUI/tools/shot.jl script.jsonl out_dir` runs a list of JSON lines (`{"open": folder}`, `{"click": ref}`, `{"key": "Ctrl+K"}`, `{"type": text}`, `{"theme": "dark"}`, `{"scale": 1.5}`, `{"size": [w, h]}`, `{"wait": frames}`, `{"shot": name}`) and writes `name.png` files. This is the tool for pixel reviews.

- [ ] **Step 1: Write the failing tests**

`test_icons.jl`: every SVG in `assets/icons` parses with Rsvg and has a 24 by 24 view box; there are as many SVGs as the prototype has `ICONS` entries plus the logo; `icon_for("math") == "math"` and `icon_for("unknown-word") == "tool"`.
`window/test_harness.jl`: `with_test_app` opens, `shot` writes a PNG, and a 32 px `database` icon drawn in light mode has pixels of `LIGHT.icon` and of `LIGHT.accent` in the PNG.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.** Measure the atlas build time at scale 2 and add it to `docs/bench.md`; it must stay under 300 ms.
- [ ] **Step 5: Commit** `git commit -m "Draw the prototype icons from SVG and add the window test harness"`

---

### Task 7: App state, snapshots and the worker queue

**Files:**
- Create: `JuliaMagUI/src/app/state.jl`, `src/app/worker.jl`, `src/app/toasts.jl`
- Test: `test/test_state.jl`, `test/test_worker.jl`

**Interfaces:**
- Consumes: Tasks 1 to 3 (`revision`, `warnings`, `isopen`, `SessionClosedError`), Task 5 `wake!`.
- Produces:
  - Snapshot types (immutable, built off the render thread, never changed after):
    - `ItemRow(id, kind::Core.ItemKind, name, missing::Bool, made_by, busy::String)` (`busy` is the core's busy reason, or `""`).
    - `LineRow(id::Core.LineId, name, selected::Bool, flight, nrows::Int)`, `ChannelRow(name, label, units, role::Core.ChannelRole, eltype::String, protected::Bool, arraylen::Int, decimals::Int, format::Symbol, width::Int)`.
    - `DatabaseView(id, lines::Vector{LineRow}, channels::Vector{ChannelRow}, pairs::Vector{Core.PositionPair}, current_pair::Int, rows::Int, error::String)`; `error` holds the message when the database cannot be read.
    - `GridView(id, nx, ny, dx, dy, x0, y0, rotation, crs, units, eltype::String, vmin, vmax, count, error::String)`.
    - `JobRow(job::Core.Job, id, command, title::String, target::String, started, finished, status::Core.JobStatus, error, outputs, warnings::Vector{String})` (`status` is the status at snapshot time; the card reads the live `Core.status(job)` and `job.progress[]`).
    - `Snapshot(revision::Int, project_name, folder, items::Vector{ItemRow}, databases::Dict{String,DatabaseView}, grids::Dict{String,GridView}, jobs::Vector{JobRow}, undo_label::Union{Nothing,String}, redo_label::Union{Nothing,String}, warnings::Vector{String}, cursor, marked)`.
  - `snapshot(s::Core.Session)::Snapshot`: takes the locks in the core's order, copies, and opens each database and grid once (a broken one fills `error`, never throws).
  - `mutable struct AppState`: `config::AppConfig`, `tokens::Tokens`, `session::Union{Nothing,Core.Session}`, `snap::Union{Nothing,Snapshot}` (replaced whole, read on the render thread), `refreshing::Bool`, `queue::Worker`, `ui::UiState`, `toasts::Vector{Toast}`, `window::Union{Nothing,Window}`, `seen_warnings::Int`, `busy::Union{Nothing,String}` (text of the worker action now running).
  - `mutable struct UiState`: `tab::String`, `backstage::Bool`, `backstage_page::Symbol`, `ribbon_peek::Bool`, `left_tab::Symbol` (`:data`, `:jobs`), `right_tabs::Vector{Symbol}`, `right_active::Symbol`, `current_db::String`, `selected::Union{Nothing,Tuple{Symbol,String,String}}` (kind, item id, sub key: line name or channel name), `expanded::Set{String}`, `filter::String`, `search::Union{Nothing,String}`, `search_index::Int`, `dialogs::Vector{Any}` (the modal stack, Task 9), `tooltip_since::Float64`, `tooltip_id::UInt32`.
  - `refresh!(app)`: on the render thread each frame: when a session is open, `Core.revision(s) != app.snap.revision` (or `snap === nothing`) and no refresh runs, it starts `Threads.@spawn` that builds `snapshot(s)` and hands it back through the worker results channel. New warnings (`length(snap.warnings) > app.seen_warnings`) each become a `:warn` toast once.
  - `Worker`: one task on the default pool that runs actions in order. `submit!(app, label::String, f::Function; done = (app, result) -> nothing)`: `f(session)` runs on the worker; its return value or exception comes back through a `Channel` that the render thread drains each frame (`drain!(app)`), calling `done` or showing the error. `app.busy` is `label` while the action runs.
  - Error to message: `user_message(e)::String` returns the core's message for `ToolError`, `ProtectedError`, `ItemBusyError`, `ProjectLockedError`, `SessionClosedError`, `ProjectError`, `DatabaseError`, `GridError`, `ArgumentError`; any other exception gives `"Something went wrong: <showerror text>"` and its stack trace goes to the log (`@error` to the log file of Task 15, never to a toast).
  - `Toast(kind::Symbol, text, sub = "", actions = Pair{String,Function}[], ms)`: `kind` is `:ok`, `:info`, `:warn`, `:error`; `toast!(app, kind, text; sub, actions)`; at most 3 shown, oldest dropped; times from the Global Constraints.
  - Test helpers in `test/support/state.jl` (the UI tests also include the core's `JuliaMagCore/test/support/synthetic.jl` for `fresh_session`, `make_test_database!` and `testdata`):
    - `test_app_state(s)::AppState`: an `AppState` with no window and a running worker, on session `s`.
    - `app_with_database()`: `test_app_state` on a fresh session with `make_test_database!`, snapshot taken, `current_db` set.
    - `session_with(; lines, channels, name)`: a session with one database of that many lines and channels, and that item name.
    - `wait_drained(app; timeout = 10)`: drains results until the queue is empty. `refresh_now!(app)`: `refresh!` and wait for the new snapshot.

- [ ] **Step 1: Write the failing tests**

```julia
s = fresh_session(); id = make_test_database!(s)
snap = snapshot(s)
@test snap.revision == Core.revision(s) && only(snap.items).id == id
@test length(snap.databases[id].lines) == length(database(s.project, id).lines)
app = test_app_state(s)                                   # helper in test/support
submit!(app, "rename", s -> Core.rename_item!(s, id, "New"))
wait_drained(app)                                         # drains until the queue is empty
refresh_now!(app)                                         # refresh! plus wait for the snapshot
@test only(app.snap.items).name == "New"
submit!(app, "bad", s -> Core.set_channel_protected!(s, id, "NOPE", true))
wait_drained(app)
@test last(app.toasts).kind == :error && !occursin("Something went wrong", last(app.toasts).text)
submit!(app, "boom", s -> error("x"))
wait_drained(app); @test startswith(last(app.toasts).text, "Something went wrong")
```

Also: a snapshot of a project whose database folder was deleted has `missing = true` on that item and no exception; 3 worker actions finish in submit order; a session warning shows as one `:warn` toast and not again on the next refresh.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Draw from project snapshots and run every core call on a worker queue"`

---

### Task 8: Commands

**Files:**
- Create: `JuliaMagUI/src/commands/commands.jl`, `src/commands/keys.jl`
- Test: `test/test_commands.jl`

**Interfaces:**
- Consumes: core `tools()`, `importers()`, `exporters()`, `Place` (Task 2), `AppState`.
- Produces:
  - `struct Command`: `id::String`, `name::String` (title case, ends with `...` when it opens a dialog), `label::String` (ribbon label, `\n` for two lines), `icon::String` (prototype icon name), `help::String` (one line for tooltips), `places::Vector{Core.Place}`, `shortcut::String` (`"Ctrl+K"` form, or `""`), `enabled::Function` (`app -> nothing` when it can run, else the reason, such as `"Open a project first."` or `"Import line data first."`), `run::Function` (`app -> nothing`), `checked::Function` (`app -> Bool`, for toggles), `searchable::Bool`, `menu::Vector{String}` (for split buttons: ids of the commands in the menu).
  - `commands(app)::Vector{Command}`, built when a project opens and when the core's tool, importer or exporter registries change length:
    - one per core tool: id = tool id, run = open its dialog (Task 13); enabled needs an open project and an item of each input kind;
    - one per importer: id = importer id, name `"Import <name>..."`; places: `Database / Import` for database importers, `Grid and Image / Import` for grid importers; run = file dialog, then the import dialog (Task 13);
    - one per exporter: id = exporter id, name `"Export <name>..."`; places `Database / Export` or `Grid and Image / Export`; enabled needs an item of its kind;
    - split buttons `import.database`, `export.database`, `import.grid`, `export.grid` (`:big` in their groups; the primary action is the first importer or exporter of that kind, the menu lists all);
    - shell commands: `project.backstage` (opens the Start page), `project.new` (Ctrl+N), `project.open` (Ctrl+O), `project.close`, `session.undo` (Ctrl+Z), `session.redo` (Ctrl+Y, also Ctrl+Shift+Z), `ui.command_search` (Ctrl+K), `ui.ribbon` (Ctrl+F1), `ui.theme.light`, `ui.theme.dark`, `ui.theme.system`, `ui.theme.toggle` (Ctrl+Shift+L), `ui.tools_pane`, `ui.jobs_pane`, `ui.shortcuts`, `ui.getting_started`, `ui.about`, `database.select_all_lines`, `database.select_no_lines` (Database / Lines, `:small`), `database.choose` (the "Acts on" chooser, not searchable).
  - `location(cmd)::String`: `"Tab > Group"` of its first place, or `""`.
  - `tab_order(cmds, hidden)::Vector{String}`: the tabs that hold at least one command, in this order: `Database`, `Database Tools`, `Coordinates`, `Grid and Image`, `Map`, then other tabs in first-seen order; `Settings` and `Help` are not in it (they are pinned, Task 9); hidden tabs are left out.
  - `keys.jl`: `parse_chord("Ctrl+Shift+Z")`, `chord_pressed(chord)::Bool` (ImGui key state), `handle_shortcuts!(app)`: runs the command for a pressed chord unless a modal dialog is open (only Ctrl+K and Esc pass then) or a text field is active (only chords with Ctrl pass, and never Ctrl+Z or Ctrl+Y, so text undo works).

- [ ] **Step 1: Write the failing tests**

```julia
app = test_app_state(fresh_session())
cmds = commands(app)
ids = Set(c.id for c in cmds)
@test "database.channel_math" in ids && "import.geosoft_xyz" in ids && "session.undo" in ids
cm = only(filter(c -> c.id == "database.channel_math", cmds))
@test cm.enabled(app) == "Import line data first."
@test tab_order(cmds, String[]) == ["Database", "Database Tools", "Coordinates", "Grid and Image"]
@test tab_order(cmds, ["Coordinates"]) == ["Database", "Database Tools", "Grid and Image"]
@test location(cm) == "Database Tools > Channels"
@test parse_chord("Ctrl+Shift+Z") == (ctrl = true, shift = true, alt = false, key = :Z)
```

After `make_test_database!`, `cm.enabled(app) === nothing`.
A tool registered with a new tab `"Magnetics"` appears in `tab_order` after `Grid and Image`.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Build the command list from the tool, importer and exporter registries"`

---

### Task 9: Header, tab strip, status bar, toasts and dialogs

**Files:**
- Create: `JuliaMagUI/src/shell/header.jl`, `src/shell/tabs.jl`, `src/shell/statusbar.jl`, `src/shell/central.jl`, `src/app/modal.jl`
- Modify: `src/app/toasts.jl` (drawing), `src/JuliaMagUI.jl` (`main` draws the shell)
- Test: `test/window/test_shell.jl`

**Interfaces:**
- Consumes: Tasks 4 to 8.
- Produces (prototype `ui-prototype.md` sections 1, 8; layout sizes in Global Constraints):
  - `draw_app(app)`: the frame: header, tab strip, ribbon (Task 10), main row (left pane, central area, right pane), status bar, then the dialogs, the command search, the toasts, the tooltip. When `app.ui.backstage` is true it draws only the backstage (Task 15).
  - Header (34 high, fill `header`, padding 10): 24 px logo, 6 px gap, "JuliaMag" 13 semibold, 10 px gap, quick access toolbar of 18 px icon buttons (26 by 26): New, Open, Undo, Redo, theme toggle (Undo and Redo greyed when there is nothing to undo; tooltip "Undo <label>"). Title centred in the window: project name semibold 12.5, dropped when it would touch the toolbar or the search pill. Search pill at the right: 248 by 24, radius 12, fill `input` (`hover` on hover), 1 px `border`, 14 px search icon, "Command Search" 12 `text_dim`, "Ctrl+K" 11 `text_disabled` right aligned 12 px from the edge; a click opens command search.
  - Tab strip (32 high, fill `tab_strip`, padding 8): Project button (26 high, text width + 26 wide, fill `brand`, `brand_dark` on hover, radius 6, white semibold 12.5 "Project"), 6 px gap, the tabs of `tab_order`, a spacer, then the pinned `Settings` and `Help` tabs, then a 24 by 24 chevron that collapses the ribbon. A tab: 32 high, text 12.5 (semibold when active; the width is reserved for the semibold text so tabs never move), padding 14 each side, `text_dim` or `text` when active; the active tab has a `ribbon` fill from 3 px below the top, a 1 px `border` outline with radius 6 on the top corners, no outline at the bottom, and a 2 px `accent` bar (radius 1) 1 px above the bottom, inset 8 px; hover is `hover` with radius 5. Double click on a tab or Ctrl+F1 collapses the ribbon; while collapsed a click on a tab shows the ribbon as a floating panel under the strip (with `shadow`) until the next click outside it.
  - Status bar (26 high, fill `status_bar`, 1 px `border` line on top, padding 10, gap 10, text 11.5): left: the current database ("Kangaroo Hills: 60 lines, 24 channels" or "No database"), separator; right: "Selected lines: 12 of 60", separator, jobs ("No jobs running" or a spinner and "2 jobs running" in `accent_text`; a click opens the Jobs tab), separator, the busy text of the worker when set (`app.busy`), separator, render mode "GPU" in `accent_text` or "Software" in `amber` (from `GL_RENDERER`: software when it contains `llvmpipe`, `softpipe` or `Software`). Separators are 1 by 14 in `border_strong`.
  - Central area (fill `canvas`): until plan 4 adds views, it shows a centred empty state: with no project, the Start page's first lines and "New Project" and "Open Project" buttons; with a project that has no items, "Import line data or a grid to start." and the two import split buttons' primary actions as buttons; else "No view is open." and "Views of databases and grids come in a later version." in `text_dim`.
  - Toasts drawing: cards at most 380 wide, radius 8, fill `menu`, 1 px stroke (`red` for errors, else `border_strong`), shadow, 16 px kind icon (`ok` green, `info` accent, `warn` amber, `error` red), text, `sub` in `text_dim`, action buttons, close x; slide up 0.14 s; time out per Global Constraints (hover pauses the timer).
  - `modal.jl`: `push_dialog!(app, d)`, `pop_dialog!(app)`; `draw_dialog(f, app, d; title, icon, width, ok_label, ok_enabled, on_ok, on_cancel, footer_left)`: a centred, movable modal over `backdrop`, radius 10, header 46 (22 px icon, title 15 semibold, close x), body padding 14 by 16, footer with the left buttons, then Cancel and the primary button (bold, `accent` fill, `on_accent` text). Esc closes the top dialog; Enter in a text field presses the primary button. `confirm!(app, title, text; action, danger = false, on_yes)`: 420 wide confirm box with a warning icon when `danger`.
  - Tooltip: after 480 ms on the same item: bold title with the shortcut in brackets, `text_dim` help line, the unavailable reason in `amber` when disabled, and the command id in mono 11 `text_disabled`.

- [ ] **Step 1: Write the failing tests** (window tests, `with_test_app` with a project made by `make_test_database!`)

- the header search pill opens command search (`app_state().ui.search !== nothing`);
- clicking the `Database Tools` tab sets `app_state().ui.tab`; Ctrl+F1 collapses the ribbon (`config.ribbon_collapsed`), and a tab click then shows the peek;
- the status bar shows the database's line and channel counts;
- `confirm!` opens a dialog; Esc closes it; a second Esc does nothing;
- `toast!` three times then a fourth: three shown, the first gone;
- light and dark shots at 1480 by 920 and at scale 1.5 are written to `JuliaMagUI/test/shots/` (git-ignored) for the pixel review;
- at 900 by 560 the title is dropped and the pill does not overlap the toolbar.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review.** Compare the shots side by side with the prototype open in a browser at the same size (`prototype/juliamag-ui.html`, light and dark). Fix every visible difference in size, spacing, colour, weight or alignment. List anything left on purpose in the report.
- [ ] **Step 6: Commit** `git commit -m "Draw the header, tab strip, status bar, toasts and dialogs"`

---

### Task 10: Ribbon

**Files:**
- Create: `JuliaMagUI/src/shell/ribbon.jl`
- Test: `test/test_ribbon.jl`, `test/window/test_ribbon.jl`

**Interfaces:**
- Consumes: Task 8 commands and places, Task 9 frame and tooltips.
- Produces:
  - Layout model (pure): `RibbonGroup(name, items::Vector{RibbonItem})`; `RibbonItem` is `BigButton(cmd_id)`, `SplitButton(cmd_id)`, `SmallColumn(cmd_ids::Vector{String})` (one to three) or `Custom(:db_chooser)`. They compare by value (define `==` and `hash`).
  - `ribbon_layout(cmds, tab)::Vector{RibbonGroup}`: groups in the order their first command was placed (core tools) with this fixed order for the shell's own groups: Database tab: `Database` (the chooser), `Import`, `Export`, `Lines`, `Channels`; Grid and Image tab: `Import`, `Export`, then tool groups. Within a group: commands by `place.order`, then registration order; `:big` places become `BigButton` (a split command becomes `SplitButton`), runs of `:small` places become `SmallColumn`s of up to three.
  - `item_width(item, measure)::Float32` with `measure(text, size)` injected, so widths are testable without fonts: big = max(label width + 14, 50); split = big + 20; small = 26 + label width + 8; group = max(sum of items with 2 px gaps, label width + 12) plus 6 + 1 + 7 for the separator.
  - Drawing (`draw_ribbon(app)`): sizes from the Global Constraints and `ui-rustgis.md` section 3: big button icon centred at top + 21, label from top + 42 with 13.5 px line pitch; split arrow area 20 wide with a 1 px divider inset 6 px and a 7 by 4 caret; small button icon centred 13 px from the left, label from x + 26; hover `hover`, pressed `pressed`, checked `checked` plus a 1 px `accent` outline at 0.55 alpha, radius 6 (5 for small); disabled icon and text `text_disabled`. Group label 11 `group_label`, centred at y = 72 + 9 - 1. When the groups are wider than the ribbon, 18 px arrow buttons appear at the edges and the mouse wheel scrolls sideways.
  - The "Acts on" chooser (Database tab, group `Database`): small label "Acts on", a 170 px combo of the project's databases with the database icon, and a `text_dim` note "N lines, M channels". It sets `app.ui.current_db`, which also follows the Data tree selection.
  - Settings and Help tabs are drawn by Task 15's `settings_tab.jl`, through the same item types.

- [ ] **Step 1: Write the failing tests**

```julia
cmds = commands(app_with_database())
g = ribbon_layout(cmds, "Coordinates")
@test [x.name for x in g] == ["Coordinate system", "Reproject", "Position pairs"]
@test g[1].items == [BigButton("coordinates.set_crs"), SmallColumn(["coordinates.guess_utm"]), BigButton("grid.set_crs")]
d = ribbon_layout(cmds, "Database")
@test first(d).items == [Custom(:db_chooser)] && d[2].name == "Import" && d[2].items[1] isa SplitButton
w = item_width(BigButton("x"), (t, s) -> 7f0 * length(t))
@test w == 50f0                                            # short label: the 50 px floor
```

Window tests: clicking the `Channel Math` big button opens its dialog; a disabled button shows its reason in the tooltip; at 900 px window width the Database tab shows the scroll arrows and the wheel scrolls; the split button's arrow opens a menu with `Geosoft XYZ` and `CSV and text`; shots of every tab in light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's ribbon, as in Task 9.
- [ ] **Step 6: Commit** `git commit -m "Build the ribbon from command places"`

---

### Task 11: Panes and the Data tab

**Files:**
- Create: `JuliaMagUI/src/panes/panes.jl`, `src/panes/data.jl`, `src/dialogs/item_dialogs.jl`
- Test: `test/test_data_tree.jl`, `test/window/test_data.jl`

**Interfaces:**
- Consumes: Task 7 snapshots and worker, Task 3 `set_lines_selected!`, core item and channel edits.
- Produces (prototype `ui-prototype.md` section 4.1):
  - Pane frames: left pane (width from config, 200 to 480) with a 34 px header band of text tabs `Data` and `Jobs` (underlined in `accent`; `Jobs` has a 16 px round `accent` badge with the running count); right pane (Task 14) the same way. Splitters 6 wide; on hover a 2 px `accent` line at 70 % alpha; drag changes the width, saved to the config on release. Long rows are clipped to the pane, never widen it.
  - Tree model (pure): `tree_rows(snap, expanded, filter)::Vector{TreeRow}`, `TreeRow(key::String, depth::Int, kind::Symbol, label::String, right::String, icon::String, bold::Bool, dim::Bool, italic::Bool, checkbox::Union{Nothing,Bool}, tag::String)`. Structure: `Databases (n)` > database > `Lines (k of n selected)` > line rows (checkbox = selected, icon `line` or `tie`, right text `"F<flight>  <rows>"`), `Channels (n)` > channel rows (lock icon when protected, role tag `x`, `y`, `line` and so on, right text units); `Grids (n)` > grid rows (right text `"<nx> x <ny>"`). Missing items are italic and dim with right text "folder not found". A filter matches database, grid, line and channel names (case-insensitive), shows matching rows with their parents and expands them.
  - Drawing: rows 26 high with a 4 px inset hover, radius 5; chevron 14 px, indent 9 + 16 per level; only the rows in view are drawn (`ImGuiListClipper` over `tree_rows`). The current database's row is bold. Keyboard: Up and Down move the selection, Right and Left expand and collapse, Enter does the default action, Shift+F10 or the Menu key opens the context menu.
  - Actions (all through `submit!`): line checkbox -> `set_line_selected!`; `database.select_all_lines` / `select_no_lines` -> `set_lines_selected!` on the current database.
  - Context menus (prototype section 4.1): Databases folder: the database importers. Database: Statistics..., Channel Math..., the database exporters, Rename..., Remove from Project (confirm, "It can be undone."). Channel: Statistics..., Channel Properties..., Protect or Unprotect, Rename..., Delete Channel... (confirm). Position pair (shown under Channels as `X, Y` rows with the CRS): Set as Current (tool `coordinates.set_current`), Remove Pair (`remove_pair!`). Grids folder: the grid importers. Grid: Grid Statistics, Set Coordinate System..., the grid exporters, Rename..., Remove from Project. Tool entries open the tool's dialog with that item as input.
  - Properties panel under the tree (at most 46 % of the pane height, header "Properties: <name>", 96 px key column): fields per kind from prototype section 4.1 (Database: Type, Lines, Rows, Channels, Positions, Folder, Made by; Grid: Type, Size, Cell size, Origin, Rotation, System, Values; Line: Type, Number and version, Flight, Rows, Selected; Channel: Label, Data type, Units, Role, Protected, Format, Decimals). Values from the snapshot only.
  - Filter box at the bottom: "Filter items, lines and channels", Esc clears.
  - `item_dialogs.jl`: Rename dialog (one text field, OK "Rename", empty name greyed); Channel Properties dialog (Label, Units, Decimals (-1 shows "auto"), Format (Normal, Exponential, Date, Time), Width) -> `set_channel_info!`; `ResultDialog(title, text)` (mono text, Copy and Close) for quick tool reports.

- [ ] **Step 1: Write the failing tests**

```julia
snap = snapshot(session_with(lines = 5_000, channels = 300, name = "x"^200))
rows = tree_rows(snap, Set(["databases", "db-1", "db-1/lines"]), "")
@test count(r -> r.kind == :line, rows) == 5_000
@test rows[1].label == "Databases (1)"
f = tree_rows(snap, Set{String}(), "L1001")
@test any(r -> r.label == "L1001", f) && all(r -> r.kind != :channel, f)
```

Window tests: with 5,000 lines expanded, one frame draws at most (visible rows + 2) tree rows (count through a test hook) and takes under 16 ms after warm-up; a 200-character name leaves the pane width unchanged; unticking a line checkbox, then Ctrl+Z, ticks it again (through the worker and the snapshot); Remove from Project asks, removes, and Ctrl+Z brings the item back; Delete Channel on a protected channel shows the core's message as an error toast; Rename to an empty name keeps OK greyed; shots of the tree and properties in light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's Data tab.
- [ ] **Step 6: Commit** `git commit -m "Add the side panes and the Data tab"`

---

### Task 12: Jobs tab

**Files:**
- Create: `JuliaMagUI/src/panes/jobs.jl`
- Test: `test/test_jobs_view.jl`, `test/window/test_jobs.jl`

**Interfaces:**
- Consumes: snapshot `JobRow`, core `cancel!`, `report_text`, `job_warnings`, `rerun!`, Task 13 `open_tool_dialog`.
- Produces (prototype section 4.3):
  - `job_title(row)::String` (tool, importer or exporter name, such as "Import Geosoft XYZ") and `job_target(row)::String` (file name `"->"` item name for imports, item name `"->"` file name for exports, the expression for Channel Math, the input item names for other tools).
  - `job_summary(row, now)::String`: running: percent; done: `"Done in 2.1 s."` plus the outputs (`"Made Kangaroo Hills."`); cancelled: `"Cancelled at 40 %. Nothing was written."`; failed: the error; undone: `"Undone."`.
  - Top bar 32 high: `"N running, M finished"`. Empty state: "No jobs yet. Imports and long tools run here."
  - Cards, newest first, padding 9/12/10, 1 px `border` line under each: 16 px status icon (clock, ok, error, stopped), bold title, right text (percent while running, start time `HH:MM` when finished), dim target line; running: 4 px progress bar (`accent` on `well`) read live from `job.progress[]` (calls `request_frames!`), then link buttons Cancel and Report; finished: Run Again... and Report; failed: red wrapped error text; warnings: amber lines.
  - Report dialog: 640 wide, mono text from `report_text(job)` (read through `submit!`, since it copies a buffer) and the job's warnings and settings (`key = value`); Copy, Close.
  - Run Again...: opens the job's dialog (Task 13) with `job.args` and the extra setting "Replace the old output" (hint "Off: the run makes a new item, and the old one stays."), shown only when the job made outputs; OK calls `rerun!(s, job; args, replace)`.
  - When a job leaves running: a toast (`ok` "<title> done." with the outputs; `error` "<title> failed." with actions Report and Run Again..., 12 s).

- [ ] **Step 1: Write the failing tests** (logic with fake `JobRow`s; window with a real slow test job)

`job_summary` for each status; `job_target` for an XYZ import (`"small.xyz -> small"`).
Window: start a job tool that takes 3 s; the badge shows 1; the card's bar grows between two shots; Cancel ends it as cancelled with "Nothing was written."; Run Again with replace off makes a second item; Report shows the report text; a failing test job shows the failed toast with both actions.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's Jobs tab.
- [ ] **Step 6: Commit** `git commit -m "Add the Jobs tab with progress, cancel, report and run again"`

---

### Task 13: Tool, import and export dialogs

**Files:**
- Create: `JuliaMagUI/src/dialogs/form.jl`, `src/dialogs/widgets.jl`, `src/dialogs/tool_dialog.jl`
- Test: `test/test_form.jl`, `test/window/test_dialogs.jl`

**Interfaces:**
- Consumes: Task 2 (`when`, `is_active`, `setting_problems`, `script_call`), core `last_settings`, `default_settings`, `reset_settings!`, `run_tool`, `import_file`, `export_file`, `rerun!`, Task 7 worker.
- Produces (spec 8.1, 8.2; prototype section 6):
  - Deps: `NativeFileDialog = "0.2"`.
  - `mutable struct Form`: `owner` (a `ToolSpec`, `ImporterSpec` or `ExporterSpec`), `inputs::Dict{String,String}`, `values::Dict{String,Any}`, `texts::Dict{String,String}` (what the user typed in number fields, so "12." is kept while typing), `errors::Dict{String,String}`, `source::Symbol` (`:defaults`, `:remembered`, `:rerun`), `path::String` (import or export file), `replace::Bool`, `rerun_of::Union{Nothing,Core.Job}`.
  - `open_form(app, owner; item = nothing, args = nothing, path = "")`: values from `last_settings` (read through the worker before the dialog opens) or `args`; inputs default to `item`, else `app.ui.current_db` for database inputs and the selected grid for grid inputs; `path` is the import file. Test helper `open_form_now` (in `test/support/state.jl`) calls it and drains.
  - `is_drawn(form, key)::Bool`: the setting exists and its `when` is met.
  - `check!(form, session)::Bool`: fills `errors` from `setting_problems` (also number text that does not parse: "Type a number.").
  - `reset!(form)`: values from `default_settings`, inputs kept, errors cleared, and `reset_settings!` through the worker; toast "Settings reset to their defaults."
  - Widgets (`widgets.jl`), one per setting type, in a two-column grid: label column 150 px, row gap 8, column gap 12; hints under the control in 11 `text_dim`; an error makes the control's border `red` and shows the message in `red` under it:
    - `NumberSetting`: right-aligned input, at most 140 wide, unit text after it; `auto` shows the placeholder `auto` and the hint "Blank means auto, worked out from the data."
    - `TextSetting`: input. `ExprSetting`: mono input plus a row of channel chips of the input database (a click inserts the name).
    - `ChoiceSetting`: segmented control when it has at most 3 choices and all labels are shorter than 14 characters, else a combo; shows `labels`, stores `choices`.
    - `BoolSetting`: checkbox with its label to the right, label column empty.
    - `FileSetting`: mono input plus "Browse..." (native open or save dialog filtered by `extensions`).
    - `ChannelSetting`: combo of the input database's channels (role matches first, arrays left out unless `allow_array`); `allow_new` makes it an input with the combo as suggestions.
    - `ChannelListSetting`: a button showing "All channels" or "n channels" that opens a checklist popup with All and None.
    - `LinesSetting`: segmented "All (N) | Selected (n) | Current" (Current greyed until plan 4 adds a cursor; its value stays possible from scripts).
    - `CRSSetting`: input plus the name of the system under it (`crs_name`, read through the worker when the text changes, debounced 300 ms) or "Not a known coordinate system." in `red`.
    - `PairSetting`: combo of the database's pairs (`"X, Y"`), first item "Current pair".
    - `ExtentSetting` and `PointSetting`: four or two number inputs (West, South, East, North / X, Y).
    - `ItemSetting`: combo of the project's items of its kind; `optional` adds "None".
    - Inputs (tool `inputs`): combos of the items of each kind, first in the form.
    - Settings whose `when` is not met are not drawn.
  - `tool_dialog.jl`: the dialog (Task 9 frame), 580 wide (620 for imports): header with the tool icon, title (`"Run Again: <name>"` for reruns) and the id in mono `text_dim`; body: help paragraph; a status line ("Default settings.", "Opened with the settings of your last run in this project." with a clock icon, or "Settings of job <id>, <HH:MM>. Change any of them before running it again."), with "Runs as a background job" at the right for job tools; the inputs and main settings; for imports, the file name, size and a read-only path line; an "Advanced" section (chevron, `text_dim` bold, 1 px line above) holding the `advanced` settings, closed unless the tool id is in `config.advanced_open` (its state is saved); a hidden "Tool Description" box (mono 11.5) showing the tool's id, inputs, setting types and `script_call(id, args)` for the current values. Footer: "Reset to Defaults" and the link "Tool Description" on the left; Cancel and the primary button on the right: "Run" for tools, "Import", "Export".
  - OK: `check!` (errors open the Advanced section when the first error is in it, and focus that field); then through `submit!`: a quick tool runs `run_tool` and shows its message (one line: an `ok` toast; more lines: a `ResultDialog`); a job tool, import or export starts the job and shows the toast "<title> started." with sub "It runs in the background. Progress is in the Jobs pane." (2.6 s) and opens the Jobs tab once per session. While a quick tool runs, the dialog shows a spinner on the primary button and stays open; it closes when the result comes back.
  - Import flow: `import.*` command -> native open dialog filtered by the importer's extensions (title "Import <name>"), remembering the last folder in the config -> import dialog with `mode`, `name` (placeholder `auto: <file name>`), `target` (only when `mode` is append, Task 2), `crs`, and any other settings. Export flow: export command with an item -> import-like dialog with the exporter's settings and a "File" row with "Browse..." (native save dialog with the exporter's extension; default name is the item name).

- [ ] **Step 1: Write the failing tests**

```julia
app = app_with_database()
f = open_form_now(app, Core.tool("database.channel_math"))     # test helper: open_form plus drain
@test f.inputs["database"] == app.ui.current_db && f.source == :defaults
f.values["expr"] = ""
@test !check!(f, app.session) && haskey(f.errors, "expr")
imp = open_form_now(app, Core.importer_for("a.xyz"); path = testdata("small.xyz"))
imp.values["mode"] = "new"
@test !is_drawn(imp, "target")
imp.values["mode"] = "append"
@test is_drawn(imp, "target")
f2 = open_form_now(app, Core.tool("database.statistics"))
f2.texts["bins"] = "12."
@test check!(f2, app.session)                                  # "12." parses as 12
```

Window tests: Channel Math with `MAG2 = MAG * 2` runs as a job and the new channel appears in the Data tree; a blank expression shows the red error under the field and does not run; Statistics (quick) shows the result dialog; a quick test tool that sleeps 2 s keeps the frame loop above 20 frames per second (count frames during the run) and shows the spinner; Reset to Defaults restores the defaults and shows the toast; the Advanced section opens for an error in `bins`; an XYZ import through the dialog (with `NativeFileDialog` replaced by a test hook that returns `testdata("small.xyz")`) makes a database; an export to a temp folder writes the file; a rerun with replace on leaves one item; shots of each setting widget in light and dark (a test tool that has one setting of every type).

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** The native dialog call goes through `app.pick_file` (a field holding a function), so tests can replace it.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's Channel Math and Import Geosoft XYZ dialogs.
- [ ] **Step 6: Commit** `git commit -m "Build tool, import and export dialogs from setting descriptions"`

---

### Task 14: Command search, shortcuts and the Tools pane

**Files:**
- Create: `JuliaMagUI/src/commands/search.jl`, `src/panes/tools.jl`
- Modify: `src/commands/keys.jl`, `src/panes/panes.jl` (right pane)
- Test: `test/test_search.jl`, `test/window/test_search.jl`

**Interfaces:**
- Consumes: Task 8 commands, Task 9 overlay drawing.
- Produces (prototype section 5, 4.4):
  - `search_commands(cmds, query; limit = 80)::Vector{Command}`: case-insensitive; score: name starts with the query 4, name contains it 3, id contains it 2, location or help contains it 1; ties keep command order; empty query lists all searchable commands; disabled commands stay in the list but sort after enabled ones with the same score.
  - Overlay: 560 wide (at most the window width minus 48), 84 px from the top, centred, radius 10, shadow, over a transparent backdrop; top row 42 high (search icon, input with placeholder "Search commands, for example import, channel math, statistics", close x); list at most 380 high, rows 28: 16 px icon, name 13, mono id `text_dim`, right-aligned location and shortcut (at least 54 wide); footer 28 high: "Up Down to move", "Enter to run", "Esc to close", and "<n> commands". No match: "No command matches \"<query>\"." Up and Down move (and scroll into view), Enter runs the highlighted command when enabled (else shows its reason as a toast) and closes, Esc closes, hover moves the highlight, a click runs.
  - Right pane: tabs with close x and a "close all" button; hidden when no tab is open; width from config (240 to 480).
  - Tools pane (`ui.tools_pane`, also Help > All Tools): search box "Find a tool by name or id"; tools grouped by ribbon tab; rows 42 high: icon, name in `accent_text` bold, mono id, a `job` tag for job tools; a click opens the tool's dialog; footer "Each tool is one Julia function and a description."
  - Shortcut list for Help > Keyboard Shortcuts (from `commands(app)` plus the fixed list in prototype section 9 that already works: Ctrl+K, Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z, Ctrl+N, Ctrl+O, Ctrl+F1, Ctrl+Shift+L, Esc).

- [ ] **Step 1: Write the failing tests**

```julia
cmds = commands(app_with_database())
@test first(search_commands(cmds, "channel m")).id == "database.channel_math"     # name starts with: 4
r = search_commands(cmds, "statistics")
@test findfirst(c -> c.id == "database.statistics", r) < findfirst(c -> c.id == "grid.statistics", r)   # name starts with beats contains
@test first(search_commands(cmds, "guess_utm")).id == "coordinates.guess_utm"   # id match
@test isempty(search_commands(cmds, "zzzz"))
@test length(search_commands(cmds, "")) == count(c -> c.searchable, cmds)
```
Window tests: Ctrl+K opens search, typing "math" then Enter opens the Channel Math dialog; Ctrl+K works while a dialog is open; Esc closes search, a second Esc closes the dialog; Ctrl+Z undoes a rename and Ctrl+Z inside a text field does not; the Tools pane lists every tool and a click opens its dialog; shots of the search overlay and the Tools pane in light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's command search and Tools pane.
- [ ] **Step 6: Commit** `git commit -m "Add command search, keyboard shortcuts and the Tools pane"`

---

### Task 15: Backstage, Settings and Help tabs, opening and closing projects

**Files:**
- Create: `JuliaMagUI/src/backstage/backstage.jl`, `src/ribbon_tabs/settings_tab.jl`
- Modify: `src/JuliaMagUI.jl` (`main`, close flow, log file)
- Test: `test/test_projects.jl`, `test/window/test_backstage.jl`

**Interfaces:**
- Consumes: core `new_session`, `open_session`, `close_session!`, `ProjectLockedError`, `script_text`, `warnings`; Task 4 config; Task 7 worker.
- Produces (prototype section 3.2; spec 9.5, 9.6):
  - Open and close (all through the worker; the render thread shows "Opening <name>..." or "Closing..." as `app.busy` and greys the shell):
    - `open_project!(app, folder; force = false)`: closes the current session first (Task 1 makes a late action fail cleanly); on success sets `app.session`, adds to recent, saves the config, leaves the backstage, sets `current_db` to the first database. On `ProjectLockedError`: a confirm box "This project is open somewhere else" with "<user> on <host> opened it at <started>." and the buttons Cancel and "Open Anyway" (danger), which calls again with `force = true`. On any other error: an error toast with the message, and the folder stays in the recent list marked as not found when it does not exist.
    - `new_project!(app, parent, name)`: `new_session(joinpath(parent, name), name)`; a name that is empty or has characters a folder name cannot have (`<>:"/\|?*`) is refused in the form.
    - `close_project!(app; then)`: when jobs run, a confirm box "<n> jobs are running. Cancel them and close?"; then `close_session!` on the worker; then the session's `warnings(s)` that were not seen yet show in a dialog "Closing the project gave these warnings" before `then` runs.
    - Window close: `on_close` returns false while a project is open; it runs `close_project!(app; then = quit)`.
    - `open_last`: at start, when set and the last recent folder exists, opens it.
    - The log file: `joinpath(config_dir(), "juliamag.log")`, cut to the last 1 MB at start; `@error` and unexpected exceptions go there.
  - Backstage (replaces the whole window content, Esc or Back returns): nav 210 wide, fill `brand`, white text 14 (semibold when selected), rows 40 high, icon 18 at x + 30 (`:nav` style), text at x + 50, selected fill white at 18 % alpha, hover white at 9 %; Back row first, then a 12 px gap; pages: Start, New, Open, separator, Run Script, separator, About; footer "JuliaMag <version>" in white at 60 %. Body fill `ribbon`, padding 48 by 36, scrolls.
    - Start: 44 px logo and "Welcome to JuliaMag" (h1 26), a lead line; "New Project" cards 200 by 160 (Empty Project, Open...), 18 px apart; "Recent Projects" rows 44 high (icon, bold name, dim path; a missing folder greyed with "(folder not found)" and a right-click "Remove from List"); when a project is open, "Current Project" info grid (Name, Folder, Items, Jobs, and the note "Data is written at once. There is nothing to save.").
    - New: Name, Folder (with Browse... for a folder), Create Project.
    - Open: "Browse for a Project..." (a folder dialog; a folder with no `project.jmag.json` gives the message "This folder has no JuliaMag project.") and the recent list.
    - Run Script: the project's `script_text` in a read-only mono box (300 high), buttons "Save Script As..." (native save dialog, `.jl`), "Run Script..." (opens a `.jl` file, asks "Running a script closes this project, runs the script, then opens the project again.", then: close, run the file with `include` in a new `Module` on the worker with its output captured to a box below, reopen), and a line saying the same script runs from the Julia REPL with `include("file.jl")`.
    - About: version, a short description, the shortcut table of Task 14.
  - Settings tab (ribbon, pinned right): groups Theme (big toggles Light, Dark, System, checked for the current mode), Defaults (small combos "Distance units" (Metres, Kilometres, Feet) and "Grid colours" (the core's colour table names), and "Temp Folder..." which picks a folder, checks it is writable and shows the free space in a toast), Startup (toggle "Open Last Project"), Rendering (big toggle "Software Rendering", toast "Takes effect the next time JuliaMag starts."), Ribbon (big menu "Show Tabs" with a check per tab; Settings and Help cannot be hidden). Every change saves the config.
  - Help tab: Help (Command Search, Getting Started, Keyboard Shortcuts), About (All Tools, About). Getting Started: a 560 wide dialog with the processing chain from the prototype (Import, Check, Lag, Heading, Base station, Levelling, IGRF, Gridding, Filters and RTP) and for each whether it is in this version, as plain text rows.

- [ ] **Step 1: Write the failing tests**

Logic: `new_project!` refuses `"a/b"`; `open_project!` of a folder without a project gives the plain message; recent list order after opening three projects; `open_last` opens the last one.
Window: open a project locked by another session (a second `open_session` from the test process holds it): the confirm box names the user; "Open Anyway" opens it; closing the window with a running 3 s job asks, then closes and the process ends; a close warning is shown before the app quits; theme Dark changes `app.tokens` and the shots; hiding the `Coordinates` tab removes it and it survives a restart (new `with_test_app` on the same config dir); Run Script with a script that renames an item runs it and the reopened project shows the new name; shots of every backstage page in light and dark.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Pixel review** against the prototype's backstage and Settings tab.
- [ ] **Step 6: Commit** `git commit -m "Add the project backstage, Settings and Help tabs, and safe open and close"`

---

### Task 16: End to end, startup, and docs

**Files:**
- Create: `JuliaMagUI/test/window/test_end_to_end.jl`, `JuliaMagUI/README.md`, `bin/juliamag.sh`, `bin/juliamag.cmd`
- Modify: `README.md`, `docs/bench.md`, `docs/superpowers/plans/2026-10-28-plan-1-followups.md`, `.gitignore` (`JuliaMagUI/test/shots/`)

**Interfaces:**
- Produces:
  - `bin/juliamag.sh` and `bin/juliamag.cmd`: start `julia -t auto,1 --project=<repo>/JuliaMagUI -e "using JuliaMagUI; JuliaMagUI.main()"` with any folder argument as the project; until plan 5 packages the app, this is how to start it.
  - `main()` warns with a toast when `Threads.nthreads(:default) < 2`: "JuliaMag runs with one worker thread. Start it with -t auto for faster jobs."

- [ ] **Step 1: Write the end-to-end test.** One window session that does what a user does on a first day, at scale 1 and again at scale 1.5:
  1. Start with no project, New Project in a temp folder.
  2. Import `small.xyz` from the core test data through the Database Import split button.
  3. Wait for the job, see the database in the Data tree and the toast.
  4. Run Statistics on `MAG` from the database's context menu; see the result dialog.
  5. Run Channel Math `MAG2 = MAG * 2`; see the channel; undo with Ctrl+Z; the channel is gone; redo.
  6. Import the core's small `.grd` test grid through the Grid and Image tab; set its coordinate system to `EPSG:28355` from the context menu.
  7. Untick two lines; the status bar shows the new selected count.
  8. Switch to dark, open command search, run "Export CSV..." to a temp file; the file exists.
  9. Close the project from the backstage; the Start page lists it under Recent Projects; open it again; everything is there.
  10. Close the window.
  Between steps, write shots for the review.
- [ ] **Step 2: Run it,** fix what breaks, and run every core and UI test.
- [ ] **Step 3: Measure startup** with `bench/ui_startup.jl` and the frame time with the 5,000-line database expanded; record both in `docs/bench.md`.
- [ ] **Step 4: Final pixel review** of all shots in light and dark at scale 1 and 1.5 against the prototype. Fix what looks off.
- [ ] **Step 5: Docs.** `JuliaMagUI/README.md`: how to start, what the shell does, how tools appear in it (a tool's `places`, `size` and `when`), how to run the UI tests and the shot tool. Root `README.md`: a short "Run the app" section. Follow-ups doc: move the five "Must be done before the UI depends on it" items to "Done in plan 3" with the commit names, and add the "Left for later" list of this plan.
- [ ] **Step 6: Commit** `git commit -m "Check the shell end to end and document how to run it"`

---

## Left for later (not in this plan)

- Views (map, database, profile, statistics), the Layers tab, maps, "Add to current map", the shared cursor and the status bar's pointer and cursor parts: plan 4.
- The CSV import wizard, file previews in import dialogs and the coordinate system picker with EPSG search: plan 4.
- Save As (copy a project), Project Settings page, "Find..." for missing items, "Clear Finished" in the Jobs tab.
- Greyed "later" buttons for tools that do not exist yet: the ribbon shows only real commands (spec 9.1: empty tabs are not shown).
- Applying the software rendering setting, and the Windows checks of DPI, fonts and dialogs: plan 5 (packaging), on a real Windows machine.
- Editing an item's free-text description (spec 9.2): the core has no call for it yet.

## Rulings made while writing this plan

These are my calls; each says what it costs if wrong.

- **The prototype is the visual reference, RustGIS second.** The prototype was built from RustGIS's tokens and is the approved look for JuliaMag, so its values win where the two differ (purple brand, 272 px left pane, 300 px right pane). Cost if wrong: token and size changes, which are all in one place.
- **Settings and Help are pinned at the right end of the tab strip**, as spec 13.4 says, although RustGIS draws them as the last tabs. Cost: a small layout change.
- **Own render loop**, copied from the CImGui extension, instead of `CImGui.render`. It is the only way to idle with `WaitEventsTimeout`, wake from worker threads, scale for DPI and take screenshots. `WaitEvents` without a timeout is not used, because it blocks Julia's event loop on thread 1 (research `ui-cimgui.md` section 6). Cost: about 150 lines to keep in step with CImGui.jl.
- **Snapshots and one worker queue** instead of reading the session from the render thread. A quick tool or undo can hold the session lock for seconds, and the spec's first anti-goal after slow imports is a frozen UI. Cost: a snapshot copy after each change (milliseconds for a normal project; the 5,000-line test pins it).
- **Icons are the prototype's SVGs drawn with librsvg into a texture atlas**, not an icon font, so they keep the two-tone look exactly. Cost if wrong: Rsvg and Cairo add load time (measured in Task 6) and binary size; an icon font is the fallback.
- **Inter and Cousine are bundled** for tests and screenshots and as the last fallback; the app prefers the system's Segoe UI on Windows, as the prototype's font list does. Cost: about 1 MB of fonts.
- **NativeFileDialog.jl for file and folder dialogs**, because ImGui has none and a native dialog is what Windows users expect. On Linux it needs GTK 3. Cost if wrong: an ImGui file browser later.
- **ImGuiTestEngine.jl drives the window tests**, as CImGui.jl's own tests do; there are no golden-image asserts, because pixels differ between GPU drivers. The shots are for human review in each task. Cost: window tests need a display, so they are skipped on a Linux machine without one.
- **The five core follow-ups are Part A of this plan**, because the UI cannot be safe without them (closed sessions, change counter, settings that depend on others). Cost: three core tasks before the first window.
- **Run Script closes the project, runs the script, and opens the project again**, because a script opens its own session and the project lock refuses a second one. Cost if wrong: a core "replay on an open session" call later.
- **No "Save" command.** Data is written at once (spec 5.2); views and layer lists, which are what Save stores in the prototype, come with plan 4. Cost: Save comes back in plan 4.
- **App settings live in a JSON file in the user's config folder** (`%APPDATA%\JuliaMag` on Windows), not in the project. Cost: none known.
