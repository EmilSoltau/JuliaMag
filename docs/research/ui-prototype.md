# Research: JuliaMag UI prototype (juliamag-ui.html)

File: `/home/ems/work/_projects/coding-workspace/Mag processing tool/JuliaMag/prototype/juliamag-ui.html` (4376 lines).
Line numbers below refer to this file.
CSS is lines 7-512. HTML skeleton is 514-529. JS is 529-4374.
The prototype says its tokens come from RustGIS `crates/ui-egui/src/theme.rs` (line 8).
Fonts are px-based CSS. In CImGui the same sizes can be used as ImGui style values.

## 1. Overall shell layout

The page is a fixed column (`#app`, line 72): header, tab strip, ribbon, main row, status bar.
HTML order is at lines 515-526.

| Part | Id | Size | CSS line |
|---|---|---|---|
| Title bar (header) | `#header` | height 34 px, side padding 10 px, gap 2 px | 73 |
| Ribbon tab strip | `#tabs` | height 32 px, side padding 8 px, gap 2 px | 84 |
| Ribbon body | `#ribbon` | height 102 px, padding 5/8/3 px, bottom border 1 px | 99 |
| Main row | `#main` | flex 1, holds left, center, right | 135 |
| Left side pane | `#left` | width `--left-w` = 272 px, resizable 200..480 px (line 4320) | 136 |
| Central area | `#center` | flex 1 | 141 |
| Right side pane | `#right` | width `--right-w` = 300 px, resizable 240..480 px, hidden when no tab is open | 137 |
| Splitters | `.splitter` | 6 px wide, margin -3 px, hover shows accent bar at 70% opacity | 138 |
| Status bar | `#status` | height 26 px, side padding 10 px, gap 10 px, font 11.5 px | 327 |
| Toast stack | `#toasts` | fixed, right 12 px, bottom 38 px, gap 8 px | 338 |

Header contents (renderHeader, line 1774):
- Logo 24 x 24 (purple rounded square, `--brand`).
- App name "JuliaMag", bold 13 px.
- Quick access toolbar (QAT): New, Open, Save, Undo, Redo, theme toggle. Icon-only buttons, 18 px icons (line 1792).
- Title centred (absolute, left 50%): bold project name, then dim " - " and the active view name, for example "Database: Kangaroo Hills 2024" (line 1803).
- Command search box at the right: 248 x 24 px pill, radius 12, shows search icon, text "Command Search" and "Ctrl+K" (line 89).

Tab strip (renderTabs, line 1819):
- First item is the "Project" button: 26 px tall, purple `--brand` fill, white bold text, opens the backstage (line 85).
- Then the normal tabs, then a spacer, then the fixed tabs (Settings, Help), then a collapse chevron button 24 x 24 (line 1844).
- The active tab has a ribbon-coloured rounded top, 1 px border and a 2 px accent underline (lines 88-92).
- The tab strip reserves bold width so it never jumps (lines 95-97).
- Planned tabs are italic.
- Double-click on a tab, or Ctrl+F1, collapses the ribbon (line 1833).
- When collapsed (`ribbon-min`) the ribbon is hidden. Clicking a tab "peeks" it as a floating panel at top 66 px with a shadow. A click elsewhere closes the peek (lines 109-110, 4341).

Ribbon body details:
- Groups (`.rg`): column with the body (72 px high) and a 18 px group label below (11 px, `--group-label`). A 1 px vertical separator sits at the right of each group (lines 112-116).
- Big button (`.rb-big`): 70 px high, min width 50 px, 32 px icon, label 11.5 px under it, label may be two lines (lines 123-125).
- Split button: big button plus a 20 px wide caret button, with 1 px divider (lines 126-128).
- Small button (`.rb-small`): 22 px high, 18 px icon, label 11.5 px. Three small buttons stack in one column (`.rb-col`, line 130, `col >= 3` rule at line 1919). A `col: 'new'` flag forces a new column.
- Icon-only small button is 26 px wide (line 131).
- Hover `--hover`, pressed `--pressed`, checked `--checked` plus a 1 px inset accent ring (lines 120-122).
- Disabled and "later" commands are greyed (`aria-disabled`).
- When groups are wider than the window, 18 px arrow buttons appear at the edges. The mouse wheel scrolls it sideways (lines 104-105, 1936, 4321).

Panes: 34 px header band (`.phead`, line 148) with tabs underlined in accent. Pane body fills the rest.
Tree rows are 26 px high with a 4 px inset hover rounded 5 px (lines 170-173).
Dialogs, menus, tooltips: see sections 5-6.

## 2. Theme

### 2.1 Tokens

Set on `:root` (line 9) for light, and `:root[data-theme="dark"]` (line 29) for dark.
`<html data-theme>` is switched by `setTheme` (line 1763). Mode can be light, dark or system. It is stored in localStorage `juliamag.theme` (can be set with `?theme=` in the URL).

