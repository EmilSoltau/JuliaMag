# Plan 4a research: what an Oasis user expects from a map

Date: 2026-11-02
Source: Oasis montaj 2025.1 online help.
Base URL for every link below: `https://help.seequent.com/Oasismontaj/2025.1/Content/`
Earlier research (oasis-map.md, oasis-grid-and-image.md) is not repeated here.
Marks: "(help)" means the help page says it.
"(guess)" means my inference, not checked in the app.
The help has no page on user complaints.
Section 6 irritations are therefore partly guess.

## 1. Displaying a grid

Main page: `gxhelp/g/Geosoft_GX_DisplayGrid.htm`

### Colour methods
- Linear: equal steps from min to max.
- Normal distribution: breaks follow a bell curve.
- Histogram equalization: each colour holds about the same number of cells.
  Other pages call this "Equal Area".
- Log-Linear: breaks follow the log of the data.
- "Default" and "As last displayed" also exist in the dialog.
- The Colour Tool says histogram equalization is the default method.
  (`ss/om_reference/context_help/tools/geosoft_gx_colour_tool.htm`)
- General Settings can change the project default to Equal Area, Linear, Log-Linear or Normal.
  (`gxhelp/s/settings_gx.htm`)
- Reverse colours and brightness (-100 to 100) are in the same dialog.

### Default colour table
- The default is `colour.tbl`, in the Geophysics category.
  It is set in General Settings ("Default grid colour table").
  (`gxhelp/s/settings_gx.htm`)
- Colour tables are grouped in categories: Geophysics, Topography, Monochromatic, Heat map, CET perceptual, Perceptually uniform.
  Users can mark favourites.
  (`gxhelp/s/Geosoft_GX_SelectZoneFile.htm`)
- Common picks (my knowledge, guess): the default Geophysics table for mag, a CET perceptual table for a modern look, grey for shading, a Topography table for DEM.
- Old tables were moved to a "Legacy" folder because many were redundant.
  So a short list of good tables is enough for v1.

### How the range is set
- By default the range is the grid min and max, with breaks from the chosen method.
- "Minimum value" and "Maximum value" clip the range.
  Values below the minimum get the lowest colour.
  Values above the maximum get the highest colour.
- "Contour interval" rounds the colour breaks.
  Help suggests about 1/10 of the standard deviation.
- The Colour Tool lets users edit the number of bins, each bin colour and each boundary.
  Bins can be switched off, which hides them.
  Colour files are .itr, .zon, .tbl, .lut.
- Auto Recolour Grids (map toolbar): recolour using only the data now in view.
  Off by default.
  It is a temporary viewing aid.
  (`ss/om_reference/context_help/bars/map_tools_bar.htm`)
  This is the "stretch to view" button users know from other software.

### Shaded relief
- Shading is a tick box.
  Defaults: inclination 45, declination 45, RGB model.
- Vertical scale default is "2.5 over the mean of the gradient" of the grid.
  It is computed from the data, not a fixed number.
- Optional "wet look" (HSV) varies saturation with sun angle.
- Optional shadow grid: shade from a different grid, such as topography.
- Interactive Shading: move a sun cursor over the map, and the image updates live.
  Also scale, brightness (default 100 percent) and contrast (default 50 percent).
  (`gxhelp/i/geosoft_gx_interactive_shading.htm`)
- Shading is a layer property, not a new grid, in the interactive route.
  The "Shaded Relief" filter (`gxhelp/g/gridshad_gx.htm`) makes a real grid, and that is a separate tool.

### Colour-shaded grid
- A separate old dialog, "Colour-shaded Grid Image", does colour plus shading in one step.
  It writes a `_s` shaded grid file next to the input.
  (`gxhelp/g/gridimgs_gx.htm`)
- The normal route is just the "Shading" tick box on a grid layer.
  Users do not need a second command.

### Transparency
- Each layer has a transparency slider.
  Start is 0 percent (opaque).
  It lives in the Map Manager and in the Colour Tool.
  (`ss/om_reference/context_help/tools/id_map_group_manager.htm`)
- The help says lowering opacity of the grid helps line paths and symbols stand out.

### Dummies
- Dummy cells are not drawn.
  The map background shows through (guess: help has no sentence on this).
- Pixel value readout returns a dummy if any of the four neighbours is a dummy.
  (`ss/present_data/edit_annotate_maps_for_presentation/p/grid_value.htm`)
- For image files, a background colour (none, white, black) can be treated as dummy.
  (`gxhelp/g/geosoft_gx_map_displayimage.htm`)

### Smoothing
- On by default: the grid is interpolated to screen resolution.
- Off: cells show as pixels.
- Users flip this to see real cell size, which matters when checking a grid by eye.

