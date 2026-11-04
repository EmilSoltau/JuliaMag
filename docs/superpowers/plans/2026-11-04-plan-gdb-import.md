# JuliaMag: Geosoft Database (`.gdb`) Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `JuliaMagCore` imports Oasis montaj databases (`.gdb`) into a new or an existing line database.
The import is read-only.
The app lists it with one icon entry and no other UI code.

**Architecture:** A `.gdb` is a paged file: a 256-byte header, a blob directory, symbol tables for blobs, lines, channels and users, then a chain of blobs.
The reader opens the file, checks every layout rule it knows, and refuses the file when one fails.
It then walks the lines in slot order.
For each line, it reads one channel at a time (one blob), found through the directory.
The values go into the channel appenders of `line_import.jl`.
Memory stays at a few buffers the size of one blob.
The importer registers itself like the XYZ importer, so the UI lists it from the registry.

**Tech Stack:** Julia 1.12, CodecZlib.jl 0.7 (for zlib blobs), Proj.jl 1.9 (EPSG name lookup through `crs_from_name`), our own LZRW1 decoder, plus the existing stack (JSON3, Mmap, Test, Aqua, JET; ImGuiTestEngine for the window test).

**Spec:** `docs/superpowers/specs/2026-10-28-juliamag-foundation-design.md` (sections 5.3, 6.1, 6.2, 6.3a, 6.5, 6.6, 8.2, 8.4, 11, 12, 13.2, 13.3).
**Research:** `docs/research/geosoft-gdb-format.md`.
The research file is the authority for every byte offset in this plan.
Its tags say how each fact was checked.
Research sections 12 (mapping), 15 (open risks) and 16 (first version scope) define the work in this plan.
**Follow-ups:** `docs/superpowers/plans/2026-10-28-plan-1-followups.md`.

## Where this fits

| Plan | Delivers |
|---|---|
| 1. Core | Done |
| 2. Grids | Done |
| 3. UI shell | Done |
| 4a. Map view | Done |
| **`.gdb` import (this plan, between 4a and 4b)** | Read-only Geosoft database importer, its tests on public files, a window test |
| 4b, 4c, 5 | Unchanged; see the table in [plan 4a](./2026-11-03-plan-4a-map-view.md) |

## Global Constraints

- Julia 1.12 or newer. Run Julia as `~/.juliaup/bin/julia`.
- `JuliaMagCore` must not depend on any UI or graphics package (spec 13.3).
- No new package. zlib goes through `CodecZlib` (already a dependency). LZRW1 is our own code (about 40 lines), because no maintained Julia package decodes it and the algorithm is small and fixed.
- JuliaMag never writes a `.gdb` file (spec 11). Nothing in this plan opens a `.gdb` for writing, except the test writer in `test/support/`.
- A whole `.gdb` is never loaded into memory (spec 6.2).
  The reader holds the header, the directory and the symbol tables.
  It also holds a few buffers the size of one blob: the packed bytes, the unpacked bytes, the decoded values and the resampled values.
- Progress is reported and cancel is checked once per data blob (spec 6.2).
- Bad input never crashes the app.
  `import_gdb` throws `GdbError` with a plain message, and the job layer turns it into a failed job (spec 6.2, 8.2).
  Input that can be read with a change gives a warning instead.
  A failed or cancelled import leaves no new item, no temp folder, and an append target as it was.
  The `import_lines` frame does this cleanup.
- Every skipped or changed item gives an `ImportWarning` that names the line and the channel.
  Its file line number is 0, because a `.gdb` has no text lines.
- All numbers in a `.gdb` are little-endian. Byte offsets in this plan count from 0, as in the research file.
- Line types are mapped by letter, never by integer: Geosoft 0 `L`, 1 `B`, 2 `T`, 3 `S`, 4 `R`, 5 `P`, 6 `D` (research 5.2). JuliaMag's enum has `TIE` before `BASE`.
  The integer orders differ, so mapping by integer would swap tie and base lines.
- Names of new top-level constants start with `GDB_` or `LZRW1_`, so the duplicate-constant scan in `test/support/consts.jl` stays clean.
- Text in messages, comments and docs: plain English, short sentences, never the em dash character.
- Tests first. Lint (Aqua, JET) and all tests pass before each commit. Tests never use the network.
- Window tests run headless only: `bin/test-headless.sh`. Never open a window on the user's desktop.
- Core tests: `~/.juliaup/bin/julia --project=JuliaMagCore -e 'using Pkg; Pkg.test()'`.
  A fast loop for one file while working: `~/.juliaup/bin/julia --project=JuliaMagCore -e 'using Test, JuliaMagCore; include("JuliaMagCore/test/support/synthetic.jl"); include("JuliaMagCore/test/support/gdb_writer.jl"); include("JuliaMagCore/test/test_gdb_<part>.jl")'`. From Task 9 on, also include `support/gdb_xyz.jl` after `gdb_writer.jl`. The whole suite is the gate before a commit.
- Commit messages: plain, no co-author lines. Commit on `feature/gdb-import`.
- Each task adds its own includes.
  Source files go into `src/JuliaMagCore.jl` after `io/csv_templates.jl`, in the order of the File structure list, so `lzrw1.jl` comes after `gdb_format.jl`, which defines `GdbError`.
  Test files go into `test/runtests.jl` after `test_csv.jl`, in task order.
  Support files go after `support/synthetic.jl`: `gdb_writer.jl` in Task 1 and `gdb_xyz.jl` in Task 9.
- Only `import_gdb` and `GdbError` are exported. Tests reach the other new names with `using JuliaMagCore: ...` at the top of each test file.

## Rulings from the project owner

The project owner decided these before this plan (spec 6.3a).
The tasks implement them.
Two are made exact in "Rulings made while writing this plan" at the end: ruling 3 (more integer types) and ruling 4 (display order, integer and text channels).
The widening table of ruling 7 is in Task 5.

1. Read-only import into the project's own format, like XYZ. Modes "new database" and "append", as for XYZ.
2. A folder named `*.gdb` gives: "`<name>` is an ArcGIS file geodatabase (a folder), not a Geosoft database. JuliaMag reads only Geosoft `.gdb` files."
   A file that fails a layout check is refused.
   The message names the check that failed, and the reader never guesses.
3. Scope is research section 16 "First version, must read". "Can wait" items go to the follow-ups file (Task 11).
   This plan also reads USHORT, ULONG and 64-bit integers (see the closing rulings).
4. Sampling: JuliaMag keeps one sampling per line.
   - The main sampling of a line is the one most of its channels share.
     On a tie, it is the sampling of the first channel in slot order (see the closing rulings).
   - A channel with another fiducial start or step is resampled onto the main sampling by linear interpolation.
     A warning names the line and the channels.
     Integer and text channels follow the rules in the closing rulings.
   - Missing values are not interpolated across.
   - A channel with the main sampling but fewer rows is padded with missing values, with a warning.
5. A line number that is not a number gets the next free number of its type; the warning keeps the original name.
6. Group lines are skipped with a warning.
7. Integer types JuliaMag lacks are widened to the smallest JuliaMag type that holds every value of the Geosoft type, or to Float64 when no JuliaMag type does.
   The choice depends on the type, not on the data.
   ULONG becomes Float64, which is exact, so there is no warning.
   64-bit integers become Float64.
   A warning names the channel when any of its values cannot be stored exactly as Float64 (spec 6.3a, updated 2026-11-04).
   Geosoft dummies become JuliaMag missing values.
   A real value equal to JuliaMag's missing marker gives a warning.
8. Coordinate system: name to EPSG lookup; unknown or custom gives an empty CRS and a warning, and the user sets it (spec 6.6).
9. Streaming blob by blob through the directory, with progress and cancel per blob.
10. Tests:
    - Small public-domain files go in the repo.
    - Larger files and `AirMag.gdb` form an optional set.
      When a file is missing, the test prints a visible skip line.
    - Every file that has an XYZ export is compared with it value by value.
    - Synthetic files cover the edge cases.
    - One headless window test takes a light and a dark screenshot.

## Review Focus

The spec does not name these inputs, but users are likely to meet them.
Each has a test in the task that owns the code.

1. **A file from another Oasis version or source:** bytes 4 to 7 set to `f0 f0 f0 f0` import normally.
   Header word 8 other than `0x10020000`, or word 12 other than `264`, fails the job with "layout JuliaMag does not know".
   So does any failed table sum in Task 1's list.
   No item is left (Task 1).
2. **A processed database:** a lag-corrected channel with a shifted fiducial start, a channel with another step, and a channel cut short are all resampled onto the line's main sampling, with one warning per line that names them (Task 8, Task 9).
3. **A damaged file.**
   Each of these gives a failed job that names the line and the channel where there is one.
   A file cut short fails before any line is read, so its message names the failed check instead.
   It leaves no temp folder, and an append target stays as it was (Tasks 1, 2, 4, 9).
   - A file cut short, such as a broken download.
   - A zlib or LZRW1 blob with a changed byte.
   - A live directory entry that does not land on a blob with its index and page count.
     The reader does not look for another copy in the chain, because the last copy can be stale (research section 4).
4. **Names Windows cannot use and repeated names:** channels named `a/b`, `CON`, `x` and `X` get safe, unique names; the label keeps the original name (Task 7).
5. **Append onto a database made from the XYZ export of the same survey:** a channel whose type differs (XYZ gives Float64, the `.gdb` has Int32) fails with a message naming the channel, and the target is unchanged; matching channels append and lines that exist get a new version (Task 9).

## Alternatives considered

- **No reader; ask users to export XYZ from Oasis.**
  Rejected: users without Oasis cannot convert, and XYZ loses labels, units, formats and coordinate systems.
- **Use pygdb (Python).**
  Rejected: it would add a Python runtime to a Julia app.
  It is used as a reference only.
- **Refuse a line whose channels differ in sampling** (instead of ruling 4).
  Rejected: processed databases, such as those with lag-corrected channels, could not be imported at all.
- **Import group lines as RANDOM lines** (instead of ruling 6).
  Rejected: a group line has no single sampling, and the result would look like survey data.
- **Load whole lines into memory** (instead of ruling 9).
  Rejected: one line of `GDR_clmag` has 1,023,807 rows per channel.

