# Oasis montaj "Database Tools" menu: research for JuliaMag

Date: 2026-10-28
Source: Oasis montaj 2025.1 online help, <https://help.seequent.com/Oasismontaj/2025.1/Content/>.
Scope: the Database Tools menu only.
Other notes cover Project, Database, Coordinates, Grid and Image, and Map.

How this was gathered:

- The menu tree comes from the help's own table of contents (`Data/Tocs/geohelp.js`), section "Database Tools".
- That table of contents lists the menu flat.
  The real menu has submenus.
  The submenu of each command comes from the first sentence of its help page ("Use the Database Tools > Corrections > Lag Correction menu option ...").
- Every command page in the menu was read.
- One level of linked pages was read where it explains how commands work together: tie-line levelling, microlevelling, IGRF, 1D FFT.

Short URL form used below: `…/` means `https://help.seequent.com/Oasismontaj/2025.1/Content/`.
All links are written out in full in the tables.

## 1. Overview

Database Tools is the toolbox for line data (Oasis "databases", `.gdb`).
Each tool reads one or more channels of the current database and writes a new or existing channel.
A few tools work on whole lines (split, merge, copy) or on the whole database (resample, subset, merge databases).

It is a grab bag.
It mixes four kinds of things:

1. **Processing steps of the mag chain:** lag, heading and base station corrections, filters, channel math, apply levels.
2. **Data housekeeping:** copy, sort, split and merge lines, fiducial (sampling) fixes, lookups, masks.
3. **QC and reports:** statistics, differences, noise channels, profile plots.
4. **Tools for other data types:** array channels (EM, IP, radiometrics), geochemistry plots, density and velocity conversion.

How it fits the user's chain (import, lag, levelling, IGRF, gridding, RTP, maps):

| Chain step | What Database Tools offers | What lives elsewhere |
|---|---|---|
| Import | Split lines on a line channel, on X,Y breaks, on direction or at a fid. Set line types. Make line, fid and distance channels. | Database > Import (XYZ, CSV etc.) |
| Lag correction | Corrections > Lag Correction | Also repeated in Geophysics Levelling > Levelling Corrections |
| Other corrections | Heading Correction, Base Station Correction, Heading Calculation | |
| Clean-up and filtering | Despike, non-linear filter, low/high/band pass, convolution, rolling statistics, remove systematic noise, interpolate gaps | 1D FFT filters are in the Geophysics menu |
| Levelling | Apply Levels, Polynomial (trend), Interpolate, 1 Channel Lookup, Mark Statistics | Tie-line levelling and microlevelling are in the **Geophysics Levelling** extension menu, which reuses these tools |
| IGRF removal | Channel Math (for the subtraction) | IGRF Channel is in the **Geophysics** menu (and in Geophysics Levelling) |
| Gridding, RTP, maps | Window data to a polygon, subset database, Multiple Profile Plot (makes a map) | Grid and Image, Geophysics (1D FFT, RTP), Map menus |

Key point: **tie-line levelling, decorrelation (microlevelling) and IGRF are not in this menu.**
They sit in the Geophysics and Geophysics Levelling extension menus.
Those menus repeat many Database Tools commands (Lag, Heading, Base Station, Interpolate, Polynomial, Apply Levels, Table Lookup, Statistics).
So in Oasis the same command shows up in two or three menus.
Section 3 describes these flows, since the task asked for them.

## 2. Command inventory

Notation:

- "ch" means channel.
- Most tools write to an output channel that is created if it does not exist.
  Most allow the output to be the same as the input.
- "Lines to process" is a common setting: displayed line, selected lines, or all lines.
- `*` is the Oasis dummy (missing value).

### 2.1 Menu tree (as reconstructed)

```
Database Tools
├─ Channel Math
├─ Compact Database                (submenu not stated in help)
├─ Corrections
│   ├─ Lag Correction
│   ├─ Heading Correction
│   └─ Base Station Correction
├─ Filters
│   ├─ High Pass / Low Pass / Band Pass Filter
│   ├─ Mask to Channel
│   ├─ Despike Channel
│   ├─ Remove Systematic Noise
│   ├─ Non Linear Filter
│   ├─ Convolution Filter
│   ├─ Differences
│   ├─ Rolling Statistics
│   ├─ Create a Noise Channel
│   ├─ Polynomial
│   ├─ B-Spline
│   └─ Linear Regression
├─ Channel Tools
│   ├─ Apply Levels
│   ├─ Assign Fiducial from Channel
│   ├─ Average Repeated Locations
│   ├─ Change Channel Fid
│   ├─ Copy Channel / Copy Channel with Mask
│   ├─ Decimate Channels
│   ├─ Dummy Repeats
│   ├─ Interpolate
│   ├─ Make Distance Channel / Make Fid Channel / Make Line Channel
│   ├─ Pick Anomalies
│   ├─ Re-Fid a Channel
│   ├─ Search / Search/Replace
│   └─ Sort a Single Channel / Sort All by 1, 2, Multiple Channels
├─ Line Tools
│   ├─ Copy Line
│   ├─ Merge Lines
│   ├─ Multiple Profile Plot
│   ├─ Set Line Types from Channel
│   └─ Split on Changes in Direction / on Fiducial / on Line Channel / on X,Y Breaks
├─ Database Utilities
│   ├─ 1 Channel Lookup / 2 Channel Lookup / Cross-Database Channel Lookup
│   ├─ Heading Calculation
│   ├─ Merge Databases
│   ├─ Re-Fid to Distance Reference
│   ├─ Same Fid Start and Increment
│   └─ Convert Density to Velocity / Convert Velocity to Density
├─ Window Data
│   ├─ Create Polygon / Rectangular / Geographic PLY File
│   ├─ Draw from PLY File
│   ├─ Mask Channel to Polygon
│   ├─ Window X,Y to Polygon Mask / to Zmin/Zmax Mask
│   ├─ Restore Full X,Y
│   └─ Subset Database
├─ Reports
│   ├─ Line/Channel Report
│   ├─ Mark Statistics
│   └─ Total Distance
├─ Geostatistics Toolkit
│   ├─ Summary Statistics
│   ├─ Apply Mask to Data
│   ├─ Create Subset Database
│   ├─ Scatter Analysis
│   └─ Triplot Analysis
└─ Array Channels
    ├─ Window / Fractional Window / Average Rows/Columns / Sort Rows/Columns
    ├─ Database Channels to Array / Array to Database Channels
    ├─ Load Array Depths from Channel / Extract Array Base Properties to Channel / Create Depth Channel
    ├─ Subset Array / 2D -> 1D / 1D -> 2D
    ├─ Non Linear Filter > Along Line / Along Array
    └─ Convolution Filter > Along Line / Along Array
```

