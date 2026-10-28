# Channel Math (spec 9.4): the user writes `OUT = <expression>` over channel
# names, such as `MAG_IGRF = MAG - IGRF`, and the result goes to channel OUT.
#
# Safety: the text is never run as Julia code. `parse_channel_expr` first scans
# the raw text with `expr_text_problem`, a token whitelist with size and nesting
# limits; text with any other token (keywords, quotes, `$`, `@`, `:`, `;`,
# brackets other than round ones, ...) never reaches the parser. Then it parses
# with `Meta.parseall`, refuses a tree nested more than 200 deep (so checking and
# computing recurse at most 200 levels), and checks every part against a short
# list. Allowed are
# number literals, channel names, the constants `pi`, `e`, `NaN` and `Inf`
# (ruling R14; `NaN` masks values, such as `ifelse(ALT > 200, NaN, MAG)`), and calls to
#
#     + - * / ^ abs sqrt exp log log10 sin cos tan atan min max ifelse isnan
#     < > <= >= == != & |
#
# Channel names that are not Julia names go in backticks: `` `MAG-IGRF` ``.
# A bare name is a channel when the database has it, so a channel called `e`
# hides the constant. Dotted forms such as `.-` and `sqrt.(x)` mean the same as
# the plain ones, since the work is always done row by row.
#
# `eval_channel_expr` walks the checked tree and works on whole line vectors with
# broadcasting. All numbers are `Float64`. Integer channels are read as `Float64`,
# with their missing value as `NaN`.
#
# Numbers follow Julia, with one change:
# - Missing values (`NaN`) pass through arithmetic. A comparison with `NaN` is false.
# - Division by zero gives `Inf`, `-Inf` or `NaN`, as in Julia.
# - Where Julia would throw a `DomainError` (`sqrt(-1)`, `log(-1)`, `(-8)^0.5`,
#   `sin(Inf)`), the value is `NaN` instead.
# - A true or false result is written as 1 or 0.
#
# The tool is a job. It marks the database busy while it writes. A new output
# channel is undone like an append (see `note_append_undo!`). For an existing
# output channel, the job first copies its file to a side folder of the
# database; undo and redo copy the old or the new bytes back into the file in
# place, so they are exact and views that map the file see the change.

# ---- the allowed functions -------------------------------------------------

"""
One allowed function: the least and most values it takes, the kind of its
values (`:num`, or `:bool` for true or false), the kind of its result, and
the Julia function that computes it for one row.
"""
struct CmFunction
    min::Int
    max::Int
    arg::Symbol
    result::Symbol
    impl::Function
end

# Versions that give NaN where Julia throws a DomainError.
cm_sqrt(x::Real)::Float64 = x < 0 ? NaN : sqrt(Float64(x))
cm_log(x::Real)::Float64 = x < 0 ? NaN : log(Float64(x))
cm_log10(x::Real)::Float64 = x < 0 ? NaN : log10(Float64(x))
cm_pow(x::Real, y::Real)::Float64 = (x < 0 && isfinite(y) && !isinteger(y)) ? NaN : Float64(x)^Float64(y)
cm_sin(x::Real)::Float64 = isinf(x) ? NaN : sin(Float64(x))
cm_cos(x::Real)::Float64 = isinf(x) ? NaN : cos(Float64(x))
cm_tan(x::Real)::Float64 = isinf(x) ? NaN : tan(Float64(x))

const CM_MANY = typemax(Int)

"The allowed functions, in the order the help text lists them."
const CM_ORDER = [:+, :-, :*, :/, :^, :abs, :sqrt, :exp, :log, :log10, :sin, :cos, :tan, :atan, :min, :max,
                  :ifelse, :isnan, :<, :>, :<=, :>=, :(==), :!=, :&, :|]

