# JuliaMag: foundation design

Date: 2026-10-28
Status: draft for review

## 1. What this is

JuliaMag is a desktop app for processing airborne magnetic survey data.
It aims at the kind of work people do in Oasis montaj.
It is written in Julia.

The user likes how RustGIS feels to use (the Rust project next to this folder).
JuliaMag should feel the same way, but its tools are geophysics tools, not GIS tools.
RustGIS is a model for the feel and the structure, not code to port.
RustGIS has no geophysics code.

Oasis montaj is the model for the functions.
It is fitted into the RustGIS structure, not copied 1:1.
The user's framing: RustGIS is like QGIS, written in Rust.
So where Oasis and a modern GIS disagree on structure, JuliaMag follows the GIS way and keeps the Oasis function.

### 1.1 Sources and research

This design is based on research done on 2026-10-28.
Go back to these sources whenever a decision needs more context, or when a new tab or tool is designed.

**Oasis montaj help (the model for the functions)**

- Version: Oasis montaj 2025.1 online help.
- Base URL: <https://help.seequent.com/Oasismontaj/2025.1/Content/>
- The menu trees come from the help's own table of contents, `Data/Tocs/geohelp.js` under the base URL, section "Context Help", one node per menu.
  The "Oasis montaj menus" page does not list the menu items.
- Start pages used:
  - [Project Explorer](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/projects_databases/about_the_project_explorer.htm) (given by the user)
  - [Oasis montaj menus](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/context_help/intro_to_om/oasis_montaj_menus.htm)
  - [About grids and images](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/gridding_3d_models/about_grids_and_images.htm)
  - [Oasis montaj maps](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/maps_groups_coordinate_systems/oasis_montaj_maps.htm)
  - Command pages under [gxhelp](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/)

**Research notes (in this repo, `docs/research/`)**

Each note has the full menu tree, each command with its help link, how the commands work together, a proposed place in JuliaMag, and open questions.

| Oasis menu | Research note | Used in this design |
|---|---|---|
| Project | [`oasis-project.md`](../../research/oasis-project.md) | 5.1, 5.2, 8.2, 9.1, 9.5, 9.6 |
| Database | [`oasis-database.md`](../../research/oasis-database.md) | 5.3, 6.3, 6.4, 6.5, 7, 9.1, 9.3 |
| Database Tools | [`oasis-database-tools.md`](../../research/oasis-database-tools.md) | 5.3, 8.1, 8.2, 9.1, 9.3, 9.4 |
| Coordinates | [`oasis-coordinates.md`](../../research/oasis-coordinates.md) | 5.3, 6.6, 9.1 |
| Grid and Image | [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md) | 5.4, 6.7, 7, 8.1, 8.2, 8.5, 9.1, 9.3 |
| Map | [`oasis-map.md`](../../research/oasis-map.md) | 5.5, 7, 8.2, 9.1, 9.2, 9.3 |

Some functions of the mag chain sit outside these six menus.
The notes describe them where they were found:

- Tie-line levelling, microlevelling and IGRF: Oasis Geophysics and Geophysics Levelling menus, see `oasis-database-tools.md` section 3.
- FFT filters and RTP: the 2D Filtering (MAGMAP) extension, see `oasis-grid-and-image.md`.
- Map Tools (drawing paths, contours, symbols): not researched yet, see `oasis-map.md` open questions.

**RustGIS (the model for the feel and structure)**

Next to this repo, at `../RustGIS`:

- `docs/architecture.md`: layers, "everything is a command", "never crash".
- `crates/ui-egui/src/ribbon.rs`: ribbon tabs and groups.
- `crates/ui-egui/src/theme.rs`: colour tokens, light and dark.
- `docs/user-guide/maps.md` and `docs/user-guide/layouts.md`: the map and layout split.

**UI prototype (the agreed look and structure)**

- `prototype/juliamag-ui.html`: an interactive HTML prototype of the whole first-version UI, with fake data.
- The user approved it on 2026-10-28: "the way it is structured is exactly what we are going for".
- It is the reference for layout, sizes, colours, ribbon contents, panes, dialogs and how the views link.
  The Julia app should match it.
  Where this document and the prototype disagree, raise it with the user.