| Token | Light | Dark |
|---|---|---|
| `--header` | #EEF1F5 | #171B21 |
| `--ribbon` | #FFFFFF | #242931 |
| `--tab-strip` | #EEF1F5 | #171B21 |
| `--canvas` | #E4E8EE | #12151A |
| `--pane` | #FBFCFD | #1E232A |
| `--pane-header` | #F3F5F8 | #242931 |
| `--border` | #DDE2E9 | #343B45 |
| `--border-strong` | #C3CAD4 | #48515D |
| `--text` | #1F2630 | #E6EAEF |
| `--text-dim` | #5E6977 | #9AA4B1 |
| `--text-disabled` | #A9B1BC | #5C6571 |
| `--icon` | #3A4554 | #C9D1DB |
| `--hover` | #E9F0FB | #2F3744 |
| `--pressed` | #D4E2F8 | #2A3D5E |
| `--checked` | #DCE8FA | #283B5C |
| `--accent` | #2563EB | #5B8DF6 |
| `--accent-text` | #1D4EC4 | #8AAFFA |
| `--on-accent` | #FFFFFF | #FFFFFF |
| `--input` | #FFFFFF | #15191F |
| `--input-border` | #C6CDD7 | #444D59 |
| `--group-label` | #707A88 | #8C96A3 |
| `--status-bar` | #F3F5F8 | #1A1E24 |
| `--selection` | #CFE0FC | #26406E |
| `--menu` | #FFFFFF | #262C34 |
| `--shadow` | rgba(0,0,0,0.11) | rgba(0,0,0,0.43) |
| `--green` | #169A5A | #3FC282 |
| `--red` | #D13C3C | #F06A6A |
| `--amber` | #E59E1A | #F2B848 |
| `--context` | #0E9384 | #2CC2AE |
| `--context-tint` | #E3F5F2 | #1B3331 |
| `--well` | #DDE3EA | #3A424D |
| `--stripe` | #F6F8FA | #21262D |
| `--backdrop` | rgba(20,26,34,0.28) | rgba(0,0,0,0.45) |
| `--brand` | #7D4A9B | #7D4A9B |
| `--brand-dark` | #693D83 | #693D83 |
| `--brand-tint` | #FFD36E | (not redefined, stays #FFD36E) |

Notes:
- `--brand-tint` is the "Julia yellow" used for icon accent in the backstage nav (line 480 `--ica: var(--brand-tint)`).
- `--context` and `--context-tint` are defined but I found no use in the shell CSS. Treat as reserved.
- Layout vars: `--left-w: 272px; --right-w: 300px` (line 22).
- Derived colours use `color-mix(in srgb, var(--accent) 55%, transparent)` for the checked ring and some overlays. In ImGui these become fixed alpha blends.
- Map lines and grid colour ramps are in `RAMPS` (line 867). Profile series colours are `SERIES = ['accent','amber','green','red']` (line 3160).

### 2.2 Fonts and sizes

- `--font`: "Segoe UI Variable Text", "Segoe UI", Ubuntu, system-ui, -apple-system, "Noto Sans", "Helvetica Neue", Arial, sans-serif (line 20).
- `--mono`: "Cascadia Mono", Consolas, "Ubuntu Mono", "DejaVu Sans Mono", ui-monospace, monospace (line 21).
- Body: 12.5 px, line-height 1.25 (line 48).
- App name 13 px / 600. Title 12.5 px bold. Group label 11 px. Ribbon labels 11.5 px.
- Dialog title 15 px / 600. Backstage h1 26 px, h2 15 px, nav items 14 px.
- Section headings (`.sect`): 11 px / 600, uppercase, letter-spacing .02em, 26 px high (line 167).
- Mono text 12 px; status bar mono 11.5 px; tooltip id line 11 px.
- Text is not selectable except inputs and some read-only text (`user-select: none`).

### 2.3 Other shared metrics

- Corner radius: buttons 6 px, small buttons 5 px, inputs 5 px, menus 8 px, dialogs 10 px, tooltips 6 px, toasts 8 px, checkbox 3 px.
- Input height 24 px; `.btn` 26 px; `.btn.small` 22 px; combo 24 px, small combo 22 px; segmented control 24 px.
- Checkbox 14 x 14. Slider track 4 px, thumb 12 px.
- Menu item height 24 px, min width 200, max 360; menu header 22 px, uppercase 10.5 px (lines 237-250).
- Tooltip shows after 480 ms hover (line 1007). Tooltip: bold title with shortcut in brackets, dim description, italic "Later: ..." line, mono command id line (lines 986-994).
- Focus ring: 2 px accent outline (line 53).
- Scrollbar: 10 px, rounded thumb `--border-strong` (line 160).
- Icons: 24-unit grid, ink stroke 1.6 with accent fills, drawn as SVG paths in the `ICONS` table (lines 584-707). Sizes used: 32 (big ribbon), 18 (small ribbon and QAT), 16 (tree, menus, panes), 14, 12, 10 (close x).

## 3. Ribbon

Tabs are data (`TABS`, line 1255). A tab is shown when at least one command is placed on it (`tabVisible`, line 1813). Hidden tabs can be switched off in Settings > Ribbon > Show Tabs.
Commands carry `at: [{tab, group, kind, order?, col?, label?, menu?, items?}]`. `renderRibbon` (line 1900) builds the groups from this.
Kinds: `big`, `small`, `split` (big plus menu list of command ids), `menu` (big with caret), `smallmenu` (small with caret), `custom` (own render function).
Commands with `later:` are shown greyed with a "later" tag. Clicking shows a toast "X is planned for a later version" (line 1752).

Placement per tab (L = "later" i.e. not yet built; B = big, S = small, Sp = split, M = menu):

### Database (line 1256)
- Database: custom "Acts on" combo (the database chooser, see 3.1).
- Import: split "Import" (Geosoft XYZ), menu: Geosoft XYZ, CSV and Text, -, ASEG-GDF2 (L), Geosoft Binary GBN (L). Small menu "Import Templates" with saved CSV layouts and "Manage Templates...".
- Export: split "Export" (CSV), menu: CSV, Geosoft XYZ, Parquet, -, ASEG-GDF2 (L).
- Lines: S Previous Line (Alt+Left), S Next Line (Alt+Right), S Go To Line..., S Select Lines..., S Select All, S Select None, S Line Properties... (two columns of up to three).
- Channels: B New Channel, S Copy Channel..., S Delete Channel..., S Channel Properties..., S Protect (toggle), S Set Current X,Y... (alias of coords.set_pair).
- View: B Database View, B Profile View, S Sync Cursor (toggle), S Split View (menu: Side by Side, One over the Other, Single View), S Statistics Pane (toggle).

