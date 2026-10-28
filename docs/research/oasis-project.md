# Oasis montaj Project menu: research for JuliaMag

Date: 2026-10-28
Source: Oasis montaj 2025.1 online help.
Base URL for all help links below: `https://help.seequent.com/Oasismontaj/2025.1/Content/`.
Links are written relative to that base.

How this was researched:

- The help has no single "Project menu" page.
- The help table of contents has a "Context Help > Project" section that lists one page per Project menu command.
  That section is the main source for the menu tree below.
- Each command page was read, plus the Project Explorer page, the Work with Projects page, the scripting pages, and the Project Explorer context menu pages.
- The order of items below follows the help contents.
  The real order in the Oasis menu may differ.
  I could not see the live menu.

## 1. Overview

The Project menu is the "file and app" menu of Oasis montaj.
It holds almost no geophysics.
It does four kinds of work:

1. **Project files:** create, open, save, close the project (`*.gpf`).
2. **Sharing and output:** Seequent Central sync, export to OMF, and printing.
3. **Settings and set-up:** which menus are loaded, global settings, language, text editor, project comments.
4. **Automation:** run a GX (a compiled Oasis tool), run and record scripts, the processing log, and a set of small script commands (create channel, delete line, math expression, and so on).

A project in Oasis is a workspace file.
It lists the data files (databases, grids, maps, 3D views and more), the open windows, the loaded menus, and the last-used settings of every tool dialog.
The data files themselves live next to it on disk, usually in the same folder.
The project folder is the working directory.

How it fits the airborne mag chain (import, lag, levelling, IGRF, gridding, RTP, maps):

- Nothing in the chain is run from this menu.
- The menu frames the chain: you create or open a project first, and everything after is stored in it.
- The **log** and **scripts** are how an Oasis user repeats the chain on the next survey.
  Every GX run is logged with its settings.
  The log can be saved and turned into a script that re-runs the chain.
- **Last-used settings are stored in the project.**
  When a tool dialog opens, Oasis fills it with the settings from the last run in this project.
  Scripts can set these values too (`SETINI`).
  This is a core part of how Oasis feels: a second line database is processed with the same lag and levelling settings without re-typing them.
- **Print** and **Batch Printing** come at the very end of the chain, for paper maps.
- **Settings** set defaults the chain uses: default colour method for grids, default distance unit, default grid file format, whether to ask for a coordinate system on import, and the temp folder used by gridding and FFT filtering.

## 2. Command inventory

Legend: "GX" names are the Oasis program behind the command.
"Script parameter" names show how the setting is named in Oasis scripts.

### 2.1 Project files

These four or five commands have no own page.
They are described together on [Work with Projects](ss/prepare_om/work_with_projects/p/create_a_project.htm).

| Command | What it does | Inputs | Outputs | Key settings |
|---|---|---|---|---|
| New | Creates a new project file in a chosen folder. Oasis then looks for data in that folder. | Folder and name | `*.gpf` file, empty Project Explorer, default menus loaded | Default project folder (from General Settings) |
| Open | Opens a project. Can also open and convert an old pre-6.0 workspace (`*.gws`). | `*.gpf` or `*.gws` | Project, its data list and its open windows | None |
| Save | Saves the project. Also on the Project Explorer toolbar. | Open project | Updated `*.gpf` | None |
| Save As | Saves the project under a new name. The new project opens with the same databases and maps. | New name | New `*.gpf` | None |
| Close | Closes the project. If files have unsaved changes, a "Save Modified Documents" dialog lists them with All, None and Selected buttons. | Open project | Closed project | "Confirm database saves?" in General Settings |

Related, but not a menu item:

- **Resolve Broken File Links** ([page](gxhelp/m/geosoft_gx_project_manage_map_file_dependencies.htm)).
  Runs by itself when a project opens.
  It checks maps and 3D views for links to grids, voxels or surfaces that were moved or deleted.
  The user can browse to the new place, or remove the link.
  "Try to fix all broken links" searches the chosen folder for the other missing files too.
  Changes are pending (yellow) until Apply.
- **Missing data files:** in the Project Explorer, a data item whose file is gone is shown grey with a warning icon and a "Find" context menu item ([Databases context menu](ss/edit_preprocess_data/view_edit_spreadsheet_data/p/project_explorer_database_tools.htm)).
- **Closing with jobs running:** Oasis asks for confirmation and cancels the background job ([Project Explorer](ss/om_reference/common_reference/projects_databases/about_the_project_explorer.htm)).
- I did not see **Recent projects** or **Exit** in the help.
  They very likely exist (guess).
  General Settings has "Load last project?", which opens the last project at start.

