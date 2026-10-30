using Test
using JuliaMagUI: Tokens, LIGHT, DARK, hex_rgba, tokens_for, RENDERED_TOKENS,
    THEME_LIGHT, THEME_DARK, THEME_SYSTEM

# Read every `--name: value;` pair of one CSS block into a Dict.
function css_tokens(block::AbstractString)
    out = Dict{Symbol,String}()
    for m in eachmatch(r"--([a-z-]+):\s*([^;]+);", block)
        out[Symbol(replace(m[1], '-' => '_'))] = strip(m[2])
    end
    return out
end

# The value of a prototype token as straight RGBA.
function css_rgba(v::AbstractString)
    m = match(r"^rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)$", v)
    m === nothing && return hex_rgba(v)
    return (parse(Float32, m[1]) / 255f0, parse(Float32, m[2]) / 255f0,
        parse(Float32, m[3]) / 255f0, parse(Float32, m[4]))
end

@testset "tokens" begin
    @testset "values" begin
        @test LIGHT.accent == hex_rgba("#2563EB") && DARK.accent == hex_rgba("#5B8DF6")
        @test LIGHT.brand == hex_rgba("#7D4A9B") && DARK.brand == LIGHT.brand
        @test LIGHT.shadow == (0f0, 0f0, 0f0, 0.11f0) && DARK.backdrop == (0f0, 0f0, 0f0, 0.45f0)
        @test DARK.brand_tint == hex_rgba("#FFD36E")
        @test fieldcount(Tokens) == 37
        # Measured from the prototype's render (Chromium's text selection), not its CSS.
        @test RENDERED_TOKENS == (:text_selection,)
        @test LIGHT.text_selection == hex_rgba("#3367D1") && DARK.text_selection == hex_rgba("#0439A4")
        @test hex_rgba("#FF0000") == (1f0, 0f0, 0f0, 1f0)
        @test_throws ArgumentError hex_rgba("red")
    end

    @testset "same as the prototype" begin
        html = read(joinpath(@__DIR__, "..", "..", "prototype", "juliamag-ui.html"), String)
        light_block = match(r":root \{(.*?)\n\}"s, html)[1]
        dark_block = match(r":root\[data-theme=\"dark\"\] \{(.*?)\n\}"s, html)[1]
        light = css_tokens(light_block)
        dark = merge(light, css_tokens(dark_block))   # dark inherits what it does not set
        names = filter(n -> !(n in RENDERED_TOKENS), fieldnames(Tokens))
        for (tokens, css) in ((LIGHT, light), (DARK, dark)), name in names
            @test haskey(css, name)
            @test getfield(tokens, name) == css_rgba(css[name])
        end
        # Every colour token of the prototype is a field. Layout and font vars are not colours.
        colours = filter(k -> !(k in (:font, :mono, :left_w, :right_w)), collect(keys(light)))
        @test sort(colours) == sort(collect(names))
    end

    @testset "tokens_for" begin
        @test tokens_for(THEME_LIGHT, true) === LIGHT
        @test tokens_for(THEME_DARK, false) === DARK
        @test tokens_for(THEME_SYSTEM, true) === DARK
        @test tokens_for(THEME_SYSTEM, false) === LIGHT
    end
end
