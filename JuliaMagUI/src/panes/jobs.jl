# The Jobs tab of the left pane (spec 8.5, prototype section 4.3): a top bar with the
# counts, then one card per job, newest first. A running card shows a live progress bar
# with Cancel and Report; a finished card shows how it ended, with Run Again... and Report.
# When a job leaves running, a toast says how it ended (`watch_jobs!`).
#
# Drawing reads only the snapshot, `Core.status(job)` and `job.progress[]`. Cancel, the
# report and Run Again go through the worker.

const JOBS_BAR_H = 32        # the top bar (`.ltools`), its 1 px line included
const JOBS_EMPTY = "No jobs yet. Imports and long tools run here."
const JOBS_EMPTY_H = 160     # the empty state's box (`.empty`)
const CARD_TOP = 9           # `.job` padding 9 12 10
const CARD_SIDE = 12
const CARD_BOTTOM = 10
const CARD_GAP = 5           # between the rows of a card
const CARD_INDENT = 24       # the sub lines and the bar start under the title
const CARD_ACTS = 18         # the link buttons' row starts here (`.acts` padding-left)
const CARD_ICON = 16
const SUB_SIZE = 11.5        # `.sub`: 11.5 px on lines 1.25 high
const TIME_SIZE = 11         # `.tm`
const JOB_BAR_H = 4          # `.pbar`
const ACT_H = 22             # a small button
const ERROR_LINES = 8        # a failed card shows at most this many lines of its error

const JOB_ICONS = Dict(Core.JOB_RUNNING => "clock", Core.JOB_DONE => "ok", Core.JOB_FAILED => "error",
    Core.JOB_CANCELLED => "stopped", Core.JOB_UNDONE => "undo")

# --- Texts ---

"The name of a job: the tool, importer or exporter in title case, such as \"Import Geosoft XYZ\"."
job_title(r::JobRow)::String = isempty(r.title) ? r.command : r.title

# The name of item `id`, or the id when the project no longer has it.
item_name(r::JobRow, id::AbstractString)::String = get(r.names, id, String(id))

# The file name of the job's `path`, or `""`.
function job_file(r::JobRow)::String
    path = get(r.args, "path", nothing)
    return path isa AbstractString && !isempty(path) ? basename(path) : ""
end

"""
    job_target(row) -> String

What a job works on, for its card:

- an import: the file name `->` the database it makes or appends to ("small.xyz -> small");
- an export: the item name `->` the file name ("Kangaroo Hills -> kh.csv");
- a tool with an expression (Channel Math): the expression;
- another tool: the names of its input items, by input name;
- a command no registry knows: its item, else its file.
"""
function job_target(r::JobRow)::String
    a = r.args
    file = job_file(r)
    if r.kind === :import
        isempty(file) || return string(file, " -> ", import_name(r, file))
    elseif r.kind === :export
        item = get(a, "item", nothing)
        (item isa AbstractString && !isempty(file)) && return string(item_name(r, item), " -> ", file)
    end
    isempty(r.expression) || return r.expression
    inputs = get(a, "inputs", nothing)
    if inputs isa AbstractDict && !isempty(inputs)
        ids = [inputs[k] for k in sort!(collect(keys(inputs)))]
        return join((item_name(r, string(id)) for id in ids), ", ")
    end
    item = get(a, "item", nothing)
    item isa AbstractString && return item_name(r, item)
    return file
end

# The database an import makes or appends to: the target, else the name it was given, else
# its output (when the project has it), else the file's name without extension.
function import_name(r::JobRow, file::AbstractString)::String
    a = r.args
    target = get(a, "target", nothing)
    if get(a, "mode", "new") == "append" && target isa AbstractString && !isempty(target)
        return item_name(r, target)
    end
    name = get(a, "name", nothing)
    name isa AbstractString && !isempty(name) && return String(name)
    isempty(r.outputs) || !haskey(r.names, first(r.outputs)) || return r.names[first(r.outputs)]
    return String(splitext(file)[1])
end

"""
    job_summary(row) -> String

How a job stands or ended: running: the live percent ("40 %"); done: the time it took and
what it made ("Done in 2.1 s. Made Kangaroo Hills."); cancelled: "Cancelled at 40 %.
Nothing was written."; failed: the core's error; undone: "Undone.".
"""
function job_summary(r::JobRow)::String
    st = r.status
    st == Core.JOB_RUNNING && return percent_text(r.job.progress[])
    st == Core.JOB_CANCELLED && return "Cancelled at $(percent_text(r.job.progress[])). Nothing was written."
    st == Core.JOB_FAILED && return job_text(r, r.error)
    st == Core.JOB_UNDONE && return "Undone."
    sec = elapsed(r.started, r.finished)
    head = isfinite(sec) && sec >= 0 ? "Done in $(duration_text(sec))." : "Done."
    made = made_text(r)
    return isempty(made) ? head : head * " " * made
