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

# The loaded fonts of each ImGui context, in `FontRole` order. Only the render thread uses it.
const LOADED_FONTS = Dict{Ptr{ig.lib.ImGuiContext},NTuple{3,Ptr{ig.lib.ImFont}}}()

# Add one font file to the atlas. A file that does not load falls back to `fallback`.
function add_font(atlas, path::AbstractString, fallback::AbstractString)::Ptr{ig.lib.ImFont}
    font = ig.AddFontFromFileTTF(atlas, path, BODY_FONT_SIZE)
    font != C_NULL && return font
    @warn "Could not load the font $path. Using $fallback."
    font = ig.AddFontFromFileTTF(atlas, fallback, BODY_FONT_SIZE)
    font == C_NULL && error("could not load the bundled font $fallback")
    return font
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
    return nothing
end

forget_fonts!(ctx::Ptr{ig.lib.ImGuiContext}) = (delete!(LOADED_FONTS, ctx); nothing)

"""
    with_font(f, which::FontRole, size)

Draw `f()` with font `which` at `size` logical pixels.
ImGui multiplies the size by `style.FontScaleDpi`, so the text is `size * scale` pixels high.
"""
function with_font(f, which::FontRole, size::Real)
    fonts = LOADED_FONTS[ig.GetCurrentContext()]
    ig.PushFont(fonts[Int(which) + 1], Float32(size))
    try
        return f()
    finally
        ig.PopFont()
    end
end
