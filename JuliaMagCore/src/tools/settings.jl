# Setting types of tools and importers (spec 8.1).
# A setting is plain data: the UI builds its dialog from it, and `validate`
# checks a value against it. Values are plain too (numbers, text, booleans,
# `nothing` and vectors), so they go into JSON and into the history as they are.

"""
One setting of a tool or importer. Every setting type has the fields
`key`, `label`, `help` (a sentence for the dialog), `advanced`
(true puts it under "Advanced" in the dialog), `when` (see below) and a `default` value.

`when = "mode" => ["append"]` means: this setting is used only when the setting
`mode` has one of these values. The other setting must be in the same list and be
a `ChoiceSetting` or a `BoolSetting` (its values are `"true"` and `"false"`).
A setting that is not used is stored and recorded as its default (see `is_active`).
"""
abstract type SettingSpec end

"The type of the `when` field of a setting: no condition, or `key => values`."
const SettingWhen = Union{Nothing,Pair{String,Vector{String}}}

"The condition `when` of setting `key` in the form the field keeps. Throws `ArgumentError` for a bad one."
function when_value(key, when)::SettingWhen
    when === nothing && return nothing
    (when isa Pair && first(when) isa AbstractString && last(when) isa AbstractVector &&
     all(v -> v isa AbstractString, last(when)) && !isempty(last(when))) ||
        throw(ArgumentError("setting \"$key\": when must be a setting key => a list of values, such as \"mode\" => [\"append\"]"))
    return String(first(when)) => String[String(v) for v in last(when)]
end

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
                  unit = "", help = "", advanced = false, when = nothing)

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
    when::SettingWhen
    default::Union{Nothing,Int,Float64}
    min::Float64
    max::Float64
    auto::Bool
    integer::Bool
    unit::String
    function NumberSetting(key, label; default, min::Real = -Inf, max::Real = Inf, auto::Bool = false,
                           integer::Bool = false, unit = "", help = "", advanced::Bool = false, when = nothing)
        min <= max || throw(ArgumentError("setting \"$key\": min is above max"))
        d = default === nothing ? nothing : number_value(integer, default)
        integer && d isa Float64 && throw(ArgumentError("setting \"$key\": the default of a whole number setting must be whole"))
        return new(String(key), String(label), String(help), advanced, when_value(key, when), d, Float64(min), Float64(max), auto,
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
    when::SettingWhen
    default::String
    TextSetting(key, label; default = "", help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), String(default))
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
    when::SettingWhen
    default::String
    ExprSetting(key, label; default = "", help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), String(default))
end

"""
    ChoiceSetting(key, label, choices; default = first(choices), labels = choices, help = "", advanced = false, when = nothing)

One of a fixed list of words. The value is a `String` from `choices`.
`labels` are the words the dialog shows for the choices, in the same order.
"""
struct ChoiceSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    choices::Vector{String}
    labels::Vector{String}
    default::String
    function ChoiceSetting(key, label, choices::AbstractVector{<:AbstractString};
                           default = isempty(choices) ? "" : first(choices),
                           labels::AbstractVector{<:AbstractString} = choices, help = "", advanced::Bool = false, when = nothing)
        isempty(choices) && throw(ArgumentError("setting \"$key\": a choice needs at least one choice"))
        default in choices || throw(ArgumentError("setting \"$key\": the default \"$default\" is not a choice"))
        length(labels) == length(choices) ||
            throw(ArgumentError("setting \"$key\": there must be one label for each choice"))
        return new(String(key), String(label), String(help), advanced, when_value(key, when), String[c for c in choices],
                   String[l for l in labels], String(default))
    end
end

"True or false."
struct BoolSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    default::Bool
    BoolSetting(key, label; default::Bool = false, help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), default)
end

"""
    FileSetting(key, label; extensions = String[], save = false, default = "", help = "", advanced = false, when = nothing)

A file path. `extensions` (lower case, with the dot, such as `".xyz"`) limit the
file types; empty means any. `save = true` means a file to write, not to read.
"""
struct FileSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    extensions::Vector{String}
    save::Bool
    default::String
    FileSetting(key, label; extensions::AbstractVector{<:AbstractString} = String[], save::Bool = false,
                default = "", help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), String[lowercase(e) for e in extensions],
            save, String(default))
end

