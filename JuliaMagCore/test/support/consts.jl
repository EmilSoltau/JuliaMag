# Finds `const` names that a package defines more than once. Julia 1.12 lets a constant
# be defined again with a new value and gives no warning, so the last include wins in
# silence. The scan follows the package's own `include` calls from its main file, so it
# sees the module's top level as Julia does, and nothing inside a function.

"The top-level `const` names of the module in `main` that are defined more than once,
as name => the places (\"file:line\") that define it."
function duplicate_consts(main::AbstractString)::Dict{Symbol, Vector{String}}
    places = Dict{Symbol, Vector{String}}()
    scan_consts!(places, abspath(main))
    return filter(kv -> length(kv[2]) > 1, places)
end

function scan_consts!(places, file::AbstractString)
    ex = Meta.parseall(read(file, String); filename = file)
    line = Ref(0)
    walk_consts!(places, ex, file, line)
    return places
end

function walk_consts!(places, ex, file, line)
    if ex isa LineNumberNode
        line[] = ex.line
    elseif ex isa Expr
        if ex.head in (:toplevel, :block)
            foreach(a -> walk_consts!(places, a, file, line), ex.args)
        elseif ex.head === :module
            walk_consts!(places, ex.args[3], file, line)
        elseif ex.head === :if || ex.head === :elseif
            foreach(a -> walk_consts!(places, a, file, line), ex.args[2:end])
        elseif ex.head === :macrocall
            # `@static if ...`, `@doc`, and others: their bodies stay at the top level.
            foreach(a -> walk_consts!(places, a, file, line), ex.args[2:end])
        elseif ex.head === :global
            foreach(a -> walk_consts!(places, a, file, line), ex.args)
        elseif ex.head === :const
            for name in const_names(ex.args[1])
                push!(get!(places, name, String[]), "$(basename(file)):$(line[])")
            end
        elseif ex.head === :call && ex.args[1] === :include && length(ex.args) == 2 &&
               ex.args[2] isa String
            scan_consts!(places, joinpath(dirname(file), ex.args[2]))
        end
    end
    return places
end

const_names(ex::Symbol) = [ex]
function const_names(ex::Expr)
    ex.head === :(=) && return const_names(ex.args[1])
    ex.head === :(::) && return const_names(ex.args[1])
    ex.head === :tuple && return reduce(vcat, map(const_names, ex.args); init = Symbol[])
    ex.head === :global && return const_names(ex.args[1])
    return Symbol[]
end
const_names(::Any) = Symbol[]
