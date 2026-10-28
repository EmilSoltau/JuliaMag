# Oasis montaj "Database" menu: research for JuliaMag

Date: 2026-10-28
Source: Oasis montaj 2025.1 online help.
Scope: the **Database** menu only.
Other notes cover Project, Database Tools, Coordinates, Grid and Image, and Map.

All help links below start with `https://help.seequent.com/Oasismontaj/2025.1/Content/`.
In the text they are written as `…/Content/<path>`, and given in full where it matters.

How the menu tree was found:

- The "Oasis montaj Menus" page does not list menu items.
- The help's table of contents has a "Context Help" section with one node per menu.
  The "Context Help > Database" node is the menu tree used below.
- A few items are named on other help pages but are not in that tree.
  They are marked "seen elsewhere".

## 1. Overview

The Database menu is the "file menu" for line data.
A Geosoft database (`.gdb`) holds all line data for one survey.
The menu creates, opens, saves and closes databases.
It brings data in (Import) and sends it out (Export).
It also has a few housekeeping items: saved channel layouts, an audit log, maintenance and properties.

It does no processing.
Processing (lag, levelling, filters, gridding) lives in other menus and extensions.
But every step of the chain depends on it:

1. **Import** (this menu) turns XYZ, CSV and other files into a database.
2. **Lag correction, levelling, IGRF removal** read and write channels in that database.
   These tools live elsewhere (Database Tools and extensions), not in this menu.
3. **Gridding** reads a channel from the database and writes a grid.
4. **RTP and maps** work on grids and maps, not on the database.
5. **Export** (this menu) writes processed line data out to CSV, XYZ and other formats.

The database is shown in a **spreadsheet window**, with a **profile window** under it.
These windows are not menu items, but the menu items act on them.
For example, "Save Working View" saves which channels are shown, and many exports offer "displayed channels".
So this note also covers the spreadsheet and profile windows, channels, lines and fiducials.

### 1.1 The data model behind the menu

From "About the Geosoft Database" (`…/Content/ss/prepare_om/work_with_databases/c/oasis_databases.htm`):

- A database has three levels: **line**, **channel**, **element**.
- An **element** is one value: byte, ushort, short, long, float, double or a fixed-length string.
- A **channel** is a named column.
  - It has a start fiducial and a fiducial increment.
  - Once a channel exists, it exists on every line, but it may be empty on some lines.
  - All its elements have the same type.
  - Names must start with a letter or `_` and have no spaces.
  - A channel can be an **array channel** (several values per sample, for example 256 radiometric windows).
- A **line** is a set of channels for one survey line.
  - It has a type, number, version, flight number, date and a selected flag.
  - The line name format is `TYPE number.version:flight`, for example `T110.2:16`.
  - Type, number and version must be unique in the database.
  - Line types: `L` normal, `T` tie, `B` base, `S` test, `R` trend, `P` special, `D` random.
- A **group** is a special line with a free-text name and an optional class.
  A group can limit which channels it shows.
  Groups came from drillhole work and are not needed for airborne magnetics.
- Data is stored **column by column**.
  The help says this makes it fast to process one channel and lets each channel have its own start and sample interval.

A key point for JuliaMag: **the fiducial start and increment belong to each channel on each line, not to the line.**
The help says: "the sample increment (fiducial increment) of each channel on a line may be different, but data between channels is related based on the fiducial number."
Example: a mag channel at 10 Hz and a GPS channel at 1 Hz can sit on the same line.

Dummy (missing) values depend on the type (`…/Content/ss/import_data/import_file_types/c/import_data_types_and_database_display_formats.htm`):

| Type | Range | Dummy |
|---|---|---|
| Byte | -126 to 127 | -127 |
| Ushort | 0 to 65534 | 65535 |
| Short | -32766 to 32767 | -32767 |
| Long | 32-bit signed | -2147483647 |
| Float | 32-bit | -1.0E+32 |
| Double | 64-bit | -1.0D+32 |
| String | null terminated | empty |

Internally, time is stored as decimal hours, dates as decimal years, and geographic values as decimal degrees.
A display format (Normal, Exponent, Time, Date, Geo, SigDigit, Hex) only changes how values look.

## 2. Command inventory

The tree below is "Context Help > Database" from the 2025.1 help table of contents.

```
Database
├── New
├── Open
├── Save
├── Save As
├── Close
├── Close All
├── Import
│   ├── ASCII
│   ├── Database Table
│   │   ├── Single Table
│   │   └── All Tables
│   ├── Geosoft XYZ  (with "Import XYZ Template")
│   ├── Geosoft Database Merge
│   ├── Geosoft Binary
│   ├── Flat Archive
│   ├── Blocked Binary
│   ├── ODBC
│   ├── MapInfo TAB or MIF File(s)
│   ├── ArcGIS Shapefile(s)
│   ├── ASEG-GDF2  (with "Scan ASEG-GDF2")
│   ├── ASEG-ESF
│   ├── RMS
│   ├── RMS DAARC500 Binary Data
│   ├── UBC Mag3D Model(s)
│   ├── Picodas PDAS
│   │   ├── Scan Data
│   │   └── Import Data
│   ├── USGS
│   │   ├── ODDF Express
│   │   └── POST File
│   └── AMIRA
│       └── Import AMIRA File
├── Export
│   ├── CSV etc.
│   ├── Geosoft XYZ  (with "Export XYZ Template")
│   ├── Geosoft GBN
│   ├── Subset GDB
│   ├── Access Database
│   ├── ASEG-GDF2
│   ├── ASEG-ESF
│   ├── Esri File Geodatabase
│   ├── Export to KML
│   ├── ArcGIS Shapefile(s)
│   └── Mark
├── Save Working View
├── Get Saved View
├── Edit Audit Log
├── Maintenance
│   ├── Defragment Database
│   └── Grow Database
└── Properties
```

