# Geosoft Oasis montaj `.grd` (v2): byte-level research for JuliaMag

Plan: `docs/superpowers/plans/2026-10-29-plan-2-grids.md` (Tasks 4 to 7).
Spec: `docs/superpowers/specs/2026-10-28-juliamag-foundation-design.md` section 6.7.

Date: 2026-10-29.
Tags: **[SPEC]** = read in Geosoft's own spec text.
**[CODE]** = read in reader source code.
**[BYTES]** = I checked it myself by parsing real files with a Python script (struct/zlib/olefile).
**[PROSE]** = only seen in prose or search snippets.
**[GUESS]** = my inference, not verified.

## Sources

- S1 Geosoft spec "Geosoft Grid File Format" (Oasis montaj 9.9 help, (c) 2020 Geosoft).
  The original URL https://help.seequent.com/Oasis-montaj/9.9/en/Content/ss/process_data/grid_data/c/geosoft_grid_file_format.htm now returns 404 (also the `glossary/grid_file_format__grd.htm` variant, and all 2022-2026 versions I tried).
  A full saved copy is in the Loop3D QGIS plugin repo: https://github.com/Loop3D/grd_loader/blob/main/Geosoft%20Grid%20File%20Format.html (I read all of it).
- S2 harmonica reader (BSD-3): https://github.com/fatiando/harmonica/blob/main/src/harmonica/_io/oasis_montaj_grd.py (path moved under `src/`; the old `harmonica/_io/...` path is 404).
- S3 Loop3D reader (MIT): https://github.com/Loop3D/geosoft_grid (`grd2geotiff.py`, README).
- S4 pygdb clean-room reader (MIT, 2026): https://github.com/jcapriot/pygdb (`pygdb/grd_reader.py`, `docs/spec.md` sections 7.1 and IPJ table).
- S5 geoawd QGIS plugin (harmonica-derived): https://github.com/geoawd/geosoftgrdloader/blob/main/grd_parser.py
- S6 GX Developer "Grid File Name Decorations": https://geosoftgxdev.atlassian.net/wiki/display/GXDEV92/Grid+File+Name+Decorations (seen via search snippets only, page body did not load).
- S7 Seequent "Summary of Oasis montaj Files": https://help.seequent.com/Oasismontaj/2026.1/Content/ss/om_reference/common_reference/intro_to_om/summary_of_oasis_montaj_and_geosoft_files.htm
- S8 geosoft-gxpy: https://github.com/GeosoftInc/gxpy (`geosoft/gxpy/grid.py`, `coordinate_system.py`).
- Test files parsed: 8 harmonica fixtures, 2 Loop3D fixtures, 1 USGS grid (see section 6).

## 1. The 512-byte header

All fields are **little-endian** **[BYTES]** (every sample file; S1 only says "4-byte signed integers and 8-byte IEEE doubles", it does not name byte order).
S2, S3, S4 all read little-endian **[CODE]**.

| Off | Len | Type | Name | Meaning (S1 [SPEC] unless noted) |
|---|---|---|---|---|
| 0 | 4 | int32 | ES | Element size: 1, 2, 4, 8 bytes. "If the data is compressed 0x400 is added" (so 1025, 1026, 1028, 1032). |
| 4 | 4 | int32 | SF | Sign flag: 0 unsigned, 1 signed, 2 float (4 and 8 byte only), 3 colour grid RGB (4 byte only). |
| 8 | 4 | int32 | NE | Elements per vector. |
| 12 | 4 | int32 | NV | Number of vectors. |
| 16 | 4 | int32 | KX | First-element corner and storage sense: +-1 bottom-left, +-2 upper-left, +-3 upper-right, +-4 bottom-right; positive = right-handed, negative = left-handed. Spec: only +-1 was ever implemented by Geosoft libraries. |
| 20 | 8 | float64 | DE | Distance between points along a vector. |
| 28 | 8 | float64 | DV | Distance between vectors. |
| 36 | 8 | float64 | X0 | X of grid origin; "always the bottom left corner of the grid (the first element if KX=1)". |
| 44 | 8 | float64 | Y0 | Y of grid origin (same rule). |
| 52 | 8 | float64 | ROT | "grid axis rotation, in degrees counter clockwise, relative to the co-ordinate system axis". |
| 60 | 8 | float64 | ZBASE | Base value removed. |
| 68 | 8 | float64 | ZMULT | Data was multiplied by ZMULT. |
| 76 | 48 | ASCII | LABEL | Grid label, may be blank. |
| 124 | 16 | ASCII | MAPNO | Map number, may be blank. |
| 140 | 4 | int32 | PROJ | Map projection reference (0 in all samples [BYTES]; not the real CRS, see section 5). |
| 144/148/152 | 4 each | int32 | UNITX/UNITY/UNITZ | Distance units (0 in all samples [BYTES]). |
| 156 | 4 | int32 | NVPTS | Number of valid points (matched real count in all samples [BYTES]). |
| 160/164/168/172 | 4 each | int32 or float32 | IZMIN/IZMAX/IZMED/IZMEA | Min, max, median, mean in *stored* units; float if SF=2; spec says for double grids set them to the 4-byte float dummy. |
| 176 | 8 | float64 | ZVAR | Variance. |
| 184 | 4 | int32 | PRCS | Process flag (0 in all samples). |
| 188 | 324 | ? | USER | Application area; general tools leave it or copy it unchanged. |

