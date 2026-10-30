# Icons: the prototype's SVG icons, drawn with Rsvg into one texture.
# `tools/extract_icons.jl` wrote the SVG files from the prototype. They use placeholder
# colours (see `ICON_PLACEHOLDERS`), which the atlas swaps for theme colours.

const ICON_DIR = normpath(joinpath(@__DIR__, "..", "..", "assets", "icons"))

# The package recompiles when an icon file changes, is added or is removed.
include_dependency(ICON_DIR)
foreach(f -> endswith(f, ".svg") && include_dependency(joinpath(ICON_DIR, f)), readdir(ICON_DIR))

"""
    ICON_SIZES

The icon sizes in the atlas, in logical pixels.
"""
const ICON_SIZES = (10, 12, 14, 16, 18, 22, 24, 32, 48)

"""
    ICON_STYLES

How an icon is coloured:

- `:normal`: ink `icon`, accent `accent`.
- `:disabled`: `text_disabled` for every colour.
- `:nav`: on the brand colour of the backstage nav; ink `on_accent` (white), accent `brand_tint`.
- `:on_accent`: on an accent fill; ink `on_accent` (white), accent `accent`.
- `:dim`: ink `text_dim`, as the prototype's search pill and ribbon chevron.
"""
const ICON_STYLES = (:normal, :disabled, :nav, :on_accent, :dim)

"""
    ICON_STYLE_SIZES

The sizes the atlas holds for each style, as the prototype uses them:
`:normal` at every size, `:disabled` for buttons and menus, `:nav` for the backstage
nav (18) and its cards (48), `:on_accent` for selected rows (16) and dialog heads (22),
`:dim` for the search pill and the ribbon chevron (14).
Another size is drawn scaled from the next bigger size of its style.
"""
const ICON_STYLE_SIZES = (ICON_SIZES, (16, 18, 32), (18, 48), (16, 22), (14,))

# The placeholder colour of each prototype colour variable in the SVG files.
# tools/extract_icons.jl writes the same table.
const ICON_PLACEHOLDERS = (;
    ink = "#000001", accent = "#000002", green = "#000003", red = "#000004",
    amber = "#000005", halo = "#000006", white = "#000007", brand = "#000008",
)

# An icon name the atlas does not have draws this one.
const FALLBACK_ICON = "tool"

# Names that draw another icon. "tool" is the generic tool icon: the prototype's toolbox.
const ICON_ALIASES = Dict("tool" => "tools")

# The core's icon words and the importer and exporter ids, with the prototype icon of each.
const CORE_ICONS = Dict(
    "crs" => "crs",
    "reproject" => "reproject",
    "pair" => "pair",
    "globe" => "utm",
    "statistics" => "stats",
    "math" => "math",
    "channel" => "channel",
    "import.geosoft_xyz" => "import",
    "import.csv" => "fileCsv",
    "import.geotiff" => "import",
    "import.ers" => "import",
    "import.grd" => "import",
    "export.geosoft_xyz" => "export",
    "export.csv" => "export",
    "export.parquet" => "export",
    "export.geotiff" => "export",
    "export.ers" => "export",
    "export.geosoft_grd" => "export",
)

"""
    icon_for(core_icon) -> String

The prototype icon name for an icon word of the core (`ToolSpec.icon`) or an importer or
exporter id. An unknown word gives `"tool"`.
"""
icon_for(core_icon::AbstractString)::String = get(CORE_ICONS, core_icon, FALLBACK_ICON)

# The SVG text of every icon, read at first use. Sorted by name.
# `__init__` empties it, so a cache filled while precompiling is never used.
const ICON_SVGS = Ref{Union{Nothing,Vector{Pair{String,String}}}}(nothing)

function icon_svgs()::Vector{Pair{String,String}}
    svgs = ICON_SVGS[]
    if svgs === nothing
        files = sort!(filter(f -> endswith(f, ".svg"), readdir(ICON_DIR)))
        svgs = [first(splitext(f)) => read(joinpath(ICON_DIR, f), String) for f in files]
        ICON_SVGS[] = svgs
    end
    return svgs
end

hex_colour(c::NTuple{4,Float32}) =
    "#" * join(string(round(Int, clamp(x, 0f0, 1f0) * 255); base = 16, pad = 2) for x in c[1:3])