const CM_FUNCTIONS = Dict{Symbol,CmFunction}(
    :+ => CmFunction(1, CM_MANY, :num, :num, +),
    :- => CmFunction(1, 2, :num, :num, -),
    :* => CmFunction(2, CM_MANY, :num, :num, *),
    :/ => CmFunction(2, 2, :num, :num, /),
    :^ => CmFunction(2, 2, :num, :num, cm_pow),
    :abs => CmFunction(1, 1, :num, :num, abs),
    :sqrt => CmFunction(1, 1, :num, :num, cm_sqrt),
    :exp => CmFunction(1, 1, :num, :num, exp),
    :log => CmFunction(1, 1, :num, :num, cm_log),
    :log10 => CmFunction(1, 1, :num, :num, cm_log10),
    :sin => CmFunction(1, 1, :num, :num, cm_sin),
    :cos => CmFunction(1, 1, :num, :num, cm_cos),
    :tan => CmFunction(1, 1, :num, :num, cm_tan),
    :atan => CmFunction(1, 2, :num, :num, atan),
    :min => CmFunction(2, CM_MANY, :num, :num, min),
    :max => CmFunction(2, CM_MANY, :num, :num, max),
    :ifelse => CmFunction(3, 3, :ifelse, :num, ifelse),
    :isnan => CmFunction(1, 1, :num, :bool, isnan),
    :< => CmFunction(2, 2, :num, :bool, <),
    :> => CmFunction(2, 2, :num, :bool, >),
    :<= => CmFunction(2, 2, :num, :bool, <=),
    :>= => CmFunction(2, 2, :num, :bool, >=),
    :(==) => CmFunction(2, 2, :num, :bool, ==),
    :!= => CmFunction(2, 2, :num, :bool, !=),
    :& => CmFunction(2, CM_MANY, :bool, :bool, &),
    :| => CmFunction(2, CM_MANY, :bool, :bool, |),
)

"Names that stand for a number, when no channel has the name."
const CM_CONSTANTS = Dict{Symbol,Float64}(:pi => Float64(pi), :π => Float64(pi), :e => Float64(ℯ),
                                          :ℯ => Float64(ℯ), :NaN => NaN, :Inf => Inf)

const CM_ALLOWED_TEXT = "Allowed functions: " * join(string.(CM_ORDER), " ") * "."
const CM_FORM = "Write the expression as OUT = <expression>, such as MAG_IGRF = MAG - IGRF."

cm_error(msg::AbstractString) = throw(ToolError(String(msg)))

# ---- parsing and checking --------------------------------------------------

"The channel name in backticks, or `nothing` when `x` is not a backtick name."
function backtick_name(x)::Union{Nothing,String}
    (x isa Expr && x.head === :macrocall && length(x.args) == 3) || return nothing
    x.args[1] == GlobalRef(Core, Symbol("@cmd")) || return nothing
    s = x.args[3]
    return s isa String ? s : nothing
end

"Most levels of calls in a checked expression, so checking and computing it never overflow the stack."
const CM_MAX_DEPTH = 200

"The levels of `Expr` in a parsed tree, counted without recursion."
function tree_depth(x)::Int
    deepest = 0
    stack = Tuple{Any,Int}[(x, 1)]
    while !isempty(stack)
        node, d = pop!(stack)
        node isa Expr || continue
        deepest = max(deepest, d)
        for a in node.args
            a isa Expr && push!(stack, (a, d + 1))
        end
    end
    return deepest
end

"Throw the message for a name that is not a channel."
function unknown_channel(name::String, channels::Vector{String})
    k = findfirst(c -> lowercase(c) == lowercase(name), channels)
    k === nothing && cm_error("There is no channel $name.")
    cm_error("There is no channel $name. Did you mean $(channels[k])?")
end

"The problem text of a parse error, such as ``Expected `)` or `,` ``."
function parse_problem(e)::String
    msg = e isa Meta.ParseError ? e.msg : string(e)
    m = match(r"── (.*)", msg)
    text = m === nothing ? String(strip(first(split(msg, '\n')))) : String(strip(something(m[1])))
    return endswith(text, '.') ? text : text * "."
end

