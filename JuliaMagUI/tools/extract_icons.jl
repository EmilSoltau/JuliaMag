# Extract the prototype's icons into SVG files.
#
# Usage, from the repo root:
#   julia JuliaMagUI/tools/extract_icons.jl
#
# It reads the `ICONS` table and the header `LOGO` of prototype/juliamag-ui.html
# and writes one JuliaMagUI/assets/icons/<name>.svg per icon.
# The SVG files are committed; run this again only when the prototype's icons change.
#
# The prototype styles its icons with CSS classes and variables (lines 56-67).
# Each SVG gets those styles as plain attributes, with placeholder colours in place of the
# variables. `src/theme/icons.jl` swaps the placeholders for theme colours when it draws.
# The placeholder table here must match `ICON_PLACEHOLDERS` there; a test checks it.

module ExtractIcons

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const PROTOTYPE = joinpath(ROOT, "prototype", "juliamag-ui.html")
const OUT_DIR = joinpath(ROOT, "JuliaMagUI", "assets", "icons")

# Placeholder colours, one per prototype colour variable.
const INK = "#000001"     # --ic, the ink (--icon)
const ACCENT = "#000002"  # --ica, the accent
const GREEN = "#000003"   # --icg
const RED = "#000004"     # --icr
const AMBER = "#000005"   # --icm
const HALO = "#000006"    # --halo, the ring behind a badge (--ribbon)
const WHITE = "#000007"   # #fff in the icons
const BRAND = "#000008"   # --brand, in the logo

const PLACEHOLDERS = (; ink = INK, accent = ACCENT, green = GREEN, red = RED, amber = AMBER,
    halo = HALO, white = WHITE, brand = BRAND)

# The `.ic` rule of the prototype, set on the <svg> element so children inherit it.
const ROOT_STYLE = ["fill" => "none", "stroke" => INK, "stroke-width" => "1.6",
    "stroke-linecap" => "round", "stroke-linejoin" => "round"]

# The `.ic .<class>` rules, in the order of the prototype's style sheet.
const CLASS_STYLES = [
    "a" => ["fill" => ACCENT, "stroke" => "none"],
    "at" => ["fill" => ACCENT, "fill-opacity" => "0.22"],
    "as" => ["stroke" => ACCENT],
    "g" => ["stroke" => GREEN],
    "gf" => ["fill" => GREEN, "stroke" => "none"],
    "r" => ["stroke" => RED],
    "rf" => ["fill" => RED, "stroke" => "none"],
    "am" => ["fill" => AMBER, "stroke" => "none"],
    "w" => ["stroke" => WHITE],
    "wf" => ["fill" => WHITE, "stroke" => "none"],
    "ink" => ["fill" => INK, "stroke" => "none"],
]

# CSS values that name a variable or white, and their placeholders.
const VALUE_MAP = Dict(
    "var(--halo,var(--ribbon))" => HALO,
    "var(--brand)" => BRAND,
    "#fff" => WHITE,
)

# ---------------------------------------------------------------------------------------
# A small reader for the JavaScript that builds the icons:
# `const NAME = expr;` and `const ICONS = { key: expr, ... };`, where an expression joins
# 'strings' and constant names with `+`, and may call `.replace('a', 'b')` on a name.

struct Reader
    s::String
    pos::Base.RefValue{Int}
end
Reader(s::AbstractString) = Reader(String(s), Ref(1))

function skip_space(r::Reader)
    while r.pos[] <= ncodeunits(r.s) && isspace(r.s[r.pos[]])
        r.pos[] = nextind(r.s, r.pos[])
    end
end

function peek(r::Reader)::Char
    skip_space(r)
    return r.pos[] <= ncodeunits(r.s) ? r.s[r.pos[]] : '\0'
end

function expect(r::Reader, c::Char)
    peek(r) == c || error("expected '$c' at $(context(r))")
    r.pos[] += 1
end

context(r::Reader) = repr(r.s[r.pos[]:min(end, r.pos[] + 40)])

function read_name(r::Reader)::String
    skip_space(r)
    m = match(r"[A-Za-z_][A-Za-z0-9_]*", r.s, r.pos[])
    (m === nothing || m.offset != r.pos[]) && error("expected a name at $(context(r))")
    r.pos[] += ncodeunits(m.match)
    return m.match
end

function read_string(r::Reader)::String
    expect(r, '\'')
    stop = findnext('\'', r.s, r.pos[])
    stop === nothing && error("unterminated string")
    text = r.s[r.pos[]:prevind(r.s, stop)]
    occursin('\\', text) && error("escapes in strings are not supported: $text")
    r.pos[] = stop + 1
    return text
end

function read_term(r::Reader, consts::Dict{String,String})::String
    if peek(r) == '\''
        return read_string(r)
    end
    name = read_name(r)
    haskey(consts, name) || error("unknown constant $name")
    value = consts[name]
    if peek(r) == '.'
        r.pos[] += 1
        read_name(r) == "replace" || error("only .replace is supported, at $(context(r))")
        expect(r, '(')
        from = read_string(r)
        expect(r, ',')
        to = read_string(r)
        expect(r, ')')
        value = replace(value, from => to; count = 1)   # JS replace with a string: first only
    end
    return value
end

function read_expr(r::Reader, consts::Dict{String,String})::String
    value = read_term(r, consts)
    while peek(r) == '+'
        r.pos[] += 1
        value *= read_term(r, consts)
    end
    return value