Seen elsewhere, but not in that tree:

- **Discard Changes.** Named on the "Save a Database" page and the Database Viewer toolbar page ("Database > Discard Changes").
- **Settings > Configure GDB Shortcut Keys.** Named on the Database Viewer toolbar page.
- **Metadata.** The "About Metadata" page says Metadata is on the Database menu, among others.

The exact 2025.1 menu may differ a little from the help tree.
Checking it needs a running copy of Oasis montaj.

### 2.1 File items

#### New

- Help: `…/Content/gxhelp/n/geosoft_gx_newgdb_newgdb_run.htm`
- What: creates an empty `.gdb` file.
  Also on the Project Explorer "Databases" right-click menu.
- Inputs: a file name.
- Settings:
  - Maximum lines/groups and maximum channels.
    The database has a fixed-size index (lines times channels times 6 bytes).
    Going over the limit is an error, fixed with Maintenance > Grow.
  - Compression: none, "for speed" (zlib, about 55% smaller and faster), "for size" (about 80% smaller, up to 20% slower).
  - Page size: sets the largest database (4 TB default, up to 64 TB) and the most data per channel per line (64 MB default, up to 1 GB).
- Output: an empty database, opened in a spreadsheet window.

#### Open

- Help: `…/Content/ss/prepare_om/work_with_databases/p/open_a_database.htm`
- What: opens a `.gdb` file into a spreadsheet window.
  Also from the Project Explorer.

#### Save

- Help: `…/Content/ss/prepare_om/work_with_databases/p/save_a_database.htm`
- What: commits edits to the file.
- Edits (new channels, deleted channels, changed values) stay pending until saved.
- Showing or hiding channels is not an edit.
- The help advises to save after each major step, so "Discard Changes" can roll back a bad processing run.

#### Save As

- Help: `…/Content/gxhelp/s/savegdb_gx.htm`
- What: writes the current database, with all changes, to a new file.
  The original is closed and its unsaved changes are dropped.
- Settings: new file name, compression (none, speed, size).

#### Discard Changes (seen elsewhere)

- Help: named on `…/Content/ss/prepare_om/work_with_databases/p/save_a_database.htm` and `…/Content/ss/om_reference/context_help/bars/line_toolbar.htm`.
- What: returns the database to its last saved state.

#### Close and Close All

- Help: `…/Content/gxhelp/c/closegdb_gx.htm`, `…/Content/gxhelp/d/dbclose_gx.htm`
- What: closes the current database or all databases.
  Asks to save if there are changes.
- A General Setting "Confirm database saves?" decides whether closing a project asks, or saves by itself.

### 2.2 Import

Common behaviour seen on many import pages:

- The target is the current database, another database in the project, or a new one (a "Create Database" button).
- Many imports accept several files at once, if they share one format.
- Many use a **template file** that maps file columns to channels, saved next to the project and reusable.
- If the General Setting "Specify coordinate system on import?" is Yes, and the X and Y channels have no coordinate system, the import opens "Set Coordinate System" afterwards.
- Imported channels are **protected** (read-only) by default.
- After import, the spreadsheet does not show the data by itself.
  The user picks which channels to show.

#### Geosoft XYZ (most important)

- Help: `…/Content/gxhelp/i/import_gx.htm`
- Template editor: `…/Content/ss/import_data/import_file_types/import_geosoft_xyz_files/r/id_import_xyz.htm`
- File format: `…/Content/ss/glossary/xyz_data.htm`
- What: imports Geosoft XYZ files, which are columns of numbers split into lines by line headers.
- Inputs:
  - Target database (current, other, or new).
  - One or more XYZ files in the same format.
  - Optional template (`.i0`).
- File rules from the help:
  - Comment lines start with `/`.
  - Channel names can come from a `/` comment record with comma-separated names, just above or below the first `Line` record.
  - Without a template, Oasis uses the **last comment line that has as many names as there are columns**.
    If a later comment line (for example a units line) also matches the count, that one wins.
  - Without any names, columns become `X`, `Y`, `Z1`, `Z2`, …
  - `//Flight` and `//Date` lines can appear anywhere and apply to all following lines until the next one.
  - Lines start with a line header such as `Line 15700`.
  - If there are no line headers, all data goes into one random line (type `D`).
  - "Archive style" files, where the line number is a column, should be imported with the line number in a channel, then split with the BRKLINE GX (in Database Tools).
  - Dummy is `*` by default.
    The template dummy is matched as text, exactly.
