# Opening, making and closing projects; quitting; running scripts; the log file.
#
# Every core call that touches a session or a file runs on the worker (`submit!`), so the
# window keeps drawing. While a project opens or closes, `app.switching` holds what the app
# says ("Opening Survey...", "Closing...") and the shell is greyed (`draw_busy`).
# `set_session!` is the only way the project changes.

const PROJECT_NAME_CHARS = ('<', '>', ':', '"', '/', '\\', '|', '?', '*')
const BAD_PROJECT_NAME = "A folder name cannot have any of these characters: < > : \" / \\ | ? *"
const NO_PROJECT_HERE = "This folder has no JuliaMag project."
const PROJECT_THERE = "There is a project in this folder already. Open it from the Open page."
const CLOSE_WARNINGS_TITLE = "Closing the project gave these warnings"
const RESERVED_NAME = "Windows keeps this name for itself. Pick another name."
const BAD_NAME_END = "A folder name cannot end with a dot or a space."
const SCRIPT_RUNNING = "A script is still running. Quit anyway?"

# Names Windows keeps for devices, also with an extension (`NUL.txt`), in any case.
const RESERVED_NAMES = Set(["CON", "PRN", "AUX", "NUL",
    ("COM" * string(k) for k in 1:9)..., ("LPT" * string(k) for k in 1:9)...])

"""
    project_name_problem(name) -> Union{Nothing,String}

Why `name` cannot be the name of a new project, whose folder takes the same name, or
`nothing`: it is blank, `.` or `..`, has a character a folder name cannot have, ends with
a dot or a space, or is a name Windows keeps for devices (`CON`, `NUL`, `COM1`, ... also
with an extension). Windows is the main platform, so these are refused everywhere.
"""
function project_name_problem(name::AbstractString)::Union{Nothing,String}
    t = strip(name)
    (isempty(t) || t in (".", "..")) && return "Type a name."
    any(c -> c in PROJECT_NAME_CHARS || iscntrl(c), t) && return BAD_PROJECT_NAME
    (endswith(name, ' ') || endswith(t, '.')) && return BAD_NAME_END
    uppercase(first(split(t, '.'))) in RESERVED_NAMES && return RESERVED_NAME
    return nothing
end

# The last part of a folder path, also with a slash at the end.
folder_label(folder::AbstractString)::String = basename(rstrip(String(folder), ('/', '\\')))

# --- Opening and making ---

"A project the worker opened: the session, the folder's real path and the project's name."
struct OpenedProject
    session::Core.Session
    path::String
    name::String
end

"An open that failed with a plain message. `missing`: the folder is not there."
struct OpenFailure
    text::String
    missing::Bool
end

"""
    open_on_worker(folder, force, name) -> OpenedProject or the exception

Open the project in `folder` (`name === nothing`) or make a new project called `name` in
it. Runs on the worker. Never throws: a failure is returned, so the render thread always
learns how it ended. A folder that is not there, a folder with no project and a new
project over an old one give an `OpenFailure` with a plain message.
"""
function open_on_worker(folder::String, force::Bool, name::Union{Nothing,String})
    try
        project_file = joinpath(folder, Core.PROJECT_FILE)
        if name === nothing
            isdir(folder) || return OpenFailure("The folder $folder was not found.", true)
            isfile(project_file) || return OpenFailure(NO_PROJECT_HERE, false)
            s = Core.open_session(folder; force)
        else
            parent = dirname(folder)
            isdir(parent) || return OpenFailure("The folder $parent was not found.", false)
            isfile(project_file) && return OpenFailure(PROJECT_THERE, false)
            isdir(folder) && !isempty(readdir(folder)) && return OpenFailure(
                "The folder $folder is not empty. Pick another name, or an empty folder.", false)
            s = Core.new_session(folder, name; force)
        end
        return OpenedProject(s, realpath(folder), s.project.name)
    catch e
        return e
    end
end