### Colour bar
- "Add colour bar" is a tick box in the same dialog.
- In the interactive map it matters most as a legend of the range, not as a print item.

## 2. Displaying line data

### Line path
Help: `gxhelp/p/path.htm`
- Line thickness, colour and style (solid by default).
- "Draw ticks": yes or no.
  The help does not say what a tick marks (guess: ticks at fiducial or line ends; the help only says "line ticks").
- Label format: a string with L (line type), N (number), V (version), F (flight).
  "LNVF" gives "T1023.4:13".
- Label location: none, end, above ends, below ends.
- Optional direction arrow in the label.
- Optional compass letter.
- Break the path where the gap is larger than a set distance.
- The tool thins the path to speed drawing.
  Default thinning is 0.02 mm on paper.
  For exact points, the help tells users to use a symbol plot.
- The group is named `PATH_...` in the Map Manager.

So an Oasis user expects: lines as thin paths, line number labels at the ends, an arrow for flight direction, and gaps shown as breaks.

### Colour by a channel
- "Zone Coloured" symbols (COLSYMB): colour from a channel with a colour table.
  Symbols are fixed size or sized by value.
  (`gxhelp/c/colsymb_gx.htm`)
  Colour breaks use Normal distribution unless the table is a zone file.
  Needs X and Y channels.
  Mask channel option.
- "Colour Range Symbols" (CLASYMB, "classified symbols"): 1 to 12 ranges, each with its own symbol, size and colour.
  (`gxhelp/c/clasymb_gx.htm`)
- Both make a symbol per data point (group names `CSYMB_` / `SYMB_`).
  The Colour Tool can recolour a CSYMB layer afterwards, the same way as a grid.
- Gap in Oasis: there is no "line path coloured along the line".
  Users get coloured dots instead.
  For an import check, a coloured line is nicer (guess), and a dot plot is the fallback at high zoom.

### Profiles on the map
- Map Tools > Profile draws profiles beside each line, offset perpendicular to the line.
  (`gxhelp/p/profile_gx.htm`)
- Settings: scale (units per mm), base, log option, positive and negative fill colours, gap handling, join to line ends.
- It is a presentation and interpretation tool.
- Verdict: later.
  The separate Profile window already covers QC (see section 4).

## 3. Navigating

Page: `ss/om_reference/context_help/bars/map_tools_bar.htm`

| Action | Default key |
|---|---|
| Pan | P or Space, left drag |
| Zoom to box | B (drag a rectangle) |
| Zoom in / out | Z / X (drag right or left) |
| Zoom to selection (group) | S |
| Zoom to full extents | F |
| Previous / next extent | L / O |
| Redraw | R |
| Shadow cursor on/off | Alt+C |

- Zoom to group is also in the Map Manager right-click menu ("Zoom to Selection").
- Zoom level box in the status bar bottom right: 400, 200, 100, 75, 50, 25 percent, or typed.
  It relates to print size, so JuliaMag does not need it.
- Extent linking between maps: this map only, all maps, other maps only.
- "Pan to Cursor on All Maps" keeps the shadow cursor in view.
- Mouse wheel: the 2025.1 pages I read do not describe the wheel (not found).
  Every modern viewer zooms with the wheel at the cursor, so users will expect it (guess).
- Redraw with big grids:
  - "Auto-Redraw" toggle (on by default).
    When off, the map redraws only on zoom, pan or the Redraw button.
    This exists for slow maps.
  - Grids are drawn at screen resolution (smoothing).
  - Line paths are thinned.
  - Users of big projects do turn Auto-Redraw off, so slow redraw is a known pain.
    JuliaMag target (from spec section 9.3): smooth pan and zoom, thinned when zoomed out.
    That makes Auto-Redraw unnecessary.

## 4. Cursor and linked views

Pages: `ss/prepare_om/work_with_dynamic_data_process_links/c/two_types_of_linking.htm`, map_tools_bar.htm, `ss/om_reference/common_reference/profiles_linking/about_profiles.htm`

Oasis has two links.
- **Desktop link (Shadow Cursor, Alt+C):** on by default when a map opens.
  - Move the mouse over the map, and the same place shows as a shadow cursor in other maps and grid viewers.
  - In open databases, the closest point on the visible line is highlighted.
  - It also works the other way: selecting a cell in the database or a point on a profile moves the shadow cursor on all maps.
- **Database link (Data Linking button):** click a place on the map.
  - The cursor snaps to the nearest data point.
  - The database and profile windows jump to that point.
  - If the point is on another line, the database switches to that line.
  - It needs a "linking" layer on the map, such as a line path.
    A grid alone cannot link.
