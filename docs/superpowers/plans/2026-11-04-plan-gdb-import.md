# JuliaMag: Geosoft Database (`.gdb`) Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `JuliaMagCore` imports Oasis montaj databases (`.gdb`), read only, into a new or an existing line database, and the import shows up in the app with no special UI code.

**Architecture:** A `.gdb` is a paged file: a 256-byte header, a blob directory, symbol tables for blobs, lines, channels and users, then a chain of blobs.
The reader opens the file, checks every layout rule it knows, and refuses the file when one fails.
It then walks the lines in slot order and reads the data of one channel on one line (one blob) at a time, through the directory, into the channel appenders of `line_import.jl`.
Memory stays at about one decompressed blob.
The importer registers itself like the XYZ importer, so the UI lists it from the registry.

**Tech Stack:** Julia 1.12, CodecZlib.jl 0.7 (already a dependency, for zlib blobs), Proj.jl 1.9 (EPSG name lookup through `crs_from_name`), an own LZRW1 decoder, plus the existing stack (JSON3, Mmap, Test, Aqua, JET; ImGuiTestEngine for the window test).

**Spec:** `docs/superpowers/specs/2026-10-28-juliamag-foundation-design.md` (sections 5.3, 6.1, 6.2, 6.3a, 6.5, 6.6, 8.4, 11, 12, 13.2).
Research: `docs/research/geosoft-gdb-format.md`.
That file is the requirement for every byte offset in this plan; its tags say how each fact was checked.
Sections 12 (mapping), 15 (open risks) and 16 (first version scope) are the core.
Follow-ups: `docs/superpowers/plans/2026-10-28-plan-1-followups.md`.

## Where this fits

| Plan | Delivers |
|---|---|
| 1. Core | Done |
| 2. Grids | Done |
| 3. UI shell | Done |
| 4a. Map view | Done |
| **`.gdb` import (this plan)** | Read-only Geosoft database importer, its tests on public files, a window test |
| 4b, 4c, 5 | As before |

## Global Constraints

- Julia 1.12 or newer. Run Julia as `~/.juliaup/bin/julia`.
- `JuliaMagCore` must not depend on any UI or graphics package (spec 13.3).
- No new package. zlib goes through `CodecZlib` (already a dependency). LZRW1 is our own code (about 40 lines), because no maintained Julia package decodes it and the algorithm is small and fixed.
- JuliaMag never writes a `.gdb` file (spec 11). Nothing in this plan opens a `.gdb` for writing, except the test writer in `test/support/`.
- A whole `.gdb` is never loaded into memory (spec 6.2). The reader holds the header, the directory, the symbol tables and at most one blob (packed and unpacked) at a time.
- Progress is reported and cancel is checked once per data blob (spec 6.2).
- Bad input never throws out of the importer to the caller as a crash: it becomes a failed job with a plain message, or a warning (spec 6.2, 8.2). A failed or cancelled import leaves no new item, no temp folder, and an append target as it was (the `import_lines` frame does this).
- Every skipped or changed item gives an `ImportWarning` (file line 0) that names the line and the channel.
- All numbers in a `.gdb` are little-endian. Byte offsets in this plan count from 0, as in the research file.
- Line types are mapped by letter, never by integer: Geosoft 0 `L`, 1 `B`, 2 `T`, 3 `S`, 4 `R`, 5 `P`, 6 `D` (research 5.2). JuliaMag's enum has `TIE` before `BASE`.
- Names of new top-level constants start with `GDB_` or `LZRW1_`, so the duplicate-constant scan in `test/support/consts.jl` stays clean.
- Text in messages, comments and docs: plain English, short sentences, never the em dash character.
- Tests first. Lint (Aqua, JET) and all tests pass before each commit. Tests never use the network.
- Window tests run headless only: `bin/test-headless.sh`. Never open a window on the user's desktop.
- Core tests: `~/.juliaup/bin/julia --project=JuliaMagCore -e 'using Pkg; Pkg.test()'`.
  A fast loop for one file while working: `~/.juliaup/bin/julia --project=JuliaMagCore -e 'using Test, JuliaMagCore; include("JuliaMagCore/test/support/synthetic.jl"); include("JuliaMagCore/test/support/gdb_writer.jl"); include("JuliaMagCore/test/test_gdb_<part>.jl")'`. The whole suite is the gate before a commit.
- Commit messages: plain, no co-author lines. Commit on `feature/gdb-import`.
- Only `import_gdb` and `GdbError` are exported. Tests reach the other new names with `using JuliaMagCore: ...` at the top of each test file.

## Rulings from the controller

These were decided before this plan.
The tasks implement them as written.

1. Read-only import into the project's own format, like XYZ. Modes "new database" and "append", as for XYZ.
2. A folder named `*.gdb` gives: "`<name>` is an ArcGIS file geodatabase (a folder), not a Geosoft database. JuliaMag reads only Geosoft `.gdb` files." A file that fails a layout check is refused with a clear message, never guessed.
3. Scope is research section 16 "First version, must read". "Can wait" items go to the follow-ups file (Task 11).
4. A channel whose fiducial start or step differs from the line's main sampling is resampled by linear interpolation onto the main sampling, with a warning naming the line and channels. The main sampling is the one most channels of the line share; on a tie, the sampling of the first channel in display order. Missing values are not interpolated across. Same sampling but fewer rows: padded with missing values, with a warning.
5. A line number that is not a number gets the next free number of its type; the warning keeps the original name.
6. Group lines are skipped with a warning.
7. Integer types JuliaMag lacks are widened to the smallest JuliaMag type that holds every value; when none does, Float64 with a warning. Geosoft dummies become JuliaMag missing values; a real value equal to JuliaMag's missing marker gives a warning.
8. Coordinate system: name to EPSG lookup; unknown or custom gives an empty CRS and a warning, and the user sets it (spec 6.6).
9. Streaming blob by blob through the directory, with progress and cancel per blob.
10. Tests: small public-domain files in the repo; larger files and `AirMag.gdb` in an optional set that prints a visible skip line when the files are missing; every file with an XYZ export is compared value by value; synthetic files for edge cases; one headless window test with a light and a dark screenshot.

## Review Focus

These inputs are not named by the spec but will reach real users first.
Each has a test in the task that owns the code.