### Database Tools (line 1256)
- Calculate: B Channel Math, B Statistics.
- Lines: B Split into Lines.
- Edit: S Search and Replace..., S Interpolate Gaps..., S Dummy a Range... (L).
- Filters: B Despike (L), S Low High and Band Pass... (L), S Non-linear Filter... (L), S Rolling Statistics... (L).
- Resample: S Decimate... (L), S Resample to Distance... (L).
- Find: B All Tools (toggles the Tools pane).

### Coordinates
- Coordinate System: B Set Coordinate System, B Reproject, S Set Current Pair..., S Guess UTM Zone.
- Repair: B Interpolate X,Y Gaps (L), S Fill GPS Gaps... (L).
- Georeference: S Define Warp... (L), S Warp Data... (L), S Warp Grid... (L).

### Grid and Image
- Import: split (Geosoft or Surfer Grid .grd; menu adds ER Mapper .ers).
- Export: split (Geosoft Grid .grd; menu adds ER Mapper, GeoTIFF).
- Grid: B Grid Properties, B Colour Style.
- Gridding: B Grid Data (L), S Bi-directional Gridding (L), S Kriging (L).
- Utilities: S Window Grid (L), S Fill Grid Gaps (L), S Remove Trend (L).
- Filters: B FFT Filters (L).
- Find: B All Tools.

### Map
- Map: B New Map, M "Add Item" (menu of items), S Remove Layer.
- Navigate: B Full Extent (Home), S Zoom In (+), S Zoom Out (-), S Zoom to Layer, S Previous Extent, S Next Extent, S Go To Cursor.
- Display: B Point Readout, B Layer Style, S Hillshade (toggle), S Colour Bars (toggle), S Line Labels (toggle).
- Bookmarks: B Bookmarks (L).
- Layout: B New Layout (L).

### Magnetics (planned tab, italic, hidden unless "Planned tabs (preview)" is on; lines 1717-1722)
- Corrections: B Lag Correction, B Heading Correction, B Base Station Correction.
- IGRF: B Remove IGRF.
- Levelling: B Tie-Line Levelling, B Microlevelling.
- Filters: B Reduce to Pole.
All are `later` and `planned`. They exist only to show where the processing chain will go.

### Settings (fixed tab, right side of the strip; line 1723)
- Theme: three big toggle buttons Light, Dark, System (checked state shows the current).
- Defaults: custom group with two small combos: "Distance units" (Metres, Kilometres, Feet) and "Grid colours" (default colour table). Plus small "Temp Folder..." tool (folder, shows free space).
- Startup: small checkbox-style "Open Last Project" (toggle).
- Rendering: big "Software Rendering" toggle (takes effect at next start; status bar shows GPU or Software).
- Ribbon: big menu "Show Tabs" (list of tabs with check marks; Settings and Help disabled; Magnetics preview toggle).

### Help (fixed tab, line 1740)
- Help: B Command Search (Ctrl+K), B Getting Started, B Keyboard Shortcuts.
- About: B All Tools, B About.

Getting Started dialog (line 4264): numbered list of the processing chain (Import, Lag, Levelling, IGRF, Gridding, RTP, ...) with where each step lives and a "now" or "later" tag. Width 560.

### 3.1 Database chooser (left edge of the Database tab)
- `db.choose` command, kind `custom`, `renderDbChooser` (line 1951).
- A column: small label "Acts on", a small combo 170 px wide listing all line databases (with database icon), and a dim note "N lines, M channels".
- Changing it calls `setCurDb`, which re-renders the ribbon and status bar. It is hidden from command search (`searchHidden`).
- The current database also follows selection in the Data tree.

### 3.2 Project backstage (line 4168)
Opens from the purple Project button, Ctrl+N, Ctrl+O, and the commands project.*.
It is a full-window overlay (`#backstage`, z-index 400): left nav 210 px wide in `--brand` purple with white text, right body padded 36 / 48 px.
Nav: a Back arrow button (Esc closes), then Start, New, Open, Save (runs the save and closes), Save As, separator, Project Settings, Run Script, separator, About, and a footer "JuliaMag 0.1 prototype" (lines 4172-4183).

Pages:
- Start: logo + "Welcome to JuliaMag", lead text. "New Project" cards (200 x 160 px: Empty Project, Import Line Data, Open...). "Recent Projects" list (44 px rows: icon, bold name, dim path, when; missing folders greyed with "(folder not found)"). "Current Project" info grid (Name, Folder, Items, Jobs, Saved note: data is written at once, views and layer lists autosave every N minutes).
- New: form (max width 640): Name, Folder + Browse, Coordinate system (read-only, "Set by the first import"), Create Project button.
- Open: Browse for a Project button and the recent list.
- Save As: New folder + Browse, checkbox "Copy the data files too (2.1 GB)", Save Copy.
- Project Settings: Name, Folder (read-only), Coordinate system + Change (default for new maps), Distance units (segmented), Autosave views (minutes), Description (textarea).
- Run Script: a mono textarea (300 px high) with a Julia script made from the command history (`run_tool("id"; key = value, ...)`), buttons Run, Save Script As..., Open Script...; a help line saying the same calls work from the REPL. Output box below.
- About: version, description, shortcut table.
- Project file is `.jmag` in a project folder (recent list, line 4161).

## 4. Side pane (left): Data, Layers, Jobs

Header (`renderLeftNow`, line 2032): three text tabs Data, Layers, Jobs in the 34 px band. Jobs gets a round accent count badge (16 px, white 10.5 px bold) with the number of running jobs.

### 4.1 Data tab (line 2087)
Body is a scrollable tree, a Properties panel below, and a filter box at the bottom.
Tree rows: 26 px; expand chevron (14 px, indent 9 + 16 x depth), optional checkbox, 16 px icon, name, optional tag, optional action link, dim right-aligned count text.
Structure:
- Databases (folder, count)
  - Database name (select sets current database; double-click opens Database view)
    - Lines (folder, "N of M selected")
      - Line id, e.g. L1012 (checkbox = selected for processing, icon L or T, bold accent when it is the cursor line, right text "F18  3,420" = flight and rows)
    - Channels (folder, count)
      - Channel name (lock icon if protected, role tag such as x, y, line, right text = units)
