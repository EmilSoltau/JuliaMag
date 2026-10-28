# Oasis montaj Coordinates menu - research for JuliaMag

Source: Oasis montaj 2025.1 online help, read on 2026-10-28.
The menu tree comes from the help's own table of contents (`Data/Tocs/geohelp.js`), section "Menus > Coordinates".
All help links below start with `https://help.seequent.com/Oasismontaj/2025.1/Content/`.
Short form in the tables: `gxhelp/x/xyset_gx.htm` means `https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/x/xyset_gx.htm`.

Marking used in this note:

- **(help)** means the help page says it.
- **(guess)** means it is my reading or a suggestion, not something the help says.

## 1. Overview

### What the menu is for

The Coordinates menu works on the position channels of a line database.
It answers four questions:

1. Which channels hold the position? (Set Current X,Y,Z)
2. What coordinate system are those numbers in? (Set Coordinate System, Determine UTM Zone)
3. How do I get the positions into another system? (New Projected Coordinate System, Translate, Rotate, Georeferencing, Long,Lat to Local X,Y)
4. How do I repair or add to the positions? (Interpolate X,Y, Differential GPS, Geoid Height)

The help calls this step "Resolve Data Positioning".
It says it is "the second major step in the Oasis montaj data processing sequence", right after import (help: `ss/process_data/resolve_data_positioning/define_modify_map_projections/c/introduction_to_map_projections.htm`).

Almost every command takes a database channel pair as input and writes a channel pair as output.
Only three commands touch grids (Warp a Grid, Attach Warp to Grid, and Geoid Height, which reads a geoid grid).
One command (Design Survey) creates a new database from scratch.

### Key ideas from the help

- **A coordinate system belongs to a channel pair, not to the database.** (help)
  One database can hold a Lat/Long pair in WGS 84 and an X/Y pair in UTM, each with its own coordinate system.
  Oasis stores it in a side file (`*.gi`) next to the data.
- **"Current" X, Y and Z channels.** (help)
  Each database marks one channel pair (and an optional Z) as the current position.
  "All Geosoft core GXs" use these channels whenever a tool needs positions but does not ask for them.
  The spreadsheet shows small "x", "y", "z" markers in the channel headers.
  If nothing is set, Oasis assumes the channels are named "X", "Y" and "Z".
- **The coordinate system flows downstream.** (help)
  "In most cases, all that is required is to define the coordinate system of the X and Y channels of an original database.
  This coordinate system will then be passed on to grids when data is gridded, and map views will inherit this coordinate system when they are created."
- **On-the-fly display.** (help)
  Maps reproject data and grids as they draw them ("smart projections").
  A grid keeps its own coordinate system; only the display changes.
- **Unknown is a valid state.** (help)
  If the user sets nothing, Oasis assumes all X,Y data is in "the same, unknown map coordinate system".
- **One shared Coordinate System dialog.** (help)
  The same wizard is used for database channels, grids, map views and other files.
  It has EPSG search, favourites, a tree by country, Esri tables, custom projections and custom datum transforms.

### Where it sits in the airborne magnetic workflow

| Step | Uses the Coordinates menu how |
|---|---|
| Import | Positions arrive as GPS longitude/latitude (WGS 84), and often also as projected X/Y. Import alone does not attach a coordinate system in Oasis; Set Coordinate System does. |
| Positioning | Assign the coordinate system, project Lat/Long to UTM (or a national grid), set the current X/Y, fill GPS dropouts. |
| Lag correction | Not in this menu. Lag shifts channels along the line; positions must be clean first. |
| Levelling | Not in this menu. It finds line and tie crossings from the current X/Y, so the positions must be final and projected (guess: the help pages read do not say this directly). |
| IGRF removal | Not in this menu. IGRF needs longitude, latitude, height and date, so the geographic pair should be kept next to the projected pair (guess). |
| Gridding | Not in this menu. The grid takes the coordinate system of the database X/Y channels (help). |
| RTP | Not in this menu. It needs field inclination and declination for the area, which come from geographic position (guess). |
| Maps | Not in this menu. The map view inherits the coordinate system and can draw data in other systems on the fly (help). |
| Heights | Geoid Height turns GPS ellipsoid heights into heights above the geoid, by subtracting the geoid height channel (help). |