1. **A file from another Oasis version or source:** bytes 4 to 7 set to `f0 f0 f0 f0` import normally; header words at bytes 8 and 12 with other values, or broken table arithmetic, give a failed job that says the layout is unknown, with no item left (Task 1).
2. **A processed database:** a lag-corrected channel with a shifted fiducial start, a channel with another step, and a channel cut short all line up on the line's main sampling, with one warning per line that names them (Task 8, Task 9).
3. **A damaged file:** a file cut short (a broken download), a zlib or LZRW1 blob with a changed byte, or a directory entry that points at the wrong page give a failed job naming the line and channel, no temp folder, and an append target as it was; a directory entry that misses but has a copy in the chain is read from the chain with a warning (Tasks 2, 4, 9).
4. **Names Windows cannot use and repeated names:** channels named `a/b`, `CON`, `x` and `X` get safe, unique names; the label keeps the original name (Task 7).
5. **Append onto a database made from the XYZ export of the same survey:** a channel whose type differs (XYZ gives Float64, the `.gdb` has Int32) fails with a message naming the channel, and the target is unchanged; matching channels append and lines that exist get a new version (Task 9).

---

## File structure

```
JuliaMag/
  JuliaMagCore/
    src/
      JuliaMagCore.jl                 # + includes after csv_templates.jl, + exports
      io/gdb_format.jl                # GdbError, gdb_kind, header and layout checks, directory, symbol tables
      io/lzrw1.jl                     # lzrw1_decode!
      io/gdb_blobs.jl                 # blob headers, plain / zlib / LZRW1 blobs, chain fallback
      io/gdb_values.jl                # GS_* types, dummies, widening, strings
      io/gdb_admin.jl                 # registry (REG) and coordinate system (IPJ) objects
      io/gdb_lines.jl                 # line ids, dates, channel plans, roles, position pairs
      io/gdb_sampling.jl              # main sampling of a line, resampling
      io/gdb_import.jl                # import_gdb, settings, registration
    test/
      support/gdb_writer.jl           # write_test_gdb, lzrw1_compress (tests and bench only)
      support/gdb_xyz.jl              # compare_gdb_xyz: a database against an Oasis XYZ export
      data/gdb/                       # afgrav.gdb, afgrav.XYZ, LICENSE.md
      test_gdb_format.jl  test_lzrw1.jl  test_gdb_blobs.jl  test_gdb_values.jl
      test_gdb_admin.jl  test_gdb_lines.jl  test_gdb_sampling.jl  test_gdb_import.jl
      test_gdb_real_files.jl          # optional set, skipped with a printed line when files are missing
  JuliaMagUI/
    src/theme/icons.jl                # + "import.geosoft_gdb" => "import" (test_icons requires it)
    test/window/test_gdb_end_to_end.jl
  bench/import_gdb.jl
  docs/bench.md  README.md  JuliaMagUI/README.md
  docs/superpowers/plans/2026-10-28-plan-1-followups.md
```

---

### Task 1: Format check, header and layout checks

Research sections 1, 2, 3 and 5 (table starts).

**Files:**
- Create: `src/io/gdb_format.jl`, `test/test_gdb_format.jl`, `test/support/gdb_writer.jl`, `test/data/gdb/` (`afgrav.gdb`, `afgrav.XYZ`, `LICENSE.md`)
- Modify: `src/JuliaMagCore.jl` (include after `io/csv_templates.jl`), `test/runtests.jl` (include `support/gdb_writer.jl` after `support/synthetic.jl`, and each new test file after `test_csv.jl`)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `struct GdbError <: Exception; msg::String; end`, with `showerror` printing the message only.
  - `gdb_kind(path)::Symbol`: `:esri_folder` for a directory; `:geosoft` for a regular file that starts with `!CBD`; `:unknown` otherwise (also for a missing or short file).
  - `gdb_refusal(path)::Union{Nothing,String}`: `nothing` for `:geosoft`; for `:esri_folder` the ruling 2 text; for a missing file `"no file at <path>"`; for `:unknown` `"<file> is not a Geosoft database: it starts with <first 4 bytes as hex, or "fewer than 4 bytes">, not !CBD."`.
  - `struct GdbHeader` with `Int` fields `chans_max, blobs_max, cache, lines_max, users_max, dir_slots, first_admin, page_size, index_size, blob_start_page, n_pages, comp_level, line_handle0, chan_handle0, user_handle0` and the table starts `blob_table, line_table, chan_table, user_table` (byte offsets).
  - `read_gdb_header(io::IO, file_size::Integer)::GdbHeader`. It throws `GdbError` with `"the file is damaged or uses a Geosoft database layout JuliaMag does not know (<check>). It was not imported."` when any check fails. `<check>` names the rule in plain words. The checks, with word `wN` = int32 at byte N:
    - magic `!CBD`; file at least 256 bytes;
    - `w8 == 0x10020000` and `w12 == 264` (the version words);
    - every capacity (`w24, w28, w36, w40`) above 0, `w32 >= 0`, `page_size = w100 > 0`;
    - `w44 == w60 + w32`, `w48 == w36 * w24`, `w52 == w48 + w28`, `w56 == w60 == w52 + w40`, `w64 == w28 + w36 + w24 + w40`;
    - `w72 == w28`, `w76 == w72 + w36`, `w80 == w76 + w24`; `w84..w96` repeat `w28, w36, w24, w40`;
    - `chan_table = w104 - (w24 + w40) * 128`, `line_table = chan_table - w36 * 128`, `blob_table = 280 + w44 * 6`, and `blob_table + w28 * 128 == line_table`; `user_table = chan_table + w24 * 128`;
    - `w108 * page_size >= w104`, and `(w108 + w112) * page_size == file_size`;
    - `w120` in `0:2`.
    Bytes 4 to 7 are not checked (13 of 45 files in the pygdb corpus have `f0 f0 f0 f0`).
  - `open_gdb(path)::GdbFile` and `close(g::GdbFile)`: `mutable struct GdbFile; path::String; io::IOStream; size::Int; header::GdbHeader; dir::Vector{GdbSlot}; chain::Union{Nothing,Dict{Int,Int}}; end`. In this task `dir` is empty and `chain` is `nothing`; Task 2 fills `dir`. `open_gdb` throws `GdbError(gdb_refusal(path))` for anything but `:geosoft`, and closes the stream when the header check throws.
  - `with_gdb(f, path)`: opens, calls `f(g)`, closes, also on error.