## Open risks from the research (section 15)

| Risk | How this plan handles it |
|---|---|
| 1. Plain-blob fiducial offsets unverified | Task 10 checks the default start and step on the 3 plain files. A step other than 1.0 stays unverified (follow-up, Oasis check). |
| 2. Per-channel sampling | Ruling 4, Task 8. |
| 3. Protect flag is a guess | Not read. Every imported channel starts protected, as for every import. |
| 4. Line selection bytes are a guess | Not read. Every line starts selected (follow-up). |
| 5, 6. Integer dummies and missing types | Ruling 7, Task 5. |
| 7. Coordinate system lookup | Ruling 8, Task 6. |
| 8. Group lines, text line numbers | Rulings 5 and 6, Task 7. |
| 9. Text encoding | UTF-8, else Windows-1252 (Task 2). One warning per file when the fallback is used (Task 9). |
| 10. LZRW1 bug truncates silently | Every blob must unpack to exactly its stated size (Task 4). afgrav and fortymile are compared with their XYZ exports. |
| 11. Unknown header words | Ruling 2, Task 1. |
| 12. Large files | Ruling 9, Task 10 bench. |
| 13. Legal | Clean-room: public files, BSD and MIT sources, and byte analysis only (research Sources). |

---

## File structure

```
JuliaMag/
  JuliaMagCore/
    src/
      JuliaMagCore.jl                 # + includes after csv_templates.jl, + exports
      io/gdb_format.jl                # GdbError, gdb_kind, header and layout checks, directory, symbol tables
      io/lzrw1.jl                     # lzrw1_decode!
      io/gdb_blobs.jl                 # blob headers, plain / zlib / LZRW1 blobs
      io/gdb_values.jl                # GS_* types, dummies, widening, strings
      io/gdb_admin.jl                 # registry (REG) and coordinate system (IPJ) objects
      io/gdb_lines.jl                 # line ids, dates, channel plans, roles, position pairs
      io/gdb_sampling.jl              # main sampling of a line, resampling
      io/gdb_import.jl                # import_gdb, settings, registration
      jobs/jobs.jl                    # import_work sends item warnings to job_warning! (Task 8a)
    test/
      support/gdb_writer.jl           # write_test_gdb, lzrw1_compress (tests and bench only)
      support/gdb_xyz.jl              # compare_gdb_xyz: a database against an Oasis XYZ export
      data/gdb/                       # afgrav.gdb, afgrav.XYZ, LICENSE.md
      test_gdb_format.jl  test_lzrw1.jl  test_gdb_blobs.jl  test_gdb_values.jl
      test_gdb_admin.jl  test_gdb_lines.jl  test_gdb_sampling.jl  test_gdb_import.jl
      test_gdb_real_files.jl          # optional set, skipped with a printed line when files are missing
  JuliaMagUI/
    src/theme/icons.jl                # + "import.geosoft_gdb" => "import" (test_icons requires it)
    test/test_ribbon.jl  test/test_data_tree.jl  test/test_search.jl  test/window/test_ribbon.jl
                                      # importer lists gain the new entry (Task 9)
    test/window/test_gdb_end_to_end.jl
  bench/import_gdb.jl  bench/README.md
  docs/bench.md  README.md  JuliaMagUI/README.md
  docs/superpowers/plans/2026-10-28-plan-1-followups.md
```

---

### Task 1: Format check, header and layout checks

Research sections 1, 2, 3 and 5 (table starts).

**Files:**
- Create: `src/io/gdb_format.jl`, `test/test_gdb_format.jl`, `test/support/gdb_writer.jl`, `test/data/gdb/` (`afgrav.gdb`, `afgrav.XYZ`, `LICENSE.md`)
- Modify: `src/JuliaMagCore.jl` (include after `io/csv_templates.jl`), `test/runtests.jl` (include `support/gdb_writer.jl` after `support/synthetic.jl`, and `test_gdb_format.jl` after `test_csv.jl`)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `struct GdbError <: Exception; msg::String; end`, with `showerror` printing the message only.
  - `gdb_kind(path)::Symbol`: `:esri_folder` for a directory; `:geosoft` for a regular file that starts with `!CBD`; `:unknown` otherwise (also for a missing or short file).
  - `gdb_refusal(path)::Union{Nothing,String}`: `nothing` for `:geosoft`; for `:esri_folder` the ruling 2 text; for a missing file `"no file at <path>"`; for `:unknown` `"<file> is not a Geosoft database: it starts with <first 4 bytes as hex, or "fewer than 4 bytes">, not !CBD."`.
  - `struct GdbHeader` with `Int` fields `chans_max, blobs_max, cache, lines_max, users_max, dir_slots, first_admin, page_size, index_size, blob_start_page, n_pages, comp_level, line_handle0, chan_handle0, user_handle0` and the table starts `blob_table, line_table, chan_table, user_table` (byte offsets).
    The fields come from these words (research section 3): `chans_max = w24`, `blobs_max = w28`, `cache = w32`, `lines_max = w36`, `users_max = w40`, `dir_slots = w44`, `first_admin = w48` (not `w60`), `line_handle0 = w72`, `chan_handle0 = w76`, `user_handle0 = w80`, `page_size = w100`, `index_size = w104`, `blob_start_page = w108`, `n_pages = w112`, `comp_level = w120`.
  - `read_gdb_header(io::IO, file_size::Integer)::GdbHeader`. It throws `GdbError` with `"the file is damaged or uses a Geosoft database layout JuliaMag does not know (<check>). It was not imported."` when any check fails. `<check>` names the rule in plain words. The checks, with word `wN` = int32 at byte N:
    - magic `!CBD`; file at least 256 bytes;
    - `w8 == 0x10020000` and `w12 == 264` (the version words);
    - every capacity (`w24, w28, w36, w40`) above 0, `w32 >= 0`, `page_size = w100 > 0`;
    - `w44 == w60 + w32`, `w48 == w36 * w24`, `w52 == w48 + w28`, `w56 == w60 == w52 + w40`, `w64 == w28 + w36 + w24 + w40`;
    - `w72 == w28`, `w76 == w72 + w36`, `w80 == w76 + w24`; `w84..w96` repeat `w28, w36, w24, w40`;
    - `chan_table = w104 - (w24 + w40) * 128`, `line_table = chan_table - w36 * 128`, `blob_table = 280 + w44 * 6`, and `blob_table + w28 * 128 == line_table`; `user_table = chan_table + w24 * 128`;
    - `w108 * page_size >= w104`, and `(w108 + w112) * page_size == file_size`;
    - `w120` in `0:2`.
    Bytes 4 to 7 are not checked: 13 of the 45 files pygdb lists for that word have `f0 f0 f0 f0`.
    Words 8 and 12 held the values above in all 49 files pygdb lists for them.
    Both counts come from S1 `docs/spec.md`, header table; pygdb reports them on file sets of different size.
  - `struct GdbSlot; live::Bool; page::Int; pages::Int; end`: one directory slot. Task 2 reads them.
  - `open_gdb(path)::GdbFile` and `close(g::GdbFile)`: `mutable struct GdbFile; path::String; io::IOStream; size::Int; header::GdbHeader; dir::Vector{GdbSlot}; cp1252::Bool; end`. In this task `dir` is empty and `cp1252` is false; Task 2 fills `dir`, and Tasks 2 and 6 set `cp1252` (see `gdb_text`). `open_gdb` throws `GdbError(gdb_refusal(path))` for anything but `:geosoft`, and closes the stream when the header check throws.
  - `with_gdb(f, path)`: opens, calls `f(g)`, closes, also on error.
- Test helper `xyz_column_names(path)::Vector{String}` in `test/support/gdb_writer.jl`, for an Oasis XYZ export:
  find the first data row and count its columns;
  return the names on the last `/` comment line before that row that has exactly that many names.
- Test writer (`test/support/gdb_writer.jl`), grown by later tasks:
  - `Base.@kwdef struct TestChannel; name::String; type::Int = 5; arraylen::Int = 1; format::Int = 0; width::Int = 10; decimals::Int = 2; flags::Int = 2; deleted::Bool = false; end`
  - `Base.@kwdef struct TestLine; name::String; number::Int = 0; type::Int = 0; version::Int = 0; flight::Int = 0; date::Float64 = 0.0; category::Int = 100; end`
  - `Base.@kwdef struct TestBlob; values::AbstractVector; fid_start::Float64 = 0.0; fid_step::Float64 = 1.0; pack::Symbol = :none; end` with `pack` in `:none`, `:zlib`, `:lzrw1` (Task 3 adds the compressor), `:lzrw1_stored`.
  - `write_test_gdb(path; channels, lines, blob = (line_slot, chan_slot) -> nothing, chans_max = max(4, length(channels)), lines_max = max(4, length(lines)), blobs_max = 16, users_max = 2, cache = 8, page_size = 1024, comp_level = 0, admin = Pair{String,Vector{UInt8}}[], tweak = h -> h)`.
    It writes the header, directory, symbol tables (user 0 named `SUPER`), then each blob, page aligned, in the layout of research sections 3 to 6.
    `blob` returns a `TestBlob` or `nothing` (no directory entry). The writer streams: it writes the blobs first, leaving room for the directory and symbol tables, then seeks back to write them, so a bench can write a file of 1 GB.
    `admin` adds named admin objects (blob symbol name => bytes of the framed object, from Task 6 helpers).
    `tweak(bytes)` gets the 256 header bytes before they are written, so a test can break one word.

- [ ] **Step 1: Add the public sample file**

Download `afgrav.gdb` (435,200 bytes) and `afgrav.XYZ` (196,221 bytes) from `https://pubs.usgs.gov/of/2006/1204/Gravity/` into `test/data/gdb/`.
They are already in `/home/ems/data/juliamag-samples/gdb/usgs-ofr2006-1204-afgrav/`; copy them from there when the sizes match, so the test run needs no network.
Write `LICENSE.md`: source URL, "U.S. Geological Survey Open-File Report 2006-1204, U.S. public domain", and the date 2026-11-04.
Only afgrav goes into the repo.
`long_valley_ed` (7.3 MB with its XYZ) is too large for the repo.
The Geoscience BC QUEST files have no licence statement in their `Readme.txt` and none was found on geosciencebc.com, so they are not redistributed; they stay in the optional set (Task 10).

