# Keyboard chords. `parse_chord` and `shortcut_command` are pure; `chord_pressed` and
# `handle_shortcuts!` read the ImGui key state.

# `Chord` is defined in commands.jl, which caches the chords of the commands.

# Shortcuts that are not the one in `Command.shortcut`.
const SHORTCUT_ALIASES = ["Ctrl+Shift+Z" => "session.redo"]

# Key names the chords use that ImGui spells differently.
const KEY_NAMES = Dict(:Left => :LeftArrow, :Right => :RightArrow, :Up => :UpArrow, :Down => :DownArrow)

imgui_key_name(key::Symbol) = Symbol("ImGuiKey_", get(KEY_NAMES, key, key))

"""
    parse_chord("Ctrl+Shift+Z") -> (ctrl, shift, alt, key)

Modifiers are `Ctrl`, `Shift` and `Alt`; the last part is the key, such as `Z`, `F1` or `Left`.
Throws `ArgumentError` for a chord without a key or with an unknown key.
"""
function parse_chord(text::AbstractString)::Chord
    ctrl = shift = alt = false
    key = nothing
    for part in split(text, '+')
        if part == "Ctrl"
            ctrl = true
        elseif part == "Shift"
            shift = true
        elseif part == "Alt"
            alt = true
        elseif key === nothing && !isempty(part)
            key = Symbol(part)
        else
            throw(ArgumentError("bad chord \"$text\""))
        end
    end
    key === nothing && throw(ArgumentError("the chord \"$text\" has no key"))
    isdefined(lib, imgui_key_name(key)) || throw(ArgumentError("unknown key \"$key\" in chord \"$text\""))
    return (; ctrl, shift, alt, key)
end

# The modifier keys held now, as (ctrl, shift, alt). Reads the three fields through the
# pointer, without copying the whole `ImGuiIO`.
function held_modifiers()::NTuple{3,Bool}
    io = Ptr{lib.ImGuiIO}(ig.GetIO())
    return (unsafe_load(io.KeyCtrl), unsafe_load(io.KeyShift), unsafe_load(io.KeyAlt))
end

"True when the chord's key went down in this frame and exactly its modifiers (`held`) are held."
function chord_pressed(chord::Chord, held::NTuple{3,Bool} = held_modifiers())::Bool
    held == (chord.ctrl, chord.shift, chord.alt) || return false
    return ig.IsKeyPressed(getproperty(lib, imgui_key_name(chord.key)), false)
end

# Every chord with its command id: the commands' shortcuts and the aliases.
function chord_table(cmds)::Vector{Pair{Chord,String}}
    table = Pair{Chord,String}[parse_chord(c.shortcut) => c.id for c in cmds if !isempty(c.shortcut)]
    for (text, id) in SHORTCUT_ALIASES
        push!(table, parse_chord(text) => id)
    end
    return table
end

# Chords that undo or redo text while a text field is active.
const TEXT_UNDO_KEYS = (:Z, :Y)

"""
    shortcut_command(cmds, chord, modal_open, text_active) -> Union{Nothing,Command}

The command that `chord` runs, or `nothing`.
While a modal dialog or the command search is open only `Ctrl+K` and `Esc` pass.
While a text field is active only chords with `Ctrl` pass, and never `Ctrl+Z` or `Ctrl+Y`
(the text field undoes its own text).
"""
function shortcut_command(cmds, chord::Chord, modal_open::Bool, text_active::Bool;
        table = chord_table(cmds))::Union{Nothing,Command}
    if modal_open
        search = chord.ctrl && !chord.shift && !chord.alt && chord.key === :K
        search || chord.key === :Escape || return nothing
    end
    if text_active
        chord.ctrl || return nothing
        chord.key in TEXT_UNDO_KEYS && return nothing
    end
    for (c, id) in table
        c == chord || continue
        i = findfirst(x -> x.id == id, cmds)
        return i === nothing ? nothing : cmds[i]
    end
    return nothing
end

"""
    handle_shortcuts!(app)

Run the command of the chord pressed in this frame, if it can run. An error in the command
becomes an error toast, as for a click (`guarded`). Call it once per frame on the render
thread, after the frame's widgets, so `WantTextInput` is current.
"""
function handle_shortcuts!(app)
    cmds = commands(app)
    table = command_chords(app)   # parsed once per command list, not per frame
    modal = blocks_shortcuts(app)   # a dialog or the command search is open
    text = unsafe_load(Ptr{lib.ImGuiIO}(ig.GetIO()).WantTextInput)
    held = held_modifiers()
    for (chord, id) in table
        chord_pressed(chord, held) || continue
        cmd = shortcut_command(cmds, chord, modal, text; table)
        cmd === nothing && continue
        cmd.enabled(app) === nothing && guarded(app, cmd.run)
        return nothing
    end
    return nothing
