# Fonts: find the files, load them into the ImGui font atlas, push them while drawing.
# Dear ImGui 1.92+ makes glyphs on demand at the size used, so one loaded font serves every size.

"""
    FontRole

Which of the three app fonts to use: `FONT_REGULAR`, `FONT_SEMIBOLD` or `FONT_MONO`.
"""
@enum FontRole FONT_REGULAR FONT_SEMIBOLD FONT_MONO

const FONT_DIR = joinpath(@__DIR__, "..", "..", "assets", "fonts")

"""
    BUNDLED_FONTS

The font files shipped with the package: Inter (Regular and SemiBold) and Cousine.
Tests and screenshots use them, so they look the same on every machine.
"""
const BUNDLED_FONTS = (;
    regular = normpath(joinpath(FONT_DIR, "Inter-Regular.ttf")),
    semibold = normpath(joinpath(FONT_DIR, "Inter-SemiBold.ttf")),
    mono = normpath(joinpath(FONT_DIR, "Cousine-Regular.ttf")),
)

# System fonts to look for, best first. Each body font needs both files of its pair.
const SYSTEM_BODY_FONTS = (
    ("segoeui.ttf", "seguisb.ttf"),
    ("Ubuntu-R.ttf", "Ubuntu-M.ttf"),
    ("NotoSans-Regular.ttf", "NotoSans-SemiBold.ttf"),
    ("DejaVuSans.ttf", "DejaVuSans-Bold.ttf"),
)
const SYSTEM_MONO_FONTS = ("CascadiaMono.ttf", "consola.ttf", "DejaVuSansMono.ttf")

"""
    system_font_dirs() -> Vector{String}

The folders that hold the system fonts on this platform.
"""
function system_font_dirs()::Vector{String}
    if Sys.iswindows()
        return [joinpath(get(ENV, "WINDIR", raw"C:\Windows"), "Fonts")]
    elseif Sys.islinux()
        return ["/usr/share/fonts"]
    end
    return String[]
end

# Map each wanted file name to the first path found for it under `dirs`.
function index_font_files(dirs, wanted)::Dict{String,String}
    found = Dict{String,String}()
    for dir in dirs
        isdir(dir) || continue
        for (root, _, files) in walkdir(dir; onerror = _ -> nothing)
            for f in files
                f in wanted && !haskey(found, f) && (found[f] = joinpath(root, f))
            end
        end
    end
    return found
end

"""
    find_system_fonts(dirs = system_font_dirs())

The font files to use, as `(; regular, semibold, mono)`.
Takes the first system body pair and the first system mono font found under `dirs`.
What is not found comes from `BUNDLED_FONTS`.
"""
function find_system_fonts(dirs = system_font_dirs())
    wanted = Set{String}(SYSTEM_MONO_FONTS)
    for pair in SYSTEM_BODY_FONTS
        push!(wanted, pair...)
    end
    found = index_font_files(dirs, wanted)
    regular, semibold = BUNDLED_FONTS.regular, BUNDLED_FONTS.semibold
    for (r, s) in SYSTEM_BODY_FONTS
        if haskey(found, r) && haskey(found, s)
            regular, semibold = found[r], found[s]
            break
        end
    end
    mono = BUNDLED_FONTS.mono
    for m in SYSTEM_MONO_FONTS
        if haskey(found, m)
            mono = found[m]
            break
        end
    end
    return (; regular, semibold, mono)
end

"""
    font_paths(source::Symbol)

The font files for `source`: `:system` (system fonts, else bundled) or `:bundled`.
"""
function font_paths(source::Symbol)
    source === :bundled && return BUNDLED_FONTS
    source === :system && return find_system_fonts()
    throw(ArgumentError("fonts must be :system or :bundled, got :$source"))
end

"""
    font_metrics(path) -> (ratio, ascent)

How a font file's sizes relate to CSS sizes, from its `head` and `hhea` tables.

- `ratio`: how much bigger the font must be asked of ImGui to match a CSS font of the same
  size. CSS sizes a font by its em; ImGui sizes it by its height, ascender minus
  descender. The ratio is that height over the em.
- `ascent`: the ascender as a part of that height, to put the baseline where a browser
  puts it.

A file that cannot be read gives `(1, 0.8)`.
"""
function font_metrics(path::AbstractString)::NTuple{2,Float32}
    fallback = (1f0, 0.8f0)
    try
        return open(path) do io
            read(io, UInt32)   # the sfnt version
            n = ntoh(read(io, UInt16))
            skip(io, 6)
            upm = 0
            ascender = descender = 0
            for _ in 1:n
                tag = String(read(io, 4))
                skip(io, 4)   # the checksum
                offset = ntoh(read(io, UInt32))
                skip(io, 4)   # the length
                back = position(io)
                if tag == "head"
                    seek(io, offset + 18)
                    upm = Int(ntoh(read(io, UInt16)))
                elseif tag == "hhea"
                    seek(io, offset + 4)
                    ascender = Int(ntoh(read(io, Int16)))
                    descender = Int(ntoh(read(io, Int16)))
                end
                seek(io, back)
            end
            height = ascender - descender
            (upm > 0 && height > 0) || return fallback
            r = Float32(height / upm)
            0.8f0 <= r <= 2f0 ? (r, Float32(ascender / height)) : fallback
        end
    catch e
        e isa InterruptException && rethrow()
        return fallback
    end