- Grids (folder, count)
  - Grid name (count "nx x ny"; double-click adds to current map)
  - Missing item shown italic and grey with a "Find..." action link (opens Find Missing Data dialog; paths are stored relative to the project folder)
- Maps (folder, count)
  - Map name (count "N layers"; double-click opens it)
Expanded state is kept in `S.expanded`. Folder names are bold.
The filter box ("Filter items, lines and channels") matches database, line and channel names, auto-expands all, Esc clears.
Keyboard: Up and Down move selection, Right and Left expand and collapse, Enter opens, Menu key or Shift+F10 opens the context menu (line 2078).

Context menus:
- Databases folder: Import Geosoft XYZ, Import CSV and Text, -, Export All Databases..., etc.
- Database: Open Database View, Open Profile View, Add to Current Map, -, Statistics..., Channel Math..., Export CSV..., Export Geosoft XYZ..., -, Rename..., Remove from Project (danger red, confirm box).
- Lines folder: Select All, Select None, and more (line truncated at 2102).
- Line: Show in Database View, Show Profile, Show on Map, and more.
- Channel (`chanMenu`, line 2161): Statistics, Channel Properties..., Protect or Unprotect, -, Copy Channel..., Delete Channel... (danger).
- Grids folder: Import Grid..., -, Remove All Grids... (danger).
- Grid (`gridMenu`, line 2171): Add to Current Map, Colour Style..., Statistics, -, Export Geosoft Grid..., Export GeoTIFF..., -, Rename..., Remove from Project.
- Map: Open, Rename..., and more.
- Removal opens a confirm box saying the action can be undone.

Properties panel (`renderProps`, line 2199): max 46% of pane height, header "Properties: <name>", key-value grid (96 px key column), and a Description textarea for databases, grids and maps. Fields by kind:
- Database: Type, Lines (lines and ties), Rows, Channels, Positions (X,Y pairs with CRS), Folder, Made by.
- Grid: Type, Size, Cell size, Origin, Rotation, System, Values, Colours.
- Map: Type, Layers, System, Note.
- Line: Type, Number and version, Flight and date, Fiducials, Rows, Length, Selected.
- Channel: Label, Data type, Units, Role, Protected, Format, Missing, File.
- Missing grid: Type, Was at, Status.

### 4.2 Layers tab (line 2252)
- Toolbar (32 px): Add item (menu), Remove layer, Move up, Move down, Layer style, and at the right a small map chooser combo (112 px).
- Rows of the current map: drag grip, visibility checkbox, 16 px icon (lines or grid), name (grey if hidden), opacity % when below 100.
- Below each row a 22 px sub-line: colour channel or "Grid colours" or "Own colours", a colour ramp strip, "hist. eq." or "linear".
- The selected layer shows an Opacity slider row (28 px).
- Drag to reorder, with a 2 px accent drop line. Footer text: "Drag rows to change the drawing order. The top layer draws last."
- Double-click opens Layer Style. Context menu: Zoom to Layer, Layer Style..., Colour Style of the Grid..., and more.
- Empty map shows a message and an "Add Item" button.
- Visibility, reorder and opacity are undoable (`doChange`).

### 4.3 Jobs tab (line 2315)
- Top bar (32 px): "N running, M finished" text and a small "Clear Finished" button at the right.
- Empty state: "No jobs yet. Imports and long tools run here."
- Each job is a card (`jobCard`, line 2326), newest first, 1 px bottom border, padding 9/12/10:
  - Row 1: 16 px status icon, bold name, right side text (percent while running, start clock time when finished).
  - Row 2: dim target line, for example "KH2024_mag.xyz  ->  Kangaroo Hills 2024", or the expression for Channel Math.
  - Running: 4 px progress bar (accent on `--well`), step text line (for example "Reading line 1052"), then link buttons "Cancel" and "Report".
  - Done: "Done in 2.1 s. <first output note>". Cancelled: "Cancelled at 40%. Nothing was written." Failed: red wrapped error text.
  - Finished jobs: link buttons "Run Again..." and "Report".
- Status icons: running = clock, done = ok, failed = error, cancelled = stopped.
- Count badge: only on the Jobs tab header (running count). The status bar also shows "N jobs running" with a spinner, and clicking it opens the Jobs tab.
- Cancel (`cancelJob`, line 3633) sets status, logs it, shows a toast "X cancelled - Nothing was written."
- Report dialog (`showReport`, line 2346): width 640, mono log text with timestamps "[08:03:10] step", settings listing (`key = JSON`), and result lines; footer Copy, Close.
- Run Again... opens the tool dialog with the old settings (see 6.5).
- Simulation: `tickJobs` every 100 ms advances progress. Real app must do this in a worker task.
- Job record shape: `{id, tool, name, target, vals, status, progress, started, ended, ms, steps, log[], stepText, error, outputsNote}` (line 3623).

### 4.4 Right pane (Statistics, Tools)
Not requested but part of the shell (line 2354):
- Tabs that each have a close x. A "close all" icon at the right. Pane is hidden when empty.
- Statistics: source segmented control (Channel or Grid), Database, Channel, Lines (Current, Selected, All) combos, a caption, a count/missing/min/max/mean/std/median/5-95% table (24 px rows), a 150 px histogram canvas, "Follows the cursor and edits." and "Save as CSV".
- Tools: search box "Find a tool by name or id", list grouped by ribbon tab, rows 42 px: icon, accent bold name, mono id, "later" or "job" tag. Click runs the tool. Footer says each tool is one Julia function plus a description.

## 5. Command search (Ctrl+K) (line 4109)