- Test helper `xyz_column_names(path)::Vector{String}` in `test/support/gdb_writer.jl`: the names of the last `/` line of an Oasis XYZ export whose count equals the columns of the first data row.
- Test writer (`test/support/gdb_writer.jl`), grown by later tasks:
  - `Base.@kwdef struct TestChannel; name::String; type::Int = 5; arraylen::Int = 1; format::Int = 0; width::Int = 10; decimals::Int = 2; flags::Int = 2; deleted::Bool = false; end`
  - `Base.@kwdef struct TestLine; name::String; number::Int = 0; type::Int = 0; version::Int = 0; flight::Int = 0; date::Float64 = 0.0; category::Int = 100; end`
  - `Base.@kwdef struct TestBlob; values::AbstractVector; fid_start::Float64 = 0.0; fid_step::Float64 = 1.0; pack::Symbol = :none; end` with `pack` in `:none`, `:zlib`, `:lzrw1` (Task 3 adds the compressor), `:lzrw1_stored`.
  - `write_test_gdb(path; channels, lines, blob = (line_slot, chan_slot) -> nothing, chans_max = max(4, length(channels)), lines_max = max(4, length(lines)), blobs_max = 16, users_max = 2, cache = 8, page_size = 1024, comp_level = 0, admin = Pair{String,Vector{UInt8}}[], tweak = h -> h)`.
    It writes the header, directory, symbol tables (user 0 named `SUPER`), then each blob, page aligned, in the layout of research sections 3 to 6.
    `blob` returns a `TestBlob` or `nothing` (no directory entry). The writer streams: it writes the blobs first after a placeholder index area, then seeks back to write the directory and tables, so a bench can write a file of 1 GB.
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
  - `struct GdbSlot; live::Bool; page::Int; pages::Int; end`; `open_gdb` reads all `dir_slots` slots (6 bytes each from byte 280): `live` = bit 31 of the uint32, `page = word & 0x3FFFFFFF`, `pages` = the uint16.
  - `blob_offset(g, index)::Union{Nothing,Int}`: the byte offset of the current copy of blob `index` (0-based):
    - slot not live: `nothing` (no data);
    - live, and the bytes at `(blob_start_page + page) * page_size` start with `cc cc 00 ff`, with the int32 at +4 equal to `pages` and the int32 at +12 equal to `index`: that offset;
    - live but not landing on such a blob: the last copy of `index` in chain order from `gdb_chain(g)`, and the caller gets a warning (return a second value: `blob_offset(g, index)::Tuple{Union{Nothing,Int},Bool}`, where the `Bool` says "taken from the chain"); when the chain has no copy either, `nothing` with the flag set.
  - `gdb_chain(g)::Dict{Int,Int}`: built once and kept in `g.chain`. Walks from `blob_start_page * page_size`; each blob must start with `cc cc 00 ff` and have a page count above 0; the walk must land exactly on the end of the file. Else `GdbError("the blob chain is broken at byte <n>")`. Later copies of an index replace earlier ones.
  - `struct GdbChannelRecord; slot::Int; name::String; type::Int; flags::Int; format::Int; width::Int; decimals::Int; arraylen::Int; end`
  - `read_gdb_channels(g)::Vector{GdbChannelRecord}`: the live records in slot order. Record offsets per research 5.1 (name at +0, 64 bytes NUL-terminated; type int16 at +76; flags int16 at +78; format int16 at +84; width int16 at +86; decimals int32 at +88; array width int16 at +110). A record is live only when the name is non-empty and every character is printable, bit 0 of the flags is clear, the type is in `0:9` or below 0, and `arraylen >= 1`.
  - `struct GdbLineRecord; slot::Int; name::String; category::Int; date::Float64; number::Int; type::Int; flight::Int; version::Int; end`
  - `read_gdb_lines(g)::Vector{GdbLineRecord}`: records with category 100 or 200 (bit `0x10000` clear), in slot order. Offsets per research 5.2 (category int32 +76, date float64 +84, number int32 +92, type int32 +96, flight int32 +100, version int32 +124).
  - `read_gdb_blob_symbols(g)::Vector{Tuple{Int,String}}`: `(k, name)` of live blob symbols (category int32 +76 equal to 0, name non-empty); symbol `k` owns admin blob `first_admin + k`.
  - Names are decoded with `gdb_text(bytes)::String` (up to the first NUL; UTF-8 when valid, else Windows-1252; Task 5 reuses it for string channels).
- Writer: `TestChannel(deleted = true)` sets bit 0 of the flags; `garbage_channels::Int = 0` fills that many slots after the real ones with random bytes and bit 0 set (as `7042_106_wform`); `stale::Vector{Int} = Int[]` writes a second, later copy of those blob indexes with other values that the directory does not point at (as AirMag `__552`); `dead::Vector{Int} = Int[]` writes those blobs but leaves their slots not live; `misdirect::Vector{Int} = Int[]` points those live slots one page off.

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
- `misdirect = [i]`: `blob_offset` gives the chain copy with the flag set;
- `dead = [i]`: `blob_offset` gives `nothing` without the flag;
- a blob whose page count field is 0 makes `gdb_chain` throw "the blob chain is broken at byte";
- a channel name in Windows-1252 (`"Mag°"` as byte `0xB0`) reads as `"Mag°"`.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** Read each table with one `read` of `n * 128` bytes; these are small (fortymile: 2000 lines, 100 channels).
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Read the directory and symbol tables of Geosoft databases"`

---

### Task 3: LZRW1 decoder

Research section 6.3 (LZRW1 chunks) and source S6.