## 2. Command inventory

### Menu tree

```
Coordinates
  Set Current X,Y,Z
  Backup Current X,Y
  Restore X,Y
  Determine UTM Zone
    (Statistics window)
  Set Coordinate System
    (opens the Coordinate System wizard)
  New Projected Coordinate System
  Translate Coordinates
  Rotate Coordinates
  Interpolate X,Y
  Georeferencing
    Define a Warp
    Warp Data
    Warp a Grid
    Attach Warp to Grid
    Long,Lat to Local X,Y
    Local X,Y to Long,Lat
  Differential GPS
    Load GPS Based Data
    Fill GPS Gaps
  Geoid Height
  Design Survey
```

The shared Coordinate System wizard is listed in the help under "Tools > Coordinate System".
It is not a menu item, but most commands here open it, so it is described too.

### 2.1 Set Current X,Y,Z (XYSET GX)

- **Does:** picks which channels are the current X (Easting), Y (Northing) and optional Z (Elevation).
- **Inputs:** the open database; three channel names.
- **Outputs:** no data change. The database remembers the roles, and the channel headers show x/y/z markers.
- **Settings:** `SETXY.X`, `SETXY.Y`, `SETXY.Z` (Z may be "(none)").
- **Notes:** all core tools use these channels when they need positions. Defaults are "X", "Y", "Z". Z is mostly used for drillholes.
- **Help:** `gxhelp/x/xyset_gx.htm`, concept page `ss/edit_preprocess_data/view_edit_spreadsheet_data/manipulate_spreadsheet_channels/c/current_x_and_y_channels.htm`

### 2.2 Backup Current X,Y (XYSAVE GX)

- **Does:** copies the current X and Y channels into backup channels `_X` and `_Y`.
- **Inputs:** the open database.
- **Outputs:** channels `_X`, `_Y`.
- **Settings:** none.
- **Notes:** meant to be used before a rotation, projection or translation, "in case of errors or for future reference".
- **Help:** `gxhelp/x/xysave_gx.htm`

### 2.3 Restore X,Y (XYGET GX)

- **Does:** overwrites the current X and Y with the backup channels `_X` and `_Y`.
- **Inputs:** the open database with `_X`, `_Y`.
- **Outputs:** X and Y are replaced.
- **Settings:** none.
- **Notes:** this is Oasis's undo for coordinate transforms.
- **Help:** `gxhelp/x/xyget_gx.htm`

### 2.4 Determine UTM Zone (LLToUTMZone, a .NET GX)

- **Does:** computes the UTM zone for every sample from a longitude channel, and the hemisphere from a latitude channel.
- **Inputs:** longitude channel (default: current X); optional latitude channel (default: current Y); line selection (all, selected, displayed).
- **Outputs:** a new channel of zone numbers 1 to 60 with an N or S label; then a Statistics window.
- **Formula (help):** `UTM_Zone = INT(Longitude/6 + 31)`.
- **Edge rules (help):** longitude outside -180..180 gives an empty value. No latitude channel means "N" everywhere. A dummy latitude takes the hemisphere of the last valid one.
- **Statistics window:** database name, channel, lines used, number of items, valid items, dummies, and a table of zone vs percent of samples. A "Save Stats" button writes it to a text file.
- **Help:** `gxhelp/c/geosoft_gx_coordsyswizard_lltoutmzone.htm`, `gxhelp/c/geosoft_gx_UTMStatistics.htm`

### 2.5 Set Coordinate System (SETCHPRJ GX)

- **Does:** assigns a coordinate system to an X/Y channel pair. It does not change the numbers.
- **Inputs:** X channel, Y channel.
- **Outputs:** the coordinate system is stored for the pair. Optionally the pair becomes current (`SETCHPRJ.SETCURRENTXY`, default Yes).
- **Settings:** a "Coordinate System" button opens the shared wizard (2.16).
- **Scripting:** the coordinate system is given by `IPJ.NAME` (EPSG style name), `IPJ.DATUM`, `IPJ.METHOD`, `IPJ.UNITS`, `IPJ.LOCALDATUM`, in GXF revision 3 form.
- **Help:** `gxhelp/s/setchprj_gx.htm`, how-to `ss/process_data/resolve_data_positioning/define_modify_map_projections/c/defining_the_projection_of_database_channels.htm`

