# Oasis montaj Grid and Image menu: research for JuliaMag

Date: 2026-10-28
Source: Oasis montaj 2025.1 online help (https://help.seequent.com/Oasismontaj/2025.1/Content/).
Scope: the **Grid and Image** menu only.
FFT filtering and reduction to pole (RTP) are not in this menu.
They live in the 2D Filtering extension (MAGMAP).
I read those pages too, because the task asked for them and because the Grid and Image menu prepares grids for them.

How the menu tree was found:
The help's table of contents (`Data/Tocs/geohelp.js`) has a "Context Help" section with one node per menu.
The "Grid and Image" node lists the items in section 2.
Each command page also says "Use the Grid and Image > ... menu option", which confirms the path.
I assume the order in the table of contents matches the real menu (guess, not checked in the app).

All help URLs start with `https://help.seequent.com/Oasismontaj/2025.1/Content/`.
They are written in full so they can be clicked.
"GX" is the Oasis name for one command program; the GX name is given because scripts use it.

## 1. Overview

### What the menu is for

The Grid and Image menu turns line data into grids and then works on grids.
It has six parts:

- **Gridding:** make a grid from a database channel (minimum curvature, bi-directional, kriging, IDW, direct, multi-trend, TIN).
- **Display on Map:** draw a grid or image on a map with colours and shading, or combine 2 to 4 grids.
- **Grid editing:** Grid Math, Window a Grid, Window by polygon, Merge Grids (knit, mosaic, boolean mask).
- **Utilities:** convert formats, sample a grid into a database, profiles, reproject, fill holes, expand, volume, peaks, outline.
- **Filters:** space-domain filters (convolution, derivatives, shaded relief, gradients, trend, AGC, analytic signal, tilt).
- **Properties:** show and change a grid's header, statistics and coordinate system.

### What a grid is in Oasis

From "About Grids and Images" and the format pages:

- A grid is a regular array of values (Z) at evenly spaced X,Y points.
- An image holds colours, not values.
  Images cannot be processed, only shown.
- The Geosoft grid file is `.grd`.
  Its coordinate system lives in a side file `.grd.gi`.
  Metadata lives in a side file `.grd.xml` (ISO 19115 based).
- The `.gi` file also holds the grid's colour display (the "ITR": colour table plus colour breaks).
- Geosoft grid element types: byte, short (2-byte int), long (4-byte int), float (4-byte), double, and colour (4 bytes RGB plus a dummy flag).
- Geosoft grids can be compressed.
  Options are `COMP=NONE`, `COMP=SPEED` and `COMP=SIZE`.
  `COMP=SIZE12` and similar drop mantissa bits for better compression (12 bits is 3 to 4 significant figures).
- The default element type for new Geosoft grids is "Compressed 32-bit float".
  So most `.grd` files users have will be compressed.
- A grid has an origin at the bottom-left point, a point separation in X and Y, a rotation angle, and a row orientation (KX).
  The "normal Geosoft definition" is that the origin is the centre of the lower-left cell (point registration).
- Missing values are "dummies".
  The dummy value depends on the data type.
- A grid can carry the coefficients of a removed trend in its header, so the trend can be added back later.
- Oasis reads many formats through "DAT" plug-ins: Geosoft GRD, Surfer GRD, USGS, ER Mapper ERS (via `ERM`), Geopak, GXF, GeoTIFF, ArcGIS float grid, plain images and more.
  A file name can carry options, for example `City.ers(ERM;band=3)`.
- An ER Mapper raster is two files: an ASCII `.ers` header and a binary data file named in the header.

### Place in the processing chain

The user's chain is: import, lag correction, levelling, IGRF removal, gridding, RTP, maps.

- Import, lag, levelling and IGRF work on line data in the Database menus.
- **Gridding** is the first step of this menu.
  It takes the final levelled, IGRF-removed channel and makes a grid.
- **RTP** is done in the 2D Filtering extension (MAGMAP), on the grid.
  The Grid and Image menu supplies the prep steps that FFT needs: Expand Grid, Fill Grid Dummies, Trend.
- **Derivatives** (vertical derivative, analytic signal, tilt) are in both places: convolution versions in this menu, FFT versions in MAGMAP.
- **Maps:** Display on Map puts the grid (with colour and shading) onto a map from the Map menu.
- **Back to line data:** Sample a Grid writes grid values into a channel.
  The levelling extension also uses it ("Tie Line Levelling > Levelling Utilities").

## 2. Command inventory

The tree below is the menu.
Each command then has a short entry: what it does, inputs, outputs, key settings, help URL.

```
Grid and Image
  Gridding
    Grid Data
      Minimum Curvature
      Bi-directional
      Kriging (+ Variogram tab)
      Inverse Distance Weighted
      Direct Gridding
      Multi-trend
      Grid Preview (tab of the Grid Data tool)
    Tinning
      Create TIN File from Database
      Grid using TIN
      Plot a TIN Mesh
      Plot TIN Nodes
      Plot Voronoi Cells
      Plot Convex Hull
      Sample a TIN
    Grid Multiple Channels (+ Advanced Options per method)
    Regrid a Grid
    Trend Enforcement
      Find Trends
      Plot Trends
      Add Trend Line
    Gridding from Control File
      Minimum Curvature
      Bi-Directional
      Kriging
    Plot Variogram
  Display on Map
    Grid
    Image (bmp, tiff, etc.)
    Grid Histogram
    Ternary Image
    Ternary Legend
    2-Grid Composite
    3-Grid Composite
    4-Grid Composite
    Create Colour Zone File
  Grid Math
  Window a Grid
  Window a Grid using Polygon File
  Merge Grids
    Knit Two Grids Together
    Knit Multiple Grids Together
    Plot Suture Path
    Boolean Operations
    Grid Mosaic from Grid File(s)
  Utilities
    Copy/Convert Grid(s)
    Import ASCII Grid
    Create Master Grid
    Grid Outline
    Point Values
    Sample a Grid
    Grid Profile
    Save Grid to Database
    Export Grid to XYZ File
    Reproject Grid File(s)
    Grid UTM Zone
    Modify Coordinate System for Grid File(s)
    Transpose Grid
    Expand Grid
    Fill Grid Dummies
    Grid Volume
    Grid Peaks
  Filters
    3x3 Convolution
    5x5 Symmetric Convolution
    7x7 and 9x9 Symmetric Convolution
    Vertical Derivative Convolution
    Vertical Continuation Convolution
    Shaded Relief
    Horizontal Gradient
    Trend
    Automatic Gain Correction
    Analytic Signal
    Generalised Derivative
    Tilt Derivative
  Properties
```

### 2.1 Gridding > Grid Data (one tool, six methods)

Grid Data is one dialog.
The user picks a method; the left side shows that method's settings and the right side has a live Grid Preview tab.
All methods share these parts:

- **Inputs:** the active database, one channel (an array element can be picked as `Chan[1]`), optional mask channel.
- **Output:** one grid file, plus a text log (`rangrid.log`, `bigrid.log`, `krigrid.log`).
  The output name is filled in from the database and channel.
  The output format follows a project default and can be changed.
- **Cell size:** filled in from the data and rounded to the nearest ten or hundred.
- **Extents:** default to the data limits; can be typed or drawn on the preview with the mouse ("Draw Extents", "Reset Extents").
- **Mask channel:** only channels with class "MASK" are listed; dummies in the mask drop those points.
- **Log option:** linear, log save as linear, log-linear save as linear, log save as log, log-linear save as log, with a log minimum.
  The log-linear options are meant for levelled geophysical data with a wide range.
- **Restore Defaults:** resets method settings but not channel, output name or method.
- **Run in background:** runs the gridding in a separate process.
  A node appears in the Project Explorer Jobs tab with status (processing, completed, failed, cancelled).
  The output grid is added to the Data tab when done.
  Double-click on the job runs it again, with the option to change settings.
  Several runs can go at once.
- **Memory:** the settings used last are recalled per database.
- **Control file:** each run writes a control file (`_rangrid.con`, `_bigrid.con`) in the project folder.

#### Minimum Curvature (RANGRID)

- What: fits the smoothest surface through the data.
  Best for random data, arbitrary lines, or when tie lines must be used.
  Method: coarse grid (default 16x the final cell) from inverse-distance means within a search radius, then iterate, halve the cell, repeat (Briggs 1974, Swain 1976).
  Optional internal tension (Smith and Wessel 1990) to stop overshoot in sparse areas.
- Inputs: channel, optional mask channel.
- Output: grid, `rangrid.log`.
- Key settings (script names):
  - Cell size `RANGRID.CS`: default about 1/4 to 1/2 of line spacing.
  - Extents `RANGRID.XY`.
  - Blanking distance `RANGRID.BKD`: cells further than this from data become dummy.
    For line data set it just above the maximum line spacing.
  - Cells to extend beyond data `RANGRID.EDGCLP`.
  - Log option and log minimum `RANGRID.LOGOPT`, `RANGRID.LOGMIN`.
  - Low-pass desampling factor `RANGRID.DSF` (default 1): averages data into bins of N cells, a boxcar de-aliasing filter.
  - Starting coarse grid `RANGRID.ICGR` (16, 8, 4, 2, 1; default 16).
  - Search radius `RANGRID.SRD` (in cells) for the starting grid.
  - Weighting power `RANGRID.IWT` and weighting slope `RANGRID.WTSLP` (slope 0 means nearest point only).
    For airborne data the help suggests slope about equal to grid points between lines.
  - Tolerance `RANGRID.TOL` (default 0.1% of data range), % pass tolerance `RANGRID.PASTOL` (default 99%).
  - Max iterations `RANGRID.ITRMAX` (default 100; up to 500 is fine).
  - Internal tension `RANGRID.TENS` (0 to 1, default 0).
- Tip from the help: grid lines with minimum curvature, then mask with a bi-directional grid using Boolean Operations so the grid stops at the data edge.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_griddingtool_MinC.htm
- Overview and method comparison: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/c/gridding_data_methods.htm

#### Bi-directional (BIGRID)

- What: grids roughly parallel line data in two passes.
  Pass 1 splines along each line to where grid lines cross it.
  Pass 2 splines across the lines to each grid node.
  It joins narrow features from line to line.
  It does not use tie lines.
  The help says it is 10 to 100 times faster than minimum curvature.
  This is the usual method for airborne magnetic survey lines.
- Inputs: channel, optional mask channel, optional transverse gradient channel.
- Output: grid, `bigrid.log` (lists lines skipped for backtracks or clipping).
- Key settings:
  - Cell size `BIGRID.CS`: default is the larger of 1/8 of the average line spacing and the average sample spacing.
    The help says never smaller than 1/8 of line spacing.
  - Extents `BIGRID.XYRANGE`.
  - Max line separation `BIGRID.SMX`: wider gaps between lines become dummies (default 1.7x the maximum line spacing; the advanced dialog says 1.5x the average, the two pages disagree).
  - Max point separation `BIGRID.GAPLIM`: gaps along a line wider than this are not filled (default 0 = fill all).
  - Cells to extend beyond data `BIGRID.NEX` (1 for gridding, 0 for regridding).
    A "strip grid" (data only in strips along lines) is made with NEX 2 or 3 and SMX equal to the cell size.
  - Log option and log minimum.
  - Low-pass wavelength `BIGRID.WS` and high-pass wavelength `BIGRID.WL`, applied along lines before gridding.
  - Non-linear filter tolerance `BIGRID.TOLN` (Naudy and Dreyer filter, removes spikes; blank = off).
  - Pre-filter sample increment `BIGRID.FDX`: lines are resampled to an even step before filtering.
  - Data pre-sort `BIGRID.PRESORT`: none, pre-sort, or remove backtracks (recommended for airborne data).
  - Spline down line `BIGRID.ISP1` and across line `BIGRID.ISP2`: linear, cubic (minimum curvature), Akima (default), nearest.
  - Trend angle `BIGRID.TRA` (degrees counter-clockwise from +X): for oblique lines set it perpendicular to the lines.
  - Force grid direction `BIGRID.KX`.
  - Gradient-enhanced gridding (Hardwick 1999): transverse gradient channel `BIGRID.GRAD`, sensor separation `BIGRID.GSEP`, gradient direction `BIGRID.GCOR`, correct gradient levels `BIGRID.GLEV`, gradient noise level `BIGRID.GNOISE`.
- Filter details from the help: data is extended at line ends with Burg maximum entropy before filtering; the linear filter (Fraser et al. 1966) has up to 512 coefficients.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_griddingtool_bigrid.htm
- Trend enhancement (aliasing, manual trend lines in the XYZ file with line type TREND): https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/perform_bi-directional_gridding/c/trend_enhancement.htm
- BIGRID control file: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/perform_bi-directional_gridding/c/bigrid_control_file.htm
- BIGRID error messages: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/perform_bi-directional_gridding/r/bigrid_error_messages.htm

#### Kriging (KRIGRID) and the Variogram tab

- What: geostatistical gridding for random, clustered or poorly sampled data.
  The help says it is rarely used for geophysical data.
- Inputs: channel, optional mask, optional input variogram file.
- Outputs: grid, optional error grid (standard deviation per node), output variogram file, `krigrid.log`.
- Key settings: cell size, extents, blanking distance, desampling, log option, variogram model (power, spherical, Gaussian, exponential, linear), nugget, sill, range, strike and strike weight, trend removal.
- The Variogram tab plots the data variogram against the model; "Update" refits it.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_griddingtool_kriging.htm
- Variogram tab: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_griddingtool_variogram.htm
- Kriging theory: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/perform_kriging/c/kriging_theory.htm

#### Inverse Distance Weighted (IDW)

- What: each node is a distance-weighted mean of points in a search radius.
  For highly variable data such as geochemistry.
- Inputs: channel, optional mask.
- Output: grid.
- Key settings: cell size, extents, weighting power (default 2), weighting slope (default 1), search radius (at least 4 cells by default), blanking distance, cells to extend, log option.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_griddingtool_IDW.htm

#### Direct Gridding

- What: no interpolation.
  Each cell gets the weighted mean (or minimum or maximum) of the points inside it.
  Empty cells stay blank.
  For very dense data (LiDAR, GPR) or a quick first look at a large database.
- Inputs: channel, optional mask.
- Output: grid.
- Key settings: cell size, extents, grid value (mean, min, max) `DIRECT_GRIDDING.GRID_VALUE`, treat zeros as dummies `DIRECT_GRIDDING.DUMMY_ZEROS`.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_griddingtool_direct.htm

#### Multi-trend

- What: the NSI gridding algorithm (Naprstek and Smith, Laurentian University).
  For thin linear features across several lines when there is no single strike.
  It finds local trend directions with a structure tensor.
- Inputs: channel, optional mask.
  Data must be in projected (ground) units.
- Output: grid.
- Key settings: starting cell size and final cell size, blanking distance (default 10 cells), max iterations (default 50), auto stop, trending factor (0 to 100, default 100), theta (rotation step, default 10 degrees), multi-smooth factor (0 to 100).
- The preview is off by default for this method because it is slow.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_MultiTrendGridding.htm

#### Grid Preview tab

- What: a live preview of the output grid that redraws when any setting changes.
- Tools: auto-refresh on/off, show data points (all points, including masked ones), measure distance, pan, zoom to box, zoom in/out, zoom to full extents, cursor readout of X, Y and value.
- Uses the default colour table.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_griddingtool_gridpreview.htm

### 2.2 Gridding > Tinning

TIN = triangulated irregular network, built with Fortune's sweepline algorithm into a binary `.tin` file.

| Command | What it does | In / out | Key settings | Help |
|---|---|---|---|---|
| Create TIN File from Database (TINDB) | Builds a TIN from database X,Y (and optional Z). | Database channels / `.tin` file | Z channel, duplicate handling (TIN allows one point per X,Y). | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tindb_gx.htm |
| Grid using TIN (TINGRID) | Grids a Z-valued TIN. | `.tin` / grid | Method: linear, natural neighbour (default, Sambridge 1995), nearest; cell size. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tingrid_gx.htm |
| Plot a TIN Mesh (TINMESH) | Draws the Delaunay triangles on the current map. | `.tin` / map group | Line colour, thickness. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tinmesh_gx.htm |
| Plot TIN Nodes (TINNODES) | Draws the TIN points. | `.tin` / map group | Symbol colour and size, labels. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tinnodes_gx.htm |
| Plot Voronoi Cells (TINVORONOI) | Draws Voronoi cells. | `.tin` / map group | Colours, thickness, clip to convex hull. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tinvoronoi_gx.htm |
| Plot Convex Hull (TINHULL) | Draws the outer hull and also writes it to a `.ply` polygon file. | `.tin` / map group, `.ply` | Colour, thickness. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tinhull_gx.htm |
| Sample a TIN (TINSAMP) | Interpolates TIN values at database X,Y into a channel. | `.tin` + database / channel | Method: natural neighbour, linear, nearest. Projection-aware. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tinsamp_gx.htm |

### 2.3 Gridding > other commands

#### Grid Multiple Channels

- What: grids many channels of one database with the same method and settings.
- Inputs: list of channels, method (minimum curvature, bi-directional, kriging, IDW, multi-trend), optional mask channel.
- Outputs: one grid per channel, named with prefix and suffix, in a chosen folder and format.
- Key settings: cell size, name prefix and suffix, output grid type, destination folder, display option (current map, grid windows, do not display), "Advanced" button per method, run in background.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/geosoft_gx_channelstogrid.htm
- Advanced options pages:
  - Bi-directional: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/b/geosoft_gx_grid_bigrid_advancedoptions.htm
  - IDW: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/geosoft_gx_grid_idw_advancedoptions.htm
  - Kriging: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/k/geosoft_gx_grid_krigrid_advancedoptions.htm
  - Minimum curvature: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/geosoft_gx_grid_rangrid_advancedoptions.htm
  - Multi-trend: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_grid_multitrend_advancedoptions.htm

#### Regrid a Grid (REGRID)

- What: runs bi-directional gridding again on an existing grid.
  Used to change cell size, to filter along grid rows, or to fill small dummy gaps.
- Input: grid.
  Output: grid.
- Key settings: new cell size, cells to extend beyond edge, low-pass and high-pass cutoff wavelengths, non-linear filter tolerance, spline (linear, cubic, Akima, nearest), maximum gap to interpolate (0 = fill all inner gaps; blank = none), trend angle, row orientation (KX).
- Note from the BIGRID page: BIGRID filters only along survey lines.
  Regridding the output with the same filter filters across lines too.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/regrid_gx.htm

#### Trend Enforcement

These help bi-directional gridding join features across lines when there is no single strike.
Trend lines are extra database lines of type "R" (trend) that BIGRID uses as data.

| Command | What it does | In / out | Key settings | Help |
|---|---|---|---|---|
| Find Trends (TRENDDB) | Finds maxima and minima along lines and links them into trend lines. | Database channel / new trend lines (R0, R1, ...) | Max-min search window (default 100), preferred angle, allowed deviation (default 30), min and max length, resample, branch angle, deflection. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/trenddb_gx.htm |
| Plot Trends (TRNDPATH) | Draws trend lines on the current map (minima blue, maxima red). | Database / map group | Colours, thickness. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/trndpath_gx.htm |
| Add Trend Line (TRNDDIGI) | User digitises a trend line on the map; values are sampled from a grid into a new trend line. | Map + grid / new trend line | Grid to digitise, output channel, resample interval. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/trnddigi_gx.htm |

#### Gridding from Control File

Each runs a gridding program from a hand-edited text control file that exposes all settings, including some the dialog does not show.

| Command | Help |
|---|---|
| Minimum Curvature (RGCON) | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/rgcon_gx.htm |
| RANGRID control file format | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/rangrid_control_file.htm |
| Bi-Directional (BGCON), also takes a transverse gradient channel | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/b/bgcon_gx.htm |
| Kriging (KGCON), can make a variogram only | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/k/kgcon_gx.htm |
| KRIGRID control file format | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/perform_kriging/r/using_control_files_to_perform_kriging.htm |

#### Plot Variogram (VARIOGRM)

- What: draws a variogram file from kriging as a plot on the current map.
- Settings: variogram file, plot width and height in mm (default 250 x 180).
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/variogrm_gx.htm

### 2.4 Display on Map

Overview page: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/analyse_data/visualise_gridded_data/c/adding_grids_and_images_to_maps.htm

#### Grid

- What: draws one grid on a new or the current map as a colour image, with optional shading and colour bar.
- Input: grid.
  Output: an "AGG" (aggregate image) group in a map.
- Key settings:
  - Colour scheme (colour table file).
  - Colour method `GRIDIMG1.ZONE`: default, linear, normal distribution, histogram equalization, log-linear, as last displayed.
  - Brightness (-100 to 100), reverse colours, smoothing (smooth to screen resolution, or show cells as pixels).
  - Shading on/off; normal or "wet look" (HSV: saturation changes with sun angle); shadow grid (for example topography); inclination and declination (default 45 and 45); vertical scale factor (default 2.5 over the mean gradient).
  - Data range: contour interval used to round colour breaks (about 1/10 of the standard deviation), minimum and maximum clip values.
  - Add colour bar; location (default registration, or fit to an area drawn by the user).
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/Geosoft_GX_DisplayGrid.htm

#### Image (bmp, tiff, etc.)

- What: draws an image file on a map (also in Map > Import).
- Settings: image file, background colour treated as dummy (none, white, black), registration (default from georeference or fit to area).
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_map_displayimage.htm

#### Other display commands

| Command | What it does | Key settings | Help |
|---|---|---|---|
| Grid Histogram (GRIDHIST) | Draws a histogram of a displayed grid on the map, under its colour bar. | Bins (default 50), size, location, linear or log, summary statistics, box-whisker, probability plot. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridhist_gx.htm |
| Ternary Image (GRIDIMGT) | Maps three grids to CMY or RGB (typical for radiometrics K, Th, U). | Colour model (CMY, RGB, inverted), colour method, three grids, optional extra grid. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridimgt_gx.htm |
| Ternary Legend (TERNLEG) | Draws the triangle legend for a ternary image. | Model, three labels, size, location picked on map. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/ternleg_gx.htm |
| 2-Grid Composite (GRIDIMG2) | Combines two grids in one image, usually colour plus a shaded grid. | Per grid: colour table, colour method (incl. shaded relief), contour interval; blend method. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridimg2_gx.htm |
| 3-Grid Composite (GRIDIMG3) | Like ternary but with any colour tables. | Three grids, three tables, method. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridimg3_gx.htm |
| 4-Grid Composite (GRIDIMG4) | Four grids in one image. | Four grids, four tables, method. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridimg4_gx.htm |
| Create Colour Zone File (GRIDZONE) | Makes one colour zone file from the combined statistics of up to 5 grids, so they share colours. | Output `.tbl`, `.zon` or ER Mapper `.lut`; colour table; method; contour interval; histogram viewer. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridzone_gx.htm |

#### Related tools reached from grids (not in this menu, but used with it)

- **Colour Tool:** edit a grid's or layer's colours: distribution (linear, normal, histogram equalization (default), log-linear, custom), brightness, transparency, number of bins, edit bin colours and boundaries, save as `.itr`, `.zon`, `.tbl`, `.lut`.
  Opened from Project Explorer right-click on a grid, the grid viewer toolbar, or the Map Manager.
  Several grids can be edited at once.
  From the Project Explorer it changes the grid's own colours; from the Map Manager it changes only that map layer.
  https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/context_help/tools/geosoft_gx_colour_tool.htm
- **Interactive Shading:** live change of shadow grid, wet look, inclination, declination (drag a sun cursor over the map), scale, brightness, contrast.
  https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/geosoft_gx_interactive_shading.htm
- **Project Explorer, Grids node:** right-click gives New Grid (opens Grid Data), Open Grids, Remove, Rename, Open File Location, Colour Tool, Properties, Metadata, export to OMF.
  https://help.seequent.com/Oasismontaj/2025.1/Content/ss/edit_preprocess_data/view_edit_spreadsheet_data/p/project_explorer_grid_tools.htm
- Opening a grid opens a **grid viewer** window.
  It cannot hold other graphics, but can be saved as a map.

### 2.5 Grid Math

- What: a C-style expression on grids, for example `G0 = G1 - G2` or `G0 = (G1>5000) ? G2 : G3`.
  Several equations in one run.
  Tabs list operators and functions (common, conditional, log, trig, statistics).
- Inputs: grids assigned to variables G1, G2, ...
  Output: a new or existing grid (G0).
- Key settings: expression, grid assignments, common tasks list, save and load expression files, Apply (run without closing).
- Values outside the output type's range become dummy.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_mathexpressionbuilder_gridmathexpressionbuilder.htm
- Expressions in general: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/interpretations_expressions_scripts/defining_and_applying_math_expressions.htm

### 2.6 Window a Grid and Window a Grid using Polygon File

| Command | What it does | In / out | Key settings | Help |
|---|---|---|---|---|
| Window a Grid (GRIDWIND) | Cuts a sub-area from a grid (up to 16000 x 16000). | Grid / grid | Grid indices or ground units; X/Y min and max; Z min and max with out-of-range values clipped or dummied; new cell size; decimation factor. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridwind_gx.htm |
| Window a Grid using Polygon File (GRIDMASK) | Sets cells inside or outside polygons to dummy. | Grid + `.ply` polygon file / grid | Inside or outside; shrink output to the valid area. Up to 2048 vertices per polygon, many polygons per file. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridmask_gx.htm |

### 2.7 Merge Grids

| Command | What it does | In / out | Key settings | Help |
|---|---|---|---|---|
| Knit Two Grids Together (GRIDSTCH) | Joins two overlapping grids into one. Grid 2 is reprojected and resampled to grid 1. | 2 grids / grid, `suture.lin` | Method: blend (cosine weights over the overlap) or suture (a cut line through the overlap); detrend to each other or to a regional grid; output cell size; output only grid 1 or grid 2 area. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridstch_0.htm |
| Knit Multiple Grids Together (GRIDSTCH2) | Same, for up to 10 grids (20 from a script), added one at a time; each must overlap the earlier ones. | Grids / grid | As above. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridstch_0.htm |
| Plot Suture Path (GRIDKNITPATH) | Draws the suture line from knitting on a map. | `suture.lin` / map group | Colour, thickness. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridknitpath_gx.htm |
| Boolean Operations (GRIDBOOL) | Masks one grid by another using where each has data. | 2 grids / grid | AND, OR, XOR; output size (minimum, grid 1, grid 2, maximum); which values in overlap. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridbool_gx.htm |
| Grid Mosaic from Grid File(s) (MOSAIC) | Pastes many grids into one; later grids overwrite earlier ones; no levelling between them. | Grids / grid | Input grids (same folder, same format, all projected or all geographic). Output takes projection and cell size of the first grid. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/mosaic_gx.htm |

### 2.8 Utilities

| Command | What it does | In / out | Key settings | Help |
|---|---|---|---|---|
| Copy/Convert Grid(s) | Copies or converts one or many grids or images between formats. | Grids / grids | Output format, prefix, folder, overwrite, display option. ER Mapper bands via `name.ers(ERM;band=1)`. A data grid to GeoTIFF colour keeps its colour display. Only EPSG datums survive conversion to common image formats. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridUtils_CopyConvertMultiGrids.htm |
| Import ASCII Grid (READASCIIGRID) | Reads a plain-text grid. | Text file / grid | Header lines to skip, points per row, rows, row orientation (KX), dummy value, DX, DY, X0, Y0, rotation. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/readasciigrid_gx.htm |
| Create Master Grid | Makes an empty grid of NX x NY with a constant value, then asks for cell size, rotation, coordinate system. | None / grid | NX, NY, constant. | https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/process_grids/c/utils_create_master_grid.htm |
| Grid Outline (GRID2PLY) | Finds the edge of valid data and draws it or saves it as a polygon file. | Grid / map group or `.ply` | Draw or save, minimum polygon size, edge resolution (thinning), line style. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/grid2ply_gx.htm |
| Point Values (GRIDVALUE) | Click on the map; shows values of up to 4 grids at that point. | Up to 4 grids / dialog | Typed X,Y and "Calc". | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridvalue_gx.htm |
| Sample a Grid | Samples a grid at every X,Y of the current database into a new channel. Also in the levelling extension. | Grid + database / channel | Linear (bilinear, default) or nearest; output channel. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/Geosoft_GX_GridUtils_SampleAGrid.htm |
| Grid Profile (GRIDPROF) | Extracts a profile from up to 5 grids into a new database line. | Grids / database line with X, Y and value channels | Line name with type prefix (L, B, T, R, S, D), sample method and spacing. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridprof_gx.htm |
| Save Grid to Database (GRIDGDB) | Writes every grid cell as a point (X, Y, Z, Data) into a database. | Grid / database | Channel name, X and Y decimation, trim dummies (leading/trailing, all, none), index channel. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridgdb_gx.htm |
| Export Grid to XYZ File (GRIDXYZ) | Writes a grid to a Geosoft XYZ text file, one line per grid row. | Grid / `.xyz` | Grid index as station numbers, X and Y decimation, line labels. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridxyz_gx.htm |
| Reproject Grid File(s) (GRIDREPJ) | Reprojects one or many grids to a new coordinate system. | Grids / grids | New coordinate system, cell size (single grid), name prefix and suffix (many grids). | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridrepj_gx.htm |
| Grid UTM Zone | For a geographic grid, reports which UTM zones it covers and the % in each. | Grid / report | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/geosoft_gx_gridutils_gridUTMzone.htm |
| Modify Coordinate System for Grid File(s) (SETIMGPRJ) | Assigns a coordinate system to grids without changing the data (writes the `.gi`). | Grids / same grids | Coordinate system wizard. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/setimgprj_gx.htm |
| Transpose Grid (GRIDTRNS) | Swaps rows and columns in place (storage order only). Some two-grid tools need the same storage order. | Grid / same grid | Always, force rows in X, force rows in Y. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridtrns_gx.htm |
| Expand Grid (GRIDXPND) | Adds a dummy border, mainly to be filled before FFT (MAGMAP). | Grid / grid | Minimum % expansion (default 10), square or rectangle, or exact X and Y size. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/Geosoft_GX_GridUtils_GridExpand.htm |
| Fill Grid Dummies (GRIDFILL) | Fills all dummies so the grid is full and periodic at its edges, as FFT needs. | Grid / grid | Roll-off linear or square, distance to roll to zero, maximum entropy prediction filter length and area (else inverse distance), roll-off base, amplitude limit, edge amplitude limit and width, convolution passes. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridfill_gx.htm |
| Grid Volume (GRIDVOL) | Volume above and below a reference level. | Grid / report | Reference base, multiplier. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridvol_gx.htm |
| Grid Peaks (GRIDPEAK) | Finds peaks (Blakely test) and writes them to a database line. | Grid / database line (type D) | Hanning smoothing passes, detection level, cut-off value, output line. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridpeak_gx.htm |

### 2.9 Filters (space domain)

| Command | What it does | In / out | Key settings | Help |
|---|---|---|---|---|
| 3x3 Convolution (GRIDFILT) | Applies a 9-point filter any number of times. | Grid / grid | Predefined (Hanning default, Laplace, X, Y, 45-degree derivative), filter file, or 9 numbers; passes; multiplier; dummy handling. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridfilt_gx.htm |
| 5x5 Symmetric Convolution (GRIDFLT5) | 5x5 symmetric filter, 6 coefficients. | Grid / grid | Predefined (Least Square default), file or string; passes. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridflt5_gx.htm |
| 7x7 and 9x9 Symmetric Convolution (GRIDFLTN) | 7x7 or 9x9 symmetric filter. | Grid / grid | Predefined (Least Square, Laplacian of Gaussian for 9x9), file or string; passes. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridfltn_gx.htm |
| Vertical Derivative Convolution (GRIDVD) | First vertical derivative with Henderson's radial filter on a 51x51 window. Saves memory and time on very large grids. | Grid / grid | None. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridvd_gx.htm |
| Vertical Continuation Convolution (GRIDVC) | Upward or downward continuation by convolution (Henderson). | Grid / grid | Up or down; distance, limited to 5 cells. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridvc_gx.htm |
| Shaded Relief (GRIDSHAD) | Makes a reflectance grid (-1 to 1) to combine with the colour grid in a composite. Output is one cell smaller and shifted half a cell. | Grid / grid | Inclination (default 45), declination (default 45), vertical scale (default from data). | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridshad_gx.htm |
| Horizontal Gradient | Gradient in a chosen direction, or the gradient magnitude, with a 3x3 convolution. | Grid / grid | Directional or magnitude; angle (CCW from +X). | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/Geosoft_GX_GridUtils_GridGrad.htm |
| Trend (GRIDTRND) | Removes a polynomial trend (order 0 to 3) or adds back the trend stored in the grid header. | Grid / grid | Remove or replace; edge points or all points (default edge); order (default 1); given coefficients. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridtrnd_gx.htm |
| Automatic Gain Correction (GRIDAGC) | Evens out signal amplitude across the grid with a moving window. | Grid / grid | Window size, maximum gain, full or local amplitude. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridagc_gx.htm |
| Analytic Signal (GRIDASIG) | sqrt(dx^2 + dy^2 + dz^2). | Grid / grid (and optional dx, dy, dz grids) | Z-derivative by FFT (default) or convolution (for grids over about 4000 x 4000); keep derivative grids. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridasig_gx.htm |
| Generalised Derivative | Derivative in any direction given by azimuth and dip. | Grid / grid | Azimuth, dip, FFT or convolution, keep derivative grids. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/Geosoft_GX_GridUtils_GeneralizedDerivative.htm |
| Tilt Derivative (TILTDRV) | Tilt angle atan(VDR / THDR), optional horizontal derivative of tilt, optional tilt-depth points (Salem et al. 2008) into a database. Meant for RTP data. | Grid / grid(s), optional database | FFT or convolution for the vertical derivative; output names. | https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/tiltdrv_gx.htm |

### 2.10 Properties (GRIDSTAT)

- What: a wizard to view and change a grid's header.
- Shows: element type, points in X and Y, point separation, row orientation (KX), bottom-left and top-right point, rotation, coordinate system and units, compression ratio.
- Stats: statistics (from the header or the `.gi` file, or "Re-Calc" from all cells), histogram, removed trend coefficients.
- Modify: change origin, spacing, rotation, coordinate system.
  This moves the grid on the map but does not change values.
- Metadata (ISO 19115 based) is kept in the grid or a companion XML file.
- Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gridstat_gx.htm

### 2.11 Outside this menu: FFT filtering and RTP (2D Filtering extension)

The 2D Filtering extension adds a menu "2D Filtering".
I list it because RTP is step 6 of the user's chain and nothing in Grid and Image does RTP.

- **MAGMAP Filtering:** one dialog that runs the whole FFT chain on one or many grids.
  - Steps: remove trend (mean, 1st order default, 2nd, 3rd; based on edge points (default) or all points), expand (default at least 10%, square default), fill (maximum entropy default, inverse distance, or multi-trend), forward FFT, apply filters, inverse FFT, mask back to the original footprint, add the trend back.
  - Cached files: `_prp.grd` (prepared grid) and `_trn.grd` (transform).
    They are reused for later filters on the same grid unless prep settings change.
  - Also writes a radially averaged power spectrum (`.spc`).
  - Filter chain is defined in a filter control file; up to six filters at once.
  - FFT sizes: Cooley-Tukey (powers of 2) or Winograd (more sizes).
  - Run in background, Jobs tab, rerun, same as gridding.
  - Help: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/geosoft_gx_fft2d_magmapfiltering.htm
- **Reduce to Magnetic Pole (REDP):** settings are survey date (to compute IGRF inclination and declination), inclination, declination, amplitude correction inclination Ia for low latitudes.
  The grid needs a coordinate system.
  https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/fft2con/fft2con_redp.htm
- **Differential RTP (DRTP):** computes inclination and declination grids over the survey from date and position, for large surveys where the field changes.
  https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/fft2con/fft2con_drtp.htm
- Other filters in the same library: reduce to equator, transform from pole, upward and downward continuation, vertical integration, derivatives in X, Y, Z, band-pass, Butterworth, cosine roll-off, Gaussian regional/residual, directional cosine (decorrugation), pseudo-gravity, apparent susceptibility, Wiener, field component conversion.
  Filter list: https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/fft2con/fft2con_main.htm
- The extension menu also lists Analytic Signal, Generalised Derivative and Tilt Derivative, the same commands as in Grid and Image > Filters.
- Extension overview: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/extensions/2D_filtering.htm

### 2.12 Format and background pages read

- Grid and image formats: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/analyse_data/visualise_gridded_data/r/grid_and_image_formats.htm
- DAT (XGD) formats and qualifiers, incl. GRD compression and types: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/import_data/import_file_types/import_ascii_binary_data/r/dat_xgd_formats.htm
- Grid compression: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/c/grid_compression.htm
- General Settings (default grid element type "Compressed 32-bit float"): https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/settings_gx.htm
- Geosoft grid glossary (projection in `.gi`): https://help.seequent.com/Oasismontaj/2025.1/Content/ss/glossary/grids_or_grid_file.htm
- ER Mapper ERS glossary: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/glossary/er_mapper_ers.htm
- About grids and images: https://help.seequent.com/Oasismontaj/2025.1/Content/ss/om_reference/common_reference/gridding_3d_models/about_grids_and_images.htm
- Process grids (list of grid GXs): https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/grid_data/process_grids/processing_grids.htm

What the help did not say:
The online help does not describe the byte layout of the `.grd` header, the compression scheme, or the `.gi` file.
Those need the GX Developer documentation or reverse engineering of sample files.

## 3. How the commands work together

### 3.1 The main magnetic sequence

1. Line data is levelled and IGRF-removed in the Database menus.
2. **Grid Data > Bi-directional** on the residual field channel.
   - Cell size about 1/4 to 1/5 of line spacing.
   - Pre-sort "remove backtracks".
   - Trend angle perpendicular to the lines if lines are oblique.
   - Optional non-linear filter to remove spikes, optional low-pass at about 2 cells.
   - Optional gradient-enhanced gridding if the survey has wing-tip gradiometers.
   - Watch the Grid Preview, then run (often in background).
3. Or **Grid Data > Minimum Curvature** when tie lines should be used or lines are irregular, then **Boolean Operations** against a bi-directional grid to clip the edges.
4. **Display on Map > Grid** with histogram equalization and shading to check the result.
5. If lines show corrugation, go back to levelling, or use a directional cosine filter in MAGMAP (decorrugation).
6. **RTP** in 2D Filtering > MAGMAP with REDP (or DRTP for large areas).
   MAGMAP does trend removal, expansion and fill itself.
   The manual route is Trend, Expand Grid, Fill Grid Dummies, then FFT.
7. Derivatives on the RTP grid: vertical derivative, horizontal gradient, analytic signal, tilt derivative.
8. **Display on Map** each product, often as a 2-grid composite (colour grid plus shaded grid), with colour bar and histogram, then finish the map in the Map menu.

### 3.2 Data flow between commands

- Database channel -> Grid Data -> grid.
- Grid -> Regrid / Window / Polygon mask / Boolean / Grid Math / Filters -> grid.
- Several grids -> Knit or Mosaic -> one grid.
- Grid -> Sample a Grid -> database channel (used for levelling to a grid, comparing grid to lines, and checking misfit).
- Grid -> Grid Profile -> database line (for modelling).
- Grid -> Save Grid to Database or Export Grid to XYZ -> point data.
- Grid -> Grid Peaks -> database line of targets.
- Grid -> Grid Outline -> polygon file -> Window a Grid using Polygon File (or other menus).
- Grid -> Display on Map -> map group; colour state lives in the grid's `.gi` (ITR) or in the map layer.
- Database -> Find Trends / Add Trend Line -> trend lines in the same database -> Bi-directional gridding again.

### 3.3 Links to other menus

- **Database / Database Tools:** source channels; mask channels (class MASK); line types (L, T, B, R, S, D); Sample a Grid writes back.
- **Coordinates:** coordinate systems of grids (Modify Coordinate System, Reproject); the wizard is shared.
- **Map / Map Tools:** Display on Map draws into maps; contours, colour bars and legends are in Map Tools; Plot commands (TIN, trends, suture, variogram) draw into the current map.
- **Project:** default grid format and element type, default colour table, default colour method (General Settings); Project Explorer Grids node and Jobs tab.
- **2D Filtering extension:** FFT filters and RTP.

### 3.4 Patterns worth noting

- Many commands exist twice: a "nice" dialog and a "control file" version, or a convolution version and an FFT version.
- Many commands are "Plot X on current map" helpers (TIN mesh, nodes, Voronoi, hull, trends, suture path, variogram, histogram, ternary legend).
  They are drawing tools, not processing tools.
- Multi-grid batching appears in several places with the same pattern: list of inputs, prefix, suffix, folder, display option (Grid Multiple Channels, Copy/Convert, Reproject, MAGMAP).
- Heavy tools all share the same background job model with a Jobs tab and rerun.
- Defaults are smart and data-driven: cell size, blanking distance, search radius, vertical shading scale, colour breaks.
  Many fields are "blank means auto".

## 4. Fit in JuliaMag

### 4.1 Main ideas

**Idea 1: split the Oasis menu by what each command really is.**
The Oasis menu mixes four kinds of things.
In a GIS-style app they belong in different places:

| Kind | Oasis examples | JuliaMag place |
|---|---|---|
| Processing tools (grid in, grid out; channel in, grid out) | Grid Data, Regrid, Window, Grid Math, Filters, Merge | Ribbon tools (function plus description), run as jobs. |
| Display and styling | Display on Map > Grid, composites, Colour Tool, Interactive Shading | Built-in map layer styling: a contextual "Grid Style" area and the layer's properties, not tools. |
| File conversion | Copy/Convert, Import ASCII Grid, Export Grid to XYZ | The import/export system (pluggable importers and exporters). |
| Inspection | Properties, Point Values, Grid Histogram, Grid UTM Zone | Built-in: Project Explorer properties, map cursor readout, histogram in the style pane. |

**Idea 2: "Display on Map" becomes "add layer" plus styling.**
In RustGIS a raster is a layer in a map, and its look is set in the Style tab with "Rendering" groups that appear when a raster layer is selected.
RustGIS's raster model already has most of what Oasis offers:

- Stretch types: min-max, custom, percent clip, standard deviation, histogram equalize (`crates/map/src/raster.rs`, `Stretch`).
- Renderers: colour ramp, classify, unique values, and `ShadedRelief` with azimuth, altitude, z-factor and an optional colour ramp tint (`RasterRenderer`).
- Brightness, contrast, gamma, resampling (smooth or nearest, like Oasis "smoothing"), layer blend modes, transparency, swipe compare.

So in JuliaMag:

- "Display grid on map" = drag the grid from the Project Explorer onto a map, or right-click "Add to map".
- Colour method (linear, normal, histogram equalization, log-linear), colour table, reverse, min/max clip, contour-rounded breaks, brightness, transparency, shading (normal or wet look, sun angles, scale, shadow grid) are layer style settings.
- A 2-grid composite is two layers with a blend mode, or one layer with "shade from another grid".
- 3-grid and 4-grid composites and ternary are a multi-band renderer (RGB/CMY from three grids).
- Interactive shading is a live control in the style area, with a "drag the sun on the map" mode.

**Idea 3: FFT and RTP get their own group or tab.**
Oasis keeps space-domain filters in Grid and Image and FFT filters in an extension.
That split is historical (licensing), not useful to the user.
I suggest one place for all grid filters, grouped by purpose, with the method (FFT or convolution) as a setting.
For example "Vertical derivative" is one tool with `method = fft | convolution`, as Oasis already does for Analytic Signal and Tilt.

**Idea 4: one "batch" mechanism for all tools.**
Grid Multiple Channels, multi-grid Copy/Convert, Reproject and MAGMAP all repeat the same pattern.
The tool system should let any tool whose input is "one channel" or "one grid" run over a list, with output naming by prefix/suffix.
Then "Grid Multiple Channels" is not a separate command.

**Idea 5: drop control files.**
Oasis needs control files to reach hidden settings and to repeat runs.
JuliaMag's tool descriptions, job records and Julia script history do this better.
All settings should be in the tool description, with rarely used ones in an "Advanced" section.
An importer for Oasis `.con` files could come later if the user has many (guess: not needed).

### 4.2 Proposed ribbon layout

Tab **Grid and Image** (or renamed "Grids"; see open questions):

| Group | Commands |
|---|---|
| Gridding | Bi-directional, Minimum Curvature, Direct (quick look), Kriging, IDW, Multi-trend, TIN gridding |
| Regrid | Regrid (change cell size, filter rows, fill gaps) |
| Edit | Window (box), Clip to Polygon, Grid Math, Fill Dummies, Expand, Remove/Restore Trend |
| Merge | Knit, Mosaic, Mask by Grid (boolean) |
| Filters | Smoothing/convolution, Vertical Derivative, Continuation, Horizontal Gradient, Analytic Signal, Tilt Derivative, Generalised Derivative, AGC |
| FFT (or own tab "Magnetics") | RTP, Differential RTP, Reduce to Equator, Upward/Downward Continuation, Band-pass and regional/residual, Decorrugation, Power Spectrum |
| Grid to Lines | Sample Grid to Channel, Grid Profile, Grid to Points, Find Peaks |
| Coordinates | Reproject Grid, Set Coordinate System (shared with the Coordinates tab) |

Map tab or contextual "Grid Style" (when a grid layer is selected): colour method, colour table, reverse, clip, shading, composite/blend, colour bar.

### 4.3 Per command

Priority key:

- **v1** = foundation version in the draft design.
  The draft says gridding and RTP are not in v1, so only import, display and inspection of grids are v1.
- **Next** = the first processing release (the user's chain).
- **Later** = useful, after the chain works.
- **Skip** = not worth building, or covered by something else.

"Tool" = Julia function plus description, built into a ribbon button and dialog.
"Built-in" = part of the app's views, panes or core.

| Oasis command | JuliaMag place | Kind | Priority | Note |
|---|---|---|---|---|
| Grid Data: Bi-directional | Grid and Image > Gridding | Tool, background job | Next | Main method for airborne mag. Needs trend angle, splines, pre-sort, along-line filters. |
| Grid Data: Minimum Curvature | Grid and Image > Gridding | Tool, background job | Next | Named by the user. Use with a bi-directional edge mask. |
| Grid Data: Direct | Grid and Image > Gridding | Tool, job | v1 or Next | My call: cheap to build and useful to check an import by eye as a grid. |
| Grid Data: Kriging + variogram | Gridding | Tool, job | Later | Rare for mag data. |
| Grid Data: IDW | Gridding | Tool, job | Later | Simple, mostly geochemistry. |
| Grid Data: Multi-trend | Gridding | Tool, job | Later | Published algorithm, slow, specialist. |
| Grid Preview tab | Inside the gridding dialog | Built-in (tool preview hook) | Next | Live preview on a subsample or coarse cell size; show points; draw extents on the map. |
| Tinning: Create TIN, Grid using TIN | Gridding (one tool "TIN gridding") | Tool | Later | One tool, TIN kept internal, no `.tin` file. |
| Tinning: Plot mesh, nodes, Voronoi, hull | Map layer options of a TIN item | Built-in view | Skip or Later | Display options, not commands. |
| Sample a TIN | Grid to Lines | Tool | Skip | Sample a grid covers the need. |
| Grid Multiple Channels | Batch mode of every gridding tool | Built-in (tool system) | Next | No separate command. |
| Advanced Options dialogs | "Advanced" section of each tool's dialog | Built-in (dialog builder) | Next | |
| Regrid a Grid | Grid and Image > Regrid | Tool | Next | Needed to change cell size and fill small gaps. |
| Trend Enforcement (Find, Plot, Add) | Gridding > advanced | Tool + map digitising | Later | Needs trend line type in the line database. |
| Gridding from Control File (3) | none | | Skip | Tool settings, job records and scripts replace them. |
| Plot Variogram | Kriging dialog plot | Built-in | Later | Comes with kriging. |
| Display on Map: Grid | Add grid to map + layer style | Built-in view | v1 | The draft already plans grid colour and hillshade. Add histogram equalization, linear, normal, log-linear, reverse, clip, brightness. |
| Display on Map: Image | Import image as a map layer | Import system + built-in | Later | GeoTIFF RGB, georeferenced images. |
| Grid Histogram | Histogram in the grid style pane; on a printed map later | Built-in | v1 (in pane), Later (on map layout) | |
| Ternary Image + Legend | Layer renderer "ternary from 3 grids" | Built-in view | Later | Radiometrics, not magnetics. |
| 2-Grid Composite | Layer blend, or "shade from grid" option | Built-in view | Next | Colour plus shading is the standard mag map look. |
| 3-/4-Grid Composite | Multi-grid renderer | Built-in view | Later | |
| Create Colour Zone File | "Share colour scale" across selected grids | Built-in (style) | Later | Useful for many blocks of one survey. |
| Grid Math | Grid and Image > Edit | Tool | Next | Expression over named grids. Could use a safe Julia expression subset. |
| Window a Grid | Edit | Tool | Next | Box drawn on the map or typed. |
| Window using Polygon File | Edit ("Clip to Polygon") | Tool | Later | Polygon from a drawn shape or polygon item, not only `.ply` files. |
| Knit Two / Multiple Grids | Merge | Tool, job | Later | Blend and suture methods. |
| Plot Suture Path | Output layer of the knit job | Built-in | Later | |
| Boolean Operations | Merge ("Mask by Grid") | Tool | Next | Needed for the min-curvature-plus-bigrid edge mask. |
| Grid Mosaic | Merge | Tool | Later | |
| Copy/Convert Grid(s) | Export system (and import system) | Exporter / importer | v1 | `.grd` (read compressed and uncompressed), `.ers`, GeoTIFF already planned. |
| Import ASCII Grid | Import system | Importer | Later | Also ESRI ASCII grid (guess: more common than Geosoft's raw ASCII). |
| Create Master Grid | | | Skip | Little use for mag processing. |
| Grid Outline | Edit or Grid to Lines | Tool | Later | Output a polygon item. |
| Point Values | Map cursor readout and identify | Built-in view | v1 | Show values of all grid layers under the cursor in the status bar. |
| Sample a Grid | Grid to Lines (also listed in Database Tools via command search) | Tool | Next | Writes a channel; used for levelling checks. |
| Grid Profile | Profile along a line drawn on the map, in the profile view | Built-in view, plus tool to save as a line | Later | |
| Save Grid to Database | Grid to Lines ("Grid to Points") | Tool | Later | |
| Export Grid to XYZ | Export system | Exporter | Later | |
| Reproject Grid File(s) | Coordinates group / Coordinates tab | Tool, job | Next | The draft already promises a reproject tool. |
| Grid UTM Zone | Grid properties pane (info line) | Built-in | Skip as command | Show "covers UTM zones 33N (80%), 34N (20%)" in properties for geographic grids. |
| Modify Coordinate System | Properties pane, editable, undoable | Built-in | v1 | Needed when an imported grid has no `.gi`. |
| Transpose Grid | | | Skip | Storage detail; JuliaMag stores one layout. |
| Expand Grid | Edit, and inside FFT prep | Tool | Next (inside FFT) | Standalone later. |
| Fill Grid Dummies | Edit, and inside FFT prep | Tool | Next | Maximum entropy and inverse distance. |
| Grid Volume | Edit or a report in properties | Tool | Later | |
| Grid Peaks | Grid to Lines | Tool | Later | |
| 3x3 / 5x5 / 7x7 / 9x9 Convolution | Filters ("Convolution filter" with kernel presets) | Tool | Later | One tool, kernel size and preset as settings. Hanning smoothing is the common case. |
| Vertical Derivative Convolution | Filters > Vertical Derivative (method setting) | Tool | Next | Same tool as the FFT version. |
| Vertical Continuation Convolution | Filters > Continuation (method setting) | Tool | Later | FFT version is next. |
| Shaded Relief | Layer style (shading); optional tool "Save shaded grid" | Built-in + tool | v1 (display), Later (tool) | |
| Horizontal Gradient | Filters | Tool | Next | |
| Trend | Edit (Remove/Restore Trend) | Tool | Next | Store removed coefficients with the grid. |
| Automatic Gain Correction | Filters | Tool | Later | |
| Analytic Signal | Filters | Tool | Next | |
| Generalised Derivative | Filters | Tool | Later | |
| Tilt Derivative (+ tilt depth) | Filters | Tool | Next (tilt), Later (tilt depth) | |
| Properties | Project Explorer properties pane | Built-in | v1 | Size, cell, origin, rotation, CS, type, compression, stats, histogram, provenance (job). |
| MAGMAP RTP (extension) | FFT group or Magnetics tab | Tool, job | Next | Chain step 6. One tool that does trend, expand, fill, FFT, filter, inverse, mask, restore. |
| MAGMAP other filters | FFT group | Tools, jobs | Next (continuation, derivatives), Later (the rest) | |

### 4.4 Things that would change the draft design

1. **Grid data model needs more fields.**
   The draft says "raw arrays plus metadata".
   From the help, a grid also needs:
   - rotation angle (Oasis grids can be rotated);
   - point registration (origin at the centre of the lower-left cell), and a clear rule for converting to and from cell-corner formats like GeoTIFF and ESRI;
   - a dummy rule (NaN inside JuliaMag; map to the file's dummy value on read and write);
   - removed-trend coefficients, so "restore trend" works;
   - the source element type and compression (to report it, and maybe to write it back);
   - the colour state of the grid (Oasis keeps it in the `.gi`; see the open question on per-grid versus per-layer colours).
2. **Geosoft `.grd` compressed writing may matter sooner.**
   Oasis's default for new grids is "Compressed 32-bit float".
   Reading compressed is already planned.
   Writing uncompressed first is fine, since Oasis reads both, but files will be larger than what users are used to.
   The `.gi` side file holds the coordinate system.
   The reader should read it, and the writer should write it, or Oasis will see grids with no coordinate system.
   The help does not document the `.gi` format (needs investigation).
3. **Tool descriptions need richer setting types.**
   - "Blank means automatic" numbers with defaults computed from the inputs (cell size from line spacing, blanking distance, search radius, shading scale).
   - An "extent" type that can be drawn on the map.
   - A "point" or "polyline" type picked on the map (Point Values, Add Trend Line, legend location).
   - Channel inputs filtered by channel class (mask channels have class MASK) and array element (`Chan[1]`).
   - Lists of inputs (several channels, several grids) for batch runs.
   - An "Advanced" section, and "Restore defaults".
   - Settings remembered per input database (Oasis recalls gridding settings per database).
4. **Tool preview hook.**
   Gridding (Grid Preview), the 2D Filtering interactive spectrum filter, and interactive shading all show live results before running.
   The tool system should allow an optional "preview" function that runs fast on a subsample, drawn in the dialog or on the map.
5. **Batch mode in the tool system.**
   See Idea 4.
   It replaces Grid Multiple Channels and the multi-file parts of Copy/Convert, Reproject and MAGMAP.
6. **Output display policy.**
   Oasis offers "display in grid window", "add to current map", "do not display" for outputs.
   The draft adds outputs to the Data tab.
   Add a per-run option "add to the current map".
7. **Job reports.**
   Oasis gridding writes a log (`bigrid.log` lists skipped lines).
   Job records should keep a text report next to the settings, shown in the Jobs tab.
8. **Hidden cache items.**
   MAGMAP keeps `_prp` and `_trn` grids to reuse.
   JuliaMag should keep such intermediates in a project cache, keyed by input and prep settings, not as user items.
9. **Line database: line types and channel classes.**
   The draft has Line and Tie.
   Grid commands use more line types: B (base), R (trend), S (special), D (random points; peaks and profiles go here).
   Channels have a "class" (MASK).
   This is mostly for the Database research, but gridding depends on it.
10. **Map view: no separate grid viewer.**
    Oasis opens a grid in its own grid viewer.
    I suggest JuliaMag has only map views: "Open" on a grid opens a map with that grid as its only layer.
    That keeps one view type and one styling system.
11. **Point Values belongs in v1.**
    A cursor readout of grid values is the cheapest way to check an imported grid.
    The draft's map view should show it in the status bar.

### 4.5 Suggested v1 scope for grids (from this menu)

- Import `.grd` (compressed and uncompressed, with `.gi`), `.ers`, and say clearly when a `.grd` is a Surfer grid.
- Export `.grd`, `.ers`, GeoTIFF.
- Add a grid to a map; colour methods linear, histogram equalization, normal, log-linear; colour table choice; reverse; clip; shading with sun angles and scale; transparency.
- Histogram in the grid style pane.
- Grid properties pane with stats and editable coordinate system.
- Cursor readout of grid values.
- Optional (my call): Direct gridding as a quick-look tool, to prove the tool system end to end with a real grid output.

## 5. Open questions for the user

1. Should "Display grid on map" colours belong to the grid (shared by every map that shows it, like Oasis's `.gi` ITR), to each map layer, or both (grid default plus a per-layer override)?
2. Where do FFT filters and RTP go: a group inside "Grid and Image", or their own tab (for example "Magnetics" or "Filters")?
3. Do you want the convolution and FFT versions of the same filter as one tool with a method setting, or as two tools like in Oasis?
4. Which gridding methods do you use today besides minimum curvature and bi-directional? Is gradient-enhanced bi-directional gridding needed (do your surveys have wing-tip gradiometers)?
5. Do you use tie lines in gridding (minimum curvature), or only for levelling?
6. Do you use trend enforcement (Find Trends, manual trend lines) in practice?
7. Do your `.grd` files from Oasis usually come with `.gi` files, and are they compressed? Sample files would help, since the help does not document the binary format.
8. Must JuliaMag write compressed `.grd` files, or is uncompressed fine for exchange with Oasis?
9. Do you need grid knitting or mosaicking (merging survey blocks) in the first processing release?
10. Is a quick-look Direct gridding tool in v1 useful to you, or should v1 stay strictly import and display?
11. Do you still use Oasis control files (`.con`) for gridding? Would an importer for them help?
12. Do you need ternary images and other radiometric display, or is JuliaMag magnetic-only for now?
13. Rename the tab "Grids" or keep the Oasis name "Grid and Image"? Images (non-data rasters) would mostly be handled by import, not by this tab.