**Files:**
- Create: `src/io/lzrw1.jl`, `test/test_lzrw1.jl`
- Modify: `test/support/gdb_writer.jl` (`lzrw1_compress`), `src/JuliaMagCore.jl`

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
- Modify: `test/support/gdb_writer.jl` (`:lzrw1` packing with chunks of at most 16,368 bytes, `:lzrw1_stored` chunks), `src/JuliaMagCore.jl`

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces:
  - `struct GdbBlobHeader; index::Int; class::Int; pages::Int; packing::Symbol; fid_start::Float64; fid_step::Float64; count::Int; type::Int; raw_bytes::Int; packed_bytes::Int; payload::Int; end`. `packing` is `:none`, `:zlib` or `:lzrw1`. `payload` is the byte offset of the values (plain) or of the stream (packed).
  - `read_blob_header(g, offset)::GdbBlobHeader`:
    - The chunk magic `0f 0e ff fe 12 34 56 78` at +56 means packed: the 56-byte header (+24 raw bytes, +28 sixteen plus the packed length, +32 fid start, +40 fid step, +48 count, +52 type), subtype int32 at +64 (2 zlib, 1 LZRW1), payload at +72.
    - Else plain: the 48-byte header (+24 fid start, +32 fid step, +40 count, +44 type), payload at +48. The plain fid offsets are a research guess; Task 10 checks them on the plain real files.
    - Class 202 must go with the magic and 200 without it. A mismatch, another class, a subtype other than 1 or 2, a negative count, or a payload that runs past the blob's pages throws `GdbError("blob <index> ...")` with the reason.
    - A step that is not finite or not above 0 throws `GdbError("blob <index> has a fiducial step of <x>")`.
  - `read_blob_bytes!(buf::Vector{UInt8}, scratch::Vector{UInt8}, g, h::GdbBlobHeader, elsize::Int)::Vector{UInt8}`: fills `buf` (resized) with the `h.count * elsize` value bytes and returns it. `scratch` holds the packed bytes. Both are reused across blobs, so memory stays at one blob.
    - plain: reads the bytes;
    - zlib: inflates `packed_bytes - 16` bytes with `transcode(ZlibDecompressor, ...)` into `buf`; a `ZlibError` becomes `GdbError("blob <index> is damaged: its zlib data cannot be inflated")`;
    - LZRW1: walks the chunks from the payload. Each chunk has a 12-byte header: int32 raw length, int32 chunk length (with the 12 bytes), uint32 marker. Marker `0xF4E5D6C7` decodes with `lzrw1_decode!`; `0xF0E1D2C3` copies the bytes as they are; any other marker throws. It stops when the raw lengths add up to `raw_bytes`.
    - Every path checks `raw_bytes == h.count * elsize` first and that the output is exactly `raw_bytes`; else `GdbError("blob <index> unpacks to <n> of <m> bytes")`.

- [ ] **Step 1: Write the failing tests**

On synthetic files with one Float64 channel of 5,000 values (a ramp with a few `-1e32`), written once with each packing (`:none`, `:zlib`, `:lzrw1`, `:lzrw1_stored`), and a 40,000-value Float64 LZRW1 blob (20 chunks):

```julia
h = read_blob_header(g, first(blob_offset(g, 0)))
@test h.packing == pack_of[p] && h.count == 5000 && h.fid_start == 12.5 && h.fid_step == 0.1
@test reinterpret(Float64, read_blob_bytes!(UInt8[], UInt8[], g, h, 8)) == values
```

Also: the first live data blob of afgrav is LZRW1 and unpacks to the size its header says; a zlib blob with one payload byte changed throws "cannot be inflated"; an LZRW1 blob with a bad chunk marker throws "marker"; a blob whose class says 200 but holds the magic throws; a file cut inside the last blob fails at `open_gdb` (Task 1 check), and a blob whose count is larger than its pages hold throws "runs past".

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Read plain, zlib and LZRW1 blobs of Geosoft databases"`

---

### Task 5: Value types, dummies and widening

Research section 7.

**Files:**
- Create: `src/io/gdb_values.jl`, `test/test_gdb_values.jl`
- Modify: `src/JuliaMagCore.jl`

**Interfaces:**
- Consumes: Task 4.
- Produces:
  - `struct GdbType; code::Int; size::Int; T::DataType; widened::Bool; lossy::Bool; end` and `gdb_type(code)::GdbType`, throwing `GdbError` for a code outside `0:9` and not below 0. The table (ruling 7):

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

  - `mutable struct GdbValueNotes; clashes::Int; inexact::Int; end`: `clashes` counts real values equal to JuliaMag's missing marker (Int8 -128, Int16 -32768, Int32 `typemin`); they stay as stored and so read as missing. `inexact` counts 64-bit values above 2^53 in size.
  - `gdb_values!(out::Vector{T}, bytes::Vector{UInt8}, t::GdbType, notes::GdbValueNotes)::Vector{T}`: decodes and maps dummies to `missing_value(T)`. Numeric types loop in a function with concrete argument types (function barrier).
  - For strings, `out::Vector{String}` and each value is `gdb_text` of its fixed-width, NUL-padded bytes.
  - `gdb_type_warning(t, channel)::Union{Nothing,String}`: for a lossy type, `"channel <c> holds 64-bit integers; JuliaMag keeps them as Float64, so values above 2^53 lose precision"`.

- [ ] **Step 1: Write the failing tests**

```julia
n = GdbValueNotes(0, 0)
@test gdb_values!(Int16[], bytes_of(Int16[-32767, 5, -32768]), gdb_type(2), n) == Int16[-32768, 5, -32768]
@test n.clashes == 1
@test isequal(gdb_values!(Float32[], bytes_of(Float32[-1f32, 2.5f0]), gdb_type(4), n), Float32[NaN, 2.5])
@test gdb_values!(Int32[], bytes_of(UInt16[65535, 65534]), gdb_type(1), n) == Int32[typemin(Int32), 65534]
@test gdb_values!(String[], Vector{UInt8}("2007/10/04\0ab\0\0\0\0\0\0\0\0\0"), gdb_type(-11), n) == ["2007/10/04", "ab"]
```

Also: every row of the table above, with its dummy and one real value; `ULONG 4294967294` stays exact; `LONG64 2^60 + 1` counts as inexact and `gdb_type_warning` names the channel; UBYTE 255 is missing with no clash; code 10 throws; a string with byte `0xB0` reads as `°`.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** `bytes_of` is a test helper that `reinterpret`s to `UInt8`.
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Map Geosoft value types and dummies to JuliaMag"`

---

### Task 6: Registry and coordinate system objects

Research sections 5.3, 9 and 10.

**Files:**
- Create: `src/io/gdb_admin.jl`, `test/test_gdb_admin.jl`
- Modify: `test/support/gdb_writer.jl` (`test_registry(pairs)` and `test_ipj(; name, method, datum, units)` build framed object bytes), `src/JuliaMagCore.jl`