"""
    ChannelSetting(key, label; input = "database", roles = ChannelRole[], allow_array = false,
                   allow_new = false, default = "", help = "", advanced = false, when = nothing)

A channel name of the database given as tool input `input`. `roles` suggest
channels to the UI; `allow_array` allows array channels; `allow_new` allows a
name that does not exist yet (an output channel). The value is a `String`.
"""
struct ChannelSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    input::String
    roles::Vector{ChannelRole}
    allow_array::Bool
    allow_new::Bool
    default::String
    ChannelSetting(key, label; input = "database", roles::AbstractVector{ChannelRole} = ChannelRole[],
                   allow_array::Bool = false, allow_new::Bool = false, default = "", help = "",
                   advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), String(input), collect(ChannelRole, roles),
            allow_array, allow_new, String(default))
end

"""
    ChannelListSetting(key, label; input = "database", allow_array = true, default = String[],
                       help = "", advanced = false, when = nothing)

A list of channel names of the database given as tool input `input`.
An empty list means all channels. `allow_array` allows array channels.
The value is a `Vector{String}`.
"""
struct ChannelListSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    input::String
    allow_array::Bool
    default::Vector{String}
    ChannelListSetting(key, label; input = "database", allow_array::Bool = true,
                       default::AbstractVector{<:AbstractString} = String[], help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), String(input), allow_array,
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
    when::SettingWhen
    default::String
    function LinesSetting(key, label; default = "all", help = "", advanced::Bool = false, when = nothing)
        default in LINES_CHOICES || throw(ArgumentError("setting \"$key\": the default \"$default\" is not all, selected or current"))
        return new(String(key), String(label), String(help), advanced, when_value(key, when), String(default))
    end
end

"A coordinate system code, such as `\"EPSG:7855\"`. Blank means unknown."
struct CRSSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    default::String
    CRSSetting(key, label; default = "", help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), String(default))
end

"""
    PairSetting(key, label; input = "database", default = "", help = "", advanced = false, when = nothing)

A position pair of the database given as tool input `input`, such as `\"X,Y\"`.
Blank means the current pair.
"""
struct PairSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    input::String
    default::String
    PairSetting(key, label; input = "database", default = "", help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), String(input), String(default))
end

"An area: `[west, south, east, north]`, or `nothing` for the whole data."
struct ExtentSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    default::Union{Nothing,Vector{Float64}}
    ExtentSetting(key, label; default = nothing, help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when),
            default === nothing ? nothing : collect(Float64, default))
end

"A point: `[x, y]`, or `nothing` when not set."
struct PointSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    default::Union{Nothing,Vector{Float64}}
    PointSetting(key, label; default = nothing, help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when),
            default === nothing ? nothing : collect(Float64, default))
end

"""
    ItemSetting(key, label, kind; optional = false, default = "", help = "", advanced = false, when = nothing)

An item of the project of kind `kind`, such as `ITEM_DATABASE`, by its id,
such as `"db-1"`. The UI shows a list of the project's items of that kind.
The value is a `String`. With `optional = true` it may be blank (no item).
`validate` checks that the item exists and has the kind when it is given the session.
"""
struct ItemSetting <: SettingSpec
    key::String
    label::String
    help::String
    advanced::Bool
    when::SettingWhen
    kind::ItemKind
    optional::Bool
    default::String
    ItemSetting(key, label, kind::ItemKind; optional::Bool = false, default = "", help = "", advanced::Bool = false, when = nothing) =
        new(String(key), String(label), String(help), advanced, when_value(key, when), kind, optional, String(default))
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
# (`return return ...`, `begin begin ... end end`, `x->x->...`, `- - ...`,
# `a^a^...`). Nesting deep enough overflows its stack, which can leave the
# process broken. So the check is a whitelist. Allowed are only:
#
# - names that are not Julia keywords;
# - number literals (decimal, with a fraction or exponent, or 0x, 0b, 0o);
# - names in backticks (their text is not scanned: the parser does not look inside);
# - whole operator tokens: `+ - * / ^ < > <= >= == != & |`, the same with a dot
#   in front, and `=`; each may be followed by one unary `-` or `+` (as in `x^-1`),
#   but not to make `++` or `--`; a lone `.` only right before `(`, as in `sqrt.(x)`;
# - round brackets, commas, white space, and `#` comments to the end of the line.
#
# And within that: at most 10,000 characters, round brackets nested at most 100
# deep, and at most 500 operator characters. Anything else is refused with a
# message that names it. Text that is not valid UTF-8 is refused first. Text
# that passes is parsed by `parse_expr_text`, in one long-lived task with its
# own 64 MiB stack.
#
# What was tested (Julia 1.12.7, Linux x86_64), each case in a fresh process,
# through `parse_channel_expr` and the `ExprSetting` check, on the main thread
# and in a `Threads.@spawn` task: brackets alone, unary minus and plus chains,
# `^` chains (plain, dotted, with unary minus), nested `sqrt(`, `sqrt.(` and
# `ifelse(` calls, comparison, equality, `-`, `&` and `+` chains, tuples,
# juxtaposition, calls on calls, and brackets combined with each chain, all at
# the limits. None printed anything on stderr. The worst case, brackets around a
# `^` chain, still parses in the 64 MiB task at 16 times the bracket and operator
# limits (1,600 brackets and 8,000 operators) and first overflows at 32 times.
# Without the big stack, it overflows at 3 times the old limits of 200 and 1,000.
# This is a tested margin, not a proof for every Julia version. Code that walks
# the parsed tree must still limit its own depth (Channel Math refuses trees
# over 200 deep).

