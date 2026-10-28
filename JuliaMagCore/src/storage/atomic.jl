# Atomic JSON writing, shared by databases and projects.

using JSON3

"""
    write_json_atomic(path, value; allow_inf = false)

Write `value` as pretty JSON to `path`. The text is first written to
`path * ".tmp"` and then moved over the old file, so a crash never
leaves a half-written file.
"""
function write_json_atomic(path::AbstractString, value; allow_inf::Bool = false)
    tmp = path * ".tmp"
    open(tmp, "w") do io
        JSON3.pretty(io, JSON3.write(value; allow_inf); allow_inf)
        println(io)
    end
    mv(tmp, path; force = true)
    return nothing
end