- [ ] **Step 2: Write the failing tests**

```julia
g = open_gdb(testdata("gdb/afgrav.gdb"))
h = g.header
@test h.page_size > 0 && (h.blob_start_page + h.n_pages) * h.page_size == filesize(g.path)
@test h.comp_level == 1 && h.blob_table + h.blobs_max * 128 == h.line_table
close(g)
@test gdb_kind(testdata("gdb/afgrav.gdb")) == :geosoft
esri = mkpath(joinpath(mktempdir(), "roads.gdb"))
@test gdb_kind(esri) == :esri_folder
@test occursin("ArcGIS file geodatabase", gdb_refusal(esri))
```

Also, each with `write_test_gdb` and a `tweak`:
- a synthetic file with one channel and one line opens and its header fields equal what the writer was given;
- bytes 4 to 7 set to `f0 f0 f0 f0`: opens;
- `w12` set to 265: `GdbError` whose message has "layout JuliaMag does not know" and "version";
- `w48` off by one; `w104` off by 128; a file cut by one page (`truncate`): each a `GdbError` naming its rule;
- 600 random bytes named `x.gdb`: `:unknown`, and the message has the hex of the first 4 bytes and "!CBD";
- a 2-byte file: `:unknown`, "fewer than 4 bytes".

- [ ] **Step 3: Run to see it fail.** `UndefVarError: open_gdb`.
- [ ] **Step 4: Implement.** Read the 256 header bytes once with `read(io, 256)` and take words with `ltoh(reinterpret(Int32, ...))`.
- [ ] **Step 5: Run to see it pass.**
- [ ] **Step 6: Commit** `git commit -m "Check the layout of Geosoft databases"`

---

### Task 2: Directory, blob location and symbol tables

Research sections 4, 5.1, 5.2, 5.3, 6.1.

**Files:**
- Modify: `src/io/gdb_format.jl`, `test/test_gdb_format.jl`, `test/support/gdb_writer.jl`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `open_gdb` reads all `dir_slots` slots into `g.dir` (`GdbSlot` from Task 1) (6 bytes each from byte 280): `live` = bit 31 of the uint32, `page = word & 0x3FFFFFFF`, `pages` = the uint16.
  - `blob_offset(g, index)::Union{Nothing,Int}`: the byte offset of blob `index` (0-based), as the directory gives it:
    - slot not live: `nothing` (no data);
    - live, and the bytes at `(blob_start_page + page) * page_size` start with `cc cc 00 ff`, with the int32 at +4 equal to `pages` and the int32 at +12 equal to `index`: that offset;
    - live but not landing on such a blob, or with pages that run past the end of the file: throws `GdbError("the directory entry of blob <index> does not point at its data")`. Check the range before reading, so a bad page never gives an `EOFError`.
      The reader does not search the chain for another copy, because the last copy can be stale (research section 4, AirMag `__552`).
  - `struct GdbChannelRecord; slot::Int; name::String; type::Int; flags::Int; format::Int; width::Int; decimals::Int; arraylen::Int; end`
  - `read_gdb_channels(g)::Vector{GdbChannelRecord}`: the live records in slot order. Record offsets per research 5.1 (name at +0, 64 bytes NUL-terminated; type int16 at +76; flags int16 at +78; format int16 at +84; width int16 at +86; decimals int32 at +88; array width int16 at +110). A record is live only when the name is non-empty and every character is printable, bit 0 of the flags is clear, the type is in `0:9` or below 0, and `arraylen >= 1`.
  - `struct GdbLineRecord; slot::Int; name::String; category::Int; date::Float64; number::Int; type::Int; flight::Int; version::Int; end`
  - `read_gdb_lines(g)::Vector{GdbLineRecord}`: records with category 100 or 200 (bit `0x10000` clear), in slot order. Offsets per research 5.2 (category int32 +76, date float64 +84, number int32 +92, type int32 +96, flight int32 +100, version int32 +124).
  - `read_gdb_blob_symbols(g)::Vector{Tuple{Int,String}}`: `(k, name)` of live blob symbols (category int32 +76 equal to 0, name non-empty); symbol `k` owns admin blob `first_admin + k`.
  - Names are decoded with `gdb_text(bytes)::Tuple{String,Bool}`: the text up to the first NUL, as UTF-8 when it is valid, else as Windows-1252 with the full table for bytes 0x80 to 0x9F.
    The `Bool` is true when the Windows-1252 fallback was used.
    `read_gdb_channels`, `read_gdb_lines` and `read_gdb_blob_symbols` set `g.cp1252 = true` when any name used it.
    Task 5 reuses `gdb_text` for string values and counts them in `GdbValueNotes.cp1252`; Task 9 warns once per file from both.
- Writer: `TestChannel(deleted = true)` sets bit 0 of the flags; `garbage_channels::Int = 0` fills that many slots after the real ones with random bytes and bit 0 set (as `7042_106_wform`); `stale::Vector{Int} = Int[]` writes a second, later copy of those blob indexes with other values that the directory does not point at (as AirMag `__552`); `dead::Vector{Int} = Int[]` writes those blobs but leaves their slots not live; `misdirect::Vector{Int} = Int[]` points those live slots one page off. `TestChannel` and `TestLine` take `name_bytes::Vector{UInt8} = UInt8[]`; when it is not empty, the writer stores those bytes as the name instead of the UTF-8 text, so a test can write a Windows-1252 name.

- [ ] **Step 1: Write the failing tests**

```julia
with_gdb(testdata("gdb/afgrav.gdb")) do g
    ch = read_gdb_channels(g)
    @test length(ch) == 10                            # 28 named records, 18 deleted (research 5.1)
    @test Set(lowercase(c.name) for c in ch) == Set(lowercase.(xyz_column_names(testdata("gdb/afgrav.XYZ"))))
    ln = read_gdb_lines(g)
    @test length(ln) == 1 && ln[1].name == "D0" && ln[1].type == 6
end
```

Also, on synthetic files:
- a deleted channel and 5 garbage slots are not returned; the live ones come back in slot order;
- a line with category 200 is returned (Task 7 skips it); a slot with category 65536 and one with 130936 are not;
- `stale = [i]`: `blob_offset` gives the directory's copy, not the later one;
- `misdirect = [i]`: `blob_offset` throws a `GdbError` that names blob `i`;
- `dead = [i]`: `blob_offset` gives `nothing`;
- a channel name `"Mag€"` written in Windows-1252 (`€` is byte `0x80`, which Latin-1 would read as a control character) reads back as `"Mag€"`, and `g.cp1252` is true; on a file with only ASCII names it stays false.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** Read each table with one `read` of `n * 128` bytes; these are small (fortymile: 2000 lines, 100 channels).
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Read the directory and symbol tables of Geosoft databases"`

---

### Task 3: LZRW1 decoder

Research section 6.3 (LZRW1 chunks) and source S6.

**Files:**
- Create: `src/io/lzrw1.jl`, `test/test_lzrw1.jl`
- Modify: `test/support/gdb_writer.jl` (`lzrw1_compress`), `src/JuliaMagCore.jl`, `test/runtests.jl`

**Interfaces:**
- Consumes: Task 1 (`GdbError`).
- Produces:
  - `lzrw1_decode!(out::AbstractVector{UInt8}, o::Int, src::AbstractVector{UInt8}, a::Int, b::Int, n::Int)::Int`: decodes the LZRW1 stream `src[a:b]` into `out[o:o+n-1]` and returns `n`.
    The stream has no 4-byte flag prefix.
    Items come in groups of 16, each group led by a 16-bit little-endian control word read least significant bit first.
    A clear bit is one literal byte.
    A set bit is a copy item of two bytes `b0, b1`: `offset = ((b0 & 0xF0) << 4) | b1`, `length = (b0 & 0x0F) + 1`; it copies `length` bytes one by one from `offset` bytes back in the output (overlap allowed).
    Decoding stops when `n` bytes are out, even mid-group.
    Throws `GdbError` for: a copy with offset 0 or reaching before `o`; output that would pass `n`; input that ends before `n` bytes are out.
- Writer: `lzrw1_compress(data::AbstractVector{UInt8})::Vector{UInt8}`: greedy, a 4096-entry hash of 3-byte prefixes, copy lengths 3 to 16, offsets 1 to 4095. Tests only.

- [ ] **Step 1: Write the failing tests**

```julia
for data in (UInt8[], UInt8[7], rand(UInt8, 1000), repeat(UInt8[1, 2, 3], 5000), zeros(UInt8, 16368))
    z = lzrw1_compress(data)
    out = Vector{UInt8}(undef, length(data))
    @test lzrw1_decode!(out, 1, z, 1, length(z), length(data)) == length(data) && out == data
end
```

Also hand-made streams: an overlapping copy (`"ab"` then a copy of offset 2, length 6 gives `"abababab"`); offset 0 throws; an offset past the start throws; a stream that ends early throws "ends"; 17 literals (two control words); a group that ends after 3 items because `n` is reached.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Add an LZRW1 decoder"`

---

### Task 4: Data blobs: plain, zlib and LZRW1

Research sections 6.1 to 6.4 and 8 (fiducial fields).

