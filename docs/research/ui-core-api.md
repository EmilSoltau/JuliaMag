# JuliaMagCore API map for the UI (plan 3 research)

Repo root: `/home/ems/work/_projects/coding-workspace/Mag processing tool/JuliaMag` (branch feature/ui-shell-plan).
Note: the real path has no "(sh)" in it. Paths below are relative to `JuliaMagCore/` unless they start with `docs/`.
Read-only research. Nothing in the repo was changed.

## 1. Exports (src/JuliaMagCore.jl lines 46-87)

The module has one big export block. Includes are at lines 8-44. `__init__` is at line 91 (atexit lock release, quiet GDAL, GDAL cache).

- Line 46-47: `LineType, LINE, TIE, BASE, TEST, TREND, SPECIAL, RANDOM`, `line_letter, line_type, line_name`.
- Line 48-49: `ChannelRole` and `ROLE_NONE, ROLE_X, ROLE_Y, ROLE_Z, ROLE_TIME, ROLE_DATE, ROLE_LON, ROLE_LAT, ROLE_ELEVATION, ROLE_MASK, ROLE_LINE`.
- Line 50: `LineId, LineInfo, ChannelInfo, PositionPair`.
- Line 51: `missing_value, ismissingvalue`.
- Line 52-54: `LineDatabase, DatabaseError, create_database, open_database, save_meta, add_channel!, add_line!, channel, line, total_rows`, `ColumnAppender, open_appenders, append_value!, end_line!, close_appenders!`.
- Line 55-58: `ItemKind, ITEM_DATABASE, ITEM_GRID, ITEM_MAP, ProjectItem, Project, ProjectError`, `create_project, open_project, save_project, add_item!, remove_item!, item, item_missing, new_item_id, database, grid`, `read_channel, write_value!, write_channel!`.
- Line 59-60: grids: `GridError, GridStyle, GridSource, Grid, GRID_BLOCK_BYTES, create_grid, open_grid, save_grid_meta, values_path, block_rows, read_rows, write_rows!, with_grid_values, cell_centre, grid_corners`.
- Line 61-65: session: `UndoStep, HistoryEntry, Cursor, Session, ProtectedError, ItemBusyError, LOCK_FILE, ProjectLockedError`, `open_session, new_session, close_session!, check_not_busy, push_undo!, undo!, redo!, can_undo, can_redo`, `record!, set_cell!, set_line_selected!, set_cursor!, script_text`, `rename_item!, set_marked!, set_channel_protected!, rename_channel!, delete_channel!, set_channel_info!`.
- Line 66-73: IO: `eachfileline, ImportWarning, ImportResult, Progress, report, is_cancelled, NO_PROGRESS`, `GridHeader, GridSink, put_rows!, put_columns!, import_grid`, `georef_from_affine, affine_from_grid, read_gdal_grid`, `GrdHeader, read_grd_header, grd_eltype, grd_dummy, read_geosoft_grd, grd_kind, crs_from_grd_xml, crs_from_grd_gi`, `ImporterSpec, register_importer!, importers, importer_for, import_xyz`, `CsvColumn, CsvLayout, sniff_csv, preview_rows, import_csv`, `save_template, load_template, list_templates, layout_json`.
- Line 74-79: jobs and export: `JobStatus, JOB_RUNNING, JOB_DONE, JOB_FAILED, JOB_CANCELLED, JOB_UNDONE, Job`, `start_job!, cancel!, status, wait_job, jobs, rerun!, import_file, export_file`, `JobFailedError`, `JobReport, report_text, job_warning!, job_warnings`, `ExportResult, ExporterSpec, register_exporter!, exporters, exporter_for`, `export_xyz, export_csv, export_parquet, export_geosoft_grd, export_geotiff, export_ers`.
- Line 80-84: settings and tools: `SettingSpec, NumberSetting, TextSetting, ExprSetting, ChoiceSetting, BoolSetting, FileSetting, ChannelSetting, ChannelListSetting, LinesSetting, CRSSetting, PairSetting, ExtentSetting, PointSetting, ItemSetting`, `Place, ToolSpec, ToolError, register_tool!, unregister_tool!, tools, tool, tabs`, `default_settings, validate, last_settings, reset_settings!, run_tool`.
- Line 85-87: CRS and misc: `valid_crs, crs_name, crs_from_wkt, crs_from_name, crs_wkt, guess_utm, reproject_xy`, `parse_channel_expr, ChannelStats, channel_stats, grid_stats`, `set_grid_crs!, set_grid_georef!, set_grid_style!`.

Things the UI needs that are NOT exported (call as `JuliaMagCore.name`):
- `find_tool` (src/tools/registry.jl:87). `tool(id)` (line 95) is exported and throws `ArgumentError`.
- `session_warning!` (session.jl:479), `mark_busy!`, `mark_reading!`, `item_path` (project.jl:167), `KIND_NAMES` (project.jl:22), `file_extension` (io/registry.jl:110), `validate_settings`, `setting_value`, `setting_problem`, `ProjectItem` helpers.
- `with_session` exists only in `test/support/synthetic.jl:10`. It is NOT part of the package.
- `import_grid` is exported but `export_geosoft_grd`, `export_geotiff` and so on are low level exporters; the UI should go through `export_file`.

## 2. Tool registry (src/tools/registry.jl, src/tools/settings.jl)