"""
    open_project!(app, folder; force = false, stay = false)

Open the project in `folder`. The open project closes first (`close_project!`, which asks
when jobs run). On the worker; while it runs the shell shows "Opening <folder name>...".

When it opened: it becomes the app's project, goes first in the recent list, the
settings are saved, and the backstage closes (unless `stay`). The Data tree's current
database becomes the first database once the snapshot is in (`sync_current_db!`).
When another session has it open: a question names who and since when, and "Open Anyway"
opens it with `force = true`. Any other failure: an error toast with a plain message; a
folder that is not there stays in the recent list, marked as not found.
"""
function open_project!(app, folder::AbstractString; force::Bool = false, stay::Bool = false)
    path = String(folder)
    if is_open_project(app, path)   # it is open already: just show it
        close_backstage!(app)
        return nothing
    end
    start = a -> start_open!(a, path, nothing; force, stay)
    app.session === nothing ? start(app) : close_project!(app; then = start)
    return nothing
end

# Is `folder` the folder of the open project? Compares paths only (no file access).
function is_open_project(app, folder::String)::Bool
    app.session === nothing && return false
    f = normpath(rstrip(folder, ('/', '\\')))
    f == app.ui.bs.open_path && return true
    snap = app.snap
    return snap !== nothing && f == normpath(rstrip(snap.folder, ('/', '\\')))
end

"""
    new_project!(app, parent, name) -> Union{Nothing,String}

Make a new project called `name` in the folder `joinpath(parent, name)` and open it, as
`open_project!` does. A name that cannot be a folder name is refused: the reason is
returned and nothing happens. Returns `nothing` when the project is on its way.
"""
function new_project!(app, parent::AbstractString, name::AbstractString)::Union{Nothing,String}
    problem = project_name_problem(name)
    problem === nothing || return problem
    n = String(strip(name))
    folder = joinpath(String(parent), n)
    start = a -> start_open!(a, folder, n; force = false, stay = false)
    app.session === nothing ? start(app) : close_project!(app; then = start)
    return nothing
end

function start_open!(app, folder::String, name::Union{Nothing,String}; force::Bool, stay::Bool)
    app.switching === nothing || return nothing   # one open or close at a time
    label = "Opening $(name === nothing ? folder_label(folder) : name)..."
    app.switching = label
    submit!(app, label, _ -> open_on_worker(folder, force, name);
        done = (a, r) -> opened!(a, folder, name, r; stay))
    return nothing
end

# The end of an open, on the render thread.
function opened!(app, folder::String, name::Union{Nothing,String}, @nospecialize(r); stay::Bool)
    app.switching = nothing
    bs = app.ui.bs
    if r isa OpenedProject
        set_session!(app, r.session)
        bs.open_path = r.path
        app.config.recent = recent_after_open(app.config.recent, r.path)
        bs.recent[r.path] = RecentInfo(r.name, true)
        save_settings!(app)
        stay || (app.ui.backstage = false)
        bs.scroll = 0f0
    elseif r isa Core.ProjectLockedError
        retry = a -> start_open!(a, folder, name; force = true, stay)
        confirm!(app, "This project is open somewhere else", lock_text(r);
            action = "Open Anyway", danger = true, on_yes = retry)
    elseif r isa OpenFailure
        toast!(app, :error, r.text)
        r.missing && (bs.recent[folder] = RecentInfo(folder_label(folder), false))
    else
        toast!(app, :error, safe_user_message(r))
    end
    return nothing
end

"""
    lock_text(e::ProjectLockedError) -> String

Who holds the project, as a sentence: "<user> on <host> opened it at <time>.", with the
core's note after it when there is one (a take-over of the lock that went wrong).
A login name keeps its case ("ems"); a phrase the core writes when it cannot read the
lock ("another program") starts with a capital, so the sentence does.
"""
function lock_text(e::Core.ProjectLockedError)::String
    who = isempty(e.user) ? "another user" : e.user
    occursin(' ', who) && (who = uppercasefirst(who))
    text = who * " on $(e.host) opened it at $(lock_time_text(e.started))."
    isempty(strip(e.note)) || (text *= " " * sentence(e.note))
    return text