end

"""
    job_text(row, text) -> String

A core error or warning of a job as a sentence (`sentence`), as the toasts show them. The
names the job knows (its items, and the text of its settings, such as a channel) keep
their case at the start.
"""
job_text(r::JobRow, text::AbstractString)::String = sentence(text; names = job_names(r))

function job_names(r::JobRow)::Set{String}
    names = Set{String}(values(r.names))
    for v in values(r.args)
        v isa AbstractString && push!(names, String(v))
    end
    return names
end

# "Made A, B and C." for the job's outputs, or `""`.
function made_text(r::JobRow)::String
    isempty(r.outputs) && return ""
    names = [item_name(r, id) for id in r.outputs]
    list = length(names) == 1 ? names[1] : join(names[1:end-1], ", ") * " and " * names[end]
    return "Made $list."
end

"A fraction as a whole percent, such as \"40 %\"."
percent_text(p::Real)::String = string(isfinite(p) ? round(Int, 100 * clamp(p, 0, 1)) : 0, " %")

"A time span: \"2.1 s\" under a minute (\"under 0.1 s\" for less), else \"1 min 5 s\"."
function duration_text(sec::Real)::String
    t = round(sec; digits = 1)
    t == 0 && return "under 0.1 s"
    t < 60 && return string(t, " s")
    m, s = divrem(round(Int, sec), 60)
    return string(m, " min ", s, " s")
end

"""
    JobTime

A job time read from its text: `seconds` since 1970, and whether the text named its zone
(`zoned`). Without a zone (records written on Windows had the zone's name, not an offset),
`seconds` holds the local clock time read as if it were UTC.
"""
struct JobTime
    seconds::Float64
    zoned::Bool
end

const STAMP = r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?(.*)$"
const ZONE = r"^([+-])(\d\d):?(\d\d)$"

"""
    job_time(text) -> JobTime or nothing

Read a job time in any form the core wrote: now UTC with a "Z", such as
`"2026-10-31T09:15:02.123Z"`; before that local time with `+hhmm` (milliseconds optional),
or with a zone name on Windows. `nothing` when the text is not a time.
"""
function job_time(text::AbstractString)::Union{Nothing,JobTime}
    m = match(STAMP, text)
    m === nothing && return nothing
    part(k) = parse(Int, something(m[k]))
    secs = days_from_civil(part(1), part(2), part(3)) * 86400 + part(4) * 3600 + part(5) * 60 + part(6)
    frac = m[7] === nothing ? 0.0 : part(7) / 10.0^length(something(m[7]))
    zone = strip(something(m[8]))
    zone == "Z" && return JobTime(secs + frac, true)
    z = match(ZONE, zone)
    z === nothing && return JobTime(secs + frac, false)   # no zone, or only its name
    offset = (z[1] == "-" ? -1 : 1) * (parse(Int, something(z[2])) * 3600 + parse(Int, something(z[3])) * 60)
    return JobTime(secs + frac - offset, true)
end

"""
    elapsed(started, finished) -> Float64

The seconds between two job times, or `NaN` when one cannot be read or only one of them
names its zone.
"""
function elapsed(started::AbstractString, finished::AbstractString)::Float64
    a, b = job_time(started), job_time(finished)
    (a === nothing || b === nothing || a.zoned != b.zoned) && return NaN
    return b.seconds - a.seconds
end

"""
    local_offset(t, localtime = Libc.TmStruct) -> Int

The machine's offset from UTC at time `t` (seconds since 1970), in seconds, summer time
included. `localtime(whole_seconds)` gives the local clock as a `TmStruct` does (years from
1900, months from 0); the C library's local time works on every platform. A time before
1970, not a number, or a local time that is not within 14 hours of UTC gives 0 (UTC):
some C libraries return nothing useful for those.
"""
function local_offset(t::Real, localtime = Libc.TmStruct)::Int
    (isfinite(t) && t >= 0) || return 0
    offset = try
        whole = floor(Int, t)   # inside: a time past what an Int holds throws here
        tm = localtime(whole)
        wall = days_from_civil(Int(tm.year) + 1900, Int(tm.month) + 1, Int(tm.mday)) * 86400 +
            Int(tm.hour) * 3600 + Int(tm.min) * 60 + Int(tm.sec)
        round(Int, (wall - whole) / 60) * 60
    catch e
        e isa InterruptException && rethrow()
        0
    end
    return abs(offset) <= 14 * 3600 ? offset : 0
end

"`t` (seconds since 1970) as UTC `yyyy-mm-ddTHH:MM:SS`, whole seconds."
function utc_text(t::Real)::String
    whole = floor(Int, t)
    days, secs = fldmod(whole, 86400)
    y, m, d = civil_from_days(days)
    pad(x, n = 2) = lpad(x, n, '0')
    return string(pad(y, 4), "-", pad(m), "-", pad(d), "T", pad(secs ÷ 3600), ":", pad(secs % 3600 ÷ 60), ":",
        pad(secs % 60))