const MAX_EXPR_CHARS = 10_000
const MAX_EXPR_BRACKETS = 100
const MAX_EXPR_OPERATORS = 500

"Stack of the task that parses expression text (bytes). See `parse_expr_text`."
const PARSE_STACK = 64 << 20

# The one parser task, made on first use. A task with its own stack maps that
# stack until the task is garbage collected, so a new 64 MiB task per parse
# would grow the address space by 64 MiB for each check (1,000 checks grew it
# by 66 GB). One long-lived task maps it once.
const PARSER_LOCK = ReentrantLock()
const PARSER_JOBS = Ref{Union{Nothing,Channel{Tuple{String,Channel{Any}}}}}(nothing)

"Parse each text sent to `jobs`, and put the result (or the error and its backtrace) on its reply channel."
function parser_loop(jobs::Channel{Tuple{String,Channel{Any}}})
    for (text, reply) in jobs
        r = try
            Meta.parseall(text)
        catch e
            (e, catch_backtrace())
        end
        put!(reply, r)
    end
    return nothing
end

"The channel of the parser task. Starts the task the first time, or again if it has stopped."
function parser_jobs()::Channel{Tuple{String,Channel{Any}}}
    lock(PARSER_LOCK) do
        jobs = PARSER_JOBS[]
        jobs !== nothing && isopen(jobs) && return jobs
        jobs = Channel{Tuple{String,Channel{Any}}}(Inf)
        t = Task(() -> parser_loop(jobs), PARSE_STACK)
        t.sticky = false                         # free to run on any thread
        bind(jobs, t)                            # if the task ever ends, the channel closes
        schedule(t)
        PARSER_JOBS[] = jobs
        return jobs
    end
end

"""
    parse_expr_text(text)

`Meta.parseall(text)`, run in the one parser task, which has its own 64 MiB
stack. So the room the parser has does not depend on where it is called from
(the main thread, a job, a UI callback deep in its own stack) or on the
platform. Calls from many tasks at once take turns. Call it only on text that
`expr_text_problem` passed. If the parser throws, this throws `ToolError` with
the error and the parser's backtrace.
"""
function parse_expr_text(text::String)
    reply = Channel{Any}(1)
    put!(parser_jobs(), (text, reply))
    r = take!(reply)
    if r isa Tuple{Exception,Any}
        e, bt = r
        throw(ToolError("The expression could not be parsed: " * sprint(showerror, e, bt)))
    end
    return r
end

"Words of Julia syntax. They may not appear as bare names in an expression."
const EXPR_KEYWORDS = Set(["begin", "end", "let", "if", "elseif", "else", "return", "local", "global", "const",
    "quote", "try", "catch", "finally", "for", "while", "function", "macro", "module", "baremodule", "struct",
    "mutable", "abstract", "primitive", "type", "do", "using", "import", "export", "outer", "where", "in",
    "isa", "true", "false", "break", "continue", "public"])

