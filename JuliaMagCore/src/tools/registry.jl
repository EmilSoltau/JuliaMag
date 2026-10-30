# Tools (spec 8.1, 8.2). A tool is a Julia function plus a plain description.
# The UI builds ribbon buttons, settings dialogs, command search and script
# entries from the descriptions, so adding a tool needs no UI code.
# Tools from other packages register here too. Registering an id again
# replaces the old tool, so a reloaded package updates its tools.

"""
    Place(tab, group; size = :big, order = 0)

Where a tool shows in the ribbon: a tab and a group on it. `size` is `:big` (a
big button) or `:small` (a small one, three to a column). `order` sorts the
buttons of a group: lower comes first, and equal ones keep the order of registration.
"""
struct Place
    tab::String
    group::String
    size::Symbol
    order::Int
    function Place(tab, group; size::Symbol = :big, order::Integer = 0)
        size in (:big, :small) || throw(ArgumentError("a place has size :big or :small, not :$size"))
        return new(String(tab), String(group), size, Int(order))
    end
end

"""
    ToolSpec(id, name, help, icon, places, inputs, settings, mode, run)

One tool.

- `id` is the command name in the history, such as `"dbtools.channel_math"`.
- `places` are the ribbon places of its button. A tool with none is still
  found by command search and scripts.
- `inputs` name the items it works on, such as `"database" => ITEM_DATABASE`.
  `run_tool` gets them as item ids.
- `mode` is `:quick` (runs at once, for short work) or `:job` (runs as a
  background job with progress and cancel).
- `run(s, inputs::Dict{String,String}, settings::Dict{String,Any}, progress, report)`
  returns the new `ProjectItem`s it made, or `nothing`. `report` is an `IO` for
  text the user reads. A job tool may return items it has not added; the job adds
  them. A quick tool adds its own items and pushes its own undo steps.
  It throws `ToolError` for problems the user should read.
"""
struct ToolSpec
    id::String
    name::String
    help::String
    icon::String
    places::Vector{Place}
    inputs::Vector{Pair{String,ItemKind}}
    settings::Vector{SettingSpec}
    mode::Symbol
    run::Function
    function ToolSpec(id, name, help, icon, places, inputs, settings, mode::Symbol, run::Function)
        isempty(id) && throw(ArgumentError("a tool needs an id"))
        mode in (:quick, :job) || throw(ArgumentError("tool \"$id\": mode must be :quick or :job, not :$mode"))
        check_setting_keys(settings, "tool \"$id\"")
        check_when(settings, "tool \"$id\"")
        names = first.(inputs)
        allunique(names) || throw(ArgumentError("tool \"$id\" has two inputs with the same name"))
        for st in settings
            if st isa Union{ChannelSetting,ChannelListSetting,PairSetting} && !(st.input in names)
                throw(ArgumentError("tool \"$id\": setting \"$(st.key)\" uses input \"$(st.input)\", which the tool does not have"))
            end
        end
        return new(String(id), String(name), String(help), String(icon), places, inputs, settings, mode, run)
    end
end

const TOOLS = ToolSpec[]
const TOOLS_LOCK = ReentrantLock()

"""
    register_tool!(spec)

Add a tool, or replace the one with the same id. Safe from any thread.
A replaced tool keeps its place in the list.
"""
function register_tool!(spec::ToolSpec)
    lock(TOOLS_LOCK) do
        k = findfirst(t -> t.id == spec.id, TOOLS)
        k === nothing ? push!(TOOLS, spec) : (TOOLS[k] = spec)
    end
    return spec
end

"Take a tool out of the list. Returns false when there was none with that id."
function unregister_tool!(id::AbstractString)::Bool
    lock(TOOLS_LOCK) do
        k = findfirst(t -> t.id == id, TOOLS)
        k === nothing && return false
        deleteat!(TOOLS, k)
        return true
    end
end

"All tools, in the order they were registered."
tools()::Vector{ToolSpec} = lock(() -> copy(TOOLS), TOOLS_LOCK)

"The tool with this id, or `nothing`."
function find_tool(id::AbstractString)::Union{Nothing,ToolSpec}
    lock(TOOLS_LOCK) do
        k = findfirst(t -> t.id == id, TOOLS)
        return k === nothing ? nothing : TOOLS[k]
    end
end

"The tool with this id. Throws `ArgumentError` when there is none."
function tool(id::AbstractString)::ToolSpec
    t = find_tool(id)
    t === nothing && throw(ArgumentError("there is no tool \"$id\""))
    return t
end

"The ribbon tabs named by any tool, in first-seen order."
function tabs()::Vector{String}
    out = String[]
    for t in tools(), p in t.places
        p.tab in out || push!(out, p.tab)
    end
    return out
end

