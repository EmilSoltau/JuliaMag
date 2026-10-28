# A short tour of JuliaMagCore, driven from the REPL.
# Run it from the repository root:
#   JULIA_NUM_THREADS=4 julia --project=JuliaMagCore examples/quickstart.jl

using JuliaMagCore

# Make a small test file with 3 lines and 1 tie line, 500 rows each.
# It has longitude and latitude near 15E, 62N.
work = mktempdir()
xyz = joinpath(work, "flight data.xyz")
open(xyz, "w") do io
    println(io, "/ LON LAT X Y FIDUCIAL MAG")
    for (b, name) in enumerate(["Line 1001", "Line 1002", "Line 1003", "Tie 901"])
        println(io, name)
        for row in 1:500
            lon = 15.0 + 0.0001 * row + 0.01 * b
            lat = 62.0 + 0.0001 * row + 0.01 * b
            mag = 50000.0 + 100.0 * sin(row / 20) + b
            println(io, lon, " ", lat, " ", 500000.0 + 10 * row, " ", 7.0e6 + 100.0 * b, " ", row - 1, " ", mag)
        end
    end
end

# Make a new project. The folder name may hold spaces.
s = new_session(joinpath(work, "my project"), "Quickstart")

# Import the file. An import is a job, so wait for it to finish.
job = wait_job(import_file(s, xyz))
println("Import: ", status(job))
id = only(job.outputs)

# Guess the UTM zone from longitude and latitude.
ok, message, _ = run_tool(s, "coordinates.guess_utm"; inputs = Dict("database" => id))
println(message)

# Reproject the position to that zone.
job = wait_job(run_tool(s, "coordinates.reproject"; inputs = Dict("database" => id),
                        pair = "LON,LAT", crs = "EPSG:32633"))
println("Reproject: ", status(job))

# Make a new channel with Channel Math.
job = wait_job(run_tool(s, "database.channel_math"; inputs = Dict("database" => id),
                        expr = "MAG_C = MAG - 50000", lines = "all"))
println("Channel Math: ", status(job))

# Change one value of the new channel. Imported channels are protected.
line = LineId(LINE, 1001, 0)
db = database(s.project, id)
println("Before: ", read_channel(db, line, "MAG_C")[5])
set_cell!(s, id, line, "MAG_C", 5, 0.0)
println("Edited: ", read_channel(database(s.project, id), line, "MAG_C")[5])

# Undo the edit.
undo!(s)
println("After undo: ", read_channel(database(s.project, id), line, "MAG_C")[5])

# Export the database to CSV. An export is a job too.
csv = joinpath(work, "result.csv")
job = wait_job(export_file(s, id, csv))
println("Export: ", status(job), ", ", countlines(csv), " lines in ", csv)

# Save the history as a Julia script. Run it later to repeat these steps.
script = joinpath(work, "steps.jl")
write(script, script_text(s))
println("Script saved to ", script)
println(script_text(s))
