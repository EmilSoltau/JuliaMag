# Geosoft Oasis montaj database (`.gdb`): byte-level research for JuliaMag

Goal: a read-only `.gdb` importer for JuliaMag.
Spec: `docs/superpowers/specs/2026-10-28-juliamag-foundation-design.md` section 5.3 (line database) and section 6 (import).
The spec still lists `.gdb` as a non-goal (section 11); that will change in a later edit.

Date: 2026-11-04.
Tags: **[SPEC]** = read in Geosoft's own text: the GX API docstrings in gxpy, or the Oasis montaj 2025.2.1 help installed on the user's machine.
Geosoft has never published a `.gdb` format spec.
**[CODE]** = read in reader source code (pygdb, gxpy).
**[BYTES]** = I checked it myself by parsing real files with my own Python script (standard library only).
Each [BYTES] claim names the files it was checked on.
"AirMag" means the levelling tutorial file `AirMag.gdb`.
**[PROSE]** = only seen in prose (docs, READMEs, pygdb's spec text), not checked by me.
**[GUESS]** = my inference, not verified.

All offsets are in bytes.
All numbers are **little-endian** **[BYTES: all 8 files]**.

## Sources

- S1 pygdb, a clean-room reader (MIT, 2026): https://github.com/jcapriot/pygdb.
  I read `docs/spec.md` (all 1,593 lines), `docs/provenance/notes.md` (sources, sample list, blob header notes) and `pygdb/gdb_reader.py` (blob header, value decoding).
  I downloaded the source archive into its own folder, read it with `sed`/`grep`, and did not run it.
  pygdb's tags are [CONFIRMED]/[LIKELY]/[GUESS]; I quote its claims as [PROSE] unless my own scripts confirmed them.
  pygdb itself was tested on 22 to 49 public files; see its `docs/provenance/notes.md` section 5 for the list.
- S2 geosoft-gxpy (BSD-2): https://github.com/GeosoftInc/gxpy.
  Read, not run: `geosoft/gxapi/__init__.py` (constants), `geosoft/gxapi/GXDB.py` (docstrings), `geosoft/gxpy/gdb.py` (line and channel details, fiducials, line names).
- S3 Oasis montaj 2025.2.1 help, installed at `C:\Program Files\Geosoft\Desktop Applications\hlp\Montaj\Content` (read as text, nothing run).
  Pages used: `ss/edit_preprocess_data/view_edit_spreadsheet_data/c/database_compression.htm`, `gxhelp/d/geosoft_gx_database_databaseproperties.htm`, `gxhelp/n/newfid_gx.htm`.
- S4 Oasis coordinate system tables in the same install: `csv/ipj_pcs.csv` (4,872 projected systems, name to EPSG code) and `csv/datum.csv` (690 datums, name to EPSG code).
  These are Seequent files; I only read them.
- S5 GDAL OpenFileGDB driver page (for telling Esri file geodatabases apart): https://gdal.org/en/stable/drivers/vector/openfilegdb.html
- S6 Ross Williams' LZRW1 algorithm, as cited by S1: http://www.ross.net/compression/download/original/old_lzrw1.c (I did not fetch it; I wrote the decoder from the algorithm as S1 describes it, and it reproduced the XYZ exports exactly).
- S7 The sibling grid research: [`geosoft-grd-format.md`](geosoft-grd-format.md) (shared compression framing, IPJ offsets).
- Test files: AirMag plus 7 public files from 4 sources (section 13).

Dead or blocked URLs, all checked on 2026-11-04:

- USGS ScienceBase item `5e7be5eee4b01d50927301b3` (Mojave `Magnetic_Data.gdb` and `Radiometric_Data.gdb`, S1's main samples): the page returns HTTP 403 to WebFetch.
  I did not try to get around it.
- `https://cdn.geosciencebc.com/project_data/QUESTdata/data/7042-Main.gdb`: 404 (the README lists it; the Mt Milligan block is still there).
- Geological Survey of Queensland portal: S1 says its download endpoint is behind an AWS bot challenge [PROSE]; I did not try.
- Geosoft has no public `.gdb` spec page at all; there is nothing to be dead.

## 1. How to tell a Geosoft `.gdb` from an Esri `.gdb`

- A Geosoft database is **one regular file**.
  It starts with the 4 ASCII bytes `!CBD` (`21 43 42 44`) **[BYTES: all 8 files][PROSE S1: 49 files]**.
- An Esri file geodatabase is **a directory** whose name ends in `.gdb` **[PROSE S5]**.
  It holds `.gdbtable`, `.gdbtablx`, `.atx` and `.spx` files **[PROSE S5]**.
  GDAL also reads a zipped one named `.gdb.zip` **[PROSE S5]**.
- An Esri personal geodatabase is an Access `.mdb` file, so it does not clash **[PROSE]**.
- Rule for the reader:
  1. a directory, or a `.gdb.zip`: Esri, say so and stop;
  2. a regular file that starts with `!CBD`: Geosoft;
  3. anything else: "not a Geosoft database", with the first 4 bytes in the message.
- Oasis can also export to an Esri geodatabase; its own schema lists both `GeosoftGDB` and `ArcGeoDatabase` as data types **[BYTES: `schema/FileMappingsSubSchema.xsd` in the Oasis install]**.
- gxpy deletes `name.gdb` and `name.gdb.xml` together, so a `.gdb.xml` metadata side file can exist **[CODE S2 `gdb.delete_files`]**.
  None of the public deliveries I found ship one.
  The reader should not need it.

## 2. The model in one page

A `.gdb` is a paged file of fixed size records, then a chain of "blobs" **[PROSE S1][BYTES: all 8 files]**.

```
0          256-byte header                                   (section 3)
256        24 zero bytes
280        blob directory: word44 slots x 6 bytes             (section 4)
...        blob-symbol table: blobs_max x 128 bytes           (section 5)
...        line table:        lines_max x 128 bytes
...        channel table:     chans_max x 128 bytes
...        user table:        users_max x 128 bytes   -> ends exactly at index_size
...        zero padding to a page boundary
page P     blob chain to end of file: each blob is a whole number of pages (section 6)
```

- A **line** and a **channel** are both "symbols" with a 0-based **slot** in their table.
- The data of one channel on one line is one blob, found by `blob_index = line_slot * chans_max + channel_slot` **[BYTES: all 8 files]**.
- Data is stored **column by column**: one blob holds all rows of one channel on one line **[BYTES]**.
- Metadata (labels, units, coordinate systems, history) sits in "administrative" blobs with indexes at and above `lines_max * chans_max` **[BYTES]**.
- The file is append-only in practice: a changed blob is written again at the end, and the directory points at the current copy **[BYTES: AirMag, long_valley_ed]**.

## 3. File header (bytes 0 to 255)

Words are int32 unless noted.
Values in the last column are AirMag's **[BYTES: AirMag]**.

| Off | Name | Meaning | Status | AirMag |
|---|---|---|---|---|
| 0 | magic | ASCII `!CBD` | [BYTES all 8] | `!CBD` |
| 4 | ? | 0 in all my files; S1 saw `f0 f0 f0 f0` on 13 of 45 files, meaning unknown | [BYTES all 8 = 0][PROSE S1] | 0 |
| 8, 12 | ? | bytes `00 00 02 10 08 01 00 00` (words 0x10020000 and 264) in every file | [BYTES all 8] | same |
| 16, 20, 68 | ? | 0 | [BYTES all 8] | 0 |
| 24 | chans_max | channel table capacity | [BYTES all 8] | 50 |
| 28 | blobs_max | blob-symbol table capacity | [BYTES all 8] | 350 |
| 32 | cache | free-list slots at the end of the directory | [BYTES all 8] | 500 |
| 36 | lines_max | line table capacity | [BYTES all 8] | 200 |
| 40 | users_max | user table capacity | [BYTES all 8] | 10 |
| 44 | dir_slots | directory slots = word 60 + cache | [BYTES all 8] | 10860 |
| 48 | | lines_max * chans_max (first admin blob index) | [BYTES all 8] | 10000 |
| 52 | | word 48 + blobs_max | [BYTES all 8] | 10350 |
| 56, 60 | | word 52 + users_max (both) | [BYTES all 8] | 10360 |
| 64 | | total symbols = blobs + lines + chans + users | [BYTES all 8] | 610 |
| 72, 76, 80 | | first line, channel and user **handle** (running totals: blobs_max, + lines_max, + chans_max) | [BYTES all 8] | 350, 550, 600 |
| 84, 88, 92, 96 | | blobs_max, lines_max, chans_max, users_max again | [BYTES all 8] | 350, 200, 50, 10 |
| 100 | page_size | page size in bytes | [BYTES all 8] | 1024 |
| 104 | index_size | end of the user table (vendor `DB_INFO_INDEX_SIZE`) | [BYTES all 8] | 143520 |
| 108 | blob_start_page | first blob = this * page_size | [BYTES all 8] | 141 |
| 112 | n_pages | pages in the blob region; `(word108 + word112) * page_size` = file size | [BYTES all 8] | 1147 |
| 116 | lost_pages | pages of orphaned blobs the free list could not hold | [PROSE S1][BYTES long_valley_ed = 1148, others 0] | 0 |
| 120 | comp_level | 0 `DB_COMP_NONE`, 1 `DB_COMP_SPEED`, 2 `DB_COMP_SIZE` | [SPEC S2 names][BYTES 0, 1 and 2 seen] | 2 |
| 124 to 255 | | zero | [BYTES all 8] | 0 |

- My script checks all the arithmetic in this table on every file; it held on all 8 **[BYTES]**.
- A reader should check it too, and refuse a file where it fails ("damaged or unknown version").
- Defaults in gxpy `GXDB.create_comp`: 200 lines, 50 channels, 10 users, cache 100, page 1024 **[SPEC S2]**.
  Real files use other sizes: fortymile has 2000 lines, 100 channels, cache 10000; MtMill has 350 channels **[BYTES]**.
- `comp_level` only says how the file was configured.
  Each blob must be probed on its own (section 6.4) **[PROSE S1][BYTES: all blobs of all 8 files probed]**.

## 4. Blob directory (from byte 280)

`dir_slots` (word 44) slots of 6 bytes each **[PROSE S1][BYTES: all 8]**:

| Off in slot | Type | Meaning |
|---|---|---|
| 0 | uint32 | bit 31 = live; bits 30..28 a flag (`0x8` or `0xC` seen in the top nibble); low 30 bits = start page, counted from `blob_start_page` |
| 4 | uint16 | the blob's page count |

- Slot `i` < word 48 is the data blob of `(line, channel)` with `i = line_slot * chans_max + channel_slot` **[BYTES]**.
- Slots from word 48 to word 52 are the admin blobs; slot `word48 + k` belongs to blob symbol `k` **[BYTES]**.
- Slots from word 60 to word 44 are the free list of superseded copies **[PROSE S1]**.
- A live entry always pointed at a blob in the chain with the same index and page count **[BYTES: all 8, every live entry]**.
- When a blob has two copies in the chain, the directory decides which is current.
  It is not always the last one: in AirMag the `__552` registry has two copies, and the directory picks the **earlier** one; the later copy is on the free list **[BYTES: AirMag]**.
  long_valley_ed has 1,226 blobs in its chain but only 602 live directory entries **[BYTES]**.
- Reader rule: use the directory.
  Fall back to the last copy in chain order only when the directory entry is missing or does not land on a blob (S1 does the same) **[CODE S1]**.

## 5. Symbol tables

Every symbol record is 128 bytes.
The offsets below are measured from the **start of the name**, which is the true record start **[PROSE S1 section 2.1][BYTES: all 8]**.
(S1's older tables measure from 8 or 32 bytes earlier; I convert.)

Table starts, from header words **[BYTES: all 8]**:

- channels: `c0 = index_size - (chans_max + users_max) * 128`
- lines: `l0 = c0 - lines_max * 128`
- blob symbols: `b0 = 280 + dir_slots * 6`, and `b0 + blobs_max * 128 == l0` (checked)
- users: `c0 + chans_max * 128`; the first user is `SUPER` or `super` **[BYTES]**.

### 5.1 Channel record

| Off | Type | Meaning | Status |
|---|---|---|---|
| 0 | 64 bytes | name, NUL-terminated | [BYTES all 8] |
| 76 | int16 | data type: `GS_*` code 0..9 (section 7), or **minus the byte width** for a string | [BYTES: double, float, long, string widths 9 to 13] |
| 78 | int16 | flags; bit 0 (`0x10000` of the int32 at 76) = **deleted/free slot** | [BYTES: long_valley_ed, afgrav, 7042_106_wform] |
| 84 | int16 | display format: 0 NORMAL, 1 EXP, 2 TIME, 3 DATE, 4 GEOGR, 5 SIGDIG, 6 HEX | [SPEC S2 names][BYTES: 0, 2, 3, 4 seen] |
| 86 | int16 | display width (characters) | [PROSE S1][BYTES: each afgrav XYZ column is this width plus one space] |
| 88 | int32 | display decimals | [PROSE S1][BYTES: matches XYZ decimals in afgrav, GDR_clmag] |
| 100 | float64 | always 1.0 | [BYTES all 8], meaning unknown |
| 108 | int16 | always 5 | [BYTES all 8], meaning unknown |
| 110 | int16 | **array width**: 1 = plain channel, N > 1 = array (VA) channel | [BYTES: 40 on MtMill `Sf`, `Bf`] |

The **deleted bit is a new finding** (S1 does not decode it for channels).
Evidence **[BYTES]**:

- long_valley_ed has 33 named channel records, with `BOTTOM_RDG`, `TOP_RDG_RAW`, `TOP_DNL`, `BOTTOM_RDG_RAW`, `BOTTOM_DNL` each twice.
  All 18 records with bit 0 set have **no live directory entry** on any line.
  All 15 records without it are live on all 30 lines.
- afgrav has 28 named records; 18 have the bit.
  Its XYZ export has **exactly the other 10** channels.
- The same `0x10000` free bit marks free records in the line and blob-symbol tables **[PROSE S1]**.

Bit 1 of +78 (value 2) is set on some channels and not others.
It is set on every channel of AirMag (3) and fortymile (28), on the imported channels of afgrav and GDR_clmag, and never on channels made later by a GX (`newxy.gx` outputs in GDR_clmag) **[BYTES]**.
**[GUESS]** bit 1 is the "protected" flag (`DB_CHAN_PROTECTED = 1` in gxapi, set by Oasis on import).
Not confirmed; see section 17.

Unused slots past the real channels are zero in most files, but hold garbage in some.
7042_106_wform has 27 garbage records with binary "names", all with bit 0 set **[BYTES]**.
A record is a live channel only when: the name is printable and non-empty, bit 0 of +78 is clear, the type code is known, and the array width is at least 1 **[BYTES: this rule gives exactly the XYZ channel set on afgrav]**.

### 5.2 Line record

| Off | Type | Meaning | Status |
|---|---|---|---|
| 0 | 64 bytes | line name, such as `L10160`, `T90060`, `D0`, `L28_29` | [BYTES all 8] |
| 76 | int32 | category: 100 normal line, 200 group, 65536 empty slot; bit `0x10000` = free | [SPEC S2 values][BYTES: 100 and 65536 seen] |
| 84 | float64 | **line date as a decimal year**: `year + (day_of_year - 1) / days_in_year` | [BYTES: MtMill, matches its `Date` channel on all 14 lines] |
| 92 | int32 | line number; the int32 dummy -2147483647 when the number is not an integer | [BYTES: AirMag 10160 for `L10160`; long_valley `L28_29` holds the dummy] |
| 96 | int32 | line type, `DB_LINE_TYPE_*`: 0 normal `L`, 1 base `B`, 2 tie `T`, 3 test `S`, 4 trend `R`, 5 special `P`, 6 random `D` | [SPEC S2][BYTES: 0, 2, 6 seen] |
| 100 | int32 | flight number | [BYTES: MtMill 90 and 112, matches its `FltNo` channel] |
| 104 | 20 bytes | float32 -1e32, float64 -9e31, float64 +1e32; meaning unknown | [BYTES all 8 identical][PROSE S1] |
| 124 | int32 | line version (the `.1` in `L100.1`) | [PROSE S1][BYTES: 0 on all my lines] |

- The type letters match JuliaMag's `LINE_LETTERS`, but **the integer order does not**: Geosoft 1 is base and 2 is tie; JuliaMag's enum has `TIE` before `BASE`.
  Map by letter, never by integer.
- AirMag's line date is 2023.1616 on all 127 lines, which is 2023-03-01, the file's modified date **[BYTES]**.
  So when the line date was never set, Oasis seems to write the day the line was made **[GUESS]**.
- A group line (category 200) has a free name and a group class name instead of date and number **[PROSE S1]**.
  None of my files has group lines.
- Slots past the real lines can hold garbage: GDR_clmag has 20 such records with categories like 130936 **[BYTES]**.
  Only categories 100 and 200 count as lines.

### 5.3 Blob-symbol record

Name at +0, category at +76 (0 = live), object size at +84 **[PROSE S1][BYTES: all 8]**.
Blob symbol `k` owns admin blob `lines_max * chans_max + k`.
Names seen **[BYTES]**:

| Name | Content (section 9) |
|---|---|
| `Line Selection` | one byte per line slot |
| `Display List` | channels shown in the spreadsheet, in order |
| `Database Extension Objects` | an empty `EXT` list |
| `__dbreg` | database registry: current X, Y, Z channels |
| `__<n>`, `n` a channel handle (`word76 <= n < word80`) | that channel's registry: label, units, projection text, history |
| `__<n>`, `n` a line handle (`word72 <= n < word76`) | a line or group registry |
| `?\|IPJ_<X>:<Y>` | the coordinate system of channel pair X, Y |
| `OE.DB_ACTIVITY_LOG` | plain text creation and import log |
| `OE32.View` | plain text view settings |

Channel slot = `n - word76`; line slot = `n - word72` **[BYTES: names and labels agree on all 8]**.

## 6. Data blobs

### 6.1 Chain and common header

- The chain starts at `blob_start_page * page_size`.
  Each blob starts with `cc cc 00 ff`, and its int32 at +4 is its length in pages.
  Walking the chain lands **exactly on end of file** **[BYTES: all 8]**.
- The int32 at +12 is the blob index; +20 is the blob class **[BYTES]**.
- The int32 at +16 is a Unix time or `0x80000000` (unset) **[BYTES]**.
  It is set on every blob of long_valley_ed (2004-08-13) and afgrav (2005-10-25 to 2006-04-28), on some of GDR_clmag, and unset in the other 5 files.
  The dates fit each file's publication; the reader can ignore the field.

| Class at +20 | Meaning | Seen in |
|---|---|---|
| 100 | admin object | all 8 |
| 200 | plain (uncompressed) data | long_valley_ed, GDR_clmag, 7042_106_wform |
| 202 | compressed data | AirMag (zlib), afgrav and fortymile (LZRW1), MtMill (zlib) |

### 6.2 Plain data blob (48-byte header)

| Off | Type | Meaning | Status |
|---|---|---|---|
| 0 | 4 bytes | `cc cc 00 ff` | [BYTES] |
| 4, 8 | int32 | page count (twice) | [BYTES] |
| 12 | int32 | blob index | [BYTES] |
| 16 | int32 | Unix time or `0x80000000` | [BYTES] |
| 20 | int32 | 200 | [BYTES] |
| 24 | float64 | **fiducial start** (0.0 in all my plain blobs) | [GUESS, by the shift rule below] |
| 32 | float64 | **fiducial increment** (1.0 in all my plain blobs) | [GUESS, same] |
| 40 | int32 | element count (rows times array width) | [BYTES] |
| 44 | int32 | `GS_*` type, same as the channel's | [BYTES] |
| 48 | | values, `count * element size` bytes, then padding to the page end | [BYTES] |

### 6.3 Compressed data blob (56-byte header)

The compressed header inserts two int32 fields at +24 and shifts the rest by 8 **[BYTES]**:

| Off | Type | Meaning | Status |
|---|---|---|---|
| 0 to 20 | | as in the plain blob, class 202 | [BYTES] |
| 24 | int32 | total decompressed bytes | [BYTES: AirMag 381 of 381, all blobs of all 4 compressed files] |
| 28 | int32 | 16 + compressed stream length | [BYTES: AirMag 381 of 381 for zlib][PROSE S1 for LZRW1] |
| 32 | float64 | **fiducial start** | [BYTES: MtMill, see section 8] |
| 40 | float64 | **fiducial increment** | [BYTES: 1.0 on every blob of every file] |
| 48 | int32 | element count; count * element size = +24 | [BYTES: AirMag 381 of 381; MtMill arrays = rows * 40] |
| 52 | int32 | `GS_*` type | [BYTES] |
| 56 | 16 bytes | chunk magic `0f 0e ff fe 12 34 56 78`, int32 subtype, int32 reserved | [BYTES] |
| 72 | | payload | [BYTES] |

- Subtype 2, reserved 1: one **zlib** stream (starts `78 01`) **[BYTES: AirMag 381 of 381, MtMill]**.
- Subtype 1, reserved 0: **LZRW1** chunks **[BYTES: afgrav, fortymile]**.
  Each chunk has a 12-byte header: int32 decompressed length, int32 chunk length (including these 12 bytes), uint32 marker.
  Marker `0xF4E5D6C7` = LZRW1 data; `0xF0E1D2C3` = stored raw **[PROSE S1][BYTES: both decode to values that match the XYZ]**.
  Only the first chunk has the 16-byte magic.
  Later chunks follow back to back; stop when the outputs add up to the +24 total **[PROSE S1][BYTES: 7,532 multi-chunk blobs in fortymile, 3 in afgrav]**.
  A chunk decompresses to at most 16,368 bytes **[PROSE S1]**.
- LZRW1 is Ross Williams' 1991 algorithm with no 4-byte flag prefix **[PROSE S1]**.
  My decoder is about 25 lines: a 16-bit little-endian control word; bit set = copy item (`offset = ((b0 & 0xF0) << 4) | b1`, `length = (b0 & 0x0F) + 1`); bit clear = one literal byte **[BYTES: 57 million fortymile values match]**.
- The Oasis help says both modes use zlib **[SPEC S3]**.
  That is wrong for `SPEED`: the bytes are LZRW1 **[BYTES]**.
- A compressed blob can span many pages as one continuous stream **[PROSE S1][BYTES: AirMag blobs of up to 6 pages]**.

### 6.4 Probe every blob

- A file with `comp_level` 1 or 2 can still hold plain blobs, and a `SPEED` file can hold none compressed at all **[PROSE S1]**.
- Reader rule: if bytes 56..63 are the chunk magic, read the compressed header; else read the plain header **[CODE S1]**.
  The class at +20 (200 or 202) says the same thing **[BYTES: agreed on every data blob of all 8 files]**.
  Check both, and report a mismatch.
- A blob whose type field reads `REG\0`, `IPJ\0` or `EXT\0` is an admin object, not data **[BYTES]**.

## 7. Values, types and missing values

| Code | `GS_*` | Size | Geosoft dummy | Seen in my files | JuliaMag type | JuliaMag missing |
|---|---|---|---|---|---|---|
| 0 | BYTE (Int8) | 1 | -127 | no | Int8 | -128 (typemin) |
| 1 | USHORT | 2 | 65535 | no | Int32 (widen; no UInt16 in JuliaMag) | typemin(Int32) |
| 2 | SHORT | 2 | -32767 | no | Int16 | -32768 |
| 3 | LONG | 4 | -2147483647 | MtMill `FltNo` | Int32 | -2147483648 |
| 4 | FLOAT | 4 | -1e32 | 7042_106_wform `fiducial` | Float32 | NaN |
| 5 | DOUBLE | 8 | -1e32 | all 8 | Float64 | NaN |
| 6 | UBYTE | 1 | 255 | no | UInt8 | 255 |
| 7 | ULONG | 4 | 4294967295 | no | Float64 (exact) | NaN |
| 8 | LONG64 | 8 | -2^63 | no | Float64, warn above 2^53 | NaN |
| 9 | ULONG64 | 8 | 2^64 - 1 | no | Float64, warn above 2^53 | NaN |
| < 0 | string | -code bytes | empty | strings of width 9 to 13 | String | "" |

- Codes and dummies: **[SPEC S2]** (`GS_*`, `GS_S1DM` ... `GS_R8DM`).
- Float dummies: treat any value `<= -1e31` as missing, because float32(-1e32) is not exactly -1e32 as a float64 (same rule as `.grd`).
  **[BYTES]**: every `*` in the XYZ exports is a -1e32 in the `.gdb` (3,554,185 in fortymile, 11,316 in long_valley_ed).
- **Integer dummies differ from JuliaMag's.**
  Geosoft uses typemin + 1 for signed types; JuliaMag uses typemin.
  The reader must map Geosoft dummies to JuliaMag's missing value.
  A real value equal to JuliaMag's typemin (for example Int8 -128) would become missing; warn when that happens.
- Strings are fixed width, NUL-padded **[BYTES]**.
  MtMill `Date` is width 11 for `2007/10/04` (10 characters + NUL).
  The text encoding is not documented; all my strings are ASCII.
  **[GUESS]** Windows-1252; decode as UTF-8 when valid, else as Windows-1252.
- **Array channels**: the values of one row are stored together, row after row; the count field is `rows * width` **[BYTES: MtMill `Sf` and `Bf`, width 40, 590,400 values = 14,760 rows * 40]**.
  S1 confirms the same with a 512-wide USHORT spectrum and against ASEG-GDF2 widths **[PROSE S1]**.
  The int16 at channel +78 is not an array indicator; S1's "+86 base type" is the same field and S1 calls it unreliable.
  Array base types (time windows, frequencies, ...) are in gxapi **[SPEC S2]** but I found no field that holds them **[BYTES]**.
- Display formats: a `TIME` channel holds **decimal hours** and a `DATE` channel a **decimal year** **[BYTES: long_valley_ed `TIME` 15.5721 = 15:34:19.60 and `DATE` 2003.567 = 2003/07/27 in its XYZ, all 12,772 rows match]**.
  A `GEOGR` channel holds decimal degrees **[BYTES: MtMill `Longitude`]**; the format only changes the display.

## 8. Fiducials

Oasis keeps a fiducial start and increment **per line and per channel** **[SPEC S2: `GXDB.get_fid_start(line, chan)`, `get_fid_incr(line, chan)`, `set_fid(line, chan, start, incr)`]**.
The help's "Change Channel Fid" tool changes them for chosen channels on chosen lines **[SPEC S3]**.
S1 does not say where they are stored.

My finding: they are the float64 pair at +32/+40 of a compressed blob, and very likely +24/+32 of a plain blob.
Evidence **[BYTES]**:

- In 7 of the 8 files every data blob has (0.0, 1.0): the Oasis default for data imported without a fiducial setting.
  That includes fortymile, whose `FID` **channel** starts at 662.2: the channel is ordinary data, not the line's fiducial.
- In MtMill each line has its own start (33727.0, 35681.0, ...), the same on all 16 channels of that line, with increment 1.0.
- Within flight 112, `gtime * 10 - start` is the same number on every line (681930 for 6 lines, then 681936 for 7 lines).
  So the start counts 0.1 s samples, which is how a fiducial behaves.
- The plain header has the same two values (0.0, 1.0) at the same place after the 8-byte shift.
  No plain blob with a non-default value was found, so the plain offsets stay **[GUESS]**.

Not seen yet: an increment other than 1.0, and channels of one line with different starts or row counts.
In all 8 files every channel of a line has the same start, increment and row count **[BYTES]**.
JuliaMag keeps one sampling per line (spec 5.3), so the reader must handle files that break this (section 12).

## 9. Admin objects

All framed objects share one layout **[PROSE S1][BYTES: every REG, IPJ, EXT object in all 8]**:

```
+24   int32  payload length; the object ends at +28 + this
+28   ff 00 f0 0f  object frame, int32 length at +32
+40   int32 1;  +44 class name: "REG", "IPJ", "EXT"
+60   ff 00 e1 1e  member frame, int32 length at +64
+92   00 1a cc ff, then a 4-character code ("REG ", " JPI", "LMSL")
```

### 9.1 Registry (`REG`) objects

```
+124         int32 n: number of entries
+128         n slots of 256 bytes, each "KEY\0value\0"
+128 + 256n  int32 m: number of nested objects (a MAKER record when 1)
```

**[PROSE S1][BYTES: every registry of all 8 files decodes this way]**.

Keys seen **[BYTES]**:

| Where | Key | Meaning |
|---|---|---|
| `__dbreg` | `DB_CHAN_X`, `DB_CHAN_Y`, `DB_CHAN_Z` | the current X, Y, Z channels (the help calls them "current coordinate channels" [SPEC S3]) |
| `__dbreg` | `DEFAULT_GP`, `DEFAULT_GWS` | path of the Oasis project; ignore |
| channel | `LABEL` | the channel label (GDR_clmag `resmag` has label `mag`) |
| channel | `UNITS` | units text such as `m`, `dega`; empty in most files |
| channel | `CLASS` | channel class; always empty in my files |
| channel | `FORMULA` | the math expression that made the channel |
| channel | `_PJ_NAME`, `_PJ_DATUM_TRANSFORM`, `_PJ_ELLIPSOID`, `_PJ_PROJECTION`, `_PJ_UNITS`, `_PJ_X`, `_PJ_Y`, `_PJ_IPJ` | the coordinate system as GXF text, on both channels of a pair |
| line or group | `ASSOCIATED`, `ASSOCIATED$$$` | the channels associated with a group or line |

- Units are in the registry, not in the channel record; gxapi says the same ("The unit label is stored in the "UNITS" parameter of the channel reg") **[SPEC S2]**.
- A channel with no `LABEL` key has the name as its label **[GUESS, matches XYZ headers]**.
- A nested `MAKER` record names the GX that made the channel and its settings as `TOOL.KEY="value"` text, for example `newxy.gx` with old and new coordinate systems **[BYTES: GDR_clmag, long_valley_ed, MtMill]**.
  Useful as history; not needed to import.
- AirMag has **no `__dbreg` and no IPJ**: its coordinate system is unknown, and X/Y can only be guessed from the names `x`, `y` **[BYTES]**.

### 9.2 Other objects

- `Line Selection`: one byte per line slot from +28 (count at +24, `lines_max` rounded up to a multiple of 8) **[BYTES: AirMag 200 bytes]**.
  Every byte is `ff` in every file I have **[BYTES]**.
  **[GUESS]** `ff` = selected; I have no file with a cleared line.
- `Display List`: a vector of fixed-width strings `name\0handle\0`; element type -130 (or -82) at the `VV  ` tag, then the count **[BYTES: AirMag `Mag 550`, `x 551`, `y 552`]**.
  The handle is what counts; the name is a cached label and can be stale (long_valley_ed lists `TOP_RDG_RAW_ed` for handle 577, which is now named `TOP_RDG_RAW`) **[BYTES]**.
  **[GUESS]** this is the spreadsheet's channel order.
- `OE.DB_ACTIVITY_LOG`: plain text, for example "Database: .\Data\7042_106_wform.gdb, Created: 2007/12/13, IMPORT GX (XYZ file import), Import Template: ...\wave_form.I0" **[BYTES: 7042_106_wform]**.
- `Database Extension Objects`: always the same empty list **[PROSE S1][BYTES]**.

## 10. Coordinate system

- Oasis attaches a coordinate system to a **pair of channels** (`GXDB.set_ipj(ch1, ch2, ipj)`) **[SPEC S2]**.
  This matches JuliaMag's `PositionPair` exactly.
- Each pair has an admin blob named `?|IPJ_<X>:<Y>` with class `IPJ` **[BYTES]**.
  Its fixed-offset record, offsets from the blob header start **[PROSE S1][BYTES: long_valley_ed, afgrav, GDR_clmag, fortymile, MtMill, 13 live objects]**:

| Off | Type | Field | Example (fortymile `IPJ_X:Y`) |
|---|---|---|---|
| 104 | 64 bytes | full name | `NAD27 / UTM zone 7N` |
| 168 | int32 | method: 1 geographic, 11 Transverse Mercator, 3 Lambert 2SP, 14 polar stereographic | 11 |
| 180 | 64 bytes | datum | `NAD27` |
| 244 | 64 bytes | ellipsoid | `Clarke 1866` |
| 308 | float64 | semi-major axis | 6378206.4 |
| 316 | float64 | eccentricity | 0.0822718542230039 |
| 324 | float64 | prime meridian | 0 |
| 332 | 64 bytes | datum transform name | `NAD27 to WGS 84 (7)` |
| 396 | 7 x float64 | dX, dY, dZ, rotations, scale | -5, 135, 172, 0, 0, 0, 1 |
| 452 | 64 bytes | units | `m` |
| 516 | float64 | units to metres | 1 |
| 524 | 64 bytes | projection name | `UTM zone 7N` |
| 588 | 8 x float64 | method parameters; -1e32 = unused | 0, -141, -, -, 0.9996, 500000, 0, - |

- These are the same offsets as the `.grd.gi` IPJ stream plus 28 (see [`geosoft-grd-format.md`](geosoft-grd-format.md) section 5) **[BYTES]**.
- The `_PJ_*` registry text on each channel of the pair carries the same values as GXF strings, for example `"Transverse Mercator",0,-141,0.9996,500000,0` **[BYTES: all 5 files with an IPJ]**.
- **No EPSG code is stored** in any of my 13 IPJ objects **[BYTES]**.
  S1 saw an `EPSG` member in one file out of 22 **[PROSE S1]**.
- The names are EPSG names.
  Oasis's own `csv/ipj_pcs.csv` maps `NAD27 / UTM zone 7N` to 26707 and `NAD83 / UTM zone 10N` to 26910; `csv/datum.csv` maps `WGS 84` to 4326 **[BYTES: S4]**.
  JuliaMag should look the name up in the EPSG database (PROJ), not ship Seequent's tables.
  Names starting with `*` are Geosoft custom systems with no EPSG code (`WGS 84 / *TM_afghan_adf` in afgrav and GDR_clmag) **[BYTES]**.
  For those, build a PROJ string from the method and parameters, or report "custom" and let the user pick.
- **Stale IPJ blobs exist**: MtMill has `IPJ_GPSLon1:GPSLat1`, `IPJ___X:__Y` and `IPJ_Long:Lat` for channels that no longer exist **[BYTES]**.
  Only attach an IPJ whose two channel names are both live channels.
- The current pair is `DB_CHAN_X` / `DB_CHAN_Y` in `__dbreg` **[BYTES: 5 files]**.
  When `__dbreg` is missing (AirMag), gxapi falls back to channels named `X` and `Y` **[SPEC S2 `get_xyz_chan`]**.

## 11. Robustness rules (from what the files did)

- Check the header arithmetic (section 3) and that the chain ends at end of file.
- Use the directory for current copies; never trust "last copy wins" alone (AirMag breaks it).
- Skip channel records with bit 0 of +78, and lines with categories other than 100 and 200.
- Check each data blob: class, type code equal to the channel's, count a multiple of the array width, decompressed size equal to +24.
- A (line, channel) with no live blob means "no data on this line": fill with missing values and warn **[PROSE S1: real files are sparse]**.
  I saw none in my 8 files.
- Duplicate live channel names are possible in theory; I saw them only among deleted records.
  If two live channels share a name, rename the second (JuliaMag `channel_name` already does this).

## 12. Mapping onto JuliaMag's line database (spec 5.3)

| `.gdb` | JuliaMag | Notes |
|---|---|---|
| line record name, type, number, version | `LineId(type, number, version)` | type by letter (section 5.2). An alphanumeric number (`L28_29`, number field = dummy) does not fit `LineId.number::Int`: warn and give it a free number, keeping the name in the warning. |
| line flight (+100) | `LineInfo.flight` | |
| line date (+84, decimal year) | `LineInfo.date` as `yyyy-mm-dd` | Convert with `year + (doy - 1) / days_in_year`. |
| group lines (category 200) | none | First version: import as lines of type `RANDOM` with a warning, or skip with a warning. |
| `Line Selection` byte | `LineInfo.selected` | `ff` = selected [GUESS]. |
| fiducial start/incr of the blobs | `fid_start`, `fid_step` | One per line in JuliaMag. If all channels of a line agree, use it. If not, resample to the line's most common sampling, or refuse that line with a clear warning. |
| element count / width | `nrows` | Must agree across channels of a line; else pad with missing values and warn. |
| channel name | `ChannelInfo.name` | Through `channel_name` (safe file names, no duplicates). |
| registry `LABEL` | `label` | Fall back to the name. |
| type code | `eltype` | Table in section 7. |
| registry `UNITS` | `units` | |
| format +84 | `format` | NORMAL `:normal`, EXP `:exponential`, TIME `:time`, DATE `:date`, others `:normal`. |
| width +86, decimals +88 | `width`, `decimals` | |
| +78 bit 1 | `protected` | JuliaMag protects imported channels anyway; keep that. |
| array width +110 | `arraylen` | |
| `DB_CHAN_X/Y/Z` | `role` X, Y, Z | Also lon/lat roles for a pair whose IPJ method is 1 (geographic) or units `dega`. |
| IPJ blob of a pair | `PositionPair(x, y, crs)` | crs = `EPSG:nnnn` from the name, or `""` with a warning. Current pair = `DB_CHAN_X/Y`. |
| dummies | missing values | Section 7; note integer dummies differ. |
| `Display List` | channel order | Use it to order channels; fall back to slot order. |

The import flow fits `import_lines` in `line_import.jl`: start a line with `start_line!`, add channels with `import_channel!`, and stream each blob into the channel appenders.
Memory stays at one decompressed blob (a few MB at most), as spec 6.2 asks.

## 13. Test files

All downloaded on 2026-11-04 into `/home/ems/data/juliamag-samples/gdb/<source>/` (764 MB in all).
Scripts and dumps: the session scratchpad folder `gdb-research/` (`gdblib.py`, `gdb_dump.py`, `compare_xyz.py`, `fid_check.py`, `dump_*.txt`, `compare_*.txt`); they are not in the repo.
"XYZ match" means every value in the Oasis XYZ export was compared with the `.gdb` value, within half a unit of the last printed digit.

| File | Size | Source | Compression | Covers | XYZ match |
|---|---|---|---|---|---|
| `AirMag.gdb` (Oasis levelling tutorial) | 1,318,912 | Oasis install sample | SIZE (zlib), 381 blobs | L and T lines, stale admin copies, no CRS | no XYZ (section 14) |
| `usgs-ofr2006-1204-afgrav/afgrav.gdb` + `afgrav.XYZ` | 435,200 + 196,221 | https://pubs.usgs.gov/of/2006/1204/Gravity/ (US public domain) | SPEED (LZRW1) | random line `D0`, 18 deleted channels, Lambert and custom TM CRS | 16,450 of 16,450 |
| `usgs-ofr2004-1096-long-valley/long_valley_ed.gdb` + `long_valley_ed.XYZ` | 4,804,608 + 2,503,606 | https://pubs.usgs.gov/of/2004/1096/downloads/ | none | deleted duplicate names, TIME/DATE formats, alphanumeric line `L28_29`, dummies, 624 stale blobs | 191,580 of 191,580 |
| `usgs-ofr2006-1204-gdr-clmag/GDR_clmag.gdb` + `GDR_clmag.XYZ` | 41,088,000 + 58,357,228 | https://pubs.usgs.gov/of/2006/1204/German_mag/ | none | 1 line of 1,023,807 rows, label differs from name, Herat North datum | 5,119,025 of 5,119,025 (the XYZ leaves out 2 rows that are dummy in every channel) |
| `dggs-gpr2015-004-fortymile/fortymile_linedata.gdb` + `fortymile_linedata_final.xyz` | 173,428,736 + 511,476,196 | Alaska DGGS GPR 2015-4, https://dggs.alaska.gov/pubs/id/29411 (zip files `...-geosoft-database.zip` and `...-ascii-data.zip`, unpacked, zips deleted) | SPEED (LZRW1), 8,064 blobs, 7,532 of them multi-chunk | 288 L/T lines, 2.1 million rows, NAD27 UTM 7N | 57,057,723 of 57,057,723 (XYZ column `BIRDHITE` is channel `BIRDHIT`) |
| `geosciencebc-quest-7042/7042-MtMill.gdb` | 7,817,216 | Geoscience BC QUEST, https://cdn.geosciencebc.com/project_data/QUESTdata/data/ | SIZE (zlib) | **array channels** (width 40), GS_LONG, string, GEOGR, **non-zero fiducial starts**, flights, dates, stale IPJ | no XYZ in the release |
| `geosciencebc-quest-7042/7042_106_wform.gdb` + `7042_106_wform.xyz` | 444,416 + 100,236 | same | none | GS_FLOAT, garbage free records, activity log, flight 106 | 10,000 of 10,000 |

No file has: BYTE, SHORT, USHORT, UBYTE, ULONG or 64-bit integer channels; string arrays; group lines; line versions above 0; a fiducial increment other than 1; channels of one line with different sampling.
S1's corpus has USHORT arrays and group lines (USGS OFR 2011-1270, `https://pubs.usgs.gov/of/2011/1270/report/`) **[PROSE S1]**.

## 14. What AirMag.gdb holds

All **[BYTES: AirMag]**; full dump in `gdb-research/dump_AirMag.txt`.

- Header: 50 channels max, 200 lines max, 350 blob symbols, 10 users, cache 500, page 1024, `comp_level` 2 (SIZE).
- Blob chain: 392 blobs (381 data, 11 admin), ends exactly at 1,318,912 bytes; 392 live directory entries.
- Channels (3, all GS_DOUBLE, array width 1, NORMAL format, +78 = 2, units empty):

| Slot | Name | Label | Width | Decimals | Min | Max | Dummies |
|---|---|---|---|---|---|---|---|
| 0 | `Mag` | `Mag` | 11 | 2 | 55990.98 | 58295.42 | 0 |
| 1 | `x` | `x` | 9 | 1 | 582834.9 | 612106.6 | 0 |
| 2 | `y` | `y` | 10 | 1 | 6849898.5 | 6873483.0 | 0 |

- Lines: 127 = 117 normal lines `L10160` to `L11320` (type 0) and 10 ties `T90060` to `T90150` (type 2).
  Numbers equal the names; versions 0; flights 0; date 2023.1616 (2023-03-01) on all.
  Some numbers end in 1 or 2 (`L10181`, `L10642`), which looks like reflown lines numbered by the survey, not Oasis versions.
- Rows: 83,466 in all, 582 to 854 per line, the same for the 3 channels of each line.
- Fiducials: start 0.0, increment 1.0 on all 381 blobs.
- Compression: every data blob is one zlib stream; header fields +24, +28 and +48 agree on all 381.
- Registries: `Mag` has `CLASS`, `LABEL`, `UNITS` (empty); `x` and `y` have only `LABEL`; line slot 0 has an empty registry.
- No `__dbreg`, no IPJ: the coordinate system and current X/Y are not stored.
  The ranges (x 583 to 612 km, y 6850 to 6873 km) look like a southern-hemisphere UTM grid **[GUESS]**.
- Selection: all 200 line slots `ff`.
- Display list: `Mag`, `x`, `y`.
- Stale copies: 4 admin objects have 2 copies each; for `__552` (`y`) the directory picks the earlier copy.

**I could read every value in AirMag.gdb**: all 3 channels on all 127 lines decode, with the right counts and types and no errors.
What cannot be checked without Oasis is listed in section 17.

## 15. Open risks

1. **Fiducial offsets** rest on one file with non-default starts (MtMill, compressed, increment 1.0).
   The plain-blob offsets (+24, +32) and any increment other than 1.0 are unverified.
2. **Per-channel sampling**: Oasis allows each channel its own fiducial start, increment and row count on a line.
   JuliaMag allows one per line.
   I found no file that differs, but real processed databases (lag-corrected channels, resampled channels) may.
   The importer needs a defined policy and a test file.
3. **Protect flag** (+78 bit 1) is a guess.
4. **Line selection** meaning of the bytes is a guess; every file has all `ff`.
5. **Integer dummies** differ from JuliaMag's; a real value at JuliaMag's typemin becomes missing.
6. **Types JuliaMag lacks** (UInt16, UInt32, Int64, UInt64) need widening; 64-bit integers can lose precision.
7. **Coordinate system**: no EPSG codes in the file; name lookup fails for `*` custom systems, and for methods other than 1, 3, 11, 14 the parameter slots are not mapped **[PROSE S1]**.
8. **Group lines** and **alphanumeric line numbers** have no clean JuliaMag equivalent.
9. **Text encoding** of names and strings is unknown beyond ASCII.
10. **LZRW1** needs our own decoder; a bug truncates data silently, so test it on fortymile and afgrav against their XYZ.
11. **Unknown header words** (bytes 4..7 `f0f0f0f0` in some files, bytes 8..15): a new Oasis version could change the layout.
    The reader should check the arithmetic and refuse what it does not know, instead of guessing.
12. **Large files**: S1 read files up to 1.93 GB; a JuliaMag reader must seek by directory and stream blob by blob, never load the file.
13. **Legal**: the format is proprietary and undocumented.
    pygdb is clean-room and MIT.
    This research used only public files, gxpy (BSD-2), the installed help, and byte analysis; Oasis was not run.

## 16. What a JuliaMag reader needs

First version, must read:

- The format check (section 1), including the Esri folder case.
- Header, layout checks, directory, symbol tables with the free-bit rules.
- Data blobs: plain, zlib, and LZRW1 (with multi-chunk chains), with per-blob probing.
- Types: DOUBLE, FLOAT, LONG, SHORT, BYTE, UBYTE, strings; dummies mapped to JuliaMag missing values.
- Array channels (`arraylen`).
- Lines: name, type letter, number, version, flight, date.
- Fiducial start and increment per blob; one sampling per line, with the policy from risk 2.
- Channel label, units, format, width, decimals.
- Position pairs: `DB_CHAN_X/Y`, IPJ blobs of live pairs, name to EPSG, unknown otherwise (the user can set it, spec 6.6).
- Clear warnings with line and channel names for every skipped or changed item, and progress and cancel per blob.
- Tests: all 8 files in section 13, with the XYZ comparisons as checks.

Can wait:

- Group lines and group classes.
- USHORT, ULONG and 64-bit integer types (no test files).
- Line selection and the display-list channel order.
- `MAKER` history, `FORMULA`, the activity log (could feed JuliaMag's history later).
- Custom (`*`) coordinate systems built from IPJ parameters.
- Projection methods other than geographic, TM, Lambert 2SP and polar stereographic.
- Datum transform parameters (only needed when the datum has no EPSG code).
- Writing `.gdb` files: out of scope.

## 17. Ground truth still needed

An Oasis XYZ export of AirMag.gdb would confirm:

- That the reader's values for `Mag`, `x`, `y` on all 127 lines are right, digit for digit (zlib path on this exact file).
- The line names and their order as Oasis lists them, and that `L10181`-style names are plain line numbers, not versions.
- That the export has no hidden channels (the 3 channels are all there is).

An export alone cannot show the other open points.
For those, a few minutes in Oasis on AirMag.gdb (or a copy) would settle them:

- **Fiducials**: export with a `FIDUCIAL` column; then use Change Channel Fid to set start 1000.5 and increment 0.1 on one channel, save a copy, and send the copy.
  That confirms the compressed offsets, a non-1.0 increment, and a line whose channels differ.
  The same on a database saved with no compression confirms the plain offsets.
- **Protect flag**: unprotect one channel, save a copy, and compare +78.
- **Line selection**: deselect a few lines, save a copy, and compare the `Line Selection` bytes.
- **Coordinate system**: set one (for example GDA94 / MGA zone 54) on `x`, `y`, save a copy, and check that the reader finds it and its EPSG code.
- **Database properties** (Database > Properties): the compression method, current X/Y channels and coordinate system that Oasis reports for AirMag, to compare with the reader's output.
