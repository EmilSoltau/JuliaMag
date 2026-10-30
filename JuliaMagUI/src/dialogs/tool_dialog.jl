# The dialog of a tool, importer or exporter, built from its setting descriptions (spec
# 8.1, 8.2; prototype section 6), and the requests that open it: `OpenToolDialog`,
# `OpenImport` (a native file dialog first) and `OpenExport`.

"""
    ToolDialog

The dialog of a `Form`. Besides the form it keeps what only the drawing needs:

- `file_size`: the size of the file to import in bytes, or -1.
- `buffers`: the byte buffer of each text field, by key.
- `focus`: the key of the field that takes the keyboard focus in the next frame, or `""`.
- `caret`: `(key, byte)`: put the caret of that field there once it is active.
- `show_desc`: the Tool Description box is shown.
- `running`: a quick tool runs; the primary button shows a spinner.
- `crs_names`: the name of each coordinate system code looked up (`""`: not known);
  `crs_pending`: codes being looked up; `crs_edited`: when each CRS field last changed.
- `field_ids`: the ImGui id of each text field; `hint_boxes`: where each hint went;
  `ok_box`: where the primary button went; `path_box`: where the import's path line went
  (tests read them).
- `confirmed`: the export file the user agreed to replace (the native save dialog asked,
  or the Replace question), or `""`.
"""
mutable struct ToolDialog
    form::Form
    file_size::Int
    buffers::Dict{String,Vector{UInt8}}
    focus::String
    caret::Union{Nothing,Tuple{String,Int}}
    show_desc::Bool
    running::Bool
    crs_names::Dict{String,String}
    crs_pending::Set{String}
    crs_edited::Dict{String,Float64}
    field_ids::Dict{String,UInt32}
    hint_boxes::Dict{String,Union{Nothing,Box}}
    ok_box::Union{Nothing,Box}
    path_box::Union{Nothing,Box}
    confirmed::String
end

ToolDialog(app, f::Form; file_size::Integer = -1) =
    ToolDialog(f, Int(file_size), Dict{String,Vector{UInt8}}(), "", nothing, false, false,
        Dict{String,String}(), Set{String}(), Dict{String,Float64}(), Dict{String,UInt32}(),
        Dict{String,Union{Nothing,Box}}(), nothing, nothing, "")

"The form's values changed outside its fields (a reset, a new input): fill the fields again."
function form_changed!(app, f::Form)
    for d in app.ui.dialogs
        d isa ToolDialog && d.form === f && empty!(d.buffers)
    end
    return nothing
end

dialog_width(o::FormOwner) = o isa Core.ImporterSpec ? 620 : 580
ok_label(o::FormOwner) = o isa Core.ToolSpec ? "Run" : o isa Core.ImporterSpec ? "Import" : "Export"
owner_icon(o::Core.ToolSpec) = icon_for(o.icon)
owner_icon(::Core.ImporterSpec) = "import"
owner_icon(::Core.ExporterSpec) = "export"

"The help paragraph at the top of the dialog."
owner_help(o::Core.ToolSpec) = o.help
owner_help(o::Core.ImporterSpec) =
    "Reads the file into a new or existing database. It runs as a background job, so the app stays usable."
owner_help(o::Core.ExporterSpec) =
    "Writes the $(lowercase(KIND_WORDS[o.kind])) to a $(o.extension) file. It runs as a background job."

function draw_modal(app, d::ToolDialog)
    f = d.form
    o = f.owner
    title = (f.rerun_of === nothing ? "" : "Run Again: ") * form_title(f)
    b = draw_dialog(app, d; title, icon = owner_icon(o), subtitle = o.id, width = dialog_width(o),
        ok_label = ok_label(o), ok_busy = d.running, on_ok = () -> press_ok!(app, d),
        on_cancel = () -> cancel_dialog!(app, d),
        footer_left = () -> draw_tool_footer(app, d)) do
        draw_tool_body(app, d)
    end
    b === nothing || (d.ok_box = b)
    return nothing
end