# The colour that takes each placeholder, for one style.
function style_colours(t::Tokens, style::Symbol)
    white = t.on_accent
    ink, accent, green, red, amber = if style === :normal
        (t.icon, t.accent, t.green, t.red, t.amber)
    elseif style === :disabled
        ntuple(_ -> t.text_disabled, 5)
    elseif style === :nav
        (white, t.brand_tint, t.green, t.red, t.amber)
    elseif style === :on_accent
        (white, t.accent, t.green, t.red, t.amber)
    elseif style === :dim
        (t.text_dim, t.accent, t.green, t.red, t.amber)
    else
        throw(ArgumentError("icon style must be one of $(ICON_STYLES), got :$style"))
    end
    p = ICON_PLACEHOLDERS
    return (p.ink => hex_colour(ink), p.accent => hex_colour(accent),
        p.green => hex_colour(green), p.red => hex_colour(red), p.amber => hex_colour(amber),
        p.halo => hex_colour(t.ribbon), p.white => hex_colour(white),
        p.brand => hex_colour(t.brand))
end

"""
    IconAtlas

Every icon in every style at the sizes of `ICON_STYLE_SIZES`, for one theme and one scale,
packed into one straight RGBA image. `upload!` makes it an OpenGL texture.

- `names`: icon names, sorted; `index` maps a name to its position.
- `rects[style, size, icon]`: `(x, y, w, h)` in pixels, `w == h == px(scale, size)`;
  `size` indexes `ICON_SIZES`. A size the style does not hold is all zeros.
- `pixels`: RGBA bytes, rows from the top. Emptied by `upload!`.
- `texture`: the OpenGL texture, or 0.
"""
mutable struct IconAtlas
    tokens::Tokens
    scale::Float32
    names::Vector{String}
    index::Dict{String,Int}
    width::Int
    height::Int
    rects::Array{NTuple{4,Int32},3}
    pixels::Vector{UInt8}
    texture::UInt32
end

const ICON_ATLAS_WIDTH = 4096
const ICON_GAP = 1   # empty pixels around each icon, so linear filtering takes nothing from a neighbour

# Place every icon cell in rows, biggest size first. Returns the rects and the atlas height.
function pack_icons(n_icons::Int, scale::Float32)
    rects = fill(NTuple{4,Int32}((0, 0, 0, 0)), length(ICON_STYLES), length(ICON_SIZES), n_icons)
    x = y = row_h = 0
    for k in reverse(eachindex(ICON_SIZES))
        d = Int(px(scale, ICON_SIZES[k]))
        cell = d + ICON_GAP
        for s in eachindex(ICON_STYLES), i in 1:n_icons
            ICON_SIZES[k] in ICON_STYLE_SIZES[s] || continue
            if x + cell > ICON_ATLAS_WIDTH
                x = 0
                y += row_h
                row_h = 0
            end
            rects[s, k, i] = (x, y, d, d)
            x += cell
            row_h = max(row_h, cell)
        end
    end
    return rects, y + row_h
end

"""
    build_icon_atlas(tokens, scale) -> IconAtlas

Draw every icon with Rsvg and Cairo. Needs no window; `upload!` makes the texture.
"""
function build_icon_atlas(tokens::Tokens, scale::Real)::IconAtlas
    scale = Float32(scale)
    svgs = icon_svgs()
    names = first.(svgs)
    rects, height = pack_icons(length(svgs), scale)
    argb = zeros(UInt32, ICON_ATLAS_WIDTH, height)   # argb[x, y], premultiplied
    surface = Cairo.CairoImageSurface(argb, Cairo.FORMAT_ARGB32; flipxy = false)
    cr = Cairo.CairoContext(surface)
    try
        for (s, style) in enumerate(ICON_STYLES)
            colours = style_colours(tokens, style)
            for (i, (name, svg)) in enumerate(svgs)
                handle = svg_handle(replace(svg, colours...))
                try
                    for k in eachindex(ICON_SIZES)
                        x, y, d, _ = rects[s, k, i]
                        d == 0 && continue
                        Cairo.save(cr)
                        Cairo.translate(cr, x, y)
                        Cairo.rectangle(cr, 0, 0, d, d)
                        Cairo.clip(cr)
                        Cairo.scale(cr, d / 24, d / 24)
                        Rsvg.handle_render_cairo(cr, handle) ||
                            error("Rsvg could not draw the icon $name")
                        Cairo.restore(cr)
                    end
                finally
                    Rsvg.destroy(handle)
                end
            end
        end
        Cairo.flush(surface)
    finally
        Cairo.destroy(cr)
        Cairo.destroy(surface)
    end
    pixels = straight_rgba(argb)
    index = Dict(n => i for (i, n) in enumerate(names))
    return IconAtlas(tokens, scale, names, index, ICON_ATLAS_WIDTH, height, rects, pixels, 0)
