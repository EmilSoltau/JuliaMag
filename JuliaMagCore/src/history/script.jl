# Turn the history of a session into a Julia script.
#
# Each job's outputs are bound to variables named after their ids, such as
# `db_1 = only(wait_job(import_file(s, "..."; ...)).outputs)`. Later lines that
# name such an item use the variable, so the script replays on the same project
# too: each run makes new items with new ids. Items that existed before the first
# history entry keep their literal ids.
#
# Values are written in one form, whether the history is live or read back from
# `history.jsonl` (JSON reads 3.0 back as 3, and a list as `Any[...]`): see `literal`.

"A variable of the script that holds an item id."
struct ScriptVar
    name::String
end

"The variable name for item `id`: `\"db-1\"` becomes `db_1`."
function var_name(id::AbstractString)::String
    v = String(replace(String(id), r"[^A-Za-z0-9_]" => "_"))::String
    return Base.isidentifier(v) && v != "s" ? v : "item_" * v
end

"""
A line id as Julia source. The line type must be one of the `LineType` names,
since it is written as a name, not as text. Throws `ArgumentError` otherwise.
"""
function line_expr(d)::String
    d isa AbstractDict || throw(ArgumentError("the line is not an object"))
    ty = get(d, "type", nothing)
    names = [string(x) for x in instances(LineType)]
    (ty isa AbstractString && ty in names) ||
        throw(ArgumentError("the line type $(repr(ty)) is not one of $(join(names, ", "))"))
    return "LineId($ty, $(literal(get(d, "number", nothing))), $(literal(get(d, "version", nothing))))"
end

"""
History text for a comment line of the script. Control characters (such as a
newline, which would end the comment) and line or paragraph separators become
spaces, and bytes that are not valid text become U+FFFD.
"""
comment_text(x::AbstractString)::String =
    map(c -> !isvalid(c) ? '\ufffd' : iscntrl(c) || c in ('\u2028', '\u2029') ? ' ' : c, String(x))

# Keyword name for `run_tool`. Names that are not identifiers are quoted with var"...".
kwname(k::AbstractString) = Base.isidentifier(k) ? String(k) : "var" * repr(String(k))

"""
A value as Julia source, the same for a live value and for the value JSON reads
back. Dictionaries become `Dict(k => v, ...)` with sorted keys, so
`inputs = Dict("database" => "db-1")` reads well. Vectors become `[a, b]`.
A whole float becomes an integer (`3.0` is `3`). A `ScriptVar` is its name.
Other values use `repr`.
"""
function literal(x)::String
    x isa ScriptVar && return x.name
    if x isa AbstractDict
        ks = sort!([String(k) for k in keys(x)])
        return "Dict(" * join(("$(repr(k)) => $(literal(x[k]))" for k in ks), ", ") * ")"
    end
    x isa AbstractVector && return "[" * join((literal(v) for v in x), ", ") * "]"
    x isa AbstractString && return repr(String(x))
    x isa Bool && return repr(x)
    x isa Integer && return repr(Int(x))
    if x isa AbstractFloat
        f = Float64(x)
        return isinteger(f) && abs(f) <= 2.0^53 ? repr(Int(f)) : repr(f)
    end
    return repr(x)
end

"""
The value `x` of setting `st` as Julia source: in the type the setting keeps
(see `setting_value`), so a number setting writes `3.0` both live and after a
reload. Other values, or no setting, use `literal`.
"""
function setting_text(st, x)::String
    x isa ScriptVar && return x.name
    v = st === nothing ? x : setting_value(st, x)
    v isa Float64 && return repr(v)
    v isa Vector{Float64} && return "[" * join((repr(f) for f in v), ", ") * "]"
    return literal(v)
end

"The settings of the importer, exporter or tool with id `c`, or none."
function command_settings(c::String)::Vector{SettingSpec}
    k = findfirst(i -> i.id == c, importers())
    k === nothing || return importers()[k].settings
    k = findfirst(x -> x.id == c, exporters())
    k === nothing || return exporters()[k].settings
    t = find_tool(c)
    return t === nothing ? SettingSpec[] : t.settings
end

function kwtext(c::String, a::AbstractDict, ks)::String
    specs = command_settings(c)
    one(k) = (k2 = findfirst(st -> st.key == k, specs); setting_text(k2 === nothing ? nothing : specs[k2], a[k]))
    return join(("$(kwname(k)) = $(one(k))" for k in sort!(collect(String, ks))), ", ")
end

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
# `check = true` makes a failed or cancelled job throw, so the script stops there too.
function call_text(e::HistoryEntry, vars::AbstractDict = Dict{String,String}())::String
    c, a = e.command, e.args
    wrap = !isempty(e.job) || is_import(c, a) || is_export(c, a) || is_tool_call(c, a)
    return wrap ? "wait_job($(command_text(e, vars)); check = true)" : command_text(e, vars)
