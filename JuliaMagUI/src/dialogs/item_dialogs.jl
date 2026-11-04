# Dialogs for one project item: Rename, Channel Properties, and the result of a quick tool.
# Each is a modal dialog on `app.ui.dialogs` (see modal.jl). Their edits go through the
# worker, so they are undoable core calls.

const FORM_LABEL_W = 150    # the prototype's `.form` label column
const FORM_GAP_X = 12
const FORM_GAP_Y = 8
const FIELD_H = 24

"""
    text_field!(app, id, buffer, b; focus = false, flags = 0, role = FONT_REGULAR, size = 12.5,
                placeholder = "", prefix = "", right = false, error = false) -> Bool

A prototype `.inp` in box `b`: 24 high, `input` fill, 1 px `input_border`, radius 5, text
7 px in; an `accent` ring while it has the focus. `role` and `size` set the font (`.inp.mono`
is `FONT_MONO` at 12). `placeholder` shows in `text_disabled` while the field is empty.
`right` puts the text at the right end (a number field); a click anywhere in the field
still edits it. `prefix` is a short dim label at the left that stays when the field is
filled (the W, S, E, N of an area). With `error` the frame and ring are `red` (`.inp.err`).
Returns true when the text changed.
"""
function text_field!(app, id::AbstractString, buf::Vector{UInt8}, b::Box; focus::Bool = false,
        flags::Integer = 0, role::FontRole = FONT_REGULAR, size::Real = BODY_FONT_SIZE,
        placeholder::AbstractString = "", prefix::AbstractString = "", right::Bool = false,
        error::Bool = false)
    s = app.window.scale
    t = app.tokens
    hl = hairline(s)
    dl = ig.GetWindowDrawList()
    r = fpx(s, 5)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.input), r)
    # Each box is set once: a name a closure takes that is set twice is boxed, which allocates.
    pad = Box(b.x0 + hl + fpx(s, 7), b.y0 + hl, b.x1 - hl - fpx(s, 7), b.y1 - hl)
    if !isempty(prefix)
        with_font(FONT_REGULAR, 11.5) do
            ig.AddText(dl, (round(pad.x0), input_text_y(FONT_REGULAR, 11.5, centre_y(pad))),
                u32(t.text_dim), String(prefix))
        end
    end
    lead = isempty(prefix) ? 0f0 : text_width(FONT_REGULAR, 11.5, prefix) + fpx(s, 6)
    inner = Box(pad.x0 + lead, pad.y0, pad.x1, pad.y1)
    # ImGui has no right-aligned field: the field starts where the text starts, and a
    # click on the empty part left of it gives it the focus.
    field = right ? Box(max(inner.x0, inner.x1 - buffer_width(role, size, buf) - fpx(s, 2)), inner.y0, inner.x1, inner.y1) :
        inner
    if right
        ig.PushID(id)
        first(hit("##area", Box(b.x0, b.y0, field.x0, b.y1); overlap = true)) && (focus = true)
        ig.PopID()
    end
    changed, active = text_input!(app, id, buf, field; flags, focus, role, size, input = true)
    if buf[1] == 0x00 && !isempty(placeholder)   # where the text would be
        with_font(role, size) do
            pw = Float32(ig.CalcTextSize(placeholder).x)
            ig.AddText(dl, (round(right ? inner.x1 - pw : inner.x0), input_text_y(role, size, centre_y(field))),
                u32(t.text_disabled), String(placeholder))
        end
    end
    if error || active
        ring = error ? t.red : t.accent
        ig.AddRect(dl, (b.x0 - hl / 2, b.y0 - hl / 2), (b.x1 + hl / 2, b.y1 + hl / 2), u32(ring),
            r + hl / 2, 2 * hl)
    else
        ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.input_border), r, hl)
    end
    return changed
end

# The next form row of a dialog body: its box at the cursor, `h` high and the body wide.
function form_row(app, h::Real)
    pos = ig.GetCursorScreenPos()
    return Box(pos.x, pos.y, pos.x + Float32(ig.CalcItemWidth()), pos.y + Float32(h))
end

# Take the space of a form row and the gap under it. ImGui adds its item spacing after
# the row, so the row takes that much less: the next row starts `gap` px under it, as the
# prototype's `.form` row gap. A last row (`gap = 0`) keeps its full height.
function end_form_row(app, b::Box; gap::Real = FORM_GAP_Y)
    ig.SetCursorScreenPos((b.x0, b.y0))
    spacing = unsafe_load(Ptr{lib.ImGuiStyle}(ig.GetStyle()).ItemSpacing).y
    ig.Dummy((width(b), gap > 0 ? height(b) + fpx(app.window.scale, gap) - spacing : height(b)))
    return nothing
