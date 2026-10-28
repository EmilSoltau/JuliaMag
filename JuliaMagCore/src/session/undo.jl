# Undo and redo stacks of a session. They are in memory only and are not saved.

"Add a step to the undo stack and clear the redo stack."
function push_undo!(s::Session, step::UndoStep)
    lock(s.lock) do
        push!(s.undo_stack, step)
        empty!(s.redo_stack)
        return step
    end
end

can_undo(s::Session)::Bool = lock(() -> !isempty(s.undo_stack), s.lock)
can_redo(s::Session)::Bool = lock(() -> !isempty(s.redo_stack), s.lock)

"""
    undo!(s)::Bool

Undo the last step. Returns false when there is nothing to undo.
If the step throws, it stays on the stack.
The undo is recorded as `"session.undo"` so the script repeats it.
"""
function undo!(s::Session)::Bool
    lock(s.lock) do
        isempty(s.undo_stack) && return false
        step = last(s.undo_stack)
        step.undo()
        pop!(s.undo_stack)
        push!(s.redo_stack, step)
        record!(s, "session.undo", Dict{String,Any}())
        return true
    end
end

"Redo the last undone step. Returns false when there is nothing to redo."
function redo!(s::Session)::Bool
    lock(s.lock) do
        isempty(s.redo_stack) && return false
        step = last(s.redo_stack)
        step.redo()
        pop!(s.redo_stack)
        push!(s.undo_stack, step)
        record!(s, "session.redo", Dict{String,Any}())
        return true
    end
end