end

# Commands that `command_text` writes as a call of their core function.
const CORE_COMMANDS = ("database.set_cell", "database.set_line_selected", "session.undo", "session.redo",
                       "grid.set_georef", "grid.set_style", "project.remove_item", "project.rename_item",
                       "database.set_channel_protected", "database.rename_channel", "database.delete_channel",
                       "database.set_channel_info")

# True for an entry of `set_grid_crs!`: `"grid.set_grid_crs"`. History files from
# before that name wrote it as `"grid.set_crs"` with an `"item"` and no `"inputs"`;
# the tool of that id is recorded with its inputs, and replays with `run_tool`.
is_grid_crs_call(c::String, a::AbstractDict) =
    c == "grid.set_grid_crs" || (c == "grid.set_crs" && haskey(a, "item") && !haskey(a, "inputs"))

# True when `command_text` writes the entry as a `run_tool` call.
is_tool_call(c::String, a::AbstractDict) = !(c in CORE_COMMANDS || is_grid_crs_call(c, a))

"""
The args of entry `e` with each item id that has a variable in `vars` (id to
name) replaced by a `ScriptVar`: the `"item"` of an edit or an export, the
values of `"inputs"`, and the item settings (`ItemSetting`) of an importer or a tool.
"""
function bind_items(e::HistoryEntry, vars::AbstractDict)::Dict{String,Any}
    a = copy(e.args)
    isempty(vars) && return a
    ref(x) = x isa AbstractString && haskey(vars, x) ? ScriptVar(vars[x]) : x
    haskey(a, "item") && (a["item"] = ref(a["item"]))
    ins = get(a, "inputs", nothing)
    ins isa AbstractDict && (a["inputs"] = Dict{String,Any}(String(k) => ref(v) for (k, v) in ins))
    for st in command_settings(e.command)
        st isa ItemSetting && haskey(a, st.key) && (a[st.key] = ref(a[st.key]))
    end
    return a
end

function command_text(e::HistoryEntry, vars::AbstractDict = Dict{String,String}())::String
    c = e.command
    # The kind of call is told from the args as recorded; `a` names items by their variables.
    crs_call, import_call, export_call = is_grid_crs_call(c, e.args), is_import(c, e.args), is_export(c, e.args)
    a = bind_items(e, vars)
    if c == "database.set_cell"
        return "set_cell!(s, $(literal(a["item"])), $(line_expr(a["line"])), $(literal(a["channel"])), " *
               "$(literal(a["row"])), $(literal(a["value"])))"
    elseif c == "database.set_line_selected"
        return "set_line_selected!(s, $(literal(a["item"])), $(line_expr(a["line"])), $(literal(a["selected"])))"
    elseif c == "session.undo"
        return "undo!(s)"
    elseif c == "session.redo"
        return "redo!(s)"
    elseif crs_call
        return "set_grid_crs!(s, $(literal(a["item"])), $(literal(a["crs"])))"
    elseif c == "grid.set_georef"
        # JSON reads a whole number back as an integer: write each value as a Float64.
        kw = join(("$(kwname(k)) = $(repr(Float64(a[k])))" for k in sort!([String(k) for k in keys(a) if k != "item"])),
                  ", ")
        return "set_grid_georef!(s, $(literal(a["item"])); $kw)"
    elseif c == "grid.set_style"
        return "set_grid_style!(s, $(literal(a["item"])), $(style_text(a)))"
    elseif c == "project.remove_item"
        return "remove_item!(s, $(literal(a["item"])))"
    elseif c == "project.rename_item"
        return "rename_item!(s, $(literal(a["item"])), $(literal(a["name"])))"
    elseif c == "database.set_channel_protected"
        return "set_channel_protected!(s, $(literal(a["item"])), $(literal(a["channel"])), " *
               "$(literal(a["protected"])))"
    elseif c == "database.rename_channel"
        return "rename_channel!(s, $(literal(a["item"])), $(literal(a["channel"])), $(literal(a["name"])))"
    elseif c == "database.delete_channel"
        return "delete_channel!(s, $(literal(a["item"])), $(literal(a["channel"])))"
    elseif c == "database.set_channel_info"
        return "set_channel_info!(s, $(literal(a["item"])), $(literal(a["channel"])); $(channel_info_text(a)))"
    end
    if import_call
        kw = kwtext(c, a, filter(!=("path"), collect(keys(a))))
        return isempty(kw) ? "import_file(s, $(literal(a["path"])))" : "import_file(s, $(literal(a["path"])); $kw)"
    end
    if export_call
        kw = kwtext(c, a, filter(k -> !(k in ("item", "path")), collect(keys(a))))
        head = "export_file(s, $(literal(a["item"])), $(literal(a["path"])); exporter = $(repr(c))"
        return isempty(kw) ? head * ")" : head * ", " * kw * ")"
    end
    kw = kwtext(c, a, keys(a))
    return isempty(kw) ? "run_tool(s, $(repr(c)))" : "run_tool(s, $(repr(c)); $kw)"
