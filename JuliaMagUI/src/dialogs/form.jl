# The model of a tool, import or export dialog: what the user has set so far (spec 8.1,
# 8.2). The dialog (tool_dialog.jl) draws a `Form` with the widgets of widgets.jl. Every
# core call goes through the worker: the remembered settings and the defaults are read
# before the dialog opens, the check and the run happen when the user presses the button.

"What a form is for: a tool, an importer or an exporter."
const FormOwner = Union{Core.ToolSpec,Core.ImporterSpec,Core.ExporterSpec}

"""
    Form

What the user has set in a tool, import or export dialog.

- `owner`: the `ToolSpec`, `ImporterSpec` or `ExporterSpec` the dialog was built from.
- `inputs`: item ids by input name: a tool's inputs, or `"item"` for an export.
- `values`: the settings by key, in the types the core keeps.
- `texts`: what the user typed in number fields, so `"12."` stays while typing. An extent
  or point keeps one text per number, as `"key/1"`, `"key/2"`, ...
  A channel checklist set to None keeps `"none"` under its key.
- `errors`: the problem of each setting (or input, or `"path"`), as a sentence.
- `source`: where the values came from: `:defaults`, `:remembered` or `:rerun`.
- `path`: the file to import or to export to.
- `replace`: a run again takes the old job's outputs out of the project.
- `rerun_of`: the job this dialog runs again, or `nothing`.
"""
mutable struct Form
    owner::FormOwner
    inputs::Dict{String,String}
    values::Dict{String,Any}
    texts::Dict{String,String}
    errors::Dict{String,String}
    source::Symbol
    path::String
    replace::Bool
    rerun_of::Union{Nothing,Core.Job}
end

"The settings of a form's owner."
form_settings(f::Form) = f.owner.settings

"The items a form works on, as input name => kind: a tool's inputs, or the item of an export."
form_inputs(o::Core.ToolSpec) = o.inputs
form_inputs(::Core.ImporterSpec) = Pair{String,Core.ItemKind}[]
form_inputs(o::Core.ExporterSpec) = ["item" => o.kind]

"Does the owner run as a background job? Imports and exports always do."
runs_as_job(o::FormOwner) = !(o isa Core.ToolSpec) || o.mode == :job

"The name of the owner in title case: \"Channel Math\", \"Import Geosoft XYZ\", \"Export CSV\"."
owner_title(o::Core.ToolSpec) = title_case(o.name)
owner_title(o::Core.ImporterSpec) = "Import " * title_case(o.name)
owner_title(o::Core.ExporterSpec) = "Export " * title_case(o.name)

"The title of the form's owner (`owner_title`). A dialog that runs a job again adds \"Run Again: \"."
form_title(f::Form) = owner_title(f.owner)

"The setting of `key`, or `nothing`."
function find_setting(f::Form, key::AbstractString)
    list = form_settings(f)
    k = findfirst(st -> st.key == key, list)
    return k === nothing ? nothing : list[k]
end

"""
    is_drawn(form, key) -> Bool

Does the form show setting `key`? The setting exists and its `when` is met by the values.
"""
function is_drawn(f::Form, key::AbstractString)::Bool
    st = find_setting(f, key)
    st === nothing && return false
    return Core.is_active(form_settings(f), st, f.values)
end

# --- Numbers as text ---

"""
    number_text(x) -> String

A setting's number as the text of its field: `""` for `nothing`, whole floats without a
fraction (`25.0` is `"25"`), other floats in Julia's shortest form.
"""
number_text(::Nothing) = ""
number_text(x::Integer) = string(x)
number_text(x::AbstractFloat) = isinteger(x) && abs(x) < 1e15 ? string(Int(x)) : string(x)
number_text(x) = string(x)

"The number in `text`, or `nothing` when it is not one. Spaces around it are allowed."
parse_number(text::AbstractString) = tryparse(Float64, strip(text))

# The keys of `texts` that a setting's numbers use.
number_keys(st::Core.NumberSetting) = [st.key]
number_keys(st::Core.ExtentSetting) = ["$(st.key)/$k" for k in 1:4]
number_keys(st::Core.PointSetting) = ["$(st.key)/$k" for k in 1:2]
number_keys(::Core.SettingSpec) = String[]

"Fill `texts` from `values`: one text per number field. Other texts are cleared."
function set_texts!(f::Form)
    empty!(f.texts)
    for st in form_settings(f)
        keys = number_keys(st)
        isempty(keys) && continue
        v = get(f.values, st.key, nothing)
        if st isa Core.NumberSetting
            f.texts[st.key] = number_text(v)
        else
            for (k, key) in enumerate(keys)
                f.texts[key] = v isa AbstractVector && k <= length(v) ? number_text(v[k]) : ""
            end
        end
    end
    return f