### 2.6 New Projected Coordinate System (NEWXY GX)

- **Does:** computes a new coordinate pair in another coordinate system from an existing pair. This is the real reprojection command.
- **Steps (help, a 4-page wizard):**
  1. Pick the input pair (normally X and Y) and all lines or selected lines.
  2. Check or set the coordinate system of the input pair. If it is unknown, the user must set it here.
  3. Name the output pair. It may be new channels or other existing channels, but not the input channels. Existing channels trigger an overwrite prompt.
  4. Pick the output coordinate system in the shared wizard.
- **Outputs:** the new channel pair, with its coordinate system attached.
- **Notes (help):**
  - If only selected lines are processed, the output channels are still assumed to be all in the new system.
  - It no longer transforms elevations. Use Geoid Height for that.
  - It does not change the current X/Y. The user runs Set Current X,Y,Z after.
  - Also used to remove a warp: attach the warp to the original pair, then make a new unwarped pair.
- **Help:** `gxhelp/n/newxy_gx.htm`

### 2.7 Translate Coordinates (XYTRNS GX)

- **Does:** shifts and scales coordinates: `X = (X - X0) * SCALE`, `Y = (Y - Y0) * SCALE`.
- **Inputs:** X channel, Y channel; new origin X0, Y0; scale factor.
- **Outputs:** the input channels are overwritten in place.
- **Notes (help):** if the channels are named "X" and "Y", Oasis first copies them to `_X` and `_Y`, but only if both do not exist yet.
- **Help:** `gxhelp/x/xytrns_gx.htm`

### 2.8 Rotate Coordinates (XYROTATE GX)

- **Does:** rotates coordinates counter-clockwise by an angle around a point.
- **Inputs:** X channel, Y channel; angle in degrees CCW; centre X0, Y0.
- **Outputs:** the input channels are overwritten in place, with the same `_X`/`_Y` backup rule as Translate.
- **Formula as printed in the help:** `X = X cos(q) - Y sin(q) + X0`, `Y = X sin(q) + Y cos(q) + Y0`.
  As printed, it rotates around the origin and then adds X0, Y0 (guess: the help formula may be simplified; this needs a test against Oasis before copying it).
- **Help:** `gxhelp/x/xyrotate_gx.htm`

### 2.9 Interpolate X,Y (XYFILL2 GX)

- **Does:** fills dummy (missing) values in an X/Y pair.
- **Inputs:** X channel, Y channel; fill method; fill the edges yes/no.
- **Methods (help):** Linear, Minimum Curvature (smoothest, may overshoot), Akima (smooth, stable with noise), Prediction (maximum entropy; keeps the noise character, can make line ends continuous for FFT).
- **Outputs:** the filled channels (guess: in place; the page does not name output channels).
- **Notes (help):** it interpolates against the fiducial only. It is the coordinate version of Database Tools > Interpolate (INTERP GX).
- **Help:** `gxhelp/x/xyfill2_gx.htm`, concept page `ss/process_data/resolve_data_positioning/c/interpolating_data.htm`

### 2.10 Georeferencing > Define a Warp (WARPFILE GX)

- **Does:** makes a warp file (`.wrp`) from control points (old position to new position).
- **Inputs:** output file name; warp type; definition mode.
- **Warp types (help):** 1-point (shift), 2-point (shift, scale, rotate), 3-point (scale X and Y apart, rotate), 4-point quadrilateral (points must go round in order), multipoint (2 to 1000 points, exact at every point, uses a TIN with four far boundary nodes).
- **Modes (help):** Interactive (click old and new points on the current map), Semi-interactive (click old, type new), Manual (type both; the only mode allowed in scripts).
- **Outputs:** the `.wrp` file. Temporary marks on the map while picking.
- **Notes (help):** the multipoint warp only works within about 2.5 times the spread of the control points.
- **Help:** `gxhelp/w/warpfile_gx.htm`, concept `ss/process_data/resolve_data_positioning/apply_warping_to_data/c/warping_data_and_grids.htm`

