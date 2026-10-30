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
    st == Core.JOB_FAILED && return r.error
    st == Core.JOB_UNDONE && return "Undone."
    sec = stamp_seconds(r.finished) - stamp_seconds(r.started)
    head = isfinite(sec) && sec >= 0 ? "Done in $(duration_text(sec))." : "Done."
    made = made_text(r)
    return isempty(made) ? head : head * " " * made
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

"The `HH:MM` of a job time, or `\"\"`."
function clock_text(stamp::AbstractString)::String
    m = match(r"T(\d\d:\d\d)", stamp)
    return m === nothing ? "" : String(something(m[1]))
end

const STAMP = r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?(?:([+-])(\d\d)(\d\d))?$"

"""
    stamp_seconds(stamp) -> Float64

A job time such as `"2026-10-30T10:43:02.123+1000"` as seconds since 1970 (UTC), or `NaN`
when it is not one. Milliseconds and the zone are optional, as in older job records.
"""
function stamp_seconds(stamp::AbstractString)::Float64
    m = match(STAMP, stamp)
    m === nothing && return NaN
    part(k) = parse(Int, something(m[k]))
    secs = days_from_civil(part(1), part(2), part(3)) * 86400 + part(4) * 3600 + part(5) * 60 + part(6)
    frac = m[7] === nothing ? 0.0 : part(7) / 10.0^length(something(m[7]))
    zone = m[8] === nothing ? 0 : (m[8] == "-" ? -1 : 1) * (part(9) * 3600 + part(10) * 60)
    return secs + frac - zone
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