end

# A number as the setting keeps it: an `Int` for a whole number setting, else a `Float64`.
setting_number(st::Core.NumberSetting, x::Float64) =
    st.integer && isfinite(x) && isinteger(x) && abs(x) <= 2.0^53 ? Int(x) : x

const TYPE_A_NUMBER = "Type a number."

# Read the number texts of setting `st` into `values`; a text that is no number is an error.
read_numbers!(f::Form, ::Core.SettingSpec, errors) = nothing

function read_numbers!(f::Form, st::Core.NumberSetting, errors)
    text = strip(get(f.texts, st.key, ""))
    if isempty(text)
        f.values[st.key] = nothing   # auto, or "must be set" from the core
        st.auto || (errors[st.key] = TYPE_A_NUMBER)
        return nothing
    end
    x = parse_number(text)
    x === nothing ? (errors[st.key] = TYPE_A_NUMBER) : (f.values[st.key] = setting_number(st, x))
    return nothing
end

function read_numbers!(f::Form, st::Union{Core.ExtentSetting,Core.PointSetting}, errors)
    texts = [strip(get(f.texts, k, "")) for k in number_keys(st)]
    if all(isempty, texts)
        f.values[st.key] = nothing
        return nothing
    end
    xs = parse_number.(texts)
    any(isnothing, xs) ? (errors[st.key] = TYPE_A_NUMBER) : (f.values[st.key] = Float64[x for x in xs])
    return nothing
end

# --- Checking ---

const NO_CHANNELS = "none"   # the text of a channel checklist set to None

"""
    check!(form, session) -> Bool

Check the form: read the number texts into `values` ("Type a number." for one that does
not parse), then ask the core for the problems of the settings and inputs that are used
(`setting_problems`, with the project of `session`). An export also needs a file.
Fills `form.errors` and returns whether it is empty. It calls the core, so the app calls
it on the worker, on a copy of the form (`copy_form`).
"""
function check!(f::Form, session)::Bool
    errors = Dict{String,String}()
    list = form_settings(f)
    for st in list
        Core.is_active(list, st, f.values) || continue
        read_numbers!(f, st, errors)
        if st isa Core.ChannelListSetting && get(f.texts, st.key, "") == NO_CHANNELS
            errors[st.key] = "Pick at least one channel."
        end
    end
    for (key, text) in core_problems(f, session)
        haskey(errors, key) || (errors[key] = text)
    end
    if f.owner isa Core.ExporterSpec && isempty(strip(f.path))
        errors["path"] = "Choose a file."
    end
    f.errors = errors
    return isempty(errors)
end

function core_problems(f::Form, session)
    o = f.owner
    o isa Core.ToolSpec && return Core.setting_problems(o, f.values; session, inputs = f.inputs)
    problems = Core.setting_problems(o, f.values; session)
    if o isa Core.ExporterSpec && isempty(get(f.inputs, "item", ""))
        pushfirst!(problems, "item" => "Choose a $(lowercase(string(KIND_WORDS[o.kind])))." )
    end
    return problems
end

const KIND_WORDS = Dict(Core.ITEM_DATABASE => "Database", Core.ITEM_GRID => "Grid", Core.ITEM_MAP => "Map")

"A copy of the form for the worker: the dicts are copied, the owner and job are shared."
copy_form(f::Form) = Form(f.owner, copy(f.inputs), deepcopy(f.values), copy(f.texts), copy(f.errors),
    f.source, f.path, f.replace, f.rerun_of)

# --- Opening ---