The help table of contents also lists three entries under Database Tools whose pages say they live elsewhere:

- Import Geosoft Binary (page says Database > Import).
- Export Database to Esri File Geodatabase (page says Database > Export).
- Select/Deselect Name or Mask (page is a drillhole tool, DH-Plot > Select Holes).

These may be leftovers in the help, or the menu may really include them.
I could not tell which.

### 2.2 Corrections

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Lag Correction (LAG) | Shifts a channel in time by changing its start fid, then resamples it back onto the original fids. | 1 ch -> 1 ch | Lag in fiducials (positive shifts data back in time). | [lag_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/lag_gx.htm) |
| Heading Correction (HEADING) | Removes a shift that depends on the direction of travel. Correction is linearly interpolated from a table of direction vs correction. | 1 ch + heading table file -> 1 ch | Table file (Geosoft table, directions in true heading, must include 0 and 360). | [heading_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/h/heading_gx.htm) |
| Base Station Correction (MAGBASE) | Subtracts diurnal variation measured at a base station. Uses the line's date plus a time channel to look up the correction. | data ch + time ch + base table file -> 1 ch | Base table (Date, Time, Correction columns; header holds the base value and location). | [magbase_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/magbase_gx.htm) |

Notes:

- Lag: when the lag is a whole number of fids, data simply shifts.
  Otherwise it uses piecewise linear interpolation.
  Data is lost at one end of each line.
- Heading: the help says modern surveys usually include this in aircraft compensation.
  It is needed for older or badly compensated surveys.
  The corrections come from a clover-leaf test flight.
- Base station: the help says corrections must be compiled into a table by date and time first.
  So the base station data is prepared outside the tool.
  Base station data import is not described on this page.

### 2.3 Filters

All lengths are in **fiducials** (samples), except Despike and Remove Systematic Noise, which use seconds and a time channel.

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Low Pass Filter (LOWPASS) | Smoothing convolution filter, designed after Fraser (1966). | 1 ch -> 1 ch | Cutoff wavelength (fids). Filter length = cutoff. | [lowpass_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/lowpass_gx.htm) |
| High Pass Filter (HIGHPASS) | Sharpening convolution filter (Fraser). | 1 ch -> 1 ch | Cutoff wavelength (fids). | [highpass_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/h/highpass_gx.htm) |
| Band Pass Filter (BANDPASS) | Removes features shorter than the short cutoff and longer than the long cutoff. Low and high pass are special cases. | 1 ch -> 1 ch | Short cutoff, long cutoff, filter length (0 = default). | [bandpass_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/b/bandpass_gx.htm) |
| Non Linear Filter (NLFILT) | Naudy-Dreyer (1968) spike filter. Replaces features narrower than a width and larger than a tolerance with interpolated values. Leaves the rest untouched. | 1 ch -> 1 ch | Width (points), tolerance (data units; default 10% of std dev). | [nlfilt_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/n/nlfilt_gx.htm) |
| Despike Channel | Removes high-amplitude, short spikes and dropouts. Naudy-Dreyer reference. Works per element on array channels. | 1 ch + time ch (hours) -> 1 ch | Spike width in seconds. | [despikechannel](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_field_despikechannel.htm) |
| Remove Systematic Noise | Removes noise of one fixed frequency (50/60 Hz power line, rotor noise), then smooths with a fixed 7-point filter. | 1 ch + time ch (hours) -> 1 ch | Frequency. | [removesystematicnoise](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/geosoft_gx_field_removesystematicnoise.htm) |
| Convolution Filter (FILTER) | Applies any user filter. Pads ends and fills holes by maximum entropy prediction, then removes them again. | 1 ch + coefficients (file or "c1,c2,...") -> 1 ch | Coefficients. Ships Fraser, Laplace and Savitzky-Golay filters. | [filter_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/f/filter_gx.htm) |
| Differences (DIFF) | n-th difference. The 4th difference is the standard noise QC. | 1 ch -> 1 ch | Number of differences, normalize (divide by 2^n). | [diff_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/diff_gx.htm) |
| Rolling Statistics (ROLLINGSTATS) | Moving-window statistic (mean, median, std dev, min, max, mode, skew and about 20 others). | 1 ch -> 1 ch | Statistic, window width (made odd), shrink window at ends. | [rollingstats_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/rollingstats_gx.htm) |
| Polynomial (TREND) | Least-squares polynomial per line. Writes the trend and/or the residual. | 1 ch -> trend ch and/or residual ch | Order 0-9. | [trend_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/trend_gx.htm) |
| B-Spline (BSPLINE) | Smoothing spline through a channel. | 1 ch -> 1 ch | Smoothness 0-1, tension 0-1. | [bspline_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/b/bspline_gx.htm) |
| Linear Regression (REGRESS) | Fits a line to the marked data of one line and reports slope and intercept. | marked range of X ch and Y ch -> report | Needs a marked range on one line. | [regress_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/regress_gx.htm) |
| Mask to Channel | Sets output to dummy where one or two conditions hold (=, !=, >, >=, <, <=; AND/OR). | 1 ch + condition chs -> 1 ch | Up to two conditions. | [maskchannel](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/geosoft_gx_field_maskchannel.htm) |
| Create a Noise Channel (NOISECHAN) | Fills a channel with random values (uniform, exponential, normal). For testing. | reference ch -> 1 ch | Distribution, seed. | [noisechan_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/n/noisechan_gx.htm) |

Overview page: [Spatial Domain Filters](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/apply_filters_gxs/c/applying_linear_spatial_domain_filters.htm).
It says to run the non-linear filter first and a linear low pass after it, to smooth what remains.