end

# An Rsvg handle for SVG text. `Rsvg.handle_new_from_data` leaks its input stream,
# so this calls librsvg directly. `Rsvg.destroy` frees the handle.
function svg_handle(svg::String)::Rsvg.RsvgHandle
    err = Ref{Ptr{Rsvg.GError}}(C_NULL)
    ptr = GC.@preserve svg ccall((:rsvg_handle_new_from_data, Rsvg.librsvg), Ptr{Cvoid},
        (Ptr{UInt8}, Csize_t, Ptr{Ptr{Rsvg.GError}}), svg, sizeof(svg), err)
    if ptr == C_NULL
        msg = err[] == C_NULL ? "no reason given" : unsafe_string(unsafe_load(err[]).message)
        err[] == C_NULL || ccall((:g_error_free, Rsvg.libglib), Cvoid, (Ptr{Rsvg.GError},), err[])
        error("Rsvg could not read an SVG icon: $msg")
    end
    return Rsvg.RsvgHandle(ptr)
end

# Cairo's premultiplied ARGB words to straight RGBA bytes, in the same pixel order.
function straight_rgba(argb::Matrix{UInt32})::Vector{UInt8}
    out = Vector{UInt8}(undef, 4 * length(argb))
    @inbounds for j in eachindex(argb)
        p = argb[j]
        a = p >> 24
        o = 4 * (j - 1)
        if a == 0
            out[o+1] = out[o+2] = out[o+3] = out[o+4] = 0x00
        else
            out[o+1] = unpremultiply((p >> 16) & 0xff, a)
            out[o+2] = unpremultiply((p >> 8) & 0xff, a)
            out[o+3] = unpremultiply(p & 0xff, a)
            out[o+4] = a % UInt8
        end
    end
    return out
end

unpremultiply(c::UInt32, a::UInt32)::UInt8 = min((c * 255 + a ÷ 2) ÷ a, 0xff) % UInt8

"""
    upload!(atlas) -> Bool

Make the atlas an OpenGL texture of the current context and drop the CPU copy.
Returns false, with an `@error`, when the card does not take it; the atlas then has no texture.
"""
function upload!(atlas::IconAtlas)::Bool
    max_size = Ref{GL.GLint}(0)
    GL.glGetIntegerv(GL.GL_MAX_TEXTURE_SIZE, max_size)
    if max(atlas.width, atlas.height) > max_size[]
        @error "The icon atlas is $(atlas.width) by $(atlas.height) pixels at scale " *
               "$(atlas.scale); this graphics card allows at most $(max_size[]). Icons are not drawn."
        return false
    end
    while GL.glGetError() != GL.GL_NO_ERROR   # clear errors from earlier calls
    end
    id = Ref{GL.GLuint}(0)
    GL.glGenTextures(1, id)
    GL.glBindTexture(GL.GL_TEXTURE_2D, id[])
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_S, GL.GL_CLAMP_TO_EDGE)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_T, GL.GL_CLAMP_TO_EDGE)
    GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 1)
    GL.glPixelStorei(GL.GL_UNPACK_ROW_LENGTH, 0)
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, atlas.width, atlas.height, 0,
        GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, atlas.pixels)
    GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
    err = GL.glGetError()
    if err != GL.GL_NO_ERROR
        GL.glDeleteTextures(1, id)
        @error "Could not upload the icon atlas ($(atlas.width) by $(atlas.height) pixels): " *
               "OpenGL error 0x$(string(err; base = 16)). Icons are not drawn."
        return false
    end
    atlas.texture = id[]
    atlas.pixels = UInt8[]
    return true
end

"""
    free!(atlas)

Delete the atlas texture. The OpenGL context must be current.
"""
function free!(atlas::IconAtlas)
    if atlas.texture != 0
        GL.glDeleteTextures(1, Ref{GL.GLuint}(atlas.texture))
        atlas.texture = 0
    end
    return nothing
end