end

const MONTH_NAMES = ("January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December")

"""
    lock_time_text(started; offset = the machine's offset) -> String

The local time of a lock's `started` text, such as `"09:15 on 31 October 2026"`. A time
with a zone is moved by `offset` seconds from UTC. Text that is not a time comes back as it is.
"""
function lock_time_text(text::AbstractString; offset::Union{Nothing,Integer} = nothing)::String
    t = job_time(text)
    t === nothing && return String(text)
    wall = t.seconds
    t.zoned && (wall += offset === nothing ? local_offset(t.seconds) : offset)
    days, secs = fldmod(floor(Int, wall), 86400)
    y, m, d = civil_from_days(days)
    return string(lpad(secs ÷ 3600, 2, '0'), ":", lpad(secs % 3600 ÷ 60, 2, '0'), " on ", d, " ",
        MONTH_NAMES[m], " ", y)
end

"""
    open_last!(app)

At start: when the setting "Open Last Project" is on and the last recent folder still
holds a project, open it. Checks the folder on the worker. A folder that is gone does
nothing.
"""
function open_last!(app)
    c = app.config
    (c.open_last && !isempty(c.recent)) || return nothing
    folder = first(c.recent)
    submit!(app, "Look for the last project", _ -> isfile(joinpath(folder, Core.PROJECT_FILE));
        done = (a, there) -> (there === true && a.session === nothing && open_project!(a, folder); nothing))
    return nothing
end

# --- The recent list ---

"""
    recent_infos(folders) -> Dict{String,RecentInfo}

The project name of each folder and whether the folder is there. Runs on the worker.
A folder without a readable project is named after the folder.
"""
function recent_infos(folders::Vector{String})::Dict{String,RecentInfo}
    out = Dict{String,RecentInfo}()
    for f in folders
        found = isdir(f)
        name = folder_label(f)
        if found
            try
                name = Core.open_project(f).name
            catch e
                e isa InterruptException && rethrow()
            end
        end
        out[f] = RecentInfo(name, found)
    end
    return out
end

"Read the name and state of every recent folder on the worker (the backstage opened)."
function refresh_recent!(app)
    folders = copy(app.config.recent)
    submit!(app, "Read the recent projects", _ -> recent_infos(folders);
        done = (a, infos) -> (merge!(a.ui.bs.recent, infos); nothing))
    return nothing
end

"Take `folder` out of the recent list (Remove from List) and save the settings."
function remove_recent!(app, folder::AbstractString)
    filter!(!=(folder), app.config.recent)
    save_settings!(app)
    return nothing
end

# --- Closing ---

"""
    WarningsDialog

The warnings of a close (`close_project!`): its `title`, one line per warning, and `then`,
which runs when the user closes the dialog.
"""
struct WarningsDialog
    title::String
    lines::Vector{String}
    then::Function
end

"""
    close_project!(app; then = app -> nothing)

Close the project, then call `then(app)`. When jobs run, it asks first ("1 job is
running. Cancel it and close?"); Cancel stops here, `then` does not run, and a quit
waiting for the close is given up. The close runs on the worker (`close_session!` cancels
the jobs and waits for them); the shell shows "Closing...". The warnings of the session
that no toast showed yet (those of the close itself) then show in a dialog, and `then`
runs when it closes. Without a project, `then` runs at once.
"""
function close_project!(app; then::Function = app -> nothing)
    app.session === nothing && return then(app)
    app.switching === nothing || return nothing
    n = running_jobs(app.snap)
    if n > 0
        text = n == 1 ? "1 job is running. Cancel it and close?" :
            "$n jobs are running. Cancel them and close?"
        confirm!(app, "Close the project?", text; action = "Close Project", danger = true,
            on_yes = a -> start_close!(a, then), on_no = a -> (a.quit_pending = false; nothing))
        return nothing
    end
    start_close!(app, then)
    return nothing
end

