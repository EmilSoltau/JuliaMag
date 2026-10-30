# Colour tokens. The values are copied from prototype/juliamag-ui.html (lines 9-46).
# A test reads the prototype and checks every value, so the two cannot drift apart.
# Widget code never has a colour literal. It reads a field of the active `Tokens`.

"""
    hex_rgba(s) -> NTuple{4,Float32}

Turn `"#RRGGBB"` into straight RGBA with every part from 0 to 1.
"""
function hex_rgba(s::AbstractString)::NTuple{4,Float32}
    m = match(r"^#([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})$", s)
    m === nothing && throw(ArgumentError("expected a colour like #RRGGBB, got \"$s\""))
    r, g, b = (parse(UInt8, p; base = 16) / 255f0 for p in m.captures)
    return (r, g, b, 1f0)
end

# `rgba(r, g, b, a)` with r, g, b from 0 to 255 and a from 0 to 1.
function rgba(r::Integer, g::Integer, b::Integer, a::Real)::NTuple{4,Float32}
    return (r / 255f0, g / 255f0, b / 255f0, Float32(a))
end

"""
    Tokens

One straight RGBA colour (0 to 1) per prototype token.
Field names are the prototype names in snake case.
"""
struct Tokens
    header::NTuple{4,Float32}
    ribbon::NTuple{4,Float32}
    tab_strip::NTuple{4,Float32}
    canvas::NTuple{4,Float32}
    pane::NTuple{4,Float32}
    pane_header::NTuple{4,Float32}
    border::NTuple{4,Float32}
    border_strong::NTuple{4,Float32}
    text::NTuple{4,Float32}
    text_dim::NTuple{4,Float32}
    text_disabled::NTuple{4,Float32}
    icon::NTuple{4,Float32}
    hover::NTuple{4,Float32}
    pressed::NTuple{4,Float32}
    checked::NTuple{4,Float32}
    accent::NTuple{4,Float32}
    accent_text::NTuple{4,Float32}
    on_accent::NTuple{4,Float32}
    input::NTuple{4,Float32}
    input_border::NTuple{4,Float32}
    group_label::NTuple{4,Float32}
    status_bar::NTuple{4,Float32}
    selection::NTuple{4,Float32}
    menu::NTuple{4,Float32}
    shadow::NTuple{4,Float32}
    green::NTuple{4,Float32}
    red::NTuple{4,Float32}
    amber::NTuple{4,Float32}
    context::NTuple{4,Float32}
    context_tint::NTuple{4,Float32}
    well::NTuple{4,Float32}
    stripe::NTuple{4,Float32}
    backdrop::NTuple{4,Float32}
    brand::NTuple{4,Float32}
    brand_dark::NTuple{4,Float32}
    brand_tint::NTuple{4,Float32}
end

const LIGHT = Tokens(
    hex_rgba("#EEF1F5"), hex_rgba("#FFFFFF"), hex_rgba("#EEF1F5"), hex_rgba("#E4E8EE"),
    hex_rgba("#FBFCFD"), hex_rgba("#F3F5F8"), hex_rgba("#DDE2E9"), hex_rgba("#C3CAD4"),
    hex_rgba("#1F2630"), hex_rgba("#5E6977"), hex_rgba("#A9B1BC"), hex_rgba("#3A4554"),
    hex_rgba("#E9F0FB"), hex_rgba("#D4E2F8"), hex_rgba("#DCE8FA"),
    hex_rgba("#2563EB"), hex_rgba("#1D4EC4"), hex_rgba("#FFFFFF"),
    hex_rgba("#FFFFFF"), hex_rgba("#C6CDD7"), hex_rgba("#707A88"), hex_rgba("#F3F5F8"),
    hex_rgba("#CFE0FC"), hex_rgba("#FFFFFF"), rgba(0, 0, 0, 0.11),
    hex_rgba("#169A5A"), hex_rgba("#D13C3C"), hex_rgba("#E59E1A"),
    hex_rgba("#0E9384"), hex_rgba("#E3F5F2"),
    hex_rgba("#DDE3EA"), hex_rgba("#F6F8FA"), rgba(20, 26, 34, 0.28),
    hex_rgba("#7D4A9B"), hex_rgba("#693D83"), hex_rgba("#FFD36E"),
)

# The dark block does not set brand, brand_dark and brand_tint. They keep the light value.
const DARK = Tokens(
    hex_rgba("#171B21"), hex_rgba("#242931"), hex_rgba("#171B21"), hex_rgba("#12151A"),
    hex_rgba("#1E232A"), hex_rgba("#242931"), hex_rgba("#343B45"), hex_rgba("#48515D"),
    hex_rgba("#E6EAEF"), hex_rgba("#9AA4B1"), hex_rgba("#5C6571"), hex_rgba("#C9D1DB"),
    hex_rgba("#2F3744"), hex_rgba("#2A3D5E"), hex_rgba("#283B5C"),
    hex_rgba("#5B8DF6"), hex_rgba("#8AAFFA"), hex_rgba("#FFFFFF"),
    hex_rgba("#15191F"), hex_rgba("#444D59"), hex_rgba("#8C96A3"), hex_rgba("#1A1E24"),
    hex_rgba("#26406E"), hex_rgba("#262C34"), rgba(0, 0, 0, 0.43),
    hex_rgba("#3FC282"), hex_rgba("#F06A6A"), hex_rgba("#F2B848"),
    hex_rgba("#2CC2AE"), hex_rgba("#1B3331"),
    hex_rgba("#3A424D"), hex_rgba("#21262D"), rgba(0, 0, 0, 0.45),
    LIGHT.brand, LIGHT.brand_dark, LIGHT.brand_tint,
)