### 2.11 Georeferencing > Warp Data (WARPDATA GX)

- **Does:** applies a warp file to an X/Y pair and writes a new pair.
- **Inputs:** input X/longitude and Y/latitude channels; `.wrp` file; output channel names.
- **Outputs:** the new pair, which carries the warp as its "projection".
- **Notes (help):** existing output channels are not recreated, so unselected lines keep old values, which may then be in the wrong place because one pair can only have one projection.
- **Help:** `gxhelp/w/warpdata_gx.htm`

### 2.12 Georeferencing > Warp a Grid (WARPGRID GX)

- **Does:** writes a new grid warped by a `.wrp` file.
- **Inputs:** input grid; `.wrp` file; output grid; optional new cell size (default keeps about the same cell count).
- **Outputs:** a new grid. A second page shows the new grid's properties.
- **Notes (help):** "very memory intensive"; meant for images where pixel values matter.
- **Help:** `gxhelp/w/warpgrid_gx.htm`

### 2.13 Georeferencing > Attach Warp to Grid (WARPGRDA GX)

- **Does:** attaches a warp to a grid so it is warped on the fly when drawn. No new grid.
- **Inputs:** grid or image file; `.wrp` file.
- **Notes (help):** use it only when the grid is too big to rewrite, usually a large compressed image.
- **Help:** `gxhelp/w/warpgrda_gx.htm`

### 2.14 Georeferencing > Long,Lat to Local X,Y (LL2XY GX) and Local X,Y to Long,Lat (XY2LL GX)

- **Does:** converts between longitude/latitude and a local survey grid, and back.
- **Inputs:** longitude and latitude channels; local X and Y channels; one tie point known in both systems (its longitude, latitude, local X, local Y); length units (m or ft); azimuth of the local Y axis from true north.
- **Method (help):** project to Transverse Mercator with a central meridian through the tie point, then rotate to the given azimuth.
- **Outputs:** the new channel pair.
- **Notes (help):** both commands share the same script parameters, so the inverse needs no new settings.
- **Help:** `gxhelp/l/ll2xy_gx.htm`, `gxhelp/x/xy2ll_gx.htm`

### 2.15 Differential GPS > Load GPS Based Data (GPSLOAD GX) and Fill GPS Gaps (GPSGAP GX)

- **Load does:** looks up corrected GPS positions from a Geosoft table file (Date, Time, X, Y, Alt) by time, and writes them to new channels.
- **Load inputs:** GPS table; flight number (blank means use Date and Time); time channel; lookup tolerance in seconds; output longitude, latitude, altitude channel names.
- **Fill does:** fills gaps in the differential channel with the raw GPS channel, assuming the raw error drifts linearly through the gap.
- **Fill inputs:** differential channel, raw channel, output channel.
- **Notes:** the help describes the C3Nav and `C3N2TBL` workflow and GPS "intentional signal degradation".
  That degradation (Selective Availability) was switched off in 2000, so this is a legacy workflow (guess: my knowledge, not from the help).
- **Help:** `gxhelp/g/gpsload_gx.htm`, `gxhelp/g/gpsgap_gx.htm`

### 2.16 Geoid Height (GEOID GX)

- **Does:** makes a channel of geoid height above the GRS80 ellipsoid, by sampling a geoid grid at each X/Y.
- **Inputs:** X and Y channels (geographic, or projected with a defined coordinate system); geoid model from a built-in list, or "Other grid" (any grid with a coordinate system, values in metres above GRS80).
- **Outputs:** channel `GeoidHeight` (default name).
- **Notes (help):**
  - Subtract it from a GPS (ellipsoid) elevation to get elevation above the geoid.
  - Built-in models include NGS models for North America and AUSGeoid2020; EGM2008 is downloaded via Seeker from the public DAP server.
  - It handles grids in 0..360 longitude vs data in -180..180.
  - It warns if the data does not overlap the model.
  - "Particularly important in the gravity workflow."
- **Help:** `gxhelp/g/geoid_gx.htm`