end

"""
    clock_text(text, offset = the machine's offset) -> String

The local `HH:MM` of a job time, or `""`. A time with a zone is moved by `offset` seconds
from UTC; a time without one is shown as written.
"""
function clock_text(text::AbstractString, offset::Union{Nothing,Integer} = nothing)::String
    t = job_time(text)
    t === nothing && return ""
    wall = t.seconds
    t.zoned && (wall += offset === nothing ? local_offset(t.seconds) : offset)
    minutes = mod(floor(Int, wall), 86400) ÷ 60
    return string(lpad(minutes ÷ 60, 2, '0'), ":", lpad(minutes % 60, 2, '0'))
end

# The date of a day number from 1970-01-01 (the inverse of `days_from_civil`).
function civil_from_days(z::Int)::NTuple{3,Int}
    z += 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (m <= 2), m, d)
end

# Days from 1970-01-01 to a date of the proleptic Gregorian calendar (H. Hinnant's method).
function days_from_civil(y::Int, m::Int, d::Int)::Int
    y -= m <= 2
    era = fld(y, 400)
    yoe = y - era * 400
    doy = div(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

"The top bar's text: \"1 running, 2 finished\", or \"3 finished\" when none runs."
jobs_bar_text(running::Integer, total::Integer)::String =
    running == 0 ? "$total finished" : "$running running, $(total - running) finished"

# --- Actions ---

"""
    job_owner(command) -> ToolSpec, ImporterSpec, ExporterSpec or nothing

The job tool, importer or exporter that runs `command`, or `nothing` when no registry has
it (then the job cannot run again). Reads only the registries.
"""
function job_owner(command::AbstractString)
    t = Core.find_tool(command)
    t !== nothing && t.mode == :job && return t
    for list in (Core.importers(), Core.exporters())
        k = findfirst(x -> x.id == command, list)
        k === nothing || return list[k]
    end
    return nothing
end

"""
    run_again!(app, row)

Open the job's dialog (see `open_form`) with the settings it ran with. Its OK runs
`rerun!` with the settings and, when the job made items, "Replace the old output".
"""
function run_again!(app, r::JobRow)
    owner = job_owner(r.command)
    if owner === nothing
        toast!(app, :error, "$(job_title(r)) cannot run again: no tool runs \"$(r.command)\" now.")
        return nothing
    end
    open_form(app, owner; args = r.args, rerun_of = r.job)
    return nothing
end

"""
    offers_replace(app, form) -> Bool

Does a Run Again dialog show "Replace the old output"? Only when the job it runs again is
done and an item it made is still in the project (not after an undo). Reads the snapshot.
"""
function offers_replace(app, f::Form)::Bool
    job = f.rerun_of
    snap = app.snap
    (job === nothing || snap === nothing) && return false
    k = findfirst(r -> r.job === job, snap.jobs)
    k === nothing && return false
    r = snap.jobs[k]
    r.status == Core.JOB_DONE || return false
    return any(it -> it.id in r.outputs, snap.items)
end

"Ask a running job to stop, through the worker."
function cancel_job!(app, r::JobRow)
    job = r.job
    submit!(app, "Cancel $(job_title(r))", s -> Core.cancel!(job))
    return nothing
end

"""
    show_report!(app, row)

Read the job's report, warnings and error on the worker (the report is a copy of a
buffer), then open the Job Report dialog, unless the project changed meanwhile.
"""
function show_report!(app, r::JobRow)
    job = r.job
    session = app.session
    read_report = s -> (Core.report_text(job), Core.job_warnings(job),
        Core.status(job) == Core.JOB_FAILED ? job.error : "")
    submit!(app, "Read the report of $(job.id)", read_report;
        done = (app, res) -> begin
            app.session === session || return nothing   # it was for the old project
            push_dialog!(app, job_report_dialog(r, res[1], res[2]; failure = res[3]))
            nothing
        end)
    return nothing
end

"""
    job_report_dialog(row, report, warnings; failure = row's error if it failed) -> ResultDialog

The Job Report dialog: the report text (its "Warning: " lines in amber), then the warnings
the report does not hold yet, the error of a failed job, and the settings as `key = value`
(values as JSON), sorted by key.
"""
function job_report_dialog(r::JobRow, report::AbstractString, warnings::Vector{String};
        failure::AbstractString = r.status == Core.JOB_FAILED ? r.error : "")::ResultDialog
    lines, kinds = String[], Symbol[]
    add(line, kind) = (push!(lines, String(line)); push!(kinds, kind); nothing)
    text = String[String(l) for l in split(rstrip(report, '\n'), '\n')]
    if isempty(strip(report))
        add("The job wrote no report.", :dim)
    else
        for l in text
            add(l, startswith(l, "Warning: ") ? :warn : :text)
        end
    end
    extra = [w for w in warnings if !("Warning: " * w in text)]
    if !isempty(extra)
        add("", :text)
        add("Warnings:", :dim)
        foreach(w -> add("  " * w, :warn), extra)
    end
    if !isempty(failure)
        add("", :text)
        add("Error:", :dim)
        foreach(l -> add("  " * l, :error), split(failure, '\n'))
    end
    add("", :text)
    add("Settings:", :dim)
    isempty(r.args) && add("  None", :dim)
    for k in sort!(collect(keys(r.args)))
        add("  $k = " * setting_text(r, k, r.args[k]), :text)
    end
    return ResultDialog("Job Report: " * job_title(r), lines, kinds)
end

# A setting's value for the report, as JSON (Inf and NaN too). Item ids show the item's
# name with the id: `inputs`, an export's `item` and an append's `target`.
function setting_text(r::JobRow, key::AbstractString, v)::String
    named(id) = haskey(r.names, id) ? "$(r.names[id]) ($id)" : String(id)
    if key == "inputs" && v isa AbstractDict
        value(x) = JSON3.write(x isa AbstractString ? named(x) : x; allow_inf = true)
        parts = ["$(JSON3.write(string(k))): $(value(x))" for (k, x) in sort!(collect(v); by = first)]
        return "{" * join(parts, ", ") * "}"
    end
    key in ("item", "target") && v isa AbstractString && !isempty(v) && return JSON3.write(named(v))
    return JSON3.write(v; allow_inf = true)
end

# --- Toasts ---

"""
    watch_jobs!(app)

Once per new snapshot: a toast for each job that left running since the last snapshot,
whoever started it (a dialog, a script, Run Again). A job gets one toast. The jobs of the
project's first snapshot get none: they ended before the app saw them.
"""
function watch_jobs!(app)
    snap = app.snap
    ui = app.ui
    (snap === nothing || snap === ui.jobs_watched) && return nothing
    ui.jobs_watched = snap
    seen = ui.jobs_seen
    if seen === nothing
        ui.jobs_seen = Dict{String,Core.JobStatus}(r.id => r.status for r in snap.jobs)
        return nothing
    end
    for r in snap.jobs
        before = get(seen, r.id, Core.JOB_RUNNING)   # a job new to us ran in this session
        seen[r.id] = r.status
        before == Core.JOB_RUNNING && r.status != Core.JOB_RUNNING && job_ended_toast!(app, r)
    end
    return nothing
end

# The toast of a job that left running. It replaces the job's "started" toast.
function job_ended_toast!(app, r::JobRow)
    title = job_title(r)
    session = app.session
    # An action from a toast of an old project does nothing.
    same(f) = a -> (a.session === session ? f(a) : nothing)
    if r.status == Core.JOB_DONE
        toast!(app, :ok, "$title done."; sub = made_text(r), job = r.id)
    elseif r.status == Core.JOB_FAILED
        actions = Pair{String,Function}["Report" => same(a -> show_report!(a, r))]
        job_owner(r.command) === nothing || push!(actions, "Run Again..." => same(a -> run_again!(a, r)))
        toast!(app, :error, "$title failed."; sub = first(job_text(r, r.error), 300), actions, ms = TOAST_JOB_FAILED_MS,
            job = r.id)
    elseif r.status == Core.JOB_CANCELLED
        toast!(app, :info, "$title cancelled."; sub = "Nothing was written.", job = r.id)
    end
    return nothing
end

# --- Layout ---
#
# Cards are laid out per job and cached by what they show and their width, so a long job
# history is measured once, and only for the cards that come into view. Cards not drawn yet
# get their height from an estimate of their wrapped lines, which drawing then corrects.

const CARD_WARNINGS = 3   # a card shows at most this many warnings; Report shows all

"The warnings a card shows: the first $(CARD_WARNINGS), then \"And N more warnings. See Report.\"."
card_warnings(r::JobRow)::Vector{String} = card_warnings([job_text(r, w) for w in r.warnings])

function card_warnings(warnings::Vector{String})::Vector{String}
    length(warnings) <= CARD_WARNINGS && return copy(warnings)
    n = length(warnings) - CARD_WARNINGS
    return vcat(warnings[1:CARD_WARNINGS], "And $n more warning$(n == 1 ? "" : "s"). See Report.")
end

"What a card shows, measured to fit its width: the texts, the lines and whether it can run again."
struct CardText
    title::String
    target::String
    time::String
    summary::Vector{String}
    warnings::Vector{String}
    rerun::Bool
end

"""
    CardEntry

The card of one job at one width and scale. `key` is a hash of what it shows (`card_key`).
Until the card is first drawn, `text` is `nothing` and its line counts are estimates; the
height follows the line counts.
"""
mutable struct CardEntry
    key::UInt64
    width::Float32
    scale::Float32
    has_target::Bool
    summary_lines::Int
    warning_lines::Int
    height::Float32
    text::Union{Nothing,CardText}
end

"""
    JobsView

The layout of the Jobs tab's cards:

- `snap`, `width`, `height`, `scale`: the snapshot and the list's box it was built for;
  `x0`, `y0`: where that box was drawn last (tests read them).
- `bar`: the scrollbar shows; `card_w`: the cards' width (10 px less with the bar). It is
  the one answer to "does the list overflow": `bar == (total > height)` whenever a frame
  draws, and `scroll_area!` gets the same `total` (see `draw_job_cards`).
- `keys`: the `card_key` of each row of `snap`, worked out once per build.
- `entries`: the card of each job, by id. They outlive snapshots: a job whose card did
  not change is not measured again.
- `tops`: each card's top, from the list's top; `total`: the list's height (device px).
- `measured`: how many cards were measured since the project opened; `drawn`: how many
  cards the last frame drew (tests read both).
"""
mutable struct JobsView
    snap::Union{Nothing,Snapshot}
    width::Float32
    height::Float32
    scale::Float32
    x0::Float32
    y0::Float32
    bar::Bool
    card_w::Float32
    keys::Vector{UInt64}
    entries::Dict{String,CardEntry}
    tops::Vector{Float32}
    total::Float32
    measured::Int
    drawn::Int
end

JobsView() = JobsView(nothing, 0f0, 0f0, 0f0, 0f0, 0f0, false, 0f0, UInt64[], Dict{String,CardEntry}(),
    Float32[], 0f0, 0, 0)

# A hash of what a card shows. A running card's percent and bar are read live, so they
# are not in it.
function card_key(r::JobRow)::UInt64
    r.status == Core.JOB_RUNNING && return hash((r.status, r.command, job_title(r), job_target(r)))
    return hash((r.status, r.command, job_title(r), job_target(r), job_summary(r), r.warnings, r.started))
end

# The lines `text` likely wraps to at `width`, without measuring (about 0.55 em a character).
function estimate_lines(text::AbstractString, width::Real, scale::Real)::Int
    per_line = max(1, floor(Int, width / (0.55 * SUB_SIZE * scale)))
    return sum(p -> max(1, cld(length(p), per_line)), split(text, '\n'))
end

# The text width of a card's sub lines.
card_text_w(width::Real, scale::Real) = Float32(width) - fpx(scale, 2 * CARD_SIDE + CARD_INDENT)

# A card's height from its line counts (see `draw_job_card` for the rows).
function card_height(r::JobRow, has_target::Bool, summary_lines::Int, warning_lines::Int,
        scale::Real)::Float32
    p(v) = fpx(scale, v)
    sub_h = p(SUB_SIZE * 1.25)
    h = p(CARD_TOP + CARD_ICON + CARD_GAP) + (has_target ? sub_h : 0f0)
    h += r.status == Core.JOB_RUNNING ? p(CARD_GAP + JOB_BAR_H) : p(CARD_GAP) + summary_lines * sub_h
    warning_lines > 0 && (h += p(CARD_GAP) + warning_lines * sub_h)
    return h + p(CARD_GAP + ACT_H + CARD_BOTTOM) + hairline(scale)
end

# A new card entry with estimated line counts.
function estimated_entry(r::JobRow, key::UInt64, width::Float32, scale::Float32)::CardEntry
    text_w = card_text_w(width, scale)
    summary = r.status == Core.JOB_RUNNING ? 0 :
        r.status == Core.JOB_FAILED ? min(ERROR_LINES, estimate_lines(job_summary(r), text_w, scale)) : 1
    warnings = sum((estimate_lines(w, text_w, scale) for w in card_warnings(r)); init = 0)
    has_target = !isempty(job_target(r))
    return CardEntry(key, width, scale, has_target, summary, warnings,
        card_height(r, has_target, summary, warnings, scale), nothing)
end

"""
    card_text(r, width, scale, measure, wrap) -> CardText

Measure the card of job `r` at `width` device px: the title (semibold 12.5) cut to leave
room for the time, the target and the summary (11.5) cut to fit; a failed job's error
wraps, at most $(ERROR_LINES) lines; the warnings (`card_warnings`) wrap.
`measure(role, size, text)` and `wrap(role, size, text, max_width)` work in device px.
"""
function card_text(r::JobRow, width::Real, scale::Real, measure, wrap)::CardText
    running = r.status == Core.JOB_RUNNING
    time = running ? "" : clock_text(r.started)
    text_w = card_text_w(width, scale)
    title_w = text_w - measure(FONT_REGULAR, TIME_SIZE, running ? "100 %" : time) - fpx(scale, 8)
    title = elide(measure, job_title(r), title_w; role = FONT_SEMIBOLD, size = BODY_FONT_SIZE)
    target = elide(measure, job_target(r), text_w; size = SUB_SIZE)
    summary = String[]
    if r.status == Core.JOB_FAILED
        summary = wrap(FONT_REGULAR, SUB_SIZE, job_summary(r), text_w)
        if length(summary) > ERROR_LINES
            summary = summary[1:ERROR_LINES]
            summary[end] = elide(measure, summary[end] * " ...", text_w; size = SUB_SIZE)
        end
    elseif !running
        summary = [elide(measure, job_summary(r), text_w; size = SUB_SIZE)]
    end
    warnings = String[]
    for w in card_warnings(r)
        append!(warnings, wrap(FONT_REGULAR, SUB_SIZE, w, text_w))
    end
    return CardText(title, target, time, summary, warnings, job_owner(r.command) !== nothing)
end

# The card of `r` (whose `card_key` is `key`) at `width`: the cached one when nothing
# changed, else a new estimate.
function fit_card!(v::JobsView, r::JobRow, key::UInt64, width::Float32, scale::Float32)::CardEntry
    old = get(v.entries, r.id, nothing)
    (old !== nothing && old.key == key && old.width == width && old.scale == scale) && return old
    e = estimated_entry(r, key, width, scale)
    # A card measured at another width bounds the estimate: a narrower card is never
    # shorter, a wider one never taller. So a switch of the scrollbar cannot make the list
    # look shorter or longer than it is (T12-P4).
    if old !== nothing && old.text !== nothing && old.key == key && old.scale == scale
        h = width < old.width ? max(e.height, old.height) : min(e.height, old.height)
        e = CardEntry(e.key, e.width, e.scale, e.has_target, e.summary_lines, e.warning_lines, h, nothing)
    end
    v.entries[r.id] = e
    return e
end

# The tops of the cards and the list's height, from the entries.
function place_cards!(v::JobsView, rows::Vector{JobRow})
    resize!(v.tops, length(rows))
    y = 0f0
    for (k, r) in enumerate(rows)
        v.tops[k] = y
        y += v.entries[r.id].height
    end
    v.total = y
    return nothing
end

"""
    jobs_view!(app, snap, view) -> JobsView

The cards' layout for `snap` in the list box `view`, built again only when the snapshot,
the box size or the scale changed. No text is measured here. The scrollbar choice of the
last build is kept when the box size did not change, so a new snapshot of the same jobs
cannot flip it; a first build guesses from the estimated heights at the narrow width.
`draw_job_cards` then checks the choice against the measured cards (`settle_bar!`).
"""
function jobs_view!(app, snap::Snapshot, view::Box)::JobsView
    s = Float32(app.window.scale)
    v = app.ui.jobs_cache
    v isa JobsView || (v = app.ui.jobs_cache = JobsView())
    v.x0, v.y0 = view.x0, view.y0
    w, h = width(view), height(view)
    v.snap === snap && v.width == w && v.height == h && v.scale == s && return v
    rows = snap.jobs
    v.keys = UInt64[card_key(r) for r in rows]
    ids = Set(r.id for r in rows)
    filter!(kv -> first(kv) in ids, v.entries)
    narrow = w - fpx(s, SCROLLBAR_W)
    if !(v.snap !== nothing && v.width == w && v.height == h && v.scale == s)
        total = 0f0
        for (r, key) in zip(rows, v.keys)
            e = get(v.entries, r.id, nothing)
            fits = e !== nothing && e.key == key && e.width == narrow && e.scale == s
            total += fits ? something(e).height : estimated_entry(r, key, narrow, s).height
        end
        v.bar = total > h
    end
    v.snap, v.width, v.height, v.scale = snap, w, h, s
    lay_out!(v, rows)
    return v
end

# Fit every card at the width the scrollbar choice gives, and place them.
function lay_out!(v::JobsView, rows::Vector{JobRow})
    v.card_w = v.bar ? v.width - fpx(v.scale, SCROLLBAR_W) : v.width
    for (r, key) in zip(rows, v.keys)
        fit_card!(v, r, key, v.card_w, v.scale)
    end
    place_cards!(v, rows)
    return nothing
end

"""
    settle_bar!(app, v, rows, scroll) -> scroll

Make the scrollbar choice agree with the cards' height, as `scroll_area!` will see it:
when the list overflows without the bar, or fits with it, lay the cards out once at the
other width and measure the ones in view. One switch is enough: wider cards are never
taller, and `fit_card!` keeps the estimates of measured cards on that side. The card at the
top of the view keeps its place. Returns the scroll.
"""
function settle_bar!(app, v::JobsView, rows::Vector{JobRow}, scroll::Float32)::Float32
    (v.total > v.height) == v.bar && return scroll
    # The card at the top of the view stays there, so the visible cards do not jump.
    k = first(cards_in_view(v, scroll, v.height))
    into = k <= length(v.tops) ? scroll - v.tops[k] : 0f0
    v.bar = !v.bar
    lay_out!(v, rows)
    k <= length(v.tops) && (scroll = v.tops[k] + into)
    scroll = clamp(scroll, 0f0, max(v.total - v.height, 0f0))
    return measure_cards!(app, v, rows, scroll, v.height)
end

# The cards that overlap the band `scroll .. scroll + h` of the list.
function cards_in_view(v::JobsView, scroll::Real, h::Real)::UnitRange{Int}
    n = length(v.tops)
    n == 0 && return 1:0
    first = max(1, searchsortedlast(v.tops, Float32(scroll)))
    last = searchsortedlast(v.tops, Float32(scroll + h) - 0.001f0)
    return first:max(first - 1, min(last, n))
end

"""
    measure_cards!(app, v, rows, scroll, h) -> scroll

Measure the cards in view that were not measured yet, so they can be drawn. A card whose
height changes moves the cards under it; one that starts above the view also moves the
scroll by the change, so what the user looks at stays put. Returns the new scroll.
"""
function measure_cards!(app, v::JobsView, rows::Vector{JobRow}, scroll::Float32, h::Float32)::Float32
    measure = (role, size, text) -> text_width(role, size, text)
    for _ in 1:4   # a card that grows less can bring the next one into view
        moved = false
        for k in cards_in_view(v, scroll, h)
            r = rows[k]
            e = v.entries[r.id]
            e.text === nothing || continue
            t = card_text(r, e.width, e.scale, measure, wrap_lines)
            e.text = t
            e.summary_lines, e.warning_lines = length(t.summary), length(t.warnings)
            new_h = card_height(r, e.has_target, e.summary_lines, e.warning_lines, e.scale)
            v.measured += 1
            new_h == e.height && continue
            v.tops[k] < scroll && (scroll += new_h - e.height)
            e.height = new_h
            moved = true
        end
        moved || break
        place_cards!(v, rows)
    end
    return scroll
end

# --- Drawing ---

"""
    draw_jobs_tab(app, dl, body)

The Jobs tab in box `body`: the 32 px top bar ("1 running, 2 finished", 11.5 `text_dim`,
a 1 px `border` line under it) and the cards, newest first, scrolled with `scroll_area!`.
Only the cards in view are drawn and take input. With no job: "No jobs yet. Imports and
long tools run here." centred in a 160 px box.
"""
function draw_jobs_tab(app, dl, body::Box)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    snap = app.snap
    rows = snap === nothing ? JobRow[] : snap.jobs
    ig.PushID("jobs")
    bar = Box(body.x0, body.y0, body.x1, body.y0 + fpx(s, JOBS_BAR_H))
    running = running_jobs(snap)
    draw_text_mid(dl, FONT_REGULAR, SUB_SIZE, bar.x0 + fpx(s, 12), (bar.y0 + bar.y1 - hl) / 2,
        u32(t.text_dim), jobs_bar_text(running, length(rows)))
    line = rnd(bar.y1 - hl)
    ig.AddRectFilled(dl, (bar.x0, line), (bar.x1, line + hl), u32(t.border))
    view = Box(body.x0, line + hl, body.x1, body.y1)
    empty!(app.ui.job_bars)
    if isempty(rows)
        app.ui.jobs_scroll = 0f0
        draw_jobs_empty(app, dl, Box(view.x0, view.y0, view.x1, view.y0 + fpx(s, JOBS_EMPTY_H)))
    else
        draw_job_cards(app, dl, view, something(snap))
    end
    ig.PopID()
    return nothing
end

# The `.empty` state: centred lines 1.6 high, `text_dim`.
function draw_jobs_empty(app, dl, b::Box)
    s = app.window.scale
    lines = wrap_lines(FONT_REGULAR, BODY_FONT_SIZE, JOBS_EMPTY, width(b))
    lh = fpx(s, BODY_FONT_SIZE * 1.6)
    y = centre_y(b) - length(lines) * lh / 2
    for l in lines
        tw = text_width(FONT_REGULAR, BODY_FONT_SIZE, l)
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, b.x0 + (width(b) - tw) / 2, y + lh / 2,
            u32(app.tokens.text_dim), l; line = 1.6)
        y += lh
    end
    return nothing