Optional fields (76-187) must be set to the type's dummy when unused or no longer valid **[SPEC]**.
**[BYTES]** IZ* fields are unreliable in real files: double grids hold float32 -1e32 (`ae c5 9d f4`) in all four; IZMED is 0 in every sample; om_short/om_byte IZMIN holds garbage.
Readers should ignore IZ*, ZVAR and NVPTS and recompute.
**[BYTES]** Oasis 9.6 writes four float32 -1e32 values at 188-203 of USER and zeros after; meaning unknown.

Element types (S1 [SPEC], S2 `_get_data_type` [CODE]):

| ES (mod 1024) | SF=0 | SF=1 | SF=2 | SF=3 |
|---|---|---|---|---|
| 1 | UInt8 | Int8 | - | - |
| 2 | UInt16 | Int16 | - | - |
| 4 | UInt32 | Int32 | Float32 | colour RGB (layout not documented) |
| 8 | - | - | Float64 | - |

S2 maps ES=8 to Float64 whatever SF is **[CODE]**.
An 8-byte integer is not in S1; S4 lists an int64 dummy only as "[LIKELY]" with no real files.
Compression test: `ES > 1024` (S2, S5) or `ES & 0x400` (S1).

## 2. Data layout

- Data starts at byte 512 **[SPEC][BYTES]**.
  It holds NV vectors of NE elements; vector length is ES*NE bytes **[SPEC]**.
- The file is at least `512 + ES*NE*NV` bytes and "may be longer depending on the blocking factor" **[SPEC]**.
  So read exactly `ES*NE*NV` bytes, not to EOF.
  (S2 reads to EOF and then checks the size, so a padded file would fail there **[CODE]**.)
- **KX = 1**: vector = row along +X (west to east), first vector at Y0 (south), later vectors go north.
  First element = bottom-left = (X0, Y0).
  So the file is row-major, south row first **[SPEC][CODE][BYTES]**.
  Verified: om_float reshaped as (NV=49 rows, NE=50 cols) equals the compressed and integer twins.
- **KX = -1**: vector = column going north; vectors go west to east.
  First element is still bottom-left **[CODE][BYTES]**.
  Verified: `om_order.grd` (NE=49, NV=50, KX=-1) reshaped to (50,49) and transposed equals `om_double.grd` (KX=1).
  In that case DE is the Y spacing and DV the X spacing (S2 swaps them **[CODE]**).
- KX = +-2..4: never implemented by Geosoft **[SPEC]**; reject them.
- **Real value** = `stored / ZMULT + ZBASE` (write: `stored = (real - ZBASE) * ZMULT`) **[SPEC][CODE]**.
  Checked on om_short/om_byte/om_long against om_float: error 4e-4, 0.1, 6e-9 (quantisation) **[BYTES]**.
  Apply dummy masking to the *stored* value before scaling.
- **Registration**: point (node) registered.
  X0, Y0 is the centre of the lower-left cell; display cells extend half a cell west and south of the origin **[SPEC]**.
  `.grd.xml` `<extent2d>` for om_float is minx=1, maxx=50 = X0 + (NE-1)*DE, so node extents **[BYTES]**.
  Loop3D builds a GeoTIFF transform with `X0 - DE/2` **[CODE]**.