Does a Run Again dialog show "Replace the old output"? Only when the job it runs again
made items. Reads the snapshot.
"""
function offers_replace(app, f::Form)::Bool
    job = f.rerun_of
    snap = app.snap
    (job === nothing || snap === nothing) && return false
    k = findfirst(r -> r.job === job, snap.jobs)
    return k !== nothing && !isempty(snap.jobs[k].outputs)
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
buffer), then open the Job Report dialog.
"""
function show_report!(app, r::JobRow)
    job = r.job
    read_report = s -> (Core.report_text(job), Core.job_warnings(job),
        Core.status(job) == Core.JOB_FAILED ? job.error : "")
    submit!(app, "Read the report of $(job.id)", read_report;
        done = (app, res) -> begin
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
        add("  $k = " * JSON3.write(r.args[k]), :text)
    end
    return ResultDialog("Job Report: " * job_title(r), lines, kinds)
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

# The toast of a job that left running.
function job_ended_toast!(app, r::JobRow)
    title = job_title(r)
    session = app.session
    # An action from a toast of an old project does nothing.
    same(f) = a -> (a.session === session ? f(a) : nothing)
    if r.status == Core.JOB_DONE
        toast!(app, :ok, "$title done."; sub = made_text(r))
    elseif r.status == Core.JOB_FAILED
        actions = Pair{String,Function}["Report" => same(a -> show_report!(a, r))]
        job_owner(r.command) === nothing || push!(actions, "Run Again..." => same(a -> run_again!(a, r)))
        toast!(app, :error, "$title failed."; sub = first(r.error, 300), actions, ms = TOAST_JOB_FAILED_MS)
    elseif r.status == Core.JOB_CANCELLED
        toast!(app, :info, "$title cancelled."; sub = "Nothing was written.")
    end
    return nothing
end

# --- Layout ---

"One card: its height, its texts cut to fit, and whether it can run again."
struct CardLayout
    height::Float32
    title::String
    target::String
    summary::Vector{String}
    warnings::Vector{String}
    rerun::Bool
end

"""
    JobsLayout

The cards of one snapshot at one width and scale (`card_layout`), and the top of each,
from the top of the list, in device pixels. `total` is the list's height.
"""
struct JobsLayout
    snap::Snapshot
    width::Float32
    scale::Float32
    cards::Vector{CardLayout}
    tops::Vector{Float32}
    total::Float32
end

"""
    card_layout(r, width, scale, measure, wrap) -> CardLayout

Lay out the card of job `r`, `width` device px wide, as the prototype's `.job`: padding
9 12 10, rows 5 apart, a 1 px line under it. The rows: a 16 px row with the icon, the title
(semibold 12.5, cut to fit) and the time on the right; the target (11.5, cut); then the
4 px bar while it runs, or the summary (cut; a failed job's error wraps, red, at most
$(ERROR_LINES) lines); the warnings (wrapped, amber); the 22 px row of link buttons.
`measure(role, size, text)` and `wrap(role, size, text, max_width)` work in device px.
"""
function card_layout(r::JobRow, width::Real, scale::Real, measure, wrap)::CardLayout
    p(v) = fpx(scale, v)
    sub_h = p(SUB_SIZE * 1.25)
    running = r.status == Core.JOB_RUNNING
    right = running ? "100 %" : clock_text(r.started)
    title_w = width - p(2 * CARD_SIDE + CARD_INDENT) - measure(FONT_REGULAR, TIME_SIZE, right) - p(8)
    title = elide(measure, job_title(r), title_w; role = FONT_SEMIBOLD, size = BODY_FONT_SIZE)
    text_w = width - p(2 * CARD_SIDE + CARD_INDENT)
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
    for w in r.warnings
        append!(warnings, wrap(FONT_REGULAR, SUB_SIZE, w, text_w))
    end
    h = p(CARD_TOP + CARD_ICON + CARD_GAP) + (isempty(target) ? 0f0 : sub_h)
    h += running ? p(CARD_GAP + JOB_BAR_H) : p(CARD_GAP) + length(summary) * sub_h
    isempty(warnings) || (h += p(CARD_GAP) + length(warnings) * sub_h)
    h += p(CARD_GAP + ACT_H + CARD_BOTTOM) + hairline(scale)
    return CardLayout(h, title, target, summary, warnings, job_owner(r.command) !== nothing)
end

# The layout of the jobs of `snap` at `width`, from the cache when nothing changed.
function jobs_layout!(app, snap::Snapshot, width::Float32)::JobsLayout
    s = app.window.scale
    c = app.ui.jobs_cache
    c isa JobsLayout && c.snap === snap && c.width == width && c.scale == s && return c
    measure = (role, size, text) -> text_width(role, size, text)
    cards = CardLayout[card_layout(r, width, s, measure, wrap_lines) for r in snap.jobs]
    tops = Float32[]
    y = 0f0
    for card in cards
        push!(tops, y)
        y += card.height
    end
    layout = JobsLayout(snap, width, s, cards, tops, y)
    app.ui.jobs_cache = layout
    return layout
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
    layout = jobs_layout!(app, snap, width(view))
    if layout.total > height(view)   # the scrollbar takes 10 px of the cards' width
        layout = jobs_layout!(app, snap, width(view) - fpx(s, SCROLLBAR_W))
    end
    ui.jobs_scroll, has_bar = scroll_area!(app, "scrollbar", view, layout.total, ui.jobs_scroll)
    right = view.x1 - (has_bar ? fpx(s, SCROLLBAR_W) : 0f0)
    ig.PushClipRect((view.x0, view.y0), (right, view.y1), true)
    for (k, r) in enumerate(snap.jobs)
        top = view.y0 + layout.tops[k] - ui.jobs_scroll
        c = layout.cards[k]
        (top + c.height <= view.y0 || top >= view.y1) && continue
        draw_job_card(app, dl, r, c, Box(view.x0, top, right, top + c.height))
    end
    ig.PopClipRect()
    return nothing
end

"""
    draw_job_card(app, dl, row, card, b)

One card in box `b`. A running card reads the live `job.progress[]` for its percent and
bar, and keeps frames coming so the bar moves. Its buttons are Cancel and Report; a
finished card has Run Again... (when its command is known) and Report.
"""
function draw_job_card(app, dl, r::JobRow, c::CardLayout, b::Box)
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
    right = running ? percent_text(progress) : clock_text(r.started)
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
    labels = running ? ("Cancel", "Report") : c.rerun ? ("Run Again...", "Report") : ("Report",)
    for label in labels
        if button(app, label, label, ax, y; small = true, link = true)
            label == "Cancel" ? cancel_job!(app, r) :
                label == "Report" ? show_report!(app, r) : run_again!(app, r)
        end
        ax += round(button_width(app, label; small = true, link = true)) + p(4)
    end
    line = rnd(b.y1 - hl)
    ig.AddRectFilled(dl, (b.x0, line), (b.x1, line + hl), u32(t.border))
    ig.PopID()
    return nothing
end