**Interfaces:**
- Consumes: Tasks 2, 4.
- Produces:
  - `read_gdb_object(g, offset)::Union{Nothing,Tuple{String,Vector{UInt8}}}`: the class name (`"REG"`, `"IPJ"`, `"EXT"`) and the object's bytes from the blob start to `+28 + payload length`. `nothing` when the frame `ff 00 f0 0f` is not at +28 or the length runs past the blob.
  - `gdb_registry(bytes)::Dict{String,String}`: `n` at +124, then `n` slots of 256 bytes, each `KEY\0value\0`. Throws `GdbError` when `n` is negative or the slots run past the bytes.
  - `struct GdbIpj; name::String; method::Int; datum::String; units::String; end`; `gdb_ipj(bytes)::GdbIpj` reads name at +104 (64 bytes), method int32 at +168, datum at +180, units at +452.
  - `struct GdbMeta; dbreg::Dict{String,String}; channel_reg::Dict{Int,Dict{String,String}}; ipj::Vector{Tuple{String,String,GdbIpj}}; end` (channel registries by channel slot; `ipj` entries are `(x name, y name, ipj)` from symbols named `?|IPJ_<X>:<Y>`).
  - `read_gdb_meta(g, symbols)::Tuple{GdbMeta,Vector{String}}`: reads `__dbreg`, `__<n>` with `chan_handle0 <= n < user_handle0` (channel slot `n - chan_handle0`), and every IPJ object. A missing or damaged admin object is a warning (`"the <name> object of the file is damaged; it was skipped"`), never a failed import: it holds metadata, not data. Line registries and other objects are not read.
  - `gdb_crs(ipj::GdbIpj)::Tuple{String,Union{Nothing,String}}`: `("EPSG:n", nothing)` when `crs_from_name(ipj.name)` finds one; else `("", warning)`. A name starting with `*` gives `"the coordinate system <name> is a Geosoft custom system with no EPSG code. Set the coordinate system of <x>, <y> in the database."`; another unknown name gives `"JuliaMag does not know the coordinate system <name>. ..."` with the same last sentence. The caller fills `<x>, <y>`.

- [ ] **Step 1: Write the failing tests**

```julia
with_gdb(testdata("gdb/afgrav.gdb")) do g
    meta, warns = read_gdb_meta(g, read_gdb_blob_symbols(g))
    @test isempty(warns)
    @test haskey(meta.dbreg, "DB_CHAN_X") && haskey(meta.dbreg, "DB_CHAN_Y")
    @test any(startswith(i[3].name, "WGS 84 / *TM") for i in meta.ipj)    # research 10: custom TM
end
@test gdb_crs(GdbIpj("NAD27 / UTM zone 7N", 11, "NAD27", "m"))[1] == "EPSG:26707"
@test gdb_crs(GdbIpj("NAD83 / UTM zone 10N", 11, "NAD83", "m"))[1] == "EPSG:26910"
@test gdb_crs(GdbIpj("WGS 84", 1, "WGS 84", "dega"))[1] == "EPSG:4326"
c, w = gdb_crs(GdbIpj("WGS 84 / *TM_afghan_adf", 11, "WGS 84", "m"))
@test c == "" && occursin("custom", w)
```

Write afgrav's `DB_CHAN_X`, `DB_CHAN_Y` values and each IPJ pair name into the test once you have read them, with a comment that they come from the file (check them against research section 10: a Lambert system and a custom TM system).
Also, on synthetic files: a registry with `LABEL` and `UNITS` for channel slot 1 reads back by slot; a registry whose frame is broken gives one warning and an empty registry; an IPJ symbol whose channels are not live is still returned here (Task 7 drops it); a registry with `n = -1` gives a warning.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Read registries and coordinate systems of Geosoft databases"`

---

### Task 7: Lines and channels

Research section 12, rulings 5, 6 and 8.

**Files:**
- Create: `src/io/gdb_lines.jl`, `test/test_gdb_lines.jl`
- Modify: `src/JuliaMagCore.jl`

**Interfaces:**
- Consumes: Tasks 2, 5, 6; `line_import.jl` (`free_line_id`, `channel_name`, `position_roles`, `WarningLog`, `warn!`).
- Produces:
  - `gdb_line_type(code)::Union{Nothing,LineType}`: by letter, `0 => 'L', 1 => 'B', 2 => 'T', 3 => 'S', 4 => 'R', 5 => 'P', 6 => 'D'`; another code gives `nothing`.
  - `gdb_date(x::Float64)::String`: `""` for 0, not finite, or `<= -1e31`; else `yyyy-mm-dd` with `year = floor(x)` and day of year `round((x - year) * days_in_year) + 1`.
  - `struct GdbLinePlan; slot::Int; id::LineId; flight::Int; date::String; name::String; end` (`name` is the name in the file).
  - `plan_gdb_lines(records, db::LineDatabase, log::WarningLog)::Vector{GdbLinePlan}`, in slot order:
    - category 200: skipped, `"group line <name> was skipped; JuliaMag has no group lines"`;
    - an unknown type code: skipped with a warning naming the line and the code;
    - number field equal to the int32 dummy -2147483647 (alphanumeric name): the next free number of its type, which is one above the highest number of that type among `db.lines` and all numeric lines of the file, counting up for each such line; warning `"line <name> has a name that is not a number; it was imported as <new name>"`;
    - the version from the record; a taken id gets the next version through `free_line_id` at import time (Task 9), as XYZ does.
  - `struct GdbChannelPlan; slot::Int; name::String; label::String; units::String; gtype::GdbType; arraylen::Int; format::Symbol; width::Int; decimals::Int; role::ChannelRole; end`
  - `plan_gdb_channels(records, meta, crs::String, log)::Tuple{Vector{GdbChannelPlan},Vector{PositionPair},Int}`: the plans in slot order, the position pairs and the index of the current pair (0 when none):
    - names through `channel_name` (safe and unique); `label` = registry `LABEL`, else the name in the file; `units` = registry `UNITS`, else `""`;
    - format: 0 `:normal`, 1 `:exponential`, 2 `:time`, 3 `:date`, other `:normal`; width and decimals from the record;
    - a string channel with `arraylen > 1`: skipped, `"channel <c> is an array of text values; JuliaMag cannot store it, so it was skipped"`;
    - a lossy type: the warning from `gdb_type_warning`;
    - roles and pairs: the current pair is `DB_CHAN_X`, `DB_CHAN_Y` of `__dbreg` when both are live channels; else the first X and Y by name (`position_roles`, as XYZ). `DB_CHAN_Z` gets `ROLE_Z`. Each IPJ entry whose two channel names are live channels becomes a pair, once. A pair whose IPJ method is 1 or whose units are `dega` gets `ROLE_LON`, `ROLE_LAT`; others `ROLE_X`, `ROLE_Y` (only the first pair of each kind gets roles, as `position_roles` does). The pair's CRS comes from `gdb_crs`; when that is empty and `crs` is not, the current pair takes `crs`. A pair left with an empty CRS gives the `gdb_crs` warning, or `"the file stores no coordinate system for <x>, <y>. Set it in the database."` when it had no IPJ.
    - pairs name the JuliaMag channel names (after `channel_name`), not the file names.

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
- a string array channel is skipped with its warning.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Map Geosoft lines and channels onto JuliaMag"`