end

function draw_job_cards(app, dl, view::Box, snap::Snapshot)
    s = app.window.scale
    ui = app.ui
    rows = snap.jobs
    v = jobs_view!(app, snap, view)
    h = height(view)
    scroll = clamp(ui.jobs_scroll, 0f0, max(v.total - h, 0f0))
    scroll = measure_cards!(app, v, rows, scroll, h)
    scroll = settle_bar!(app, v, rows, scroll)   # now `v.bar == (v.total > h)`, as scroll_area! sees it
    ui.jobs_scroll, _ = scroll_area!(app, "scrollbar", view, v.total, scroll)
    right = view.x0 + v.card_w
    ig.PushClipRect((view.x0, view.y0), (right, view.y1), true)
    range = cards_in_view(v, ui.jobs_scroll, h)
    for k in range
        e = v.entries[rows[k].id]
        e.text === nothing && continue   # comes into view at the next frame's measure
        top = view.y0 + v.tops[k] - ui.jobs_scroll
        draw_job_card(app, dl, rows[k], something(e.text), Box(view.x0, top, right, top + e.height))
    end
    v.drawn = length(range)
    ig.PopClipRect()
    return nothing
end

"Cancel's label: \"Cancelling...\" once the job was asked to stop (an atomic read)."
cancel_label(r::JobRow)::String = r.job.cancel[] ? "Cancelling..." : "Cancel"