**Files:**
- Create: `src/io/gdb_blobs.jl`, `test/test_gdb_blobs.jl`
- Modify: `test/support/gdb_writer.jl` (`:lzrw1` packing with chunks of at most 16,368 bytes, `:lzrw1_stored` chunks), `src/JuliaMagCore.jl`, `test/runtests.jl`

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces:
  - `struct GdbBlobHeader; index::Int; class::Int; pages::Int; packing::Symbol; fid_start::Float64; fid_step::Float64; count::Int; type::Int; raw_bytes::Int; packed_bytes::Int; payload::Int; end`. `packing` is `:none`, `:zlib` or `:lzrw1`. `payload` is the byte offset of the values (plain) or of the stream (packed). For a plain blob `raw_bytes` and `packed_bytes` are -1, because its header has no such fields.
  - `read_blob_header(g, offset)::GdbBlobHeader`:
    - The chunk magic `0f 0e ff fe 12 34 56 78` at +56 means packed: the 56-byte header (+24 int32 raw bytes; +28 int32 packed stream length plus 16, kept as read in `packed_bytes`; +32 fid start; +40 fid step; +48 count; +52 type), subtype int32 at +64 (2 zlib, 1 LZRW1), payload at +72.
    - Else plain: the 48-byte header (+24 fid start, +32 fid step, +40 count, +44 type), payload at +48. The plain fid offsets are a research guess; Task 10 checks them on the plain real files.
    - A blob of class 202 must have the chunk magic, and a blob of class 200 must not. A mismatch, another class, a subtype other than 1 or 2, a negative count, or a packed stream (`packed_bytes - 16` bytes from the payload) that runs past the blob's pages throws `GdbError("blob <index> ...")` with the reason.
    - A packed blob may not claim more raw bytes than its stream can give: at most 1032 times `packed_bytes - 16` for zlib (the bound `read_grd_blocks!` in `geosoft_grd.jl` uses), and at most 8 times for LZRW1 (a group of 34 bytes gives at most 256). Else `GdbError("blob <index> claims <raw> bytes from <packed> packed bytes")`. This check runs before any buffer is sized, so a damaged header cannot make the reader allocate more than its pages justify.
    - A step that is not finite or not above 0 throws `GdbError("blob <index> has a fiducial step of <x>")`.
  - `read_blob_bytes!(buf::Vector{UInt8}, scratch::Vector{UInt8}, g, h::GdbBlobHeader, elsize::Int)::Vector{UInt8}`: fills `buf` (resized) with the `h.count * elsize` value bytes and returns it. `scratch` holds the packed bytes. Both are reused across blobs, so memory stays at one blob.
    - plain: checks that `h.payload + h.count * elsize` stays within the blob's pages (else `GdbError("blob <index> runs past its pages")`), then reads the bytes;
    - zlib: reads the `packed_bytes - 16` stream bytes into `scratch`, then reads exactly `raw_bytes` bytes into `buf` through `ZlibDecompressorStream(IOBuffer(scratch); stop_on_end = true)` with `readbytes!`, and requires the stream to end there. This is the pattern of `read_grd_blocks!` in `geosoft_grd.jl`. A `ZlibError` becomes `GdbError("blob <index> is damaged: its zlib data cannot be inflated")`;
    - LZRW1: walks the chunks from the payload. Each chunk has a 12-byte header: int32 raw length, int32 chunk length (with the 12 bytes), uint32 marker. Marker `0xF4E5D6C7` decodes with `lzrw1_decode!`; `0xF0E1D2C3` copies the bytes as they are; any other marker throws. It stops when the raw lengths add up to `raw_bytes`.
    - Packed paths check `raw_bytes == h.count * elsize` first, and that the output is exactly `raw_bytes`; else `GdbError("blob <index> unpacks to <n> of <m> bytes")`.

- [ ] **Step 1: Write the failing tests**

On synthetic files with one Float64 channel of 5,000 values (a ramp with a few `-1e32`), written once with each packing (`:none`, `:zlib`, `:lzrw1`, `:lzrw1_stored`), and a 40,000-value Float64 LZRW1 blob (20 chunks):

```julia
h = read_blob_header(g, blob_offset(g, 0))
@test h.packing == pack_of[p] && h.count == 5000 && h.fid_start == 12.5 && h.fid_step == 0.1
@test reinterpret(Float64, read_blob_bytes!(UInt8[], UInt8[], g, h, 8)) == values
```

Also: the first live data blob of afgrav is LZRW1 and unpacks to the size its header says; a zlib blob with one payload byte changed throws "cannot be inflated"; an LZRW1 blob with a bad chunk marker throws "marker"; a blob whose class says 200 but holds the magic throws; a file cut inside the last blob fails at `open_gdb` (Task 1 check); a plain blob whose count is larger than its pages hold throws "runs past"; a zlib blob whose header claims 10^9 raw bytes from a 100-byte stream throws "claims", and the call allocates under 1 MB (`@allocated`).

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Read plain, zlib and LZRW1 blobs of Geosoft databases"`

---

### Task 5: Value types, dummies and widening

Research section 7.

**Files:**
- Create: `src/io/gdb_values.jl`, `test/test_gdb_values.jl`
- Modify: `src/JuliaMagCore.jl`, `test/runtests.jl`

**Interfaces:**
- Consumes: Task 4.
- Produces:
  - `struct GdbType; code::Int; size::Int; T::DataType; widened::Bool; lossy::Bool; end` and `gdb_type(code)::GdbType`, throwing `GdbError` for a code of 10 or more. The table (ruling 7):

| Code | Geosoft | Size | JuliaMag `T` | Geosoft dummy | Notes |
|---|---|---|---|---|---|
| 0 | BYTE | 1 | Int8 | -127 | |
| 1 | USHORT | 2 | Int32 | 65535 | widened |
| 2 | SHORT | 2 | Int16 | -32767 | |
| 3 | LONG | 4 | Int32 | -2147483647 | |
| 4 | FLOAT | 4 | Float32 | any value `<= -1e31` | |
| 5 | DOUBLE | 8 | Float64 | any value `<= -1e31` | |
| 6 | UBYTE | 1 | UInt8 | 255 | |
| 7 | ULONG | 4 | Float64 | 4294967295 | widened, exact |
| 8 | LONG64 | 8 | Float64 | -2^63 | widened, lossy |
| 9 | ULONG64 | 8 | Float64 | 2^64 - 1 | widened, lossy |
| < 0 | string | `-code` | String | empty | |

  - `mutable struct GdbValueNotes; clashes::Int; inexact::Int; cp1252::Int; end`: `clashes` counts real values equal to JuliaMag's missing marker (Int8 -128, Int16 -32768, Int32 `typemin`); they stay as stored and so read as missing. `inexact` counts 64-bit values that Float64 cannot store exactly: for LONG64, `Float64(v)` converted back to `Int64` is not `v`; for ULONG64 the same with `UInt64`. Compare in `Int128`, so values at the edge of the range (`2^63 - 1` rounds up to `2^63`) do not throw. `cp1252` counts string values decoded with the Windows-1252 fallback.
  - `gdb_values!(out::Vector{T}, bytes::Vector{UInt8}, t::GdbType, notes::GdbValueNotes)::Vector{T}`: decodes and maps dummies to `missing_value(T)`. Put the inner loop for numeric types in a separate function with concrete argument types (a function barrier).
  - For strings, `out::Vector{String}` and each value is `gdb_text` of its fixed-width, NUL-padded bytes; each value that used the fallback adds 1 to `notes.cp1252`.

- [ ] **Step 1: Write the failing tests**

```julia
n = GdbValueNotes(0, 0, 0)
@test gdb_values!(Int16[], bytes_of(Int16[-32767, 5, -32768]), gdb_type(2), n) == Int16[-32768, 5, -32768]
@test n.clashes == 1
@test isequal(gdb_values!(Float32[], bytes_of(Float32[-1f32, 2.5f0]), gdb_type(4), n), Float32[NaN, 2.5])
@test gdb_values!(Int32[], bytes_of(UInt16[65535, 65534]), gdb_type(1), n) == Int32[typemin(Int32), 65534]
@test gdb_values!(String[], Vector{UInt8}("2007/10/04\0ab\0\0\0\0\0\0\0\0\0"), gdb_type(-11), n) == ["2007/10/04", "ab"]
```

Also: every row of the table above, with its dummy and one real value; `ULONG 4294967294` stays exact; `LONG64 2^60 + 1` counts as inexact, while `LONG64 2^60` and `LONG64 5` do not; `LONG64 2^63 - 1` counts as inexact and does not throw; `ULONG64 2^64 - 2` counts as inexact; UBYTE 255 is missing with no clash; code 10 throws; a string with byte `0x80` reads as `€` and adds 1 to `cp1252`, and an ASCII string adds nothing.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** `bytes_of` is a test helper that `reinterpret`s to `UInt8`.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Map Geosoft value types and dummies to JuliaMag"`

---

### Task 6: Registry and coordinate system objects

Research sections 5.3, 9 and 10.

**Files:**
- Create: `src/io/gdb_admin.jl`, `test/test_gdb_admin.jl`
- Modify: `test/support/gdb_writer.jl` (`test_registry(pairs)` and `test_ipj(; name, method, datum, units)` build framed object bytes), `src/JuliaMagCore.jl`, `test/runtests.jl`

**Interfaces:**
- Consumes: Tasks 2, 4.
- Produces:
  - `read_gdb_object(g, offset)::Union{Nothing,Tuple{String,Vector{UInt8}}}`: the class name (`"REG"`, `"IPJ"`, `"EXT"`; NUL-ended text at +44, research section 9) and the object's bytes from the blob start to `+28 + payload length`. `nothing` when the frame `ff 00 f0 0f` is not at +28 or the length runs past the blob.
  - `gdb_registry(bytes)::Dict{String,String}`: `n` at +124, then `n` slots of 256 bytes, each `KEY\0value\0`. Throws `GdbError` when `n` is negative or the slots run past the bytes.
  - `struct GdbIpj; name::String; method::Int; datum::String; units::String; end`; `gdb_ipj(bytes)::GdbIpj` reads name at +104 (64 bytes), method int32 at +168, datum at +180, units at +452.
  - `struct GdbMeta; dbreg::Dict{String,String}; channel_reg::Dict{Int,Dict{String,String}}; ipj::Vector{Tuple{String,String,GdbIpj}}; end` (channel registries by channel slot; `ipj` entries are `(x name, y name, ipj)`, in symbol order).
    An IPJ symbol is named exactly `?|IPJ_<X>:<Y>`: `?|IPJ_` is literal text, and X and Y are split at the `:`. A name with no `:` or more than one is skipped with a warning naming the symbol. afgrav has three: `?|IPJ_xTM:yTM`, `?|IPJ_lon:lat`, `?|IPJ_xlam:ylam`.
  - `read_gdb_meta(g, symbols)::Tuple{GdbMeta,Vector{String}}`: reads `__dbreg`, `__<n>` with `chan_handle0 <= n < user_handle0` (channel slot `n - chan_handle0`), and every IPJ object. A missing or damaged admin object is a warning (`"the <name> object of the file is damaged; it was skipped"`), never a failed import: it holds metadata, not data. This includes a live admin directory slot that misses its blob: `read_gdb_meta` catches the `GdbError` from `blob_offset` and from the object readers, and turns it into this warning. Line registries and other objects are not read.
  - `gdb_crs(ipj::GdbIpj, x::String, y::String)::Tuple{String,Union{Nothing,String}}`: `("EPSG:n", nothing)` when `crs_from_name(ipj.name)` finds one; else `("", warning)`. A name whose projection part starts with `*` (the whole name, or the part after `/ `, as in `WGS 84 / *tm_afghan`; `occursin(r"(^|/ )\*", name)`) gives `"the coordinate system <name> is a Geosoft custom system with no EPSG code. Set the coordinate system of <x>, <y> in the database."`; another unknown name gives `"JuliaMag does not know the coordinate system <name>. ..."` with the same last sentence. `x` and `y` are the JuliaMag channel names of the pair.
  - Text read here goes through `gdb_text`, and sets `g.cp1252` like Task 2.