### Place and ToolSpec
- `struct Place` (registry.jl:8-11): `tab::String`, `group::String`. Both are required. There is no optional group.
- `struct ToolSpec` (registry.jl:31-54). Constructor: `ToolSpec(id, name, help, icon, places, inputs, settings, mode, run)`.
  - `id::String`, `name::String`, `help::String`, `icon::String`.
  - `places::Vector{Place}` (a tool with none is found only by search and scripts).
  - `inputs::Vector{Pair{String,ItemKind}}`, for example `["database" => ITEM_DATABASE]`.
  - `settings::Vector{SettingSpec}`.
  - `mode::Symbol` is `:quick` or `:job` (checked in the constructor).
  - `run::Function`, called as `run(s, inputs::Dict{String,String}, settings::Dict{String,Any}, progress, report::IO)`.
  - The constructor checks: id not empty, mode valid, setting keys unique and not `"inputs"`, input names unique, and each `ChannelSetting`, `ChannelListSetting` and `PairSetting` names an existing input.
- Icon is a plain string such as `"crs"`, `"statistics"`, `"math"`, `"globe"`, `"pair"`, `"reproject"`. The UI must map these to its own glyphs. There is no icon registry in the core.

### Registry functions
- `register_tool!(spec)` registry.jl:65. Replaces a tool with the same id and keeps its place. Thread safe (`TOOLS_LOCK`).
- `unregister_tool!(id)::Bool` registry.jl:74.
- `tools()::Vector{ToolSpec}` registry.jl:84. Copy, in registration order. This is the "all tools" listing. There is no `all_tools` name.
- `find_tool(id)::Union{Nothing,ToolSpec}` registry.jl:87 (not exported). `tool(id)` registry.jl:95 throws.
- `tabs()::Vector{String}` registry.jl:102. Tabs in first-seen order. There is no `groups(tab)` helper; the UI groups `tools()` by `Place.tab` and `Place.group` itself.
- `default_settings(spec::ToolSpec)::Dict{String,Any}` registry.jl:114. Also methods for `ImporterSpec` (io/registry.jl:77), `ExporterSpec` (io/registry.jl:157) and `Vector{<:SettingSpec}` (settings.jl:~290).
- `validate(spec, settings; session = nothing)::Vector{String}` registry.jl:123. Empty means fine. Missing keys take defaults. Unknown keys are a problem. With a session, `ItemSetting` is checked against the project. Same method exists for importer and exporter specs.
- `last_settings(s, id)::Dict{String,Any}` registry.jl:159. Remembered values for this project, else defaults. A remembered value that no longer validates is replaced by the default. Throws `ArgumentError` for an unknown tool.
- `reset_settings!(s, id)` registry.jl:172. Saves the project file.
- `run_tool(s, id; inputs = Dict(), settings...)` registry.jl:239.
  - Keyword args are setting keys. Given values go over the remembered ones.
  - Problems with inputs or settings return `(false, "<problems joined by space>", nothing)` and remember nothing.
  - Unknown tool returns `(false, "There is no tool \"id\".", nothing)`.
  - `:quick` tool runs on the calling thread and returns `(ok::Bool, message::String, outputs::Union{Nothing,Vector{String}})`. It never throws except `InterruptException`. It remembers the settings only after success and records history.
  - `:job` tool returns a `Job` at once. Settings are remembered when the job starts.
  - UI consequence: a `:quick` tool runs on whatever thread calls it and may hold `s.lock` for a while (statistics, guess UTM read the database). Run it off the render thread, or accept a short stall.
- Settings values are plain data: `Float64`/`Int`, `String`, `Bool`, `Vector{String}`, `Vector{Float64}`, `nothing`. They go to JSON as they are.

### Setting types (src/tools/settings.jl)
Every `SettingSpec` has `key`, `label`, `help`, `advanced` (true means "Advanced" section) and `default`. Field order in the struct is `key, label, help, advanced, ...` then the type specific fields.
- `NumberSetting(key, label; default, min=-Inf, max=Inf, auto=false, integer=false, unit="", help="", advanced=false)` settings.jl:33.
  - Fields: `default::Union{Nothing,Int,Float64}`, `min::Float64`, `max::Float64`, `auto::Bool`, `integer::Bool`, `unit::String`.
  - `auto = true` allows the value `nothing` (blank means "the tool works it out").
  - `default = nothing` without `auto` means the user must type a number.
  - `integer = true` stores an `Int` and requires a whole number.
- `TextSetting(key, label; default="", help, advanced)` settings.jl:65. `default::String`.
- `ExprSetting(key, label; default="", ...)` settings.jl:79. Julia expression text, checked by `expr_text_problem` (limits: 10 000 chars, 100 brackets, 500 operators, parsed on a 64 MB stack worker thread, settings.jl:380-420). Blank is a problem.
- `ChoiceSetting(key, label, choices; default=first(choices), labels=choices, help, advanced)` settings.jl:95. Fields `choices::Vector{String}`, `labels::Vector{String}`, `default::String`. Show `labels`, store `choices`.
- `BoolSetting(key, label; default=false, ...)` settings.jl:116.
- `FileSetting(key, label; extensions=String[], save=false, default="", ...)` settings.jl:132. `extensions` lower case with dots. `save` says whether the dialog is a save dialog. Blank is a problem. The core checks only the extension, not that the file exists.
- `ChannelSetting(key, label; input="database", roles=ChannelRole[], allow_array=false, allow_new=false?, default="", ...)` settings.jl:154. Fields `input::String` (name of the tool input whose database lists the channels), `roles::Vector{ChannelRole}`, `allow_array::Bool`, `allow_new::Bool`, `default::String`. The core only checks "not blank". It does not check the channel exists. `allow_new` is for typing a new channel name (see the constructor at line 164 for the exact keyword list).
- `ChannelListSetting(key, label; input="database", allow_array=true, default=String[], ...)` settings.jl:179. Empty list is allowed (exporters mean "all channels").
- `LinesSetting(key, label; default="all", ...)` settings.jl:197. Value is one of `"all"`, `"selected"`, `"current"` (`LINES_CHOICES`, line 194).
- `CRSSetting(key, label; default="", ...)` settings.jl:210. Text such as `"EPSG:7855"`. Blank means unknown. `setting_problem` for CRSSetting is not in the list of methods I found; the tools check it with `valid_crs` at run time. (Not verified further.)
- `PairSetting(key, label; input="database", default="", ...)` settings.jl:226. Text `"X,Y"`. Blank means the current pair.
- `ExtentSetting` settings.jl:238 and `PointSetting` settings.jl:250. `Union{Nothing,Vector{Float64}}`; extent is `[west, south, east, north]` with west below east, point is `[x, y]`. No built-in tool uses them yet.
- `ItemSetting(key, label, kind::ItemKind; optional=false, default="", ...)` settings.jl:269. Field `kind::ItemKind`, `optional::Bool`, `default::String`. Value is an item id like `"db-1"`. `validate(...; session=s)` checks the item exists and has the kind (`session_problem`, settings.jl:661).
- `ToolError(msg)` settings.jl:17: a message the user should read. `showerror` prints only `msg`.
- Check functions: `setting_problem(st, x)` returns a sentence or `nothing`. `validate_settings(list, values, owner; session)` settings.jl:692.
- No setting type exists for: password, colour, multi-line text (ExprSetting is the only long text), list of lines, or an item list. `lines` selection beyond all/selected/current is not possible.