"""
    draw_job_card(app, dl, row, text, b)

One card in box `b`, with its measured `text`. A running card reads the live
`job.progress[]` for its percent and bar, and keeps frames coming so the bar moves. Its
buttons are Cancel and Report; Cancel reads "Cancelling..." and takes no clicks once
asked. A finished card has Run Again... (when its command is known) and Report.
"""
function draw_job_card(app, dl, r::JobRow, c::CardText, b::Box)
    w = app.window::Window
    s = w.scale
    t = app.tokens
    p(v) = fpx(s, v)
    hl = hairline(s)
    sub_h = p(SUB_SIZE * 1.25)
    running = r.status == Core.JOB_RUNNING
    ig.PushID(r.id)
    x = b.x0 + p(CARD_SIDE)
    text_x = x + p(CARD_INDENT)
    y = b.y0 + p(CARD_TOP)
    mid = y + p(CARD_ICON / 2)
    draw_icon(dl, JOB_ICONS[r.status], (rnd(x), rnd(y)), CARD_ICON)
    progress = r.job.progress[]
    right = running ? percent_text(progress) : c.time
    rw = text_width(FONT_REGULAR, TIME_SIZE, right)
    draw_text_mid(dl, FONT_REGULAR, TIME_SIZE, b.x1 - p(CARD_SIDE) - rw, mid, u32(t.text_dim), right)
    name_col = r.status == Core.JOB_CANCELLED ? t.text_dim : t.text
    draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, text_x, mid, u32(name_col), c.title)
    y += p(CARD_ICON + CARD_GAP)
    if !isempty(c.target)
        draw_text_mid(dl, FONT_REGULAR, SUB_SIZE, text_x, y + sub_h / 2, u32(t.text_dim), c.target)
        y += sub_h
    end
    y += p(CARD_GAP)
    if running
        bar = snap(Box(text_x, y, b.x1 - p(CARD_SIDE), y + p(JOB_BAR_H)))
        radius = height(bar) / 2
        ig.AddRectFilled(dl, (bar.x0, bar.y0), (bar.x1, bar.y1), u32(t.well), radius)
        fill = width(bar) * Float32(isfinite(progress) ? clamp(progress, 0, 1) : 0)
        fill > 0 && ig.AddRectFilled(dl, (bar.x0, bar.y0), (bar.x0 + round(fill), bar.y1),
            u32(t.accent), radius)
        app.ui.job_bars[r.id] = bar
        request_frames!(w, 0.05)   # the bar follows the progress
        y += p(JOB_BAR_H)
    else
        col = r.status == Core.JOB_FAILED ? t.red : t.text_dim
        for l in c.summary
            draw_text_mid(dl, FONT_REGULAR, SUB_SIZE, text_x, y + sub_h / 2, u32(col), l)
            y += sub_h
        end
    end
    if !isempty(c.warnings)
        y += p(CARD_GAP)
        for l in c.warnings
            draw_text_mid(dl, FONT_REGULAR, SUB_SIZE, text_x, y + sub_h / 2, u32(t.amber), l)
            y += sub_h
        end
    end
    y += p(CARD_GAP)
    ax = x + p(CARD_ACTS)
    ids = running ? ["Cancel", "Report"] : c.rerun ? ["Run Again...", "Report"] : ["Report"]
    for id in ids
        label = id == "Cancel" ? cancel_label(r) : id
        enabled = label != "Cancelling..."
        if button(app, id, label, ax, y; small = true, link = true, enabled)
            id == "Cancel" ? cancel_job!(app, r) : id == "Report" ? show_report!(app, r) : run_again!(app, r)
        end
        ax += round(button_width(app, label; small = true, link = true)) + p(4)
    end
    line = rnd(b.y1 - hl)
    ig.AddRectFilled(dl, (b.x0, line), (b.x1, line + hl), u32(t.border))
    ig.PopID()
    return nothing
end