### 2.17 Design Survey (Geochemistry DesignSurvey, a .NET GX)

- **Does:** creates a new database of planned sample stations for a ground geochemical survey.
- **Inputs:** dataset name; extents (polygon file or a box); start point; coordinate system (projected only); number of lines, line azimuth, line spacing, first line number, line number step, alternate directions; sample spacing, first sample number; optional QA/QC samples.
- **Outputs:** a new database with lines, coordinates and sample numbers.
- **Help:** `gxhelp/d/geosoft_gx_geochemistry_designsurvey.htm`

### 2.18 The shared Coordinate System wizard (not a menu item)

Opened from Set Coordinate System, New Projected Coordinate System, grid properties, map views and import tools.

- **Coordinate System page** (`gxhelp/c/geosoft_gx_coordsyswizard_select.htm`):
  - Shows the source (channel pair or file), well-known ID (EPSG name), type (Geographic, Projected, Unknown), datum, local datum transform, projection method, length units.
  - "Details" lists all parameters. A reset button undoes changes.
  - Search box: several words, all must match; searches names, EPSG/Esri IDs, area of use, zone; case-insensitive; stops expanding the tree after 100 hits.
  - Tree with three roots: Favourites, Geographic, Projected. Each is ordered by country, "because you always know the location of the survey by country".
  - Buttons: Modify, Copy from, Copy to, Add/Remove Favourites, Show Esri.
- **Modify Coordinate System** (`gxhelp/c/geosoft_gx_coordsyswizard_coordsyswizardmain.htm`): pick type, projection method (EPSG and Esri lists, plus custom), datum, local datum transform, units, plus orientation settings. Custom entries get a `*` prefix.
  - **New Projection Method** (`gxhelp/c/geosoft_gx_coordsyswizard_newpcs.htm`): name, units, projection type and its parameters. Warns if it is almost the same as an existing one.
  - **New Custom Local Datum Transform** (`gxhelp/c/geosoft_gx_coordsyswizard_newLDT.htm`): area-of-use text, dX/dY/dZ, rotations, scale in ppm. Saved to the user's CSV tables.
- **Copy Coordinate System From** (`gxhelp/c/geosoft_gx_coordsyswizard_copyfrom.htm`): from a database channel, grid, voxel, Geosoft or Esri `.prj`, warp, polygon, or GMSYS model. If the target must be geographic, the projection part is dropped.
- **Copy Coordinate System To** (`gxhelp/c/geosoft_gx_coordsyswizard_copyto.htm`): to an Esri `.prj`, database, grid, voxel, polygon.
- **Geographic Coordinate Systems Transformation** (`gxhelp/d/geosoft_gx_datumreprojection_datumreprojection.htm`): asks which datum transform to use when an ArcGIS layer or shapefile with another datum is added to a map.
- **Datum transforms (help):** 7-parameter Bursa-Wolf (and 3-parameter Molodensky), always via WGS 84; or correction grids (NADCON, NTv2, OSTN15, GDA2020). The help stresses that a local datum transform is a hint for converting, not part of the coordinate system.
- **Tables (help):** all definitions live in CSV files (`datum.csv`, `datumtrf.csv`, `ldatum.csv`, `ellipsoid.csv`, `ipj_pcs.csv`, `area_of_use.csv`, `datum_alias.csv`), updated yearly from EPSG.
- Concept pages: `ss/om_reference/common_reference/maps_groups_coordinate_systems/map_projections.htm`, `ss/process_data/resolve_data_positioning/define_modify_map_projections/r/spheroids_vs_datums.htm`.

## 3. How the commands work together

### Typical airborne magnetic sequence (positions)

1. Import the XYZ or CSV file (Project or Database menu).
2. **Set Coordinate System** on the GPS Long/Lat pair: WGS 84 geographic.
3. **Determine UTM Zone** if the zone is not known, or the survey may cross a zone edge.
4. **New Projected Coordinate System**: Long/Lat (WGS 84) to X/Y (for example WGS 84 / UTM 33N).
5. **Set Current X,Y,Z** to the new X/Y pair (NEWXY does not do it).
6. **Interpolate X,Y** to fill GPS dropouts.
7. Optional: **Geoid Height**, then subtract it from the GPS height (Database Tools math) to get height above sea level.
8. Then lag correction, levelling, IGRF, gridding, maps, all reading the current X/Y.
   The grid and the map view take over the coordinate system of the database pair (help).