### 2.2 Seequent Central (cloud project versions)

Central is Seequent's server for versioned projects.
All four commands say "not scriptable".

| Command | What it does | Inputs | Outputs | Help |
|---|---|---|---|---|
| Open Project from Central | Downloads a revision from a Central project and makes a new local Oasis project from it. | Server, project, revision, local folder | New local project | [page](gxhelp/c/create_project_from_central.htm) |
| Publish Revision | Uploads chosen datasets as a new revision. Runs in the background. Grids, voxels and surfaces are converted to "Seequent Object" format and reprojected to the Central project's coordinate system. Databases stay in Geosoft format. Maps with outside grids are packed first. | Datasets, coordinate system, thumbnail PNG | New revision on the server | [page](gxhelp/c/geosoft_gx_central_upload.htm) |
| Update Project from Central | Downloads another revision and overwrites local files of the same name. | Server, project, revision | Updated local files | [page](gxhelp/c/connect_to_central_server.htm) |
| Local Revision Details | Shows server, project, coordinate system, branch, date, stage, author and notes of the local revision. | None | Info dialog | [page](gxhelp/c/geosoft_gx_central_create_new_folder.htm) |

Background: [Oasis montaj integration with Seequent Central](ss/om_reference/common_reference/intro_to_om/central_oasis_integration.htm).

### 2.3 Export Project to OMF

[Page](gxhelp/e/geosoft_gx_export_project_to_omf.htm).

- Exports grids, voxels and geosurfaces of the project to one OMF file (Open Mining Format, an open exchange format read by Leapfrog, Surpac, Deswik and others).
- Inputs: a tick list of the project's grids, voxels and surfaces; output file name; target coordinate system and units; title and description.
- All chosen items are reprojected on the fly to the one target coordinate system.
  A warning shows if an item has no coordinate system.
- Sub-dialog [Regrid Voxels for OMF Export](gxhelp/e/geosoft_gx_geo3dv_export3dvtoomf_regrid.htm): resample rotated or variable-cell voxels, because many readers cannot handle them.
- Also on the grid context menu in the Project Explorer ("Export to OMF").
- Line databases are not exported to OMF.

### 2.4 Print (submenu)

| Command | What it does | Key settings | Help |
|---|---|---|---|
| Page Setup | Paper size, source, orientation, margins (mm), printer. | Paper, margins | [page](ss/om_reference/context_help/dialogs_tabs/printer_setup.htm) |
| Print Preview | Shows the active map as it will print, one or two pages. | Same as Print | [page](ss/present_data/plot_print_final_map_products/r/id_print_preview.htm) |
| Print | Prints the selected map. | Printer configuration; region (viewed area or entire map); panels (all or range) and panel overlap (mm); scale (fit to page, scale factor, fit on roll); print to file; copies; centre on page; X/Y offset (mm) | [page](ss/present_data/plot_print_final_map_products/r/id_print_setup.htm) |
| Change/Add Printer Configuration | Named printer set-ups with a print mode: Windows driver, Geosoft bands, Geosoft band and dither, HP-RTL, PostScript. Also resolution and colour scaling. | Print mode | [page](ss/present_data/plot_print_final_map_products/r/id_print_config.htm) |
| Batch Printing (MAPPRINT GX) | Prints many maps in one go with the same settings. Can write print files (multi-panel gives `.0`, `.1`, ...). | Maps list, scale option, pages, offsets, overlap, destination, copies | [page](gxhelp/m/mapprint_gx.htm) |
| Print Saved Files (FILEPRNT GX) | Sends saved print files to the printer. | File list | [page](gxhelp/f/fileprnt_gx.htm) |

"Panels" means a large map split over several sheets.
This is for large-format paper maps on plotters.

### 2.5 Manage Menus

[Page](gxhelp/m/geosoft_gx_manage_menus.htm).
Also a button on the Project Explorer toolbar.