### Built-in tools registered (8 tools)
| id | name | mode | places (tab, group) | inputs | settings |
|---|---|---|---|---|---|
| `coordinates.set_crs` (coordinates.jl:321) | Set coordinate system | quick | Coordinates / Coordinate system | database | `pair` PairSetting, `crs` CRSSetting |
| `coordinates.reproject` (coordinates.jl:328) | Reproject | job | Coordinates / Reproject | database | `pair`, `crs`, `make_current` Bool |
| `coordinates.set_current` (coordinates.jl:336) | Set current pair | quick | Coordinates / Position pairs; Database / Channels | database | `pair` |
| `coordinates.guess_utm` (coordinates.jl:342) | Guess UTM zone | quick | Coordinates / Coordinate system | database | `pair` |
| `database.statistics` (statistics.jl:438) | Statistics | quick | Database Tools / Channels | database | `channel` (allow_array), `lines`, `bins` (advanced, 64, 1..100000, integer) |
| `grid.statistics` (statistics.jl:464) | Grid statistics | quick | Grid and Image / Properties | grid | `bins` (advanced) |
| `database.channel_math` (channel_math.jl:516) | Channel Math | job | Database Tools / Channels | database | `expr` ExprSetting, `lines` |
| `grid.set_crs` (grid_properties.jl:182) | Set grid coordinate system | quick | Coordinates / Coordinate system; Grid and Image / Properties | grid | `crs` |
- Tab names in use: `"Coordinates"` (const `COORDINATES_TAB`, coordinates.jl:17), `"Database Tools"`, `"Database"`, `"Grid and Image"`. The shell must create ribbon tabs from `tabs()`, not from a fixed list. The prototype tab list is in `prototype/juliamag-ui.html`.
- Tool outputs and reports: a quick tool writes text to `report`, which `run_tool` returns as the message. Statistics returns a text block, not a table or histogram data. A UI that wants to draw the histogram must call `channel_stats` / `grid_stats` (exported) itself.

## 3. Importers and exporters (src/io/registry.jl)

- `ImporterSpec(id, name, extensions, kind, settings, run)` registry.jl:67. `extensions` lower case with dots. `run(session, path, settings::Dict, progress)::ImportResult`.
- `ExporterSpec(id, name, extension, kind, settings, run)` registry.jl:147. One extension per exporter. `run(session, item_id, path, settings, progress)::ExportResult`.
- `ImportResult(item, warnings, rows, lines[, summary])` registry.jl:18. `ImportWarning(file_line, message)` registry.jl:7. `ExportResult(path, rows, lines, notes)` registry.jl:127.
- `Progress(done::Function, cancelled::Function)` registry.jl:35. `report(p, fraction)`, `is_cancelled(p)`, `NO_PROGRESS`.
- Listing:
  - `importers()` registry.jl:97 (copy, in order). `importer_for(path)` registry.jl:100 picks the FIRST importer whose `extensions` contains the lower-cased extension; `nothing` if none or no extension. Only one importer per extension is possible in practice.
  - `exporters()` / `exporters(kind::ItemKind)` registry.jl:182-183. `exporter_for(path_or_id)` registry.jl:192 (id match first, then extension). `exporter_for(path, kind)` registry.jl:208.
  - The file dialog filter must be built by the UI from `importers()` (`name` and `extensions`) and `exporters(kind)` (`name` and `extension`).
- Registered importers (all via `register_importer!`):
  - `import.geosoft_xyz` "Geosoft XYZ" `.xyz` -> database (xyz_import.jl:388). Settings XYZ_SETTINGS (xyz_import.jl:363): `mode` Choice new/append, `name` Text, `target` ItemSetting(ITEM_DATABASE, optional), `crs` CRSSetting.
  - `import.csv` "CSV and text" `.csv .txt .tsv .dat` -> database (csv_import.jl:745). CSV_SETTINGS (csv_import.jl:705): `mode`, `name`, `target`, `template` Text, `layout` Text (advanced, JSON), `crs`.
  - `import.grd` "Geosoft or Surfer grid" `.grd` -> grid, no settings (grd_files.jl:306).
  - `import.geotiff` `.tif .tiff` and `import.ers` `.ers` -> grid, settings `band` NumberSetting(default 1, min 1, integer) (gdal_grid.jl:117,534-537).
