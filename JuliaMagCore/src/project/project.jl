# A project is a folder with `project.jmag.json` that lists its items
# (line databases now; grids and maps later). Item paths are relative to the
# project folder, so the folder can be moved.
#
# Layout: project.jmag.json, databases/<folder>/, grids/, jobs/, templates/.

using JSON3, StructTypes

const PROJECT_FILE = "project.jmag.json"
const PROJECT_VERSION = 1
const PROJECT_SUBFOLDERS = ("databases", "grids", "jobs", "templates")

"An error in a project: a missing or broken file, or an unknown item."
struct ProjectError <: Exception
    msg::String
end

Base.showerror(io::IO, e::ProjectError) = print(io, "ProjectError: ", e.msg)

@enum ItemKind ITEM_DATABASE ITEM_GRID ITEM_MAP

const KIND_NAMES = Dict(ITEM_DATABASE => "database", ITEM_GRID => "grid", ITEM_MAP => "map")
const KIND_PREFIXES = Dict(ITEM_DATABASE => "db-", ITEM_GRID => "grid-", ITEM_MAP => "map-")

"An item of a project. `path` is relative to the project folder."
mutable struct ProjectItem
    id::String
    kind::ItemKind
    name::String
    path::String
    description::String
    made_by::String
end

mutable struct Project
    folder::String
    name::String
    items::Vector{ProjectItem}
    settings::Dict{String,Any}
end

# ---- file records ----------------------------------------------------------

struct ItemRecord
    id::String
    kind::String
    name::String
    path::String
    description::String
    made_by::String
end
StructTypes.StructType(::Type{ItemRecord}) = StructTypes.Struct()

struct ProjectRecord
    version::Int
    name::String
    items::Vector{ItemRecord}
    settings::Dict{String,Any}
end
StructTypes.StructType(::Type{ProjectRecord}) = StructTypes.Struct()

project_path(folder::AbstractString) = joinpath(folder, PROJECT_FILE)

ItemRecord(i::ProjectItem) = ItemRecord(i.id, KIND_NAMES[i.kind], i.name, i.path, i.description, i.made_by)

function kind_from_name(s::AbstractString, file::AbstractString)
    for (k, n) in KIND_NAMES
        n == s && return k
    end
    throw(ProjectError("$file is broken: unknown item kind \"$s\""))
end

# JSON3 returns its own object and array types. Turn them into plain Julia values.
plain(x::JSON3.Object) = Dict{String,Any}(String(k) => plain(v) for (k, v) in pairs(x))
plain(x::JSON3.Array) = Any[plain(v) for v in x]
plain(x::AbstractDict) = Dict{String,Any}(String(k) => plain(v) for (k, v) in pairs(x))
plain(x) = x

# ---- create, open, save ----------------------------------------------------

"Make a new project folder with its sub folders and write `project.jmag.json`."
function create_project(folder::String, name::String)::Project
    mkpath(folder)
    for d in PROJECT_SUBFOLDERS
        mkpath(joinpath(folder, d))
    end
    p = Project(folder, name, ProjectItem[], Dict{String,Any}())
    save_project(p)
    return p
end

"""
    open_project(folder)

Read `project.jmag.json`. Throws `ProjectError` if it is missing or broken.
A missing item is not an error here. Use `item_missing` to check an item.
"""
function open_project(folder::String)::Project
    path = project_path(folder)
    isfile(path) || throw(ProjectError("no project in $folder: $PROJECT_FILE is missing ($path)"))
    rec = try
        JSON3.read(read(path, String), ProjectRecord)
    catch e
        e isa InterruptException && rethrow()
        throw(ProjectError("$path is broken: $(sprint(showerror, e))"))
    end
    rec.version == PROJECT_VERSION ||
        throw(ProjectError("$path has version $(rec.version); this program reads version $PROJECT_VERSION"))
    items = ProjectItem[ProjectItem(r.id, kind_from_name(r.kind, path), r.name, r.path,
                                    r.description, r.made_by) for r in rec.items]
    return Project(folder, rec.name, items, plain(rec.settings))
end

"Write `project.jmag.json` atomically (see `write_json_atomic`)."
function save_project(p::Project)
    rec = ProjectRecord(PROJECT_VERSION, p.name, ItemRecord[ItemRecord(i) for i in p.items], p.settings)
    mkpath(p.folder)
    write_json_atomic(project_path(p.folder), rec)
    return nothing
end

# ---- items -----------------------------------------------------------------

"Add an item. Throws `ProjectError` if its id is already used."
function add_item!(p::Project, it::ProjectItem)
    any(i -> i.id == it.id, p.items) &&
        throw(ProjectError("the project already has an item with id \"$(it.id)\""))
    push!(p.items, it)
    return it
end

"""
    remove_item!(p, id)::ProjectItem

Take the item out of the list and return it. Files are not deleted;
the caller decides what to do with them.
"""
function remove_item!(p::Project, id::AbstractString)::ProjectItem
    k = findfirst(i -> i.id == id, p.items)
    k === nothing && throw(ProjectError("no item with id \"$id\" in project $(p.name)"))
    return popat!(p.items, k)
end

function item(p::Project, id::AbstractString)::ProjectItem
    k = findfirst(i -> i.id == id, p.items)
    k === nothing && throw(ProjectError("no item with id \"$id\" in project $(p.name)"))
    return p.items[k]
end

item_path(p::Project, it::ProjectItem) = joinpath(p.folder, split(it.path, '/')...)

"True when the item's data folder or file does not exist."
item_missing(p::Project, it::ProjectItem)::Bool = !ispath(item_path(p, it))

"A new id like `\"db-3\"`: the kind's prefix and the next unused number."
function new_item_id(p::Project, kind::ItemKind)::String
    prefix::String = KIND_PREFIXES[kind]
    used = Set{String}(i.id for i in p.items)
    n = 1
    while (prefix * string(n)) in used
        n += 1
    end
    return prefix * string(n)
end

"Open the line database of item `id`. Throws `ProjectError` if it cannot."
function database(p::Project, id::AbstractString)::LineDatabase
    it = item(p, id)
    it.kind == ITEM_DATABASE || throw(ProjectError("item \"$id\" is not a database"))
    item_missing(p, it) && throw(ProjectError("the folder of database \"$id\" is missing: $(item_path(p, it))"))
    return open_database(item_path(p, it))
end