"""
    cancel_dialog!(app, d)

Close the dialog (Cancel, Esc, the close x). A quick tool that runs goes on without it:
its result comes as a toast (see `finish_ok!`).
"""
cancel_dialog!(app, d::ToolDialog) = (filter!(x -> x !== d, app.ui.dialogs); nothing)

# The footer's left side: "Reset to Defaults" and the "Tool Description" link.
function draw_tool_footer(app, d::ToolDialog)
    pos = ig.GetCursorScreenPos()
    if button(app, "Reset to Defaults", "Reset to Defaults", pos.x, pos.y)
        reset!(app, d.form)
    end
    ig.IsItemHovered() && item_tip!(app, "Reset to Defaults"; help = "Set every setting back to the tool's default.")
    x = pos.x + round(button_width(app, "Reset to Defaults")) + fpx(app.window.scale, 8)
    clicked, _ = link_button(app, "Tool Description", "Tool Description", "script", x, pos.y; on = d.show_desc)
    clicked && (d.show_desc = !d.show_desc)
    ig.IsItemHovered() && item_tip!(app, "Tool Description";
        help = "The Julia description this dialog was built from, and the script call for these settings.")
    return nothing
end

"""
    draw_tool_body(app, d)

The body: the help paragraph, the status line, the inputs and main settings, the file of
an import or export, "Replace the old output" for a run again, the Advanced section and
the Tool Description box. Settings whose `when` is not met are left out.
"""
function draw_tool_body(app, d::ToolDialog)
    s = app.window.scale
    t = app.tokens
    f = d.form
    o = f.owner
    p(v) = fpx(s, v)
    dl = ig.GetWindowDrawList()
    pos = ig.GetCursorScreenPos()
    x0, top = pos.x, pos.y
    w = Float32(ig.CalcItemWidth())
    x1 = x0 + w
    y = top
    empty!(d.hint_boxes)

    # Help: `.help`, 60 characters wide at most, lines 1.4 high, 12 px under it.
    help = owner_help(o)
    if !isempty(help)
        max_w = min(w, 60 * text_width(FONT_REGULAR, BODY_FONT_SIZE, "0"))
        lh = p(BODY_FONT_SIZE * 1.4)
        for l in wrap_lines(FONT_REGULAR, BODY_FONT_SIZE, help, max_w)
            draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x0, y + lh / 2, u32(t.text_dim), l; line = 1.4)
            y += lh
        end
        y += p(12 - 4)   # the status line's margin-top is -4
    end

    # The status line (`.cap`, 14 high): where the values came from, and "Runs as a background job".
    mid = y + p(7)
    icon = f.source === :remembered ? "clock" : "info"
    draw_icon(dl, icon, (rnd(x0), rnd(mid - p(7))), 14; style = :dim)
    draw_text_mid(dl, FONT_REGULAR, 11, x0 + p(14 + 6), mid, u32(t.text_dim), status_text(f))
    if runs_as_job(o)
        jt = "Runs as a background job"
        draw_text_mid(dl, FONT_REGULAR, 11, x1 - text_width(FONT_REGULAR, 11, jt), mid, u32(t.text_dim), jt)
    end
    y += p(14 + 12)

    # The main form.
    g = form_flow(app, x0, x1, y)
    for (name, kind) in form_inputs(o)
        input_row!(app, d, g, name, kind)
    end
    o isa Core.ImporterSpec && import_file_rows!(app, d, g)
    o isa Core.ExporterSpec && export_file_row!(app, d, g)
    list = o.settings
    for st in list
        st.advanced || !Core.is_active(list, st, f.values) || draw_setting!(app, d, g, st)
    end
    if f.rerun_of !== nothing && !(o isa Core.ExporterSpec)
        bool_row!(app, d, g, "replace", "Replace the old output", f.replace) && (f.replace = !f.replace)
        hint!(app, d, g, "replace", "Off: the run makes a new item, and the old one stays.")
    end
    y = g.y

    # Advanced: a 1 px line 12 px under the form, 8 px padding, the toggle, then its form.
    adv = [st for st in list if st.advanced && Core.is_active(list, st, f.values)]
    if !isempty(adv)
        y += p(12)
        ig.AddRectFilled(dl, (x0, rnd(y)), (x1, rnd(y) + hairline(s)), u32(t.border))
        y += hairline(s) + p(8)
        open = o.id in app.config.advanced_open
        advanced_toggle!(app, d, x0, y, open)
        y += p(24)
        if open
            g = form_flow(app, x0, x1, y + p(8))
            foreach(st -> draw_setting!(app, d, g, st), adv)
            y = g.y
        end
    end

    d.show_desc && (y = draw_description(app, d, x0, x1, y + p(12)))

    ig.SetCursorScreenPos((x0, top))
    ig.Dummy((w, y - top))
    return nothing