- Settings:
  - **Import mode** (what to do when a line already exists):
    - Replace (default): the incoming line replaces the old one.
    - Append: the new line gets the next version, for example `100.1`.
    - Merge Append: the new rows go on the end of the existing line.
    - Merge: incoming and existing channels are merged on fiducial.
      This needs a channel marked as `FIDUCIAL`.
      It may resample to the smallest common fiducial increment.
      Without a fiducial channel it acts like Replace.
- Template (`.i0`) format:
  - Starts at a line `[IMPORT XYZ]`.
  - Then one `IMPORT column, format, channel, type, width, decimals, dummy` line per column.
  - `column` can be `5:16` to read 16 consecutive columns into one array channel.
  - `format`: NORMAL, DATE (YY/MM/DD or YYYY/MM/DD), DATE1 (DD/MM/YY), DATE2 (MM/DD/YY), TIME (hh:mm:ss.ss), TIME2 (hh.mmss), GGRAPH (dd.mm.ss.ss).
  - `type`: UBYTE, BYTE, USHORT, SHORT, LONG, FLOAT, DOUBLE, or USER## (string of width ##).
  - The special channel name `FIDUCIAL` marks a column of fiducials.
    The fiducial increment is then set **per line** to the smallest interval found in that column.
    Without it, each line starts at fiducial 0 with increment 1.
- Template editor ("Create XYZ Template"):
  - Shows field number, an example value and the output channel name for each column.
  - Per column: array size, storage direction (row or column), input format, dummy, output name, type, string size, decimals, width, unit.
  - A channel name in square brackets means "create this new channel".
- Output: lines and channels in the database.

#### ASCII (the CSV route)

- Help: `…/Content/gxhelp/i/impasc_gx.htm`
- Wizard pages:
  - Step 1: `…/Content/ss/import_data/import_file_types/import_ascii_binary_data/r/id_ascii_main.htm`
  - Step 2 delimited: `…/r/id_ascii_delimited.htm`
  - Step 2 fixed: `…/r/id_ascii_fixed.htm`
  - Step 3: `…/r/id_ascii_fields.htm`
  - (all under `…/Content/ss/import_data/import_file_types/import_ascii_binary_data/`)
- Template format (`.i3`): `…/Content/ss/import_data/import_file_types/template_files/i3_import_template_file.htm`
- What: imports delimited or fixed-width text, including Excel CSV and flat archive files.
- Inputs: target database, one or more files, optional `.i3` template.
  With no template, the wizard opens.
- Wizard step 1:
  - Delimited or fixed field.
  - Row with headings, row with units, first data row, number of preview rows.
  - A preview of the file.
- Wizard step 2 (delimited):
  - Excel CSV, comma, white space, tab, or other.
  - Soft or hard delimiters (soft: runs of spaces count as one).
  - Quote character and escape handling.
- Wizard step 2 (fixed): click in the preview to place column breaks.
- Wizard step 3, per column:
  - Role: not imported, data, **line**, **fiducial**, or array (with direction and size).
  - Channel name and label (default from the heading row), data type, display format or string size (1 to 128), dummy (default `*`).
  - Every imported column must have a name before Finish.
  - ISO 8601 date-times become one double "Date-Time" channel, converted to UTC if a time zone is given.
- Settings: import mode Replace or Append.
  Note: the help says Append is the default here, unlike XYZ where Replace is the default.
- Multi-file rules:
  - All files must have the same layout.
  - **Without a line column, each file becomes its own line.**
  - Duplicate line numbers get a new version number.
  - If files differ, the import may still run but give misaligned or dummy channels.
    The help says to check the import log.
- `.i3` template keys (also used by Flat Archive):
  - `FILEHEADER` rows to skip.
  - `RECORDFORM` FIXED, FREE, COMMA or DELIM (with soft, hard, escape, quote rules).
  - `SKIPSTRING` to skip comment lines.
  - `LINENAME` default line, `LINENUMBER`, `FLIGHT`, `DATE` column positions.
  - `DATA` (start, length, read format, scale, base, dummy) followed by `CHAN` (name, type, display format, width, decimals, registry such as `units=nT`).
  - `scale` and `base` let the import convert units on the fly.
  - Read formats include several DATE, TIME, GEO and HEX forms.
  - Two-digit years: 50 to 99 is 19xx, 00 to 49 is 20xx.

#### Flat Archive

- Help: `…/Content/gxhelp/i/imparc_gx.htm`
- What: imports fixed-record text using an `.i3` template.
- Settings: data file, template, optional line name, flight and date for files that lack them.

#### Database Table (Single Table, All Tables) and ODBC

- Help: `…/Content/gxhelp/i/impdb_gx.htm`, `…/Content/gxhelp/i/impdb2_gx.htm`, `…/Content/gxhelp/i/impodbc_gx.htm`
- What: imports tables from Access, Excel, dBase and other sources through Windows ODBC drivers.
  Single Table picks a table and fields, or an SQL query.
  All Tables imports every table as a line or a group.
- Writes an `impdb.i4` template.

#### Geosoft Database Merge