# The icon atlas of each ImGui context. Only the render thread uses it.
const ICON_ATLASES = Dict{Ptr{ig.lib.ImGuiContext},IconAtlas}()

# The theme and scale of the last build that failed, per context, so it is not tried each frame.
const ICON_FAILURES = Dict{Ptr{ig.lib.ImGuiContext},Tuple{Tokens,Float32}}()

"""
    update_icons!(w)

Build the icon atlas of the window when it has none, or when the theme or scale changed.
The loop calls it before each frame. The new atlas is uploaded before the old one is freed,
so there is always a texture to draw with.
When the build fails, it logs an `@error`, keeps the old atlas and does not try again until
the theme or scale changes. It never throws.
"""
function update_icons!(w)
    atlas = get(ICON_ATLASES, w.ctx, nothing)
    if atlas !== nothing && atlas.tokens == w.tokens && atlas.scale == w.scale
        delete!(ICON_FAILURES, w.ctx)   # back to a working theme: a later change tries again
        return nothing
    end
    get(ICON_FAILURES, w.ctx, nothing) == (w.tokens, w.scale) && return nothing
    new = try
        a = build_icon_atlas(w.tokens, w.scale)
        upload!(a) ? a : nothing
    catch e
        @error "Could not build the icon atlas" exception = (e, catch_backtrace())
        nothing
    end
    if new === nothing
        ICON_FAILURES[w.ctx] = (w.tokens, w.scale)
        return nothing
    end
    delete!(ICON_FAILURES, w.ctx)
    ICON_ATLASES[w.ctx] = new
    atlas === nothing || free!(atlas)
    return nothing
end

"""
    forget_icons!(ctx)

Delete the icon texture of an ImGui context. Called when the window closes.
"""
function forget_icons!(ctx::Ptr{ig.lib.ImGuiContext})
    delete!(ICON_FAILURES, ctx)
    atlas = pop!(ICON_ATLASES, ctx, nothing)
    atlas === nothing || free!(atlas)
    return nothing
end

# The position of an icon name in the atlas, after aliases and the fallback.
function icon_index(atlas::IconAtlas, name::AbstractString)::Int
    i = get(atlas.index, get(ICON_ALIASES, name, name), 0)
    i == 0 || return i
    return atlas.index[ICON_ALIASES[FALLBACK_ICON]]
end

# The atlas size to draw a `size` icon of style `s` from, as an index of `ICON_SIZES`:
# that size, else the next bigger of the style, else the style's biggest.
function icon_size_index(s::Int, size::Integer)::Int
    sizes = ICON_STYLE_SIZES[s]
    j = findfirst(>=(size), sizes)
    return findfirst(==(sizes[j === nothing ? lastindex(sizes) : j]), ICON_SIZES)::Int
end

"""
    draw_icon(dl, name, pos, size; style = :normal, alpha = 1)

Draw icon `name` at `pos` (device pixels, top left) on the draw list `dl`,
`size` logical pixels wide. See `ICON_STYLES` for `style`. `alpha` fades it (toasts).
An unknown name draws the icon `tool`. A size the style does not hold (see
`ICON_STYLE_SIZES`) is drawn scaled from the next bigger one.
Without an icon atlas (its upload failed) it draws nothing.
"""
function draw_icon(dl, name::AbstractString, pos, size::Integer; style::Symbol = :normal,
        alpha::Real = 1)
    s = findfirst(==(style), ICON_STYLES)
    s === nothing && throw(ArgumentError("icon style must be one of $(ICON_STYLES), got :$style"))
    atlas = get(ICON_ATLASES, ig.GetCurrentContext(), nothing)
    atlas === nothing && return nothing
    x, y, w, h = atlas.rects[s, icon_size_index(s, size), icon_index(atlas, name)]
    d = px(atlas.scale, size)
    p = pos isa ig.ImVec2 ? (pos.x, pos.y) : pos
    x0, y0 = round(Float32(p[1])), round(Float32(p[2]))
    tex = ig.ImTextureRef(ig.ImTextureID(atlas.texture))
    ig.AddImage(dl, tex, (x0, y0), (x0 + d, y0 + d),
        (x / atlas.width, y / atlas.height), ((x + w) / atlas.width, (y + h) / atlas.height),
        0x00ffffff | (round(UInt32, 255 * clamp(Float32(alpha), 0f0, 1f0)) << 24))
    return nothing
end