- Registered exporters (all via `register_exporter!`):
  - `export.geosoft_xyz` `.xyz` (line_export.jl:654), `export.csv` `.csv` (line_export.jl:656), `export.parquet` `.parquet` (parquet_export.jl:106): all database. Settings `lines` LinesSetting, `channels` ChannelListSetting; CSV adds `delimiter` and `decimal` ChoiceSettings (line_export.jl:620-631).
  - `export.geosoft_grd` `.grd`, `export.geotiff` `.tif`, `export.ers` `.ers`: grid, no settings.
- `import_file(s, path; settings...)::Job` jobs.jl:557. Picks importer by extension. Unknown type gives a FAILED job (command `"import"`), not an exception. Settings are checked inside the job (`spec_values` throws `ToolError`, so the job fails with the message). It does NOT run `validate(...; session)`, so a bad `target` fails inside the job. The UI should call `validate(spec, settings; session = s)` first.
- `export_file(s, item_id, path; exporter = "", settings...)::Job` jobs.jl:644. Blank `exporter` picks by the item kind and extension. Unknown exporter gives a failed job. No undo step. Writes to temp files and renames at the end.
- Because the importer is chosen by extension only, a `.txt` or `.dat` file is always CSV and a `.xyz` is always Geosoft XYZ. The UI cannot pick another importer through `import_file`; to force one it must call `start_job!` itself or call `spec.run` (not recommended).
- CSV preview helpers (src/io/csv_import.jl):
  - `sniff_csv(path; rows = 20, delimiter = nothing, fixed_widths = Int[])::CsvLayout` line 333. Throws `ToolError` if the file is missing or has no rows.
  - `preview_rows(path, layout::CsvLayout; rows = 20)::Vector{Vector{String}}` line 426. Row k is file line k (heading and units rows are included).
  - `CsvLayout(; delimiter=',', fixed_widths=Int[], heading_row=0, units_row=0, first_data_row=1, columns=CsvColumn[], line_column="", x="", y="", crs="", decimal='.')` line 85 (immutable, copy with `CsvLayout(l; changes...)`). `CsvColumn(name; role=:data, eltype=Float64, units="")` line 50. Roles: `:skip :data :line :fiducial :array` (`CSV_ROLES`, not exported).
  - `layout_json(layout)::String` and `layout_from_json(text, what)` (csv_templates.jl:25, the latter not exported). The `layout` setting of `import.csv` takes the JSON text.
  - `save_template(s, name, layout)` csv_templates.jl:83, `load_template(s, name)` :105, `list_templates(s)::Vector{String}` :144. Templates live in the project `templates/` folder.
  - `import_csv(s, path, layout; name, mode, target, progress, record)` line 679, `import_xyz(s, path; ...)` xyz_import.jl:343 are direct (synchronous, not undoable unless `record`); the UI should use `import_file`.
- `eachfileline` (io/textscan.jl) is exported but is a low level helper.
- No preview exists for XYZ files, grids (header only: `read_grd_header` is exported for `.grd`) or GeoTIFF/ERS.

## 4. Session (src/session/session.jl, undo.jl, lock.jl)

### Opening and closing
- `open_session(folder; force = false)::Session` session.jl:195. Throws `ProjectError` if there is no project file. Takes the lock first, then reads. Throws `ProjectLockedError` if another session holds it.
- `new_session(folder, name; force = false)::Session` session.jl:208. Creates the folder and project.
- `close_session!(s)` session.jl:329. Cancels and waits for running jobs, runs `commit` of each undo step and `drop` of each redo step, removes the lock. A second call does nothing. Errors become `s.warnings`. This call can block for as long as the running jobs take to stop. Run it off the render thread and show a "closing" state.
- There is no `with_session` in the package. Tests define it in `test/support/synthetic.jl:10`.
- Julia must be started with threads (`julia -t auto`): jobs use `Threads.@spawn` (jobs.jl:~80). With one thread jobs still work but share the thread with the UI loop.

### Project lock behaviour (src/session/lock.jl)
- Lock file `project.lock` (const `LOCK_FILE`, lock.jl:22) in the project folder. It holds pid, host, user, started (JSON). Made with an exclusive hard link.
- `ProjectLockedError(folder, host, user, started, note)` lock.jl:29. Fields: `folder::String, host::String, user::String, started::String, note::String`. Its message tells the user to close the other session or use `force = true`.
- A lock whose process has ended on the same host (stale, `lock_alive` false) is taken over silently with a session warning. A broken lock file is replaced with a warning.
- A live lock from another process or host: `ProjectLockedError`. With `force = true`: the lock is replaced, with a warning in `s.warnings`, and `.importing-*` / `.undo-*` leftovers are NOT swept (`sweep_leftovers!`, session.jl:~232). Also the `commit` actions at close run only while the lock is still ours.
- UI flow: try `open_session(folder)`, catch `ProjectLockedError`, show `e.user`, `e.host`, `e.started`, offer "Open anyway" which calls `open_session(folder; force = true)`.
- Known lock gaps (from followups "Can wait"): pid reuse after reboot, two forced sessions in one process have equal records, Windows hard link codes untested.

