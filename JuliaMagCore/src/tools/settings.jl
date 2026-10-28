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
    NumberSetting(key, label; default, min = -Inf, max = Inf, auto = false, integer = false,
                  unit = "", help = "", advanced = false)

A number. With `auto = true` the value may be `nothing`, which means
"blank: the tool works out the value". The value is a `Float64`, or an `Int`
with `integer = true` (then it must be a whole number). `unit` is shown next
to the box, such as `"m"` or `"nT"`.
`default = nothing` without `auto` means the user must type a number.
"""
struct NumberSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    default::Union{Nothing,Int,Float64}
    min::Float64
    max::Float64
    auto::Bool
    integer::Bool
    unit::String
    function NumberSetting(key, label; default, min::Real = -Inf, max::Real = Inf, auto::Bool = false,
                           integer::Bool = false, unit = "", help = "", advanced::Bool = false)
        min <= max || throw(ArgumentError("setting \"$key\": min is above max"))
        d = default === nothing ? nothing : number_value(integer, default)
        integer && d isa Float64 && throw(ArgumentError("setting \"$key\": the default of a whole number setting must be whole"))
        return new(String(key), String(label), String(help), advanced, d, Float64(min), Float64(max), auto,
                   integer, String(unit))
    end
end

# Largest whole number that a Float64 holds exactly.
const MAX_EXACT_INT = 2.0^53

# A number as the setting keeps it: an `Int` for a whole number setting when the
# value is whole, else a `Float64`.
function number_value(integer::Bool, x::Real)::Union{Int,Float64}
    f = Float64(x)
    return integer && isfinite(f) && isinteger(f) && abs(f) <= MAX_EXACT_INT ? Int(f) : f
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

"""
An expression over channels, such as `MAG_IGRF = MAG - IGRF`. The value is a `String` that must parse.
Only the tokens of Channel Math are allowed, within size and nesting limits (see `expr_text_problem`).
"""
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
    ChoiceSetting(key, label, choices; default = first(choices), labels = choices, help = "", advanced = false)

One of a fixed list of words. The value is a `String` from `choices`.
`labels` are the words the dialog shows for the choices, in the same order.
"""
struct ChoiceSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    choices::Vector{String}
    labels::Vector{String}
    default::String
    function ChoiceSetting(key, label, choices::AbstractVector{<:AbstractString};
                           default = isempty(choices) ? "" : first(choices),
                           labels::AbstractVector{<:AbstractString} = choices, help = "", advanced::Bool = false)
        isempty(choices) && throw(ArgumentError("setting \"$key\": a choice needs at least one choice"))
        default in choices || throw(ArgumentError("setting \"$key\": the default \"$default\" is not a choice"))
        length(labels) == length(choices) ||
            throw(ArgumentError("setting \"$key\": there must be one label for each choice"))
        return new(String(key), String(label), String(help), advanced, String[c for c in choices],
                   String[l for l in labels], String(default))
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

"""
    ChannelListSetting(key, label; input = "database", allow_array = true, default = String[],
                       help = "", advanced = false)

A list of channel names of the database given as tool input `input`.
An empty list means all channels. `allow_array` allows array channels.
The value is a `Vector{String}`.
"""
struct ChannelListSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    input::String
    allow_array::Bool
    default::Vector{String}
    ChannelListSetting(key, label; input = "database", allow_array::Bool = true,
                       default::AbstractVector{<:AbstractString} = String[], help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String(input), allow_array,
            String[d for d in default])
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

"""
    PairSetting(key, label; input = "database", default = "", help = "", advanced = false)

A position pair of the database given as tool input `input`, such as `\"X,Y\"`.
Blank means the current pair.
"""
struct PairSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    input::String
    default::String
    PairSetting(key, label; input = "database", default = "", help = "", advanced::Bool = false) =
        new(String(key), String(label), String(help), advanced, String(input), String(default))
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
setting_default(st::ChannelListSetting) = copy(st.default)
function setting_default(st::Union{ExtentSetting,PointSetting})
    d = st.default
    return d === nothing ? nothing : copy(d)