end

"""
    LoadedFont

A font in the ImGui atlas with its `font_metrics`.
"""
struct LoadedFont
    font::Ptr{ig.lib.ImFont}
    ratio::Float32
    ascent::Float32
end

LoadedFont(font::Ptr{ig.lib.ImFont}, path::AbstractString) = LoadedFont(font, font_metrics(path)...)

# The loaded fonts of each ImGui context, in `FontRole` order. Only the render thread uses it.
const LOADED_FONTS = Dict{Ptr{ig.lib.ImGuiContext},NTuple{3,LoadedFont}}()

# Add one font file to the atlas. A file that does not load falls back to `fallback`.
function add_font(atlas, path::AbstractString, fallback::AbstractString)::LoadedFont
    font = ig.AddFontFromFileTTF(atlas, path, BODY_FONT_SIZE)
    font != C_NULL && return LoadedFont(font, path)
    @warn "Could not load the font $path. Using $fallback."
    font = ig.AddFontFromFileTTF(atlas, fallback, BODY_FONT_SIZE)
    font == C_NULL && error("could not load the bundled font $fallback")
    return LoadedFont(font, fallback)
end

"""
    body_font_size(ctx = ig.GetCurrentContext()) -> Float32

The ImGui size of the body font (12.5 px in CSS terms) in context `ctx`, before the DPI
scale. ImGui widgets that draw text without `with_font` use it.
"""
function body_font_size(ctx = ig.GetCurrentContext())::Float32
    fonts = get(LOADED_FONTS, ctx, nothing)
    return BODY_FONT_SIZE * (fonts === nothing ? 1f0 : fonts[1].ratio)
end

"""
    load_fonts!(w::Window, source::Symbol)

Load the regular, semibold and mono fonts into the font atlas of the window's ImGui context.
The regular font is the default font.
See `font_paths` for `source`.
"""
function load_fonts!(w, source::Symbol)
    paths = font_paths(source)
    atlas = unsafe_load(ig.GetIO().Fonts)
    regular = add_font(atlas, paths.regular, BUNDLED_FONTS.regular)
    semibold = add_font(atlas, paths.semibold, BUNDLED_FONTS.semibold)
    mono = add_font(atlas, paths.mono, BUNDLED_FONTS.mono)
    LOADED_FONTS[w.ctx] = (regular, semibold, mono)
    style = Ptr{ig.lib.ImGuiStyle}(ig.GetStyle())
    style.FontSizeBase = body_font_size(w.ctx)   # `apply_style!` set it before the fonts were known
    return nothing
end

forget_fonts!(ctx::Ptr{ig.lib.ImGuiContext}) = (delete!(LOADED_FONTS, ctx); nothing)

"""
    with_font(f, which::FontRole, size)

Draw `f()` with font `which` at `size` logical pixels, as CSS sizes fonts: the em of the
glyphs is `size`. ImGui multiplies by `style.FontScaleDpi`, so the em is `size * scale`
pixels. Inside `f`, `ig.GetFontSize()` is the line height of the glyphs (ascender to
descender), in device pixels; ImGui rounds it to whole pixels.
"""
function with_font(f, which::FontRole, size::Real)
    loaded = loaded_font(which)
    ig.PushFont(loaded.font, Float32(size) * loaded.ratio)
    try
        return f()
    finally
        ig.PopFont()
    end
end

# The loaded font of `which` in the current ImGui context.
loaded_font(which::FontRole) = LOADED_FONTS[ig.GetCurrentContext()][Int(which) + 1]

"""
    text_y(which, size, mid_y; line = 1.25) -> Float32

The top for ImGui text of font `which` at `size` (logical px) in a CSS line box `line`
times the font size high, centred on `mid_y`. The baseline lands where a browser (Blink)
puts it: the line top rounded to a pixel, plus the half leading rounded down, plus the
ascender rounded. Call it inside `with_font(which, size)`.
"""
function text_y(which::FontRole, size::Real, mid_y::Real; line::Real = 1.25)::Float32
    loaded = loaded_font(which)
    style = Ptr{ig.lib.ImGuiStyle}(ig.GetStyle())
    em = Float32(size) * unsafe_load(style.FontScaleDpi)
    ascender = floor(em * loaded.ratio * loaded.ascent + 0.5f0)
    descender = floor(em * loaded.ratio * (1 - loaded.ascent) + 0.5f0)
    box = Float32(line) * em
    top = floor(Float32(mid_y) - box / 2 + 0.5f0)
    baseline = top + floor((box - ascender - descender) / 2) + ascender
    return round(baseline - unsafe_load(ig.GetFontBaked().Ascent))
end