end

# --- The list of shortcuts (Help > Keyboard Shortcuts) ---

"""
    ShortcutRow

One row of the shortcut list: the `keys` that do the same thing (shown with "or" between
them) and what they do.
"""
struct ShortcutRow
    keys::Vector{String}
    text::String
end

# What the shortcuts of the shell and the map do, in the prototype's words and order (section 9).
const SHORTCUT_TEXTS = ["ui.command_search" => "Command search", "session.undo" => "Undo",
    "session.redo" => "Redo", "project.new" => "New project", "project.open" => "Open project",
    "ui.ribbon" => "Collapse or expand the ribbon", "ui.theme.toggle" => "Switch light and dark",
    "map.full_extent" => "Map: full extent"]

const ESC_ROW = ShortcutRow(["Esc"], "Close a dialog, menu or the command search")

"""
    shortcut_rows(cmds) -> Vector{ShortcutRow}

Every shortcut that works, for the Keyboard Shortcuts dialog: the shell's in the
prototype's order, then any other command's shortcut (by the command's name), then Esc.
A command's aliases (Ctrl+Shift+Z for Redo) share its row.
"""
function shortcut_rows(cmds::AbstractVector{Command})::Vector{ShortcutRow}
    keyed = [c for c in cmds if !isempty(c.shortcut)]
    order = first.(SHORTCUT_TEXTS)
    sort!(keyed; by = c -> something(findfirst(==(c.id), order), length(order) + 1))   # stable
    rows = ShortcutRow[]
    for c in keyed
        keys = [c.shortcut]
        append!(keys, text for (text, id) in SHORTCUT_ALIASES if id == c.id)
        k = findfirst(==(c.id), order)
        push!(rows, ShortcutRow(keys, k === nothing ? plain_name(c) : last(SHORTCUT_TEXTS[k])))
    end
    push!(rows, ESC_ROW)
    return rows
end

"The Keyboard Shortcuts dialog (Help > Keyboard Shortcuts)."
struct ShortcutsDialog end

"Open the Keyboard Shortcuts dialog, unless it is open."
function open_shortcuts!(app)
    any(d -> d isa ShortcutsDialog, app.ui.dialogs) || push_dialog!(app, ShortcutsDialog())
    return nothing
end

const SHORTCUT_KEYS_W = 240   # the key column
const SHORTCUT_GAP = (6, 16)  # between rows, between the columns
const SHORTCUT_ROW_H = 19     # a key cap

"""
    draw_modal(app, ::ShortcutsDialog)

The list of shortcuts, as the prototype's `openShortcuts`: a 600 px dialog with the keys in
a 240 px column (key caps, "or" between keys that do the same), what they do in the other,
and a Close button.
"""
function draw_modal(app, d::ShortcutsDialog)
    draw_dialog(app, d; title = "Keyboard Shortcuts", icon = "keyboard", width = 600,
        ok_label = "Close", cancel_label = nothing, on_ok = () -> pop_dialog!(app)) do
        draw_shortcut_rows(app, shortcut_rows(commands(app)))
    end
    return nothing
end

function draw_shortcut_rows(app, rows::Vector{ShortcutRow})
    s = app.window.scale
    t = app.tokens
    f(v) = fpx(s, v)
    dl = ig.GetWindowDrawList()
    pos = ig.GetCursorScreenPos()
    x0, y = pos.x, pos.y
    or_w = text_width(FONT_REGULAR, BODY_FONT_SIZE, " or ")
    for (k, r) in enumerate(rows)
        k > 1 && (y += f(SHORTCUT_ROW_H + SHORTCUT_GAP[1]))
        mid = y + f(SHORTCUT_ROW_H) / 2
        x = x0
        for (i, key) in enumerate(r.keys)
            if i > 1
                draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x, mid, u32(t.text_dim), " or ")
                x += or_w
            end
            x += draw_kbd(app, dl, x, mid, key)
        end
        # The text's line box (1.25) sits at the top of the row, as in the prototype's grid.
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x0 + f(SHORTCUT_KEYS_W + SHORTCUT_GAP[2]),
            y + f(BODY_FONT_SIZE * 1.25f0) / 2, u32(t.text), r.text)
    end
    h = length(rows) * f(SHORTCUT_ROW_H) + (length(rows) - 1) * f(SHORTCUT_GAP[1])
    ig.Dummy((0f0, h))   # only its height counts: the dialog sets the width
    return nothing
end