end

# A form label in the label column of row `b`.
form_label(app, b::Box, text::AbstractString) =
    (draw_text_mid(ig.GetWindowDrawList(), FONT_REGULAR, BODY_FONT_SIZE, b.x0, centre_y(b),
        u32(app.tokens.text), elide(text_width, text, fpx(app.window.scale, FORM_LABEL_W))); nothing)

control_box(app, b::Box) = Box(b.x0 + fpx(app.window.scale, FORM_LABEL_W + FORM_GAP_X), b.y0, b.x1, b.y1)

# --- Rename ---

"""
    rename_problem(text) -> Union{Nothing,String}

Why `text` cannot be a new name, or `nothing`: a name cannot be blank.
"""
rename_problem(text::AbstractString) = isempty(strip(text)) ? "Type a name." : nothing

"""
    RenameDialog

Rename a database, a grid or a channel. `target` is the tree target `(kind, item, sub)`:
`(:database, id, "")`, `(:grid, id, "")` or `(:channel, database id, channel name)`.
`name` is the text field's buffer.
"""
struct RenameDialog
    target::Tuple{Symbol,String,String}
    old::String
    name::Vector{UInt8}
    focus::Base.RefValue{Bool}
end

"""
    open_rename!(app, target, name)

Open the Rename dialog for `target` (see `RenameDialog`), with the field holding `name`.
"""
open_rename!(app, target::Tuple{Symbol,String,String}, name::AbstractString) =
    push_dialog!(app, RenameDialog(target, String(name), set_field!(zeros(UInt8, FIELD_BYTES), name), Ref(true)))

function draw_modal(app, d::RenameDialog)
    text = field_text(d.name)
    draw_dialog(app, d; title = "Rename", icon = "rename", width = 380, ok_label = "Rename",
        ok_enabled = rename_problem(text) === nothing, on_ok = () -> finish_rename!(app, d)) do
        b = form_row(app, fpx(app.window.scale, FIELD_H))
        text_field!(app, "##Name", d.name, b; focus = d.focus[], flags = Int(lib.ImGuiInputTextFlags_AutoSelectAll))
        d.focus[] = false
        end_form_row(app, b; gap = 0)
    end
    return nothing
end

function finish_rename!(app, d::RenameDialog)
    new = String(strip(field_text(d.name)))
    rename_problem(new) === nothing || return nothing
    filter!(x -> x !== d, app.ui.dialogs)
    new == d.old && return nothing
    kind, id, sub = d.target
    if kind === :channel
        submit!(app, "Rename channel $sub", s -> Core.rename_channel!(s, id, sub, new);
            done = (a, _) -> a.ui.selected == d.target && (a.ui.selected = (:channel, id, new)))
    else
        submit!(app, "Rename $(d.old)", s -> Core.rename_item!(s, id, new))
    end
    return nothing
end

# --- Channel Properties ---

const FORMAT_CHOICES = (:normal => "Normal", :exponential => "Exponential", :date => "Date",
    :time => "Time")

"The text of a decimals setting: `\"auto\"` for -1 (the view chooses), else the number."
decimals_text(n::Integer) = n == -1 ? "auto" : string(n)

"""
    parse_decimals(text) -> Union{Nothing,Int}

The decimals of `text`: -1 for `"auto"` or blank, a whole number from 0, else `nothing`.
"""
function parse_decimals(text::AbstractString)::Union{Nothing,Int}
    t = lowercase(strip(text))
    (isempty(t) || t == "auto") && return -1
    n = tryparse(Int, t)
    return n !== nothing && n >= -1 ? n : nothing
end

parse_width(text::AbstractString) = (n = tryparse(Int, strip(text)); n !== nothing && n >= 1 ? n : nothing)

"""
    channel_info_problem(decimals, width) -> Union{Nothing,String}

What is wrong with the decimals and width texts of the Channel Properties dialog, or `nothing`.
"""
function channel_info_problem(decimals::AbstractString, width::AbstractString)::Union{Nothing,String}
    parse_decimals(decimals) === nothing && return "Decimals must be a whole number from 0, or auto."
    parse_width(width) === nothing && return "Width must be a whole number from 1."
    return nothing
end

"""
    ChannelPropsDialog

The Channel Properties of channel `channel` (as it was, a `ChannelRow`) of database `db`:
label, units, decimals, display format and column width, saved with `set_channel_info!`.
"""
struct ChannelPropsDialog
    db::String
    db_name::String
    channel::ChannelRow
    label::Vector{UInt8}
    units::Vector{UInt8}
    decimals::Vector{UInt8}
    width::Vector{UInt8}
    format::Base.RefValue{Symbol}
    focus::Base.RefValue{Bool}
end