"""
    parse_channel_expr(text, channels)::Expr

Parse and check a Channel Math expression `OUT = <expression>`. `channels` are
the channel names of the database. Returns `:(OUT = <checked expression>)`:
in the checked expression every name is a channel (a `Symbol`, which may hold
any text), every number is a `Float64` (the constants `pi`, `e`, `NaN` and `Inf`
become numbers too), every call is to an allowed function,
dotted calls are plain, and `a < b < c` is `(a < b) & (b < c)`.
OUT may be a new channel name.

Throws `ToolError` with a plain message for a syntax error, an unknown name,
a call to a function that is not allowed, or any other form, such as field
access, macros, text, ranges or keyword arguments. Text with a token outside
the whitelist of `expr_text_problem`, over 10,000 characters, or nested too
deep, is refused before it is parsed.
The text is only parsed, never run.
"""
function parse_channel_expr(text::String, channels::Vector{String})::Union{Expr,Symbol}
    isempty(strip(text)) && cm_error("The expression is empty.")
    problem = expr_text_problem(text, "The expression")
    problem === nothing || cm_error(problem)
    top = Meta.parseall(text)
    parts = Any[a for a in top.args if !(a isa LineNumberNode)]
    for a in parts
        if a isa Expr && a.head in (:error, :incomplete)
            cm_error("The expression is not valid Julia: " * parse_problem(isempty(a.args) ? "" : a.args[1]))
        end
    end
    isempty(parts) && cm_error("The expression is empty.")
    length(parts) == 1 || cm_error("Write one expression only, such as MAG_IGRF = MAG - IGRF.")
    ex = parts[1]
    (ex isa Expr && ex.head === :(=) && length(ex.args) == 2) || cm_error(CM_FORM)
    lhs, rhs = ex.args
    target = lhs isa Symbol ? String(lhs) : backtick_name(lhs)
    (target === nothing || isempty(target)) && cm_error("The left side of = must be one channel name, such as MAG_IGRF.")
    (rhs isa Expr && rhs.head === :(=)) && cm_error("Use only one = in the expression.")
    tree_depth(rhs) > CM_MAX_DEPTH && cm_error("The expression is nested more than $CM_MAX_DEPTH deep.")
    checked, _ = cm_check(rhs, channels)
    return Expr(:(=), Symbol(target), checked)
end

"""
Check one part of the expression. Returns the checked part and its kind:
`:num` for a number, `:bool` for true or false.
"""
function cm_check(x, channels::Vector{String})::Tuple{Any,Symbol}
    x isa Bool && cm_error("true and false are not allowed. Use a comparison, such as MAG > 0.")
    x isa Real && return (Float64(x), :num)
    if x isa Symbol
        name = String(x)
        name in channels && return (x, :num)
        haskey(CM_CONSTANTS, x) && return (CM_CONSTANTS[x], :num)
        haskey(CM_FUNCTIONS, x) &&
            cm_error("$name is a function. Call it with values in brackets, such as $name(MAG).")
        unknown_channel(name, channels)
    end
    x isa AbstractString && cm_error("Text in quotes is not allowed.")
    x isa QuoteNode && cm_error("Symbols such as :name are not allowed.")
    x isa Expr || cm_error("This part of the expression is not allowed: $(first(string(x), 60)).")
    name = backtick_name(x)
    if name !== nothing
        isempty(name) && cm_error("Empty backticks are not a channel name.")
        name in channels || unknown_channel(name, channels)
        return (Symbol(name), :num)
    end
    h = x.head
    h === :call && return cm_call(x.args[1], x.args[2:end], channels)
    if h === :.
        # `f.(a, b)` is a dotted call; anything else with a dot is field access.
        (length(x.args) == 2 && x.args[2] isa Expr && x.args[2].head === :tuple) ||
            cm_error("Field access with . is not allowed.")
        return cm_call(x.args[1], x.args[2].args, channels)
    end
    h === :comparison && return cm_comparison(x, channels)
    if h === :macrocall
        m = x.args[1]
        big = m isa GlobalRef && m.name in (Symbol("@int128_str"), Symbol("@uint128_str"), Symbol("@big_str"))
        big && cm_error("The number $(x.args[end]) is too large.")
        cm_error("Macros (names that start with @) are not allowed.")
    end
    h === :string && cm_error("Text in quotes is not allowed.")
    h === :$ && cm_error("Interpolation with \$ is not allowed.")
    h in (:comprehension, :generator) && cm_error("Comprehensions and generators are not allowed.")
    h in (:kw, :parameters) && cm_error("Keyword arguments are not allowed.")
    h === :(=) && cm_error("Use only one = in the expression.")
    h === :&& && cm_error("&& is not allowed. Use & instead.")
    h === :|| && cm_error("|| is not allowed. Use | instead.")
    h === :ref && cm_error("Indexing with [ ] is not allowed.")
    h in (:vect, :vcat, :hcat, :tuple, :typed_vcat, :typed_hcat) && cm_error("Lists of values are not allowed.")
    cm_error("This part of the expression is not allowed: $(h === :block ? "begin" : string(h)).")