end

"""
    read_icons(html) -> (icons::Vector{Pair{String,String}}, logo::String)

The prototype's icons in table order, as SVG inner markup, and the logo SVG.
"""
function read_icons(html::AbstractString)
    start = findfirst("const PLUS_BADGE", html)
    stop = findfirst("function icon(", html)
    (start === nothing || stop === nothing) && error("the icon table was not found")
    r = Reader(html[first(start):prevind(html, first(stop))])
    consts = Dict{String,String}()
    icons = Pair{String,String}[]
    while peek(r) != '\0'
        read_name(r) == "const" || error("expected const at $(context(r))")
        name = read_name(r)
        expect(r, '=')
        if name == "ICONS"
            expect(r, '{')
            while peek(r) != '}'
                key = read_name(r)
                expect(r, ':')
                push!(icons, key => read_expr(r, consts))
                peek(r) == ',' && (r.pos[] += 1)
            end
            expect(r, '}')
        else
            consts[name] = read_expr(r, consts)
        end
        expect(r, ';')
    end
    m = match(r"const LOGO = '([^']*)';", html)
    m === nothing && error("the logo was not found")
    return icons, String(m.captures[1])
end

# ---------------------------------------------------------------------------------------
# Markup to SVG with plain attributes.

const ELEMENT = r"<([a-z]+)((?:\s+[a-z-]+=\"[^\"]*\")*)\s*/>"
const ATTRIBUTE = r"([a-z-]+)=\"([^\"]*)\""

function parse_elements(markup::AbstractString)
    elements = Tuple{String,Vector{Pair{String,String}}}[]
    pos = 1
    for m in eachmatch(ELEMENT, markup)
        strip(markup[pos:prevind(markup, m.offset)]) == "" ||
            error("unexpected markup before $(m.match)")
        attrs = [String(a[1]) => String(a[2]) for a in eachmatch(ATTRIBUTE, m.captures[2])]
        push!(elements, (String(m.captures[1]), attrs))
        pos = m.offset + ncodeunits(m.match)
    end
    strip(markup[pos:end]) == "" || error("unexpected markup at the end: $(markup[pos:end])")
    return elements
end

map_value(v::AbstractString) = get(VALUE_MAP, replace(v, " " => ""), String(v))

function set!(attrs::Vector{Pair{String,String}}, key::String, value::String)
    i = findfirst(p -> first(p) == key, attrs)
    i === nothing ? push!(attrs, key => value) : (attrs[i] = key => value)
    return attrs
end

# The attributes an element ends up with: its own, then its class rules, then its style.
# This is the CSS order: class rules beat presentation attributes, style beats both.
function resolve(attrs::Vector{Pair{String,String}}; classes_known = true)
    out = Pair{String,String}[]
    classes = String[]
    style = ""
    for (k, v) in attrs
        if k == "class"
            append!(classes, split(v))
        elseif k == "style"
            style = v
        else
            push!(out, k => map_value(v))
        end
    end
    for (cls, props) in CLASS_STYLES
        cls in classes || continue
        for (k, v) in props
            set!(out, k, v)
        end
    end
    if classes_known
        unknown = setdiff(classes, first.(CLASS_STYLES))
        isempty(unknown) || error("unknown icon classes: $(join(unknown, ", "))")
    end
    for decl in split(style, ';'; keepempty = false)
        k, v = strip.(split(decl, ':'; limit = 2))
        set!(out, String(k), map_value(v))
    end
    return out
end

function element_svg(tag, attrs)
    return "  <" * tag * join(" $k=\"$v\"" for (k, v) in attrs) * "/>\n"
end

function icon_svg(markup::AbstractString)::String
    head = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" " *
           "viewBox=\"0 0 24 24\"" * join(" $k=\"$v\"" for (k, v) in ROOT_STYLE) * ">\n"
    body = join(element_svg(tag, resolve(attrs)) for (tag, attrs) in parse_elements(markup))
    return head * body * "</svg>\n"
end

function logo_svg(logo::AbstractString)::String
    m = match(r"^<svg[^>]*>(.*)</svg>$", logo)
    m === nothing && error("the logo is not one <svg> element")
    head = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\">\n"
    body = join(element_svg(tag, resolve(attrs; classes_known = false))
                for (tag, attrs) in parse_elements(m.captures[1]))
    return head * body * "</svg>\n"
end

"""
    extract(html_path = PROTOTYPE, out_dir = OUT_DIR) -> Vector{String}

Write every icon and the logo as SVG files. Returns the names written.
"""
function extract(html_path::AbstractString = PROTOTYPE, out_dir::AbstractString = OUT_DIR)
    icons, logo = read_icons(read(html_path, String))
    allunique(first.(icons)) || error("the icon table has a name twice")
    "logo" in first.(icons) && error("an icon is called logo")
    mkpath(out_dir)
    for f in readdir(out_dir)
        endswith(f, ".svg") && rm(joinpath(out_dir, f))
    end
    for (name, markup) in icons
        write(joinpath(out_dir, name * ".svg"), icon_svg(markup))
    end
    write(joinpath(out_dir, "logo.svg"), logo_svg(logo))
    return [first.(icons); "logo"]
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    names = ExtractIcons.extract()
    println("Wrote $(length(names)) SVG files to $(ExtractIcons.OUT_DIR)")
end