@enum ThemeMode THEME_LIGHT THEME_DARK THEME_SYSTEM

"""
    tokens_for(mode, system_dark) -> Tokens

The tokens to draw with. `system_dark` only matters for `THEME_SYSTEM`.
"""
function tokens_for(mode::ThemeMode, system_dark::Bool)::Tokens
    mode == THEME_LIGHT && return LIGHT
    mode == THEME_DARK && return DARK
    return system_dark ? DARK : LIGHT
end

# Style sizes in logical pixels, from the prototype. `apply_style!` scales them.
const BODY_FONT_SIZE = 12.5f0
const STYLE_SIZES = (;
    FramePadding = (8f0, 4f0),
    ItemSpacing = (6f0, 5f0),
    FrameRounding = 5f0,
    PopupRounding = 8f0,
    WindowRounding = 10f0,
    ScrollbarSize = 10f0,
    GrabRounding = 5f0,
)
const BORDER_SIZES = (:WindowBorderSize, :ChildBorderSize, :PopupBorderSize, :FrameBorderSize)

# The ImGui colour slots and the token each one takes.
const STYLE_COLOURS = (
    ig.ImGuiCol_WindowBg => :pane,
    ig.ImGuiCol_FrameBg => :input,
    ig.ImGuiCol_FrameBgHovered => :input,
    ig.ImGuiCol_FrameBgActive => :input,
    ig.ImGuiCol_Border => :input_border,
    ig.ImGuiCol_Button => :ribbon,
    ig.ImGuiCol_ButtonHovered => :hover,
    ig.ImGuiCol_ButtonActive => :pressed,
    ig.ImGuiCol_HeaderHovered => :hover,
    ig.ImGuiCol_HeaderActive => :pressed,
    ig.ImGuiCol_Header => :selection,
    ig.ImGuiCol_Text => :text,
    ig.ImGuiCol_TextDisabled => :text_disabled,
    ig.ImGuiCol_PopupBg => :menu,
    ig.ImGuiCol_ModalWindowDimBg => :backdrop,
    ig.ImGuiCol_CheckMark => :accent,
    ig.ImGuiCol_SliderGrab => :accent,
    ig.ImGuiCol_SliderGrabActive => :accent,
    ig.ImGuiCol_Tab => :tab_strip,
    ig.ImGuiCol_TabHovered => :hover,
    ig.ImGuiCol_TabSelected => :ribbon,
    ig.ImGuiCol_TabDimmed => :tab_strip,
    ig.ImGuiCol_TabDimmedSelected => :ribbon,
    ig.ImGuiCol_Separator => :border,
    ig.ImGuiCol_ScrollbarGrab => :border_strong,
    ig.ImGuiCol_NavCursor => :accent,
)

# Relative luminance of a token, to pick the light or dark ImGui preset as a base.
luminance(c::NTuple{4,Float32}) = 0.2126f0 * c[1] + 0.7152f0 * c[2] + 0.0722f0 * c[3]

"""
    apply_style!(t::Tokens, scale)

Set the style of the current ImGui context from the tokens, with sizes scaled by `scale`.
It starts from a fresh default style each time, so calling it again never scales twice.
Colours that no token covers come from the ImGui light or dark preset.
"""
function apply_style!(t::Tokens, scale::Real)
    s = Float32(scale)
    style = Ptr{ig.lib.ImGuiStyle}(ig.GetStyle())
    fresh = ig.lib.ImGuiStyle_ImGuiStyle()
    try
        unsafe_store!(style, unsafe_load(fresh))
    finally
        ig.lib.ImGuiStyle_destroy(fresh)
    end
    luminance(t.pane) < 0.5f0 ? ig.StyleColorsDark() : ig.StyleColorsLight()
    for (slot, name) in STYLE_COLOURS
        ig.c_set!(style.Colors, slot, ig.ImVec4(getfield(t, name)...))
    end
    for (name, value) in pairs(STYLE_SIZES)
        setproperty!(style, name, value isa Tuple ? ig.ImVec2(value...) : value)
    end
    ig.ScaleAllSizes(style, s)
    border = max(1f0, round(s))
    for name in BORDER_SIZES
        setproperty!(style, name, border)
    end
    style.FontSizeBase = BODY_FONT_SIZE
    style.FontScaleDpi = s
    return nothing
end