- Its tool descriptions (plain data that builds ribbon buttons and dialogs) show the intended shape of the tool system in section 8.
- Its brand colour is Julia purple instead of RustGIS orange.

**Keeping this up to date**

- When a later tab is designed (Map Tools, 3D View, Voxel and so on), research it the same way and add a note `docs/research/oasis-<menu>.md` in the same format.
- Add the note to the table above.
- Each section below names the note it is based on, in a "Research:" line.

## 2. Why

- Julia is easier for scientific math.
- Julia makes it quick to try and change processing algorithms.
- Julia code is easier for the user to maintain than Rust.

## 3. The work it serves

The user's normal chain for airborne magnetic line data is:

1. Import
2. Lag correction
3. Levelling
4. IGRF removal
5. Gridding
6. Reduction to pole (RTP)
7. Maps

This first version builds the foundation for that chain.
It does not build the processing steps themselves.
But the data model and the tool system must already fit every step in the chain, so no step later forces a change of the stored format.

## 4. Goals for the first version

The user named two things that must be done really well:

1. **Import.**
2. **A tab and tool system** where new tools can be added to tabs later.

## 5. Data model

The data model is the part that is costly to change later.
It is set now with the whole chain in mind.

### 5.1 Project

Research: [`oasis-project.md`](../../research/oasis-project.md).

- A project is a folder.
  It holds a small text file listing the items and their settings, and one folder of data files per item.
- All paths inside the project are relative, so a project folder can be moved or copied.
- Item types in the first version: **line database**, **grid**, **map**.
- Item type planned for later, with room left in the model: **vector** (polygons, lines and points from Shapefile, KML, and so on).
  It is needed later for area masks, outlines and overlays.
- An item whose data files are missing shows as missing (greyed) with a "Find" action.
  The project still opens.

### 5.2 Saving

Research: [`oasis-project.md`](../../research/oasis-project.md), [`oasis-database.md`](../../research/oasis-database.md).

Claude's call: data is written at once, and every change can be undone.
There is no Oasis-style "unsaved changes / discard" state for data.
This is how RustGIS works, and it is safer with large files: a crash never loses an import.
Project-level settings (open views, layer lists) are saved with a normal Save, with autosave, as in RustGIS.

### 5.3 Line database

Research: [`oasis-database.md`](../../research/oasis-database.md), [`oasis-database-tools.md`](../../research/oasis-database-tools.md), [`oasis-coordinates.md`](../../research/oasis-coordinates.md).

**Lines.**
Each line has:

- a type, with its Oasis letter: Line `L`, Tie `T`, Base `B`, Test `S`, Trend `R`, Special `P`, Random `D`
- a number and a version; type, number and version together are unique
- a flight number and a date
- a fiducial start and step (its sampling)
- a "selected" flag

**Sampling.**
Claude's call: one sampling (fiducial start and step) per line, shared by all its channels.
Oasis allows a separate start and step per channel.
That leads to misaligned ("red bar") channels and needs repair tools.
JuliaMag keeps one sampling per line.
A tool that changes the sampling writes a new database, or resamples onto the line's sampling.
Lag correction shifts the data and resamples it onto the same sampling.

**Channels.**
Each channel has:

- a name and a label (the label keeps the original name from the file)
- a data type: float 32 or 64, integer types, string
- units
- a role, when it has one: x, y, z, time, date, longitude, latitude, elevation, mask, line
  Tool settings use roles to pick sensible default channels.
- display format, width and decimals
- a "protected" flag; imported channels start protected, so they are not changed by mistake
- a missing value (dummy): NaN for floats, a fixed value for each integer type, empty for strings
- array channels (several values per sample) are allowed by the format

**Storage.**
One file per channel per database, column by column, memory-mapped.
A new channel is a new file.
Changing a channel rewrites only that channel's file.
Views read only the part on screen.

**Positions and coordinate systems.**
- A coordinate system belongs to a pair of channels (x, y), not to the database.
- A database can hold several position pairs, for example longitude/latitude and UTM easting/northing.
- One pair is marked "current".
  Every tool uses the current pair for positions, unless told otherwise.
- Coordinate systems pass downstream: a grid made from a database gets the current pair's coordinate system, and a map gets it from its first item.

**Selection and cursor.**
These are shared app state, built in now because adding them later is costly:

- The set of selected lines.
- A marked range (a stretch of fiducials on one line).
- The current point (line and fiducial).
  It shows in every open view: a highlighted row in the database view, a marker in the profile view, and a marker on each map ("shadow cursor" in Oasis).

Every tool that works on lines has a standard "which lines" setting: all, selected, or current line.

### 5.4 Grid

Research: [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md).

Each grid stores:

- size, cell size, origin, rotation, and whether values sit on cell corners or centres
- coordinate system
- value type and missing value
- where it came from (file, format, compression) and which job made it
- stored trend coefficients, when a tool removed a trend (FFT filters need this later)
- a default colour style

Values are stored as a raw array, memory-mapped.

Claude's call on colour: the grid has a default colour style.
A map layer uses that style unless the layer sets its own.
This keeps Oasis's "the grid remembers its colours" and still lets one grid look different on two maps.

### 5.5 Map

Research: [`oasis-map.md`](../../research/oasis-map.md).

An Oasis map is two things in one file: a data view in ground coordinates and a page in paper coordinates.
JuliaMag splits them the RustGIS way:

- **Map:** an interactive view in ground coordinates with a layer list.
  Making one asks for nothing: no template, no scale, no data range.
- **Layout** (later): a printable page with map frames, title block, legend, scale bar.
  One map can feed several layouts.

Each map's layer list holds which items are drawn, their order, visibility and opacity.
Folders in the layer list come later.

## 6. Import

### 6.1 Formats

Research: [`oasis-database.md`](../../research/oasis-database.md), [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md), [`oasis-map.md`](../../research/oasis-map.md).

| Data | Formats in the first version |
|---|---|
| Line data | Geosoft XYZ, CSV and other delimited or fixed-width text |
| Grids | Geosoft `.grd`, ER Mapper `.ers` |

Later: ASEG-GDF2, Geosoft binary (GBN), Oasis import templates (`.i0`, `.i3`), Shapefile and KML into vector items.

### 6.2 Speed and safety

- Typical files are around 500 MB and a few million rows.
  Some are much larger.
  Design for several GB.
- Files are read in a stream, in chunks.
  A whole file is never loaded into memory at once.
- Import runs as a background job with progress and cancel.
  The app stays usable while it runs.
- Bad lines, odd headers and broken values give a clear warning with the line number.
  They never crash the app.
- A file is imported once into the project's own format.
  Opening the project again is near instant.

### 6.3 Geosoft XYZ

Research: [`oasis-database.md`](../../research/oasis-database.md).

The reader must handle:

- `/` comment lines.
  The channel names come from the last `/` line whose number of names equals the number of columns.
- Line headers: `Line`, `Tie`, `Base`, `Test`, `Trend`, `Random`, and their short forms, with number and optional version.
- `//Flight` and `//Date` lines, anywhere in the file; they apply to the lines that follow.
- `*` as the missing value, matched as text.
- A column named `FIDUCIAL` sets the line's fiducial start and step.
- A file with no line headers goes into one line.

### 6.4 CSV and other text

Research: [`oasis-database.md`](../../research/oasis-database.md).

A three-step dialog, like the Oasis ASCII wizard:

1. File layout: delimited or fixed width, delimiter, heading row, units row, first data row.
   A preview of the first rows.
2. Column roles: skip, data, line, fiducial, array.
   Each column's name, type and units.
3. Lines and coordinates: split into lines by a line column, or one line per file.
   Coordinate system of the position pair.

The settings can be saved as a named import template and reused for files with the same layout.

### 6.5 Import into an existing database

Research: [`oasis-database.md`](../../research/oasis-database.md).

Claude's call: the first version supports two modes.

- **New database** (the default).
- **Append:** add the file's lines to an existing database, for example a new flight.
  A line that already exists gets a new version.

Merge modes (merge channels onto existing lines by fiducial) come later.

### 6.6 Coordinate system on import

Research: [`oasis-coordinates.md`](../../research/oasis-coordinates.md).

- The user sets the coordinate system of the position pair, with a guess shown.
- For longitude/latitude data, the guess includes the UTM zone that covers most of the data (Oasis "Determine UTM Zone").
- One shared coordinate system picker is used everywhere: EPSG search, favourites, recent, and custom definitions.
  RustGIS's coordinate system dialog is a good model.