- Opens from Ctrl+K, the header box, or Help > Command Search. Works even when a dialog is open (it is handled before dialog checks, line 4327).
- Layout: floating panel, 560 px wide (max viewport minus 48), top 84 px, centred, radius 10, shadow, over a transparent backdrop (z 899/900).
  - Top row 42 px: search icon, input (placeholder "Search commands, for example import, channel math, db.export"), close button.
  - List: max 380 px high, rows 28 px: 16 px icon, name (13 px), mono id (dim), "later" tag, right-aligned location "Tab > Group" (or "Tab > Group > Menu"), and the shortcut (min 54 px).
  - Footer 28 px: "Up Down to move", "Enter to run", "Esc to close", and "N commands" at the right.
- Matching and score (line 4125): name starts with query 4, name contains 3, id contains 2, location or description contains 1. "Later" commands lose 0.5 when a query exists. Empty query lists all (score 1). Max 80 shown.
- Excluded: commands with `searchHidden` and planned commands unless the Magnetics preview is on.
- Keys: Up and Down move the highlight (scrolls into view), Enter runs and closes, Esc closes, mouse hover moves the highlight, click runs.
- Running a "later" command shows the toast "planned for a later version".
- No results: "No command matches ...".
- Command location text comes from `cmdWhere` (line 1746), based on the ribbon placement.

## 6. Tool settings dialog (generated from tool descriptions)

### 6.1 The JS tool description shape
Registered with `tool({...})` (line 1274). A tool is a command plus a description. Fields:
- `id`: string such as `db.import_xyz`. Also the script call id.
- `name`: full name, ends with `...` for menu entries that open a dialog. `menuName`: shorter name for split menus. `label`: ribbon label (`\n` makes two lines). `icon`.
- `desc`: one line for tooltips. `help`: paragraph shown at the top of the dialog.
- `okLabel`: label of the primary button (Run, Import, Export, Create, Apply, Show, Select...). Default "Run".
- `at`: ribbon placements (see section 3).
- `inputs`: array of input settings, usually `[IN_DB]` or `[IN_GRID]` (`{key:'db', label:'Database', type:'db'}`).
- `settings`: array of setting objects.
- `quick: true`: runs `apply(v)` at once with no job (small edits such as Go To Line, Statistics, Search and Replace, Set Coordinate System, Layer Style).
- `job: {ms, steps(v)->[text], finish(v, job)->[output lines]}`: background job (simulated duration, step texts, and result). Without `quick` and with `job`, the OK button starts a job. Tools without a job and without `quick` are not used in the prototype.
- `jobName(v)`, `jobTarget(v)`: strings for the Jobs card.
- `validate(v) -> {key: message}`: extra checks that run when OK is pressed (for example expression syntax, protected channel, output exists).
- `preview(v)`: element for a "File preview" section (file imports).
- `apply(v)`: handler for quick tools.
- `later`, `planned`, `custom` flags for non-built tools (`custom` means the command has its own dialog, such as the CSV wizard).

### 6.2 Setting object
Common keys: `key`, `label`, `type`, `default`, `defaultFn(v)`, `hint`, `advanced: true`, `visibleIf(v)`, `unit`, `min`, `max`, `mono`, `remember: false` (do not restore from the last run), `placeholderFn(v)`.
Types (switch at line 3772):
- `db`, `grid`, `layer`, `line`, `pair` (X,Y position pair): dropdown filled from the project.
- `channel`: dropdown of channels of the chosen database; `numeric`, `role` (channels with that role listed first), `ofLayer`.
- `lines`: segmented control "All (N) | Selected (n) | Current (L1012)". `default` can be `all` or `current`.
- `crs`: read-only text, a "Change..." button that opens the CRS picker, and a hint with the guessed system and why.
- `file`: mono text input plus "Browse..." (a menu of sample files in the prototype). `save`, `folder`, `ext`, `files` options.
- `number`: right aligned input max 140 px wide, with unit text; checks min and max.
- `auto`: number input with placeholder "auto: X" and hint "Blank means auto, worked out from the data."; blank means auto.
- `text`: plain or mono input.
- `expr`: mono input plus a row of small chips (one per channel name, click inserts) and a live hint line that shows what will be written or the compile error.
- `choice`: dropdown, or segmented when `seg: true`; `options: [[value, label, disabled]]`; `ramp: true` shows a colour strip next to the colour table dropdown.
- `bool`: checkbox with the label next to it (label column left empty).
- `info`: read-only dim text from `textFn(v)`.
Shared blocks: `LINES` (Lines), `ADD_MAP` (Add to current map, bool, default true), `IN_DB`, `IN_GRID` (lines 1301-1304).

### 6.3 Dialog layout (`openTool`, line 3692; `openDialog`, line 1160)
- Modal, centred, draggable by the title bar. Width 580 px (620 when it has a file preview). Max height viewport minus 40. Backdrop dims the app.
- Header 46 px: 22 px tool icon, title (15 px / 600), mono command id in dim text, close button. Esc closes the topmost dialog.
- Body (14/16 padding, scrolls):
  1. Help paragraph (`help` or `desc`).
  2. A status line with an icon: "Default settings.", or "Opened with the settings of your last run in this project." (clock icon), or for reruns "Settings of job N, 08:03. Change any of them before running it again." Right side: "Runs as a background job" for job tools.
  3. Main form: grid with a 150 px label column and one control column, row gap 8, column gap 12. Hints go under the control in 11 px dim text; errors are red and put a red ring on the input.
  4. Optional "File preview" section.
  5. "Advanced" collapsible (chevron + bold dim text, 1 px top border). Open state is remembered per tool for the session. Holds all settings with `advanced: true`.
  6. "Tool Description" box (hidden by default): mono 11.5 px block showing the Julia description the dialog was built from and the script call for the current values (see 6.4).