- A tick tree of menus: Standard Menus, Extensions (licensed add-ons such as MAGMAP), Custom Extensions (company add-ons), User Menus (the user's own `*.omn` files).
- Ticked menus appear on the menu bar of **this project**.
  Each project keeps its own set ([Oasis montaj Menus](ss/om_reference/context_help/intro_to_om/oasis_montaj_menus.htm)).
- Buttons: Select All, Restore Defaults.
- Licensed extensions are not loaded by default in new projects.
  The user must tick them.

Custom menus ([Create Custom Menus](ss/prepare_om/add_remove_menus/c/creating_your_own_menus.htm)):

- A menu file (`*.omn`, `*.smn`) is plain text.
- Keywords: `MENU`, `ITEM "label", program.gx`, `SEPARATOR`, `SUBMENU`, `LOADMENU`, `&` hot keys, and `[n]` licence dependencies.
- An item can run a GX, a GX.NET entry such as `geogxnet.dll(Geosoft.GX.Database.InterpolateChannel;Run)`, or a script (`.gs`).
- User files go in `%USERPROFILE%\Documents\Geosoft\Desktop Applications\omn`.
- The help's example is the Tie Line Levelling menu (Intersections, Load Corrections, Statistics, Interpolate, Trend, Sample a Grid, Apply Levels, Table Lookup).

### 2.6 Settings (submenu)

Hub page: [Configure Oasis montaj Settings](ss/prepare_om/configure_settings/change_oasis_montaj_settings.htm).
All settings here are **global** (per user and computer), not per project.

**General** (SETTINGS GX, [page](gxhelp/s/settings_gx.htm)).
Stored in a `geosettings` file in the user's Documents folder.
Restart needed.
Two pages:

| Setting | Meaning |
|---|---|
| Default project directory | Parent folder for new projects. |
| Default menus | Which `*.omn` files load in a new project. |
| Default grid colour table | Colour scheme for new grid images. |
| Default symbol colour table | Colour scheme for symbols. |
| Default colour method | Equal Area, Linear, Log-Linear or Normal. Used by all displayed grids. |
| Default distance unit | Metre, kilometre, foot, ... |
| Default map font, default symbol font | Fonts for maps. |
| Database compression | None, Speed or Size, for new databases. ([Database Compression](ss/edit_preprocess_data/view_edit_spreadsheet_data/c/database_compression.htm): zlib; "speed" is about 3x faster read/write and 58% size; "size" is 19% size.) |
| Text file editor | Program used by Edit File and Comments. |
| Default input / output grid format | File type offered first when browsing for grids. |
| Default Geosoft grid element type | Compressed 32-bit float (default) or 32-bit float. ([Grid Compression](ss/process_data/grid_data/c/grid_compression.htm)) |
| Load last project? | Open the last project at start. |
| Confirm database saves? | Ask, or save databases on close without asking. |
| Specify coordinate system on import? | If Yes, import asks for a coordinate system when X and Y have none. |
| Error report level | How much error detail is shown. |
| HP-RTL nesting | Printer option. |
| Temporary file directory | Folder for temp files. Can need gigabytes. Should be on a fast drive. Used by MAGMAP filtering and gridding. |

**Advanced** (ADVSETTINGS GX, [page](ss/prepare_om/configure_settings/c/advanced_settings.htm)).
A tree of sections with an attribute and value table, stored in `geosettings.meta`.
Examples from the help:

- Auto Save Time: a reminder to save every N minutes (30, 90, never, or custom).
- Default project directory.
- OpenGL: "Use Discrete GPU" and "Use Software Rendering" as a fallback for weak or broken graphics drivers.
- Image settings: show grids colour-shaded by default; default grid input format.
- Map settings: pin the Map Manager when a map opens.

**Language** ([page](ss/prepare_om/configure_settings/p/language_settings.htm)): English, Simplified Chinese, Russian.
Restart needed.

### 2.7 Log File (submenu)

[Page](ss/prepare_om/configure_settings/c/using_log_files_and_clearing_the_internal_log.htm).

- Oasis records every GX run with its settings inside the project.
- **Save Log:** writes the record to an ASCII log file.
- **View Log:** opens it (VIEWLOG GX).
- **Clear Log:** empties the internal record, which "can become quite large".
- The help says the log is useful to remember settings and to build scripts from.

### 2.8 Edit File and Comments

- **Edit File** (EDIT GX, [page](gxhelp/e/edit_gx.htm)): opens any file in the chosen external text editor.
  Sub-dialog [Select Default Text Editor](gxhelp/n/newedit_gx.htm) (NEWEDIT GX).
  Used for scripts, expression files and control files.
- **Comments** (GPFCMNT GX, [page](gxhelp/g/gpfcmnt_gx.htm)): edits an RTF comment block stored in the project file, in the external editor.
  There is a matching database comment block (DBACTLOG GX).

### 2.9 Run GX

[Page](gxhelp/g/gxrun_gx.htm).
Also a button on the Project Explorer toolbar.

- Runs any GX (`*.gx` in the `gx` folder) or GX.NET entry (`geogxnet.dll(Namespace.Class;Run)`).
- A History button lists the GXs run from this dialog in this project.
- This is how a user runs a tool that is not on any menu.
- Background: [About GXs](ss/om_reference/common_reference/interpretations_expressions_scripts/about_gxs.htm).
  Geosoft GXs are signed.
  Unsigned GXs give a warning.

### 2.10 Scripting (submenu)

Hub: [Script Tools in Project Explorer](ss/om_reference/context_help/bars/script_toolbar.htm).
Record Script and Stop Recording are on the Project Explorer toolbar.
I believe they are also in this submenu, but I did not see that stated (guess).

| Command | GX | What it does | Key settings |
|---|---|---|---|
| [Run Script](gxhelp/g/gsrun_gx.htm) | GSRUN | Runs a Geosoft script (`*.gs`). Can set up to eight `name.parm=value` overrides first. Scripts start non-interactive. Has an Edit Script button. | `GSRUN.NAME`, `GSRUN.P0`..`P7` |
| Record Script | (toolbar) | Starts writing every action to a `*.gs` file. Asks to overwrite or append if the file exists. | File name |
| Stop Recording | (toolbar) | Ends recording. | None |
| [Load a Channel](gxhelp/l/loadchan_gx.htm) | LOADCHAN | Shows a channel in the spreadsheet (column choice in scripts). | Channel |
| [Unload a Channel](gxhelp/u/unloadchan_gx.htm) | UNLOADCHAN | Hides a channel from the spreadsheet. | Channel |
| [Create Channel](gxhelp/n/newchan_gx.htm) | NEWCHAN | Adds a channel to a database. | Name; data type (Byte, UShort, Short, Long, Float, Double, String); string size; display format; width; digits; array size |
| [Delete Channel](gxhelp/d/delchan_gx.htm) | DELCHAN | Deletes a channel. Will not delete protected channels. | Channel |
| [Create Line](gxhelp/n/newline_gx.htm) | NEWLINE | Adds a line. | Line (for example `L100.3`), flight, date |
| [Delete Line](gxhelp/d/delline_gx.htm) | DELLINE | Deletes lines by name or range. Line type letters: L line, B base, T tie, R trend, S test, P special, D random; `L100:300.3` is a range. | Line spec |
| [Math Expression](gxhelp/m/math_gx.htm) | MATH | Applies an expression such as `C=ADATA+BDATA;D=C*C;`. `@name` is a temporary variable. | Expression |
| [Math File](gxhelp/m/mathfile_gx.htm) | MATHFILE | Same, read from an `.exp` file with `/` comments. | File |
| [Set Printer](gxhelp/s/setprnt_gx.htm) | SETPRNT | Sets the current printer. | Printer |
| [Run Program](gxhelp/g/geo32_gx.htm) | GEO32 | Runs an `.exe` or `.bat`. | Program |
| [Run Process](gxhelp/w/winexec_gx.htm) | WINEXEC | Runs a command in a console, with wait or no-wait options. | Command, args, type, hold screen |
| [Run Sushi PDF](gxhelp/r/runpdf_gx.htm) | RUNPDF | Runs an old DOS-era "Program Description File" dialog. Legacy. | File |

Batch use without the GUI: [Command Line Interface](ss/process_data/apply_filters_gxs/r/command_line_interface.htm).
The script processor `OMS.EXE` runs `*.gs` scripts from the command line, without opening Oasis.

### 2.11 Parameters (submenu, seen only by mention)

The Seequent Evo help says "Clearing parameters (Project > Parameters > Clear Parameters) resets settings" in the Evo dialogs ([Import from Evo](evo/evo_importobjects.htm)).
There is no own page in the 2025.1 help.
My reading (guess): this clears the last-used tool settings stored in the project, so dialogs go back to defaults.

### 2.12 Project Explorer toolbar (same commands, second place)

From [Project Explorer](ss/om_reference/common_reference/projects_databases/about_the_project_explorer.htm): Save Project, Manage Menus, Run GX, Run Script, Record Script, Stop Recording.
The Project Explorer also has the Data, Tools and Jobs tabs.
The draft design already covers Data and Jobs.

## 3. How the commands work together

**Start of a job:**

1. New project in the survey folder (or Open, or Open Project from Central).
2. Manage Menus: load the extensions needed, for example MAGMAP (FFT filters, RTP) and the levelling menus.
3. Import data (Database menu).
   If "Specify coordinate system on import?" is Yes, the coordinate system dialog opens.

**During processing:**

- Every tool run is logged with its settings, and the settings are kept as the next dialog's defaults.
- Long runs (gridding, grid multiple channels, MAGMAP filtering) go to the Jobs tab.
- Comments hold free-text notes about the project.

**Repeat for the next survey (the main automation loop):**

1. Record Script while doing the chain once, or Save Log after doing it.
2. Edit the script in the external editor (Edit File).
3. Run Script on the new data, with `name.parm=value` overrides, or run it with `OMS.EXE` from the command line.
4. The small Scripting commands (create or delete channels and lines, math expressions) are the glue steps inside these scripts.

**End of a job:**

- Print or Batch Printing of the final maps (Map menu makes the maps).
- Publish Revision to Central, or Export Project to OMF for Leapfrog and mine software.
- Save, then Close.

**Links to other menus:**

- Database menu: import, and the database that Create/Delete Channel and Line act on.
- Grid and Image: gridding jobs; default grid format and colour method come from Settings.
- Map: the maps that Print acts on; Resolve Broken File Links fixes maps whose grids moved.
- Coordinates: the coordinate system dialog used by import, OMF export and Publish Revision.

## 4. Fit in JuliaMag

### 4.1 The big point: "Project" should not be a ribbon tab

RustGIS already solves this.
In RustGIS the "Project" button at the left end of the ribbon opens a **backstage** page (like the File page in Office): start page, open, save, save as, about (`crates/ui-egui/src/backstage.rs`).
RustGIS also has a fixed **Settings** tab and a fixed **Help** tab at the right end of the ribbon (`ribbon.rs`, `FIXED_TABS`).

The Oasis Project menu is a file menu plus app settings plus automation.
None of it is a processing step.
So I suggest:

- **Backstage ("Project" button):** New, Open, Recent, Save, Save As, Close, project notes, project info, export of the whole project.
- **Settings tab (fixed, right end):** general settings, ribbon tabs shown, shortcuts, language later.
- **Automation lives where it already is in the draft:** the command history, the Jobs list and the script export.
  Plus a small "Scripts" group, see 4.4.

This changes draft section 5.1, where "Project" is the first of the 13 ribbon tabs.
Proposed change: "Project" becomes the backstage button, and the first real ribbon tab is Database.

### 4.2 Per-command placement

Priority key: **v1** = first version, **later**, **skip**.
Kind: **tool** = a Julia function plus description (shows in the ribbon, command search and scripts).
**built-in** = part of the app shell, not a tool.

| Oasis command | JuliaMag place | Kind | Priority | Notes |
|---|---|---|---|---|
| New project | Backstage, Ctrl+N | built-in command | v1 | Pick folder and name. A project is a folder (draft 9), so "New" makes the folder. |
| Open project | Backstage, Ctrl+O, start page | built-in command | v1 | Open the project folder or its index file. |
| Recent projects, "load last project" | Backstage start page | built-in | v1 | RustGIS already has a start page with recent items. |
| Save, Save As | Backstage, Ctrl+S | built-in command | v1 | See question Q1: with per-channel files and a job record, "save" may only be needed for view state. Save As = copy the folder. |
| Close (with "save modified" list) | Backstage | built-in | v1 | Also: warn and cancel when jobs are running, as Oasis does. |
| Open old `.gws` workspace | - | - | skip | Oasis legacy. |
| Resolve Broken File Links / Find missing file | Project Explorer: grey item with warning and a "Find..." context item; a check when the project opens | built-in | v1 (small) | JuliaMag copies data into the project on import, so links break far less often. But a user can still move or delete files. Store paths relative to the project folder. |
| Open/Publish/Update from Central, Local Revision Details | - | - | skip | Seequent cloud service. Note for later: "publish a snapshot" is like committing the project folder to git or copying to a share. |
| Export Project to OMF | Exporter system, and a backstage "Export project" page | exporter (tool) | later | One OMF exporter for grids. Fits the draft's pluggable exporters. Useful for Leapfrog users. |
| Print, Print Preview, Page Setup, Printer Config | Map tab, layout group (the Map menu agent covers maps) | tool | skip in v1; later as "export layout to PDF" | Modern route is PDF export from a layout. Printing a PDF is the OS's job. Panels and plotter modes are not needed. |
| Batch Printing | Map tab | tool (background job) | later | As "export many layouts to PDF/PNG". Natural as a job. |
| Print Saved Files, Set Printer | - | - | skip | Plotter-era features. |
| Manage Menus | Settings tab, "Ribbon" button (show or hide tabs), as in RustGIS | built-in | v1 (RustGIS already has it) | Oasis keeps the menu set per project. RustGIS keeps it per user. I suggest per user (simpler). See Q3. |
| Custom menus (`.omn` files) | A user tab file listing command ids by group | built-in, data file | later | Fits the draft's "the tab list is data". A user writes a small TOML file: tab name, groups, command ids. No code. A good way to put "my levelling chain" in one tab. |
| Licensed extensions in Manage Menus | Tool packages that register themselves | built-in | later (draft 4.2 already leaves room) | Extensions = separate Julia packages. Their tabs appear when loaded. |
| Settings: General | Settings tab, "Options" dialog; stored per user (TOML) | built-in | v1 for the items below | See 4.3. |
| Settings: Advanced | Same dialog, "Advanced" page | built-in | later | Keep one settings store. Do not split into two dialogs with two files. |
| Language | Settings tab | built-in | skip (draft 6 lists translations as a non-goal) | |
| Log File: Save, View, Clear | Jobs/History pane: "Save as Julia script", "Show history" | built-in | v1 (the draft already plans history) | "Clear Log" is risky in JuliaMag because the same records hold provenance of outputs (draft 9). Offer "hide old entries" instead, and never drop records that made an existing item. See Q4. |
| Edit File, Select Text Editor | "Open script in editor" on a script item; editor path in Settings | built-in | later | Julia users have VS Code. A small built-in editor is not needed. |
| Comments (project notes) | Backstage "Info" page or Project Explorer root item: free-text Markdown notes | built-in | v1 (cheap) | The draft has descriptions per dataset. Add one at project level too. |
| Run GX | Command search (Ctrl+K) runs any registered tool. Plus "Run Julia file" | built-in | v1 (command search exists in the RustGIS model) | A tool not on any tab is still found by id or name. "Run Julia file" loads a `.jl` file that may define new tools. |
| Run Script | Scripts group: "Run script" (a `.jl` file) with parameter overrides | built-in command, runs as a job | v1 | Script runs as a background job with progress and cancel, through the same job system. |
| Record Script, Stop Recording | Not needed as a mode. Instead: select entries in History and "Save as script" | built-in | v1 | The draft already records all commands. A record mode only adds state to forget. |
| Load / Unload a Channel | Database view: show or hide column; core API call | built-in view action | v1 (part of the database view) | View state, not data change. |
| Create Channel, Delete Channel | Database tab, Channels group; context menu on a channel; core API | tool | v1 for delete and rename; create comes with Channel Math | Respect a "protected" flag (Oasis does). Raw imported channels could be protected by default (my suggestion). |
| Create Line, Delete Line | Database tab, Lines group; context menu on a line | tool | later (delete: v1 if cheap) | Keep Oasis line naming: type letter (L, T, B, ...), number, version. The XYZ importer reads `Line` and `Tie` already. |
| Math Expression, Math File | Database tab: "Channel Math" tool. The expression is Julia (for example `C = A .+ B`) | tool | later (high value) | Julia makes this easy and powerful. Math File = a saved expression snippet. The Database Tools agent may cover this too. |
| Run Program, Run Process | - | - | skip | A Julia script can call `run(...)`. |
| Run Sushi PDF | - | - | skip | DOS legacy. |
| Parameters > Clear Parameters | Tool dialog: "Reset to defaults" button; Settings: "Reset all tool settings" | built-in | v1 (the button) | Needs "last-used settings per project" first. See 4.3. |
| Command-line runs (`OMS.EXE`) | The core without UI in the REPL, plus a small `juliamag run script.jl --project X` entry | built-in | later | Draft 4.6 already says the core works without the UI. |

### 4.3 Things the draft does not have yet

1. **Last-used tool settings per project.**
   Oasis fills every dialog with the settings of the last run in this project.
   This matters a lot for a chain that is run on many lines and databases.
   Suggest: each tool's settings dialog opens with the last-used values from this project, else the tool defaults.
   "Reset to defaults" button in every dialog.
   The job records (draft 9) already hold these values, so this is cheap.
2. **Global user settings with defaults that tools read.**
   From General Settings, the ones that matter for JuliaMag v1:
   - default project folder;
   - load last project at start;
   - default colour method for grids (the draft has histogram equalisation and linear; Oasis also has log-linear and normal);
   - default distance unit;
   - default coordinate system guess on import;
   - **temp/cache folder**, with a check that it exists and is writable (Oasis says it cannot start if this is wrong, and it can need gigabytes);
   - storage compression for line databases (Oasis offers none, speed, size; the Arrow format supports LZ4 and Zstd, so the same choice fits);
   - text editor path (later).
3. **Graphics fallback.**
   Oasis has "Use Software Rendering" and "Use Discrete GPU" settings for bad graphics drivers.
   JuliaMag draws with OpenGL through CImGui and Makie, on mostly Windows laptops.
   Suggest a start-up flag or setting for software rendering, and a preference for the discrete GPU.
   This is cheap insurance against a "black window" bug report.
4. **Auto-save reminder.**
   Oasis reminds the user to save every 30 minutes.
   If JuliaMag writes data changes at once (per-channel files) this is only needed for view state.
   Better: save view state by itself and skip the reminder.
5. **Project-level notes** (from Comments), see table.
6. **Protected channels** (from Delete Channel).

### 4.4 Suggested ribbon and backstage layout for this menu's content

- **Backstage (Project button):**
  Start (recent projects, New, Open), Info (path, size, coordinate system summary, notes), Save, Save As, Export project (later: OMF), Close, About.
- **Settings tab (fixed):**
  - Customize group: Ribbon (tabs shown), Shortcuts, Options (the settings dialog).
  - Later: My Tabs (user tab files).
- **Scripts group:**
  Run Script, Run Julia File, Save History as Script, Open Scripts Folder.
  Where to put it is open (Q2).
  RustGIS has no place for it today.
  Options: on the Settings tab, on a small "Automate" tab, or only in the History/Jobs pane header.
  I lean to the pane header plus command search, because these are used rarely but must be easy to find.

### 4.5 Items in this menu that match draft decisions (no change needed)

- Jobs tab with cancel, rerun with changed settings, outputs added to Data: Oasis has exactly this (draft 4.4).
- Oasis only sends some tools to Jobs (gridding, grid multiple channels, MAGMAP filtering, section gridding).
  JuliaMag's "quick or background" flag per tool is more general and better.
- Oasis does not keep Seequent Evo jobs after reopening, and loses status for jobs that finished after close.
  JuliaMag saving jobs with the project (draft 9) is better.
- Script parameter naming `GX.PARAM=value` maps well to `tool_id(; param=value)` in Julia.

## 5. Open questions for the user

1. **Save model.**
   Should data changes be written to disk at once (each tool writes its new channel or grid file), with "Save" only for view state and layout?
   Or should JuliaMag work like Oasis, with unsaved changes and a "save modified documents" list on close?
   I lean to writing data at once, plus Undo, because large files and crashes make unsaved state risky.
2. **Where do Run Script and Save History as Script go?**
   Settings tab, a small Automate tab, or only the History/Jobs pane header and command search?
3. **Tabs shown: per user or per project?**
   Oasis keeps the loaded menus per project (for example a gravity project shows other menus than a mag project).
   RustGIS keeps it per user.
4. **Clear Log.**
   Is it fine that history entries that made an existing item can never be deleted (only hidden)?
5. **Last-used settings.**
   Should a tool remember its last settings per project (as Oasis does), per user, or both (project first, then user)?
6. **Do you use Record Script / Run Script / `OMS.EXE` batch runs in Oasis today?**
   If yes, which steps of the chain do you script?
   That tells us which tools need a good script form first.
7. **Do you use custom `.omn` menus today** (for example a personal levelling menu)?
   If yes, the "user tab file" idea should move up to the first version.
8. **Printing.**
   Do you still print from Oasis (plotters, multi-panel sheets), or only export PDF or images?
9. **OMF / Leapfrog.**
   Do grids from JuliaMag need to reach Leapfrog or mine software?
   If yes, an OMF grid exporter could be an early exporter.
10. **Temp folder.**
    Do you work on laptops where the system drive is small?
    Then the temp/cache folder setting matters in the first version.
