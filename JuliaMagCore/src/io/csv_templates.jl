# CSV layouts as JSON, and named import templates in `templates/<name>.json`.
#
# The JSON of a layout is used in three places: template files, the `layout`
# setting of the CSV importer, and the history (so a script or rerun gets the
# exact layout). A layout without `decimal` (from before it existed) reads as '.'.

using JSON3

const TEMPLATE_VERSION = 1

const ELTYPE_NAMES = Dict{String,DataType}("Float64" => Float64, "String" => String)

layout_dict(l::CsvLayout) = Dict{String,Any}(
    "delimiter" => string(l.delimiter), "fixed_widths" => l.fixed_widths,
    "heading_row" => l.heading_row, "units_row" => l.units_row, "first_data_row" => l.first_data_row,
    "columns" => [Dict{String,Any}("name" => c.name, "role" => String(c.role),
                                   "eltype" => string(c.eltype), "units" => c.units) for c in l.columns],
    "line_column" => l.line_column, "x" => l.x, "y" => l.y, "crs" => l.crs,
    "decimal" => string(l.decimal))

"The layout as JSON text, as the `layout` setting of the CSV importer takes it."
layout_json(l::CsvLayout)::String = JSON3.write(layout_dict(l))

"Read a layout from JSON text. Throws a `ToolError` that names `what` when it is not a layout."
function layout_from_json(text::AbstractString, what::AbstractString)::CsvLayout
    d = try
        plain(JSON3.read(text))
    catch e
        e isa InterruptException && rethrow()
        throw(ToolError("$what is not valid JSON."))
    end
    return layout_from_dict(d, what)
end

function layout_from_dict(d, what::AbstractString)::CsvLayout
    bad(why) = throw(ToolError("$what is not a valid import layout: $why."))
    d isa AbstractDict || bad("it is not an object")
    text(k) = (v = get(d, k, ""); v isa AbstractString ? String(v) : bad("\"$k\" must be text"))
    whole(k, default) = (v = get(d, k, default); v isa Integer && !(v isa Bool) ? Int(v) : bad("\"$k\" must be a whole number"))
    delim = text("delimiter")
    length(delim) == 1 || bad("\"delimiter\" must be one character")
    dec = haskey(d, "decimal") ? text("decimal") : "."
    length(dec) == 1 || bad("\"decimal\" must be one character")
    widths = get(d, "fixed_widths", Any[])
    (widths isa AbstractVector && all(w -> w isa Integer && !(w isa Bool), widths)) ||
        bad("\"fixed_widths\" must be a list of whole numbers")
    cols = get(d, "columns", nothing)
    cols isa AbstractVector || bad("\"columns\" must be a list")
    columns = CsvColumn[]
    for c in cols
        (c isa AbstractDict && all(k -> get(c, k, nothing) isa AbstractString, ("name", "role", "eltype"))) ||
            bad("each column needs a name, a role and an eltype as text")
        T = get(ELTYPE_NAMES, c["eltype"], nothing)
        T === nothing && bad("the eltype of column $(c["name"]) must be Float64 or String")
        u = get(c, "units", "")
        u isa AbstractString || bad("the units of column $(c["name"]) must be text")
        push!(columns, CsvColumn(String(c["name"]), Symbol(c["role"]), T, String(u)))
    end
    return CsvLayout(; delimiter = delim[1], fixed_widths = Int[w for w in widths],
                     heading_row = whole("heading_row", 0), units_row = whole("units_row", 0),
                     first_data_row = whole("first_data_row", 1), columns, line_column = text("line_column"),
                     x = text("x"), y = text("y"), crs = text("crs"), decimal = dec[1])
end

templates_folder(s::Session) = joinpath(s.project.folder, "templates")

"The file of the template `name`: `templates/<safe name>.json`."
function template_path(s::Session, name::AbstractString)::String
    slug = safe_slug(name)
    isempty(slug) && throw(ToolError("The template name \"$name\" needs at least one letter or digit."))
    return joinpath(templates_folder(s), slug * ".json")
end

"""
    save_template(s, name, layout)

Save a layout as the import template `name`, in `templates/<name>.json` of the
project. The file name is made safe: lower case letters, digits, `-` and `_`.
A template with the same name is replaced. A different name that gives the same
file name (such as `"Survey A"` and `"survey-a"`) is refused with a `ToolError`,
and so is a bad layout.
"""
function save_template(s::Session, name::AbstractString, layout::CsvLayout)
    plan_layout(layout)
    path = template_path(s, name)
    lock(s.lock) do
        old = isfile(path) ? stored_name(path) : nothing
        (old === nothing || old == name) || throw(ToolError(
            "The template name \"$name\" gives the same file name as the template \"$old\". " *
            "Choose another name, or use \"$old\" to replace that template."))
        mkpath(templates_folder(s))
        write_json_atomic(path, Dict{String,Any}("version" => TEMPLATE_VERSION, "name" => String(name),
                                                 "layout" => layout_dict(layout)))
    end
    return nothing
end

"""
    load_template(s, name) -> CsvLayout

Read the import template `name`. Throws a `ToolError` with a plain message when
there is no such template, its file is broken, or its layout cannot be used
(see `import_csv`).
"""
function load_template(s::Session, name::AbstractString)::CsvLayout
    path = template_path(s, name)
    isfile(path) || throw(ToolError("There is no import template named \"$name\"."))
    what = "The import template \"$name\""
    d = try
        plain(JSON3.read(read(path, String)))
    catch e
        e isa InterruptException && rethrow()
        throw(ToolError("$what is broken: its file is not valid JSON."))
    end
    if !(d isa AbstractDict && get(d, "version", nothing) == TEMPLATE_VERSION)
        throw(ToolError("$what is broken or from a newer version of the program."))
    end
    stored = get(d::AbstractDict, "name", name)
    stored == name || throw(ToolError("There is no import template named \"$name\"."))
    layout = layout_from_dict(get(d::AbstractDict, "layout", nothing), what)
    try
        plan_layout(layout)
    catch e
        e isa ToolError || rethrow()
        throw(ToolError("$what cannot be used: $(e.msg)"))
    end
    return layout
end

"The name stored in a template file, or `nothing` when the file cannot be read."
function stored_name(path::String)::Union{Nothing,String}
    try
        d = JSON3.read(read(path, String))
        d isa JSON3.Object || return nothing
        n = get(d, :name, nothing)
        return n isa AbstractString ? String(n) : nothing
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

"The names of the import templates of the project, sorted."
function list_templates(s::Session)::Vector{String}
    folder = templates_folder(s)
    isdir(folder) || return String[]
    names = String[]
    for f in readdir(folder)
        endswith(f, ".json") || continue
        n = stored_name(joinpath(folder, f))
        n === nothing || push!(names, n)
    end
    return sort!(names)
end