- [ ] **Step 1: Write the failing tests**

```julia
with_gdb(testdata("gdb/afgrav.gdb")) do g
    meta, warns = read_gdb_meta(g, read_gdb_blob_symbols(g))
    @test isempty(warns)
    @test meta.dbreg["DB_CHAN_X"] == "xTM" && meta.dbreg["DB_CHAN_Y"] == "yTM"
    @test Set((x, y) for (x, y, _) in meta.ipj) == Set([("xTM", "yTM"), ("lon", "lat"), ("xlam", "ylam")])
    @test only(i[3].name for i in meta.ipj if i[1] == "xTM") == "WGS 84 / *tm_afghan"    # custom TM
end
@test gdb_crs(GdbIpj("NAD27 / UTM zone 7N", 11, "NAD27", "m"), "x", "y")[1] == "EPSG:26707"
@test gdb_crs(GdbIpj("NAD83 / UTM zone 10N", 11, "NAD83", "m"), "x", "y")[1] == "EPSG:26910"
@test gdb_crs(GdbIpj("WGS 84", 1, "WGS 84", "dega"), "lon", "lat")[1] == "EPSG:4326"
c, w = gdb_crs(GdbIpj("WGS 84 / *tm_afghan", 11, "WGS 84", "m"), "xTM", "yTM")
@test c == "" && occursin("custom", w) && occursin("xTM, yTM", w)
c, w = gdb_crs(GdbIpj("*local_grid", 11, "WGS 84", "m"), "x", "y")
@test c == "" && occursin("custom", w)
c, w = gdb_crs(GdbIpj("Made up / system", 11, "WGS 84", "m"), "x", "y")
@test c == "" && occursin("does not know", w)
```

The afgrav values above come from a byte scan of the file made while reviewing this plan, not from the reader under test.
The file holds four copies of the registry; three say `xTM`, `yTM` and one older one says `lat` for Y.
The directory decides which copy is live. If the reader returns another value, check the live copy by hand before changing the test.
The three IPJ objects are a geographic system (`lon:lat`), a custom Lambert system (`xlam:ylam`, `WGS 84 / *lcc_afghan`) and the custom TM system (`xTM:yTM`, `WGS 84 / *tm_afghan`).
The channels `lon`, `lat`, `xlam` and `ylam` are deleted in afgrav (slots 24 to 27, flag bit 0 set), so two of the three IPJ objects are stale; Task 7 drops them.
Research section 10 names afgrav's custom system `*TM_afghan_adf`; the file says `*tm_afghan` (Task 11 corrects the research file).
Also, on synthetic files: a registry with `LABEL` and `UNITS` for channel slot 1 reads back by slot; a registry whose frame is broken gives one warning and an empty registry; an IPJ symbol whose channels are not live is still returned here (Task 7 drops it); a registry with `n = -1` gives a warning; a `misdirect` slot on the `__dbreg` admin blob gives the "damaged" warning and an empty `dbreg`, not an error.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Read registries and coordinate systems of Geosoft databases"`

---

### Task 7: Lines and channels

Research section 12, rulings 5, 6 and 8.

**Files:**
- Create: `src/io/gdb_lines.jl`, `test/test_gdb_lines.jl`
- Modify: `src/JuliaMagCore.jl`, `test/runtests.jl`

**Interfaces:**
- Consumes: Tasks 2, 5, 6; `line_import.jl` (`channel_name`, `position_roles`, `WarningLog`, `warn!`).
- Produces:
  - `gdb_line_type(code)::Union{Nothing,LineType}`: by letter, `0 => 'L', 1 => 'B', 2 => 'T', 3 => 'S', 4 => 'R', 5 => 'P', 6 => 'D'`; another code gives `nothing`.
  - `gdb_date(x::Float64)::String`: `""` for 0, not finite, or `<= -1e31`; else `yyyy-mm-dd` with `year = floor(x)` and day of year `round((x - year) * Dates.daysinyear(year)) + 1`, clamped to `1:Dates.daysinyear(year)`. This inverts the research formula `year + (doy - 1) / days_in_year`.
  - `struct GdbLinePlan; slot::Int; id::LineId; flight::Int; date::String; name::String; end` (`name` is the name in the file).
  - `plan_gdb_lines(records, db::LineDatabase, log::WarningLog)::Vector{GdbLinePlan}`, in slot order:
    - category 200: skipped, `"group line <name> was skipped; JuliaMag has no group lines"`;
    - an unknown type code: skipped with a warning naming the line and the code;
    - number field equal to the int32 dummy -2147483647 (alphanumeric name): the next free number of its type, which is one above the highest number of that type among `db.lines` and all numeric lines of the file, counting up for each such line; warning `"line <name> has a name that is not a number; it was imported as <new name>"`;
    - the version from the record; a taken id gets the next version at import time, because `start_line!` calls `free_line_id` (Task 9), as XYZ does.
  - `struct GdbChannelPlan; slot::Int; name::String; label::String; units::String; gtype::GdbType; arraylen::Int; format::Symbol; width::Int; decimals::Int; role::ChannelRole; end`
  - `plan_gdb_channels(records, meta, crs::String, log)::Tuple{Vector{GdbChannelPlan},Vector{PositionPair},Int}`: the plans in slot order, the position pairs and the index of the current pair (0 when none):
    - names through `channel_name(raw, k, taken)` with `taken` starting empty, in slot order (safe and unique); `label` = registry `LABEL`, else the name in the file; `units` = registry `UNITS`, else `""`;
    - format: 0 `:normal`, 1 `:exponential`, 2 `:time`, 3 `:date`; any other format (4 `GEOGR`, 5 `SIGDIG`, 6 `HEX`, or unknown) becomes `:normal`;
    - width and decimals from the record, when JuliaMag accepts them (`width >= 1`, `decimals >= -1`, the rule of `set_channel_info!`); else JuliaMag's import defaults, width 10 and decimals -1;
    - one warning per file names the channels whose display format, width or decimals changed: `"channels <c>, <d>: their Oasis display settings have no JuliaMag equal; they are shown as normal numbers"`. Spec 6.3a says every changed item gives a warning. One line per file keeps it short, since only the display changes;
    - a string channel with `arraylen > 1`: skipped, `"channel <c> is an array of text values; JuliaMag cannot store it, so it was skipped"`;
    - pairs, in this order:
      1. The current pair: `DB_CHAN_X`, `DB_CHAN_Y` of `__dbreg` when both are live channels.
         Else the first X and Y channels by name, as `position_roles` gives them for XYZ.
      2. Each IPJ entry whose two channels are live, in symbol order, unless it names the same two channels as an earlier pair.
      3. As XYZ's `add_position_pairs!` does: the first LON and LAT channels by name, when no earlier pair uses them, with `EPSG:4326` and no warning.
    - the returned vector holds the pairs in that order. The current index is 1 when step 1 found a pair. When it found none but later steps did, the first pair is current, also index 1. With no pairs it is 0.
    - kind and roles: a pair is geographic when its IPJ method is 1 or its units are `dega`, or when it came from step 3. Others are projected. The first projected pair gets `ROLE_X`, `ROLE_Y`, and the first geographic pair gets `ROLE_LON`, `ROLE_LAT`. Other pairs get no roles, as `position_roles` gives a role only once. `DB_CHAN_Z` gets `ROLE_Z`.
    - CRS: from `gdb_crs(ipj, x, y)` when the pair has an IPJ. When that is empty, and the pair is current, and the `crs` setting is not empty, the pair takes `crs`. A pair left with an empty CRS gives the `gdb_crs` warning, or `"the file stores no coordinate system for <x>, <y>. Set it in the database."` when it had no IPJ.
    - pairs name the JuliaMag channel names (after `channel_name`), not the file names. In append mode, Task 9 maps them to the names of the existing channels.

- [ ] **Step 1: Write the failing tests**

```julia
@test gdb_date(2023 + 59 / 365) == "2023-03-01"            # AirMag, research 14
@test gdb_date(2007 + 276 / 365) == "2007-10-04"
@test gdb_date(0.0) == ""
@test gdb_line_type(1) == BASE && gdb_line_type(2) == TIE
log = WarningLog()
plans = plan_gdb_lines(recs, empty_db, log)   # L10, L28_29 (dummy number), L20, group G1, T5, T_x (dummy)
@test [line_name(p.id) for p in plans] == ["L10", "L21", "L20", "T5", "T6"]
@test any(w -> occursin("L28_29", w.message) && occursin("L21", w.message), log.list)
@test any(w -> occursin("group line G1", w.message), log.list)
```

