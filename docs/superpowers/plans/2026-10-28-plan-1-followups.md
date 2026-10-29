# Plan 1 follow-ups

Date: 2026-10-28

Plan 1 (JuliaMagCore) is done and reviewed.
These are the open points from the reviews that later plans must handle.

## Must be done before the UI depends on it (plan 2 to 4)

- A job that fails after a finished append, while a reader (export, Statistics, Guess UTM) holds the item, keeps the appended rows and has no undo.
  Record it as a job warning and offer the undo once the reader ends.
- Saved scripts use literal item ids, so they only replay on a copy of the starting project.
  Bind outputs to variables before the Run Script UI exists.
- `rerun!` with `replace = true` is not in the history, so replay keeps both outputs.
- A job report (`IOBuffer`) is read while the worker writes it.
  This is a data race once the Jobs tab shows live reports.
- Two sessions on one project folder are not coordinated.
  Add a project lock file.
- `undo!` holds `s.lock` while it copies large files (Channel Math overwrite, append undo).
  This would freeze the UI.
- `Session.warnings` is stored but not shown.
- An append with a coordinate system that differs from the existing pair gives no warning.
- PROJ warnings (for example a ballpark transformation) are dropped.
- `.undo-*` side folders left after a crash are never swept.
- Settings are remembered before a quick tool runs, so a failed run still changes them.
- Session API gaps: remove an item with undo, undoable channel property edits (unprotect, rename, delete), a setter for the marked range, an item-picker setting type for importer targets.

## Windows

- Windows is the main platform, but no test has run there yet.
- The memory-map release before undo, the file-cut order in undo, and readers during an append need a Windows CI job in the packaging plan.

## Can wait

- A job that appends and then runs Channel Math on the same item is refused (no caller does this yet).
- A direct `import_xyz` replays as `import_file`, which adds an undo step the original session did not have.
- Undo of a job with several noted steps is not retryable as a unit.
- Reader marks from Statistics and Guess UTM tell writers "an export is running".
- Channel Math has no logical NOT.
- Smaller test and wording gaps are listed in the task reviews.