"What a close on the worker gave: the session's warnings, and an error of the close itself."
struct CloseResult
    warnings::Vector{String}
    error::Any
end

function close_on_worker(s::Core.Session)::CloseResult
    failure = try
        Core.close_session!(s)
        nothing
    catch e
        e
    end
    warns = try
        Core.warnings(s)
    catch
        String[]
    end
    return CloseResult(warns, failure)
end

function start_close!(app, then::Function)
    s = app.session
    s === nothing && return then(app)
    app.switching === nothing || return nothing
    seen = app.seen_warnings   # shown as toasts already
    app.switching = "Closing..."
    submit!(app, "Closing...", _ -> close_on_worker(s); done = (a, r) -> closed!(a, s, seen, r, then))
    return nothing
end

function closed!(app, s::Core.Session, seen::Int, r::CloseResult, then::Function)
    app.switching = nothing
    app.session === s && set_session!(app, nothing)
    if r.error !== nothing   # logged too: during a quit the toast is gone at once
        @error "The project did not close cleanly" exception = r.error
        toast!(app, :error, safe_user_message(r.error))
    end
    # A quit cancels what waited for the close: no other project opens, no script runs.
    next = a -> (a.quit_pending || then(a); nothing)
    fresh = r.warnings[min(seen, length(r.warnings))+1:end]
    if isempty(fresh)
        next(app)
    else
        push_dialog!(app, WarningsDialog(CLOSE_WARNINGS_TITLE, sentence.(fresh), next))
    end
    return nothing
end

"Close the warnings dialog `d` and run what waits for it."
function finish_warnings!(app, d::WarningsDialog)
    filter!(x -> x !== d, app.ui.dialogs)
    d.then(app)
    return nothing
end

function draw_modal(app, d::WarningsDialog)
    draw_dialog(app, d; title = d.title, icon = "warn", width = 520, ok_label = "OK",
        cancel_label = nothing, on_ok = () -> finish_warnings!(app, d),
        on_cancel = () -> finish_warnings!(app, d)) do
        for (k, line) in enumerate(d.lines)
            k > 1 && ig.Dummy((0f0, fpx(app.window.scale, 2)))
            paragraph(app, line; colour = :text)
        end
    end
    return nothing
end

function handle_request!(app, ::CloseProject)
    close_project!(app)
    return true
end

# --- Quitting ---

"""
    request_quit!(app) -> Bool

The user closed the window. The app closes the project first (`advance_quit!` does it,
frame by frame), so this returns `false`: the window stays open for now. Open dialogs and
menus close, so they do not hold the quit up; a second request while one waits changes
nothing. The quit is an app-level flag, not a request, so a project switch never drops it.
"""
function request_quit!(app)::Bool
    app.quit_pending && return false
    app.quit_pending = true
    empty!(app.ui.dialogs)
    close_menu!(app)
    close_search!(app)
    if app.ui.bs.running   # a script may never end: ask, and quit without waiting for it
        confirm!(app, "Quit JuliaMag?", SCRIPT_RUNNING; action = "Quit", danger = true,
            on_yes = a -> (a.quit_pending = false; a.quit_hook(a); nothing),
            on_no = a -> (a.quit_pending = false; nothing))
    end
    return false
end

"""
    advance_quit!(app)

Move a quit along; call it once per frame. It waits while a project opens or closes and
while a dialog is open (the running-jobs question, the close warnings). Then it closes the
project, and once none is open it calls `app.quit_hook(app)`.
"""
function advance_quit!(app)
    app.quit_pending || return nothing
    app.switching === nothing || return nothing
    isempty(app.ui.dialogs) || return nothing
    if app.session === nothing
        app.quit_pending = false
        app.quit_hook(app)
    else
        close_project!(app)
    end
    return nothing
end

# --- Running scripts ---

const OUTPUT_MAX_LINES = 10_000
const OUTPUT_CUT = "Earlier output was cut."
const OUTPUT_LINE_MAX = 2_000   # characters; a longer line is cut, so no line holds the memory