### Session struct (session.jl:140-176, `mutable struct Session`)
Fields: `project::Project`, `undo_stack::Vector{UndoStep}`, `redo_stack::Vector{UndoStep}`, `history::Vector{HistoryEntry}`, `cursor::Union{Nothing,Cursor}`, `marked::Union{Nothing,Tuple{Int,Int}}`, `remembered::Dict{String,Dict{String,Any}}`, `lock::ReentrantLock`, `warnings::Vector{String}`, `jobs::Vector{Job}`, `next_job::Int`, `jobs_lock::ReentrantLock`, `busy::Dict{String,BusyMark}`, `held_lock`, `undo_lock::ReentrantLock`, `held_edits`.
- `Cursor` (session.jl:~90): `item::String`, `line::LineId`, `row::Int`. `marked` is `(first, last)` rows on the current line, or `nothing`.
- `HistoryEntry` (session.jl:~76): `time, command, args::Dict{String,Any}, job::String, outputs::Vector{String}, replaces::String, replaced::Vector{String}`.
- `UndoStep` (session.jl:~36): `label, undo, redo, drop, items::Vector{String}, recorded::Bool, commit`.
- Lock order (documented at session.jl:~126): `undo_lock`, then `lock`, then `jobs_lock`. Never call `undo!`/`redo!` while holding `s.lock` or `jobs_lock`.
- Which lock guards what: `s.lock` guards project, stacks, history, cursor, marked, remembered, busy. `s.jobs_lock` guards `jobs`, `next_job`, `warnings` (via `session_warning!`, session.jl:479) and `held_lock`.

### Reading state (all direct field access, UI must lock)
- Items: `lock(() -> copy(s.project.items), s.lock)`. `ProjectItem` fields in section 6.
- Warnings: `lock(() -> copy(s.warnings), s.jobs_lock)`. There is NO accessor function for warnings.
- History: `lock(() -> copy(s.history), s.lock)`.
- Undo label: there is NO accessor. Use `lock(() -> isempty(s.undo_stack) ? nothing : last(s.undo_stack).label, s.lock)`; same for `redo_stack`.
- `can_undo(s)`, `can_redo(s)` (undo.jl:40-41) take the lock and return Bool.
- Cursor and marked: `lock(() -> (s.cursor, s.marked), s.lock)`. `Cursor` is mutable and shared; copy it.

### Undo and redo (src/session/undo.jl)
- `undo!(s)::Bool` undo.jl:56, `redo!(s)::Bool` undo.jl:59. False when empty. Steps run without `s.lock`, so a long undo (copying files) does not freeze readers, but `undo_lock` is held, so a second undo waits. Throws the step's error (step stays on its stack) or `ItemBusyError` before running. The undo is itself recorded as `session.undo` in the history.
- `push_undo!(s, step)` undo.jl:19 and `check_not_busy(s, id)` are exported for tool authors.
- Undo and redo stacks are memory only. They end at close.

### Edit functions (all take `s.lock`, refuse a busy item with `ItemBusyError`, are undoable and recorded unless noted)
- `set_cell!(s, item_id, line::LineId, channel, row, x)` session.jl:589. Throws `ProtectedError` for a protected channel.
- `set_line_selected!(s, item_id, line::LineId, flag)` session.jl:612.
- `set_cursor!(s, c::Cursor)` session.jl:631. Not undoable, not recorded, no validation.
- `set_marked!(s, range::Union{Nothing,Tuple{Int,Int}})` session.jl:645. Not undoable, not recorded. Throws `ArgumentError` if first > last. Does NOT check rows >= 1 (followup item 5).
- `remove_item!(s, id)` session.jl:686. Files stay until close (commit). Clears the cursor if it is on the item. Same name as the Project-level `remove_item!(p, id)` (project.jl:155), which is NOT undoable and must not be used by the UI.
- `rename_item!(s, id, name)` session.jl:734. Strips spaces. `ArgumentError` for blank.
- `set_channel_protected!(s, id, channel, flag)` session.jl:804.
- `set_channel_info!(s, id, channel; label, units, decimals, format, width)` session.jl:827. Fields in `CHANNEL_INFO_FIELDS` (session.jl:~815). `format` is one of `:normal, :exponential, :date, :time`. It is a no-op that still pushes an undo step if nothing changes.
- `rename_channel!(s, id, old, new)` session.jl:870. Renames position pairs too (`pairs_text`).
- `delete_channel!(s, id, channel)` session.jl:913. Takes the channel file out into a `.undo-*` side folder.
- Grid edits: `set_grid_crs!(s, id, code)`, `set_grid_georef!(s, id; ...)`, `set_grid_style!(s, id, style)` (exported, builtin/grid_properties.jl).
- No call exists to: add or remove a position pair, change the current pair (use the tool `coordinates.set_current`), edit a line (rename, delete, change type), or reorder items.

### Knowing the session changed
- There is NO version counter, event, channel, Condition, observable or callback anywhere in `src/` (grep for generation/revision/notify/Condition found nothing relevant).
- The UI must poll or must refresh after its own actions. Practical options:
  - Cheap change test per frame: `(length(s.history), length(s.undo_stack), length(s.redo_stack), length(s.jobs), s.next_job)` read under the locks, plus job `status` atomics.
  - Item list changes only through item functions, undo/redo and jobs. History length changes with every recorded edit (but not `set_cursor!`/`set_marked!`).
  - Edits made by a job (appended rows, Channel Math overwrite) show up in `jobs(s)` status change to `JOB_DONE`.
- Recommendation for plan 3: add a monotonic `Threads.Atomic{Int}` change counter to `Session`, bumped in `record!`, `push_undo!`, `run_step!`, `set_cursor!`, `set_marked!`, job finish and `session_warning!`.

