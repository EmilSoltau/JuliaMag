# Undo and redo stacks of a session. They are in memory only and are not saved.
#
# `undo!` and `redo!` hold `s.lock` only for short times: to check the step's
# items, take the step off its stack and mark the items busy; and afterwards
# to move the step to the other stack and record it. The step itself, which
# may copy large files, runs without `s.lock`, so the session goes on.
# `s.undo_lock` makes a second `undo!` or `redo!` wait for the first.
#
# While the step runs, it counts as taken off its stack. Undo steps and history
# entries that other changes make meanwhile are held (`s.held_edits`), and
# pushed and recorded after the step. So the stacks and the history keep one
# order, and a script repeats them right: a change made during an undo follows
# the undo, and clears the redo stack as any new change does.

"""
Add a step to the undo stack and clear the redo stack (running each step's `drop`).
While an undo or redo step runs, the step is held and added after it (see `Session`).
"""
function push_undo!(s::Session, step::UndoStep)
    lock(s.lock) do
        held = s.held_edits
        if held !== nothing
            push!(held, step)
            return step
        end
        push!(s.undo_stack, step)
        for old in s.redo_stack
            try
                old.drop()
            catch e
                e isa InterruptException && rethrow()
                session_warning!(s, "undo step \"$(old.label)\" could not free its data: $(sprint(showerror, e))")
            end
        end
        empty!(s.redo_stack)
        return step
    end
end

can_undo(s::Session)::Bool = lock(() -> !isempty(s.undo_stack), s.lock)
can_redo(s::Session)::Bool = lock(() -> !isempty(s.redo_stack), s.lock)

"""
    undo!(s)::Bool

Undo the last step. Returns false when there is nothing to undo.
The step runs without `s.lock` (see `UndoStep`). Its items are busy meanwhile,
with reason `"undo is running"`. A second `undo!` or `redo!` waits for it.
If the step throws, it stays on the stack and the error is thrown. So does a
step whose items are busy (`ItemBusyError`), before it runs.
The undo is recorded as `"session.undo"` so the script repeats it, unless the
step's change is not in the history (`recorded = false`).
Do not call it while holding `s.lock` (see `Session` for the order of locks).
"""
undo!(s::Session)::Bool = run_step!(s, true)

"Redo the last undone step. Returns false when there is nothing to redo. It works like `undo!`."
redo!(s::Session)::Bool = run_step!(s, false)

function run_step!(s::Session, undo::Bool)::Bool
    from() = undo ? s.undo_stack : s.redo_stack
    to() = undo ? s.redo_stack : s.undo_stack
    lock(s.undo_lock) do
        step = lock(s.lock) do
            isempty(from()) && return nothing
            top = last(from())
            ids = unique(top.items)
            foreach(id -> check_not_busy(s, id), ids)
            pop!(from())
            me = current_task()
            foreach(id -> s.busy[id] = BusyMark(true, 0, UNDO_RUNNING, :write, me), ids)
            s.held_edits = Union{UndoStep,HistoryEntry}[]
            return top
        end
        step === nothing && return false
        ok = false
        try
            undo ? step.undo() : step.redo()
            ok = true
        finally
            lock(s.lock) do
                foreach(id -> delete!(s.busy, id), unique(step.items))
                held = something(s.held_edits)
                s.held_edits = nothing
                try
                    push!(ok ? to() : from(), step)
                    ok && step.recorded && record!(s, undo ? "session.undo" : "session.redo", Dict{String,Any}())
                finally
                    foreach(x -> add_held!(s, x), held)
                end
            end
        end
        return true
    end
end

"""
Push or record a change that was held while an undo or redo step ran. Call it under `s.lock`.
A history entry that cannot be written is a warning, not an error: the change
is done. The entry of a job warns that job too, since a script will not repeat it.
"""
function add_held!(s::Session, x::Union{UndoStep,HistoryEntry})
    x isa UndoStep && return (push_undo!(s, x); nothing)
    try
        write_history!(s, x)
    catch e
        e isa InterruptException && rethrow()
        why = sprint(showerror, e)
        session_warning!(s, "the history entry \"$(x.command)\" could not be saved: $why")
        isempty(x.job) || warn_job!(s, x.job, "the history entry of this job could not be saved, " *
                                              "so a script will not repeat it: $why")
    end
    return nothing
end
