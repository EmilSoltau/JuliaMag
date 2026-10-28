# Setting types of tools and importers (spec 8.1).
# A setting is plain data: the UI builds its dialog from it, and `validate`
# checks a value against it. Values are plain too (numbers, text, booleans,
# `nothing` and vectors), so they go into JSON and into the history as they are.

"""
One setting of a tool or importer. Every setting type has the fields
`key`, `label`, `help` (a sentence for the dialog) and `advanced`
(true puts it under "Advanced" in the dialog), and a `default` value.
"""
abstract type SettingSpec end

"""
A problem the user should read, thrown by a tool or an importer for bad
settings or data. `run_tool` and failed jobs show only `msg`.
"""
struct ToolError <: Exception
    msg::String
end

Base.showerror(io::IO, e::ToolError) = print(io, e.msg)

"""
    NumberSetting(key, label; default, min = -Inf, max = Inf, auto = false, help = "", advanced = false)

A number. With `auto = true` the value may be `nothing`, which means
"blank: the tool works out the value". The value is a `Float64`.
`default = nothing` without `auto` means the user must type a number.
"""
struct NumberSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::Union{Nothing,Float64}
    min::Float64
    max::Float64
    auto::Bool
    function NumberSetting(key, label; default, min::Real = -Inf, max::Real = Inf, auto::Bool = false,
                           help = "", advanced::Bool = false)
        min <= max || throw(ArgumentError("setting \"$key\": min is above max"))
        d = default === nothing ? nothing : Float64(default)
        return new(String(key), String(label), String(help), advanced, d, Float64(min), Float64(max), auto)
    end
end

"Free text. The value is a `String`; blank is allowed."
struct TextSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::String
    TextSetting(key, label; default = "", help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String(default))
end

"A Julia expression, such as `MAG_IGRF = MAG - IGRF`. The value is a `String` that must parse."
struct ExprSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::String
    ExprSetting(key, label; default = "", help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String(default))
end

"""
    ChoiceSetting(key, label, choices; default = first(choices), help = "", advanced = false)

One of a fixed list of words. The value is a `String` from `choices`.
"""
struct ChoiceSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    choices::Vector{String}
    default::String
    function ChoiceSetting(key, label, choices::AbstractVector{<:AbstractString};
                           default = isempty(choices) ? "" : first(choices), help = "", advanced::Bool = false)
        isempty(choices) && throw(ArgumentError("setting \"$key\": a choice needs at least one choice"))
        default in choices || throw(ArgumentError("setting \"$key\": the default \"$default\" is not a choice"))
        return new(String(key), String(label), String(help), advanced, String[c for c in choices], String(default))
    end
end

"True or false."
struct BoolSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::Bool
    BoolSetting(key, label; default::Bool = false, help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, default)
end

"""
    FileSetting(key, label; extensions = String[], save = false, default = "", help = "", advanced = false)

A file path. `extensions` (lower case, with the dot, such as `".xyz"`) limit the
file types; empty means any. `save = true` means a file to write, not to read.
"""
struct FileSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    extensions::Vector{String}
    save::Bool
    default::String
    FileSetting(key, label; extensions::AbstractVector{<:AbstractString} = String[], save::Bool = false,
                default = "", help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String[lowercase(e) for e in extensions],
            save, String(default))
end

"""
    ChannelSetting(key, label; input = "database", roles = ChannelRole[], allow_array = false,
                   allow_new = false, default = "", help = "", advanced = false)

A channel name of the database given as tool input `input`. `roles` suggest
channels to the UI; `allow_array` allows array channels; `allow_new` allows a
name that does not exist yet (an output channel). The value is a `String`.
"""
struct ChannelSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    input::String
    roles::Vector{ChannelRole}
    allow_array::Bool
    allow_new::Bool
    default::String
    ChannelSetting(key, label; input = "database", roles::AbstractVector{ChannelRole} = ChannelRole[],
                   allow_array::Bool = false, allow_new::Bool = false, default = "", help = "",
                   advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String(input), collect(ChannelRole, roles),
            allow_array, allow_new, String(default))
end

"The values of a `LinesSetting`."
const LINES_CHOICES = ("all", "selected", "current")

"Which lines to work on: `\"all\"`, `\"selected\"` or `\"current\"`."
struct LinesSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::String
    function LinesSetting(key, label; default = "all", help = "", advanced::Bool = false)
        default in LINES_CHOICES || throw(ArgumentError("setting \"$key\": the default \"$default\" is not all, selected or current"))
        return new(String(key), String(label), String(help), advanced, String(default))
    end
end

"A coordinate system code, such as `\"EPSG:7855\"`. Blank means unknown."
struct CRSSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::String
    CRSSetting(key, label; default = "", help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String(default))
end

"A position pair of the input database, such as `\"X,Y\"`. Blank means the current pair."
struct PairSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::String
    PairSetting(key, label; default = "", help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String(default))
end

"An area: `[west, south, east, north]`, or `nothing` for the whole data."
struct ExtentSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::Union{Nothing,Vector{Float64}}
    ExtentSetting(key, label; default = nothing, help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced,
            default === nothing ? nothing : collect(Float64, default))
end

"A point: `[x, y]`, or `nothing` when not set."
struct PointSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::Union{Nothing,Vector{Float64}}
    PointSetting(key, label; default = nothing, help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced,
            default === nothing ? nothing : collect(Float64, default))
end

# ---- values ----------------------------------------------------------------

"The default value of a setting. Vectors are copied, so callers may change them."
setting_default(st::SettingSpec) = st.default
function setting_default(st::Union{ExtentSetting,PointSetting})
    d = st.default
    return d === nothing ? nothing : copy(d)