end

# The status line's text: where the values came from.
function status_text(f::Form)::String
    job = f.rerun_of
    if job !== nothing
        hhmm = length(job.started) >= 16 ? job.started[12:16] : job.started
        return "Settings of job $(job.id), $hhmm. Change any of them before running it again."
    end
    return f.source === :remembered ? "Opened with the settings of your last run in this project." :
        "Default settings."
end

# The Advanced toggle (`.adv > button`): a 14 px chevron and "Advanced" in semibold
# `text_dim`, 24 high, padding 0 6 0 2, `hover` fill. Its state is saved in the settings.
function advanced_toggle!(app, d::ToolDialog, x::Real, y::Real, open::Bool)
    s = app.window.scale
    t = app.tokens
    p(v) = fpx(s, v)
    dl = ig.GetWindowDrawList()
    tw = text_width(FONT_SEMIBOLD, BODY_FONT_SIZE, "Advanced")
    b = snap(Box(x, y, x + p(2 + 14 + 6) + tw + p(6), y + p(24)))
    clicked, hovered, held = hit("Advanced", b)
    hovered && ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(held ? t.pressed : t.hover), p(5))
    mid = centre_y(b)
    draw_icon(dl, open ? "chevDown" : "chevRight", (rnd(b.x0 + p(2)), rnd(mid - p(7))), 14; style = :dim)
    draw_text_mid(dl, FONT_SEMIBOLD, BODY_FONT_SIZE, b.x0 + p(2 + 14 + 6), mid, u32(t.text_dim), "Advanced")
    clicked && set_advanced!(app, d.form.owner.id, !open)
    return nothing
end

# Show or hide the Advanced settings of tool `id` and save that in the settings.
function set_advanced!(app, id::AbstractString, open::Bool)
    list = app.config.advanced_open
    filter!(!=(id), list)
    open && push!(list, String(id))
    save_settings!(app)
    return nothing
end

# The file of an import: its path as a line of mono text (it cannot be edited, so it has
# no field frame), cut at the start when long, with the whole path in a tooltip; its name
# and size under it, or the reason it cannot be imported in red.
function import_file_rows!(app, d::ToolDialog, g::FormFlow)
    s = app.window.scale
    f = d.form
    b = next_box!(app, g, :row, fpx(s, FIELD_H))
    row_label!(app, b, "File")
    c = control(g, b)
    d.path_box = c
    text = elide_start(f.path, width(c))
    with_font(FONT_MONO, 12) do
        ig.AddText(ig.GetWindowDrawList(), (round(c.x0), input_text_y(FONT_MONO, 12, centre_y(c))),
            u32(app.tokens.text), text)
    end
    _, hovered, _ = hit("File path", c)
    hovered && text != f.path && item_tip!(app, "File"; help = f.path)
    err = get(f.errors, "path", nothing)
    size = d.file_size < 0 ? "" : ", " * file_size_text(d.file_size)
    err === nothing ? hint!(app, d, g, "path", basename(f.path) * size) : hint!(app, d, g, "path", err; error = true)
    return nothing
end

# `path` in mono 12, or as much of its end as fits in `max_width` after "...".
function elide_start(path::AbstractString, max_width::Real)::String
    w(t) = text_width(FONT_MONO, 12, t)
    w(path) <= max_width && return String(path)
    chars = collect(path)
    for n in 2:length(chars)
        cut = "..." * String(chars[n:end])
        w(cut) <= max_width && return cut
    end
    return ""
end

