# Oasis montaj Map menu: research for JuliaMag

Date: 2026-10-28
Source: Oasis montaj 2025.1 online help (https://help.seequent.com/Oasismontaj/2025.1/Content/).
Scope: the **Map** menu only.
The Map Tools, Project (printing), Database, Coordinates and Grid and Image menus are only touched where they link to it.

How the menu tree was found:
The help's own table of contents (`Data/Tocs/geohelp.js`) has a "Context Help" section with one node per menu.
The "Map" node lists the items below.
I assume the order there matches the order in the real menu (guess, not checked in the app).

All help URLs below start with `https://help.seequent.com/Oasismontaj/2025.1/Content/`.
They are written in full so they can be clicked.

## 1. Overview

### What the Map menu is for

The Map menu is the "file menu" for Oasis map documents.
It creates, opens, copies, saves and closes maps.
It brings outside drawings and images into a map (Import).
It writes a map out to images, vector files or PDF (Export).
It packs a map and all its files into one file for sending.
It also has a few small helpers: snapshots (saved views), map comments, Map Manager show/hide, and the snap grid.

The Map menu does not draw data.
Drawing is done by other menus:

- **Map Tools**: new map from X,Y or lat/long or template, base map (surround, title block), line path, profiles, symbols, contours, CAD tools, masks.
- **Grid and Image**: Display on Map (grids, shaded grids, colour bars).
- **Project**: Print, Print Preview, Batch Printing.

### What an Oasis map is

From "Maps: More than Printed Sheets of Information" (oasis_montaj_maps.htm) and "Understanding the Parts of a Map" (id_map_group_manager.htm):

- A map is one `.map` file with drawings and images.
- A map is both a working area for looking at data and a print-ready sheet.
- A map has **views**.
  A view is a coordinate transform plus a mask region.
  - The **Base view** uses paper coordinates (mm, cm or inches from the paper origin).
    Surrounds, north arrows, scale bars, title blocks and legends live here.
  - The **Data view** uses ground coordinates.
    Grids, contours, line paths, symbols and coordinate annotations live here.
- Each view holds **groups** (layers).
  A group is one graphic part, for example one line path plot or one contour plot.
  Groups are drawn in the order shown in the **Map Manager**.
  Each group has its own transparency.
- Grids and images live in a special group called an **aggregate** (`AGG_` prefix).
  You cannot add or delete items in an aggregate, but you can change its colour table, shading and smoothing.
- The Map Manager is a tree inside each map window.
  It shows views, folders (two levels deep) and groups.
  It allows hide, reorder by drag and drop, rename, delete, zoom to group, transparency, and drag to a 3D view.
- A new map is made from a **data range** (scanned from a database or grid, or drawn), a **template** (page size, margins, layout style) and a **scale**.

So an Oasis map mixes two things that RustGIS keeps apart: the interactive map (Data view) and the page layout (Base view, template, scale, paper size).

### Place in the processing chain

The user's chain is import, lag correction, levelling, IGRF removal, gridding, RTP, maps.
The Map menu sits at both ends of it:

- **During processing**, a map is the plan view used to check data: flight paths, grids, anomalies.
  Snapshots help jump between areas of interest.
- **At the end**, after gridding and RTP, the map becomes the deliverable.
  The grid is put on the map (Grid and Image), line paths, contours and a base map are added (Map Tools), and the map is exported to PDF or GeoTIFF or printed (Project).
  Pack Files bundles the map and its grids for a colleague or client.

## 2. Command inventory

Legend for the "Script name" column: the GX name or .NET class the help gives.
"Script parameters" are shown where the help lists them, since they show what the command really takes.

### 2.1 Map documents

| Command | What it does | Inputs | Outputs | Key settings | Help |
|---|---|---|---|---|---|
| **New** (NEWMAP GX) | Creates a new blank map that fits a data range. Two steps: "Data Range to Map", then "New Map". | Min/max X and Y typed in, or scanned from a database's projected X,Y channels ([Scan data]), from a grid ([Scan grid]), or drawn as a box on an open map ([Interactive]). | An empty map window with a Base view and a Data view. | Distance unit; coordinate system (taken from the scanned item, warp removed); for rotated projections, plot rotated or unrotated; map name; **map template** (media size, margins, drawing style); **map scale** (blank = fit to template; [Scale] computes it). [Templates] opens the MAPPLOT Template Manager. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/n/newmap0.htm and https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/n/newmap2.htm |
| **Open** | Opens an existing `.map` file in a map window. | A `.map` file. | Map window. | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/analyse_data/create_preliminary_maps/p/opening_a_map.htm |
| **Duplicate** (DUPMAP GX) | Makes a copy of the current map under a new name. Meant for test interpretations or edits without touching the original. | Current map. | New map. | `DUPMAP.MAP` new name; `DUPMAP.CONTENTS` 0 = blank, 1 = copy current contents. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/dupmap_gx.htm |
| **Copy to Clipboard** (COPYMAP GX) | Copies the current map to the clipboard as a Windows metafile, to paste into Word and similar. | Current map. | Clipboard picture. | None. (Export Map has a "Clipboard" target with more options.) | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/copymap_gx.htm |
| **Save As** (SAVEMAP GX) | Saves the current map to a new name and closes the original. Unsaved changes go to the new map only. | Current map. | New map file. | `SAVEMAP.MAP`. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/savemap_gx.htm |
| **Close** (CLOSEMAP GX) | Closes the current map. Changes are saved on close. | Current map. | None. | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/closemap_gx.htm |
| **Close All** (MAPCLOSE GX) | Closes all open maps in the project. | None. | None. | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/mapclose_gx.htm |

Related, outside the Map menu:
The Grid Viewer toolbar has "Open in New Map" (SCLMAP GX), which turns an open grid into a new map with a scale.
The default scale fits about 30 x 30 cm (https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/sclmap_gx.htm).

### 2.2 Import (Map > Import)

All importers share one pattern:
pick one or more files, then choose **New map** or **Current map**.
For a new map they ask for a map name and an optional scale (blank = fit about 30 x 30 cm, 15 x 15 cm for DXF).
Many also ask "Project data as": Plan, E-W section, N-S section (and 3D view for DXF).
Several also put the attribute table into a new or current **database**.

| Command | What it does | Inputs | Outputs | Key settings | Help |
|---|---|---|---|---|---|
| **Geosoft PLT File** (LOADPLOT GX) | Draws a Geosoft plot file on a map. | `.plt` file. | Groups on new or current map. | `LOADPLOT.NEW` 0 current, 1 new. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/loadplot_gx.htm |
| **AutoCAD DXF File(s)** (Geosoft.GX.Map.ImportDXF2D) | Imports DXF vector entities. | One or more `.dxf`. | Groups on new or current map. | Coordinate system of the DXF (reprojected to the view if both defined); layers to separate groups or one group; keep DXF colours or one colour; target map; name; scale; project as Plan, E-W, N-S or 3D. Map extent comes from the DXF header (EXTMIN/EXTMAX). For digitizer units, define a warp first (Coordinates menu). | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/geosoft_gx_map_importdxf2d.htm |
| **Image (bmp, tiff, etc.)** (Geosoft.GX.Map.DisplayImage) | Places a raster image or grid on a map. Same command as Grid and Image > Display on Map > Image. | Image file (any supported format, ER Mapper bands via name "decorations" such as `City.ers(ERM;band=3)`). | Image group on new or current map. | Background colour as transparent (none, white, black); registration: default (georeferenced) or fit to a box drawn on the map; keep image aspect or stretch to map aspect. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_map_displayimage.htm |
| **EMF File** (Geosoft.GX.Map.DrawEMF) | Places a Windows enhanced metafile (for example a logo) at a picked spot. Keeps aspect ratio. | `.emf`. | Group on new or current map. | Destination; script-only location and size. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_drawemf.htm |
| **MapInfo TAB or MIF File(s)** (IMPORTMI GX) | Imports MapInfo features: graphics to a map, attributes to a database. Also on Database > Import. | One or more `.tab`/`.mif`. | Map groups and database lines (X,Y = centre of each feature's bounding box). | Data to new, current or no database; map to new, current or none; scale; name. Uses the TAB projection. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/importmi_gx.htm |
| **ArcGIS Shapefile(s)** (IMPORTARC GX) | Imports shapefiles: shapes to a map, `.dbf` attributes to a database. Also on Database > Import and ArcGIS Tools. | One or more `.shp`. | Map groups (black, default symbols, polygons unfilled) and database. | Data to current, new, none, or with "shape databases"; map to new, current or none; project as Plan, E-W, N-S; scale; names. Uses the `.prj` or asks for a projection. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/importarc_gx.htm |
| **ArcGIS LYR File** (Geosoft.GX.ArcGIS.ImportLYR) | Adds an ArcGIS layer file (live link, with its symbology) to the Data view. Needs a licensed ArcGIS Desktop. | `.lyr`. | LYR group on new or current map. | New or current; scale; group name. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/a/geosoft_gx_arcgis_addlyr.htm |
| **Import KMZ or KML File(s)** (Geosoft.GX.Map.ImportKMZorKML) | Imports KML vector elements (points, lines, polygons). No rasters. | `.kml` or `.kmz`. | Groups on new or current map; new map is WGS 84. | New or current map. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/geosoft_gx_map_kmzorkml.htm |
| **Microstation DGN File(s)** (IMPORTDGN GX) | Imports DGN elements into a "DGN" view, one group per DGN level. Optional element database. | One or more `.dgn`. | Map groups; optional database. | Element database yes/no; current or new map; project as; scale. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/importdgn_gx.htm |
| **Datamine DM File(s)** (IMPDATAMINE GX) | Imports Datamine files. | `.dm`. | Map groups. | Current or new; project as; scale. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/impdatamine_gx.htm |
| **Surpac STR or DTM File(s)** (IMPSURPAC GX) | Imports Surpac strings or DTMs. | `.str`, `.dtm`. | Map groups. | Current or new; project as; scale. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/impsurpac_gx.htm |
| **Micromine File** (Geosoft.GX.Micromine.Micromine) | Imports a Micromine file. | Micromine file. | Map groups. | New or current; name; scale; plan view. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/geosoft_gx_micromine_micromine.htm |
| **Gemcom BT2 File** (Geosoft.GX.Map.Gemcom) | Imports a Gemcom BT2 file. | `.bt2`. | Map groups. | New or current; name; scale; plan view. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/geosoft_gx_map_gemcom.htm |
| **Minesight File** (Geosoft.GX.Minesight.Minesight) | Imports a Minesight file. | Minesight file. | Map groups. | New or current; name; scale; plan view. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/geosoft_gx_minesight_minesight.htm |
| **UBC DCINV2D/IPINV2D Files** (Geosoft.GX.IP.ImportUBC2D) | Converts UBC 2D DC/IP inversion models to grids and shows them on a map. | Mesh, topography, conductivity and/or chargeability files. | Grids (conductivity, optional resistivity, chargeability) and a map. | Create resistivity grid (1 / conductivity). | https://help.seequent.com/Oasismontaj/2025.1/Content/ip/geosoft_gx_ip_importubc2d.htm |

### 2.3 Export

| Command | What it does | Inputs | Outputs | Key settings | Help |
|---|---|---|---|---|---|
| **Export** (Export Map dialog) | Writes the current map to one file or the clipboard. | Current map. | File in one of about 28 formats: EMF, PLT, Shapefile, DXF, DXF v12, BMP, JPEG (3 qualities), JPEG 2000 (J2K, JP2), PCX, PNG, TIFF, TIFF compressed, GeoTIFF, MapInfo TIFF, ArcGIS TIFF, EPS, Geosoft COLOR grid, ER Mapper RGB, ECW, MapInfo TAB, SVG, KMZ, KML, PDF, CGM. | Colour depth (1, 4, 8, 24 bit, grey or colour); raster resolution: "Screen" (smooth) or "Grid" (one pixel per grid cell); estimated size; region: full map, viewed region, or selection (box or selected group); target: file or clipboard; dither for low colour depths. Shapefile export writes separate line, polygon and point files with no styling and no text. GeoTIFF keeps colours, location and orientation. Only EPSG datums survive in standard image formats. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/export_archive_data/export_selected_data/export_maps/r/id_export_map_to_file.htm |
| Export > **Export Map to PDF** | PDF writer used by Export. | Current map. | `.pdf`. | Keep map layers as PDF layers; **geospatial PDF** (georeferenced; not for lat/long or custom projections; goes through a GeoTIFF on the way); open when done. Grids are put at the back of the layer stack. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/e/geosoft_gx_exporttopdf2d.htm |
| Export > **Export Map to CGM** (CGMOPTIONS GX) | Advanced options for CGM plotter files. | Current map. | `.cgm`. | Paper width and height, plotter units, default font, colour mode, number of colours, fade, ink filter, image and plot dpi, image behind or in front, images as lines. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/cgmoptions_gx.htm |
| Export > **Export Map to BMP or PLT** (EXPMAP GX) | Script-only version of export. | A map. | Raster or vector file. | View mode or raster mode; full map or region; bits; dither; dpi; view name; resolution; format (PLT, SHP, DXF12, DXF13, GTIFF and others). | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/e/expmap_gx.htm |
| **Export Multiple Maps** (Geosoft.GX.Map.ExportMultiMaps) | Exports many maps at once, full extent only. | One or more maps. | One file per map in the chosen folder. | Same formats as Export (no CGM); colour depth; resolution (default 300 dpi); file name prefix; output folder (default project folder); overwrite. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/geosoft_gx_map_ExportMultiMaps.htm |

### 2.4 Snapshots

| Command | What it does | Inputs | Outputs | Key settings | Help |
|---|---|---|---|---|---|
| **Create Snapshot** | Saves the current map extent under a name (a bookmark). Also on the map navigation toolbar and the map right-click menu. The right-click menu has a "Snapshots" list to jump back. | Current map and view. | Named snapshot saved in the map. | Name. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/analyse_data/edit_manipulate_maps/p/create_snapshot.htm |
| **Manage Snapshots** | Open, rename, delete and reorder snapshots. | Current map. | Changed snapshot list. | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/analyse_data/edit_manipulate_maps/c/manage_snapshots.htm |

### 2.5 Packing and sharing

| Command | What it does | Inputs | Outputs | Key settings | Help |
|---|---|---|---|---|---|
| **Pack Files** | Packs the map and every file it uses (grids, images, symbols, 3D views, projection info) into the map file. The map then shows "(Packed)". Also on the Project Explorer right-click menu. PACKALLMAPS GX packs all open maps. | Selected map. | Packed map file. | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/export_archive_data/export_selected_data/export_maps/p/pack_a_map.htm |
| **Pack and Send Map** | Packs the map and opens a new email with it attached. | Selected map. | Email draft. | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/export_archive_data/export_selected_data/export_maps/p/pack_and_send_map_to.htm |
| **Unpack Files** (UNPACKMAP GX) | Unpacks a packed map into a chosen folder. UNPACKALLMAPS GX unpacks all open maps. | Packed map. | Grids, images and other files in the folder. | Target folder. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/u/unpackmap_gx.htm |

### 2.6 Helpers

| Command | What it does | Inputs | Outputs | Key settings | Help |
|---|---|---|---|---|---|
| **Open/Close Map Managers** | Opens or closes the Map Manager pane in every open map. Map windows resize; zoom is kept. A default open/closed state is in Advanced Settings. | Open maps. | None. | Open or Close. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/analyse_data/create_preliminary_maps/p/open_close_map_managers.htm |
| **Edit Map Comments** (MAPCMNT GX) | Edits the map's comment block (RTF) in an outside text editor. Saved inside the `.map`. | Current map. | Comments in the map. | Default text editor. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/mapcmnt_gx.htm |
| Settings > **Snap Grid Resolution** (MAPSNAP GX) | Sets the snap step, in mm on paper, for the current map. | Current map. | Setting. | `MAPSNAP.RES` (default 1 mm). | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/mapsnap_gx.htm |

### 2.7 Pages read for background (one level deep)

- Maps concept: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/maps_groups_coordinate_systems/oasis_montaj_maps.htm
- Create Maps: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/maps_groups_coordinate_systems/creating_maps_in_oasis_montaj.htm
- Create a New Map (steps): https://help.seequent.com/Oasismontaj/2025.1/Content/ss/analyse_data/create_preliminary_maps/p/to_create_a_new_map.htm
- Map Manager and parts of a map: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/context_help/tools/id_map_group_manager.htm
- Map Window: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/context_help/dialogs_tabs/map_window.htm
- MAPPLOT Template Manager: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/maptmpl_1.htm
- Print and Plot Maps: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/maps_groups_coordinate_systems/printing_and_plotting_maps.htm
- Resize to Data Extents (Map Tools): https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/reszmap_gx.htm
- Save and Open Grid as Map: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/sclmap_gx.htm

## 3. How the commands work together

### 3.1 Making a final map of a grid (the end of the mag chain)

1. **Map > New** (or Map Tools > New Map from > X,Y).
   [Scan grid] on the RTP grid sets the range, unit and coordinate system.
2. In the New Map step, pick a template (page size, margins) and a scale.
   A blank map opens with a Base view (paper) and a Data view (ground).
3. Grid and Image > Display on Map puts the grid in an `AGG_` group in the Data view.
4. Map Tools adds line paths, contours, symbols and the base map (surround, title block, scale bar, north arrow).
   Resize to Data Extents fixes the views after adding items.
5. **Map > Import** adds overlays: survey boundary from a shapefile or KML, culture from DXF, a logo as EMF or image.
6. The Map Manager sets draw order, visibility and transparency.
7. **Map > Export** writes PDF (maybe geospatial) or GeoTIFF; or Project > Print prints it.
8. **Map > Pack Files** or **Pack and Send** shares it with all its grids.

Shortcut: from an open grid, "Open in New Map" on the Grid Viewer toolbar makes a map in one step.

### 3.2 QC maps during processing

- A quick map of flight paths or a grid is used to check data, not to print.
- Snapshots mark anomaly areas or problem lines and jump back to them.
- Duplicate with "blank" or "copy contents" makes test maps for interpretation without changing the main map.

### 3.3 Data flow between menus

- Database (line data) -> Map Tools (line path, profiles, symbols) -> map groups.
- Grid and Image (grids from gridding, RTP) -> Display on Map -> aggregate groups.
- Map > Import (SHP, TAB/MIF) -> map groups **and** a database of attributes.
  So one import feeds both the Database and the Map side.
- Coordinates menu -> map coordinate system, warps for DXF in digitizer units.
- Map -> Export -> files for GIS, CAD, documents.
- Project menu -> Print, Batch Printing.

### 3.4 Patterns worth noting

- Almost every "make something" command asks **New map or Current map**.
  The same choice repeats in every importer.
- New maps need a **scale**, because the map is also a paper sheet.
  Text size, line patterns and symbols depend on it (sclmap_gx.htm says so directly).
- The map is saved on close; there is no separate Save.

## 4. Fit in JuliaMag

### 4.1 Main idea: split the Oasis map into Map + Layout

RustGIS keeps two kinds of items:

- A **map**: layers, coordinate system, bookmarks, view settings.
  It opens as a tab over the map view.
  It has no paper size and no scale.
- A **layout**: a page (A4 to A0, portrait or landscape) with map frames, title, legend, north arrow, scale bar, grid and colour bar.
  Each map frame shows a map at its own centre and scale.
  It exports to PDF, PNG or SVG.

The Oasis map packs both into one file:

| Oasis concept | Better JuliaMag home |
|---|---|
| Data view (ground coordinates, groups) | Map item and its layer list |
| Map Manager tree (order, visibility, transparency, folders) | Layers tab in the Project Explorer pane |
| Base view (paper coordinates, surrounds) | Layout item |
| Template, page size, margins | Layout template |
| Map scale | Map frame scale on a layout |
| Data range to map | Map frame extent (or "zoom to item" on a map) |
| Snapshots | Map bookmarks |
| Snap grid (mm) | Layout editing setting |

Why this is better:

- Making a QC map needs no scale, template or data range.
  The user just opens a map and adds items.
  In Oasis, the scale and template questions get in the way of a quick look.
- One map can feed several layouts (A3 report sheet, A4 figure, client sheet) without copying the data view.
  In Oasis this needs Duplicate.
- It keeps the first version small: the interactive map exists already in the draft design; layouts can come later without changing it.
- It matches what the user likes in RustGIS.

Trade-off: Oasis users think of "a map" as the printed sheet.
The words in the UI should make the split plain, for example "Map" and "Map Sheet" or "Layout".
That naming is a question for the user.

### 4.2 Per command

Type column: **Tool** = a function plus description (gets a dialog, command id and script entry from the tool system).
**Built-in** = a built-in command or view behaviour, not a processing tool.
**Import/Export** = a unit in the importer or exporter registry.

| Oasis command | JuliaMag home | Type | Priority | Notes |
|---|---|---|---|---|
| New | Map tab > Map group > **New Map**; also Data tab right-click "New Map" | Built-in | First version | Only a name. Coordinate system taken from the first item added (guess at a good default). No range, template or scale. "New Map from item" (right-click a grid or database > "Show on new map") replaces Scan data/Scan grid and Open in New Map. |
| Open | Double-click a map in the Data tab | Built-in | First version | Maps are project items, not loose files. No menu button needed beyond the command id. |
| Duplicate | Data tab right-click > Duplicate | Built-in | Later | Keep the "blank / copy layers" choice. Less needed once layouts exist. |
| Copy to Clipboard | Map view right-click > Copy View as Image; command id `map.copy_image` | Built-in | Later | PNG to clipboard, not a Windows metafile (cross-platform). |
| Save As | Drop | - | Skip | The project saves items; Duplicate + Rename covers it. |
| Close, Close All | Map tab close button; Window commands | Built-in | First version | Plain view behaviour, no dialog. Closing does not delete. |
| Import > Shapefile, KML/KMZ, MapInfo TAB/MIF, DXF | Project tab (or Import button) > **Import**, as importer units for a new **vector item** type; then "add to current map" | Import | Later (Shapefile and KML first) | Survey boundaries, flight plans and culture are real needs in airborne mag work (guess; ask the user). Store geometry and attributes as one vector item; do not split attributes into a line database as Oasis does. |
| Import > Image (bmp, tiff, etc.) | Importer for georeferenced images (GeoTIFF RGB, PNG/JPEG with world file) as an image item | Import | Later | "Fit to area" placement is a layout job (picture element), not a data import. |
| Import > EMF | Layout > Insert Picture (logo) | Built-in (layout) | Later, with layouts | Use PNG/SVG rather than EMF. |
| Import > Geosoft PLT | Drop | - | Skip | Old Geosoft plot format; ask the user if they have archives of it. |
| Import > ArcGIS LYR | Drop | - | Skip | Needs licensed ArcGIS. |
| Import > DGN, Datamine, Surpac, Micromine, Gemcom, Minesight | Drop | - | Skip | Mining packages, not part of the mag chain. A plugin could add them later. |
| Import > UBC DCINV2D/IPINV2D | Drop | - | Skip | IP/DC inversion, not mag. |
| Export (raster: GeoTIFF, PNG, JPEG) of the map view | Map tab > Share group > **Export Map Image**; exporter unit for "map view" | Export (tool, can run as job) | Later | Settings worth keeping: region (full extent, visible view), resolution as dpi or "one pixel per grid cell" (the Oasis "Grid" option is valuable for grids), colour depth only if asked. |
| Export (PDF, SVG, PNG) of a sheet | Layout tab > Export | Export | Later, with layouts | Geospatial PDF and PDF layers are nice extras, later still. |
| Export (Shapefile, KML/KMZ, DXF) of map content | Exporters on vector items, not on the map | Export | Later | Oasis exports all map groups as unstyled shapes; per-item export is clearer. KMZ of a grid image may be useful for clients (guess). |
| Export (EMF, PCX, BMP, CGM, EPS, ECW, J2K, MapInfo TIFF, ArcGIS TIFF, Geosoft COLOR grid, ER Mapper RGB) | Drop for now | - | Skip | Old or niche formats. GeoTIFF RGB covers the "rendered grid as a georeferenced picture" use of COLOR grid and ER Mapper RGB. |
| Export Map to BMP or PLT (EXPMAP script) | Covered by the command id and script entry of the export tool | - | Skip | JuliaMag gets scripting for free from the tool system. |
| Export Multiple Maps | Data tab: select several maps or layouts > right-click > Export; runs as one background job | Export (job) | Later | Settings: format, dpi, prefix, folder, overwrite. |
| Create Snapshot, Manage Snapshots | Map tab > Navigate group > **Bookmarks** menu (new, go to, rename, delete, reorder); also map view right-click | Built-in | Later (cheap, could slip into first version) | Store bookmarks in the map item, as RustGIS does. |
| Pack Files, Pack and Send, Unpack Files | Project tab > **Package Project** / **Package Selected Items**, and "Open Package" | Built-in (job) | Later | Package a map with the grids and databases it shows into one archive, like RustGIS's project package. Skip the email step; the OS can attach a file. |
| Open/Close Map Managers | Drop as a separate command; the Layers tab can be shown or hidden like any pane | Built-in | First version (via pane toggle) | The draft's Layers tab already is the Map Manager. |
| Edit Map Comments | Item description in the Properties of the Data tab | Built-in | First version (already in draft) | No outside text editor. |
| Settings > Snap Grid Resolution | Layout editing setting (snap and guides) | Built-in (layout) | Later, with layouts | Not needed on the interactive map. |

### 4.3 Suggested Map ribbon tab for the first version

The Oasis Map menu is mostly file handling.
In a RustGIS-style app, file handling lives in the Project Explorer and right-click menus.
So the Map tab should rather hold what you do **on** a map.
Suggested first-version groups (my call, open to change):

- **Map**: New Map, Add Item to Map, Remove Layer.
- **Navigate**: Full Extent, Zoom to Layer, Previous/Next Extent; Bookmarks later.
- **Display**: colour by channel, grid colour scale, hillshade (these overlap with Grid and Image; decide one home).
- **Share** (later): Export Map Image, New Layout.

Later, when layouts arrive, a **Layout** tab (or a contextual tab shown while a layout is open, as RustGIS's Publish tab does) takes the Oasis Map Tools base-map and template work.

### 4.4 Things that would change the draft design

1. **Add a Layout item type** to the project model (Data tab lists maps and layouts).
   Not built in the first version, but the item model and the Data tab should expect it.
   The draft lists "maps" as an item and lists "map layouts" as a non-goal, which fits this split; it should say so in words.
2. **Add a vector item type** (points, lines, polygons with attributes).
   The draft has line databases, grids and maps only.
   Survey outlines, flight plans and culture need it (guess at the user's need; see open questions).
   It is also what Shapefile and KML importers produce.
3. **Exporters for views, not only data.**
   The draft's exporter registry is per data type.
   Map and layout export (image, PDF) needs exporters whose input is a map or layout.
   The registry should allow that.
4. **"Show result on map" as a tool system option, not per tool.**
   Oasis repeats "New map / Current map" in every importer.
   In JuliaMag, a tool outputs an item.
   A general option "add outputs to the current map" (or a setting) avoids repeating it in each tool.
5. **Layer list needs opacity and folders.**
   The draft's layer list has order and visibility.
   The Oasis Map Manager also has per-layer transparency and folders, and users rely on transparency for grids over shaded relief.
   Opacity should be in the first version; folders can come later.
6. **Map bookmarks** should be part of the map item's saved state.
7. **Map coordinate system rule.**
   The draft says grids in another coordinate system are not drawn.
   Oasis sets the new map's system from the scanned item and removes any warp.
   A clear rule for "the map's coordinate system is the first item's, unless set" would help (my suggestion).

## 5. Open questions for the user

1. Do you make final printed maps in Oasis today, or do you export grids and finish maps in QGIS or ArcGIS?
   This decides how much layout work JuliaMag needs, and when.
2. Which Map > Export formats do you really use (PDF, GeoTIFF, PNG, KMZ, Shapefile, DXF)?
3. Which overlays do you add to maps (survey boundary, flight plan, roads, claims, topography), and in which formats (Shapefile, KML, DXF, MapInfo)?
4. Do you use Oasis map templates or a company sheet with a logo and title block?
5. Do you send packed maps to clients or colleagues, or PDFs and grids?
6. Do you use snapshots (bookmarks) during QC?
7. Is "Map" plus "Layout" (or "Map Sheet") a naming you are happy with, or should the printed sheet keep the name "Map"?
8. Do you need to open existing Oasis `.map` files?
   The draft already leaves out `.gdb` and `.gpf`; I assume `.map` is left out too.
9. Do you need section maps (E-W, N-S) or only plan maps?
   Several importers offer section views; for airborne mag I assume plan only.
10. The Map Tools menu (line path, contours, symbols, base map, templates) is not covered by any of the current research agents.
    Should it be researched next, since it holds most of the real map-making commands?