end

"The defaults of a list of settings, by key."
default_settings(list::AbstractVector{<:SettingSpec})::Dict{String,Any} =
    Dict{String,Any}(st.key => setting_default(st) for st in list)

"""
    setting_value(st, x)

Bring a value to the type the setting keeps: numbers to `Float64`, symbols and
other text to `String`, vectors of numbers to `Vector{Float64}`.
A value that does not fit is returned as it is, for `setting_problem` to report.
"""
setting_value(::SettingSpec, x) = x
setting_value(::SettingSpec, x::Union{AbstractString,Symbol}) = String(x)
setting_value(::NumberSetting, x::Real) = x isa Bool ? x : Float64(x)
function setting_value(::Union{ExtentSetting,PointSetting}, x::AbstractVector)
    all(v -> v isa Real && !(v isa Bool), x) || return x
    return Float64[v for v in x]
end

# A number as short text: 0.0 is "0", 2.5 is "2.5".
numtext(x::Float64) = isinteger(x) && abs(x) < 1e15 ? string(Int(x)) : string(x)

istext(x) = x isa AbstractString

"""
    setting_problem(st, x)::Union{Nothing,String}

What is wrong with value `x`, as a plain sentence, or `nothing` when it is fine.
"""
function setting_problem(st::NumberSetting, x)::Union{Nothing,String}
    if x === nothing
        return st.auto ? nothing : "$(st.label) must be set."
    end
    (x isa Real && !(x isa Bool)) || return "$(st.label) must be a number."
    isfinite(x) || return "$(st.label) must be a finite number."
    x < st.min && return "$(st.label) must be at least $(numtext(st.min))."
    x > st.max && return "$(st.label) must be at most $(numtext(st.max))."
    return nothing
end

setting_problem(st::Union{TextSetting,CRSSetting,PairSetting}, x)::Union{Nothing,String} =
    istext(x) ? nothing : "$(st.label) must be text."

function setting_problem(st::ExprSetting, x)::Union{Nothing,String}
    istext(x) || return "$(st.label) must be text."
    isempty(strip(x)) && return "$(st.label) is empty."
    ex = Meta.parseall(String(x))
    for a in (ex isa Expr ? ex.args : Any[])
        if a isa Expr && a.head in (:error, :incomplete)
            msg = isempty(a.args) ? "" : string(a.args[1])
            return "$(st.label) is not a valid Julia expression: $(first(split(msg, '\n')))"
        end
    end
    return nothing
end

function setting_problem(st::ChoiceSetting, x)::Union{Nothing,String}
    (istext(x) && x in st.choices) && return nothing
    return "$(st.label) must be one of: $(join(st.choices, ", "))."
end

setting_problem(st::LinesSetting, x)::Union{Nothing,String} =
    (istext(x) && x in LINES_CHOICES) ? nothing : "$(st.label) must be all, selected or current."

setting_problem(st::BoolSetting, x)::Union{Nothing,String} =
    x isa Bool ? nothing : "$(st.label) must be true or false."

function setting_problem(st::FileSetting, x)::Union{Nothing,String}
    istext(x) || return "$(st.label) must be a file path."
    isempty(x) && return "$(st.label) is not set."
    if !isempty(st.extensions) && !(lowercase(file_extension(x)) in st.extensions)
        return "$(st.label) must be a $(join(st.extensions, " or ")) file."
    end
    return nothing
end

function setting_problem(st::ChannelSetting, x)::Union{Nothing,String}
    istext(x) || return "$(st.label) must be a channel name."
    isempty(x) && return "$(st.label) is not set."
    return nothing
end

finite_numbers(x, n) = x isa AbstractVector && length(x) == n && all(v -> v isa Real && !(v isa Bool) && isfinite(v), x)

function setting_problem(st::ExtentSetting, x)::Union{Nothing,String}
    x === nothing && return nothing
    finite_numbers(x, 4) || return "$(st.label) must be four numbers: west, south, east and north."
    (x[1] < x[3] && x[2] < x[4]) || return "$(st.label) must have west below east and south below north."
    return nothing
end

setting_problem(st::PointSetting, x)::Union{Nothing,String} =
    (x === nothing || finite_numbers(x, 2)) ? nothing : "$(st.label) must be two numbers: x and y."

"""
    validate_settings(list, values, owner)::Vector{String}

Check `values` against the settings in `list`. A missing key takes its default.
A key that is not a setting is a problem too; `owner` names the tool in that message.
"""
function validate_settings(list::AbstractVector{<:SettingSpec}, values::AbstractDict, owner::AbstractString)::Vector{String}
    given = Dict{String,Any}(String(k) => v for (k, v) in values)
    problems = String[]
    for st in list
        v = haskey(given, st.key) ? setting_value(st, given[st.key]) : setting_default(st)
        p = setting_problem(st, v)
        p === nothing || push!(problems, p)
    end
    known = Set(st.key for st in list)
    for k in sort!(collect(keys(given)))
        k in known || push!(problems, "$owner has no setting \"$k\".")
    end
    return problems
end

"Check that the setting keys are not empty, not reserved and not used twice."
function check_setting_keys(list::AbstractVector{<:SettingSpec}, owner::AbstractString)
    seen = Set{String}()
    for st in list
        isempty(st.key) && throw(ArgumentError("$owner has a setting with an empty key"))
        st.key == "inputs" && throw(ArgumentError("$owner: the setting key \"inputs\" is reserved"))
        st.key in seen && throw(ArgumentError("$owner has two settings with key \"$(st.key)\""))
        push!(seen, st.key)
    end
    return nothing
end
