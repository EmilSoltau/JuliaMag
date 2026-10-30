using Test
import Rsvg
using JuliaMagUI: icon_for, ICON_DIR, ICON_SIZES, ICON_STYLES, ICON_PLACEHOLDERS, LIGHT, DARK,
    build_icon_atlas, px, CORE_ICONS, ICON_STYLE_SIZES, icon_size_index
import JuliaMagCore as JMCore

include(joinpath(@__DIR__, "..", "tools", "extract_icons.jl"))

const PROTOTYPE_HTML = joinpath(@__DIR__, "..", "..", "prototype", "juliamag-ui.html")

@testset "icons" begin
    @testset "SVG files" begin
        files = filter(f -> endswith(f, ".svg"), readdir(ICON_DIR))
        icons, _ = ExtractIcons.read_icons(read(PROTOTYPE_HTML, String))
        @test length(files) == length(icons) + 1   # every icon and the logo
        @test "logo.svg" in files
        @test sort(first.(icons)) == sort(first.(splitext.(filter(!=("logo.svg"), files))))
        for f in files
            svg = read(joinpath(ICON_DIR, f), String)
            @test occursin("viewBox=\"0 0 24 24\"", svg)
            handle = Rsvg.handle_new_from_data(svg)
            d = Rsvg.handle_get_dimensions(handle)
            @test (d.width, d.height) == (24, 24)
            Rsvg.destroy(handle)
        end
        # The extractor's placeholders are the ones the atlas swaps.
        @test ExtractIcons.PLACEHOLDERS == ICON_PLACEHOLDERS
        # The committed files are what the extractor writes now.
        mktempdir() do dir
            ExtractIcons.extract(PROTOTYPE_HTML, dir)
            @test sort(readdir(dir)) == sort(files)
            @test all(read(joinpath(dir, f), String) == read(joinpath(ICON_DIR, f), String)
                      for f in files)
        end
    end

    @testset "icon_for" begin
        @test icon_for("math") == "math"
        @test icon_for("unknown-word") == "tool"
        # Every icon word and importer and exporter id of the core has a known icon.
        names = Set(first.(splitext.(readdir(ICON_DIR))))
        words = [[t.icon for t in JMCore.tools()]; [i.id for i in JMCore.importers()];
                 [e.id for e in JMCore.exporters()]]
        for w in words
            @test haskey(CORE_ICONS, w)
        end
        @test all(in(names), values(CORE_ICONS))
    end

    @testset "atlas" begin
        for scale in (1f0, 1.5f0)
            a = build_icon_atlas(LIGHT, scale)
            @test length(a.pixels) == 4 * a.width * a.height
            @test size(a.rects) == (length(ICON_STYLES), length(ICON_SIZES), length(a.names))
            # Each cell is the scaled size, and no two cells overlap.
            for k in eachindex(ICON_SIZES)
                @test all(r -> r[3] == 0 || r[3] == r[4] == px(scale, ICON_SIZES[k]),
                    a.rects[:, k, :])
            end
            cells = filter(r -> r[3] > 0, vec(a.rects))
            @test all(r -> r[1] + r[3] <= a.width && r[2] + r[4] <= a.height, cells)
            used = falses(a.width, a.height)
            overlaps = 0
            for (x, y, w, h) in cells
                area = view(used, x+1:x+w, y+1:y+h)
                overlaps += count(area)
                area .= true
            end
            @test overlaps == 0
        end

        # At scale 4 the atlas still fits in an 8192 px texture.
        a4 = build_icon_atlas(LIGHT, 4f0)
        @test a4.height <= 8192 && a4.width <= 8192
        # Only the sizes each style uses are drawn; the others are empty.
        for (s, sizes) in enumerate(ICON_STYLE_SIZES), (k, size) in enumerate(ICON_SIZES)
            @test all(r -> (r[3] > 0) == (size in sizes), a4.rects[s, k, :])
        end
        # A size a style does not hold comes from its next bigger size, else its biggest.
        normal, disabled, nav, on_accent, dim = 1, 2, 3, 4, 5
        @test ICON_SIZES[icon_size_index(normal, 20)] == 22
        @test ICON_SIZES[icon_size_index(normal, 64)] == 48
        @test ICON_SIZES[icon_size_index(disabled, 10)] == 16
        @test ICON_SIZES[icon_size_index(nav, 22)] == 48
        @test ICON_SIZES[icon_size_index(on_accent, 32)] == 22
        @test ICON_SIZES[icon_size_index(dim, 18)] == 16
        @test ICON_SIZES[icon_size_index(dim, 16)] == 16   # the ribbon scroll arrows
        @test ICON_SIZES[icon_size_index(normal, 24)] == 24   # the header logo

        # The biggest database icon of each style: ink, the accent fill at 22 %, straight alpha.
        a = build_icon_atlas(DARK, 1f0)
        db = a.index["database"]
        colours(style) = begin
            s = findfirst(==(style), ICON_STYLES)
            x, y, d, _ = a.rects[s, icon_size_index(s, 48), db]
            Set((a.pixels[4*((y+j)*a.width+x+i)+1], a.pixels[4*((y+j)*a.width+x+i)+2],
                 a.pixels[4*((y+j)*a.width+x+i)+3], a.pixels[4*((y+j)*a.width+x+i)+4])
                for j in 0:d-1, i in 0:d-1)
        end
        byte(c) = round(Int, c * 255)
        # Straight colours from premultiplied ones lose precision at low alpha.
        near(p, c, alpha) = abs(Int(p[4]) - byte(alpha)) <= 1 &&
                            all(abs(Int(p[i]) - byte(c[i])) <= 4 for i in 1:3)
        has(set, c, alpha) = any(p -> near(p, c, alpha), set)
        normal = colours(:normal)
        @test has(normal, DARK.icon, 1)
        @test has(normal, DARK.accent, 0.22)
        disabled = colours(:disabled)
        @test has(disabled, DARK.text_disabled, 1)
        @test all(p -> p[4] < 64 || near(p, DARK.text_disabled, p[4] / 255), disabled)
        nav = colours(:nav)
        @test has(nav, DARK.on_accent, 1)
        @test has(nav, DARK.brand_tint, 0.22)
        # At 14 px the 1.6 strokes are thinner than a pixel: look at the colour, any strong alpha.
        dimmed = colours(:dim)
        ink(set, c) = any(p -> p[4] > 128 && all(abs(Int(p[i]) - byte(c[i])) <= 4 for i in 1:3), set)
        @test ink(dimmed, DARK.text_dim) && !ink(dimmed, DARK.icon)
    end
end