- Database and Profile windows are linked to each other: select a cell or range in one, and it is highlighted in the other.
- Help claims the response is "almost instantaneous" even for big databases.

Status bar and readouts:
- The status bar shows the cursor position in the active view (guess for map: the help I read states this for the 2D Section Viewer).
  Lat/long display is not documented for the map status bar.
- Grid value: right-click > Grid Value > pick the grid.
  The value shows at bottom right of the status bar until the user picks "Done".
  With several grids, each is a menu item.
  (`ss/present_data/edit_annotate_maps_for_presentation/p/grid_value.htm`)
  Value is interpolated if smoothing is on, and the cell value if smoothing is off.
- Measure Distance and Measure Angle are in the same right-click menu.
- I found no "Inspect" or "Point info" tool on the map in 2025.1.
  The closest ones are Grid Value, the Data Linking snap, and (for ArcGIS layers only) the Map Identify tool.
- Annoyance: the grid value readout needs a menu click and a manual "Done".
  JuliaMag's plan to show every visible grid value at the cursor all the time (spec 9.3) is better.

## 5. Map Manager

Page: `ss/om_reference/context_help/tools/id_map_group_manager.htm`

What users do there:
- Tick or untick a layer to hide or show it.
- Drag layers to change draw order (top of list draws on top).
  Works on several selected layers.
- Transparency slider for the selected layer.
- Right-click: Zoom to Selection, Delete Group, Rename, Colour Tool (grids and colour symbols), Smoothing, Shading, Interactive Shading.
- Multi-select with Ctrl; apply colour tool, smoothing or shading to all.
- Folders (two levels).
- Visible scale range and fixed scale per layer.
- Group masks, "render images and grids first" tick.
- Undo history tab (unlimited).
- Cannot be closed or floated.

Layer names carry a prefix by type (`AGG_`, `PATH_`, `CSYMB_`).
This tells users what a layer is.
JuliaMag should show an icon and the item name instead.

First version must have:
1. Visibility tick.
2. Drag to reorder.
3. Opacity slider.
4. Remove from map (not delete the item).
5. Zoom to layer.
6. Rename is not needed (layer name is the item name).
7. Open the colour style editor for a grid layer, from the layer.

Later: folders, scale-range visibility, masks.

## 6. Map creation defaults and irritations

Pages: `gxhelp/g/Geosoft_GX_DisplayGrid.htm`, `gxhelp/s/sclmap_gx.htm`, `ss/analyse_data/create_preliminary_maps/p/to_create_a_new_map.htm`

How it works now:
- Display Grid has "New Map" and "Current Map" buttons.
  New Map uses the grid range to make "a basic map layout" (gridimgs page).
- If the map name exists, it asks: overwrite or give another name.
- Open a grid and you get a Grid Viewer, which cannot take other layers.
  To add lines, the user must press "Open in New Map" (the scale fits about 30 x 30 cm).
- Scale blank means fit to 30 x 30 cm.
- Every map-making tool asks new or current map again.

What annoys users (mostly my reading, guess):
- Two windows for one grid (viewer versus map), and you must pick the right one before you can overlay.
- Scale, template and paper size questions when you only want a look.
- Each tool asks "new or current map" again.
- Map name clashes and overwrite prompts.
- Text and symbol sizes are tied to map scale, so a first look at the wrong scale gives tiny or huge symbols.
- Grid value readout needs menu clicks.

What JuliaMag drops (matches the spec): scale, template, data range, paper, overwrite prompts, viewer-versus-map split.
What to keep from Oasis: "Display on Map" as one action from a grid or database.
Suggested defaults: right-click a grid or database > "Show on map" adds a layer to the current map, or makes a new one if none is open.
New map coordinate system = first item added.

## 7. What users want to see right after an import (rank by need)

Ranked for "check an import by eye":

1. **Flight path plot** - thin lines of all lines, plan view, with line labels.
   Shows missing lines, wrong CRS, swapped X and Y, wrong units, jumps.
   This is the first thing anyone does (guess, standard practice).
2. **Cursor position readout plus nearest-point info** (line, fiducial, value) - needed to understand what is odd.
3. **Link to the database and profile** (click map, see data) - turns a visual oddity into a fixable row.
4. **Path coloured by a channel** (mag, altitude, speed) - shows spikes, drop-outs, altitude errors, heading noise.
   Oasis does this with coloured dots.