# The file of an export: a mono field and "Browse..." (a native save dialog).
function export_file_row!(app, d::ToolDialog, g::FormFlow)
    f = d.form
    new = file_row!(() -> browse_path!(app, d), app, d, g, "path", "File", f.path)
    if new !== nothing
        f.path = new
        delete!(f.errors, "path")
    end
    e = get(f.errors, "path", nothing)
    e === nothing || hint!(app, d, g, "path", e; error = true)
    return nothing
end

"""
    file_size_text(bytes) -> String

A file size as the user reads it: `"512 bytes"`, `"12.3 KB"`, `"1.2 MB"`, `"3.4 GB"`.
"""
function file_size_text(n::Integer)::String
    n < 1024 && return n == 1 ? "1 byte" : "$n bytes"
    for (unit, size) in (("KB", 1024.0), ("MB", 1024.0^2), ("GB", 1024.0^3), ("TB", 1024.0^4))
        x = n / size
        (x < 1024 || unit == "TB") && return string(round(x; digits = 1), " ", unit)
    end
    return "$n bytes"
end

const DESC_SIZE = 11.5
const DESC_LINE = 1.45
const DESC_MAX_H = 260

"""
    draw_description(app, d, x0, x1, y) -> Float32

The Tool Description box (`.desc`) from `y`: mono 11.5 on lines 1.45 high, `pane_header`
fill, 1 px `border`, radius 6, padding 8 10, at most 260 high; it scrolls. Comments are
`text_dim`, text in quotes `green`, the first word `accent_text`. Returns its bottom.
"""
function draw_description(app, d::ToolDialog, x0::Real, x1::Real, y::Real)::Float32
    s = app.window.scale
    t = app.tokens
    p(v) = fpx(s, v)
    hl = hairline(s)
    lines = description_lines(d.form)
    lh = p(DESC_SIZE * DESC_LINE)
    content_h = length(lines) * lh
    widest = maximum(l -> sum(part -> text_width(FONT_MONO, DESC_SIZE, part[1]), l; init = 0f0), lines; init = 0f0)
    inner_w = Float32(x1 - x0) - 2 * hl - p(20)
    bar = widest > inner_w ? p(10) : 0f0
    h = min(content_h + p(16) + 2 * hl + bar, p(DESC_MAX_H))
    b = snap(Box(x0, y, x1, y + h))
    dl = ig.GetWindowDrawList()
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.pane_header), p(6))
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.border), p(6), hl)
    colours = Dict(:text => t.text, :dim => t.text_dim, :green => t.green, :accent => t.accent_text)
    ig.SetCursorScreenPos((b.x0 + hl, b.y0 + hl))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (p(10), p(8)))
    ig.BeginChild("Tool Description", (width(b) - 2 * hl, height(b) - 2 * hl),
        lib.ImGuiChildFlags_AlwaysUseWindowPadding,
        ig.ImGuiWindowFlags_NoBackground | ig.ImGuiWindowFlags_HorizontalScrollbar)
    cdl = ig.GetWindowDrawList()
    pos = ig.GetCursorScreenPos()
    for (k, line) in enumerate(lines)
        x = pos.x
        for (text, colour) in line
            x += draw_text_mid(cdl, FONT_MONO, DESC_SIZE, x, pos.y + (k - 0.5f0) * lh, u32(colours[colour]),
                text; line = DESC_LINE)
        end
    end
    ig.Dummy((max(widest, 1f0), content_h))
    ig.EndChild()
    ig.PopStyleVar()
    return b.y1
end

# --- OK ---