### Data flow between commands

- Set Coordinate System writes metadata only. NEWXY reads it. If it is missing, NEWXY asks for it.
- NEWXY, Warp Data and LL2XY write a new channel pair. Set Current X,Y,Z decides which pair the rest of the system uses.
- Translate and Rotate overwrite in place. Backup and Restore exist mainly to make them reversible.
- Define a Warp writes a `.wrp` file. Warp Data, Warp a Grid, Attach Warp and Copy From read it.
- Load GPS Based Data writes differential channels. Fill GPS Gaps reads them with the raw channel.
- Geoid Height reads a grid (the geoid model) and the database positions, and writes one channel.

### Links to other menus

- **Database Tools:** Interpolate (INTERP GX) is the general version of Interpolate X,Y. Channel math is used to subtract the geoid height.
- **Grid and Image:** "Modify Coordinate System for Grid File(s)" (`gxhelp/s/setimgprj_gx.htm`) is the grid version of Set Coordinate System. "Grid UTM Zone" (`gxhelp/g/geosoft_gx_gridutils_gridUTMzone.htm`) is the grid version of Determine UTM Zone. Grid Properties also opens the Coordinate System wizard. Gridding copies the database pair's coordinate system to the grid.
- **Map Tools:** New Map from X,Y scans the database or grid for range and coordinate system. Map views have their own coordinate system (right-click > Coordinate System). Base maps draw longitude/latitude annotations only if the view has a coordinate system.
- **Spreadsheet:** shows the current x/y/z markers in channel headers.

## 4. Fit in JuliaMag

### Main structural points

1. **Model coordinates as "position pairs" in the line database (affects the draft).**
   Oasis attaches a coordinate system to a channel pair, and keeps one pair "current".
   The draft says "the user sets the coordinate system on import (EPSG code)" and "data is stored in its own coordinate system", which reads as one system per database.
   Airborne files nearly always carry both GPS Long/Lat and projected X/Y, and IGRF needs the geographic pair while levelling and gridding need the projected one (guess on the IGRF and levelling needs).
   Suggestion: a line database holds a small list of position pairs `(x_channel, y_channel, crs)`, plus an optional Z channel, and one pair is marked current.
   Tools that need positions read the current pair unless the user picks another one.
   This replaces Set Current X,Y,Z as a tool, and it keeps the draft's "one channel per file" storage unchanged.

2. **Assign is not reproject. Make that clear in the UI.**
   Oasis splits them into two commands (Set Coordinate System vs New Projected Coordinate System), but users still mix them up (guess).
   JuliaMag should call them "Assign coordinate system" (metadata, instant, undoable) and "Reproject positions" (computes new channels, a tool).

3. **One shared CRS picker widget.**
   Oasis uses one wizard everywhere.
   JuliaMag should have one CRS picker used by import, the properties pane, the reproject tool, gridding, and the map view.
   RustGIS already has a "Coordinate System" dialog with presets, an "EPSG or ESRI code" box and a details pane (`crates/ui-egui/src/dialogs.rs`, `fn coordinate_system`); copy its layout.
   Add from Oasis: free-text search over name, code and area of use; Favourites (or "recent"); grouping by country.
   PROJ's own database has names, codes and areas of use (guess: check that Proj.jl exposes `proj_get_crs_info_list_from_database`, or call it through the C API).
   The tool description system should get a setting type `crs`, so any tool can ask for one and get this widget for free.

4. **No Backup/Restore. Use job history and undo.**
   The draft already says tools make new items by default and record the job that made them.
   For position tools, that means: write a new pair, keep the old pair, and switch "current" as a project change that undo can reverse.
   Translate and Rotate should not overwrite in place by default; the "replace old output" option in the draft covers users who want that.

5. **Determine UTM Zone belongs inside the CRS guess.**
   The draft already promises "a sensible guess" of the coordinate system on import.
   The UTM formula and the zone statistics (percent per zone) are exactly what that guess needs.
   Show the result in the import dialog ("data spans 32N 85 %, 33N 15 %") and suggest the main zone's EPSG code.