"What a script run gave: everything it printed, and its error or `nothing`."
struct ScriptRun
    output::String
    error::Union{Nothing,String}
end

"""
    run_script_file(path) -> ScriptRun

Run the Julia script at `path` with `include` in a new module, and catch what it prints:
`stdout`, `stderr` and its log messages go to a temp file while it runs, and are put back
afterwards, also when the script throws. A file, not a pipe: a script that prints a lot
never waits for a reader. Only the last $(OUTPUT_MAX_LINES) lines are kept (`last_lines`),
so a chatty script cannot fill the memory. Runs on the worker.

The redirect is for the whole process, so anything another thread prints to the console
while the script runs lands in the output too. The app's own log messages do not: they go
through its logger, not through `stdout`.
"""
function run_script_file(path::AbstractString)::ScriptRun
    tmp, io = mktemp()
    failure = nothing
    try
        m = Module(:JuliaMagScript)
        # What `module ... end` gives a module: its own `include` and `eval`.
        Base.eval(m, :(include(p::AbstractString) = Base.include($m, p)))
        Base.eval(m, :(eval(x) = Core.eval($m, x)))
        logger = Logging.ConsoleLogger(io, Logging.Info)
        redirect_stdout(io) do
            redirect_stderr(io) do
                Logging.with_logger(() -> Base.include(m, String(path)), logger)
            end
        end
    catch e
        e isa InterruptException && rethrow()
        failure = script_error_text(e)
    finally
        close(io)
    end
    out = try
        last_lines(tmp, OUTPUT_MAX_LINES)
    finally
        rm(tmp; force = true)
    end
    return ScriptRun(out, failure)
end


"""
    last_lines(path, n) -> String

The last `n` lines of the file at `path`, read one line at a time, so a script that
printed millions of lines takes no more memory than `n` lines. When lines were dropped,
the text starts with the line "$(OUTPUT_CUT)". Lines longer than $(OUTPUT_LINE_MAX)
characters are cut.
"""
function last_lines(path::AbstractString, n::Integer)::String
    ring = Vector{String}(undef, n)
    count = 0
    for line in eachline(path)
        length(line) > OUTPUT_LINE_MAX && (line = first(line, OUTPUT_LINE_MAX) * "...")
        count += 1
        ring[mod1(count, n)] = line
    end
    io = IOBuffer()
    count > n && println(io, OUTPUT_CUT)
    for k in max(1, count - n + 1):count
        println(io, ring[mod1(k, n)])
    end
    return String(take!(io))
end

# The error of a script as one plain line, with the line of the script it came from.
function script_error_text(@nospecialize(e))::String
    if e isa LoadError
        return "Error in $(basename(e.file)), line $(e.line): " * sprint(showerror, e.error)
    end
    return "Error: " * sprint(showerror, e)
end

"""
    run_script!(app, path)

Run Script: close the project (asking when jobs run), run the script at `path` on the
worker (`run_script_file`), show what it printed and any error on the Run Script page,
then open the project again, also when the script failed. The backstage stays open.
"""
function run_script!(app, path::AbstractString)
    app.switching === nothing || return nothing
    if app.session !== nothing && app.snap === nothing
        toast!(app, :info, "Wait until the project has loaded.")
        return nothing
    end
    folder = app.snap === nothing ? nothing : app.snap.folder
    file = String(path)
    close_project!(app; then = a -> start_script!(a, file, folder))
    return nothing
end

function start_script!(app, path::String, folder::Union{Nothing,String})
    bs = app.ui.bs
    bs.output = nothing
    bs.output_failed = false
    bs.output_lines = String[]
    bs.output_errors = 0
    bs.running = true
    bs.output_scroll = 0f0
    label = "Running $(basename(path))..."
    app.switching = label
    submit!(app, label, _ -> run_script_file(path); done = (a, r) -> script_done!(a, r, folder))
    return nothing
end