### 2.4 Channel Math

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Channel Math (Math Expression Builder) | Runs C-style expressions over channels row by row. Several equations allowed. | any chs -> any chs | Expression, mapping of variables (C0, C1, ...) to channels, expression file (save/load, plain text). | [channelmathexpressionbuilder](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/geosoft_gx_mathexpressionbuilder_channelmathexpressionbuilder.htm) |

Details seen in the help:

- Function tabs: frequent (conditional, log), special, string, trig, statistics (from one or more lines), offset (values from other rows), date, time.
- Conditional `C0 = (C1>5000) ? C2 : C3;`.
- Temporary variables start with `@`.
- Array elements by index, `C1[1]`.
- Values out of range become dummy.
- Output type follows the rightmost (or leftmost, for mixed conditionals) variable; the two statements in the help are not fully consistent.
- The same builder exists for grids and voxels ([Math Expression Builder](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/edit_preprocess_data/apply_mathematical_expressions/c/math_expression_builder.htm)).
- Table lookup functions exist but only in the spreadsheet window.

### 2.5 Channel Tools

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Apply Levels (LEVEL) | Adjusts a channel so it matches a sparse control channel (values at tie crossings). Linear between control points. | data ch + control ch -> 1 ch | Mode: Match, Minus, Plus. | [level_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/level_gx.htm) |
| Interpolate | Fills dummies. | 1 ch -> 1 ch | Method: linear, minimum curvature, Akima, nearest, prediction (max entropy). Max gap. Edge extrapolation and its length. | [interpolatechannel](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_interpolatechannel.htm) |
| Copy Channel (COPY) | Copies a channel, optionally decimated or with new fid start and step. | 1 ch -> 1 ch | Decimation, new fid start, new fid step. | [copy_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/copy_gx.htm) |
| Copy Channel with Mask (COPYMASK) | Copies, setting dummy where the mask is dummy. | data ch + mask ch -> 1 ch | | [copymask_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/copymask_gx.htm) |
| Make Distance Channel | Cumulative distance along each line from X,Y (optionally Z). | X, Y, (Z) -> 1 ch | Keep line direction, or make all lines increase in +X or +Y. | [distancechannel](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_distancechannel.htm) |
| Make Fid Channel (MAKEFID) | Writes the fid values as a channel. | reference ch -> 1 ch | Data type. | [makefid_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/makefid_gx.htm) |
| Make Line Channel (LINECHAN) | Writes the line name as a string channel. | reference ch -> 1 ch | Format letters: L line, T type, V version, F flight, D date. | [linechan_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/linechan_gx.htm) |
| Change Channel Fid (NEWFID) | Changes fid start and step of channels, no resampling. | chs -> same chs | New start, new step, lines. | [newfid_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/n/newfid_gx.htm) |
| Assign Fiducial from Channel | Sets fid start of all channels of a line from the first value of a channel; step 1. No resampling. | ref ch -> line fids | Lines. | [AssignFiducialFromChannel](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_AssignFiducialFromChannel.htm) |
| Re-Fid a Channel (REFID) | Resamples one channel onto a new axis given by a reference channel, usually distance. | data ch + ref ch -> 1 ch | New start, new step, max gap (default 1.5 x step), method (linear, min curvature, Akima, nearest). | [refid_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/refid_gx.htm) |
| Decimate Channels | Keeps every n-th sample of chosen channels. | chs -> same chs | Factor, lines. | [decimatechannels](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_decimatechannels.htm) |
| Average Repeated Locations (AVGREPXY) | Averages values at identical X,Y; first gets the average, repeats become dummy. | 1 ch -> same ch | | [avgrepxy_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/a/avgrepxy_gx.htm) |
| Dummy Repeats (DUMREP) | Sets repeated values to dummy, keeping first, last or middle. | 1 ch -> same ch | Which value to keep. | [dumrep_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/dumrep_gx.htm) |
| Pick Anomalies (ANOMPICK) | Marks local peaks above a base level whose drop to the troughs on both sides exceeds a minimum. | chs -> `<ch>_A` chs | Base level, min amplitude, output as value, number or letter. | [anompick_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/a/anompick_gx.htm), [Target Picking](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/apply_filters_gxs/c/target_picking.htm) |
| Search (SEARCH) | Finds a value in the current channel, next or previous. | current ch | Partial or exact match. | [search_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/search_gx.htm) |
| Search/Replace (SEARCHREPLACE) | Replaces an exact value in a channel on selected lines. | 1 ch -> same ch | Value, replacement. | [searchreplace_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/searchreplace_gx.htm) |
| Sort a Single Channel (SORTCHAN) | Sorts one channel; breaks its link to the other channels. | 1 ch | Order. | [sortchan_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/sortchan_gx.htm) |
| Sort All by 1 / 2 / Multiple Channels (SORTALL, SORTALL2, SORTALLN) | Sorts all channels of each line by up to four key channels. | line -> line | Keys, orders, sort read-only channels. | [sortall](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/sortall_gx.htm), [sortall2](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/sortall2_gx.htm), [sortalln](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/sortalln_gx.htm) |

### 2.6 Line Tools

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Split on Line Channel | Splits lines by values in a line-number channel. For data imported with line number as a column. | lines + line ch -> new lines | Lines, reset fids to 0. Data must be sorted by the channel first. | [splitlinesonchannel](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/b/geosoft_gx_database_splitlinesonchannel.htm) |
| Split on X,Y Breaks | Splits where consecutive points jump sideways or along the line beyond a tolerance. | lines -> new lines | Line direction, lateral and down-line tolerances, naming rule. | [splitlinesonxy](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/x/geosoft_gx_database_splitlinesonxy.htm) |
| Split on Changes in Direction | Splits at turns. Can keep the turn segments as "Disc" special lines. | lines -> new lines | Max angle change over a distance, XY gap, min line length. | [splitlinesbydirection](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_splitlinesbydirection.htm) |
| Split on Fiducial | Splits one line at a fid. Used to cut a whole flight into lines. | 1 line -> 2 lines | Fid, reset fids. | [splitlineatfid](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/geosoft_gx_database_splitlineatfid.htm) |
| Merge Lines (MERGLINE) | Joins lines end to end in a chosen order. Does not align fids; user must check. | lines -> 1 line | Order. | [mergline_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/mergline_gx.htm) |
| Copy Line (COPYLINE) | Copies a line under a new name. | 1 line -> 1 line | | [copyline_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/copyline_gx.htm) |
| Set Line Types from Channel (LINETYPECHAN) | Sets line type (Line, Base, Tie, Test, Trend, Special, Random) from a code in a channel. | code ch -> line metadata | Code for each type. | [linetypechan_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/linetypechan_gx.htm) |
| Multiple Profile Plot | Draws up to 5 panels of up to 5 profiles each onto a **map**, for selected lines. | chs + lines -> map | X-axis channel, panel channels, y scaling (separate, same, same range centred, fixed), styles, colours, symbols, log scales. | [multipleprofileplottool](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_multipleprofileplottool.htm) |