"""
    press_ok!(app, d)

What the primary button does: check the form on the worker (on a copy), then run it there.
With problems the dialog stays open and shows them: the Advanced section opens when the
first problem is in it, and that field takes the focus. A quick tool keeps the dialog open
with a spinner until its result comes back; then its message shows as an `ok` toast (one
line) or a result dialog (more lines). A job tool, import or export starts its job and the
dialog closes, with the toast "<title> started.". The first job of a session switches the
left pane to Jobs.
"""
function press_ok!(app, d::ToolDialog)
    d.running && return nothing
    f = d.form
    if f.owner isa Core.ExporterSpec   # a typed path gets the extension too, before it is looked for
        p = with_extension(f.path, f.owner.extension)
        p == f.path || (f.path = p; delete!(d.buffers, "path"))
    end
    work = copy_form(f)
    confirmed = d.confirmed
    d.running = true
    session = app.session
    # The action never throws, so the spinner always stops: an error is a failed result.
    submit!(app, "Check " * form_title(f), s -> try
        check!(work, s) || return (work.errors, nothing)
        work.owner isa Core.ExporterSpec && work.path != confirmed && isfile(work.path) &&
            return (work.errors, :replace)
        (work.errors, run_form(s, work))
    catch e
        e isa InterruptException && rethrow()
        (Dict{String,String}(), (false, safe_user_message(e, catch_backtrace()), nothing))
    end; done = (app, r) -> begin
        # A project closed or changed meanwhile: the result is dropped quietly.
        s = app.session
        (s === session && s !== nothing && isopen(s)) ? finish_ok!(app, d, r[1], r[2]) : (d.running = false)
        nothing
    end)
    return nothing
end

"""
    finish_ok!(app, d, errors, result)

Act on what the worker did for `press_ok!`: show the `errors`, ask before replacing an
export file (`result === :replace`), or close the dialog for a run. A quick run that
failed keeps the dialog and the user's edits, with the error as a toast. A dialog the user
closed during a quick run is gone: the result comes as a toast, and a report of several
lines as a toast whose "Show" opens it.
"""
function finish_ok!(app, d::ToolDialog, errors::Dict{String,String}, result)
    d.running = false
    f = d.form
    open = d in app.ui.dialogs
    title = form_title(f)
    if !isempty(errors)
        open || (toast!(app, :error, errors[something(first_problem(f, errors))]); return nothing)
        f.errors = errors
        key = first_problem(f, errors)
        st = key === nothing ? nothing : find_setting(f, key)
        st !== nothing && st.advanced && !(f.owner.id in app.config.advanced_open) &&
            set_advanced!(app, f.owner.id, true)
        key === nothing || (d.focus = focus_key(f, key))
        return nothing
    end
    if result === :replace
        open || return nothing
        path = f.path
        name = basename(path)
        confirm!(app, "Replace $name?", "$name is already in $(dirname(path)). Replacing it cannot be undone.";
            action = "Replace", danger = true, on_yes = a -> (d.confirmed = path; press_ok!(a, d)))
        return nothing
    end
    if result isa Tuple && length(result) == 3 && !result[1]
        toast!(app, :error, String(result[2]))   # the dialog stays, with the user's edits
        return nothing
    end
    filter!(x -> x !== d, app.ui.dialogs)
    if result isa Core.Job
        toast!(app, :info, "$title started."; sub = "It runs in the background. Progress is in the Jobs pane.",
            ms = 2600)
        if !app.ui.jobs_shown
            app.ui.jobs_shown = true
            app.ui.left_tab = :jobs
        end
    elseif result isa Tuple && length(result) == 3
        message = String(result[2])
        if !occursin('\n', message)
            toast!(app, :ok, message)
        elseif open
            push_dialog!(app, ResultDialog(title, message))
        else
            toast!(app, :ok, "$title is done."; actions = ["Show" => a -> push_dialog!(a, ResultDialog(title, message))])
        end
    end
    return nothing
end

# The first key with a problem, in the order the form shows them: inputs, the file, settings.
function first_problem(f::Form, errors::Dict{String,String})
    for (name, _) in form_inputs(f.owner)
        haskey(errors, name) && return name
    end
    haskey(errors, "path") && return "path"
    for st in form_settings(f)
        haskey(errors, st.key) && return st.key
    end
    return isempty(errors) ? nothing : first(sort!(collect(keys(errors))))
end

# --- Files ---