- Help: `…/Content/gxhelp/d/dbmerge_gx.htm`
- Also in Database Tools > Database Utilities > Merge Databases.
- What: copies lines and channels from one or more databases into a target database.
- Settings: lines (selected or all), channels (displayed or all), and "Replace existing data?" (Yes, No = fill only empty channels, Append).
  Missing lines and channels are created.

#### Geosoft Binary (GBN)

- Help: `…/Content/gxhelp/g/gbn_gx.htm`
- What: imports the Geosoft binary exchange format for "large volume multi-channel airborne datasets".
- Format: text header starting `OASIS BINARY DATA`, ended by byte 0x1A, then typed records (channel, array channel, line, data, parameter), little-endian IEEE.
- Setting: "Load channels after import?" (the help suggests No for large databases).

#### ASEG-GDF2 (with Scan ASEG-GDF2)

- Help: `…/Content/gxhelp/i/impaseg_gx.htm`, `…/Content/gxhelp/s/scanaseg_gx.htm`
- What: imports the ASEG-GDF2 exchange format (a `.dfn` definition file plus a `.dat` data file, optional `.des` and `.prj`).
- Settings: DEFN file, data file, description file, flight line channel name (default `FLTLINE`), `.i4` template, projection file and which X and Y channels it applies to, use fiducial channel (yes or no).
- Without a flight line channel, all data goes into line `L0`.
- Coordinate system is read from the `.prj`/`.met` file or from PROJ and TRNS records in the `.dfn`.
- Scan GDF2 writes a default `.i4` template that the user can edit.

#### Other imports (short)

| Item | Help path | What it does |
|---|---|---|
| Blocked Binary | `gxhelp/i/importbb_gx.htm` | Fixed-block binary with an `.i2` template |
| RMS | `gxhelp/r/rms_gx.htm` | RMS instrument blocked binary, `.i2` template |
| RMS DAARC500 | `gxhelp/i/geosoft_gx_dbutilities_importdaarc500.htm` | DAARC500 mag, analog, serial files, merged on fiducial |
| Picodas PDAS | `gxhelp/s/scanpico_gx.htm`, `gxhelp/p/picodas_gx.htm` | Scan to make an `.i1` template, then import |
| ASEG-ESF | `gxhelp/i/geosoft_gx_importesf.htm` | Electrical survey exchange format |
| USGS ODDF, POST | `gxhelp/i/impoddf_gx.htm`, `gxhelp/i/impost_gx.htm` | Old USGS binary formats |
| AMIRA | `gxhelp/i/impamira_gx.htm` | TEM data into array channels |
| UBC Mag3D Model(s) | `gxhelp/i/impubcmodmsh_gx.htm` | 3D model cells, one line per slice |
| MapInfo TAB/MIF | `gxhelp/i/importmi_gx.htm` | Attributes to a database, shapes to a map |
| ArcGIS Shapefile(s) | `gxhelp/i/importarc_gx.htm` | Attributes to a database, shapes to a map |

All paths above are under `…/Content/`.

### 2.3 Export

Common behaviour:

- Most exports ask for **channels** (displayed, all, or picked from a list) and **lines** (displayed line, selected lines, all lines).
- Existing output files are overwritten.

#### CSV etc.

- Help: `…/Content/gxhelp/e/expgen_gx.htm`
- Formats: CSV (Excel), USGS ODDF, USGS POST PC, USGS POST UNIX.
- Settings: file name, channels (displayed, all, list), lines (displayed, selected, all), include dummies (default yes), include channel names as the first row (default yes), include line names as the first column.
- Time and date channels are written as displayed.

#### Geosoft XYZ

- Help: `…/Content/gxhelp/e/export_gx.htm`
- Template: `…/Content/ss/export_archive_data/export_selected_data/r/id_export_xyz.htm`
- What: writes an XYZ file using an export template (`.o0`).
  The default template lists the channels shown in the spreadsheet, in their order.
- Template settings:
  - Channels and their order (Add, Add All, Remove).
  - Max line length: lines longer than this are split.
  - Fid increment: resample on export (default: the smallest increment of the exported channels).
  - Use displayed format: width and decimals come from the spreadsheet display.
    If a value shows as `**` (too wide), it is written as `**`, with a warning.
  - Include dummies: if off, a row is written only when all channels have values.
  - Include comment header, include line header (`//Flight`, `//Date`), CSV (commas between columns).

#### Mark

- Help: `…/Content/gxhelp/m/mark2xyz_gx.htm`
- What: writes the currently **marked** rows (a range picked in the spreadsheet or the profile) of all displayed channels to a file.
- Settings: file, new or append, format (Geosoft XYZ with a line header, Raw, REVS), line name.
- The help says this is handy to feed modelling programs.

#### Subset GDB

- Help: `…/Content/gxhelp/d/dbsubset_gx.htm`
- Also in Database Tools > Window Data > Subset Database.
- What: copies part of a database to a new database.
- Settings: lines (selected or all), channels (displayed or all), mask channel with "remove leading/trailing dummies" or "remove all dummies", compression.
- Typical use: dummy the X channel outside a polygon, then subset with X as the mask.

#### Other exports (short)