end

"""
The defaults of a list of settings, by key. Expression, channel and file
settings default to empty text unless the tool gives a default; such a value
is a problem for `validate`, so the user must set it before the tool runs.
"""
default_settings(list::AbstractVector{<:SettingSpec})::Dict{String,Any} =
    Dict{String,Any}(st.key => setting_default(st) for st in list)

"""
    setting_value(st, x)

Bring a value to the type the setting keeps: numbers to `Float64` (`Int` for a
whole number setting), symbols and
other text to `String`, vectors of numbers to `Vector{Float64}`.
A value that does not fit is returned as it is, for `setting_problem` to report.
"""
setting_value(::SettingSpec, x) = x
setting_value(::SettingSpec, x::Union{AbstractString,Symbol}) = String(x)
setting_value(st::NumberSetting, x::Real) = x isa Bool ? x : number_value(st.integer, x)
function setting_value(::ChannelListSetting, x::AbstractVector)
    all(v -> v isa Union{AbstractString,Symbol}, x) || return x
    return String[String(v) for v in x]
end
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
    st.integer && !(x isa Integer) && return "$(st.label) must be a whole number."
    x < st.min && return "$(st.label) must be at least $(numtext(st.min))."
    x > st.max && return "$(st.label) must be at most $(numtext(st.max))."
    return nothing
end

setting_problem(st::Union{TextSetting,CRSSetting,PairSetting}, x)::Union{Nothing,String} =
    istext(x) ? nothing : "$(st.label) must be text."

# ---- expression text -------------------------------------------------------
#
# Expression text (`ExprSetting`, Channel Math) is checked token by token before
# it is parsed. The Julia parser is recursive, and some text nests deeply
# without any brackets (`return return ...`, `begin begin ... end end`, `- - ...`,
# `a^a^...`). Nesting deep enough overflows its stack, which can leave the
# process broken. So the check is a whitelist. Allowed are only:
#
# - names that are not Julia keywords, and the constants of Channel Math;
# - number literals (decimal, with a fraction or exponent, or 0x, 0b, 0o);
# - names in backticks (their text is not scanned: the parser does not look inside);
# - the operators `+ - * / ^ < > <= >= == != & | = .` (`.` for dotted forms);
# - round brackets, commas, white space, and `#` comments to the end of the line.
#
# And within that: at most 10,000 characters, round brackets nested at most 200
# deep, and at most 1,000 operator characters. Anything else is refused with a
# message that names it.
#
# What this guarantees: text that passes reaches the parser only as names,
# numbers, those operators, commas and round brackets. The deepest nesting the
# parser can then build is 200 brackets plus 1,000 operators. That was tested not
# to overflow the stack on Julia 1.12 with the default stack size; it is a tested
# margin, not a proof for every Julia version. Code that walks the parsed tree
# must still limit its own depth (Channel Math refuses trees over 200 deep).

const MAX_EXPR_CHARS = 10_000
const MAX_EXPR_BRACKETS = 200
const MAX_EXPR_OPERATORS = 1000

"Words of Julia syntax. They may not appear as bare names in an expression."
const EXPR_KEYWORDS = Set(["begin", "end", "let", "if", "elseif", "else", "return", "local", "global", "const",
    "quote", "try", "catch", "finally", "for", "while", "function", "macro", "module", "baremodule", "struct",
    "mutable", "abstract", "primitive", "type", "do", "using", "import", "export", "outer", "where", "in",
    "isa", "true", "false", "break", "continue"])

"Operators of two characters, tried before those of one."
const EXPR_OPERATORS_2 = ("<=", ">=", "==", "!=")
const EXPR_OPERATORS_1 = "+-*/^<>=&|."

not_allowed(tok::AbstractString) = "\"$tok\" is not allowed in a channel expression."