end

"Check a call of function `f` with values `args`."
function cm_call(f, args::AbstractVector, channels::Vector{String})::Tuple{Any,Symbol}
    f isa Expr && f.head === :. && cm_error("Field access with . is not allowed.")
    f isa Symbol || cm_error("Only the allowed functions can be called, by name.")
    s = String(f)
    if !haskey(CM_FUNCTIONS, f) && length(s) > 1 && startswith(s, '.') && haskey(CM_FUNCTIONS, Symbol(s[2:end]))
        f = Symbol(s[2:end])                     # `.-` is `-`: the work is row by row anyway
    end
    f === :(:) && cm_error("Ranges with : are not allowed.")
    spec = get(CM_FUNCTIONS, f, nothing)
    spec === nothing && cm_error("$f is not an allowed function. $CM_ALLOWED_TEXT")
    any(a -> a isa Expr && a.head in (:kw, :parameters), args) && cm_error("Keyword arguments are not allowed.")
    n = length(args)
    if n < spec.min || n > spec.max
        want = spec.min == spec.max ? "$(spec.min) value$(spec.min == 1 ? "" : "s")" :
               spec.max == CM_MANY ? "at least $(spec.min) value$(spec.min == 1 ? "" : "s")" :
               "$(spec.min) or $(spec.max) values"
        cm_error("$f takes $want, not $n.")
    end
    checked = Any[]
    for (k, a) in enumerate(args)
        c, kind = cm_check(a, channels)
        if spec.arg === :bool && kind !== :bool
            cm_error("& and | need true or false values on both sides, such as (MAG > 0) & (IGRF < 1).")
        elseif spec.arg === :ifelse && k == 1 && kind !== :bool
            cm_error("The first value of ifelse must be true or false, such as MAG > 0.")
        end
        push!(checked, c)
    end
    return (Expr(:call, f, checked...), spec.result)
end

"Check `a < b <= c` and turn it into `(a < b) & (b <= c)`."
function cm_comparison(x::Expr, channels::Vector{String})::Tuple{Any,Symbol}
    a = x.args
    parts = Any[]
    for k in 1:2:(length(a) - 2)
        c, _ = cm_call(a[k + 1], Any[a[k], a[k + 2]], channels)
        push!(parts, c)
    end
    return (length(parts) == 1 ? parts[1] : Expr(:call, :&, parts...), :bool)
end

"The channel names a checked expression reads, in first-seen order."
cm_inputs(ex)::Vector{String} = cm_inputs!(String[], ex)

function cm_inputs!(out::Vector{String}, x)::Vector{String}
    if x isa Symbol
        name = String(x)
        name in out || push!(out, name)
    elseif x isa Expr
        foreach(a -> cm_inputs!(out, a), view(x.args, 2:length(x.args)))   # args[1] of a call is the function
    end
    return out
end

# ---- evaluation ------------------------------------------------------------

"""
    eval_channel_expr(ex, values, n)::Vector{Float64}

Compute a checked expression (from `parse_channel_expr`, with or without its
`OUT =`) over the rows of one line. `values` holds the `Float64` values of each
channel it reads, by name, each with `n` rows. A true or false result is 1 or 0.
"""
function eval_channel_expr(ex, values::AbstractDict{Symbol,Vector{Float64}}, n::Int)::Vector{Float64}
    rhs = ex isa Expr && ex.head === :(=) ? ex.args[2] : ex
    r = cm_eval(rhs, values)
    r isa Real && return fill(Float64(r), n)
    out = Vector{Float64}(undef, n)
    out .= r
    return out
end