"""
    open_channel_properties!(app, db, name)

Open the Channel Properties dialog of channel `name` of database `db`, as the snapshot
has it. Does nothing when the channel is not in the snapshot.
"""
function open_channel_properties!(app, db::AbstractString, name::AbstractString)
    v = app.snap === nothing ? nothing : get(app.snap.databases, db, nothing)
    k = v === nothing ? nothing : findfirst(c -> c.name == name, v.channels)
    k === nothing && return nothing
    c = v.channels[k]
    buf(text) = set_field!(zeros(UInt8, FIELD_BYTES), text)
    return push_dialog!(app, ChannelPropsDialog(String(db), item_name(app.snap, db), c, buf(c.label),
        buf(c.units), buf(decimals_text(c.decimals)), buf(string(c.width)), Ref(c.format), Ref(true)))
end

function draw_modal(app, d::ChannelPropsDialog)
    s = app.window.scale
    problem = channel_info_problem(field_text(d.decimals), field_text(d.width))
    draw_dialog(app, d; title = "Channel Properties", icon = "props", ok_label = "Apply",
        ok_enabled = problem === nothing, on_ok = () -> finish_channel_info!(app, d)) do
        h = fpx(s, FIELD_H)
        b = form_row(app, h)
        form_label(app, b, "Channel")
        c = control_box(app, b)
        draw_text_mid(ig.GetWindowDrawList(), FONT_REGULAR, BODY_FONT_SIZE, c.x0, centre_y(c),
            u32(app.tokens.text_dim), elide(text_width, d.channel.name * " in " * d.db_name, width(c)))
        end_form_row(app, b)
        for (label, buf) in (("Label", d.label), ("Units", d.units), ("Decimals", d.decimals),
                ("Width", d.width))
            b = form_row(app, h)
            form_label(app, b, label)
            text_field!(app, "##" * label, buf, control_box(app, b); focus = label == "Label" && d.focus[])
            # After the last row: no gap, or 4 px over the error line (`.hint` margin-top -4).
            gap = label != "Width" ? FORM_GAP_Y : problem === nothing ? 0 : FORM_GAP_Y - 4
            end_form_row(app, b; gap)
            label == "Decimals" && format_row!(app, d, h)
        end
        d.focus[] = false
        if problem !== nothing   # the prototype's `.hint.err`: 11 px red
            b = form_row(app, fpx(s, 11 * 1.35))
            draw_text_mid(ig.GetWindowDrawList(), FONT_REGULAR, 11, control_box(app, b).x0, centre_y(b),
                u32(app.tokens.red), problem; line = 1.35)
            end_form_row(app, b; gap = 0)
        end
    end
    return nothing
end

# The Format row: a combo of the four formats (four choices are more than a segmented
# control holds, by the rule of the tool forms).
function format_row!(app, d::ChannelPropsDialog, h::Real)
    b = form_row(app, h)
    form_label(app, b, "Format")
    k = findfirst(c -> first(c) === d.format[], FORMAT_CHOICES)
    text = k === nothing ? string(d.format[]) : last(FORMAT_CHOICES[k])
    combo!(app, "Format", control_box(app, b), text; items = () ->
        [MenuItem(name; checked = key === d.format[], action = _ -> (d.format[] = key; nothing))
         for (key, name) in FORMAT_CHOICES])
    end_form_row(app, b)
    return nothing
end

function finish_channel_info!(app, d::ChannelPropsDialog)
    decimals = parse_decimals(field_text(d.decimals))
    cols = parse_width(field_text(d.width))
    (decimals === nothing || cols === nothing) && return nothing
    filter!(x -> x !== d, app.ui.dialogs)
    c = d.channel
    label, units, format = String(strip(field_text(d.label))), String(strip(field_text(d.units))), d.format[]
    changed(new, old) = new == old ? nothing : new
    args = (label = changed(label, c.label), units = changed(units, c.units),
        decimals = changed(decimals, c.decimals), format = changed(format, c.format),
        width = changed(cols, c.width))
    all(isnothing, values(args)) && return nothing
    db, name = d.db, c.name
    submit!(app, "Channel properties of $name", s -> Core.set_channel_info!(s, db, name; args...))
    return nothing
end

# --- Results ---

