# Turn the history of a session into a Julia script.

function line_expr(d)::String
    return "LineId($(d["type"]), $(repr(d["number"])), $(repr(d["version"])))"
end

# Keyword name for `run_tool`. Names that are not identifiers are quoted with var"...".
kwname(k::AbstractString) = Base.isidentifier(k) ? String(k) : "var" * repr(String(k))

function call_text(e::HistoryEntry)::String
    a = e.args
    c = e.command
    if c == "database.set_cell"
        return "set_cell!(s, $(repr(a["item"])), $(line_expr(a["line"])), $(repr(a["channel"])), " *
               "$(repr(a["row"])), $(repr(a["value"])))"
    elseif c == "database.set_line_selected"
        return "set_line_selected!(s, $(repr(a["item"])), $(line_expr(a["line"])), $(repr(a["selected"])))"
    elseif c == "session.undo"
        return "undo!(s)"
    elseif c == "session.redo"
        return "redo!(s)"
    end
    kw = join(("$(kwname(k)) = $(repr(a[k]))" for k in sort!(collect(keys(a)))), ", ")
    return isempty(kw) ? "run_tool(s, $(repr(c)))" : "run_tool(s, $(repr(c)); $kw)"
end

"""
    script_text(s)::String

The history as a Julia script. It starts with `using JuliaMagCore` and
`s = open_session(<project folder>)`. Each entry is one call.
Commands that have a core function become that call.
Other commands become `run_tool(s, "<command>"; <args>...)`.
"""
function script_text(s::Session)::String
    lock(s.lock) do
        io = IOBuffer()
        println(io, "using JuliaMagCore")
        println(io, "s = open_session(", repr(s.project.folder), ")")
        for e in s.history
            println(io, "# ", e.time, " ", e.command, isempty(e.job) ? "" : " (job " * e.job * ")")
            println(io, call_text(e))
        end
        return String(take!(io))
    end
end