5. **Colour legend** for the channel colours - without it the colours mean nothing.
6. **Grid with a colour table and a range stretch** - the usual check on imported grids and later gridding output.
7. **Shaded relief** - shows levelling stripes and noise, so it matters most for mag grids, but it is a second look.
8. **Grid on top of path** with opacity - checks path and grid agree.
9. **Zoom to layer / full extent** - small, but it is a must for every other item to be usable.
10. Bookmarks, measure tools, coordinate grid lines - nice but not for import QC.

## 8. Leave for later

| Item | Reason |
|---|---|
| Layouts, base view, surround, title block, scale bar, north arrow | Spec splits them out; printing is not an import check. |
| Templates, map scale, paper size | The interactive map has no paper. |
| Contours | Needs a contouring engine; a shaded grid does the QC job. |
| Annotations, text, CAD edit tools | Drawing tools belong to layouts and interpretation. |
| Profiles drawn on the map (Map Tools > Profile) | The Profile window already shows profiles; map profiles are for presentation. |
| Classified symbols with 1-12 ranges and per-range symbols | A continuous colour scale on the path covers QC; classes are presentation. |
| Symbol plots sized by value | Same reason; check scale of symbols tied to paper. |
| Folders in the layer list | Spec already says later. |
| Visible scale range, fixed scale, group masks | Print-oriented features. |
| Ternary, 2/3/4-grid composites | Radiometrics and presentation. |
| Wet-look HSV and shadow grid | Extras; simple hillshade covers QC. |
| Snapshots / bookmarks | Cheap; can slip in if time allows. |
| Measure distance and angle | Useful but not an import check. |
| Shapefile, KML, DXF overlays | Needs a vector item type (spec non-goal). |
| Linked extents across several maps | Only one map view is open in v1. |
| Auto-Redraw toggle | Not needed if drawing is fast. |
| Export map image, copy view, pack | After the map works. |

## Conclusions for JuliaMag 4a

### Must have
- A map with a layer list: visibility, drag order, opacity, remove, zoom to layer.
- Line path layer: thin lines, line labels at the ends (line number only to start), gaps drawn as breaks, thinned when zoomed out.
- Colour the path by a channel with a colour table and a legend (bar) showing the range.
- Grid layer: colour table, colour method (linear and histogram equalization at least), min/max clip, reverse, smoothing on/off, dummies not drawn.
- Default colour table: one good geophysics table, plus a small list of others.
- Pan, wheel zoom at cursor, zoom to full extent, zoom to layer.
- Cursor readout in the status bar: X, Y, the value of every visible grid, the nearest line point (line, fiducial, channel value).
- Linking: click a map point selects the nearest line and fiducial in the shared cursor (database and profile follow).
  Database row or profile point moves a cursor marker on the map.
- "Show on map" action from a grid or database, no questions.

### Should have
- Shaded relief on a grid layer: sun inclination 45, declination 45, vertical scale from the grid gradient (Oasis default 2.5 over mean gradient), plus a live sun control.
- Normal and log colour methods; edit the colour range by hand.
- Per-layer colour style that overrides the grid default (matches spec 5.4).
- "Recolour to view" toggle (Oasis Auto Recolour Grids).
- Keyboard shortcuts: P/Space, B, Z/X, F, S, L/O.
- Path colour mode that works as coloured dots at high zoom for exact points.
- Line direction arrow and optional ticks on the path.
- Previous and next extent.

### Later
- Layouts, contours, annotations, vector overlays, profiles on map, classified symbols, composites, folders, bookmarks, measure tools, map export, packaging.

### Source list
- `gxhelp/g/Geosoft_GX_DisplayGrid.htm`
- `gxhelp/g/gridimgs_gx.htm`
- `gxhelp/g/gridshad_gx.htm`
- `gxhelp/i/geosoft_gx_interactive_shading.htm`
- `gxhelp/s/settings_gx.htm`
- `gxhelp/s/Geosoft_GX_SelectZoneFile.htm`
- `ss/om_reference/context_help/tools/geosoft_gx_colour_tool.htm`
- `ss/om_reference/context_help/tools/id_map_group_manager.htm`
- `ss/om_reference/context_help/bars/map_tools_bar.htm`
- `ss/om_reference/context_help/bars/grid_toolbar.htm`
- `ss/om_reference/context_help/dialogs_tabs/map_window.htm`
- `ss/prepare_om/work_with_dynamic_data_process_links/c/two_types_of_linking.htm`
- `ss/om_reference/common_reference/profiles_linking/about_profiles.htm`
- `ss/present_data/edit_annotate_maps_for_presentation/p/grid_value.htm`
- `gxhelp/p/path.htm`
- `gxhelp/p/profile_gx.htm`
- `gxhelp/c/colsymb_gx.htm`
- `gxhelp/c/clasymb_gx.htm`
