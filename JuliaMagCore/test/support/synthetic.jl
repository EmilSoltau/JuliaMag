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

"Open the database that an import made, in the session the test created."
database_of(s::Session, r::ImportResult) = database(s.project, r.item.id)

# A small random number source, so tests need no Random dependency.
# xorshift64; returns a Float64 in [0, 1).
mutable struct TestRng
    x::UInt64
end
TestRng(seed::Integer) = TestRng(UInt64(seed) * 0x9e3779b97f4a7c15 + 1)
function next_unit!(r::TestRng)::Float64
    x = r.x
    x ⊻= x << 13
    x ⊻= x >> 7
    x ⊻= x << 17
    r.x = x
    return (x >> 11) * 2.0^-53
end

"""
    write_synthetic_xyz(path; lines, ties, rows_per_line, channels, crlf, bom, seed) -> (lines, rows)

Write a valid Geosoft XYZ file: a `/` header with the channel names, a `//Flight`
and `//Date` record, then `Line 1001, 1002, ...` blocks and `Tie 901, 902, ...` blocks.
`X`, `Y` and `FIDUCIAL` are regular; other channels are random and every 97th
value is `*`. FIDUCIAL counts up by 1 from 0 on each line.
Returns the number of lines and rows written.
"""
function write_synthetic_xyz(path::AbstractString; lines::Integer = 10, ties::Integer = 2,
                             rows_per_line::Integer = 1000,
                             channels::Vector{String} = ["X", "Y", "FIDUCIAL", "MAG", "ALT"],
                             crlf::Bool = false, bom::Bool = false, seed::Integer = 1)
    rng = TestRng(seed)
    nl = crlf ? "\r\n" : "\n"
    blocks = vcat([("Line", 1000 + k) for k in 1:lines], [("Tie", 900 + k) for k in 1:ties])
    open(path, "w") do io
        bom && write(io, [0xef, 0xbb, 0xbf])
        print(io, "/ synthetic test data", nl)
        print(io, "/ ", join(channels, " "), nl)
        print(io, "//Flight 7", nl, "//Date 2024/05/01", nl)
        buf = IOBuffer()
        count = 0
        for (b, (kind, number)) in enumerate(blocks)
            print(buf, kind, " ", number, nl)
            for row in 1:rows_per_line
                count += 1
                for (k, c) in enumerate(channels)
                    k > 1 && print(buf, ' ')
                    u = c == "X" ? 500000.0 + 10.0 * row :
                        c == "Y" ? 7.0e6 + 100.0 * b :
                        c == "FIDUCIAL" ? Float64(row - 1) :
                        count % 97 == k ? NaN : round(50000.0 + 100.0 * next_unit!(rng); digits = 3)
                    isnan(u) ? print(buf, '*') : print(buf, u)
                end
                print(buf, nl)
                buf.size > (1 << 16) && write(io, take!(buf))
            end
        end
        write(io, take!(buf))
    end
    return (lines = length(blocks), rows = length(blocks) * rows_per_line)
end