---

### Task 8: Main sampling and resampling

Research section 8 and 15 (risk 2), ruling 4.

**Files:**
- Create: `src/io/gdb_sampling.jl`, `test/test_gdb_sampling.jl`
- Modify: `src/JuliaMagCore.jl`

**Interfaces:**
- Consumes: nothing from the `.gdb` tasks; plain values only.
- Produces:
  - `struct Sampling; start::Float64; step::Float64; end`, and `same_sampling(a, b)::Bool`: steps equal within `1e-9` relative, and starts equal within `1e-6 * step`.
  - `main_sampling(list::Vector{Sampling})::Sampling`: the sampling the most entries share (by `same_sampling`); on a tie, the one that comes first in `list`. `list` is in display order (slot order, see "Rulings made while writing this plan").
  - `resample!(out::AbstractVector{T}, src::AbstractVector{T}, from::Sampling, to::Sampling, rows::Int, width::Int)`: fills `out` (length `rows * width`) with `src` (length `n * width`) resampled from `from` onto `to`. For output row `r`, the source position is `x = (to.start + (r - 1) * to.step - from.start) / from.step` (0-based).
    - `x` within `1e-6` of a whole number `k` in `0:n-1`: the value of row `k + 1`, also when it is missing;
    - else, with `k = floor(x)` and both rows `k + 1`, `k + 2` in range and not missing: linear interpolation (`Float32`, `Float64`); integer types interpolate in `Float64` and round to the nearest value (`round(T, v)`, clamped to the type's range without its missing marker); strings take the nearer row;
    - else (outside the source, or a missing neighbour): missing.
    Each of the `width` values of a row is done on its own.
  - The function loops in a function with concrete argument types (function barrier).

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

Also: `Int32` values `[0, 3]` from step 2 onto step 1 give `[0, 2, 3]` (1.5 rounds to 2); an `Int16` neighbour at the missing marker gives missing; a 2-wide array resamples each column; strings take the nearer row; an exact hit on a missing row stays missing; `same_sampling(Sampling(33727.0, 1.0), Sampling(33727.0 + 1e-9, 1.0))` is true.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see it pass.**
- [ ] **Step 5: Commit** `git commit -m "Find a line's main sampling and resample channels onto it"`

---

### Task 9: The importer

Spec 6.2, 6.3a, 6.5; research section 12 (last paragraph).

**Files:**
- Create: `src/io/gdb_import.jl`, `test/test_gdb_import.jl`, `test/support/gdb_xyz.jl`
- Modify: `src/JuliaMagCore.jl` (export `import_gdb`, `GdbError`), `test/runtests.jl` (include `support/gdb_xyz.jl`), `JuliaMagUI/src/theme/icons.jl` (`"import.geosoft_gdb" => "import"`)

**Interfaces:**
- Consumes: Tasks 1 to 8; `import_lines`, `start_line!`, `import_channel!`, `add_pair!`, `open_appenders`, `append_value!`, `close_appenders!`, `check_import_args`, `spec_values`, `record!`.
- Produces:
  - `import_gdb(s, path; name = <file name without extension>, crs = "", mode = :new, target = "", progress = NO_PROGRESS, record = true)::ImportResult`, recorded as `"import.geosoft_gdb"` with the same arguments as `import_xyz`.
    1. `gdb_refusal(path)` first (before `check_import_args`, which wants a file): a refusal throws `GdbError` with its text.
    2. Open the file and read the header, tables and metadata before `import_lines`, so a refused file makes no temp folder.
    3. Inside `import_lines(...) do db`: add the channels with `import_channel!` (the JuliaMag type of each `GdbType`, `arraylen`, `"Geosoft database"`), then set label, units, format, width and decimals of each new channel from its plan; add the pairs with `add_pair!` and set `db.current_pair`. In append mode an existing channel keeps its own label and properties.
    4. Open the appenders once. For each planned line: read the headers of its channel blobs (`blob_offset` on `line_slot * chans_max + chan_slot`); skip the line with `"line <name> has no data; skipped"` when it has no blob; else find the main sampling and the line's rows (the most rows among channels with the main sampling); `start_line!`, then set `nrows`, `fid_start` and `fid_step`.
    5. Then for each channel, one blob at a time: check `is_cancelled` (throw `ImportCancelled`), unpack, check the blob's type equals the channel's and that its count is a multiple of `arraylen`, decode with `gdb_values!`, resample when its sampling differs, and append. Report progress as blobs done over all data blobs.
    6. Warnings per line, each naming the line: one for the channels resampled (`"line L10: channels A, B have another fiducial start or step than the line (start s, step d); they were resampled onto it"`), one for the channels padded (`"line L10: channels C has fewer rows than the line; the rest are missing"`), one for channels with no data on the line, one for blobs read from the chain copy. Per channel over the whole file: one warning for value clashes (`"channel <c>: <n> values equal JuliaMag's missing marker and read as missing"`) and one for inexact values.
    7. Any `GdbError` from a blob is thrown again as `GdbError("line <L>, channel <c>: <message>")`, so the job fails with a message naming both.
    8. Close the file in a `finally`.
  - `GDB_SETTINGS`: the four XYZ settings (`mode`, `name`, `target`, `crs`), with `crs` help `"Used for the current X and Y channels when the file stores no coordinate system for them, such as EPSG:7855."`.
  - `run_gdb_importer(s, path, settings, progress)` and `register_importer!(ImporterSpec("import.geosoft_gdb", "Geosoft database", [".gdb"], ITEM_DATABASE, GDB_SETTINGS, run_gdb_importer))`.
- Test support `compare_gdb_xyz(db, xyz; rename = Dict{String,String}(), skip_all_missing_rows = false)::Tuple{Int,Vector{String}}`: streams an Oasis XYZ export with `eachfileline`, takes the column names with `xyz_column_names`, matches them to channels by name and then by label (case is ignored), matches the k-th line block (`Line`, `Tie`, ... headers; one block when there are none) to `db.lines[k]` and each row to the next row of that line, and compares each value with the database. `*` must be missing. A number with `d` digits after the point must match within `0.5 * 10.0^-d` (for an exponent form, of its mantissa); `hh:mm:ss.ss` is read as decimal hours and `yyyy/mm/dd` as a decimal year (research 7). It returns the count of values checked and the first 20 mismatches as text. `skip_all_missing_rows` drops database rows that are missing in every compared channel (`GDR_clmag`).

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
- an alphanumeric line and a group line give their Task 7 warnings in the job report;
- a zlib blob with a changed byte: `JOB_FAILED`, the error names the line and channel, no `databases/.importing-*` folder (Review Focus 3);
- a `misdirect` slot with a chain copy imports with a warning;
- cancel after the first blob (a `Progress` whose `cancelled` turns true after the first `done`): `JOB_CANCELLED`, no item, no temp folder;
- append (Review Focus 5): import a synthetic file, then append the same file to it; the lines come back as version 1, rows double; append to a database whose `FltNo` is Float64 when the file has Int32: `JOB_FAILED` naming `FltNo`, and `database.json` of the target is byte for byte as before;
- undo of the import job takes the item out; redo puts it back;
- an Esri folder through `import_file`: `JOB_FAILED` with "ArcGIS file geodatabase", no item;
- the importer is in `importers()` and `importer_for("x.GDB")` finds it.

- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** Keep one `GdbValueNotes` per channel. Use typed buffers per JuliaMag type, made once per import, so the inner loops have concrete types.
- [ ] **Step 4: Run to see it pass.** Run the UI logic tests too (`test_icons.jl` and `test_commands.jl` read the registry): `bin/test-headless.sh`.
- [ ] **Step 5: Commit** `git commit -m "Import Geosoft databases"`

---

### Task 10: Real files and a large file

Research sections 13 and 14.

**Files:**
- Create: `test/test_gdb_real_files.jl`, `bench/import_gdb.jl`
- Modify: `test/runtests.jl`, `docs/bench.md`

**Interfaces:**
- Consumes: Task 9.
- Produces:
  - The optional set reads files from `GDB_SAMPLES = get(ENV, "JULIAMAG_GDB_SAMPLES", "/home/ems/data/juliamag-samples/gdb")` and AirMag from `ENV["JULIAMAG_AIRMAG_GDB"]` (a path to `AirMag.gdb`; Geosoft's tutorial file, not ours to share).
  - For each file that is missing, the test prints one line, `"SKIP gdb real file: <relative path> not found (set JULIAMAG_GDB_SAMPLES)"` or `"SKIP AirMag.gdb: set JULIAMAG_AIRMAG_GDB"`, with `println` (the suite must print no warnings), and runs no test for it.
  - `bench/import_gdb.jl [n_lines]`: writes a synthetic zlib `.gdb` of about 1 GB with the test writer (default 400 lines, 10 Float64 channels, 30,000 rows), imports it with `import_file` and `wait_job`, and prints seconds, MB/s and the memory growth (`Sys.maxrss()` before and after), like `bench/import_grid.jl`. With `JULIAMAG_GDB_SAMPLES` set it also times `fortymile_linedata.gdb`.

- [ ] **Step 1: Write the tests**

Each file is imported with `import_file`; checks from research sections 13 and 14:
- `usgs-ofr2004-1096-long-valley/long_valley_ed.gdb` (plain blobs): `compare_gdb_xyz` checks 191,580 values with no mismatch; 15 channels; 30 lines; the line `L28_29` warning; `TIME` and `DATE` channels have formats `:time` and `:date`; 11,316 missing values in all.
- `usgs-ofr2006-1204-gdr-clmag/GDR_clmag.gdb` (plain): 5,119,025 values with `skip_all_missing_rows = true`; channel `resmag` has label `mag`; 1 line of 1,023,807 rows.
- `dggs-gpr2015-004-fortymile/fortymile_linedata.gdb` (LZRW1, multi-chunk): 57,057,723 values with `rename = Dict("BIRDHITE" => "BIRDHIT")`; 288 lines; the current pair has `EPSG:26707`; memory growth of the import under 300 MB.
- `geosciencebc-quest-7042/7042_106_wform.gdb` (plain, `GS_FLOAT`): 10,000 values; the channel `fiducial` is `Float32`; flight 106.
- `geosciencebc-quest-7042/7042-MtMill.gdb` (zlib, arrays, `GS_LONG`, strings, non-zero fiducial starts; no XYZ): channels `Sf` and `Bf` have `arraylen == 40`; `FltNo` is `Int32` and equals the line's flight on every row that is not missing; `Date` is `String` and equals the line date written as `yyyy/mm/dd`; every line's `fid_start` is above 0 and `fid_step == 1.0`; the X, Y pair has `EPSG:26910`; no pair from the stale IPJ objects.
- AirMag: 127 lines (117 of type `LINE` from `L10160` to `L11320`, 10 `TIE` from `T90060` to `T90150`); channels `Mag`, `x`, `y`, all `Float64`; 83,466 rows in all; `Mag` from 55990.98 to 58295.42, `x` from 582834.9 to 612106.6, `y` from 6849898.5 to 6873483.0 (within the printed decimals); no missing values; every line date `"2023-03-01"`; the current pair `x, y` with `""` and the warning.

The plain blob fiducial offsets are a research guess (risk 1): long_valley, GDR_clmag and wform have plain blobs, so their `fid_start == 0.0` and `fid_step == 1.0` on every line confirms the offsets read the Oasis default.

- [ ] **Step 2: Run them.** With the files present, all pass; with `JULIAMAG_GDB_SAMPLES=/nonexistent`, the suite passes and prints one SKIP line per file.
- [ ] **Step 3: Run the bench.** `JULIA_NUM_THREADS=4 ~/.juliaup/bin/julia --project=JuliaMagCore bench/import_gdb.jl`. Expected: memory growth under 300 MB, flat as the file grows (try `n_lines` 100 and 400). If not, profile and fix, and record before and after numbers.
- [ ] **Step 4: Record the numbers in `docs/bench.md`** (a "Geosoft database import" section, with the machine and the command).
- [ ] **Step 5: Commit** `git commit -m "Test the gdb import on public files and a large file"`

---

### Task 11: Window test and docs

**Files:**
- Create: `JuliaMagUI/test/window/test_gdb_end_to_end.jl`
- Modify: `JuliaMagUI/test/runtests.jl` (include it after `window/test_map_end_to_end.jl`), `README.md`, `JuliaMagUI/README.md`, `docs/superpowers/plans/2026-10-28-plan-1-followups.md`, `docs/research/geosoft-gdb-format.md` (line 5: the spec now has section 6.3a)

**Interfaces:**
- Consumes: Task 9; the helpers of `test/window/test_map_end_to_end.jl` (`map_e2e_import`, `map_e2e_show`, `map_e2e_wait`), which live in the same test module.

- [ ] **Step 1: Write the window test**

In one window session, at scale 1, light theme, with `app.pick_file` replaced as in the map end-to-end test:
1. A new project from the backstage.
2. Database tab, "More import formats", the menu row `"Geosoft database..."`, the dialog's Import button, using the core's `test/data/gdb/afgrav.gdb`.
3. Wait for the database item. Check that the job ended `JOB_DONE`, that its warnings name the custom coordinate system, and that the Jobs tab shows the warning count on the job card.
4. Show on Map; wait until it is drawn (`map_e2e_wait`).
5. Shot `e2e-gdb-01-map-light.png`; switch to the dark theme with `ui.theme.dark`; wait; shot `e2e-gdb-01-map-dark.png`.
6. Open the Jobs tab and shot `e2e-gdb-02-job-light.png`, so the job card with its warning is seen.

- [ ] **Step 2: Run it headless.** `bin/test-headless.sh`. Expected: all UI tests pass, and the shots are in `JuliaMagUI/test/shots/`.
- [ ] **Step 3: Look at every shot by eye.** Check the line draws over the right extent, the legend and labels are not cut, and the job card text fits. Fix anything that looks off, also when it is not part of this work, and run the step again.
- [ ] **Step 4: Update the docs.**
  - `README.md`: under the import text, say that `import_file` reads Geosoft databases (`.gdb`), read only, with an example line `job = wait_job(import_file(s, "survey.gdb"))`.
  - `JuliaMagUI/README.md`: add `test/window/test_gdb_end_to_end.jl` to the list of window tests.
  - Follow-ups file: a new section "Left for later from the gdb import", one plain line each:
    - Group lines and group classes (now skipped with a warning).
    - The line selection byte (every imported line starts selected).
    - The display-list channel order (channels come in slot order).
    - `MAKER` history, `FORMULA` and the activity log, as JuliaMag history.
    - Custom (`*`) coordinate systems built from the IPJ parameters.
    - Projection methods other than geographic, Transverse Mercator, Lambert 2SP and polar stereographic.
    - Datum transform parameters, for a datum with no EPSG code.
    - String array channels (now skipped with a warning).
    - Check the header version words (bytes 8 to 15) against the pygdb corpus of 49 files.
  - Follow-ups file, "Checks on real systems": the Oasis checks of research section 17 (an XYZ export of AirMag; Change Channel Fid on a copy, compressed and uncompressed; the protect flag; deselected lines; a coordinate system set on AirMag; Database Properties).
- [ ] **Step 5: Run the core and UI suites.** Both pass, Aqua and JET clean.
- [ ] **Step 6: Commit** `git commit -m "Test the gdb import in the window and update the docs"`

---

## Rulings made while writing this plan

These are my calls; each says what it costs if wrong.

- **The spec subsection is numbered 6.3a.** Code comments and earlier plans cite spec 6.4 to 6.7 by number, so renumbering would break them. Cost: an odd number.
- **Display order is slot order.** Ruling 4 breaks a sampling tie by display order, and research section 16 puts the display list under "can wait". Slot order is the order the channels were made, and the order the XYZ exports list them. Cost if wrong: a different main sampling on a line where exactly half the channels differ, which no known file has.
- **USHORT, ULONG and 64-bit integers are read now.** Research 16 lists them under "can wait", but ruling 7 decides how to widen them, and the cost is a few table rows with synthetic tests. Cost: no real file tests them.
- **Resampling of integer and text channels.** Integers interpolate and round to the nearest value; text takes the nearer row. Linear interpolation has no meaning for text, and an integer channel must stay an integer. Cost if wrong: one rule changes.
- **A damaged data blob fails the whole import.** It names the line and channel. A partial database with silent holes would be worse, and the user can repair the file in Oasis. A damaged admin object (labels, units, coordinate system) is only a warning, since the data is still right.
- **A directory slot that is not live means "no data".** Only a live slot that misses its blob falls back to the chain copy. Falling back for slots that are not live could bring back old copies of deleted data (long_valley has 624 stale blobs).
- **The version words at bytes 8 and 12 are checked.** Ruling 2 says refuse what is not known. All 8 test files and the research agree on them. Cost if wrong: a valid file from another Oasis version is refused with a clear message, and the check is one line to relax. Task 11 adds a follow-up to check them against the pygdb corpus.
- **The importer has a `crs` setting**, used only for the current pair when the file stores no coordinate system for it. This is how the user sets it at import (spec 6.6), as for XYZ. A coordinate system stored in the file always wins.
- **Only `afgrav` goes into the repo.** It is U.S. public domain and 631 KB with its XYZ. `long_valley_ed` (7.3 MB) is too large. The Geoscience BC files have no licence statement that allows sharing, so they are optional only.
- **The UI needs one table entry**, `"import.geosoft_gdb" => "import"` in `CORE_ICONS`, because `test_icons.jl` checks that every importer has an icon. The menus, command search, dialog and Jobs tab come from the registry with no other change.