### 2.7 Database Utilities

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Re-Fid to Distance Reference (REFIDDB) | Resamples the whole database onto a new axis (usually distance). Same as Re-Fid on every channel. | db + ref ch -> db | Start, step, max gap, method. | [refiddb_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/refiddb_gx.htm) |
| Same Fid Start and Increment (RESAMPDB) | Resamples all channels to the fid start, step and length of one channel. Fixes the "red bar" (misaligned channels) state. | db + ref ch -> db | Reference channel. | [resampdb_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/r/resampdb_gx.htm) |
| 1 Channel Lookup (LOOKUP1) | Fills a channel from a Geosoft table, keyed on one channel. | key ch + table -> 1 ch | Fields, mode (exact, nearest, interpolate, nearest close, interpolate close), linear or binary search, nominal spacing. | [lookup1_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/lookup1_gx.htm) |
| 2 Channel Lookup (LOOKUP2) | Same, with two keys. Help says it suits date + time lookups. | 2 key chs + table -> 1 ch | As above. | [lookup2_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/lookup2_gx.htm) |
| Cross-Database Channel Lookup (LOOKUPDBCH) | Copies a channel from another database by matching a key channel on the same line names. | other db + key ch -> 1 ch | Method, max search distance. | [lookupdbch_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/lookupdbch_gx.htm) |
| Heading Calculation | Computes heading from X,Y with a fixed 7-point smoothing filter. | X, Y -> 1 ch | Smoothing passes. | [headingcalculation](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_headingcalculation.htm) |
| Merge Databases (DBMERGE) | Merges databases into one. Also under Database > Import. | dbs -> db | Lines, channels, replace / fill empty / append. | [dbmerge_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/dbmerge_gx.htm) |
| Convert Density to Velocity / Velocity to Density | Empirical rock property conversions (Gardner, Nafe-Drake etc.). | 1 ch -> 1 ch | Units, method. | [density_to_velocity](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_density_to_velocity_gx.htm), [velocity_to_density](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/geosoft_gx_velocity_to_density_gx.htm) |
| Compact Database | New database without rows that have a dummy in any chosen channel. (Submenu not stated.) | db -> new db | Channels to check. | [compactdatabase](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/geosoft_gx_field_compactdatabase.htm) |

### 2.8 Window Data

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Create Polygon PLY File (POLYDEF) | Digitise polygons on a map into a `.ply` file. Inclusive or exclusive (holes). | map clicks -> .ply | New or append. | [polydef_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/p/polydef_gx.htm) |
| Create Rectangular PLY File (WINRECT) | Rectangle from min/max X,Y or drawn on the map. | -> .ply | | [winrect_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/w/winrect_gx.htm) |
| Create Geographic PLY File (POLYGEO) | Rectangle in lon/lat, projected and densified. | -> .ply | Lon/lat limits, points per side. | [polygeo_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/p/polygeo_gx.htm) |
| Draw from PLY File (POLYDRAW) | Draws polygons on a map. | .ply -> map | Style. | [polydraw_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/p/polydraw_gx.htm) |
| Mask Channel to Polygon (POLYMASK) | Dummies a (mask) channel inside or outside polygons. | X, Y, .ply -> mask ch | Inside or outside. | [polymask_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/p/polymask_gx.htm) |
| Window X,Y to Polygon Mask (WINXY) | Dummies X and Y outside a polygon, so all later maps and grids use only that area. Backs up originals to `__X`, `__Y`. | .ply -> X, Y | Inside or outside. | [winxy_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/w/winxy_gx.htm) |
| Window X,Y to Zmin/Zmax Mask (WINZ) | Same, by a value range of a channel. | ch -> X, Y | Zmin, Zmax. | [winz_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/w/winz_gx.htm) |
| Restore Full X,Y (WINOLD) | Copies `__X`, `__Y` back. | -> X, Y | | [winold_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/w/winold_gx.htm) |
| Subset Database (DBSUBSET) | New database with chosen lines and channels, optionally dropping rows where a mask is dummy. | db -> new db | Lines, channels, dummy removal, compression. | [dbsubset_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/dbsubset_gx.htm) |

### 2.9 Reports

| Command | What it does | Inputs -> outputs | Key settings | Help |
|---|---|---|---|---|
| Line/Channel Report (XYZSTAT) | Per-line and total min, max, mean, std dev, count; X,Y also get total distance. | chs + selected lines -> text file | Channels, file. | [xyzstat_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/x/xyzstat_gx.htm) |
| Mark Statistics (STAT) | Full statistics of the marked cells (count, dummies, min, max, mean, median, mode, std dev, skew, kurtosis, sum). Also on the spreadsheet right-click menu. | marked data -> dialog / file | | [stat_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/stat_gx.htm) |
| Total Distance (TOTLDIST) | Total line-km from X,Y. | X, Y -> report | | [totldist_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/t/totldist_gx.htm) |

### 2.10 Geostatistics Toolkit

Mainly geochemistry tools that also appear in the Geochemistry extension.