### 6.7 Grid formats

Research: [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md).

- **ER Mapper `.ers`:** read with GDAL.
- **Geosoft `.grd`:** its own reader, since GDAL does not read it.
  Oasis saves new grids compressed by default, so most user files are compressed.
  The reader handles uncompressed and compressed grids.
  The coordinate system and colour state sit in a side file (`.grd.gi`); read the coordinate system from it when present.
  The Oasis help does not describe the binary layout.
  The builder must find Geosoft's published grid format specification, and test against public `.grd` files.
  This is the biggest risk in the import work.
- A `.grd` file may be a Surfer grid.
  The reader checks the header, reads Surfer grids too, and tells the user which format it found.

## 7. Export

Research: [`oasis-database.md`](../../research/oasis-database.md), [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md), [`oasis-map.md`](../../research/oasis-map.md), [`oasis-project.md`](../../research/oasis-project.md).

Export goes through pluggable exporters, one per format, registered like tools.
Oasis montaj does not need to read the project itself.

| Data | Formats in the first version |
|---|---|
| Line data | Geosoft XYZ, CSV, Parquet |
| Grids | Geosoft `.grd` (uncompressed first), ER Mapper `.ers`, GeoTIFF |

Every exporter has a "which lines" and "which channels" setting where it fits.
Later: compressed `.grd`, ASEG-GDF2, map image (GeoTIFF or PNG with one pixel per grid cell), layout export (PDF, SVG, PNG), OMF for Leapfrog.

## 8. Tab and tool system

This is the core of the app.
Every later step in the chain will be added as a tool in this system.

### 8.1 What a tool is

Research: [`oasis-database-tools.md`](../../research/oasis-database-tools.md), [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md).

A tool is one Julia function plus a description:

- id, name, help text, icon
- one or more places in the ribbon (tab and group); Oasis repeats some commands in up to three menus, so one tool can appear in several places
- inputs (for example "a line database" or "a grid") and outputs
- settings, each with a type, default and limits
- whether it is quick or runs as a background job

Setting types the system must support, from the research:

- numbers, text, choices, on/off, file paths
- a channel of an input database, with a filter (by role, type, or array/not array)
- which lines (all, selected, current)
- a coordinate system (opens the shared picker)
- an extent or a point picked on the map
- "blank means auto": a default worked out from the data when the dialog opens, for example a grid cell size
- an "Advanced" section that is closed by default

From the description, the app builds by itself:

- the ribbon button
- the settings dialog
- the command id, used by command search, keyboard shortcuts and scripts
- the script entry

Adding a tool means writing the function and its description.
No UI code.

### 8.2 Behaviour shared by all tools

Research: [`oasis-project.md`](../../research/oasis-project.md), [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md), [`oasis-database-tools.md`](../../research/oasis-database-tools.md), [`oasis-map.md`](../../research/oasis-map.md).

- **Remembered settings.**
  A dialog opens with the settings from the last run of that tool in this project.
  A "Reset to defaults" button sets them back.
- **Safety wrapper.**
  An error in a tool is shown to the user and never takes down the app.
- **Job report.**
  Each run can write a text report (Oasis writes logs like `bigrid.log`).
  The report is kept with the job.
- **Outputs.**
  New items are added to the project, and to the current map if the user ticks "add to current map".
  This replaces Oasis's "new map or current map" question in each tool.
- **Batch runs** (later): run one tool over a list of inputs, for example grid several channels at once.
- **Preview** (later, but the description has a slot for it): a live preview while settings change, for gridding and filters.
- **Pause for review** (later): a job can stop and wait for the user, for example between levelling rounds.
  A guided task pane, like RustGIS's Tasks pane, fits multi-step work such as levelling.

### 8.3 Tools from other packages

- Right now the user adds tools.
  Later, colleagues add their own tools without editing the app's core code.
- Tools can live in a separate Julia package and register themselves when loaded.
- The app loads such packages while it runs (see section 13, Packaging).
- A package that fails to load is shown as failed in a list and never stops the app.

### 8.4 Importers and exporters

Importers and exporters use the same idea.
Each one is a small unit for one file type, registered the same way.
New formats are added without touching the core.