function cm_eval(x, values::AbstractDict{Symbol,Vector{Float64}})
    x isa Float64 && return x
    x isa Symbol && return values[x]
    ex = x::Expr
    f = CM_FUNCTIONS[ex.args[1]::Symbol].impl
    args = Any[cm_eval(a, values) for a in view(ex.args, 2:length(ex.args))]
    all(a -> a isa Real, args) && return f(args...)
    return broadcast(f, args...)
end

# ---- lines of a tool -------------------------------------------------------

"""
The lines that a `LinesSetting` value names in database `id`: `"all"`, `"selected"`
or `"current"` (the line of `s.cursor`). Only lines whose rows are written count.
Call it under `s.lock`. Throws `ToolError` when there are none to pick.
"""
function tool_lines(s::Session, db::LineDatabase, id::AbstractString, choice::AbstractString)::Vector{LineInfo}
    written(l) = l.offset + l.nrows <= db.rows_written
    choice == "all" && return filter(written, db.lines)
    if choice == "selected"
        out = filter(l -> l.selected && written(l), db.lines)
        isempty(out) && throw(ToolError("No lines are selected in database $id."))
        return out
    end
    c = s.cursor
    (c === nothing || c.item != id) && throw(ToolError("No current line."))
    k = line_position(db, c.line)
    k == 0 && throw(ToolError("No current line."))
    l = db.lines[k]
    written(l) || throw(ToolError("Line $(line_name(l.id)) has no data yet."))
    return [l]
end

# ---- the tool --------------------------------------------------------------

"Throw `ToolError` unless the channel holds single numbers."
function check_number_channel(db::LineDatabase, name::String)
    c = channel(db, name)
    (c.eltype <: Real && c.arraylen == 1) ||
        throw(ToolError("Channel $name is not a channel of single numbers. Channel Math reads only such channels."))
    return nothing
end

"""
Check the output channel. Returns true when it must be made, false when it
exists and will be overwritten. Throws `ToolError` when it cannot be written.
"""
function check_output_channel(db::LineDatabase, name::String)::Bool
    k = channel_position(db, name)
    if k == 0
        j = findfirst(c -> lowercase(c.name) == lowercase(name), db.channels)
        j === nothing || throw(ToolError(
            "Channel $name is too like channel $(db.channels[j].name): names may not differ only in case."))
        return true
    end
    c = db.channels[k]
    c.protected && throw(ToolError(failure_message(ProtectedError(name))))
    (c.eltype === Float64 && c.arraylen == 1) || throw(ToolError(
        "Channel $name holds $(c.arraylen == 1 ? c.eltype : "arrays of $(c.eltype)") values. " *
        "Channel Math writes only Float64 channels. Pick another output channel."))
    return false
end

"Copy the whole file `src` over the start of file `dst`, in place. The two must have the same size."
function copy_into!(dst::String, src::String)
    filesize(dst) == filesize(src) || throw(DatabaseError(
        "cannot put back channel file $(basename(dst)): its size changed"))
    open(dst, "r+") do out
        open(io -> copy_stream(io, out), src, "r")
    end
    return nothing
end

"Copy file `src` to the new file `dst`."
copy_file(src::String, dst::String) = (open(out -> open(io -> copy_stream(io, out), src, "r"), dst, "w"); nothing)

"""
Inside a job: note how to undo and redo the overwrite of channel file `file` of
item `target`. The side folder holds `<file>.old`; undo also keeps `<file>.new`
there for redo. Both refuse when `database.json` is no longer `committed`.
"""
function note_overwrite_undo!(s::Session, target::String, file::String, side::String, committed::String)
    folder() = item_path(s.project, item(s.project, target))
    function check()
        check_not_busy(s, target)
        read(joinpath(folder(), META_FILE), String) == committed || throw(DatabaseError(
            "cannot undo or redo Channel Math on $target: database.json changed since"))
        return joinpath(channels_folder(folder()), file)
    end
    undo = () -> begin
        path = check()
        copy_file(path, joinpath(side, file * ".new"))
        copy_into!(path, joinpath(side, file * ".old"))
        nothing
    end
    redo = () -> (copy_into!(check(), joinpath(side, file * ".new")); nothing)
    drop = () -> (rm(side; recursive = true, force = true); nothing)
    note_job_undo!(undo, redo, drop; items = [target])
    return nothing