"""
    open_form(app, owner; item = nothing, args = nothing, path = "", values = Dict(),
              rerun_of = nothing)

Open the dialog of `owner` (a tool, importer or exporter). The worker reads the settings
first: a tool's `last_settings` in this project, or the defaults; then the dialog opens.
`args` (the args of a job, for Run Again) give the values instead; `rerun_of` is that job.
`values` go over them (such as the channel a menu was opened on).
Inputs default to `item` when it is of their kind, else to the current database or the
selected grid. `path` is the file to import.
"""
function open_form(app, owner::FormOwner; item::Union{Nothing,AbstractString} = nothing,
        args::Union{Nothing,AbstractDict} = nothing, path::AbstractString = "",
        values::AbstractDict = Dict{String,Any}(), rerun_of::Union{Nothing,Core.Job} = nothing)
    args === nothing && rerun_of !== nothing && (args = rerun_of.args)
    args = args === nothing ? nothing : Dict{String,Any}(String(k) => v for (k, v) in args)
    file = String(path)
    if isempty(file) && args !== nothing && owner isa Core.ImporterSpec
        p = get(args, "path", "")
        p isa AbstractString && (file = String(p))
    end
    remembered = owner isa Core.ToolSpec && args === nothing
    preset = Dict{String,Any}(String(k) => v for (k, v) in values)
    session = app.session
    submit!(app, "Open " * owner_title(owner), s -> begin
        defaults = Core.default_settings(owner)
        last = remembered ? Core.last_settings(s, owner.id) : nothing
        size = !isempty(file) && isfile(file) ? Int(filesize(file)) : -1
        (defaults, last, size)
    end; done = (app, r) -> begin
        app.session === session || return nothing   # the project changed meanwhile
        defaults, last, size = r
        f = build_form(app, owner, defaults, last; item, args, path = file, values = preset, rerun_of)
        push_dialog!(app, ToolDialog(app, f; file_size = size))
    end)
    return nothing
end

"""
    build_form(app, owner, defaults, remembered; item, args, path, values, rerun_of) -> Form

The form `open_form` opens, from what the worker read: the `defaults`, and the
`remembered` settings of a tool (or `nothing`). Reads only the snapshot.
"""
function build_form(app, owner::FormOwner, defaults::Dict{String,Any}, remembered;
        item = nothing, args = nothing, path::AbstractString = "",
        values::Dict{String,Any} = Dict{String,Any}(), rerun_of = nothing)::Form
    list = owner.settings
    vals = Dict{String,Any}(st.key => get(defaults, st.key, nothing) for st in list)
    source = :defaults
    if remembered !== nothing
        for st in list
            haskey(remembered, st.key) && (vals[st.key] = remembered[st.key])
        end
        vals != defaults && (source = :remembered)
    end
    if args !== nothing
        for st in list
            haskey(args, st.key) && (vals[st.key] = plain_value(st, args[st.key]))
        end
        rerun_of === nothing || (source = :rerun)
    end
    for st in list
        haskey(values, st.key) && (vals[st.key] = plain_value(st, values[st.key]))
    end
    inputs = Dict{String,String}()
    given = args === nothing ? nothing : get(args, "inputs", nothing)
    for (name, kind) in form_inputs(owner)
        id = given isa AbstractDict ? get(given, name, nothing) : nothing
        owner isa Core.ExporterSpec && args !== nothing && (id = get(args, "item", nothing))
        if !(id isa AbstractString)
            id = item !== nothing && item_kind(app, item) == kind ? item : default_item(app, kind)
        end
        inputs[name] = id === nothing ? "" : String(id)
    end
    file = String(path)
    if owner isa Core.ExporterSpec
        p = args === nothing ? nothing : get(args, "path", nothing)
        file = p isa AbstractString ? String(p) : ""   # "Browse..." picks it
    end
    f = Form(owner, inputs, vals, Dict{String,String}(), Dict{String,String}(), source, file,
        false, rerun_of)
    fix_channels!(f, app.snap)
    return set_texts!(f)
end

# A value from job args or a menu (plain JSON values) in the type the setting keeps.
plain_value(::Core.SettingSpec, v) = v isa Symbol ? String(v) : v
plain_value(::Core.ChannelListSetting, v::AbstractVector) = String[string(x) for x in v]
function plain_value(st::Core.NumberSetting, v)
    v isa Real && !(v isa Bool) || return v
    return setting_number(st, Float64(v))
end
plain_value(::Union{Core.ExtentSetting,Core.PointSetting}, v::AbstractVector) =
    all(x -> x isa Real, v) ? Float64[x for x in v] : v

# The kind of item `id` in the snapshot, or `nothing`.
function item_kind(app, id::AbstractString)
    k = findfirst(it -> it.id == id, snap_items(app))
    return k === nothing ? nothing : snap_items(app)[k].kind
end

# The file name of an export: the item's name with the exporter's extension.
export_name(app, e::Core.ExporterSpec, item::AbstractString) =
    (app.snap === nothing ? item : item_name(app.snap, item)) * e.extension

# --- Channels ---

"""
    channel_options(st, view) -> Vector{Pair{String,String}}

The channels of database `view` that setting `st` can take, as name => hint (role and
units, such as `"longitude, deg"`). Channels with one of the setting's roles come first;
array channels are left out unless the setting allows them.
"""
function channel_options(st::Union{Core.ChannelSetting,Core.ChannelListSetting}, view)
    view === nothing && return Pair{String,String}[]
    roles = st isa Core.ChannelSetting ? st.roles : Core.ChannelRole[]
    chans = [c for c in view.channels if st.allow_array || c.arraylen <= 1]
    first_ones = [c for c in chans if c.role in roles]
    ordered = vcat(first_ones, [c for c in chans if !(c.role in roles)])
    hint(c) = join(filter(!isempty, [role_tag(c.role), c.units]), ", ")
    return [c.name => hint(c) for c in ordered]