"""
The operator tokens that may appear, whole: those of Channel Math, their dotted
forms, and `=`. `.` alone may only start a dotted call such as `sqrt.(x)`.
"""
const EXPR_OPERATORS = Set(vcat(["+", "-", "*", "/", "^", "<", ">", "<=", ">=", "==", "!=", "&", "|"],
                                [".$o" for o in ("+", "-", "*", "/", "^", "<", ">", "<=", ">=", "==", "!=", "&", "|")],
                                ["="]))

"A character that is not a name, number, bracket, comma, quote, comment or space: part of an operator token."
is_operator_char(c::Char) =
    c == '!' || !(isspace(c) || Base.is_id_char(c) || c in "(),`\"#\$@")

"""
Whether a run of operator characters is allowed: one allowed operator, or one
followed by a single unary `-` or `+` (Julia reads `*-` as `*` then `-`). Julia
reads `++` and `--` as tokens of their own, so those are refused.
"""
function operator_run_ok(run::String)::Bool
    run in EXPR_OPERATORS && return true
    length(run) >= 2 || return false
    t, u = chop(run), last(run)
    return u in "+-" && t in EXPR_OPERATORS && last(t) != u
end

"The clean text of a parse error, such as ``Expected `)` or `,`.``"
function parse_problem(e)::String
    msg = e isa Meta.ParseError ? e.msg : string(e)
    m = match(r"── (.*)", msg)
    text = m === nothing ? String(strip(first(split(msg, '\n')))) : String(strip(something(m[1])))
    return endswith(text, '.') ? text : text * "."
end

not_allowed(tok::AbstractString) =
    "\"$(length(tok) > 20 ? first(tok, 20) * "..." : tok)\" is not allowed in a channel expression."

"""
    expr_text_problem(text, what)::Union{Nothing,String}

What makes expression text unsafe to parse, as a sentence, or `nothing`.
Sentences about size start with `what`, such as `"Expression"`. See
"expression text" above for exactly what passes and what that guarantees.
"""
function expr_text_problem(text::AbstractString, what::AbstractString)::Union{Nothing,String}
    isvalid(text) || return "$what is not valid UTF-8 text."
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
        elseif is_operator_char(c)
            j = i
            while j <= length(cs) && is_operator_char(cs[j])
                j += 1
            end
            run = String(cs[i:(j - 1)])
            next = j <= length(cs) ? cs[j] : ' '
            if run == "."
                next == '(' || return "Field access with . is not allowed."   # only `f.(x)` uses a lone dot
            elseif !operator_run_ok(run)
                startswith(run, "&&") && return "&& is not allowed. Use & instead."
                startswith(run, "||") && return "|| is not allowed. Use | instead."
                return not_allowed(run)
            end
            ops += length(run)
            i = j
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
    p = expr_text_problem(x, st.label)
    p === nothing || return p
    isempty(strip(x)) && return "$(st.label) is empty."
    ex = parse_expr_text(String(x))
    for a in (ex isa Expr ? ex.args : Any[])
        if a isa Expr && a.head in (:error, :incomplete)
            return "$(st.label) is not a valid Julia expression: " * parse_problem(isempty(a.args) ? "" : a.args[1])
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

function setting_problem(st::ItemSetting, x)::Union{Nothing,String}
    istext(x) || return "$(st.label) must be an item id."
    isempty(x) && !st.optional && return "$(st.label) is not set."
    return nothing
end

"""
    session_problem(st, x, s)::Union{Nothing,String}

What is wrong with value `x` in the project of session `s`, as a plain
sentence, or `nothing`. Only settings that name project items check anything.
Call it only for a value that `setting_problem` passed.
"""
session_problem(::SettingSpec, _, ::Session)::Union{Nothing,String} = nothing

function session_problem(st::ItemSetting, x, s::Session)::Union{Nothing,String}
    isempty(x) && return nothing
    kind = lock(s.lock) do
        k = findfirst(i -> i.id == x, s.project.items)
        return k === nothing ? nothing : s.project.items[k].kind
    end
    kind === nothing && return "$(st.label): there is no item $x in the project."
    kind == st.kind && return nothing
    return "$(st.label) must be a $(KIND_NAMES[st.kind]), but $x is a $(KIND_NAMES[kind])."
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

# The value of a controlling setting as the text that `when` lists:
# a choice as it is, a bool as "true" or "false".
when_text(v) = v isa Bool ? string(v) : v isa Union{AbstractString,Symbol} ? String(v) : nothing