"""
    expr_text_problem(text, what)::Union{Nothing,String}

What makes expression text unsafe to parse, as a sentence, or `nothing`.
Sentences about size start with `what`, such as `"Expression"`. See
"expression text" above for exactly what passes and what that guarantees.
"""
function expr_text_problem(text::AbstractString, what::AbstractString)::Union{Nothing,String}
    n = length(text)
    n > MAX_EXPR_CHARS &&
        return "$what is too long: it has $n characters, and at most $MAX_EXPR_CHARS are allowed."
    cs = collect(text)
    i = 1
    depth = 0
    deepest = 0
    ops = 0
    while i <= length(cs)
        c = cs[i]
        if isspace(c) || c == ','
            i += 1
        elseif c == '#'
            i < length(cs) && cs[i + 1] == '=' && return "Block comments #= =# are not allowed."
            while i <= length(cs) && cs[i] != '\n'
                i += 1
            end
        elseif c == '('
            depth += 1
            deepest = max(deepest, depth)
            i += 1
        elseif c == ')'
            depth = max(depth - 1, 0)
            i += 1
        elseif c == '`'
            i += 1                                   # a name in backticks; `\` escapes a character
            while i <= length(cs) && cs[i] != '`'
                i += cs[i] == '\\' ? 2 : 1
            end
            i += 1
        elseif isdigit(c) || (c == '.' && i < length(cs) && isdigit(cs[i + 1]))
            i = number_end(cs, i)
        elseif Base.is_id_start_char(c)
            j = i
            while j <= length(cs) && Base.is_id_char(cs[j])
                j += 1
            end
            word = String(cs[i:(j - 1)])
            word in ("true", "false") && return "true and false are not allowed. Use a comparison, such as MAG > 0."
            word in EXPR_KEYWORDS && return not_allowed(word) *
                " A channel of that name goes in backticks, such as `$word`."
            i = j
        elseif i < length(cs) && string(c, cs[i + 1]) in EXPR_OPERATORS_2
            ops += 2
            i += 2
        elseif c in EXPR_OPERATORS_1
            ops += 1
            i += 1
        else
            c == '"' && return "Text in quotes is not allowed."
            c == '$' && return "Interpolation with \$ is not allowed."
            c == '@' && return "Macros (names that start with @) are not allowed."
            return not_allowed(string(c))
        end
    end
    deepest > MAX_EXPR_BRACKETS && return "$what has brackets nested more than $MAX_EXPR_BRACKETS deep."
    ops > MAX_EXPR_OPERATORS && return "$what has more than $MAX_EXPR_OPERATORS operator characters."
    return nothing
end

"""
The index after the number literal that starts at `i`: digits and `_`, then a
fraction and an exponent (`e`, `E` or `f`, with an optional sign), or the
digits of `0x`, `0b` or `0o`. Letters after it are scanned as a name.
"""
function number_end(cs::Vector{Char}, i::Int)::Int
    n = length(cs)
    digit(k, f = isdigit) = k <= n && (f(cs[k]) || cs[k] == '_')
    if cs[i] == '0' && i < n && cs[i + 1] in "xbo"
        i += 2
        while digit(i, isxdigit)
            i += 1
        end
        return i
    end
    while digit(i)
        i += 1
    end
    if i <= n && cs[i] == '.' && digit(i + 1)
        i += 1
        while digit(i)
            i += 1
        end
    end
    if i <= n && cs[i] in "eEf"
        k = i + 1
        k <= n && cs[k] in "+-" && (k += 1)
        if k <= n && isdigit(cs[k])
            i = k
            while digit(i)
                i += 1
            end
        end
    end
    return i
end

function setting_problem(st::ExprSetting, x)::Union{Nothing,String}
    istext(x) || return "$(st.label) must be text."
    isempty(strip(x)) && return "$(st.label) is empty."
    p = expr_text_problem(x, st.label)
    p === nothing || return p
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

function setting_problem(st::ChannelListSetting, x)::Union{Nothing,String}
    (x isa AbstractVector && all(istext, x)) || return "$(st.label) must be a list of channel names."
    any(isempty, x) && return "$(st.label) has an empty channel name."
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
