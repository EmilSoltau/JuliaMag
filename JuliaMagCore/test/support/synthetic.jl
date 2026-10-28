# Helpers that build small sessions and databases for tests.
# Later tasks add to this file.

using JuliaMagCore

"A new session in a fresh temp folder."
fresh_session() = new_session(joinpath(mktempdir(), "p"), "p")

"Path of a file under `test/data`."
testdata(name::AbstractString) = joinpath(@__DIR__, "..", "data", name)

# Make a database item with one line L1001 and the given Float64 channels.
# `protected` lists the names of protected channels. Returns the item id.
function add_test_database!(s::Session, channels::Vector{Pair{String,Vector{Float64}}}; protected = String[])
    p = s.project
    id = new_item_id(p, ITEM_DATABASE)
    folder = joinpath(p.folder, "databases", id)
    db = create_database(folder, id)
    n = length(last(first(channels)))
    for (name, _) in channels
        add_channel!(db, ChannelInfo(name, name, Float64, "nT", ROLE_NONE, :normal, 10, -1,
                                     name in protected, 1))
    end
    add_line!(db, LineInfo(LineId(LINE, 1001, 0), 1, "2024-05-01", 0.0, 0.1, n, 0, true))
    apps = open_appenders(db, first.(channels))
    for (name, v) in channels
        foreach(x -> append_value!(apps[name], x), v)
    end
    close_appenders!(apps)
    save_meta(db)
    add_item!(p, ProjectItem(id, ITEM_DATABASE, id, "databases/$id", "", ""))
    save_project(p)
    return id
end

"One line L1001, 5 rows, MAG unprotected and MAGP protected. Returns the item id."
make_test_database!(s::Session) =
    add_test_database!(s, ["MAG" => [1.0, 2.0, 3.0, 4.0, 5.0], "MAGP" => [10.0, 20.0, 30.0, 40.0, 50.0]];
                       protected = ["MAGP"])

"""
    make_db_with(; channels...)

A new session with one database and one line L1001 that holds the given Float64 vectors.
Returns `(s, id, L, db)`.
"""
function make_db_with(; channels...)
    s = fresh_session()
    id = add_test_database!(s, Pair{String,Vector{Float64}}[String(k) => collect(Float64, v) for (k, v) in channels])
    return (s = s, id = id, L = LineId(LINE, 1001, 0), db = database(s.project, id))
end