"""
    is_active(list, st, values)::Bool

Whether setting `st` of `list` is used with `values`: it has no `when`, or the
setting it names has one of the listed values (a missing value is the default).
A setting that depends on one that is not used is not used either.
"""
function is_active(list::AbstractVector{<:SettingSpec}, st::SettingSpec, values::AbstractDict)::Bool
    cur = st
    for _ in 0:length(list)                        # a chain is not longer than the list
        cur.when === nothing && return true
        key, wanted = cur.when
        k = findfirst(x -> x.key == key, list)
        k === nothing && return false
        ctl = list[k]
        v = haskey(values, key) ? values[key] : setting_default(ctl)
        when_text(v) in wanted || return false
        cur = ctl
    end
    return false
end

"""
Check the `when` of every setting in `list`: the setting it names is in the
list, is a choice or a bool, lists only its values, and no chain loops.
Throws `ArgumentError`.
"""
function check_when(list::AbstractVector{<:SettingSpec}, owner::AbstractString)
    for st in list
        st.when === nothing && continue
        key, wanted = st.when
        k = findfirst(x -> x.key == key, list)
        k === nothing && throw(ArgumentError(
            "$owner: setting \"$(st.key)\" depends on \"$key\", which is not one of its settings"))
        ctl = list[k]
        ctl isa Union{ChoiceSetting,BoolSetting} || throw(ArgumentError(
            "$owner: setting \"$(st.key)\" depends on \"$key\", which is not a choice or a bool"))
        allowed = ctl isa ChoiceSetting ? ctl.choices : ["true", "false"]
        for w in wanted
            w in allowed || throw(ArgumentError(
                "$owner: setting \"$(st.key)\" waits for \"$w\", which \"$key\" cannot be"))
        end
        cur = ctl                                  # follow the chain: it must not come back to `st`
        for _ in 1:length(list)
            cur === st && throw(ArgumentError("$owner: setting \"$(st.key)\" depends on itself"))
            cur.when === nothing && break
            j = findfirst(x -> x.key == first(cur.when), list)
            j === nothing && break
            cur = list[j]
        end
    end
    return nothing
end

"""
    deactivate_settings(list, values)::Dict{String,Any}

A copy of `values` where each setting that is not used (see `is_active`) has its
default. Keys that are not settings stay. This is what jobs, the history and the
remembered settings keep.

It is public, not exported: the UI calls it as `JuliaMagCore.deactivate_settings` so the
script call it shows matches what the history writes.
"""
function deactivate_settings(list::AbstractVector{<:SettingSpec}, values::AbstractDict)::Dict{String,Any}
    out = Dict{String,Any}(String(k) => v for (k, v) in values)
    for st in list
        haskey(out, st.key) && !is_active(list, st, values) && (out[st.key] = setting_default(st))
    end
    return out
end

"""
    settings_problems(list, values, owner; session = nothing)::Vector{Pair{String,String}}

Check `values` against the settings in `list`: setting key => sentence, in setting order.
A missing key takes its default. A setting that is not used (see `is_active`) is skipped.
A key that is not a setting is a problem too, with the key as its key; `owner` names the tool in that message.
With a `session`, settings that name project items are checked against its
project too (see `session_problem`).
"""
function settings_problems(list::AbstractVector{<:SettingSpec}, values::AbstractDict, owner::AbstractString;
                           session::Union{Nothing,Session} = nothing)::Vector{Pair{String,String}}
    given = Dict{String,Any}(String(k) => v for (k, v) in values)
    problems = Pair{String,String}[]
    for st in list
        is_active(list, st, given) || continue
        v = haskey(given, st.key) ? setting_value(st, given[st.key]) : setting_default(st)
        p = setting_problem(st, v)
        p === nothing && session !== nothing && (p = session_problem(st, v, session))
        p === nothing || push!(problems, st.key => p)
    end
    known = Set(st.key for st in list)
    for k in sort!(collect(keys(given)))
        k in known || push!(problems, k => "$owner has no setting \"$k\".")
    end
    return problems
end

"The sentences of `settings_problems`: what `validate` returns."
validate_settings(list::AbstractVector{<:SettingSpec}, values::AbstractDict, owner::AbstractString;
                  session::Union{Nothing,Session} = nothing)::Vector{String} =
    last.(settings_problems(list, values, owner; session))

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