### 8.5 Jobs

Research: [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md), [`oasis-project.md`](../../research/oasis-project.md).

- Long tools run as background jobs.
- A **Jobs** tab lists them, newest first.
  - Status: running, done, failed, with a count of running jobs on the tab.
  - Cancel a running job.
  - Run a finished or cancelled job again, with changed settings if wanted.
  - Outputs are added to the project by themselves.
- Jobs are saved with the project.
  Each output item records the job (tool id and settings) that made it.
- The Jobs list and the script history are built from the same records.
- Running a job again makes a new item by default.
  The dialog offers "replace the old output" as an option.
- Clearing the visible history never removes the record of how an existing item was made.

## 9. Ribbon, panes and views

### 9.1 Ribbon tabs

Research: [`oasis-project.md`](../../research/oasis-project.md), [`oasis-database.md`](../../research/oasis-database.md), [`oasis-database-tools.md`](../../research/oasis-database-tools.md), [`oasis-coordinates.md`](../../research/oasis-coordinates.md), [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md), [`oasis-map.md`](../../research/oasis-map.md).

The user gave this list of tab headers, taken from the Oasis montaj menus, and said the top ones matter most for now:

Project, Database, Database Tools, Coordinates, Grid and Image, Map, Map Tools, ArcGIS Tools, Section Tools, 3D View, Voxel, Geosurface, Data Services.

From the research, the ribbon in the first version is:

| Tab | What goes in it |
|---|---|
| **Project** button | Not a tab. Opens a full-window "backstage" page, as in RustGIS: new, open, save, recent projects, project settings, about. The Oasis Project menu holds no geophysics, only file and app functions. |
| **Database** | Import, Export, Lines (select, line type, properties), Channels (new, delete, copy, properties, set current x/y), View (database, profile). A chooser at the left edge sets which database the tab acts on. |
| **Database Tools** | Channel Math, Statistics, Split into lines, Search and replace, Interpolate gaps. Later: filters, resampling, line tools. |
| **Coordinates** | Set coordinate system (metadata only), Reproject to a new pair, Set current pair, Guess UTM zone. Later: interpolate X/Y gaps, warps. |
| **Grid and Image** | Import, Export, Grid properties, Colour style. Later: Grid Data (gridding), grid utilities, grid filters. |
| **Map** | New Map, Add Item, Navigate, Bookmarks, Point readout, Layer style. Later: Layouts. |
| **Settings** and **Help** | Fixed tabs at the right, as in RustGIS. |

Later tabs, added by tools when they exist:

- **Magnetics:** lag correction, heading correction, base station correction, IGRF, tie-line levelling, microlevelling, RTP and other FFT filters.
  In Oasis these are spread over Database Tools, the Geophysics and Geophysics Levelling menus, and the 2D Filtering (MAGMAP) extension.
  JuliaMag groups them by the job they do.
- **Filters** group (on Database Tools and Grid and Image): despike, non-linear, low/high/band pass, convolution, rolling statistics.
  For grid filters, FFT or convolution is a setting of the filter, not a separate menu.
- **Map Tools, 3D View, Voxel, Geosurface, Section Tools, Data Services, ArcGIS Tools** as their tools are written.

The tab list is data, not code.
A tab exists once a tool or a built-in command names it.
Empty tabs are not shown.
The user can hide tabs, as RustGIS's ribbon settings allow.
Later, a user tab file can list tool ids by group, like Oasis custom menu files.

Less-used tools are found through command search (Ctrl+K) and a searchable **Tools** pane, like RustGIS's geoprocessing pane, so the ribbon stays clean.

### 9.2 Side pane (Project Explorer)

Research: [`oasis-map.md`](../../research/oasis-map.md), [`oasis-project.md`](../../research/oasis-project.md).

From the Oasis Project Explorer, fitted into the RustGIS side pane:

- **Data tab:** the project's items by type: line databases, grids, maps (later vectors, 3D views, voxels).
  - Open, create, rename, remove items.
  - Properties, metadata and a free-text description (Oasis "Map Comments" and "Data Description").
  - Right-click on a folder acts on many items at once.
- **Layers tab:** the layer list of the current map.
- **Jobs tab:** see section 8.5.

### 9.3 Views in the first version