end

"The keywords of a `\"database.set_channel_info\"` entry, sorted. `format` is written as a symbol."
function channel_info_text(a::AbstractDict)::String
    ks = sort!([String(k) for k in keys(a) if !(k in ("item", "channel"))])
    return join(("$(kwname(k)) = $(k == "format" ? repr(Symbol(a[k])) : literal(a[k]))" for k in ks), ", ")
end

"""
    script_text(s)::String

The history as a Julia script. It starts with `using JuliaMagCore` and
`s = open_session(<project folder>)`. The lines after it run inside
`try ... finally close_session!(s) end`, so the project is not left locked,
also when a line fails. Each entry is one call, after a comment with its time,
command and job.
Commands that have a core function become that call. Imports become
`import_file(s, path; <settings>...)`. Exports become
`export_file(s, item, path; exporter = "<id>", <settings>...)`. Other commands become
`run_tool(s, "<command>"; <args>...)`, with tool inputs as `inputs = Dict(...)`.
Every import, export and tool call, and every entry that ran as a job, is
wrapped in `wait_job(...; check = true)`. So the script waits for each job
before the next line, and stops at a job that failed or a tool that did not run.

The outputs of an entry (the items a job or a direct import made) are bound to
variables named after their ids:
`db_1 = only(wait_job(import_file(s, "..."; ...); check = true).outputs)`, or
`grid_1 = only(wait_job(run_tool(s, "..."; ...); check = true)[3])` for a quick
tool, which returns `(ok, message, outputs)`. Later lines name the
item by the variable. So the script replays on the same project as well as on a
copy: each run makes new items. Items that existed before the first history
entry are named by their ids.

A job run again with `replace = true` becomes its command, then
`remove_item!(s, <variable>)` for each item it took out. Undo and redo of that
job become one `undo!(s)` or `redo!(s)` per script step.

Every history value is written as a Julia value (`repr`), never as code, and
comment text has its control characters replaced. So a crafted history file
cannot add code to the script. A history entry that cannot be written that way,
such as one with an unknown line type, throws an `ArgumentError` that names it.
"""
function script_text(s::Session)::String
    lock(s.lock) do
        outputs = lock(() -> Dict{String,Vector{String}}(j.id => copy(j.outputs) for j in s.jobs), s.jobs_lock)
        vars = Dict{String,String}()         # item id => variable name
        steps = Dict{String,Int}()           # undo step label => script steps, when not 1
        io = IOBuffer()
        println(io, "using JuliaMagCore")
        println(io, "s = open_session(", repr(s.project.folder), ")")
        println(io, "try")
        for (n, e) in enumerate(s.history)
            println(io, "# ", comment_text(e.time), " ", comment_text(e.command),
                    isempty(e.job) ? "" : " (job " * comment_text(e.job) * ")")
            if e.command in ("session.undo", "session.redo")
                step = get(e.args, "step", "")
                times = step isa AbstractString ? get(steps, step, 1) : 1
                foreach(_ -> println(io, e.command == "session.undo" ? "undo!(s)" : "redo!(s)"), 1:times)
                continue
            end
            line = try
                call_text(e, vars)
            catch err
                err isa Union{ArgumentError,KeyError,MethodError,InexactError} || rethrow()
                why = err isa ArgumentError ? err.msg : sprint(showerror, err)
                throw(ArgumentError("history entry $n ($(repr(e.command))) cannot be written as a script line: $why"))
            end
            # History lines from before entries kept their outputs: take them from the job.
            made = !isempty(e.outputs) || isempty(e.job) ? e.outputs : get(outputs, e.job, String[])
            if isempty(made)
                println(io, line)
            else
                names = String[var_name(id) for id in made]
                foreach((id, v) -> vars[id] = v, made, names)
                # A quick tool returns `(ok, message, outputs)`, not a job.
                quick = isempty(e.job) && is_tool_call(e.command, e.args) && !is_import(e.command, e.args) &&
                        !is_export(e.command, e.args)
                outs = quick ? "$line[3]" : "$line.outputs"
                println(io, length(names) == 1 ? "$(only(names)) = only($outs)" : "$(join(names, ", ")) = $outs")
            end
            for id in e.replaced
                println(io, "remove_item!(s, ", haskey(vars, id) ? vars[id] : repr(id), ")")
            end
            isempty(e.replaces) || (steps[job_step_label(e.command, e.job)] = 1 + length(e.replaced))
        end
        println(io, "finally")
        println(io, "    close_session!(s)")
        println(io, "end")
        return String(take!(io))
    end
end
