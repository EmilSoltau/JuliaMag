# Plan 1 follow-ups

Date: 2026-10-28

Plan 1 (JuliaMagCore) is done and reviewed.
These are the open points from the reviews that later plans must handle.

## Must be done before the UI depends on it (plan 2 to 4)

- `Session.warnings` is stored but not shown.
  Close-time warnings go there too, into the warnings of the session that closes, so the UI must show them after a close.
- A closed session stays usable.
  Jobs started while `close_session!` runs are not cancelled.
  Add a closed flag that the edits and `start_job!` refuse.
- An `ItemSetting` in mode new can keep a stale target item.
- There is no call to remove a position pair.
- `set_marked!` accepts rows below 1.

## Done in plan 2

- Two sessions on one project folder were not coordinated.
  Done with a project lock file, in the commit "Lock a project while a session has it open".
- `undo!` held `s.lock` while it copied large files (Channel Math overwrite, append undo).
  This would have frozen the UI.
  Done in the commit "Run undo steps outside the session lock and sweep leftovers".
- `.undo-*` side folders left after a crash were never swept.
  Done in the same commit: `open_session` removes `.undo-*` and `.importing-*` folders, each with a warning.
- Settings were remembered before a quick tool ran, so a failed run still changed them.
  Done in the same commit: a quick tool remembers its settings only after it ran without error.
- A job that failed after a finished append, while a reader (export, Statistics, Guess UTM) holds the item, kept the appended rows and had no undo.
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
- Jobs had no warnings.
  Now they have them (`job_warning!`, `job_warnings`), saved in the job record.
  A job that finishes during an undo, and whose held history entry then cannot be written, gets such a warning.
- The session API had gaps: remove an item with undo, undoable channel property edits (unprotect, rename, delete), a setter for the marked range, an item-picker setting type for importer targets.
  Done in the commit "Add undoable item and channel edits for the views".
  The new calls are `remove_item!(s, id)`, `rename_item!`, `set_channel_protected!`, `rename_channel!`, `delete_channel!`, `set_channel_info!` and `set_marked!`.
  Each edit except `set_marked!` is undoable, recorded, and replays from a script.
  `ItemSetting` names an item of one kind, and `validate(spec, settings; session = s)` checks it against the project.
  The append target of the CSV and XYZ importers is an `ItemSetting` now.
- Saved scripts used literal item ids, so they only replayed on a copy of the starting project.
  Done in the commit "Bind outputs to variables so scripts replay on the same project".
  The outputs of each job are bound to variables named after their ids, such as `db_1`, and later lines use them.
  A history entry keeps the ids of the items it made, also for a direct import; older history files take them from the job records.
  Items from before the first history entry keep their literal ids.
  A script replays on the same project too, and each run makes new items.
- `rerun!` with `replace = true` was not in the history, so replay kept both outputs.
  Done in the same commit: the history entry of the new job names the job it replaces and the items it took out.
  The script runs the command and then removes those items with `remove_item!`.
  An undo or redo of that job becomes one `undo!(s)` or `redo!(s)` per script step.
- A saved script opened its project and did not close it, so it kept the project locked until Julia exited.
  Done in the same commit: the script lines run inside `try ... finally close_session!(s) end`.
  A job line waits with `wait_job(...; check = true)`, so the script stops with a plain message at a failed job.
- A direct `set_grid_crs!` and the tool `grid.set_crs` were told apart in the script only by an `"item"` argument.
  Done in the same commit: a direct call is recorded as `"grid.set_grid_crs"`; old history files still replay.
- A script made from a reopened session could differ from the live one, since JSON reads `3.0` back as `3`.
  Done in the same commit: the script writes each value in one form, and a number setting in the type the setting keeps.
- A rerun with `replace = true` left the folders of the items it replaced on disk for good, when the session closed with the rerun done.
  A Channel Math overwrite left its `.undo-*` side folder after a normal close, so the next open reported it as left after a crash.
  Done in the final review fixes of plan 2: a job's undo step has a `commit` too, and `note_job_undo!` takes one.
  At close, the commit deletes the replaced folders and the side folder.
  Commits run only while the project lock is still ours; after a forced open elsewhere the files are kept, with a warning.

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
- Windows hard links: check the error codes, including `EPERM` from "access denied".
- Windows: call `GetLastError` right after `OpenProcess`, so the pid check reads the right error.
- Windows: renaming a lock file that another program holds open without share-delete gives a raw `IOError`.
- Windows: rename and read failures in `take_over!` escape as raw errors.

## Can wait

- A job that appends and then runs Channel Math on the same item is refused (no caller does this yet).
- A direct `import_xyz` replays as `import_file`, which adds an undo step the original session did not have.
- Undo of a job with several noted steps is not retryable as a unit.
- Reader marks from Statistics and Guess UTM tell writers "an export is running".
- Channel Math has no logical NOT.
- Smaller test and wording gaps are listed in the task reviews.
- After a crash or an exit without close, the folders of removed items and of replaced outputs stay on disk for good.
  This is the cost of the ruling that the project file is the truth, so the open never deletes folders the project file does not list.
  Add a "clean project" command that lists such folders, so the user can choose to delete them.
- A failed job's kept rows stay after close if the user never undoes them; warn at close.
  Pushing the kept step clears the redo stack.
- Lock file: sweep stale `.project.lock.*.old` and `.tmp` files.
- Lock file: pid reuse after a reboot can make a stale lock look live.
- Lock file: two forced sessions in one process can have equal lock records; add a nonce.
  Until then, the close of the first one cannot tell that the second one took the lock, so it runs its commits.
- Lock file: `read(path)` swallows `EACCES`.
- Lock file: an error inside `release_lock!` or `restore_lock!` hides the load error.
- ERS header parsing: an empty `Rotation` fails, and keys are case-sensitive.
- ERS header parsing: an unparsable `RegistrationCellX`, `Xdimension` or `MetersX` silently becomes 0 or 1; it should warn.
- ERS export: write `Datum = "EPSG:n"` for the geographic codes that GDAL drops.
- Values: `+Inf` and `-Inf` go into `vmin` and `vmax`, and into `.grd` values and header.
- Values: a `Float32` nodata value is compared after the cast.
- Values: `set_grid_style!` does not check min and max, and `open_grid` does not check `style.method`.
- No-op edits push undo steps: `set_grid_georef!` with no keywords, and `set_channel_info!` with no change.
- In the Task 14 helpers, an error in the rollback clean-up replaces the original error.
- Compressed Geosoft grids: the whole payload of each block is read into memory, so one huge block breaks the rule that a whole file is never read at once.
- Messages: an ArchGDAL `ErrorException` bypasses `gdal_errors`.
- Messages: `xml_escape` does not handle control characters.
- PROJ: the ballpark check can miss a stretch inside a 4096-point block.
- PROJ: the coordinate system mismatch check compares text, so case, or WKT against an EPSG code, gives false warnings.
- PROJ: the "N points not transformed" line is in the report only.
- `report_text` clashes with the JET export of the same name; consider a rename.
- `NUM_THREADS=ALL_CPUS` with several GeoTIFF exports at once can oversubscribe the CPU.
- Test gaps: untested paths in `grid.jl`, and the map-release test without a rename after it.
- Test gaps: weak put-twice tests, and only one independent cell value for `mag_4126`.
- Test gaps: the order of `.xml` before `.gi` when they disagree, a damaged Surfer file, and the `extent2d` literals.
- Test gaps: the grid "changed while read" path, and the `Float64` multi-block statistics path.
- Test gaps: a sweep after a crash with a stale lock, and the settings of a failed `:job` tool.
- Run the suite with `-t 4` in CI.