6. **Coordinate system flows downstream.**
   Gridding should copy the CRS of the input pair to the grid; a new map should take the CRS of the first item added.
   Add this rule to the draft (section 9, "Map view layers") so it is a design rule, not a builder choice.

7. **Grid CRS handling stays as the draft says.**
   Oasis draws grids in another CRS on the fly.
   The draft chose to not draw them and warn instead.
   That is fine for a first version; note that Oasis users will expect on-the-fly grids later.

### Placement table

Columns: where it goes; tool (function plus description) or built-in view/command; priority (V1 = first version, Later, Skip).

| Oasis command | JuliaMag place | Kind | Priority | Why |
|---|---|---|---|---|
| Set Current X,Y,Z | Database properties pane ("Positions" section), plus a context menu on channel headers in the database view ("Use as X / Y / Z") | Built-in command, undoable | V1 | It is a property, not processing. A context menu on the channel header is faster than a dialog. Show x/y/z markers in headers like Oasis. |
| Backup Current X,Y | none | none | Skip | Replaced by new-output-by-default, job history and undo. |
| Restore X,Y | none | none | Skip | Same as above. |
| Determine UTM Zone | Import dialog (CRS guess); also Coordinates tab > Coordinate system group as a small tool | Built-in in import; tool for the channel output | V1 (in import), Later (as tool) | The guess needs it now. A per-sample zone channel is rarely needed. |
| Determine UTM Zone > Statistics | Shown in the import dialog and in the tool's result panel | Built-in view | V1 (in import) | Zone percentages are the useful part. |
| Set Coordinate System | Import dialog; database properties pane; Coordinates tab > Coordinate system > "Assign" | Built-in command, undoable | V1 | Needed before anything can be reprojected or drawn together. |
| Coordinate System wizard | Shared CRS picker widget and `crs` setting type | Built-in view | V1 (search, EPSG/WKT/PROJ code, details); Later (favourites, country tree) | Every CRS choice goes through it. |
| Modify CS, New Projection Method, New Custom LDT | CRS picker > "Custom..." (WKT or PROJ string editor) | Built-in view | Later | PROJ accepts WKT and PROJ strings, so a text box covers custom systems at first. A form editor can come later. |
| Copy From / Copy To | CRS picker: "Same as..." list of project items; "Export .prj" in the properties pane | Built-in | V1 (Same as project item), Later (.prj files) | In a project, picking another item is simpler than browsing files. |
| Geographic CS Transformation (datum choice) | CRS picker / reproject tool: "Datum transformation" setting, default "best available" | Setting | Later | PROJ picks a transformation by itself; expose an override only when users need it. |
| New Projected Coordinate System | Coordinates tab > Coordinate system > "Reproject positions" | Tool, background job | V1 | Core of the positioning step. Output: a new position pair with its CRS; option "make current" (default yes, unlike Oasis, guess). |
| Translate Coordinates | Coordinates tab > Transform > "Shift and scale" | Tool, quick | Later | Rare in airborne mag. Write a new pair, mark its CRS as "local / derived" (guess). |
| Rotate Coordinates | Coordinates tab > Transform > "Rotate" | Tool, quick | Later | Same. Could share one "Affine transform" tool with Translate (guess, a suggestion). |
| Interpolate X,Y | Coordinates tab > Repair > "Fill position gaps" | Tool, quick or job | V1 or early Later | GPS dropouts are common. Share the code with Database Tools > Interpolate; this is the same tool run on a pair. |
| Define a Warp | Map view interaction ("Pick control points") plus a warp item in the project | Tool with a map interaction mode | Later | Needs click-to-pick on the map. Store the warp as a project item, not a loose `.wrp` file. |
| Warp Data | Coordinates tab > Georeference | Tool, background job | Later | Mostly for old data in local grids. |
| Warp a Grid | Grid and Image tab or Coordinates tab > Georeference | Tool, background job | Later | Rare for magnetic grids; used for scanned maps. |
| Attach Warp to Grid | none | none | Skip | Exists to avoid rewriting huge compressed images; memory-mapped grids make this less needed (guess). |
| Long,Lat to Local X,Y / Local X,Y to Long,Lat | A "local grid" CRS type in the CRS picker (tie point, azimuth, units), then normal "Reproject positions" | CRS definition, not a tool | Later | It is a Transverse Mercator plus rotation, so it can be a custom CRS (guess: PROJ can express it as a pipeline or an Oblique Mercator/affine). Then both directions are free. |
| Load GPS Based Data | none (or a generic "join table by time" in Database Tools) | none | Skip | Legacy C3Nav workflow. Modern data arrives already corrected (guess). |
| Fill GPS Gaps | Coordinates tab > Repair | Tool, quick | Later | Small and useful when a differential and a raw channel both exist. |
| Geoid Height | Coordinates tab > Heights > "Geoid height" | Tool, background job | Later | Not needed for the first magnetic steps; useful for terrain clearance and gravity. PROJ geoid grids (for example EGM2008) could replace Oasis's bundled grids (guess). |
| Design Survey | none | none | Skip | Ground geochemistry sampling plans. A flight-line planner would be a different tool. |