- **Rotation**: ROT in degrees, counter-clockwise positive **[SPEC]**.
  With i along vectors and j across vectors (KX=1): `E = X0 + i*DE*cos(t) - j*DV*sin(t)`, `N = Y0 + i*DE*sin(t) + j*DV*cos(t)`, t = ROT in radians **[CODE S2]**.
  **[BYTES]** I checked this against Oasis's own `<extent2d>` for `om_rotate.grd` (ROT=-30, NE=50, NV=49): predicted minx 1, maxx 67.435, miny -48.5, maxy 17.569 are an exact match.
  The `.gi` REG stream also stores `LOC_ROT=-30`.

## 3. Dummy (no-data) values

S1 **[SPEC]**, the same in S2/S3 `DUMMIES` **[CODE]**:

| Type | Dummy |
|---|---|
| Int8 | -127 |
| UInt8 | 255 |
| Int16 | -32767 |
| UInt16 | 65535 |
| Int32 | -2147483647 |
| UInt32 | 4294967295 |
| Float32 | -1.0e32 (bytes `ae c5 9d f4`) |
| Float64 | -1.0e32 |

Valid ranges in S1 leave the dummy out (for example Int8 -126..127, UInt8 0..254).
S2 treats float values `<= -1e32` as dummy; integers must match exactly **[CODE]**.
Note that float32(-1e32) = -1.0000000331813535e32, so a Float32 to Float64 copy is no longer `== -1e32`.
Use `<=` or a tolerance.
**[BYTES]** Int16/Int8/Int32 samples hold exactly 655 dummies, the same mask as the float grid.

## 4. Compressed layout (ES has 0x400 added)

Compression header right after byte 512 (S1 calls it "16-bit", it is 16 bytes) **[SPEC][BYTES]**:

| Off (from 512) | Len | Type | Name | Notes |
|---|---|---|---|---|
| 0 | 4 | uint32 | SIG | 0xF8E7D8C7 (bytes `c7 d8 e7 f8`) **[SPEC][BYTES]** |
| 4 | 4 | int32 | COMP_TYPE | S1: 0 none, 1 "ZLIB", 2 "LZRW1". **All 4 real files say 2 and are zlib** [BYTES]. |
| 8 | 4 | int32 | NB | Number of blocks. |
| 12 | 4 | int32 | VPB | Vectors per block. |
| 16 | 8*NB | int64 | OB | Absolute file offset of each block (includes the 512 header) **[SPEC][BYTES]**. |
| 16+8NB | 4*NB | int32 | CBS | Size of each block, *including* its 16-byte block header **[BYTES]** (`OB[i]+CBS[i] == OB[i+1]`, last one ends at EOF). |

- Block size rule: 65536 uncompressed bytes if one or more vectors fit, otherwise one vector per block and NB = NV **[SPEC]**.
  So `VPB = floor(65536 / (NE*ES))` and `NB = ceil(NV / VPB)` **[BYTES]**: 286 float cols gives VPB=57 and NB=5; 50 cols gives VPB=327; 85 cols gives VPB=192.
- Each block = 16-byte header `0f 0e ff fe 12 34 56 78` + int32 subtype + int32 reserved, then the payload **[BYTES][S4]**.
  In all grid blocks seen: subtype=2, reserved=1, and the payload is a raw **zlib** stream (starts `78 01`) **[BYTES]**.
- S4 (.gdb corpus, thousands of blocks): subtype 1 = LZRW1 (`DB_COMP_SPEED`), subtype 2 = zlib (`DB_COMP_SIZE`) **[PROSE, S4 docs]**.
  So S1's COMP_TYPE table seems to have the names swapped. **[GUESS]**: COMP_TYPE/subtype 1 = LZRW1 = `COMP=SPEED`, 2 = zlib = `COMP=SIZE`.
  I found no real grid with subtype 1.
  In .gdb files, S4 says LZRW1 blocks carry an extra 12-byte sub-header (decompressed length, chunk length, marker 0xF4E5D6C7 compressed or 0xF0E1D2C3 stored raw).
  Whether grids use the same framing is **unverified**.
- Last block: S1 says unused elements are filled with dummies before compression.
  **[BYTES]** In practice the last block decompressed to exactly the remaining rows (26312 = 23 rows * 1144).
  So concatenate the blocks and truncate to `ES*NE*NV` bytes; that works for both cases.