Research: [`oasis-database.md`](../../research/oasis-database.md), [`oasis-database-tools.md`](../../research/oasis-database-tools.md), [`oasis-grid-and-image.md`](../../research/oasis-grid-and-image.md), [`oasis-map.md`](../../research/oasis-map.md).

These views exist so the user can check an import by eye.
They are linked through the shared selection and cursor (section 5.3).

- **Map view:**
  - Line paths in plan, coloured by a chosen channel.
  - Grids with a colour style: linear stretch and histogram equalization, colour tables, and hillshade with sun angles.
    RustGIS's raster styles (stretch, shaded relief, blend) are the model.
  - Pan and zoom stay smooth with millions of points.
    Zoomed out it draws a thinned version; zoomed in, full detail.
  - Point readout: the value of every visible grid and the nearest line point under the cursor, in the status bar.
  - Bookmarks (Oasis "Snapshots"): later.
- **Database view:** a spreadsheet of one line at a time, like the Oasis database window.
  - It scrolls smoothly through millions of rows by reading only the rows on screen.
  - The user decided that cells can be edited by hand, for example to fix a spike.
    Each edit can be undone and is recorded in the script history.
  - Right-click menus for cell, column and line actions.
  - Search and replace, copy channel.
  - The column layout can be saved and restored.
- **Profile view:** chosen channels plotted along the current line.
  - Several panes stacked, each with its own channels.
  - A pane can also show the previous or next line, to compare.
  - Oasis users check lag and noise this way.
- **Statistics pane:** count, min, max, mean, standard deviation and a histogram for a channel or grid.
  It replaces several Oasis report tools.

### 9.4 Channel Math

Research: [`oasis-database-tools.md`](../../research/oasis-database-tools.md), [`oasis-project.md`](../../research/oasis-project.md).

Channel Math is in the first version, because it is cheap and high value.
The user writes a Julia expression over channel names, for example `MAG_IGRF = MAG - IGRF`.
It writes a new or existing channel.
Missing values pass through.
Later, IGRF removal is one use of it, before a dedicated tool exists.

### 9.5 Scripts

Research: [`oasis-project.md`](../../research/oasis-project.md).

Oasis has Run GX, Run Script, Record Script and a project log.
In JuliaMag:

- Every action is a command with an id, as in RustGIS.
- The app keeps a history of the commands run, with their settings.
  This is the job records of section 8.5 plus quick actions such as cell edits.
- History can be saved as a plain Julia script that can be run again or edited.
  There is no separate record mode.
- Scripts can be run from inside the app (Run Script on the Project backstage and in command search), and from the Julia REPL.
- The core works without the UI.
  The user can load it in the REPL or a notebook and call the same tools.

### 9.6 Settings

Research: [`oasis-project.md`](../../research/oasis-project.md).

First version:

- Temp folder (large jobs can need gigabytes, so it must be valid and have room).
- Default distance units.
- Default colour table for grids.
- Open the last project at start.
- Light or dark theme.
- Software rendering fallback, for Windows laptops with weak graphics drivers.

## 10. How it should feel

The user likes how RustGIS feels to use.
From the RustGIS code, that means:

- A ribbon with tabs in the order of the work.
- Side panes, a large central view, and a status bar.
- Light and dark themes from a set of colour tokens.
  Widgets never hard-code colours.
  RustGIS's tokens (`crates/ui-egui/src/theme.rs`) are a good starting point.
- Command search (Ctrl+K) and keyboard shortcuts.
- Undo for every change.
- Fast, smooth response.
  The UI never freezes while work runs.

## 11. Non-goals for the first version

- The processing steps: lag, heading and base station corrections, levelling, IGRF, gridding, filters, RTP.
- Layouts and printing.
- Vector items (Shapefile, KML).
- 3D views, voxels, gravity, sections.
- A plugin registry or installer (tool packages are loaded from folders only).
- Basemaps and web data.
- AI assistant, web version, translations.
- Reading or writing Oasis `.gdb` databases, `.gpf` projects or `.map` files.
- Oasis-only items with no use here: database sizing and maintenance (Grow, Defragment), ODBC, old instrument formats, plotter set-ups, Seequent Central, control-file gridding, Backup/Restore X,Y (undo covers it), Design Survey.