"""
The default value of each setting of the tool, by key. Expression, channel and
file settings without a tool default are empty and must be set before a run.
"""
default_settings(spec::ToolSpec)::Dict{String,Any} = default_settings(spec.settings)

"""
    validate(spec, settings; session = nothing)::Vector{String}

The problems with `settings`, as plain sentences such as `"Factor must be at least 0."`.
Empty means the settings are fine. A missing setting takes its default.
With a `session`, an `ItemSetting` must name an item of its kind in the project.
"""
validate(spec::ToolSpec, settings::AbstractDict; session::Union{Nothing,Session} = nothing)::Vector{String} =
    last.(setting_problems(spec, settings; session))

"""
    setting_problems(spec, values; session = nothing, inputs = nothing)::Vector{Pair{String,String}}

The problems with `values`, one pair for each, as `key => sentence`, in setting
order. `validate` returns the sentences only. A setting that is not used (see
`is_active`) is skipped. A key that is not a setting is a problem under its own key.

For a tool, the inputs are checked first when they are given, as `inputs` or as
`values["inputs"]`; an input problem has the input's name as its key.
"""
function setting_problems(spec::ToolSpec, values::AbstractDict; session::Union{Nothing,Session} = nothing,
                          inputs::Union{Nothing,AbstractDict} = nothing)::Vector{Pair{String,String}}
    given = get(values, "inputs", nothing)
    ins = inputs !== nothing ? inputs : given isa AbstractDict ? given : nothing
    rest = ins === nothing ? values : Dict{String,Any}(String(k) => v for (k, v) in values if k != "inputs")
    own = ins === nothing ? Pair{String,String}[] : input_problem_pairs(spec, ins)
    return vcat(own, settings_problems(spec.settings, rest, spec.name; session))
end

# ---- remembered settings ---------------------------------------------------

# The remembered settings live in `s.remembered` and are saved in
# `project.jmag.json` under `settings.tools`, one object per tool id.

"Write `s.remembered` into the project settings and save. A save failure is a session warning."
function save_remembered!(s::Session)
    p = s.project
    p.settings["tools"] = Dict{String,Any}(id => copy(v) for (id, v) in s.remembered)
    try
        save_project(p)
    catch e
        e isa InterruptException && rethrow()
        session_warning!(s, "the tool settings could not be saved: $(sprint(showerror, e))")
    end
    return nothing
end

function remember_settings!(s::Session, id::String, values::Dict{String,Any})
    lock(s.lock) do
        s.remembered[id] = copy(values)
        save_remembered!(s)
    end
    return nothing
end

"""
    last_settings(s, id)::Dict{String,Any}

The settings the tool ran with last in this project, else its defaults.
A remembered value that does not fit the tool now (the tool changed) is
replaced by the default. Throws `ArgumentError` for an unknown tool.
"""
function last_settings(s::Session, id::AbstractString)::Dict{String,Any}
    spec = tool(id)
    out = default_settings(spec)
    rem = lock(() -> copy(get(s.remembered, spec.id, Dict{String,Any}())), s.lock)
    for st in spec.settings
        haskey(rem, st.key) || continue
        v = setting_value(st, rem[st.key])
        setting_problem(st, v) === nothing && (out[st.key] = v)
    end
    return out
end

"Forget the remembered settings of a tool, so it starts from its defaults again."
function reset_settings!(s::Session, id::AbstractString)
    lock(s.lock) do
        haskey(s.remembered, id) || return nothing
        delete!(s.remembered, String(id))
        save_remembered!(s)
    end
    return nothing
end

# ---- running ---------------------------------------------------------------

"The problems with the inputs: each input of the tool needs an item id, and no others are allowed."
function input_problems(spec::ToolSpec, inputs::AbstractDict)::Vector{String}
    return last.(input_problem_pairs(spec, inputs))
end

"`input_problems` as `input name => sentence`."
function input_problem_pairs(spec::ToolSpec, inputs::AbstractDict)::Vector{Pair{String,String}}
    problems = Pair{String,String}[]
    for (name, kind) in spec.inputs
        v = get(inputs, name, "")
        (v isa AbstractString && !isempty(v)) ||
            push!(problems, name => "$(spec.name) needs a $(KIND_NAMES[kind]) as input \"$name\".")
    end
    names = Set(first.(spec.inputs))
    for k in sort!([String(k) for k in keys(inputs)])
        k in names || push!(problems, k => "$(spec.name) has no input \"$k\".")
    end
    return problems
end

"The history args of a tool run: the settings, and the inputs under `\"inputs\"` when there are any."
function tool_args(values::Dict{String,Any}, inputs::Dict{String,String})::Dict{String,Any}
    a = copy(values)
    isempty(inputs) || (a["inputs"] = Dict{String,Any}(inputs))
    return a
