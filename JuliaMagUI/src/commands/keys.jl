# Keyboard chords. `parse_chord` and `shortcut_command` are pure; `chord_pressed` and
# `handle_shortcuts!` read the ImGui key state.

const Chord = NamedTuple{(:ctrl, :shift, :alt, :key),Tuple{Bool,Bool,Bool,Symbol}}

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

"True when the chord's key went down in this frame and exactly its modifiers are held."
function chord_pressed(chord::Chord)::Bool
    io = unsafe_load(ig.GetIO())
    (io.KeyCtrl == chord.ctrl && io.KeyShift == chord.shift && io.KeyAlt == chord.alt) || return false
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
While a modal dialog is open only `Ctrl+K` and `Esc` pass.
While a text field is active only chords with `Ctrl` pass, and never `Ctrl+Z` or `Ctrl+Y`
(the text field undoes its own text).
"""
function shortcut_command(cmds, chord::Chord, modal_open::Bool, text_active::Bool)::Union{Nothing,Command}
    if modal_open
        search = chord.ctrl && !chord.shift && !chord.alt && chord.key === :K
        search || chord.key === :Escape || return nothing
    end
    if text_active
        chord.ctrl || return nothing
        chord.key in TEXT_UNDO_KEYS && return nothing
    end
    for (c, id) in chord_table(cmds)
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
    modal = !isempty(app.ui.dialogs)
    text = unsafe_load(ig.GetIO()).WantTextInput
    for (chord, id) in chord_table(cmds)
        chord_pressed(chord) || continue
        cmd = shortcut_command(cmds, chord, modal, text)
        cmd === nothing && continue
        cmd.enabled(app) === nothing && guarded(app, cmd.run)
        return nothing
    end
    return nothing
end