| Item | Help path | What it does |
|---|---|---|
| Geosoft GBN | `gxhelp/e/expgbn_gx.htm` | Binary exchange file; channels and lines as above |
| ASEG-GDF2 | `gxhelp/e/expaseg_gx.htm` | `.dfn`, `.dat`, `.des`, `.prj`; coordinate system from a chosen channel |
| ASEG-ESF | `gxhelp/e/geosoft_gx_exportesf.htm` | Electrical survey format with a header editor |
| Access Database | `gxhelp/e/expdb_gx.htm` | One table for all lines, or one table per line |
| ArcGIS Shapefile(s) | `gxhelp/e/expshp_gx.htm` | One shapefile, or one per line |
| Esri File Geodatabase | `gxhelp/d/geosoft_gx_Database_ExportToGeodatabase.htm` | Point or line features |
| Export to KML | `gxhelp/u/geosoft_gx_uavsurvey_exporttokml.htm` | Survey path from lon, lat, elevation channels |

### 2.4 Views, log, maintenance, properties

#### Save Working View and Get Saved View

- Help: `…/Content/gxhelp/s/savedbvu_gx.htm`, `…/Content/gxhelp/l/loaddbvu_gx.htm`
- What: saves the list of channels shown in the spreadsheet and profile windows to a `.dbview` text file, and loads it again.
  It works across databases and projects.

#### Edit Audit Log

- Help: `…/Content/gxhelp/d/dbactlog_gx.htm`
- What: opens a free-text (RTF) note stored inside the database, in an external text editor.
  Meant for survey details, instruments, and major processing steps.

#### Metadata (seen elsewhere)

- Help: `…/Content/ss/om_reference/common_reference/spreadsheets_data/about_metadata.htm`
- What: ISO 19115 metadata, captured on import, stored in the data or in a side XML file.
  It records user, date, time and actions, and passes **lineage** on to derived data.

#### Maintenance > Defragment and Grow

- Help: `…/Content/ss/prepare_om/work_with_databases/maintain_databases/p/to_defragment_a_database.htm`, `…/r/id_grow_db.htm`
- Defragment rewrites the file to undo fragmentation after many edits.
  It warns that a stopped defragment may corrupt the file.
- Grow raises the maximum lines and channels of the fixed index.

#### Properties

- Help: `…/Content/gxhelp/d/geosoft_gx_database_databaseproperties.htm`
- Shows:
  - Current X, Y, Z channels.
  - Coordinate system name and length unit.
  - Compression, file size, maximum size, maximum data per channel.
  - Lines used versus available, channels used versus available.
- "Current X, Y (Z)" channels are the ones used to map and plot.
  They are set in Coordinates > Set Current X,Y,Z.
  The spreadsheet marks them with small `x`, `y`, `z` tags in the channel header.

### 2.5 The spreadsheet and profile windows

These are not menu items, but the menu acts on them.

Spreadsheet window (`…/Content/ss/om_reference/common_reference/spreadsheets_data/about_the_spreadsheet_window.htm`, `…/Content/ss/edit_preprocess_data/view_edit_spreadsheet_data/c/viewing_and_editing.htm`):

- Shows **one line at a time**.
  The top-left **ID cell** shows the line name, with a check mark if the line is selected.
- The left column shows **fiducials**.
- Each other column is a channel, chosen by the user.
  The view is only a view; hidden channels are still in the database.
- If shown channels have different fiducial starts or increments, the window shows all of them at the **smallest increment** from the **lowest start**.
  Values between samples are shown but cannot be edited.
  To change samples for real, the user must re-fid the channel (Database Tools).
- **Master sample**: right-click a channel and choose "Master Sample" to show all channels at that channel's rate instead.
- Dummies show as `*`.
  `**` means the value is too wide for the column.
- Array channels show as a small curve in each cell.
- ID cell right-click menu: List, Go To, Edit line, Edit all selected lines, New Line, New Group, Delete Lines/Groups, Selections (Selection Tool, select or deselect by single line, flight, version, direction, type, name or mask, Select All, Select None, Save and Get Selections).
- Channel header right-click menu: List, New, Insert, Edit, Delete Channel, Hide Column, Display All, Hide All, Protected, Master Sample, Show Profile.
- Edit Channel dialog (`…/Content/ss/om_reference/context_help/basic_actions/id_edit_chan.htm`):
  name, **label** (the original name when an imported name was not valid), data type (set on import only), array size, class, units, protected, display format, width, decimals.
- Marking data: click a cell, drag a range, double-click the header for the whole channel on this line, triple-click for all lines.
  "When all data in the database is marked, changes are only applied to currently selected lines."
- **Line selection** (`…/Content/ss/process_data/select_data_for_processing/c/selecting_or_de_selecting_lines_for_processing_selline_gx.htm`): each line is selected or not, the state is **saved in the database**, and most processes and maps use only selected lines.
  All lines are selected after import.
- Keyboard: Ctrl+L list, Ctrl+E edit, Ctrl+I insert, Space hides a channel, Delete deletes.
  Shortcut keys can be changed under Database > Settings > Configure GDB Shortcut Keys.

Database Viewer toolbar (`…/Content/ss/om_reference/context_help/bars/line_toolbar.htm`):

- Save Changes, Discard Changes.
- First, Last, Previous, Next line.
- New line, Delete current line.
- **Pan to Cursor on All Maps**: the cursor in the spreadsheet or profile shows as a "shadow cursor" on every open map, and maps pan to keep it in view.