end

# The input that settings without an input of their own (lines, expressions) work on:
# the first database input.
function database_input(f::Form)::String
    for (name, kind) in form_inputs(f.owner)
        kind == Core.ITEM_DATABASE && return name
    end
    return "database"
end

# The database view of the input a setting reads its channels from, or `nothing`.
function input_view(f::Form, snap, input::AbstractString)
    snap === nothing && return nothing
    return get(snap.databases, get(f.inputs, input, ""), nothing)
end

"""
    fix_channels!(form, snap)

Give each channel setting that needs an existing channel one of the input database: keep
its channel when the database has it, else take the first one (a role match first).
"""
function fix_channels!(f::Form, snap)
    for st in form_settings(f)
        st isa Core.ChannelSetting && !st.allow_new || continue
        view = input_view(f, snap, st.input)
        view === nothing && continue
        names = first.(channel_options(st, view))
        get(f.values, st.key, "") in names && continue
        f.values[st.key] = isempty(names) ? "" : first(names)
    end
    return f
end

"The text of a channel checklist's button: \"All channels\", \"1 channel\", \"3 channels\"."
function channel_list_text(chosen::AbstractVector, total::Integer)::String
    isempty(chosen) && return "All channels"
    n = length(chosen)
    return n == 1 ? "1 channel" : "$n channels"
end

# --- Other options ---

"The labels of a lines setting: `All (N)`, `Selected (n)` and `Current`."
function lines_labels(view)::Vector{String}
    n = view === nothing ? 0 : length(view.lines)
    k = view === nothing ? 0 : count(l -> l.selected, view.lines)
    return ["All ($(fmt_int(n)))", "Selected ($(fmt_int(k)))", "Current"]
end

"The position pairs of database `view` as value => label, `\"Current pair\"` first."
function pair_options(view)::Vector{Pair{String,String}}
    out = ["" => "Current pair"]
    view === nothing && return out
    for q in view.pairs
        push!(out, "$(q.x),$(q.y)" => "$(q.x), $(q.y)")
    end
    return out
end

"The project's items of `kind` as id => name; `optional` puts `\"None\"` first."
function item_options(snap, kind::Core.ItemKind, optional::Bool)::Vector{Pair{String,String}}
    out = optional ? ["" => "None"] : Pair{String,String}[]
    snap === nothing && return out
    for it in snap.items
        it.kind == kind && push!(out, it.id => it.name)
    end
    return out
end

"""
    choice_style(st) -> Symbol

How a choice setting is drawn: `:segmented` with at most 3 choices whose labels are all
shorter than 14 characters, else `:combo`.
"""
choice_style(st::Core.ChoiceSetting)::Symbol =
    length(st.choices) <= 3 && all(l -> length(l) < 14, st.labels) ? :segmented : :combo

# --- Running ---

"""
    job_args(form) -> Dict{String,Any}

The args of the run the form makes, as the history and jobs keep them: the settings, with
the tool's inputs under `"inputs"`, the import file as `"path"`, or the export's `"item"`
and `"path"`.
"""
function job_args(f::Form)::Dict{String,Any}
    a = Dict{String,Any}(k => v for (k, v) in f.values)
    o = f.owner
    if o isa Core.ToolSpec
        isempty(f.inputs) || (a["inputs"] = Dict{String,Any}(k => v for (k, v) in f.inputs))
    elseif o isa Core.ImporterSpec
        a["path"] = f.path
    else
        a["item"] = get(f.inputs, "item", "")
        a["path"] = f.path
    end
    return a
end

"""
    run_form(s, form)

Run what the form says, on the worker: run the job again (`rerun!`), run the tool
(`run_tool`: a tuple for a quick tool, a `Job` for a job tool), import the file or export
the item. Returns what the core returned.
"""
function run_form(s::Core.Session, f::Form)
    o = f.owner
    kw = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in f.values)
    job = f.rerun_of
    job === nothing || return Core.rerun!(s, job; args = job_args(f),
        replace = f.replace && !(o isa Core.ExporterSpec))
    o isa Core.ToolSpec && return Core.run_tool(s, o.id; inputs = copy(f.inputs), kw...)
    o isa Core.ImporterSpec && return Core.import_file(s, f.path; kw...)
    return Core.export_file(s, f.inputs["item"], f.path; exporter = o.id, kw...)