### Thread safety summary for the UI thread
- Never hold `s.lock` across a frame.
- `database(p, id)` (project.jl:210) opens a FRESH `LineDatabase` from `database.json` on every call. The returned object is a snapshot. Channel files are memory mapped, so reading values while a job appends is allowed only for committed rows (`rows_written`).
- A busy item (`s.busy`) makes edits throw `ItemBusyError`. The UI should read `s.busy` under `s.lock` to grey out menus (BusyMark fields `writing, reading, why, kind, owner`; `busy_reason(m)`, `readers_allowed(m)` are internal).
- Cursor and marked are plain fields guarded by `s.lock`.

## 5. Jobs (src/jobs/job.jl, src/jobs/jobs.jl)

- `@enum JobStatus JOB_RUNNING JOB_DONE JOB_FAILED JOB_CANCELLED JOB_UNDONE` job.jl:8. `JOB_UNDONE` means finished but its outputs were taken out by undo; redo makes it `JOB_DONE`.
- `mutable struct Job` job.jl:50, fields:
  - `id::String` (`"job-N"`), `command::String` (importer/exporter/tool id), `args::Dict{String,Any}`.
  - `status::Threads.Atomic{Int}`, `progress::Threads.Atomic{Float64}` (0 to 1), `cancel::Threads.Atomic{Bool}`.
  - `started::String`, `finished::String` (text times, `"%Y-%m-%dT%H:%M:%S%z"`), `report::JobReport`, `warnings::Vector{String}` (guarded by `report.lock`), `outputs::Vector{String}` (item ids), `error::String`, `task::Union{Nothing,Task}` (`nothing` when loaded from disk).
- Reading (all safe from any thread while the job runs):
  - `status(job)::JobStatus` job.jl:84. Reads the atomic.
  - progress: `job.progress[]` (no accessor function).
  - `report_text(job)::String` jobs.jl:439. Locks, copies, cuts at 1 MB with a note.
  - `job_warnings(job)::Vector{String}` job.jl:72. Copy.
  - `job.error` and `job.outputs` are plain fields written once at the end. Read them only after `status(job) != JOB_RUNNING`.
- `jobs(s)::Vector{Job}` jobs.jl:149. Newest first, a sorted copy under `jobs_lock`. The `Job` objects are shared (live).
- `cancel!(job)` jobs.jl:86 sets the flag. The work stops at its next `is_cancelled` check. An error after cancel gives `JOB_CANCELLED`. Cancelled and failed jobs leave no item.
- `wait_job(job; check = false)` jobs.jl:120 blocks. Never call it on the render thread for a running job.
- `rerun!(s, job; args = job.args, replace = false)::Job` jobs.jl:594. Works for importers, exporters and `:job` tools. With `replace = true` the old outputs leave the project once the new job is done (undo puts them back), and the history entry names `replaces`/`replaced`. A command that cannot rerun gives a failed job, nothing is thrown. Rerun with changed `args` is how an "edit and rerun" dialog would work.
- `start_job!(s, command, args, work; undoable = true)` jobs.jl:69. `work(progress, report_io)` returns `Vector{ProjectItem}`. `job_warning!(text)` (job.jl:200) adds a warning from inside the work.
- Jobs are saved in `<project>/jobs/<id>.json` and reloaded by `load_jobs!` at open; jobs that were running at a crash come back as failed. `jobs/counter.json` keeps the id counter.
- Safe polling from a UI thread, per frame: `for j in jobs(s)` then `status(j)`, `j.progress[]`, and only for the selected job `report_text(j)` and `job_warnings(j)`. Detect a new job by `length(jobs(s))`. Avoid calling `report_text` for every job every frame (it copies the buffer). Use the status change to RUNNING -> other to refresh items.
- Failed job message: `j.error` (for quick tools `run_tool` returns the message directly).
- `JobFailedError(job, command, message)` jobs.jl:92 is only thrown by `wait_job(...; check = true)`.

## 6. Project items

- `@enum ItemKind ITEM_DATABASE ITEM_GRID ITEM_MAP` project.jl:20. `ITEM_MAP` exists but nothing creates it. `KIND_NAMES` (not exported): "database", "grid", "map". Id prefixes (`KIND_PREFIXES`): `db-`, `grid-`, `map-`.
- `mutable struct ProjectItem` project.jl:26: `id::String`, `kind::ItemKind`, `name::String`, `path::String` (relative, forward slashes), `description::String`, `made_by::String` (job id or "").
- `mutable struct Project` project.jl:35: `folder, name, items::Vector{ProjectItem}, settings::Dict{String,Any}, next_ids`.
- `item(p, id)` project.jl:161 throws `ProjectError`. `item_missing(p, it)::Bool` project.jl:170 says the folder is gone (the UI should mark such items). `new_item_id(p, kind)` project.jl:187.
- Database: `database(p, id)::LineDatabase` project.jl:210 (fresh snapshot, throws `ProjectError`/`DatabaseError` if missing or broken). `LineDatabase` (database.jl:35) fields:
  - `folder, name, description`, `lines::Vector{LineInfo}`, `channels::Vector{ChannelInfo}`, `pairs::Vector{PositionPair}`, `current_pair::Int` (index into `pairs`, 0 for none), `made_by`, `rows_written::Int`, plus internal caches.
  - `LineInfo` (types.jl:35): `id::LineId, flight, date, fid_start, fid_step, nrows, offset, selected::Bool`. `LineId(type::LineType, number, version)`; `line_name(id)` gives `"L1001"` or `"L1001.2"`.
  - `ChannelInfo` (types.jl:53): `name, label, eltype::DataType, units, role::ChannelRole, format::Symbol, width, decimals (-1 = unset), protected::Bool, arraylen`.
  - `PositionPair` (types.jl:67): `x::String, y::String, crs::String` (names of two channels).
  - Helpers: `line(db, id)::LineInfo`, `channel(db, name)::ChannelInfo`, `total_rows(db)`, `read_channel(db, id, name)::AbstractArray` (database.jl:526, a view of the memory map; copy it if the UI keeps it), `write_value!`, `write_channel!`.
  - "Protected channels": `ChannelInfo.protected`. `set_cell!` throws `ProtectedError(channel)` when true. Rename/delete via `rename_channel!`/`delete_channel!` do not check it (not verified; check before relying on it). Toggle with `set_channel_protected!`.
  - "Current pair": `db.current_pair` (1-based index into `db.pairs`) and `db.pairs[db.current_pair]`. Set by importers (first pair if none) and by the tool `coordinates.set_current`. There is no accessor function like `current_pair(db)`. A pair is shown as `"X,Y"` (`pair_text`, coordinates.jl:~46, not exported).