- Footer: left side "Reset to Defaults" button and a link-style "Tool Description" toggle (script icon); then a spacer; right side "Cancel" and the primary button (`okLabel`, bold, accent fill).
- Enter in a text field presses the primary button.
- Settings are remembered per tool for the project (`S.toolSettings[id]`), except those with `remember: false` (which are re-derived from the current selection). Inputs (database, grid) are remembered too.
- Defaults: `db` = current database, `grid` = selected grid or first grid on the map, `layer` = selected layer.
- Reset to Defaults resets settings but not inputs, clears errors, and shows a toast "Settings reset to their defaults".
- Validation on OK: number is a finite number inside min/max; auto blank or number; file not empty; channel chosen; then `validate(v)`. Errors open the Advanced section if the first error is inside it and focus that field. Hidden settings (`visibleIf` false) are skipped.
- On OK for a job tool, the dialog closes, `startJob` runs, `S.history` gets the entry, and a toast "X started - It runs in the background. Progress is in the Jobs pane." shows (2.6 s).
- For `quick` tools, the dialog closes and `apply` runs at once.

### 6.4 "Tool Description" (Julia shape implied)
`toolDescription` (line 3892) prints this pseudo-Julia, which shows the intended real API:
```
tool(
    id       = "dbtools.channel_math",
    name     = "Channel Math",
    icon     = :math,
    places   = [("Database Tools", "Calculate")],
    inputs   = [:db => LineDatabase],
    settings = [
        :expr => Expression(of = :db, default = "..."),
        :lines => WhichLines(default = :all),
        :exists => Choice([:replace, :stop], default = :replace, advanced = true),
        ...
    ],
    job      = true,
    run      = channel_math!,
)
run_tool("dbtools.channel_math"; db = "Kangaroo Hills 2024", expr = "...", lines = :all)
```
Setting types map to Julia types in `juliaType` (line 3871): `Num(default, min, max, unit, advanced)`, `Auto(Num(unit))`, `Text`, `Expression`, `Choice([...])`, `Toggle`, `FilePath/SavePath/FolderPath(ext)`, `ChannelOf(of, role, numeric)`, `WhichLines(default)`, `CoordinateSystem(guess)`, `PositionPair`, `LineOf`, `Info`. Input types: `LineDatabase`, `Grid`, `MapLayer`. Empty value prints as `nothing`. Choice values print as symbols.
The script page and `S.history` use the same `run_tool("id"; key = value, ...)` form.

### 6.5 Add to current map, and rerun
- `addToMap` ("Add to current map") is a normal `bool` setting (default true) on import tools (XYZ, CSV, grid). On finish, imports add a layer to the active map: lines layers on top (`unshift`), grids above other grids (lines 3505, 3549). The toast says "Added to Map 1." The CSV wizard has the same checkbox in step 3 (line 4087).
- Rerun: the Jobs card "Run Again..." (and the failure toast) calls `openTool(j.tool, j.vals, {rerunOf: j})`. Title becomes "Run Again: <name>". The status line tells which job the settings came from.
- In rerun mode the form gets one extra checkbox at the end of the main form: "Replace the old output" with hint "Off: the run makes a new item, and the old one stays." (line 3728). It is stored in `vals.replaceOld`.
- Finding: in the prototype `replaceOld` only goes to the job log ("replacing its output" or "as a new item", line 3626). Nothing is actually replaced. The real app must define what "replace" means for each tool output (for example delete the old channel or grid and keep layers pointing at the new one) and make it undoable.
- Jobs record `job.undoable` for imports and add an undo entry (line 3508). So job results go into the undo stack.

## 7. Import dialogs (brief, for a later plan)

- Geosoft XYZ import is an ordinary tool dialog (section 6). Settings: File (Browse lists sample files with sizes), "Import into" segmented (New database | Existing database), Database name (blank = from file name, placeholder "auto: ..."), Append to (database), Coordinate system with guess ("X and Y look like UTM eastings and northings..."), Add to current map. Advanced: Missing value text (`*`), Channel names (From the last matching / line | Numbered C1, C2...), Read chunk size (auto, MB). Includes a "File preview" block (`xyzPreview`, line 3513). Streaming in chunks, so large files never fill memory.
- Append mode: lines that already exist get a new version.
- A broken-header sample file triggers a failure with a clear message: line 7 has 8 values but header lists 9; suggests Advanced > Channel names > Numbered. Error says "Nothing was written."
- Grid import (`.grd`, `.ers`): File + CRS + Add to map; CRS read from the `.grd.gi` side file when present. ER Mapper sample fails with "Data file ... not found next to the header ...".
- CSV and Text wizard (`openCsvWizard`, line 3990): own dialog, 720 px wide, three numbered steps shown as a step bar:
  1. File layout: File + Browse, Layout (Delimited | Fixed width), Delimiter (Comma, Tab, Semicolon, Spaces), Rows (Heading row, Units row, first data row; 0 = none), preview of the first 10 raw rows with heading and units rows styled, warning if only one column is found.
  2. Column roles: table with one row per column: Name (input), Use (Skip, Data, Line, Fiducial, Array), Type (Float 64, Float 32, Integer 32, String...), Units, Channel role (x, y, longitude, latitude, elevation, date...). Auto-guessed from names and the units row.
  3. Lines and coordinates: how to split lines (by a channel), line column and type, X and Y columns, coordinate system, import mode (new or append), name, target, Add to current map.
  - Footer: "Load Template..." on the left (saved layouts), Cancel, Back, Next (becomes "Import" on step 3). It then starts a job like other imports.
- CRS picker (`openCrsPicker`, line 3921): EPSG search, favourites, recent, and a "guess" banner.

## 8. Toasts, errors, warnings, undo, status bar