end

"""
    reset!(app, form)

Set every setting back to its default; the inputs stay and the errors go. A tool's
remembered settings are forgotten too (`reset_settings!`, on the worker). Then the toast
"Settings reset to their defaults." shows.
"""
function reset!(app, f::Form)
    o = f.owner
    session = app.session
    submit!(app, "Reset " * owner_title(o), s -> begin
        o isa Core.ToolSpec && Core.reset_settings!(s, o.id)
        Core.default_settings(o)
    end; done = (app, defaults) -> begin
        app.session === session || return nothing
        f.values = Dict{String,Any}(st.key => get(defaults, st.key, nothing) for st in o.settings)
        empty!(f.errors)
        f.source = :defaults
        fix_channels!(f, app.snap)
        set_texts!(f)
        form_changed!(app, f)
        toast!(app, :info, "Settings reset to their defaults."; ms = 1800)
    end)
    return nothing
end

# --- The description ---

"""
    description_lines(form) -> Vector{Vector{Tuple{String,Symbol}}}

The text of the "Tool Description" box: the description the dialog was built from (id,
inputs, setting types) and the script call for the current values (`script_call`). Each
line is a list of `(text, colour)` parts; the colour is `:text`, `:dim` (comments),
`:green` (text in quotes) or `:accent` (the first word).
"""
function description_lines(f::Form)
    o = f.owner
    kind = o isa Core.ToolSpec ? "tool" : o isa Core.ImporterSpec ? "importer" : "exporter"
    article = kind == "tool" ? "A" : "An"
    out = String["# The description this dialog was built from. $article $kind is one Julia function plus this."]
    push!(out, kind * "(")
    push!(out, "    id = $(repr(o.id)),")
    if o isa Core.ToolSpec
        ins = join(("$(repr(n)) => $(kind_const(k))" for (n, k) in o.inputs), ", ")
        push!(out, "    inputs = [$ins],")
    elseif o isa Core.ImporterSpec
        push!(out, "    extensions = [$(join(repr.(o.extensions), ", "))],")
    else
        push!(out, "    extension = $(repr(o.extension)),")
        push!(out, "    kind = $(kind_const(o.kind)),")
    end
    push!(out, "    settings = [")
    for st in o.settings
        push!(out, "        " * setting_text(st) * ",")
    end
    push!(out, "    ],")
    o isa Core.ToolSpec && push!(out, "    mode = :$(o.mode),")
    push!(out, ")")
    push!(out, "# The script call for these settings:")
    call = try
        command = f.rerun_of === nothing ? o.id : f.rerun_of.command
        Core.script_call(command, job_args(f))
    catch e
        e isa InterruptException && rethrow()
        "# It cannot be written: " * safe_user_message(e)
    end
    append!(out, split(call, '\n'))
    return [code_parts(l) for l in out]
end

kind_const(k::Core.ItemKind) = string(Symbol(k))

function setting_text(st::Core.SettingSpec)::String
    extras = String[]
    st.advanced && push!(extras, "advanced = true")
    st.when === nothing || push!(extras, "when = $(repr(first(st.when))) => $(repr(last(st.when)))")
    rest = isempty(extras) ? "" : "; " * join(extras, ", ")
    return "$(nameof(typeof(st)))($(repr(st.key)), $(repr(st.label))$rest)"
end

# Split a line of code into coloured parts: a comment, text in quotes, the first word.
function code_parts(line::AbstractString)::Vector{Tuple{String,Symbol}}
    l = String(line)
    startswith(lstrip(l), "#") && return [(l, :dim)]
    parts = Tuple{String,Symbol}[]
    for word in ("tool", "importer", "exporter")
        if startswith(l, word * "(")
            push!(parts, (word, :accent))
            l = l[ncodeunits(word)+1:end]
            break
        end
    end
    i = firstindex(l)
    buf = IOBuffer()
    quoted = false
    while i <= lastindex(l)
        c = l[i]
        if c == '"' && !quoted
            s = String(take!(buf))
            isempty(s) || push!(parts, (s, :text))
            quoted = true
            print(buf, c)
        elseif c == '"' && quoted
            print(buf, c)
            push!(parts, (String(take!(buf)), :green))
            quoted = false
        elseif c == '\\' && quoted && i < lastindex(l)
            print(buf, c)
            i = nextind(l, i)
            print(buf, l[i])
        else
            print(buf, c)
        end
        i = nextind(l, i)
    end
    s = String(take!(buf))
    isempty(s) || push!(parts, (s, quoted ? :green : :text))
    return parts
end