## 12. Anti-goals

The user named these as what would make the tool a failure:

- **Slow imports.**
- **Crashing on large files.**

Also, following from the above:

- The UI freezing while a job runs.
- Losing data after a crash.

## 13. Constraints and Claude's calls

### 13.1 Constraints

- Language: Julia.
- Platforms: mostly Windows, some Linux.
- Must start fast on Windows.
- Must handle files of several GB without running out of memory.

### 13.2 Decisions the user made

- The base app is prebuilt, and it can load extra tool code while it runs.
- Cells in the database view can be edited by hand.
- No sample files are supplied; readers follow the format documentation and public data.
- The ribbon follows the user's list of Oasis tab headers, top ones first.

### 13.3 Claude's calls (the user handed library choices over)

These are open to change.

- **UI: CImGui.jl** (Dear ImGui).
  It redraws every frame on the GPU, like egui in RustGIS, so it should feel the closest.
- **Plots and maps: Makie** (GLMakie), shown inside the ImGui windows.
  If Makie cannot draw millions of points smoothly inside ImGui, the builder may draw the map view with its own OpenGL code instead.
- **Packaging:** PackageCompiler.jl builds the base into a prebuilt image.
  The app ships with the Julia runtime and a package environment.
  At start, it loads extra tool packages from a plugins folder and from the user's own tool folder.
  The user can reload a changed tool without restarting (Revise.jl, when present).
- **Storage:** one raw memory-mapped file per channel and per grid, plus JSON metadata and a JSON project file.
  Raw files were chosen over Apache Arrow during planning, because cells must be edited in place and Arrow files are read-only when memory-mapped.
  Parquet stays an export format.
- **Code layout:** the core (data model, project, import, export, tool registry, jobs) has no UI dependency.
  The UI sits on top.
  This mirrors RustGIS's layer rule, keeps the core scriptable, and lets tools be tested without the UI.
- **Coordinate systems:** Proj.jl.
- **Grid input:** GDAL (ArchGDAL.jl) for `.ers` and GeoTIFF; own reader for Geosoft and Surfer `.grd`.
- **Jobs** run on Julia worker threads.
  The UI stays on the main thread.
  Jobs report progress and check a cancel flag.
- Calls taken from the research, explained in their sections:
  - data is written at once, with undo (5.2)
  - one sampling per line (5.3)
  - grid default colour with per-layer override (5.4)
  - map and layout split (5.5)
  - New and Append import modes (6.5)
  - Project as a backstage page, not a tab (9.1)
  - Magnetics tab for the chain, later (9.1)

### 13.4 Calls made while building the UI prototype

These came up while building the prototype and are Claude's calls:

- Changing which lines are selected is saved with the project and can be undone.
- Undoing an import removes the new item.
  The job record stays in the Jobs list, marked as undone.
- When a database's current pair is longitude/latitude, the map reprojects it on the fly to the map's coordinate system.
- Grid styling on the Map tab (for example the hillshade toggle) changes the current layer's style.
  "Save as grid default" makes it the grid's default style (section 5.4).
- Set Current X,Y appears in Coordinates and in Database > Channels, and also in a channel pair's properties.
- Statistics is a pane.
  The Statistics command opens it.
- The Data tab tree shows lines and channels under each database, so the user can select lines and see protected channels.
- Settings and Help are pinned at the right end of the tab strip.

## 14. How we check it

- A test set of survey files, including large and messy ones.
  The user did not provide files.
  Test files come from public airborne survey releases (for example USGS and Geoscience Australia publish Geosoft XYZ and `.grd` data), plus generated broken and very large files.
- Import speed and memory use are measured and tracked, so slowdowns are noticed.
- A first target is set after a first measurement.
  The starting guess is that a 500 MB XYZ file imports in well under a minute on a normal laptop.
- Tests for every importer and exporter, including broken files.
- Round trip tests: import, export, import again, and compare.
- The UI is checked by eye in light and dark themes.
- Lint and test failures are fixed, not ignored.

## 15. Left to the builder

- Exact package and module structure.
- Exact tool description format (macro, struct, or both).
- Icons and exact ribbon groups inside each tab.
- The order exporters are built in.
- How the map view thins points when zoomed out.
- Exact command ids.