"""
    ResultDialog(title, text)
    ResultDialog(title, lines, kinds; boxed = true)

A report in the mono font, with Copy and Close: the result of a quick tool (`text`, mono 12
on lines 1.4 high), or a job's report (`lines`, each with a kind, in the prototype's `.desc`
box). The dialog draws only the lines in view, and long lines scroll sideways.

- `kinds`: the colour of each line: `:text`, `:dim` (a heading), `:warn` (`amber`) or
  `:error` (`red`).
- `boxed`: the `.desc` box: `pane_header` fill, 1 px `border`, radius 6, padding 8 10,
  mono 11.5 on lines 1.45 high, at most 340 px high.
- `text`: what Copy puts on the clipboard: the lines, one per line.
"""
struct ResultDialog
    title::String
    text::String
    lines::Vector{String}
    kinds::Vector{Symbol}
    boxed::Bool
    "The widest line in device px and the scale it was measured at (measured once)."
    widest::Base.RefValue{Tuple{Float32,Float32}}
end

function ResultDialog(title::AbstractString, text::AbstractString)
    lines = String.(split(text, '\n'))
    return ResultDialog(String(title), String(text), lines, fill(:text, length(lines)), false, Ref((0f0, 0f0)))
end

function ResultDialog(title::AbstractString, lines::Vector{String}, kinds::Vector{Symbol}; boxed::Bool = true)
    length(kinds) == length(lines) || throw(ArgumentError("a ResultDialog needs one kind per line"))
    return ResultDialog(String(title), join(lines, '\n'), copy(lines), copy(kinds), boxed, Ref((0f0, 0f0)))
end

const RESULT_MAX_H = 360   # the text scrolls past this height
const RESULT_LINE = 1.4    # line height, times the 12 px mono font
const REPORT_MAX_H = 340   # the `.desc` box of a job report, padding and border included

# The mono font size and line height of the dialog's text.
result_font(d::ResultDialog) = d.boxed ? (11.5, 1.45) : (12, RESULT_LINE)

function widest_line(d::ResultDialog, scale::Float32)::Float32
    w, at = d.widest[]
    at == scale && return w
    size = first(result_font(d))
    w = maximum(l -> text_width(FONT_MONO, size, l), d.lines; init = 0f0)
    d.widest[] = (w, scale)
    return w
end

line_colour(t::Tokens, kind::Symbol) =
    kind === :dim ? t.text_dim : kind === :warn ? t.amber : kind === :error ? t.red : t.text

function draw_modal(app, d::ResultDialog)
    s = app.window.scale
    t = app.tokens
    size, lh = result_font(d)
    line_h = fpx(s, size * lh)
    n = length(d.lines)
    copy = () -> begin
        pos = ig.GetCursorScreenPos()
        button(app, "Copy", "Copy", pos.x, pos.y) || return nothing
        ig.SetClipboardText(d.text)
        toast!(app, :info, "Report copied")
        return nothing
    end
    draw_dialog(app, d; title = d.title, icon = "report", width = 640, ok_label = "Close",
        cancel_label = nothing, footer_left = copy, on_ok = () -> filter!(x -> x !== d, app.ui.dialogs)) do
        w = Float32(ig.CalcItemWidth())
        pos = ig.GetCursorScreenPos()
        hl = hairline(s)
        pad_x, pad_y = d.boxed ? (hl + fpx(s, 10), hl + fpx(s, 8)) : (0f0, 0f0)
        inner_w = w - 2 * pad_x
        wide = widest_line(d, s) > inner_w
        bar = wide ? fpx(s, 10) : 0f0   # room for the sideways scrollbar
        max_h = d.boxed ? fpx(s, REPORT_MAX_H) - 2 * pad_y : fpx(s, RESULT_MAX_H)
        h = min(n * line_h, max_h) + bar
        total = h + 2 * pad_y
        if d.boxed
            dl = ig.GetWindowDrawList()
            box = snap(Box(pos.x, pos.y, pos.x + w, pos.y + total))
            ig.AddRectFilled(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.pane_header), fpx(s, 6))
            ig.AddRect(dl, (box.x0, box.y0), (box.x1, box.y1), u32(t.border), fpx(s, 6), hl)
            ig.SetCursorScreenPos((pos.x + pad_x, pos.y + pad_y))
        end
        ig.BeginChild("report", (inner_w, h), 0, ig.ImGuiWindowFlags_NoBackground | ig.ImGuiWindowFlags_HorizontalScrollbar)
        dl = ig.GetWindowDrawList()
        top = ig.GetCursorScreenPos()   # the content's top left, scrolled
        for k in visible_rows(n, line_h, ig.GetScrollY(), h - bar)
            draw_text_mid(dl, FONT_MONO, size, top.x, top.y + (k - 0.5f0) * line_h,
                u32(line_colour(t, d.kinds[k])), d.lines[k]; line = lh)
        end
        ig.Dummy((max(widest_line(d, s), 1f0), n * line_h))
        ig.EndChild()
        if d.boxed   # the body holds the whole box, padding included
            ig.SetCursorScreenPos((pos.x, pos.y))
            ig.Dummy((w, total))
        end
    end
    return nothing
end