Profile window (`…/Content/ss/om_reference/common_reference/profiles_linking/about_profiles.htm`, `…/Content/ss/edit_preprocess_data/visualise_data_for_quality_control/p/view_a_profile.htm`):

- Sits under the spreadsheet.
- Up to 5 panes, up to 32 profiles each.
- Each profile has the colour of its channel header.
- **Linked**: picking a value or range in the spreadsheet highlights it in the profile, and the other way round.
- Per profile options: linear, log, or log/linear scale with a log minimum; line styles, colours, symbols, grid lines, X and Y axis scale.
- **Source line: Previous, Current or Next.**
  The help shows how to set three panes to previous, current and next line, to see three survey lines at once.

## 3. How the commands work together

### 3.1 A typical airborne magnetic session

1. **New** database, or let the import create it.
2. **Import > Geosoft XYZ** (or ASCII for CSV) with a template.
   Set the coordinate system on the X and Y channels when asked.
3. Show channels in the spreadsheet, then **Show Profile** for mag, altitude and so on.
   Step through lines with Next and Previous.
4. **Save Working View** so the same channel layout can be loaded on the next database.
5. Processing from other menus.
   Each step writes new channels into the same database.
   Examples: lag correction, levelling, IGRF.
   Check each result in the profile window, often with the previous, current and next line in three panes.
6. **Save** after each major step, so **Discard Changes** can undo a bad run.
7. Gridding (Grid and Image menu) reads one channel and writes a grid.
   RTP and maps work on the grid.
8. **Export > Geosoft XYZ** or **CSV** to deliver the processed line data.
   Or **Export > Subset GDB** to cut out an area or some lines.
9. **Edit Audit Log** to note what was done.

### 3.2 Data flow and shared state

- **Templates** connect import runs.
  A template made once for a contractor's file layout imports every later flight the same way.
- **Displayed channels** link the spreadsheet to exports.
  Export XYZ, CSV, Subset, Merge and Mark can all take "displayed channels".
  So the spreadsheet layout works as a channel picker.
- **Selected lines** link line selection to processing, gridding, maps and exports.
- **Marked range** links the spreadsheet and profile to Mark export and to some tools.
- **Fiducials** link channels with different sample rates, and they drive the import Merge mode.
- **Current X and Y** link the database to mapping and gridding.
  The coordinate system is stored on the X and Y channels.

### 3.3 Links to other menus

- **Database Tools**: channel tools (re-fid, change fid), split lines (BRKLINE and others), subset, merge, window data.
- **Coordinates**: Set Current X,Y,Z and Set Coordinate System; also called at the end of an import.
- **Grid and Image**: gridding reads database channels.
- **Map**: line path plots and profiles read the database; the shadow cursor links maps back to the spreadsheet.
- **Project Explorer**: New, Open, Remove, Rename, Delete, Properties and Metadata for databases.

## 4. Fit in JuliaMag

### 4.1 Main ideas