"""
    native_pick_file(; save = false, title = "", extensions = String[], start = "") -> String

Ask for a file with the system's own dialog (NativeFileDialog): a file to open, or with
`save` a file to write. `extensions` (such as `".xyz"`) filter the list; `start` is the
folder to start in, or for a save the file name to suggest in its folder. Returns the
path, or `""` when the user cancelled. Throws when the system dialog cannot open (such
as a Linux without GTK). NativeFileDialog shows no `title` and suggests no file name.
"""
function native_pick_file(; save::Bool = false, title::AbstractString = "",
        extensions::AbstractVector{<:AbstractString} = String[], start::AbstractString = "")::String
    filters = join((lstrip(e, '.') for e in extensions), ",")
    folder = save && !isempty(start) ? dirname(start) : String(start)
    isdir(folder) || (folder = "")
    path = save ? NativeFileDialog.save_file(folder; filterlist = filters) :
        NativeFileDialog.pick_file(folder; filterlist = filters)
    return String(path)
end

# Ask for a file through `app.pick_file`. A dialog that cannot open becomes an error toast
# and gives `""`.
function ask_file(app; save::Bool, title::AbstractString, extensions, start::AbstractString)::String
    try
        return String(app.pick_file(; save, title = String(title), extensions = String.(extensions),
            start = String(start)))
    catch e
        e isa InterruptException && rethrow()
        toast!(app, :error, "The file dialog could not open: " * plain_message(e))
        return ""
    end
end

# Remember the folder of a picked file for the next file dialog.
function remember_folder!(app, path::AbstractString)
    folder = dirname(path)
    (isempty(folder) || folder == app.config.last_folder) && return nothing
    app.config.last_folder = folder
    save_settings!(app)
    return nothing
end

"""
    browse_path!(app, d)

"Browse..." of an export: a native save dialog for the exporter's extension, starting at
the item's name. The path picked (with the extension added when missing) becomes the
form's file. An existing file is replaced without asking again only when the save dialog
gave exactly that path.
"""
function browse_path!(app, d::ToolDialog)
    f = d.form
    e = f.owner::Core.ExporterSpec
    item = get(f.inputs, "item", "")
    folder = isempty(f.path) ? app.config.last_folder : dirname(f.path)
    start = joinpath(folder, export_name(app, e, item))
    picked = ask_file(app; save = true, title = form_title(f), extensions = [e.extension], start)
    isempty(picked) && return nothing
    path = with_extension(picked, e.extension)
    # The save dialog asked before it gave a file that is there; with an added extension
    # it did not see the file we write, so the Run asks then.
    d.confirmed = path == picked ? path : ""
    f.path = path
    delete!(f.errors, "path")
    delete!(d.buffers, "path")
    remember_folder!(app, path)
    return nothing
end

# "Browse..." of a file setting: a native open or save dialog for its extensions.
function pick_setting_file!(app, d::ToolDialog, st::Core.FileSetting)
    current = string(get(d.form.values, st.key, ""))
    start = isempty(current) ? app.config.last_folder : st.save ? current : dirname(current)
    path = ask_file(app; save = st.save, title = st.label, extensions = st.extensions, start)
    isempty(path) && return nothing
    set_value!(d, st.key, path)
    delete!(d.buffers, st.key)
    remember_folder!(app, path)
    return nothing
end

# --- Requests ---

function find_owner(list, id::AbstractString)
    k = findfirst(x -> x.id == id, list)
    k === nothing && throw(ArgumentError("there is no \"$id\""))
    return list[k]
end

function handle_request!(app, r::OpenToolDialog)
    spec = Core.find_tool(r.id)
    spec === nothing && throw(ArgumentError("There is no tool \"$(r.id)\"."))
    open_form(app, spec; item = r.item, values = r.values)
    return true
end

"An import: ask for the file (the last folder first), then open the import dialog."
function handle_request!(app, r::OpenImport)
    spec = find_owner(Core.importers(), r.importer_id)
    path = ask_file(app; save = false, title = owner_title(spec), extensions = spec.extensions,
        start = app.config.last_folder)
    isempty(path) && return true
    remember_folder!(app, path)
    # The dialog's importer is the one that runs; a file of another type is refused.
    wrong = wrong_file_text(spec, path)
    wrong === nothing || (toast!(app, :error, wrong); return true)
    open_form(app, spec; path)
    return true
end

function handle_request!(app, r::OpenExport)
    spec = find_owner(Core.exporters(), r.exporter_id)
    item = r.item === nothing ? default_item(app, spec.kind) : r.item
    open_form(app, spec; item)
    return true
end