### 8.1 Toasts (`toast`, line 1216)
- Stack at bottom right (12 px from the right, 38 px from the bottom, above the status bar). Each toast max 380 px wide, 8 px radius, shadow, 0.14 s slide-up.
- Layout: 16 px kind icon (ok green, info, warn, error), text, optional dim second line (`sub`), optional row of small action buttons (for example "Open", "Zoom", "Report", "Run Again..."), and a close x.
- Kinds: `ok` (default), `info`, `warn`, `error`.
- Auto dismiss after 4.2 s; 9 s when it has actions; custom `ms` (2.2 s for undo/redo toasts, 2.6 s for job start, 12 s for job failure).
- `aria-live="polite"`.
- Used for: job started, cancelled, failed (with Report and Run Again), import done (with Open/Zoom), undo and redo ("Undone: X"), "Nothing to undo", settings reset, save ("Project saved" + path), theme or rendering hints, "planned for a later version".

### 8.2 Errors
- Field errors: red 1 px ring on the input plus red hint text under it; Advanced opens if needed and the field gets focus. Number errors read "Type a number.", "At least 5 deg.", "At most ...".
- Tool errors in quick tools: toast kind error with `sub` text of the exception.
- Job errors: failed card in the Jobs tab (red wrapped text, full message), an error toast with Report and Run Again actions, and a full log in the report dialog. Messages are plain language and say what to do next and whether data was written.
- Missing data: greyed italic tree item with "Find..." link and tooltip; the project still opens.
- Confirm boxes (`confirmBox`, line 1206): 420 px dialog, warn icon for dangerous, buttons Cancel and the action (primary); used for removing items. Removal says "It can be undone."
- No separate error console or modal for errors.

### 8.3 Warnings
- Toast kind `warn` (amber triangle), for example "Not found in E:\Archive\GA\" with sub "The item stays greyed out until the file is found."
- Inline `note` boxes in dialogs (pane-header background, 1 px border, 16 px icon) and a red note for CSV with only one column.
- Disabled "later" items carry an italic tooltip line "Later: planned for a later version".
- Software rendering amber text in the status bar.

### 8.4 Undo and redo
- Every data change goes through `doChange(label, redo, undo)` (line 1233): runs redo, pushes to `S.undo`, clears `S.redo`, emits `undo`.
- Undo (Ctrl+Z) and Redo (Ctrl+Y or Ctrl+Shift+Z) are QAT buttons. The tooltip says "Undo <label>" or "Redo <label>". Buttons are disabled (greyed) when the stack is empty.
- Toast "Undone: <label>" / "Redone: <label>" for 2.2 s. "Nothing to undo" when empty.
- Undoable: layer visibility, reorder, opacity, line selection checkboxes, rename, channel create/delete/edit, cell edits, coordinate system set, reproject, current pair, line properties, protect, imports (removes the item and layer), etc.
- Data is written at once and is always saved; Save only stores views and layer lists (tooltip of Save Project, line 1310). Views autosave every N minutes (default 5).
- Undo and redo keys are ignored while typing in a text field (line 4337).

### 8.5 Status bar (`renderStatus`, line 1981; `updateStatus`, line 2004)
Left to right:
1. Map coordinate system label (button, opens CRS picker for the current map; toast says other layers are reprojected on the fly).
2. Separator.
3. Pointer position "X 384,120.5   Y 7,914,010.2" (mono), or "X -   Y -".
4. Separator.
5. Current point: "L1012  fid 12345.0" (button, centres the map on it).
6. Separator.
7. Value readout text from the map pointer (dim until there is a value; "Move the pointer over the map to read values" when the Point Readout tool is on).
8. Right side (`margin-left:auto`): "Selected lines: 12 of 60", separator, jobs text ("No jobs running" or spinner + "N jobs running" in accent; click opens Jobs tab), separator, render mode "GPU" (accent text) or "Software" (amber), mono 11 px.
All have tooltips.

## 9. Keyboard shortcuts

Global handler `bindGlobal` (line 4319):
- Ctrl+K: command search (works even in dialogs).
- Esc: closes the topmost of: open menu, command search, dialog, backstage, ribbon peek.
- Ctrl+F1: collapse or expand ribbon.
- Ctrl+Shift+L: switch light and dark.
- Ctrl+S save, Ctrl+N new project, Ctrl+O open project.
- Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo (not while typing in text).
- Alt+Left and Alt+Right: previous and next line.
- Ignored while a dialog or the palette is open (except Ctrl+K and Esc).
Per view and pane:
- Data tree: Up, Down, Left, Right, Enter, Menu key, Shift+F10.
- Database view (line 3110): Up, Down, Page Up, Page Down move the current row; Ctrl+Home and Ctrl+End jump; Left and Right change the current channel (column); Enter or F2 edits the cell; in the editor Esc cancels, Enter or Tab commits (Enter moves to the next row).
- Profile view (line 3327): Left and Right move the current point; Shift for 10 samples. Wheel zooms along the line, drag pans, double-click resets, click sets the current point.
- Map view: Arrows pan, + and - zoom, Home full extent; drag pans, wheel zooms, double-click zooms in 2x, click sets the current point.
- Combo: Up and Down change the value without opening. Menus: Up, Down, Esc.
- Palette: Up, Down, Enter, Esc.
Help > Keyboard Shortcuts (line 4258) lists: Ctrl+K, Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z, Ctrl+S, Ctrl+F1, Ctrl+Shift+L, Alt+Left/Right, row keys, Enter or F2, profile keys, map keys, Esc. (Ctrl+N and Ctrl+O exist in code and in tooltips but are not in that table.)
Commands carry a `key` string shown in tooltips, menus and command search.

## 10. Views and the central area