end

function run_channel_math(s::Session, ins::Dict{String,String}, st::Dict{String,Any}, progress::Progress, out::IO)
    id = ins["database"]
    text = String(st["expr"])
    # Check everything and mark the database busy under the lock; compute without it.
    db, ex, name, lines, make, before = lock(s.lock) do
        db = tool_database(s, id)
        ex = parse_channel_expr(text, String[c.name for c in db.channels])::Expr
        foreach(n -> check_number_channel(db, n), cm_inputs(ex.args[2]))
        name = String(ex.args[1]::Symbol)
        make = check_output_channel(db, name)
        lines = tool_lines(s, db, id, st["lines"])
        # Read the state before the mark, so a failed read leaves no mark behind.
        before = committed_state(db)
        mark_busy!(s, id; reason = "Channel Math is running")
        return db, ex, name, lines, make, before
    end
    inputs = cm_inputs(ex.args[2])
    local committed::String
    side = ""
    file = ""
    rows = 0
    writing = false     # true once the output channel may have changed
    try
        nchannels, written = length(db.channels), db.rows_written
        try
            if make
                try
                    add_channel!(db, ChannelInfo(name, name, Float64, "", ROLE_NONE, :normal, 12, -1, false, 1))
                catch e
                    e isa DatabaseError || rethrow()
                    throw(ToolError("Channel $name cannot be made: $(e.msg)"))
                end
            else
                path = channel_files(db, channel(db, name))[1]
                file = basename(path)
                # Julia removes the side folder when the process ends, with the undo stack.
                side = mktempdir(db.folder; prefix = ".undo-", cleanup = true)
                copy_file(path, joinpath(side, file * ".old"))
            end
            writing = true
            total = sum(l -> l.nrows, lines; init = 0)
            for l in lines
                is_cancelled(progress) && throw(JobCancelled())
                values = Dict{Symbol,Vector{Float64}}(Symbol(n) => float_values(db, l, n) for n in inputs)
                write_channel!(db, l.id, name, eval_channel_expr(ex, values, l.nrows))
                rows += l.nrows
                report(progress, total == 0 ? 1.0 : rows / total)
            end
            release_maps!(db)
            committed = lock(s.lock) do
                make && save_meta(db)                # the commit point of a new channel
                read(meta_path(db), String)
            end
        catch
            release_maps!(db)
            keep = false
            if make
                undo_append!(db, nchannels, written)
            elseif writing
                try
                    copy_into!(joinpath(channels_folder(db.folder), file), joinpath(side, file * ".old"))
                catch e
                    e isa InterruptException && rethrow()
                    # The old values are only in the side folder now: keep it, under a
                    # name that is not removed when the process ends.
                    keep = true
                    kept = side * "-kept"
                    quietly(() -> mv(side, kept))
                    session_warning!(s, "Channel Math could not put back channel $name of $id; " *
                                        "its old values are in $(ispath(kept) ? kept : side): $(sprint(showerror, e))")
                end
            end
            (isempty(side) || keep) || rm(side; recursive = true, force = true)
            rethrow()
        end
    finally
        unmark_busy!(s, id)
    end
    make ? note_append_undo!(s, id, before, committed) : note_overwrite_undo!(s, id, file, side, committed)
    n = length(lines)
    println(out, "Wrote ", strip(text), " on ", n, n == 1 ? " line" : " lines", " (", rows, rows == 1 ? " row)." : " rows).")
    println(out, make ? "Channel $name is new." : "Channel $name was overwritten.")
    return nothing
end

register_tool!(ToolSpec("database.channel_math", "Channel Math",
    "Compute a channel from other channels with an expression, such as MAG_IGRF = MAG - IGRF. " *
    "Names that are not Julia names go in backticks, such as `MAG-IGRF`.", "math",
    [Place("Database Tools", "Channels")], DATABASE_INPUT,
    SettingSpec[ExprSetting("expr", "Expression";
                            help = "OUT = <expression>. " * CM_ALLOWED_TEXT * " Constants: pi, e, NaN, Inf."),
                LinesSetting("lines", "Lines")],
    :job, run_channel_math))