| Command | What it does | Help |
|---|---|---|
| Summary Statistics (GSTSTAT) | Basic and advanced statistics of a channel, with optional mask. | [gststat_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/g/gststat_gx.htm) |
| Apply Mask to Data (CHPOLY) | Mask channel (1 or dummy) from a polygon file, inside or outside, new or append. | [chpoly_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/chpoly_gx.htm) |
| Create Subset Database (CHSUBSET) | New database with only rows where the mask is not dummy. | [chsubset_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/c/chsubset_gx.htm) |
| Scatter Analysis (CHSCAT) | Interactive scatter plot of two channels with templates. | [scatter](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/geochem/edit_preprocess_data/visualise_data_qc_control/use_interactive_visualization_tools/r/id_chimera_scatter_channels.htm) |
| Triplot Analysis (CHTRIPLOT) | Ternary plot of three channels. | [triplot](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/geochem/edit_preprocess_data/visualise_data_qc_control/use_interactive_visualization_tools/r/id_chimera_triplot_channels.htm) |

### 2.11 Array Channels

Array channels hold several values per sample (EM time gates, IP windows, radiometric spectra).
Overview: [Filtering Array Data](https://help.seequent.com/Oasismontaj/2025.1/Content/ss/process_data/apply_filters_gxs/c/filtering_array_data.htm).

| Command | What it does | Help |
|---|---|---|
| Window (VAWINDOW) | Sum or average of a range of elements into a normal channel (e.g. a radiometric window). | [vawindow_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vawindow_gx.htm) |
| Fractional Window (VAWINDOW2) | Same with fractional element bounds. | [vawindow2_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vawindow2_gx.htm) |
| Average Rows/Columns (VAAVERAGE) | Averages along or across the array. | [vaaverage_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vaaverage_gx.htm) |
| Sort Rows/Columns (VASORT) | Sorts each row or column independently. | [vasort_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vasort_gx.htm) |
| Database Channels to Array / Array to Database Channels | Pack normal channels into an array, or unpack. | [channelstoarray](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_channelstoarray.htm), [arraytochannels](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/geosoft_gx_database_arraytochannels.htm) |
| Load Array Depths from Channel / Extract Array Base Properties to Channel / Create Depth Channel | Store or create the per-element axis (depth, time, frequency) of an array. | [load](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/Geosoft_GX_Database_LoadArrayPropertyFromChannel.htm), [extract](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/Geosoft_GX_Database_ExtractArrayBasePropertiesToChannel.htm), [vsctdpch](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vsctdpch.htm) |
| Subset Array (VA2VA) | Keep a range of elements. | [va2va_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/va2va_gx.htm) |
| 2D -> 1D (VA2VV) / 1D -> 2D (VV2VA) | Flatten an array to one long series and back, so 1D filters can be used. | [va2vv_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/va2vv_gx.htm), [vv2va_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vv2va_gx.htm) |
| Non Linear Filter / Convolution Filter, Along Line or Along Array | The normal filters, applied down the line or across the elements. | [vanlfilt_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vanlfilt_gx.htm), [vacvfilt_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/v/vacvfilt_gx.htm) |

## 3. How the commands work together

### 3.1 Concepts every tool depends on

These are not commands, but almost every page assumes them.
JuliaMag needs them in the data model, not just in tools.

- **Fiducials per channel.**
  In Oasis, each channel in a line has its own fid start and step.
  When channels on a line disagree, Oasis shows a red bar on the channel header.
  Lag correction changes the start fid and then resamples back.
  Re-Fid, Decimate and Change Channel Fid can leave channels misaligned on purpose.
  Same Fid Start and Increment and Re-Fid to Distance Reference repair this.
- **Selected lines, displayed line, all lines.**
  Most tools take a "lines to process" choice.
  Line selection is persistent state in the database.
- **Marked range.**
  Linear Regression and Mark Statistics work on a range of cells the user has marked in the spreadsheet or profile.
- **Line types and names.**
  Lines have a type (Line, Tie, Base, Test, Trend, Special, Random), a number, a version and a flight (shown as `L100.2:3`).
  Levelling tools filter by type ("Tie", "Line", "Selected").
- **Line date.**
  Base Station Correction uses "the date of each line".
- **Dummies as masks.**
  A mask channel is 1 where data is kept and dummy where it is not.
  Channels have a CLASS attribute; MASK is one value.
- **Current X and Y.**
  Many tools use "the designated X,Y channels" set in the Coordinates menu.
  Window X,Y works by dummying these, which hides data from every later map tool.
- **Side files.**
  Geosoft table files (`.tbl`) feed Base Station, Heading and Lookup.
  Polygon files (`.ply`) feed windowing and masking.
  Filter files (`.flt`) feed Convolution Filter.
  Expression files feed Channel Math.

### 3.2 Import clean-up

Typical sequence after Database > Import:

1. Split on Line Channel, Split on X,Y Breaks, Split on Changes in Direction, or Split on Fiducial, to get one Oasis line per survey line.
2. Set Line Types from Channel, so ties are marked as Tie lines.
3. Make Distance Channel, Make Line Channel, Make Fid Channel as needed.
4. Line/Channel Report and Total Distance as a first QC.

### 3.3 Corrections and filtering (before levelling)

1. QC noise: Differences (4th difference), Rolling Statistics, Mark Statistics, profile view.
2. Remove spikes: Despike Channel or Non Linear Filter.
3. Remove fixed-frequency noise if present: Remove Systematic Noise.
4. Fill gaps: Interpolate.
5. Lag Correction on the mag channel (lag found by eye in the profile, comparing lines flown in opposite directions; the help does not describe how to find the lag, this is my reading).
6. Heading Correction if the system did not compensate.
   Select/Deselect Direction (Geophysics Levelling menu) helps find heading effects by selecting lines by direction ([seldir_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/s/seldir_gx.htm)).
7. Base Station Correction for diurnal variation.
8. Optional smoothing: Low Pass after the non-linear filter.

### 3.4 IGRF removal (other menu)

IGRF Channel ([igrfchannel](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/i/geosoft_gx_igrf_igrfchannel.htm)) is in Geophysics > IGRF, and also in Tie Line Levelling > Levelling Corrections.

- Inputs: date (string or Date channel), longitude, latitude, elevation (channel or one value, metres).
- Outputs: field strength (nT), inclination and declination channels.
- Model year is picked from the date; definitive (DGRF) by default, IGRF forward model optional.
- The tool does not subtract the field.
  The residual is then made with Channel Math (`resid = mag - igrf`).
  This last step is my inference; the page does not say it.

### 3.5 Tie-line levelling (other menu, reuses this one)

Geophysics Levelling > Tie Line Levelling ([overview](https://help.seequent.com/Oasismontaj/2025.1/Content/levelling/oasis_montaj_levelling.htm)).
Its submenus are Levelling Utilities, Levelling Corrections, Intersections, Load Corrections, Simple Levelling, Careful Levelling.
Levelling Utilities and Levelling Corrections are almost entirely Database Tools commands (Statistics, Interpolate, Trend, Apply Levels, Table Lookup, Base Station, Lag, Heading, IGRF Channel) plus Sample a Grid and Select/Deselect Direction.

The flow, from the linked pages:

1. **Intersections** ([page](https://help.seequent.com/Oasismontaj/2025.1/Content/levelling/geosoft_gx_levelling_intersections.htm)): find line/tie crossings and write an intersection table or database, with mis-tie statistics.
   Settings: data channel, tolerance (default 10 x sample spacing), tie lines or all lines.
2. **Load Corrections** (XLEVEL, [page](https://help.seequent.com/Oasismontaj/2025.1/Content/levelling/xlevel_gx.htm)): turn the table into sparse channels on each line: the crossing value, the difference, and the cross-gradient.
   Intersections with high gradient can be dropped.
3. Level the ties first, then the lines:
   - **Simple:** Statistical Level (STATLEV, polynomial order 0-9 through the difference channel; [page](https://help.seequent.com/Oasismontaj/2025.1/Content/levelling/statlev_gx.htm)), Full Level (linear between crossings; [page](https://help.seequent.com/Oasismontaj/2025.1/Content/levelling/fulllev_gx.htm)), or Iterative Levelling (ties to lines, lines to ties, until it converges, usually 2 rounds; [page](https://help.seequent.com/Oasismontaj/2025.1/Content/levelling/geosoft_gx_levelling_iterativelevelling.htm)).
   - **Careful:** Shift, Tilt, Spline or Tensioned Spline corrections build a correction channel, and Apply Correction adds it ([lvcorr](https://help.seequent.com/Oasismontaj/2025.1/Content/levelling/lvcorr_gx.htm)).
4. **Apply Levels** (Database Tools > Channel Tools) is the general "match a channel to sparse control values" step that this flow ends with ([level_gx](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/l/level_gx.htm)).
   For smooth corrections, the help suggests: subtract control from data, smooth with Interpolate (spline) or Polynomial, then Apply Levels with Minus.

### 3.6 Microlevelling / decorrugation (other menu)

Geophysics Levelling > Microlevelling, two steps by design:

1. **Extract Noise** (DECORR, [page](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/d/decorr_gx.htm)): grids the channel (minimum curvature, cell = line spacing / 5), applies a directional high-pass across the lines (cutoff = 4 x line spacing), and samples the noise grid back to a channel.
   Inputs: X, Y, data channel, line spacing, line azimuth.
2. The user inspects the noise grid: flight-line noise shows as long stripes along the lines.
3. **Microlevel** (MICLEV, [page](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/m/miclev_gx.htm)): clips the noise by an amplitude limit (default = std dev of the noise grid), low-passes it along the line with a Naudy filter (default width = 5 x line spacing), and subtracts it.
   Lines shorter than 4 x filter width are treated differently.

This is the one place where the line-data and grid worlds meet inside a levelling step.

### 3.7 Resampling and FFT filtering (links to Geophysics menu)

1D FFT filters (Geophysics > 1D FFT > 1D Filtering, [page](https://help.seequent.com/Oasismontaj/2025.1/Content/gxhelp/f/fft1mult.htm)) need evenly spaced data with no gaps.
The usual chain is: Make Distance Channel, Re-Fid to distance (Re-Fid a Channel or Re-Fid to Distance Reference), Interpolate with "Prediction" and periodic edges, run the FFT filter, then Re-Fid back to fiducial.
1D Filtering has a live spectrum and profile preview, with up to six filters at once (including RTP, continuation, derivatives).

### 3.8 Area selection before gridding and maps

1. Create Polygon / Rectangular / Geographic PLY File.
2. Either Window X,Y to Polygon Mask (destructive, with `__X` backup) or Mask Channel to Polygon (non-destructive mask).
3. Subset Database or Compact Database to make a smaller database.
4. Grid from the windowed X,Y (Grid and Image menu), then Restore Full X,Y.

## 4. Fit in JuliaMag

### 4.1 Main recommendations

1. **Do not make one big "Database Tools" tab that copies the Oasis menu.**
   It mixes processing, housekeeping, QC and other data types.
   RustGIS's own ribbon rule is "use the tab's purpose to decide where a feature belongs".
   Split by purpose instead:
   - The draft's **Database Tools** tab keeps general line-data tools: channels, lines, sampling, area masks.
   - A new **Magnetics** tab (the draft already allows one) holds the chain in work order: Corrections (lag, heading, diurnal), IGRF, Levelling (tie-line, microlevelling), later RTP for lines.
   - A **Filters** group (or tab) holds the 1D filters, because they serve every data type.
   This turns Oasis's three menus (Database Tools, Geophysics, Geophysics Levelling) into one place per task.
2. **One tool, several places.**
   Oasis repeats Lag, Heading, Interpolate, Trend and Apply Levels in up to three menus.
   In JuliaMag, a tool should be written once and may be shown in more than one ribbon group.
   **Draft change:** the tool description should allow a list of (tab, group) placements, not just one.
3. **Long tail goes to command search and a Tools pane, not the ribbon.**
   RustGIS has a Geoprocessing "Tools" pane ("Find and run geoprocessing tools") next to command search.
   JuliaMag should have the same: a searchable list of every tool by category.
   Only the 10 to 20 most used tools get ribbon buttons.
   Sort, Search/Replace, Dummy Repeats, Make Fid Channel and similar live there and in context menus.
4. **Spreadsheet actions belong to the Database view's context menu.**
   Search, Search/Replace, sort, mark statistics, copy channel, new channel by expression: Oasis users do these from the spreadsheet already (Mark Statistics is on the right-click menu there).
5. **Reports become views, not text files.**
   Line/Channel Report, Mark Statistics, Summary Statistics and Total Distance should be a Statistics pane that follows the current selection (channel, line, marked range), with "Save as CSV".
6. **Destructive "window X,Y" becomes a mask or a filter.**
   Oasis dummies X,Y and keeps `__X` copies.
   This is fragile: every later tool silently sees a smaller area.
   JuliaMag should use explicit masks: polygons are project items (drawn on the map, imported from `.ply` or shapefile) and tools take an optional "area" input.
7. **Channel Math as a first-class tool and as a scripting bridge.**
   Every Oasis chain uses it (IGRF residual, unit changes, combining corrections).
   JuliaMag can offer an expression box that compiles to a Julia function.
   Expressions must be checked: only channel names, numbers, operators and a list of allowed functions.
   Full Julia stays in the script/REPL path the draft already plans.

### 4.2 Data model points that affect the draft design

These came out of reading the tools.
They should be decided before tools are written.

1. **Fiducials per line vs per channel.**
   The draft stores "a fiducial start and step" per line.
   Oasis stores them per channel, and many tools (Lag, Re-Fid, Decimate, Change Channel Fid) rely on that.
   The per-channel model creates the "red bar" state, which confuses users and needs repair tools (Same Fid Start and Increment).
   Recommendation: keep **one sampling per line** in JuliaMag.
   Lag correction then resamples the output onto the line's fids (as Oasis does at the end anyway).
   Re-Fid, Decimate and "resample to distance" make a **new database** (or a new line set) instead of misaligned channels.
   Array channels and channels at a different rate (for example a 1 Hz GPS channel in 10 Hz mag data) are the real exception.
   Open question 1 asks the user about this.
2. **Line metadata.**
   The draft reads `Line` and `Tie` markers.
   Store per line: number, type (at least Line, Tie; Oasis also has Base, Test, Trend, Special, Random), version, flight, date.
   Levelling and base-station correction need type and date.
3. **Selection and marks.**
   Add a project-level "selected lines" set and a "marked range" (line + fid range) shared by the database view, profile view and map view.
   Every tool gets a standard "lines: selected / all / current" setting, built by the tool system, not by each tool.
4. **Channel roles.**
   Oasis finds X, Y, Time, Date, Long, Lat, Elev by designation or by name prefix.
   JuliaMag should store roles on channels (x, y, z, time, date, lon, lat, elevation, mask, line).
   Tool settings can then default to the right channel, as Oasis does.
   The tool description needs an input type like "a channel with role time".
5. **Missing values.**
   Oasis uses one dummy per data type.
   Use `NaN` for float channels.
   Integer and string channels need a defined missing marker in the storage format.
6. **Units for filter lengths.**
   Oasis filter lengths are in fiducials (samples), and despike uses seconds.
   JuliaMag should let the user enter lengths in samples, seconds or metres, and convert using the line's sampling and speed.
   This is a UI improvement; it does not change the math.
7. **Side files become importers.**
   Geosoft `.tbl` (base station, heading, lookup), `.ply` polygons and `.flt` filters should be small importers in the importer registry, producing project items (tables, polygons, filters).
   Then tools take project items, not file paths, and the job record stays reproducible.
8. **Jobs that need checking between steps.**
   Microlevelling is split in two so the user can inspect the noise grid.
   Iterative levelling can pause between rounds.
   The job system should allow a tool to produce intermediate items and stop, with the next tool pre-filled.
   A "task" (guided sequence), like RustGIS's Tasks pane, fits levelling well.

### 4.3 Placement table

Priority labels:

- **v1:** needed in the foundation release (import checking, data management, views).
- **Chain:** part of the first processing release after the foundation (lag, levelling, IGRF, filters).
- **Later:** useful, not urgent.
- **Skip:** out of scope for an airborne mag tool, or replaced by a better design.

"Tool" means a function plus description, run through the tool system.
"View" means built into a pane or view.

| Oasis command(s) | JuliaMag place | Kind | Priority | Note |
|---|---|---|---|---|
| Lag Correction | Magnetics > Corrections; also Database Tools > Channels | Tool, quick | Chain | Add a lag preview in the profile view (opposite-direction lines overlaid) to pick the lag. That is new, not in the Oasis page. |
| Heading Correction | Magnetics > Corrections | Tool | Later | Needs table input (importer). |
| Heading Calculation | Database Tools > Channels | Tool | Chain | Needed by heading correction and QC. |
| Base Station Correction | Magnetics > Corrections | Tool, job | Chain | Better design: take a base-station **line database** (imported) instead of a pre-made table, and resample by time. |
| IGRF Channel (other menu) | Magnetics > IGRF | Tool | Chain | Output residual directly as an option, plus field, inc, dec. |
| Tie-line levelling (other menu) | Magnetics > Levelling, as a guided task | Tools + task | Chain | Intersections as a project item viewable on the map. |
| Microlevelling (other menu) | Magnetics > Levelling | Tools + task | Chain | Uses gridding; depends on the Grid tab. |
| Apply Levels | Magnetics > Levelling; Database Tools > Channels | Tool | Chain | |
| Polynomial (Trend) | Filters; Magnetics > Levelling | Tool | Chain | |
| Despike, Non Linear Filter | Filters | Tool | Chain | Merge into one "Despike (Naudy)" tool with width in samples or seconds. Guess: both use the same method; the help cites the same paper for both. |
| Low / High / Band Pass | Filters | Tool | Chain | One "Band pass (Fraser)" tool with low/high presets. |
| Convolution Filter | Filters | Tool | Later | Filter coefficients as a setting or a filter item. |
| Remove Systematic Noise | Filters | Tool | Later | |
| B-Spline | Filters | Tool | Later | |
| Rolling Statistics | Filters | Tool | Later | |
| Differences | Filters; QC | Tool | Chain | Fourth difference is the standard mag noise QC. Also as an on-the-fly profile view option. |
| Linear Regression | Profile view (marked range) | View | Later | |
| Mask to Channel, Copy Channel with Mask | Database Tools > Channels | Tool | Later | Covered by Channel Math with conditionals; keep as presets. |
| Create a Noise Channel | Tools pane only | Tool | Later | For testing algorithms. |
| Channel Math | Database Tools > Channels (big button); Database view context menu | Tool | Chain | Consider v1: cheap once the tool system exists, and very useful for checking imports. |
| Interpolate | Database Tools > Channels | Tool | Chain | Needed before FFT and in levelling. |
| Copy Channel | Database view context menu | Tool | v1 | Simple and needed for "keep the raw data". |
| Make Distance Channel | Database Tools > Channels | Tool | Chain | |
| Make Fid Channel, Make Line Channel | Tools pane; export options | Tool | Later | Mostly for XYZ/CSV export. Better as export settings ("write line and fid columns"). |
| Change Channel Fid, Assign Fiducial from Channel | Database Tools > Sampling | Tool | Later | Under one-sampling-per-line, these change line metadata. |
| Re-Fid a Channel, Re-Fid to Distance Reference, Same Fid Start and Increment, Decimate Channels | Database Tools > Sampling, as one "Resample lines" tool | Tool, job | Later | Output is a new database. Removes the "red bar" problem. |
| Average Repeated Locations, Dummy Repeats | Tools pane | Tool | Later | Useful for GPS repeats. |
| Pick Anomalies | Tools pane | Tool | Later | Not part of the core mag chain. |
| Search, Search/Replace | Database view (Ctrl+F) | View | v1 | Plain editor feature. |
| Sort a Single Channel | none | | Skip | Breaks row links; risky. |
| Sort All by 1/2/many | Database view context menu | Tool | Later | |
| Split on Line Channel | Import (CSV line rule) and Database Tools > Lines | Importer option + tool | v1 | The draft's CSV "rule to split into lines" is this tool. Write it once and use it in both places. |
| Split on X,Y Breaks, on Direction, on Fiducial | Database Tools > Lines; split at fid also from the profile/map context menu | Tool | Later (direction split: Chain) | Direction split matters for raw flight files with turns. |
| Merge Lines, Copy Line | Project Explorer / database view context menu | Tool | Later | |
| Set Line Types from Channel | Import option and Database Tools > Lines | Tool | v1 | Line type must exist before levelling; XYZ `Tie` markers cover most cases. |
| Multiple Profile Plot | Profile view (built in); plot-to-map later on the Map tab | View | v1 (view) / Later (map) | The draft's profile view should support several panels and the four scaling modes from this page. |
| 1, 2 Channel Lookup | Database Tools > Channels | Tool | Later | Needs table items. |
| Cross-Database Channel Lookup | Database Tools > Channels ("Join channel from database") | Tool | Later | Useful to bring base-station or radar-altimeter data in by time. |
| Merge Databases | Project Explorer context menu | Tool | Later | |
| Subset Database, Compact Database, Create Subset Database | Project Explorer context menu ("Subset...") | Tool | Later | One tool with options: lines, channels, area, drop dummy rows. |
| PLY file creation (polygon, rectangle, geographic), Draw from PLY | Map view drawing tools; polygon importer | View + importer | Later | Polygons as project items on the map, not files. |
| Mask Channel to Polygon, Apply Mask to Data | Database Tools > Area | Tool | Later | |
| Window X,Y to Polygon / Zmin-Zmax, Restore Full X,Y | none (replaced) | | Skip | Replaced by area masks and an "area" input on gridding and map tools. |
| Line/Channel Report, Mark Statistics, Total Distance, Summary Statistics | Statistics pane | View | v1 | Needed to check imports. Export as CSV. |
| Scatter Analysis | Later chart view | View | Later | General, not geochem-only. |
| Triplot Analysis | none | | Skip | Geochemistry. |
| Density <-> Velocity | none | | Skip | Seismic/gravity modelling. |
| Array Channels (all) | Database Tools > Arrays | Tools | Later | Only if spectrometer or EM data arrives. The draft already allows array channels in storage. |
| Import Geosoft Binary, Export to Esri Geodatabase | Import/export system | Importer/exporter | Later | Belong to the Database menu study. |
| Select/Deselect Name or Mask | Line selection in the Project Explorer or database view (filter by name pattern, type, direction) | View | v1 | Combine with Select/Deselect Direction from the levelling menu. |

### 4.4 Suggested ribbon groups

A sketch, not a final layout.

- **Database Tools** tab: Channels (Channel Math, Interpolate, Copy, Distance, Heading), Lines (Split, Set Types, Merge), Sampling (Resample lines), Area (Mask to polygon, Subset), Statistics (opens the pane).
- **Filters** group (on Database Tools, or its own tab if it grows): Despike, Band pass, Differences, Polynomial, Rolling statistics, Convolution, FFT (later).
- **Magnetics** tab: Corrections (Lag, Diurnal, Heading), IGRF, Levelling (Intersections, Tie-line levelling task, Microlevelling task, Apply levels), later Line RTP.

## 5. Open questions for the user

1. **Fiducials:** is one sampling per line enough for your data?
   Do you ever have channels at different rates in one line (for example GPS at 1 Hz and mag at 10 Hz) that must stay at their own rate?
2. **Magnetics tab:** may the chain tools (lag, diurnal, heading, IGRF, levelling) sit on a new Magnetics tab instead of being spread over Database Tools and extension-style menus as in Oasis?
3. **Diurnal data:** how does your base-station data arrive (raw base magnetometer files, or a ready table)?
   Should JuliaMag import raw base files and build the correction itself?
4. **Heading correction:** is it ever needed on your surveys, or is compensation always done by the contractor?
5. **Levelling methods:** which do you use in Oasis today: Statistical, Full, Iterative, or Careful (shift/tilt/spline)?
   And do you always microlevel after?
6. **Lag:** how do you find the lag now (by eye on opposite lines, or from a test line)?
   Would a lag-picking view be useful?
7. **Channel Math:** is a small expression language enough, or do you want full Julia in the expression box?
8. **Area windowing:** do you rely on Window X,Y today, or would explicit polygon masks feel natural?
9. **Array channels:** will JuliaMag ever see spectrometer or EM data, or is it mag (and maybe gravity) only?
10. **Filter units:** do you think in samples, seconds or metres when setting filter lengths?