- Grid: `grid(p, id)::Grid` project.jl:218 (snapshot). `Grid` (storage/grid.jl:57): `folder, name, eltype, nx, ny, dx, dy, x0, y0, rotation, crs, units, source::GridSource, trend, style::GridStyle, vmin, vmax, count`. `GridStyle` (grid.jl:24): `colours::String, method::Symbol (:linear :histeq :normal :loglinear), min, max, reverse, shade, azimuth, altitude, zfactor`. Reading values: `read_rows(g, ...)`, `with_grid_values`, `block_rows`, `cell_centre`, `grid_corners`.
- Listing databases, lines, channels, grids: filter `s.project.items` by `kind`, then open with `database`/`grid`. There is no list helper.
- Dummy-value handling: `missing_value(T)` / `ismissingvalue(x)` (missing.jl): NaN for floats, `typemin` for signed ints, `typemax` for unsigned ints, `""` for strings.

## 7. App-level settings

- There is none. The core has no app settings store: no temp folder, units, theme, recent projects or window state.
- The only persisted settings are per project: `project.settings` (a `Dict{String,Any}` saved in `project.jmag.json`), of which only the key `"tools"` is used (remembered tool settings, registry.jl:134). Project name is `project.name`.
- The core uses temp folders inside the project (`databases/.importing-<id>`, `.undo-*`, `.kept-*`), never a global temp folder, and `mktempdir(db.folder; ...)`.
- Colour, theme, units display, recent project list, last import folder and the tab layout all have to live in a UI-side config file (plan 3 decision).
- Templates: per project, `templates/` folder.

## 8. Script

- `script_text(s::Session)::String` src/history/script.jl:243 (exported). Holds `s.lock`. Returns Julia source:
  `using JuliaMagCore`, `s = open_session("<folder>")`, `try ... finally close_session!(s) end`, one call per history entry with a time comment. Items made by jobs are bound to variables (`db_1 = only(wait_job(import_file(...); check = true).outputs)`). Throws `ArgumentError` naming the entry when an entry cannot be written (for example an unknown line type).
- There is NO function that runs a script. No `run_script`, no `include_string` use in `src/`. A UI would have to `include_string(Main, text)` or `Meta.parse` it itself.
  - The script opens the same project with `open_session(folder)`, which would be refused by the lock the UI session holds (the doc says it is meant to run on a copy or after the UI session closed; see the "explain scripts on an open project" commit 31177c2).
  - A UI "Run script" would need to close its session first, or use a copy of the project, or a new core function that replays the history on an open session.
- The script text is built only from `repr` of values, so it cannot carry code from a crafted history file.
- Tests for this are in `test/test_session.jl`, `test/test_followups.jl`, `test/test_end_to_end.jl`.

## 9. Followups "Must be done before the UI depends on it" (docs/superpowers/plans/2026-10-28-plan-1-followups.md lines 8-17)

Note: the heading says "plan 2 to 4". Plan 2 did not do these five. They are still open. (Plan 2 finished a different list, "Done in plan 2", lines 19-74.)

1. `Session.warnings` is stored but not shown.
   - Exists: `warnings::Vector{String}` (session.jl:~152). `session_warning!(s, msg)` (session.jl:479) pushes under `jobs_lock`. Warnings come from open (lock take-over, forced open, leftover sweep, history lines skipped, bad remembered settings, hard-link fallback) and from close (failed `commit`/`drop`, kept folders) and from tools/jobs (Channel Math cannot restore, history entry cannot be saved).
   - Missing: any accessor, any clear/acknowledge call, any "seen" marker, and any way to tell new from old warnings. Close warnings go into the closing session's own `s.warnings`, which the UI must still hold after `close_session!` returns. There is no event when one is added.
   - UI needs: read `lock(() -> copy(s.warnings), s.jobs_lock)`, keep a "seen count", and keep the closed Session object for a final read.
2. A closed session stays usable.
   - Exists: `close_session!` (session.jl:329) cancels and waits for running jobs, ends the stacks, sets `held_lock = nothing` and removes the lock file.
   - Missing: a closed flag. After close, `set_cell!`, all edit calls, `run_tool`, `import_file`, `start_job!` (jobs.jl:69), `open_*` calls work without the project lock. `start_job!` does not check anything about close, so a job started during the close (after the `running` list was built at session.jl:330) is not cancelled and not waited for. `held_lock === nothing` is the only sign of closing/closed but nothing tests it.
   - UI needs: a core `isopen(s)` / closed refusal. Until then the UI must drop the Session reference after `close_session!` and block its own actions while closing.