- Decompressed bytes are the same little-endian element layout as uncompressed data **[BYTES]** (om_compress equals om_float exactly).
- Lossy `COMP=SIZEnn` (for example SIZE12): GX decoration that keeps nn float mantissa bits "to between 3 and 4 significant figures" before compression **[PROSE S6]**.
  **[GUESS]** It only zeroes low mantissa bits; the reader needs nothing special.
- harmonica (S2) **[CODE]** supports ES 1/2/4/8 and 1025/1026/1028/1032, SF 0/1/2, and KX +-1.
  It ignores SIG and COMP_TYPE, skips 16 bytes per block, and always runs `zlib.decompress`.
  It rejects SF=3 (colour), other KX values, and other ES values.
  An LZRW1 block would raise `zlib.error`.
- Writer advice **[GUESS]**: write uncompressed by default.
  For compressed output, copy the observed bytes exactly: SIG, COMP_TYPE=2, block header `0f0efffe 12345678 02000000 01000000`, and zlib payloads.
  Test the result in Oasis before you trust it.

## 5. Coordinate system side files

`.grd.gi` holds projection information and `.grd.xml` holds metadata; Seequent says both must be copied with the grid **[PROSE S7]**.
The header PROJ field is not used for the CRS (0 even in the WGS84 and NAD27 samples) **[BYTES]**.

**`.grd.xml`** (Oasis 9.6 samples) **[BYTES]**: an ISO 19139 `gmd:MD_Metadata` root wraps `<geosoft xmlns="http://www.geosoft.com/schema/geo"><dataset>`.
That holds `<georeference>`, which contains `<dataextents><extent2d minx miny maxx maxy/>` and a `<projection>` element.
Example (Loop3D):
`<projection type="GEOGRAPHIC" name="WGS 84" ellipsoid="WGS 84" datum="WGS 84" wellknown_epsg="4326" datumtrf=... radius="6378137" eccentricity="0.0818..."><shift x y z/><units name="dega" unit_scale="1"/></projection>`.
Unknown CRS: `type="UNKNOWN"` with only `<units>`; a rotated grid adds `<warp type="TRANS2"><warp_point ix iy ox oy/>...`.
I saw no ESRI WKT in any xml sample.
Readers: S5 greps `wellknown_epsg="..."` **[CODE]**; S3 suggests grepping `projection="` **[CODE]**.
The `<projection>` schema is the same Geosoft xml that gxpy `Coordinate_system.xml` accepts (root `projection`, Geosoft namespace) **[CODE S8]**.
`<lineage>` holds HTML-escaped copies of older projections; parse only `dataset/georeference/projection`, not the first string match.

**`.grd.gi`** **[BYTES]**: a Microsoft OLE2 compound file (magic `d0 cf 11 e0 a1 b1 1a e1`).
It holds streams `ipj`, `reg`, `meta_ext` and a storage `embededfiles`; read it with any CFB reader.
- `reg`: Geosoft REG key/value text such as `LOC_DX`, `LOC_DY`, `LOC_ROT`, `LOC_XO`, `LOC_YO`, `NVPTS`, `ZMIN`, `ZMAX`, `ZMEA`, `ZVAR`, `CHECK_GRID_DATE`.
- `ipj`: the binary IPJ object, with `ff 00 f0 0f` / `ff 00 e1 1e` frames as in S4's .gdb IPJ.
  The S4 offset table works here with **offset - 28**.
  I checked this on the USGS NAD27 LCC grid and the Loop3D WGS84 grid.
  Fields: method int32 @140 (1 geographic, 11 TM, 3 LCC-2SP, 14 polar stereo); full CS name @76 (seen); datum @152; ellipsoid @216; a float64 @280; e @288; prime meridian @296; datum-transform name @304 and 7 params @368; units name @424; unit factor @488; projection name @496; 8 float64 params @560.
  USGS LCC read as 33, 45, 42, -120.5, which matches its README.
  WGS84 file only: a trailing frame holds `"EPSG"` and int32 4326 at stream offset 1036 (one sample, **[GUESS]** that this is general).
- No public spec for `.gi`; all of the above is reverse-engineered.

**Which file Oasis reads**: not documented anywhere I found.
Seequent calls `.gi` the projection file **[PROSE S7]**.
USGS publishes grids with `.grd` + `.gi` only (no xml); its README says the `.gi` "contains information about the projection" **[PROSE]**.
**[GUESS]**: Oasis reads `.gi` first; `.xml` is metadata that Oasis keeps in sync.
gxpy sets CRS through closed `GXIMG.set_ipj` calls (writes `.gi`), and writes `.xml` itself as metadata **[CODE S8]**.