1. **Split "Database" into three places, not one menu.**
   - The **Project Explorer** and a **Project backstage** (RustGIS's "Project" button) own the file life cycle: new, open, close, rename, remove, properties.
   - The **Database ribbon tab** owns working with line data: import, export, lines, channels, views.
   - The **Database view** (spreadsheet plus profile panes) owns cell-level actions through right-click menus.

   This follows the RustGIS guideline that the Data tab is for "looking at records, changing fields and values, and bringing data in and out".
2. **No "current database" magic.**
   Oasis acts on the current database.
   RustGIS guidelines ask for an explicit target: a chooser at the left of the tab, for example "Database: survey_2026 ▾".
   Every tool has a "line database" input that defaults to that choice.
3. **No pending-edit state.**
   Oasis keeps edits pending until Save, and Discard Changes rolls back.
   JuliaMag already has undo and job records.
   Proposal: every change is written at once (a new channel is a new file), undo covers channel edits, and re-running a job replaces or adds outputs.
   Then Save, Save As (as "save a copy"), Discard Changes and Close lose most of their role.
   This is the biggest behaviour change from Oasis.
   See open question 1.
4. **Drop the storage housekeeping.**
   New-database sizing (max lines, max channels, page size), Grow and Defragment only exist because of the `.gdb` file design.
   JuliaMag's column-per-file store needs none of them.
   Compression can be a project setting, not a per-database question (guess: Arrow with LZ4 or Zstd is enough).
5. **Import and export are pluggable units, not menu items.**
   The draft design already says this.
   The ribbon shows one "Import" split button with the common formats and "More formats…".
   Command search finds every importer by name.

### 4.2 Placement table

Abbreviations: **v1** = first version, **later**, **skip**.
"Tool" means a function plus description (gets a dialog, command id and script entry).
"Built-in" means part of the app shell or a view.

| Oasis item | JuliaMag place | Kind | Priority |
|---|---|---|---|
| New | Project Explorer right-click and backstage; mostly done by import | Built-in | v1 |
| Open | Double-click in Project Explorer opens the Database view | Built-in | v1 |
| Save, Discard Changes | Replaced by auto-commit plus undo (see 4.1 point 3) | Built-in | v1 (as undo) |
| Save As | "Save a copy" in Project Explorer right-click; or Subset with all lines | Tool | later |
| Close, Close All | Close view tabs; nothing to close in the data | Built-in | v1 |
| Import > Geosoft XYZ | Database tab > Import group; importer unit | Importer, background job | v1 |
| Import > ASCII (CSV) | Database tab > Import group; importer unit with preview dialog | Importer, background job | v1 |
| Import XYZ / ASCII templates | "Import mapping" saved in the project and as files | Built-in part of importer | v1 |
| Import > Flat Archive | Same importer as CSV, fixed-width mode | Importer | later |
| Import > Geosoft Database Merge | Database Tools tab (merge), not import | Tool, background job | later |
| Import > ASEG-GDF2 (+ Scan) | Importer unit; scan step is the preview | Importer | later (see Q6) |
| Import > Geosoft Binary (GBN) | Importer unit | Importer | later |
| Import > Database Table, ODBC | | | skip |
| Import > Blocked Binary, RMS, DAARC500, Picodas | Importer units if a user needs them | Importer | skip for now |
| Import > ASEG-ESF, AMIRA, UBC Mag3D, USGS ODDF/POST | | | skip |
| Import > MapInfo TAB/MIF, Shapefile | Map tab (vector overlays), not line data | Importer | later, other tab |
| Export > CSV etc. | Database tab > Export group; exporter unit | Exporter, background job | v1 |
| Export > Geosoft XYZ (+ template) | Database tab > Export group; exporter unit | Exporter, background job | v1 |
| Export > Parquet (not in Oasis) | Database tab > Export group | Exporter | v1 (draft has it) |
| Export > Subset GDB | Database Tools tab (subset), plus "Export selection as new database" | Tool, background job | later |
| Export > Mark | Right-click on a marked range in the Database view: "Export selection…" | Built-in, uses CSV/XYZ exporters | later |
| Export > ASEG-GDF2 | Exporter unit | Exporter | later |
| Export > GBN | Exporter unit | Exporter | later |
| Export > Shapefile, Esri Geodatabase, KML | Exporter units (line paths as GIS features); GeoPackage may replace them | Exporter | later |
| Export > Access, ASEG-ESF, ODDF, POST | | | skip |
| Save Working View, Get Saved View | Named "layouts" in the Database view: channels, order, profile panes | Built-in | v1 (small) |
| Edit Audit Log | The draft's free-text description in Properties | Built-in | v1 |
| Metadata and lineage | Job records already give lineage; show them in Properties | Built-in | v1 (from jobs) |
| Maintenance > Defragment, Grow | Not needed | | skip |
| Properties | Project Explorer properties pane | Built-in | v1 |
| Settings > GDB shortcut keys | App-wide shortcut settings, as in RustGIS | Built-in | later |

### 4.3 Suggested Database ribbon tab

This is a proposal, sized for a first version.
Group and button names are guesses to discuss.

- **Target** (left edge): "Database: <name> ▾" chooser, as the RustGIS guidelines plan.
- **Import**: big split button "Import" (default: Geosoft XYZ…), arrow lists CSV…, and later ASEG-GDF2…, GBN….
  A small "Import Mappings" button manages saved mappings.
- **Export**: big split button "Export" (default: CSV…), arrow lists Geosoft XYZ…, Parquet…, later ASEG-GDF2….
- **Lines**: Previous, Next, Go To…, Select Lines… (selection tool by type, flight, direction, name), Select All, Select None.
- **Channels**: Show Channels… (pick from a list), Hide All, New Channel…, Edit Channel…, Delete Channel, Protect.
- **View**: Open Database View, Add Profile Pane, Layouts ▾ (save, load), Sync Cursor With Map (toggle).

Each button is a command with an id, for example `db.import.xyz`, `db.export.csv`, `db.line.next`, `db.channel.new`, `db.layout.save`.
Line and channel commands also appear in the right-click menus of the Database view, with the same names and icons.
"View > Windows" in the ribbon must still list the Database view, per the RustGIS rule that every pane is reachable there.

### 4.4 Where the GIS-style structure helps more than a copy

- **One import entry point.**
  Oasis has twenty import items in a submenu.
  A single Import button with a format list, plus drag-and-drop of files onto the Project Explorer, is simpler.
  Oasis already supports dropping XYZ files onto an open database (`…/Content/ss/import_data/import_file_types/c/importing_overview.htm`).
  JuliaMag can detect the format from the file and open the right importer.
- **Import mode as a clear choice, not a hidden default.**
  Oasis has different defaults per importer (XYZ: Replace, ASCII: Append).
  JuliaMag should show the same three or four modes in every line importer, with one default.
- **Channel picker instead of "displayed channels".**
  Oasis uses the spreadsheet layout as a channel picker for exports.
  This is fast for experts but hidden.
  JuliaMag export dialogs should have a channel list, with a "Use channels shown in the view" button as a shortcut.
- **Selected lines as a visible filter.**
  Oasis stores line selection in the database and many tools use it silently.
  JuliaMag can keep that model (it is how Oasis users think), but show "Lines: 112 of 140 selected" in the tool dialog and the status bar.
- **Linked cursor and selection across views.**
  Oasis links the spreadsheet, the profile and the maps.
  In JuliaMag this should be shared app state ("current line and fiducial", "marked range"), so the Database view, profile panes and map view all follow it.
  It is cheap if designed in early, and expensive to add later.

### 4.5 Changes this suggests to the draft design

1. **Fiducials per channel, not per line.**
   The draft says "each line stores a fiducial start and step".
   In Oasis each channel on each line has its own start and increment.
   Recommendation: store start and increment per (line, channel), with the line value as the default.
   Lag correction can then shift a channel by changing its start only, without touching the data (this is a guess about how JuliaMag might do it, not something seen in the help).
   The Database view and profile then need Oasis's display rule: show all channels at the smallest increment from the lowest start, plus an optional "master sample" channel.
2. **Line identity.**
   Add line type (L, T, B, S, R, P, D), number, version, flight, date and a selected flag.
   Make (type, number, version) unique.
   The draft only names `Line` and `Tie` markers.
   The help does not list which XYZ header words map to which type; the reader should accept at least `Line` and `Tie`, and the other words are a guess to check against real files.
3. **Line selection state** is part of the database and is the default line set for tools and exports.
4. **Channel attributes.**
   Add label (the original name when the import had to clean it), units, class, protected flag, display format, width and decimals.
   Imported channels start protected.
   Channel names follow the Oasis rule (letter or `_` first, no spaces), and the raw header goes into the label.
5. **Dummy values.**
   In memory, use `NaN` for floats (guess, it is the natural Julia choice).
   For integer channels, keep the Oasis dummy per type, so XYZ and GBN round trips stay exact.
   Readers must accept a dummy string per column (default `*`).
6. **Import into an existing database, with import modes.**
   The draft treats import as "file in, new item out".
   Oasis users often import new flights into an existing database.
   Add modes Replace and Append (new version) for v1; Merge Append and Merge (by fiducial) later.
7. **Multi-file import** with one mapping, one job, and one log of warnings with file name and line number.
8. **CSV line rules.**
   The CSV importer needs three ways to make lines: a line column, one line per file, or a single line.
   The draft mentions "a rule to split into lines"; Oasis's rules are these three, plus splitting later in Database Tools.
   Also offer flight and date columns, a fiducial column, a units row, a first-data row, and unit scale and offset (from the `.i3` `scale` and `base`).
9. **Time and date columns.**
   Oasis reads many date and time text forms and ISO 8601.
   JuliaMag should parse them on import into one numeric time channel (guess: Float64 seconds since an epoch, with the epoch stored as channel metadata).
10. **XYZ header rule.**
    Use the Oasis rule for channel names: the last `/` comment line whose name count equals the column count.
    Also read `//Flight` and `//Date` anywhere, applying to following lines.
11. **Read Oasis templates (optional).**
    Users may have many `.i0` and `.i3` templates.
    Reading them into a JuliaMag import mapping would ease the switch.
    See open question 3.
12. **Coordinate system on X and Y channels.**
    Oasis stores the coordinate system on the X and Y channels, and has "current X, Y" per database.
    The draft stores a coordinate system per item.
    Suggest: per database "current X, Y" channel names, and the coordinate system attached to that pair.
    Then a database with both lat/lon and projected channels works.
13. **Export options.**
    CSV export should offer: channels (list or "shown in view"), lines (current, selected, all), include dummies, header row, line name column.
    XYZ export should offer: max line length, resample increment, include comment and line headers, comma or space separated.
14. **Database view layouts.**
    Save and load named layouts (channel list, order, profile panes).
    Small feature; Oasis users rely on it.

## 5. Open questions for the user

1. **Save model.**
   Oasis keeps edits pending until Save and can Discard Changes.
   Is auto-commit plus undo (and job re-run) enough, or do you want an explicit Save / Discard for databases?
2. **Fiducials per channel.**
   Do your files ever mix sample rates on one line (for example 10 Hz mag and 1 Hz GPS)?
   If yes, per-channel fiducials are needed in v1.
3. **Oasis templates.**
   Do you have `.i0` or `.i3` templates you want JuliaMag to read?
4. **Import into existing databases.**
   Do you import several flights into one database over time?
   Which modes do you use: Replace, Append (new version), Merge Append, Merge on fiducial?
5. **Line header words in your XYZ files.**
   Do they use only `Line` and `Tie`, or also `Trend`, `Test`, `Base`, `Random`, or other words?
   Can you share one file of each kind for tests?
6. **ASEG-GDF2 and GBN.**
   Do you receive data in ASEG-GDF2 (common for government and contractor deliveries) or GBN?
   If yes, should either move to v1?
7. **Array channels.**
   Do any of your mag files have array data (for example several sensors as one array), or can array import wait?
8. **Line selection.**
   Do you want the Oasis model (selection stored in the database and used by all tools), or a per-tool line filter?
9. **Linked cursor.**
   Is the shadow cursor (spreadsheet and profile linked to the map) part of how you check data today?
   If yes, it should be in v1.
10. **Exports for GIS.**
    Do you need line paths as Shapefile, GeoPackage or KML?
    If yes, which one first?