### Suggested Coordinates tab (guess)

Groups, in work order:

1. **Coordinate system:** Assign, Reproject positions, Find UTM zone.
2. **Repair:** Fill position gaps, Fill GPS gaps.
3. **Transform:** Shift and scale, Rotate (later).
4. **Georeference:** Define warp, Warp data, Warp grid (later).
5. **Heights:** Geoid height (later).

"Set current X,Y,Z" lives in the database properties pane and the channel header context menu, not on the ribbon.
It can still have a command id (for command search and scripts), as every built-in command does in the draft.

In the first version the tab would hold only Assign and Reproject (plus Fill position gaps if it is ready).
The draft hides empty tabs, so a thin tab is fine.
An option is to put these two on the Database tab until the Coordinates tab has more tools (guess, the user's choice).

### Other UI ideas from the GIS side (guess)

- **Status bar:** show the cursor position in the map CRS and in longitude/latitude, and the map CRS name; click it to open the CRS picker. RustGIS has a map CRS readout to start from.
- **Data pane badge:** show each item's CRS (short EPSG code) next to its name, and a warning icon for "Unknown".
- **Layers pane:** a layer whose CRS differs from the map is reprojected on the fly; show a small "reprojected" marker so the user knows.

### Changes this suggests to the draft design

1. Section 4.1 "Coordinate systems": a database has several position pairs, each with its own CRS; one pair is current; an optional Z channel role.
2. Section 4.1: the import CRS guess uses the UTM zone formula and shows zone percentages.
3. Section 4.2: add a `crs` setting type, and a "position pair" input type (defaults to the current pair).
4. Section 9 "Map view layers": the CRS flows from the database pair to grids made from it, and from the first item to a new map.
5. Section 9: position tools write new pairs and switch "current" as an undoable project change; no `_X`/`_Y` backups.
6. Coordinates tab first version: Assign coordinate system and Reproject positions are needed early, even though section 6 lists processing steps as non-goals.
   Without them, Long/Lat files cannot be shown with projected grids, and the gridding step later has nothing to inherit.

## 5. Open questions for the user

1. Do your survey files carry both GPS Long/Lat and projected X/Y? Which pair do you want as the default "current" one after import?
2. Which coordinate systems do you use most (for example WGS 84 / UTM, ETRS89 / UTM, SWEREF99 TM, EUREF89 NTM)? These could seed the favourites list.
3. Should "Reproject positions" make the new pair current by default? Oasis does not; I suggest it should.
4. Do you ever need local survey grids, warps, or old data on national grids with a custom datum transform? If not, the whole Georeferencing group can wait.
5. Do you need heights above the geoid (for terrain clearance or a later gravity workflow)? If yes, which geoid model?
6. Do you still get raw GPS plus a separate differential correction file, or is GPS always corrected already?
7. Is it fine to keep Assign and Reproject on the Database tab until the Coordinates tab has more tools, or do you want the tab from day one?
8. Should Translate and Rotate ever overwrite the input channels (Oasis style), or always write a new pair?
