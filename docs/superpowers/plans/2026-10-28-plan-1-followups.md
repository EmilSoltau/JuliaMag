# Plan 1 follow-ups

Date: 2026-10-28

Plan 1 (JuliaMagCore) is done and reviewed.
These are the open points from the reviews that later plans must handle.

## Must be done before the UI depends on it (plan 2 to 4)

- Saved scripts use literal item ids, so they only replay on a copy of the starting project.
  Bind outputs to variables before the Run Script UI exists.
- `rerun!` with `replace = true` is not in the history, so replay keeps both outputs.
- `Session.warnings` is stored but not shown.
- Session API gaps: remove an item with undo, undoable channel property edits (unprotect, rename, delete), a setter for the marked range, an item-picker setting type for importer targets.

## Done in plan 2

- Two sessions on one project folder are not coordinated.
  Add a project lock file.
  Done in the commit "Lock a project while a session has it open".
- `undo!` holds `s.lock` while it copies large files (Channel Math overwrite, append undo).
  This would freeze the UI.
  Done in the commit "Run undo steps outside the session lock and sweep leftovers".
- `.undo-*` side folders left after a crash are never swept.
  Done in the same commit: `open_session` removes `.undo-*` and `.importing-*` folders, each with a warning.
- Settings are remembered before a quick tool runs, so a failed run still changes them.
  Done in the same commit: a quick tool remembers its settings only after it ran without error.
- A job that fails after a finished append, while a reader (export, Statistics, Guess UTM) holds the item, kept the appended rows and had no undo.
  Done in the commit "Make job reports thread safe and show job warnings".
  The job gets a warning, and an undo step "remove rows of failed <job id>" that works once the reader ends.
  The failed job is not in the history, so the undo of that step is not recorded either.
- A job report (`IOBuffer`) was read while the worker wrote it.
  Done in the same commit: the report is a `JobReport` with a lock, and `report_text(job)` is safe from any thread.
- An append with a coordinate system that differs from the existing pair gave no warning.
  Done in the same commit: the job gets a warning, and the pair keeps its own coordinate system.
- PROJ warnings were dropped.
  Done in the same commit: the lines PROJ logs reach `with_crs` and `Reprojector`, and a reprojection job shows them as warnings.
  PROJ logs nothing for a ballpark transformation, so the reprojector asks PROJ which operation it used and adds a line for a ballpark one.
- Jobs have warnings now (`job_warning!`, `job_warnings`), saved in the job record.
  A job that finishes during an undo, and whose held history entry then cannot be written, gets such a warning.

## Checks on real systems

- Windows is the main platform, but no test has run there yet.
- The memory-map release before undo, the file-cut order in undo, and readers during an append need a Windows CI job in the packaging plan.
- Open a `.grd` written by JuliaMag in Oasis montaj.
  Check that the values, the position and the coordinate system (from `.grd.xml` alone, without `.gi`) are right.
  The research could not confirm that Oasis reads the coordinate system from `.xml` alone.
  Check a rotated grid too: Oasis adds a `<warp>` for the rotation to its own `.grd.xml`, and JuliaMag does not.
- Open a rotated ER Mapper `.ers` (from Oasis or ER Mapper) in JuliaMag and check that the rotation direction is right.
  JuliaMag reads the `Rotation` field itself as degrees counter-clockwise; no rotated sample file was available to confirm the sign.
- Open an `.ers` written by JuliaMag for a grid with no coordinate system in Oasis montaj or ER Mapper, and check that it is placed at its real coordinates (JuliaMag writes a RAW block with `Eastings`/`Northings`, while ER Mapper's own RAW form uses `MetersX`/`MetersY`).
- Open an `.ers` written by JuliaMag for a grid in latitude and longitude in Oasis montaj, and check its position (GDAL writes it with `CoordinateType = EN` and `Units = METERS`).

## Can wait

- A saved script opens its project with `open_session` and does not close it.
  Run in a REPL, it keeps the project locked until Julia exits.
- A job that appends and then runs Channel Math on the same item is refused (no caller does this yet).
- A direct `import_xyz` replays as `import_file`, which adds an undo step the original session did not have.
- Undo of a job with several noted steps is not retryable as a unit.
- Reader marks from Statistics and Guess UTM tell writers "an export is running".
- Channel Math has no logical NOT.
- Smaller test and wording gaps are listed in the task reviews.