Simplest robust approach:
- (a) Read: if `.xml` exists, parse `georeference/projection`; use `wellknown_epsg` when present, else name/datum/units.
  Fallback: open `.gi` as CFB and read the `ipj` method, params and EPSG.
  Report "unknown CRS" instead of guessing.
- (b) Write: always write `.grd.xml` with a Geosoft `<projection ... wellknown_epsg="NNNN">` block copied from a real Oasis file (template), plus `<extent2d>`.
  Do not hand-craft `.gi` unless tested.
  **Not verified** that Oasis picks up a CRS from `.xml` alone; test this in Oasis before you rely on it.
  Also offer a GeoTIFF/ERS export as a CRS-safe path.

## 6. Public test files (all URLs checked with HTTP 200 on 2026-10-29)

Geosoft .grd:
- harmonica fixtures, BSD-3 (Oasis 9.6, each 2-20 KB, with `.gi` + `.xml`): `https://raw.githubusercontent.com/fatiando/harmonica/main/test/data/{om_byte,om_short,om_long,om_float,om_double,om_order,om_rotate,om_compress}.grd[.gi|.xml]`.
  They cover Int8, Int16, Int32, Float32, Float64, KX=-1, ROT=-30 and zlib.
  Also `incomplete_grid.grd` (truncated, for error tests).
- Loop3D fixtures, MIT repo, data from CPRM Brazil, WGS84 EPSG:4326, 286x251 Float32: `https://raw.githubusercontent.com/Loop3D/geosoft_grid/HEAD/test_data/test_{compressed,uncompressed}.grd[.gi|.xml]` (263 KB and 288 KB; the compressed one has 5 blocks).
- USGS Data Series 355 (Oregon gravity/mag), US public domain, all ES=1028 zlib, `.gi` only, NAD27 LCC: `https://pubs.usgs.gov/ds/355/data/mag_4126.grd` (46,925 B) + `.grd.gi` (18,432 B).
  Larger: `grvcba.grd` (5.6 MB), `magor.grd` (4.3 MB).
  Readme: https://pubs.usgs.gov/ds/355/data/00README.txt
- I found no public *uncompressed* real survey grid beyond Loop3D's.
  GA, BGS, NGU and GSF were not checked.

ER Mapper .ers:
- GDAL autotest (GDAL MIT licence): `https://raw.githubusercontent.com/OSGeo/gdal/master/autotest/gdrivers/data/ers/mag4014.ers` + `mag4014` (86,984 B, Float32 LSBFirst, 131x166, null -1e32, RAW CRS).
  GDAL's test expects geotransform `(-301100, 200, 0, -69400+200*165, 0, -200)`, which shows that RegistrationCoord sits at RegistrationCell (0,165).
  Same folder: `srtm.ers`, `ers_dem.ers`, `8s.ers`.
- USGS OFR 01-0081 Arizona, public domain: `https://pubs.usgs.gov/of/2001/ofr-01-0081/data/ermapper/f0540mag.ers` (728 B) + `f0540mag.gz` (118,890 B, gzip of the data file; rename to `f0540mag` after gunzip).
  **MSBFirst** (big-endian), null 1E+20, NAD27 LCC: a good edge case.

## 7. Surfer formats (quick check)

- Surfer 6 binary: first 4 bytes ASCII `DSBB` **[PROSE]** https://surferhelp.goldensoftware.com/topics/surfer_6_grid_file_format.htm
- Surfer 7 binary: first tag id 0x42525344 as LE int32 = bytes `DSRB` **[PROSE]** https://surferhelp.goldensoftware.com/topics/surfer_7_grid_file_format.htm
- Surfer ASCII: first token `DSAA` **[PROSE]** https://surferhelp.goldensoftware.com/topics/ascii_grid_file_format.htm
- Surfer NoData = 1.70141e38 (GDAL: 1.701410009187828e+38).
- GDAL reads all three, built in by default: GSBG (read/write), GS7BG (read/write), GSAG (read, CreateCopy write) **[PROSE]** https://gdal.org/en/stable/drivers/raster/gsbg.html, .../gs7bg.html, .../gsag.html
- GDAL has no Geosoft `.grd` driver (GXF only); a support ticket was closed wontfix https://trac.osgeo.org/gdal/ticket/4887 **[PROSE, search snippet]**.