function script_done!(app, r::ScriptRun, folder::Union{Nothing,String})
    app.switching = nothing
    bs = app.ui.bs
    bs.running = false
    out = r.output
    if r.error !== nothing
        out = isempty(out) || endswith(out, '\n') ? out * r.error : out * "\n" * r.error
    end
    bs.output = isempty(out) ? "The script printed nothing." : out
    bs.output_failed = r.error !== nothing
    # Split once here, not in every frame; the error lines are the last ones.
    bs.output_lines = String.(split(rstrip(bs.output, '\n'), '\n'))
    bs.output_errors = r.error === nothing ? 0 : length(split(rstrip(r.error, '\n'), '\n'))
    folder === nothing || app.quit_pending || open_project!(app, folder; stay = true)
    return nothing
end

# --- The log file ---

const LOG_FILE = "juliamag.log"
const LOG_MAX_BYTES = 1_000_000

"""
    trim_log!(path, max_bytes = $(LOG_MAX_BYTES))

Cut the log file at `path` to its last `max_bytes` bytes, from the start of a line. A file
that is shorter, or not there, is left alone.
"""
function trim_log!(path::AbstractString, max_bytes::Integer = LOG_MAX_BYTES)
    isfile(path) || return nothing
    n = filesize(path)
    n <= max_bytes && return nothing
    data = open(io -> (seek(io, n - max_bytes); read(io)), path)
    k = findfirst(==(UInt8('\n')), data)
    # No line start in the last part: at least start on a whole character.
    k === nothing && (k = something(findfirst(b -> b & 0xc0 != 0x80, data), length(data) + 1) - 1)
    keep = data[k+1:end]
    tmp, io = mktemp(dirname(abspath(path)))
    try
        write(io, keep)
        close(io)
        mv(tmp, path; force = true)
    catch
        close(io)
        rm(tmp; force = true)
        rethrow()
    end
    return nothing
end

"""
    AppLogger

The app's logger: every message goes to the `console` logger as before (for development),
and warnings and errors also go to the log file, each with the time.
"""
struct AppLogger <: Logging.AbstractLogger
    console::Logging.AbstractLogger
    file::Logging.ConsoleLogger
end

Logging.min_enabled_level(l::AppLogger) = min(Logging.min_enabled_level(l.console), Logging.Warn)
Logging.shouldlog(::AppLogger, level, _module, group, id) = true
Logging.catch_exceptions(::AppLogger) = true

function Logging.handle_message(l::AppLogger, level, message, _module, group, id, file, line; kwargs...)
    c = l.console
    if level >= Logging.min_enabled_level(c) && Logging.shouldlog(c, level, _module, group, id)
        Logging.handle_message(c, level, message, _module, group, id, file, line; kwargs...)
    end
    if level >= Logging.Warn
        stamp = Libc.strftime("%Y-%m-%d %H:%M:%S", time())
        Logging.handle_message(l.file, level, string(stamp, " ", message), _module, group, id, file,
            line; kwargs...)
        flush(l.file.stream)
    end
    return nothing
end

"""
    with_app_log(f, dir; console = the current logger)

Run `f()` with the app's logger: warnings and errors also go to `juliamag.log` in `dir`,
which is first cut to its last $(LOG_MAX_BYTES ÷ 1_000_000) MB. Tasks that `f` starts take the
same logger. `console` is the logger (or an `IO` for a console logger) for everything
else. When the log file cannot be written, `f` runs with the console logger alone.
"""
function with_app_log(f, dir::AbstractString; console = Logging.current_logger())
    con = console isa IO ? Logging.ConsoleLogger(console, Logging.Info) : console
    path = joinpath(dir, LOG_FILE)
    io = try
        mkpath(dir)
        trim_log!(path)
        open(path, "a")
    catch e
        e isa InterruptException && rethrow()
        Logging.with_logger(con) do
            @warn "The log file cannot be written; messages go to the console only" path exception = e
        end
        nothing
    end
    io === nothing && return Logging.with_logger(f, con)
    try
        return Logging.with_logger(f, AppLogger(con, Logging.ConsoleLogger(io, Logging.Warn)))
    finally
        close(io)
    end
end