Views are "documents" (`DOC`, line 2509). Three kinds:
- `map`: one per map. Canvas with pan and zoom, nav buttons (zoom in, zoom out, full extent, go to cursor; 26 x 26 at top right), scale bar bottom left, colour legends bottom right (228 px cards), optional hint at top left.
- `db`: Database view, a virtual-scrolled spreadsheet of one line at a time. Has a 34 px toolbar (Line combo 104 px, prev/next, info text "rows, fid range, step, flight, date, length", then icon buttons for Statistics, Search and replace, Channel math...), a header row (36 px, channel name + units, click to pick current channel), 22 px rows, striped, current row highlighted, edited cells have an amber corner mark, marked rows have an amber left bar, protected channels shown with lock icons, missing values in grey italic.
- `profile`: Profile view, stacked panes of channels along the current line on canvas. Toolbar: Line combo, prev/next, checkboxes "Previous line (L1011)" and "Next line (L1013)", horizontal axis segmented (Northing or Easting | Fiducial), and a "Panes" menu (choose channels per pane, add and remove panes). Default panes: MAG_IGRF; MAG with IGRF; ALT.
- Statistics is not a document. It is a right-pane tab (section 4.4).

Tabs and groups:
- The central area holds one or two groups. Each group has its own 34 px tab strip: tabs with a 16 px kind icon (map, table, profile), a name (min width 72 px, truncated), and a close x. Tab names: map name, database name, "Profile: <database>".
- Opening an already open view just activates its tab. Opening a new one adds a tab to the focused group (`openDoc`, line 2518).
- Split: two groups side by side (`v`) or one over the other (`h`), with a draggable splitter; fraction 0.18..0.82, default 0.6. Controlled by icon buttons at the right of each tab strip (side by side, one over the other, single view) and by the ribbon "Split View" menu. Split needs at least two open views, otherwise a toast says so.
- Tab context menu: Move to the Other Side (or Split Off), Close, Close Others, and more. Middle click closes.
- Clicking a group focuses it. Focusing a map sets the active map (the Layers tab and status bar follow). Title bar shows the focused view.
- Empty group: "No view is open. Double-click an item in the Data pane to open it."
- Start layout (`init`, line 4361): group 1 has Map 1 (active) and the Kangaroo Hills database; group 2 has the Profile view; split is "one over the other" (`DOC.dir = 'h'`), focus group 1; Statistics pane is open at the right.
- Shared cursor (`S.cur = {db, line, i}`, `setCursor`, line 2486): one current point shared by all views; the `view.sync` toggle controls whether views follow it. Changing it emits `cursor` and updates tree highlight, views and the status bar.
- Pub-sub: `on(topic, fn)` and `emit(topic)` (line 937) connect state to views. Topics seen: undo, jobs, items, layers, layers-live, style, selection, channels, lines, crs, data, cursor, theme, resize, curchan.
- Layers belong to the active map; the Layers tab shows that map only.

## Notes for the CImGui port

- Everything is plain data plus small renderers. Tool descriptions drive: ribbon button, dialog, palette entry, Tools pane row, script call. This is the core design to keep.
- Things ImGui must emulate: ribbon with groups and 70 px big buttons, split buttons, tabs with accent underline, tree rows with inset hover, virtual-scroll spreadsheet (use ImGuiListClipper), floating draggable modal dialogs, toasts, tooltip delay (480 ms), command palette overlay, pane splitters, docked/split central groups (ImGui docking can replace the custom DOC groups), a colour theme switch (swap the token table).
- The prototype is HTML-only for the pointer details such as the 2 px accent underline and 5 px inset hover. These can be drawn with the ImGui draw list.
- Real jobs need a worker task, progress, cancel, and a log. Simulated here.
- `replaceOld` on rerun is not implemented in the prototype (see 6.5).
- `--context` and `--context-tint` tokens are defined but unused.

## Summary (15 lines)

1. Shell: 34 px title bar, 32 px tab strip (purple "Project" button first), 102 px ribbon, left pane 272 px, center, optional right pane 300 px, 26 px status bar.
2. Tokens: about 30 CSS variables with a light and a dark set (full table in section 2.1); accent #2563EB, Julia purple #7D4A9B for the brand.
3. Fonts: Segoe UI family 12.5 px body, Cascadia Mono for code and ids; icons are 24-grid strokes with accent fills.
4. Ribbon tabs: Database, Database Tools, Coordinates, Grid and Image, Map, (planned) Magnetics, then fixed Settings and Help; many buttons are greyed "later" placeholders.
5. Ribbon is built from command `at` placements: big, small (3 per column), split, menu and custom kinds; Database tab starts with an "Acts on" database combo.
6. Project backstage is a full-window page with a purple nav: Start, New, Open, Save, Save As, Project Settings, Run Script, About.
7. Left pane has Data (tree of Databases > Lines/Channels, Grids, Maps, plus Properties and a filter), Layers (reorderable, opacity) and Jobs (cards with progress, Cancel, Report, Run Again, running-count badge).
8. Command search (Ctrl+K) is a 560 px overlay with scored matching on name, id and location; Up, Down, Enter, Esc.
9. Tool dialogs are generated from one data description (id, inputs, settings with types, advanced flag, job or quick, validate); footer has Reset to Defaults, Tool Description, Cancel, Run.
10. The same description yields the Julia `tool(...)` shape and a `run_tool("id"; ...)` script call, shown in the "Tool Description" box and used for the script page.
11. Settings are remembered per tool; "Add to current map" is a normal bool setting; rerun adds "Replace the old output" (only logged in the prototype, not implemented).
12. Import dialogs: XYZ and grid use the standard dialog with a file preview; CSV uses a three-step wizard (layout, column roles, lines and coordinates) with templates.
13. Feedback: bottom-right toasts (ok, info, warn, error, with action buttons), inline red field errors, failed-job cards plus report dialog, confirm boxes; every change is undoable (QAT Undo and Redo, Ctrl+Z, Ctrl+Y).
14. Status bar: map CRS, pointer X/Y, current line and fiducial, value readout, selected lines, jobs, GPU or Software.
15. Central area: tabs of Map, Database and Profile views in one or two groups (side by side or stacked) with one shared cursor linking all views.