3. An `ItemSetting` in mode new can keep a stale target item.
   - Exists: XYZ_SETTINGS (xyz_import.jl:363-372) and CSV_SETTINGS (csv_import.jl:705-720) both have `ChoiceSetting("mode", ..., ["new","append"])` and `ItemSetting("target", ..., ITEM_DATABASE; optional = true)`. `import_lines` (line_import.jl:376) ignores `target` when `mode == :new`. `check_import_args` (line_import.jl:359) only requires a target for `:append`.
   - Missing: nothing clears or hides `target` when mode is `new`. The value is still sent, stored in the job `args` and the history (`xyz_import.jl:348`, `csv_import.jl:684`), and `validate(spec, settings; session = s)` would still report "there is no item db-N" for a removed target even though the import would not use it. A rerun or script keeps the stale id. The UI cannot express "this setting is only used when mode == append" because `SettingSpec` has no `visible_if`/dependency field.
   - Fix options: clear `target` in `import_lines` args when mode is new, and/or add a dependency field to `SettingSpec` so the dialog hides it.
4. There is no call to remove a position pair.
   - Exists: `db.pairs::Vector{PositionPair}`, `db.current_pair`. Pairs are added by importers (line_import.jl:255, csv_import.jl:501), `coordinates.reproject` (coordinates.jl:289), and renamed with `rename_channel!`. `coordinates.set_current` (coordinates.jl:111) changes the current pair. `coordinates.set_crs` changes a pair's crs.
   - Missing: remove (and add) a pair as a session call or a tool, with undo and history. `delete_channel!` (session.jl:913) deletes a channel but how it treats a pair that uses it is not stated in the doc; the invariant `0 <= current_pair <= length(pairs)` is checked at open (database.jl:231). Removing a pair needs to keep `current_pair` valid (set to 0 or shift).
5. `set_marked!` accepts rows below 1.
   - Exists: `set_marked!(s, range)` (session.jl:645). It checks only `range[1] <= range[2]`.
   - Missing: a check that `first >= 1`, and any check against the number of rows of the cursor line or that a cursor exists. `set_cursor!` (session.jl:631) also takes any `Cursor` without checks (item, line, row). The UI must clamp rows itself until this is fixed.

## 10. Test layout and package setup

- Root `Project.toml` has only `[workspace] projects = ["JuliaMagCore"]` (one package in the workspace). A root `Manifest.toml` exists. So a UI package could be added to `projects = [...]` as a second workspace member (for example `JuliaMagUI`), sharing the manifest. `bench/`, `examples/quickstart.jl` and `prototype/juliamag-ui.html` (HTML mock-up of the UI) live at the root.
- `JuliaMagCore/Project.toml`: name JuliaMagCore, uuid 133f1fd6-5f53-418f-9a68-c205e5f9c1d6, version 0.1.0. Deps: ArchGDAL, CodecZlib, EzXML, JSON3, Mmap, Parquet2, Parsers, Printf, Proj, StructTypes, Tables. Compat: `julia = "1.12"`, ArchGDAL 0.10, Parquet2 0.2, Proj 1.9, Aqua 0.8, JET 0.13, others 1/2. Test deps via `[extras]` + `[targets] test = ["Test","Aqua","JET"]`. (Julia 1.12 is the compat floor; the compiled cache dir seen was `v1.12`.)
- Tests: `test/runtests.jl` (29 lines) is a single `@testset "JuliaMagCore"` that `include`s 25 files in a fixed order. `support/synthetic.jl` is included once in the middle (after `test_grid.jl`, before `test_session.jl`). `support/grids.jl` is included by the grid tests.
  - Order: test_quality, test_model, test_database, test_project, test_grid, (support/synthetic), test_session, test_lock, test_xyz, test_grid_import, test_gdal_grid, test_geosoft_grd, test_grd_files, test_grid_export, test_csv, test_jobs, test_tools, test_followups, test_export, test_coordinates, test_channel_math, test_statistics, test_grid_properties, test_grid_end_to_end, test_end_to_end.
  - Data in `test/data/`. Run with `Pkg.test()` for the package (about 21 000 lines of Julia in total, 9 000 in tests approx).
- Helpers (`test/support/synthetic.jl`): `fresh_session()` (new session in a temp folder), `with_session(f, folder)`, `testdata(name)`, `add_test_database!(s, channels; protected)`, `make_test_database!(s)`, `make_db_with(; channels...)`, `database_of(s, r::ImportResult)`, `TestRng`/`next_unit!` (own RNG), `write_synthetic_xyz(path; lines, ties, ...)`. `test/support/grids.jl`: `small_grid(folder; nx, ny)` and a Geosoft header writer helper.
- Quality: `test/test_quality.jl` runs `Aqua.test_all(JuliaMagCore)` (all default checks, including ambiguities, unbound args, stale deps, piracy, undefined exports, persistent tasks) and `JET.test_package(JuliaMagCore; target_modules = (JuliaMagCore,))`. It does `using JuliaMagCore: report_text` because JET also exports `report_text`. Consequence: any new export must have a docstring-free but defined binding, no type piracy, and no dependency listed but unused. Adding CImGui to the Core package would break the stale-deps check, so the UI must be a separate package.
- Name clash note for the UI package: JuliaMagCore exports `report`, `status`, `channel`, `line`, `item`, `grid`, `database`, `tool`, `tools`, `validate`, `jobs`. `using JuliaMagCore` next to CImGui or Makie can cause ambiguity warnings. Use `import JuliaMagCore as Core` or explicit `using JuliaMagCore: ...`.

## Other things the UI author should know

- `run_tool` quick tools return `outputs` as item ids (commit 8f580cb). Job `outputs` are item ids too.
- No cancel for quick tools. No progress for quick tools (`NO_PROGRESS`).
- `Statistics` and similar results are text only (the `report`).
- Item file removal on `remove_item!` is deferred to close; `item_missing` handles a project whose folder was deleted outside.
- Windows is the main platform but no test has run there (followups "Checks on real systems").
