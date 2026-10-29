# Turn the history of a session into a Julia script.

function line_expr(d)::String
    return "LineId($(d["type"]), $(repr(d["number"])), $(repr(d["version"])))"
end

# Keyword name for `run_tool`. Names that are not identifiers are quoted with var"...".
kwname(k::AbstractString) = Base.isidentifier(k) ? String(k) : "var" * repr(String(k))

# A value as Julia source. Dictionaries become `Dict(k => v, ...)` with sorted keys,
# so `inputs = Dict("database" => "db-1")` reads well. Other values use `repr`.
function literal(x)::String
    x isa AbstractDict || return repr(x)
    ks = sort!([String(k) for k in keys(x)])
    return "Dict(" * join(("$(repr(k)) => $(literal(x[k]))" for k in ks), ", ") * ")"
end

kwtext(a::AbstractDict, ks) = join(("$(kwname(k)) = $(literal(a[k]))" for k in sort!(collect(ks))), ", ")

# True when the command is a registered importer and the args name the file.
is_import(c::String, a::AbstractDict) =
    any(i -> i.id == c, importers()) && get(a, "path", nothing) isa AbstractString

# True when the command is a registered exporter and the args name the item and the file.
is_export(c::String, a::AbstractDict) =
    any(x -> x.id == c, exporters()) && get(a, "item", nothing) isa AbstractString &&
    get(a, "path", nothing) isa AbstractString

# A job returns at once. The script waits for it, so the next line sees its result.
# Imports and exports always run as jobs in the script, even when they were called
# directly. `run_tool` lines are wrapped too: for a quick tool or a refused one,
# `wait_job` throws a `ToolError` when the tool did not run, so the script stops there.
function call_text(e::HistoryEntry)::String
    c, a = e.command, e.args
    wrap = !isempty(e.job) || is_import(c, a) || is_export(c, a) || is_tool_call(c)
    return wrap ? "wait_job($(command_text(e)))" : command_text(e)
end

# True when `command_text` writes the entry as a `run_tool` call.
is_tool_call(c::String) = !(c in ("database.set_cell", "database.set_line_selected", "session.undo", "session.redo"))

function command_text(e::HistoryEntry)::String
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
    if is_import(c, a)
        kw = kwtext(a, filter(!=("path"), collect(keys(a))))
        return isempty(kw) ? "import_file(s, $(repr(a["path"])))" : "import_file(s, $(repr(a["path"])); $kw)"
    end
    if is_export(c, a)
        kw = kwtext(a, filter(k -> !(k in ("item", "path")), collect(keys(a))))
        head = "export_file(s, $(repr(a["item"])), $(repr(a["path"])); exporter = $(repr(c))"
        return isempty(kw) ? head * ")" : head * ", " * kw * ")"
    end
    kw = kwtext(a, keys(a))
    return isempty(kw) ? "run_tool(s, $(repr(c)))" : "run_tool(s, $(repr(c)); $kw)"
end

"""
    script_text(s)::String

The history as a Julia script. It starts with `using JuliaMagCore` and
`s = open_session(<project folder>)`. Each entry is one call.
Commands that have a core function become that call. Imports become
`import_file(s, path; <settings>...)`. Exports become
`export_file(s, item, path; exporter = "<id>", <settings>...)`. Other commands become
`run_tool(s, "<command>"; <args>...)`, with tool inputs as `inputs = Dict(...)`.
Every import, export and tool call, and every entry that ran as a job, is
wrapped in `wait_job(...)`. So the script waits for each job before the next
line, and stops at a tool that did not run.

The script uses the item ids of the session, such as `"db-1"`, as plain text.
So it replays only on a copy of the project as it was when the session started.
Run on the same project again, the imports make new items with new ids, and
the lines after them change the old items or fail.
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
