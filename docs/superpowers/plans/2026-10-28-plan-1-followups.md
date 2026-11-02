# Plan 1 follow-ups

Date: 2026-10-28

Plan 1 (JuliaMagCore) is done and reviewed.
These are the open points from the reviews that later plans must handle.

## Done in plan 3

Plan 3 (the UI shell) did the five points that had to be done before the UI depends on the core.

- `Session.warnings` was stored but not shown.
  Done in the commit "Add a change counter, a warnings reader and a closed state to sessions": `warnings(s)` reads them, also after `close_session!`.
  The app shows the warnings of a close in a dialog.
- A closed session stayed usable, and jobs started while `close_session!` ran were not cancelled.
  Done in the same commit: a session has a closed state that edits and `start_job!` refuse.
  The commit "Check the session is open again under the lock and harden the close tests" closes the race with a check under the lock.
- An `ItemSetting` in mode new could keep a stale target item.
  Done in the commit "Let settings depend on other settings and report problems per setting": the append target has `when = "mode" => ["append"]`, so it is not used in mode new.
- There was no call to remove a position pair.
  Done in the commit "Add and remove position pairs, select many lines at once, check the cursor": `add_pair!` and `remove_pair!`, both undoable.
- `set_marked!` accepted rows below 1.
  Done in the same commit: it checks the range against the cursor line.

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
- A quick tool returned its outputs as items, while a job gives item ids.
  So a script line that bound a quick tool's output gave an item, and a later line that used it failed on replay.
  Done in the commit "Return item ids from quick tools": a quick tool returns item ids now, as a job does.

## Left for later from plan 3

These were out of scope for the UI shell.

- Views (map, database, profile, statistics), the Layers tab, maps, "Add to current map", the shared cursor and the status bar's pointer and cursor parts: plan 4.
- The CSV import wizard, file previews in import dialogs and the coordinate system picker with EPSG search: plan 4.
- Save As (copy a project), the Project Settings page, "Find..." for missing items, and "Clear Finished" in the Jobs tab.
- Greyed "later" buttons for tools that do not exist yet.
  The ribbon shows only real commands (spec 9.1: empty tabs are not shown).
- Applying the software rendering setting on Windows, and the Windows checks of DPI, fonts and dialogs: plan 5 (packaging), on a real Windows machine.
  On Linux the setting already takes effect (`LIBGL_ALWAYS_SOFTWARE`).
  On Windows it is only saved; plan 5 ships a Mesa `opengl32.dll` switch (ruling T15-C4).
- Editing an item's free-text description (spec 9.2): the core has no call for it yet.
- NativeFileDialog 0.2 has no dialog title and no suggested file name for a save (ruling T13-C4): plan 5 picks a dialog that has them, or a newer NativeFileDialog.
- Text widths (T12-C1, T15-C5): long lines of regular text are about 5 % shorter than in the prototype at scale 1.
  "No jobs yet. Imports and long tools run here." is 256 px wide in the app and 270 px in Chromium.
  Two causes add up.
  ImGui rounds every font size to whole pixels (`GetRoundedFontSize`), so the 12.5 px body font (15.12 px from ascender to descender) is drawn at 15 px, 0.8 % small.
  FreeType hinting then rounds each advance to a pixel, so the space (3.49 px at 15 px) becomes 3 px, where Chromium makes it 4.
  Chromium also hints some letters wider (`o` is 8 px there, 7.5 px in the font).
  A tested fix for the first cause: set `ImFontConfig.ExtraSizeScale` to the requested size over the rounded size.
  At scale 1 it makes the space 4 px and that sentence 264 px, and line heights stay the same.
  Its glyphs were not checked for blur.
  At scale 1.5 it makes text narrower, so it needs one font per size and scale, or a fix in ImGui; that is why it is not in plan 3.
- Long expressions in text (`wrap_units` in `shell/draw.jl`): it glues an operator chain into one unit, so `A = B - C + D` is one unit.
  A long expression can run past the box.
  Consider breaking a unit after the last operator when it is wider than the line.
- `ViewCache` (`app/state.jl`) watches only `database.json` and `grid.json`.
  If a channel file is cut or damaged outside the app, no error shows until the JSON changes.
  Before the cache, every revision bump read the files again.
- With three sticky toasts open, a new ordinary toast is dropped at once (`add_toast!`).
  The user then sees no toast for their action while three errors stay.

## Checks on real systems

- Plan 3: on Windows, check the job start and end times in the Jobs tab and the job records (T12-P3).
  They are written in UTC with a "Z" and shown in local time.
- Plan 3: check the overwrite question of the native save dialog on GTK and on Windows (T13-P2).
  JuliaMag asks itself when the dialog did not confirm the exact path.
- Windows is the main platform, but no test has run there yet.
- The memory-map release before undo, the file-cut order in undo, and readers during an append need a Windows CI job in the packaging plan.
- Open a `.grd` written by JuliaMag in Oasis montaj.
  Check that the values, the position and the coordinate system (from `.grd.xml` alone, without `.gi`) are right.
  The research could not confirm that Oasis reads the coordinate system from `.xml` alone.
  The Oasis manual says Oasis keeps the projection of a grid in its `.gi` file, and that without it a grid "can appear in the incorrect location and/or orientation".
  If this check fails, JuliaMag must write a `.grd.gi` file too, as its own task.
  Check a rotated grid too: Oasis adds a `<warp>` for the rotation to its own `.grd.xml`, and JuliaMag does not.
- Open a rotated ER Mapper `.ers` (from Oasis or ER Mapper) in JuliaMag and check that the rotation direction is right.
  JuliaMag reads the `Rotation` field itself as degrees counter-clockwise; no rotated sample file was available to confirm the sign.
- Open an `.ers` written by JuliaMag for a grid with no coordinate system in Oasis montaj or ER Mapper, and check that it is placed at its real coordinates (JuliaMag writes a RAW block with `Eastings`/`Northings`, while ER Mapper's own RAW form uses `MetersX`/`MetersY`).
- Open an `.ers` written by JuliaMag for a grid in latitude and longitude in Oasis montaj, and check its position (GDAL writes it with `CoordinateType = EN` and `Units = METERS`).
- Windows hard links: check the error codes, including `EPERM` from "access denied".
- Windows: call `GetLastError` right after `OpenProcess`, so the pid check reads the right error.
- Windows: renaming a lock file that another program holds open without share-delete gives a raw `IOError`.
- Windows: rename and read failures in `take_over!` escape as raw errors.
- Plan 5: `thrown_by_juliamag` (`app/worker.jl`) compares the first frame's file with `SOURCE_DIR` and `pathof(JuliaMagCore)`.
  In a packaged or relocated build the debug paths can differ.
  Then every JuliaMag `ArgumentError` would count as a bug.

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