Also:
- channels `a/b`, `CON`, `x`, `X`: names `a_b`, `CON_`, `x`, `X_2`; labels keep the file names (Review Focus 4);
- `DB_CHAN_X = "Easting"`, `DB_CHAN_Y = "Northing"` with an IPJ `NAD83 / UTM zone 10N`: current pair `Easting, Northing` with `EPSG:26910`, roles X and Y;
- a second IPJ pair `Longitude, Latitude` with method 1: a second pair with `EPSG:4326` and roles LON and LAT;
- a stale IPJ for `GPSLon1:GPSLat1` (not live): no pair;
- no `__dbreg`, channels `x`, `y` (AirMag): current pair `x, y` with `""` and the "stores no coordinate system" warning; with `crs = "EPSG:32755"` the pair takes it and there is no warning;
- a custom `*TM` IPJ on the current pair: `""` and the custom warning;
- a string array channel is skipped with its warning;
- a record with width 0 and decimals -5 gives width 10 and decimals -1; a channel with format 4 (`GEOGR`, as MtMill's `Longitude`) gives `:normal`; both are named in the one display warning;
- channels `Longitude`, `Latitude` with no IPJ and no `__dbreg`, next to `x`, `y`: the pairs are `x, y` (current, empty CRS) and `Longitude, Latitude` with `EPSG:4326`;
- afgrav: exactly two pairs. The current pair is `xTM, yTM`, with `""`, roles X and Y and the custom warning. The second is `longitude, latitude` from step 3, with `EPSG:4326`, roles LON and LAT and no warning. The IPJ objects for `lon:lat` and `xlam:ylam` give no pair, because those channels are deleted;
- an IPJ pair `xlam, ylam` with live channels, next to a current projected pair: a second projected pair with no roles.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Map Geosoft lines and channels onto JuliaMag"`

---

### Task 8: Main sampling and resampling

Research section 8 and 15 (risk 2), ruling 4.

**Files:**
- Create: `src/io/gdb_sampling.jl`, `test/test_gdb_sampling.jl`
- Modify: `src/JuliaMagCore.jl`, `test/runtests.jl`

**Interfaces:**
- Consumes: nothing from the `.gdb` tasks; plain values only.
- Produces:
  - `struct Sampling; start::Float64; step::Float64; end`, and `same_sampling(a, b)::Bool`: steps equal within `1e-9` relative, and starts equal within `1e-6 * step`.
  - `main_sampling(list::Vector{Sampling})::Sampling`: the sampling the most entries share (by `same_sampling`); on a tie, the one that comes first in `list`. `list` is in display order (slot order, see "Rulings made while writing this plan").
  - `resample!(out::AbstractVector{T}, src::AbstractVector{T}, from::Sampling, to::Sampling, rows::Int, width::Int)`: fills `out` (length `rows * width`) with `src` (length `n * width`) resampled from `from` onto `to`. For output row `r`, the source position is `x = (to.start + (r - 1) * to.step - from.start) / from.step` (0-based).
    - `x` within `1e-6` of a whole number `k` in `0:n-1`: the value of row `k + 1`, also when it is missing;
    - else, with `k = floor(x)` and both rows `k + 1`, `k + 2` in range and not missing: linear interpolation (`Float32`, `Float64`); integer types interpolate in `Float64` and round to the nearest value, with ties away from zero (`round(T, v, RoundNearestTiesAway)`, clamped to the type's range without its missing marker); strings take the nearer row, and the earlier row on a tie;
    - else (outside the source, or a missing neighbour): missing.
    Each of the `width` values of a row is done on its own.
  - Put the inner loop in a separate function with concrete argument types (a function barrier).

- [ ] **Step 1: Write the failing tests**

```julia
s = [Sampling(0.0, 1.0), Sampling(0.5, 1.0), Sampling(0.0, 1.0), Sampling(0.5, 1.0)]
@test main_sampling(s) == Sampling(0.0, 1.0)                       # tie: first in order
@test main_sampling([Sampling(3.0, 0.1), Sampling(0.0, 1.0), Sampling(0.0, 1.0)]) == Sampling(0.0, 1.0)
out = Vector{Float64}(undef, 5)
resample!(out, [10.0, 20.0, NaN, 40.0], Sampling(0.5, 1.0), Sampling(0.0, 1.0), 5, 1)
@test isequal(out, [NaN, 15.0, NaN, NaN, NaN])                       # missing not crossed, out of range missing
resample!(out, [1.0, 2.0, 3.0], Sampling(0.0, 2.0), Sampling(0.0, 1.0), 5, 1)
@test out == [1.0, 1.5, 2.0, 2.5, 3.0]
```

Also: `Int32` values `[0, 3]` from step 2 onto step 1 give `[0, 2, 3]`, and `[0, 5]` give `[0, 3, 5]` (2.5 rounds away from zero, where Julia's default would give 2); an `Int16` neighbour at the missing marker gives missing; a 2-wide array resamples each column; strings take the nearer row, and the earlier one at 0.5; an exact hit on a missing row stays missing; `same_sampling(Sampling(33727.0, 1.0), Sampling(33727.0 + 1e-9, 1.0))` is true.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Find a line's main sampling and resample channels onto it"`

---

### Task 8a: Import warnings on the job card

Approved by the project owner on 2026-11-04.
Today no importer calls `job_warning!`: `import_work` in `jobs/jobs.jl` only prints import warnings into the report text, so the job card never shows them.
This applies to every importer, not only `.gdb`.

**Files:**
- Modify: `JuliaMagCore/src/jobs/jobs.jl` (`import_work`), `JuliaMagCore/test/test_jobs.jl` (or the XYZ import tests), and any existing test that expects `job_warnings(job)` to be empty after an import with item warnings.

**Interfaces:**
- Consumes: `ImportResult.warnings`, `job_warning!`.
- Produces: in `import_work`, a warning with `file_line == 0` is about the item as a whole (a coordinate system, a skipped line or channel, a resampled channel). It goes through `job_warning!`, which adds it to `job_warnings(job)` and writes one "Warning:" line to the report. It is not printed a second time.
  A warning with `file_line > 0` is about one row of a text file. It stays in the report text only, as today, so a file with many bad rows does not flood the job card.

- [ ] **Step 1: Write the failing tests.** An XYZ import whose file gives one item warning (for example a position pair with no coordinate system) and two bad rows: `job_warnings(job)` holds exactly the item warning; the report text holds it once, and holds the two row warnings with their line numbers.
- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.** Run the core and UI suites. Update any test that expected no job warnings after such an import.
- [ ] **Step 5: Commit** `git commit -m "Show item warnings of an import on its job card"`

---

### Task 9: The importer

Spec 6.2, 6.3a, 6.5; research section 12 (last paragraph).

**Files:**
- Create: `src/io/gdb_import.jl`, `test/test_gdb_import.jl`, `test/support/gdb_xyz.jl`
- Modify: `src/JuliaMagCore.jl` (export `import_gdb`, `GdbError`), `test/runtests.jl` (include `support/gdb_xyz.jl` after `support/gdb_writer.jl`, and `test_gdb_import.jl` after `test_gdb_sampling.jl`), `JuliaMagUI/src/theme/icons.jl` (`"import.geosoft_gdb" => "import"`)
- Modify, UI tests that list the importers exactly (the menus come from `Core.importers()`, and the new importer registers after CSV):
  - `JuliaMagUI/test/test_ribbon.jl:38-39`: `["Geosoft XYZ...", "CSV and text...", "Geosoft database..."]`;
  - `JuliaMagUI/test/test_data_tree.jl:296`: `["Import Geosoft XYZ...", "Import CSV and Text...", "Import Geosoft database..."]`;
  - `JuliaMagUI/test/test_search.jl:205`: `["import.geosoft_xyz", "import.csv", "import.geosoft_gdb", "export.geosoft_xyz", "export.csv", "export.parquet"]`;
  - `JuliaMagUI/test/window/test_ribbon.jl:87`: the same three labels as `test_ribbon.jl`.
  The exact labels come from the registry name `"Geosoft database"` through the same code that makes the XYZ and CSV labels; check them on the first run, and keep the tests exact.

**Interfaces:**
- Consumes: Tasks 1 to 8; `import_lines`, `start_line!`, `end_line!`, `import_channel!`, `channel_position_ci`, `add_pair!`, `open_appenders`, `append_value!`, `close_appenders!`, `check_import_args`, `spec_values`, `record!`.
- Produces:
  - `import_gdb(s, path; name = <file name without extension>, crs = "", mode = :new, target = "", progress = NO_PROGRESS, record = true)::ImportResult`, recorded as `"import.geosoft_gdb"` with the same arguments as `import_xyz`.
    1. `gdb_refusal(path)` first (before `check_import_args`, which wants a file): a refusal throws `GdbError` with its text.
    2. Open the file and read the header, tables and metadata before `import_lines`, so a refused file makes no temp folder.
    3. Inside `import_lines(...) do db`, first make the plans: `plan_gdb_lines` (it needs `db`, which in append mode is the target) and `plan_gdb_channels`, both writing into one `WarningLog`. Add the warnings from `read_gdb_meta` to the same log, with file line 0. That log becomes the `warnings` of the result. Then, for each channel plan:
       - note whether the channel is new (`channel_position_ci(db, name) == 0`);
       - call `import_channel!(db, name, label, T, units, role, arraylen, "Geosoft database")`. `T` is the JuliaMag type of its `GdbType`. The last argument is the source name that `import_channel!` puts in its error text. It already sets the label and units of a new channel;
       - keep the name it returns. In append mode this is the existing channel's name, which can differ in case;
       - for a new channel, set format, width and decimals from the plan. An existing channel keeps its own properties.
       Then map the channel names of each planned pair to the returned names, and add the pairs with `add_pair!` in plan order. `add_pair!` skips a pair the database already has.
       Set `db.current_pair` only when it is 0, as `add_position_pairs!` does: to the index in `db.pairs` of the file's current pair, found by its x and y names. In append mode a target that already has a current pair keeps it.
    4. Open the appenders once. The progress total is the number of planned (line, channel) blobs with a live slot. For each planned line: read the headers of its channel blobs (`blob_offset` on `line_slot * chans_max + chan_slot`); skip the line with `"line <name> has no data; skipped"` when it has no blob; else find the main sampling and the line's rows (the most rows among channels with the main sampling); `start_line!`, then set `nrows`, `fid_start` and `fid_step`.
    5. Then for each channel, one blob at a time: check `is_cancelled` (throw `ImportCancelled`), unpack, and check the blob:
       - its type must equal the channel's, else `GdbError("blob <index> holds type <code>, but the channel has type <code>")`;
       - its count must be a multiple of `arraylen`, else `GdbError("blob <index> holds <n> values, not a multiple of the array width <a>")`.
       Decode with `gdb_values!`, resample when its sampling differs, and append. Report progress after each blob.
       A channel with fewer rows than the line is padded by `end_line!`; this step only records it for the warning.
       When all lines are done, the body closes the appenders and returns `(warnings, rows, lines)`, as `import_lines` expects.
    6. Warnings per line, each naming the line: one for the channels resampled (`"line L10: channels A, B have another fiducial start or step than the line (start s, step d); they were resampled onto it"`), one for the channels padded (`"line L10: channels C have fewer rows than the line; the rest are missing"`), one for channels with no data on the line (`"line L10: channels D have no data on this line; they are missing"`). Use "channel" instead of "channels" when only one is named. Per file: one warning when `g.cp1252` is true or any channel's `notes.cp1252` is above 0 (`"some names or text values are not valid UTF-8; they were read as Windows-1252"`). Per channel over the whole file: one warning for value clashes (`"channel <c>: <n> values equal JuliaMag's missing marker and read as missing"`), and one when `notes.inexact` is above 0 (`"channel <c>: <n> 64-bit values cannot be stored exactly as Float64 and were rounded"`). A 64-bit channel whose values are all exact gives no warning.
    7. Any `GdbError` from a blob is thrown again as `GdbError("line <L>, channel <c>: <message>")`, so the job fails with a message naming both.
    8. Close the file in a `finally`.
  - `GDB_SETTINGS`: the four XYZ settings (`mode`, `name`, `target`, `crs`), with `crs` help `"Used for the current X and Y channels when the file stores no coordinate system for them, or one JuliaMag cannot use, such as a Geosoft custom system. Example: EPSG:7855."`.
  - `run_gdb_importer(s, path, settings, progress)` and `register_importer!(ImporterSpec("import.geosoft_gdb", "Geosoft database", [".gdb"], ITEM_DATABASE, GDB_SETTINGS, run_gdb_importer))`.
- Test support `compare_gdb_xyz(db, xyz; rename = Dict{String,String}(), skip_all_missing_rows = false)::Tuple{Int,Vector{String}}`. It returns the count of values checked and the first 20 mismatches as text.
  1. Stream the Oasis XYZ export with `eachfileline`, and take the column names with `xyz_column_names`.
  2. Match the columns to channels by name, then by label, ignoring case. `rename` maps an XYZ name to a channel name first.
  3. Match the k-th line block (`Line`, `Tie`, ... headers; one block when there are none) to `db.lines[k]`, and each row to the next row of that line.
     `skip_all_missing_rows` first drops database rows that are missing in every compared channel (`GDR_clmag`).
  4. Compare each value:
     - `*` must be missing;
     - a plain number with `d` digits after the point must match within `0.5 * 10.0^-d`;
     - a number in exponent form `m e k` must match within `0.5 * 10.0^(k - d)`, where `d` is the digit count after the point of `m`;
     - `hh:mm:ss.ss` is read as decimal hours, and must match within half a unit of the last printed seconds digit, divided by 3600;
     - `yyyy/mm/dd` is read as a decimal year with `year + (doy - 1) / days_in_year` (research 7 and section 5.2), and must match within half a day, `0.5 / Dates.daysinyear(year)`.
  It does not use `import_xyz`: that reader turns time and date text into missing values, and it does not keep how many digits each value had, which the tolerances need.

- [ ] **Step 1: Write the failing tests**

```julia
s = fresh_session()
job = wait_job(import_file(s, testdata("gdb/afgrav.gdb")))
@test status(job) == JOB_DONE
db = database(s.project, only(job.outputs))
@test length(db.lines) == 1 && line_name(db.lines[1].id) == "D0"
@test length(db.channels) == 10 && all(c.protected for c in db.channels)
n, bad = compare_gdb_xyz(db, testdata("gdb/afgrav.XYZ"))
@test isempty(bad) && n == 16_450                               # research 13
@test s.history[end].command == "import.geosoft_gdb"
```

Also, on synthetic files:
- every type of Task 5 in one file round-trips through `import_file` into the right JuliaMag type, with dummies as missing, and the clash warning for an `Int8` value -128;
- a line where channel B starts 0.5 later and channel C has step 2: the line keeps A's sampling, B and C are resampled (values checked), one warning names B and C (Review Focus 2);
- a line where channel B has 10 fewer rows with the same sampling: padded, one warning;
- a channel with no blob on line 2: missing there, one warning; a line with no blobs: skipped with a warning;
- an alphanumeric line and a group line give their Task 7 warnings in `job_warnings(job)` (Task 8a), each once, and the report text holds each once;
- a zlib blob with a changed byte: `JOB_FAILED`, the error names the line and channel, no `databases/.importing-*` folder (Review Focus 3);
- a `misdirect` slot: `JOB_FAILED`, the error names the line and channel, no temp folder;
- a channel name and a string value in Windows-1252: the import succeeds with one fallback warning for the file; an all-ASCII file gives none;
- cancel after the first blob: `@test_throws JuliaMagCore.ImportCancelled import_gdb(s, path; progress = gdb_cancel_later())`, with `gdb_cancel_later()` built like `csv_cancel_later()` in `test_csv.jl`; then no item and no temp folder;
- a LONG64 channel with the value 2^60 + 1 gives one inexact warning; one with the values 5 and 2^60 gives none;
- append (Review Focus 5): import a synthetic file, then append the same file to it; each line now exists twice, as version 0 and version 1, with the same rows, so the database holds twice the rows; for the name match, write a second synthetic file whose channels are all Float64 (`X`, `Y`, `Mag`), build a target database in the test with channels `x`, `y`, `mag` (lower case, Float64), and append the file to it: the rows go into `x`, `y`, `mag`, no new channel appears, and the position pair names `x`, `y`; for the type check, append a synthetic file whose `FltNo` is Int32 to a target whose `FltNo` is Float64 (the type `import_xyz` gives every channel): `JOB_FAILED` naming `FltNo`, and `database.json` of the target is byte for byte as before;
- undo of the import job takes the item out; redo puts it back;
- an Esri folder through `import_file`: `JOB_FAILED` with "ArcGIS file geodatabase", no item;
- the importer is in `importers()` and `importer_for("x.GDB")` finds it.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** Keep one `GdbValueNotes` per channel. Use typed buffers per JuliaMag type, made once per import, so the inner loops have concrete types.
- [ ] **Step 4: Run to see it pass.** Run the UI suite too: `bin/test-headless.sh`. `test_icons.jl` and `test_commands.jl` read the registry, and the four tests changed above list the importers.
- [ ] **Step 5: Commit** `git commit -m "Import Geosoft databases"`

---

### Task 10: Real files and a large file

Research sections 13 and 14.

**Files:**
- Create: `test/test_gdb_real_files.jl`, `bench/import_gdb.jl`
- Modify: `test/runtests.jl` (include `test_gdb_real_files.jl` after `test_gdb_import.jl`), `docs/bench.md`, `bench/README.md` (list the new script)

**Interfaces:**
- Consumes: Task 9.
- Produces:
  - The optional set reads files from `GDB_SAMPLES = get(ENV, "JULIAMAG_GDB_SAMPLES", "/home/ems/data/juliamag-samples/gdb")` and AirMag from `ENV["JULIAMAG_AIRMAG_GDB"]` (a path to `AirMag.gdb`; Geosoft's tutorial file, not ours to share).
  - For each file that is missing, the test prints one line, `"SKIP gdb real file: <relative path> not found (set JULIAMAG_GDB_SAMPLES)"` or `"SKIP AirMag.gdb: set JULIAMAG_AIRMAG_GDB"`, with `println` (the suite must print no warnings), and runs no test for it.
  - `bench/import_gdb.jl [n_lines]`:
    - writes a synthetic zlib `.gdb` with the test writer: default 400 lines, 10 Float64 channels, 30,000 rows, so 960 MB before compression. The values are a random walk, so zlib keeps most of that size.
    - imports it in a fresh Julia process with `import_file` and `wait_job`, and prints seconds, MB/s and the growth of `Sys.maxrss()` in that process. `bench/import_grid.jl` runs each step in its own process for the same reason: `Sys.maxrss()` is a peak for the whole process, so the writer's memory would hide the import's.
    - with `JULIAMAG_GDB_SAMPLES` set, it also times `fortymile_linedata.gdb` in its own process.

- [ ] **Step 1: Write the tests**

Each file is imported with `import_file`; checks from research sections 13 and 14:
- `usgs-ofr2004-1096-long-valley/long_valley_ed.gdb` (plain blobs): `compare_gdb_xyz` checks 191,580 values with no mismatch; 15 channels; 30 lines; the line `L28_29` warning; `TIME` and `DATE` channels have formats `:time` and `:date`; 11,316 missing values in all.
- `usgs-ofr2006-1204-gdr-clmag/GDR_clmag.gdb` (plain): 5,119,025 values with `skip_all_missing_rows = true`; channel `resmag` has label `mag`; 1 line of 1,023,807 rows.
- `dggs-gpr2015-004-fortymile/fortymile_linedata.gdb` (LZRW1, multi-chunk): 57,057,723 values with `rename = Dict("BIRDHITE" => "BIRDHIT")`; 288 lines; the current pair has `EPSG:26707`. Its memory use is measured by the bench, not here, because earlier tests in the same process set the peak.
- `geosciencebc-quest-7042/7042_106_wform.gdb` (plain, `GS_FLOAT`): 10,000 values; the channel `fiducial` is `Float32`; flight 106.
- `geosciencebc-quest-7042/7042-MtMill.gdb` (zlib, arrays, `GS_LONG`, strings, non-zero fiducial starts; no XYZ): channels `Sf` and `Bf` have `arraylen == 40`; `FltNo` is `Int32` and equals the line's flight on every row that is not missing; `Date` is `String` and equals the line date written as `yyyy/mm/dd`; every line's `fid_start` is above 0 and `fid_step == 1.0`; the X, Y pair has `EPSG:26910`; no pair from the stale IPJ objects.
- AirMag: 127 lines (117 of type `LINE` from `L10160` to `L11320`, 10 `TIE` from `T90060` to `T90150`); channels `Mag`, `x`, `y`, all `Float64`; 83,466 rows in all; `Mag` from 55990.98 to 58295.42, `x` from 582834.9 to 612106.6, `y` from 6849898.5 to 6873483.0 (within the printed decimals); no missing values; every line date `"2023-03-01"`; the current pair `x, y` with `""` and the warning.

For long_valley, GDR_clmag and wform, test that every line has `fid_start == 0.0` and `fid_step == 1.0`.
These files have plain blobs, so this checks risk 1: the plain-blob fiducial offsets are a research guess, and these values are the Oasis default.

- [ ] **Step 2: Run them.** With the files present, all pass; with `JULIAMAG_GDB_SAMPLES=/nonexistent`, the suite passes and prints one SKIP line per file.
- [ ] **Step 3: Run the bench.** `JULIA_NUM_THREADS=4 ~/.juliaup/bin/julia --project=JuliaMagCore bench/import_gdb.jl`. Run it with `n_lines` 100 and 400. Expected: memory growth under 300 MB at both sizes, and the growth at 400 lines at most 50 MB above the growth at 100 lines. If not, profile, fix, and record the numbers before and after.
- [ ] **Step 4: Record the numbers in `docs/bench.md`** (a "Geosoft database import" section, with the machine and the command).
- [ ] **Step 5: Commit** `git commit -m "Test the gdb import on public files and a large file"`

---

### Task 11: Window test and docs

**Files:**
- Create: `JuliaMagUI/test/window/test_gdb_end_to_end.jl`
- Modify: `JuliaMagUI/test/runtests.jl` (include it after `window/test_map_end_to_end.jl`), `README.md`, `JuliaMagUI/README.md`, `docs/superpowers/plans/2026-10-28-plan-1-followups.md`, `docs/research/geosoft-gdb-format.md` (line 5)

**Interfaces:**
- Consumes: Tasks 8a and 9; the helpers of `test/window/test_map_end_to_end.jl` (`map_e2e_import`, `map_e2e_show`, `map_e2e_wait`), which live in the same test module.

- [ ] **Step 1: Write the window test**

In one window session, at scale 1, light theme, at the window size the map end-to-end test uses, with `app.pick_file` replaced as in that test:
1. A new project from the backstage.
2. Database tab, "More import formats", the menu row `"Geosoft database..."`, the dialog's Import button, using the core's `test/data/gdb/afgrav.gdb`.
3. Wait for the database item. Check that the job ended `JOB_DONE`, that `job_warnings(job)` has an entry naming the custom coordinate system, and that the job card in the Jobs tab shows the count `length(job_warnings(job))`.
4. Show on Map; wait until it is drawn (`map_e2e_wait`).
5. Shot `e2e-gdb-01-map-light.png`; switch to the dark theme with `ui.theme.dark`; wait; shot `e2e-gdb-01-map-dark.png`.
6. Open the Jobs tab and shot `e2e-gdb-02-job-light.png`, so the job card with its warning is seen.

- [ ] **Step 2: Run it headless.** `bin/test-headless.sh`. Expected: all UI tests pass, and the shots are in `JuliaMagUI/test/shots/`.
- [ ] **Step 3: Look at every shot by eye.** Check the line draws over the right extent, the legend and labels are not cut, and the job card text fits. Fix anything that looks off, also when it is not part of this work, and run the step again. When a fix outside this feature is large, add it to the follow-ups file instead.
- [ ] **Step 4: Update the docs.**
  - `README.md`: under the import text, say that `import_file` reads Geosoft databases (`.gdb`), read only, with an example line `job = wait_job(import_file(s, "survey.gdb"))`.
  - `JuliaMagUI/README.md`: add `test/window/test_gdb_end_to_end.jl` to the list of window tests.
  - `docs/research/geosoft-gdb-format.md`:
    - line 5: replace "The spec still lists `.gdb` as a non-goal (section 11); that will change in a later edit." with "Spec section 6.3a now describes the `.gdb` import; section 11 lists only writing `.gdb` as a non-goal."
    - section 4, "Reader rule": keep "use the directory", and replace the fallback sentence with "JuliaMag does not fall back to a chain copy: a live entry that misses its blob fails the import (data) or gives a warning (admin), because the last copy can be stale. S1 falls back."
    - section 10: the example says `WGS 84 / *TM_afghan_adf` is "in afgrav and GDR_clmag". GDR_clmag has that name; afgrav has `WGS 84 / *tm_afghan` and `WGS 84 / *lcc_afghan` (byte scan, 2026-11-04). Say so, and add that the `*` of a custom name comes after the `/ ` of the datum part.
  - Follow-ups file: a new section "Left for later from the gdb import", one plain line each:
    - Group lines and group classes (now skipped with a warning).
    - The line selection byte (every imported line starts selected).
    - The display-list channel order (channels come in slot order).
    - `MAKER` history, `FORMULA` and the activity log, as JuliaMag history.
    - Custom (`*`) coordinate systems built from the IPJ parameters.
    - Projection methods other than geographic, Transverse Mercator, Lambert 2SP and polar stereographic.
    - Datum transform parameters, for a datum with no EPSG code.
    - String array channels (now skipped with a warning).
    - Geosoft grids with LZRW1 blocks: the grid reader refuses them today (`geosoft_grd.jl`), and it can reuse `io/lzrw1.jl`.
    - One Geosoft text helper: `grd_text` falls back to Latin-1, and `gdb_text` to Windows-1252. Use `gdb_text`'s rule for both.
  - Follow-ups file, "Checks on real systems": the Oasis checks of research section 17 (an XYZ export of AirMag; Change Channel Fid on a copy, compressed and uncompressed; the protect flag; deselected lines; a coordinate system set on AirMag; Database Properties).
- [ ] **Step 5: Run the core and UI suites.** Both pass, Aqua and JET clean.
- [ ] **Step 6: Commit** `git commit -m "Test the gdb import in the window and update the docs"`

---

## Rulings made while writing this plan

These are the plan author's calls; each says what it costs if wrong.

- **The spec subsection is numbered 6.3a.** Code comments and earlier plans cite spec 6.4 to 6.7 by number, so renumbering would break them. Cost: an unusual section number.
- **Display order is slot order.** Ruling 4 breaks a sampling tie by display order, and research section 16 puts the display list under "can wait". Slot order is the order the channels were made. It is not always the XYZ export order: afgrav's slots start `xTM yTM longitude latitude`, and its export starts `longitude latitude xTM yTM`. Cost if wrong: a different main sampling on a line where exactly half the channels differ, which no known file has.
- **USHORT, ULONG and 64-bit integers are read now.** Research 16 lists them under "can wait", but ruling 7 decides how to widen them, and the cost is a few table rows with synthetic tests. Cost: no real file tests them.
- **Resampling of integer and text channels.** Integers interpolate and round to the nearest value; text takes the nearer row. Linear interpolation has no meaning for text, and an integer channel must stay an integer. Ties round away from zero, so a value halfway between two integers does not depend on whether the lower one is even. Cost if wrong: one rule changes.
- **A damaged data blob fails the whole import.** It names the line and channel. A partial database with silent holes would be worse, and the user can repair the file in Oasis. A damaged admin object (labels, units, coordinate system) is only a warning, since the data is still right. Cost if wrong: a user with one bad blob must repair the file in Oasis before importing.
- **A directory slot that is not live means "no data".** A live data slot that misses its blob fails the import. A live admin slot that misses its blob only gives a warning (Task 6), like any damaged admin object.
  The chain is not searched for another copy, because the last copy can be stale (AirMag `__552`; long_valley has 624 stale blobs).
  Cost if wrong: a file with one wrong directory entry is refused, where a reader that guessed might have read it.
- **The version words at bytes 8 and 12 are checked.** Ruling 2 says refuse what is not known. All 8 test files (the 7 public files and AirMag) and the research agree on them.
  The pygdb corpus agrees: 49 of 49 files from 1991 to 2024.
  Cost if wrong: a valid file is refused with a clear message, and the check is one line to relax.
- **The importer has a `crs` setting**, used only for the current pair when the file stores no coordinate system for it, or one JuliaMag cannot use (a custom or unknown name). This is how the user sets it at import (spec 6.6), as for XYZ. A coordinate system from the file that JuliaMag can use always wins. Cost if wrong: none for data; the user can change the system later (spec 6.6).
- **Only `afgrav` goes into the repo.** It is U.S. public domain and 631 KB with its XYZ. `long_valley_ed` (7.3 MB) is too large. The Geoscience BC files have no licence statement that allows sharing, so they are optional only. Cost: the full real-file checks run only on machines that have the files.
- **The app needs one table entry**, `"import.geosoft_gdb" => "import"` in `CORE_ICONS`, because `test_icons.jl` checks that every importer has an icon. The menus, command search, dialog and Jobs tab come from the registry with no other app code. Four UI tests list the importers exactly, so they gain the new entry (Task 9). Cost if wrong: a missed test list fails the Task 9 gate, which shows it at once.
- **The inexact warning fires only when a value was rounded.** A 64-bit channel whose values Float64 stores exactly gives no warning, so users are not warned about a loss that did not happen. The owner approved this rule, and spec 6.3a was updated to match on 2026-11-04. Cost: a channel that could hold large values but does not is not flagged.
- **Display settings that JuliaMag does not accept fall back to its defaults, with one warning per file.** Formats `GEOGR`, `SIGDIG` and `HEX`, and bad width or decimals, only change how values are shown, so one line that names the channels is enough. Spec 6.3a asks for a warning for every changed item. Cost: one more warning line on files that use these formats.
- **When the file names no current pair, the first pair found becomes current.** This matches `add_position_pairs!`, which makes the first pair current. In append mode the target's current pair is kept. Cost if wrong: the user picks another current pair in the database.
- **`compare_gdb_xyz` keeps its own XYZ parsing.** `import_xyz` cannot read time and date text, and it drops the printed digit count that the tolerances need. Cost: a second, small parser in test code only.
- **The test-only LZRW1 compressor stays.** Its random round trips test the decoder's copy items on many patterns, beyond the hand-made streams and the two real files. Cost: about 60 lines of test code.