end

"The work function of a job tool, for `start_job!`."
tool_work(s::Session, spec::ToolSpec, inputs::Dict{String,String}, values::Dict{String,Any}) =
    (progress::Progress, io::IO) -> job_outputs(spec.run(s, copy(inputs), copy(values), progress, io))

"The message the user reads for an error of a quick tool."
function failure_message(e)::String
    e isa ToolError && return e.msg
    e isa ItemBusyError && return "$(e.item) is busy: $(e.reason)."
    e isa ProtectedError && return "Channel $(e.channel) is protected and cannot be edited."
    text = try
        sprint(showerror, e)
    catch
        string(typeof(e))
    end
    return "Tool failed: " * first(text, 10_000)
end

"""
    run_tool(s, id; inputs = Dict(), settings...)

Run a tool. The given settings go over the remembered ones (see `last_settings`).
Inputs are item ids by input name, such as `inputs = Dict("database" => "db-1")`.

The settings are checked first. With problems, nothing runs and the result is
`(false, <the problems>, nothing)`, and nothing is remembered.

- A `:quick` tool runs now and returns `(ok, message, outputs)`, where
  `outputs` are the ids of the items it made, as in `Job.outputs`. Nothing is
  thrown: a `ToolError` gives its own message, other errors give
  `"Tool failed: <message>"`. A run that worked is recorded in the history,
  and only then are its settings remembered.
- On a closed session (see `isopen`) nothing runs and the result is
  `(false, <the SessionClosedError message>, nothing)`.
- A `:job` tool returns the `Job` at once. Its settings are remembered when the
  job starts. The job records itself in the history when it is done.
"""
function run_tool(s::Session, id::AbstractString; inputs::AbstractDict = Dict{String,String}(), kwargs...)
    isopen(s) || return (false, sprint(showerror, SessionClosedError(s.project.folder)), nothing)
    spec = find_tool(id)
    spec === nothing && return (false, "There is no tool \"$id\".", nothing)
    values = last_settings(s, spec.id)
    for (k, v) in kwargs
        key = String(k)
        st = findfirst(x -> x.key == key, spec.settings)
        values[key] = st === nothing ? plain_arg(v) : setting_value(spec.settings[st], plain_arg(v))
    end
    problems = vcat(input_problems(spec, inputs), validate(spec, values; session = s))
    isempty(problems) || return (false, join(problems, " "), nothing)
    values = deactivate_settings(spec.settings, values)
    ins = Dict{String,String}(String(k) => String(v) for (k, v) in inputs)
    args = tool_args(values, ins)
    if spec.mode == :job
        remember_settings!(s, spec.id, values)
        try
            return start_job!(s, spec.id, args, tool_work(s, spec, ins, values))
        catch e
            e isa SessionClosedError || rethrow()
            return (false, sprint(showerror, e), nothing)
        end
    end
    return run_quick(s, spec, ins, values, args)
end

function run_quick(s::Session, spec::ToolSpec, ins::Dict{String,String}, values::Dict{String,Any},
                   args::Dict{String,Any})
    report = IOBuffer()
    outputs = try
        job_outputs(spec.run(s, copy(ins), copy(values), NO_PROGRESS, report))
    catch e
        e isa InterruptException && rethrow()
        return (false, failure_message(e), nothing)
    end
    remember_settings!(s, spec.id, values)
    ids = String[it.id for it in outputs]
    try
        record!(s, spec.id, args; outputs = ids)
    catch e
        e isa InterruptException && rethrow()
        session_warning!(s, "the run of $(spec.id) could not be recorded: $(sprint(showerror, e))")
    end
    text = strip(String(take!(report)))
    return (true, isempty(text) ? "$(spec.name) is done." : String(text), ids)
end

"""
The work to run a job tool again with history args `a` (see `rerun!`).
Bad args give work that throws, so the new job fails with the problems.
"""
function tool_rerun_work(s::Session, spec::ToolSpec, a::Dict{String,Any})::Function
    raw = get(a, "inputs", Dict{String,Any}())
    inputs = raw isa AbstractDict ? raw : Dict{String,Any}()
    values = default_settings(spec)
    for (k, v) in a
        k == "inputs" && continue
        st = findfirst(x -> x.key == k, spec.settings)
        values[k] = st === nothing ? v : setting_value(spec.settings[st], v)
    end
    values = deactivate_settings(spec.settings, values)
    problems = vcat(input_problems(spec, inputs), validate(spec, values; session = s))
    isempty(problems) || return (_, _) -> throw(ToolError(join(problems, " ")))
    ins = Dict{String,String}(String(k) => String(v) for (k, v) in inputs)
    return tool_work(s, spec, ins, values)
end
