# Throwaway spike for plan 4a (map view). Run headless only:
#   xvfb-run -a -s "-screen 0 1920x1080x24" env -u WAYLAND_DISPLAY julia -t 8,1 --project=../hl/env spike.jl
# Reads the data made by gen.jl through JuliaMagCore, draws lines (VBOs, GL_LINE_STRIP via
# glMultiDrawArrays) and a tiled R32F grid (colour LUT + histeq LUT + hillshade shader) into an
# FBO shown with ig.Image, and times scenarios while panning.
using JuliaMagCore, Printf, Statistics
import CImGui as ig
import CImGui.lib as lib
import GLFW
import ModernGL as GL
import PNGFiles

const DATA = joinpath(@__DIR__, "data")
const OUT = joinpath(@__DIR__, "out")
mkpath(OUT)
const LOG = open(joinpath(OUT, get(ENV, "RES", "results.txt")), "w")
say(args...) = (s = string(args...); println(s); println(LOG, s); flush(LOG); flush(stdout))
ms(t) = @sprintf("%.2f ms", 1000t)

# ---------------------------------------------------------------- CPU side ("worker")

struct LineSet
    origin::NTuple{2,Float64}
    xy::Vector{Float32}          # x1,y1,x2,y2,... relative to origin
    val::Vector{Float32}
    first::Vector{Int32}         # first vertex of each line (from 0)
    count::Vector{Int32}
    bbox::Vector{NTuple{4,Float32}}
end

"Read X, Y, MAG of every line with read_channel (mmap views) into one packed Float32 set."
function read_lines(folder)
    db = open_database(folder)
    n = total_rows(db)
    xy = Vector{Float32}(undef, 2n); val = Vector{Float32}(undef, n)
    first = Int32[]; count = Int32[]; bbox = NTuple{4,Float32}[]
    l1 = db.lines[1]
    ox = floor(read_channel(db, l1.id, "X")[1]); oy = floor(read_channel(db, l1.id, "Y")[1])
    k = 0
    for l in db.lines
        x = read_channel(db, l.id, "X"); y = read_channel(db, l.id, "Y"); m = read_channel(db, l.id, "MAG")
        push!(first, k)
        push!(bbox, pack!(xy, val, k, x, y, m, ox, oy))   # function barrier: read_channel returns AbstractArray
        k += length(x)
        push!(count, length(x))
    end
    return LineSet((ox, oy), xy, val, first, count, bbox)
end

function pack!(xy, val, k, x, y, m, ox, oy)
    x0 = y0 = Inf32; x1 = y1 = -Inf32
    @inbounds for i in eachindex(x)
        a = Float32(x[i] - ox); b = Float32(y[i] - oy)
        xy[2k+1] = a; xy[2k+2] = b; val[k+1] = m[i]
        x0 = min(x0, a); x1 = max(x1, a); y0 = min(y0, b); y1 = max(y1, b)
        k += 1
    end
    return (x0, y0, x1, y1)
end

"One LOD level: per bucket of `b` points keep the points with the min and max value, in order (and the line ends)."
function decimate(ls::LineSet, b::Int)
    xy = Float32[]; val = Float32[]; first = Int32[]; count = Int32[]
    sizehint!(xy, 2 * (2 * length(ls.val) ÷ b + 4 * length(ls.first))); sizehint!(val, length(xy) ÷ 2)
    for (f, c) in zip(ls.first, ls.count)
        push!(first, length(val))
        put(i) = (push!(xy, ls.xy[2i+1], ls.xy[2i+2]); push!(val, ls.val[i+1]))
        put(f)
        s = f + 1
        while s < f + c - 1
            e = min(s + b - 1, f + c - 2)
            imin = imax = s
            @inbounds for i in s:e
                ls.val[i+1] < ls.val[imin+1] && (imin = i)
                ls.val[i+1] > ls.val[imax+1] && (imax = i)
            end
            a, z = minmax(imin, imax)
            put(a); a != z && put(z)
            s = e + 1
        end
        put(f + c - 1)
        push!(count, length(val) - first[end])
    end
    return LineSet(ls.origin, xy, val, first, count, ls.bbox)
end

const TILE = 2048
const NLUT = 4096

"Read the grid tile by tile (band of rows with read_rows!), plus a NLUT-bin histogram for histeq."
function grid_tiles(g::Grid)
    nt = cld(g.nx, TILE), cld(g.ny, TILE)
    tiles = Dict{Tuple{Int,Int},Vector{Matrix{Float32}}}()
    hist = zeros(Int, NLUT)
    lo, hi = g.vmin, g.vmax
    t_read = t_tile = t_mip = 0.0
    for tj in 1:nt[2]
        # rows of this band plus one border row each side
        jj0 = max((tj - 1) * TILE, 1); j1 = min(tj * TILE + 1, g.ny)
        nrow = j1 - jj0 + 1
        t0 = time(); band = read_rows(g, jj0, nrow)::Matrix{Float32}; t_read += time() - t0
        t_tile += @elapsed cut_band!(tiles, hist, band, g, tj, jj0, nt, lo, hi)
    end
    # NaN-aware 2x2 mean mips on the CPU
    t_mip = @elapsed Threads.@threads for key in collect(keys(tiles))
        levels = tiles[key]
        while size(levels[end], 1) > 1
            A = levels[end]; n = max(1, size(A, 1) ÷ 2)   # GL mip sizes: floor(n/2)
            B = Matrix{Float32}(undef, n, n)
            @inbounds for c in 1:n, r in 1:n
                s = 0f0; k = 0
                for dc in 0:1, dr in 0:1
                    rr = min(2r - 1 + dr, size(A, 1)); cc = min(2c - 1 + dc, size(A, 2))
                    v = A[rr, cc]; isnan(v) || (s += v; k += 1)
                end
                B[r, c] = k == 0 ? NaN32 : s / k
            end
            push!(levels, B)
        end
    end
    cdf = Float32.(cumsum(hist) ./ sum(hist))
    return tiles, cdf, nt, (t_read, t_tile, t_mip)
end

function cut_band!(tiles, hist, band::Matrix{Float32}, g, tj, jj0, nt, lo, hi)
    for ti in 1:nt[1]
        T = fill(NaN32, TILE + 2, TILE + 2)
        i0 = (ti - 1) * TILE   # cell i0 is the left border
        @inbounds for c in 1:TILE+2, r in 1:TILE+2
            i = i0 + r - 1; j = (tj - 1) * TILE + c - 1
            (1 <= i <= g.nx && 1 <= j <= g.ny) || continue
            T[r, c] = band[i, j - jj0 + 1]
        end
        tiles[(ti, tj)] = [T]
    end
    # histogram of the band's own rows
    @inbounds for j in max((tj - 1) * TILE + 1, 1):min(tj * TILE, g.ny), i in 1:g.nx
        v = band[i, j - jj0 + 1]
        isnan(v) && continue
        hist[clamp(1 + floor(Int, (v - lo) / (hi - lo) * NLUT), 1, NLUT)] += 1
    end
    return nothing
end

"256-entry rainbow (Geosoft-like) colour table as RGBA8."
function rainbow_lut()
    stops = [(0.0, (0, 0, 160)), (0.17, (0, 120, 255)), (0.33, (0, 220, 220)), (0.5, (60, 220, 60)),
             (0.67, (250, 240, 0)), (0.83, (255, 110, 0)), (1.0, (230, 0, 160))]
    out = Vector{UInt8}(undef, 4 * 256)
    for k in 0:255
        t = k / 255
        s = findlast(s -> s[1] <= t, stops); s = min(s, length(stops) - 1)
        (t0, c0), (t1, c1) = stops[s], stops[s+1]
        f = (t - t0) / (t1 - t0)
        for ch in 1:3
            out[4k+ch] = round(UInt8, c0[ch] + f * (c1[ch] - c0[ch]))
        end
        out[4k+4] = 0xff
    end
    return out
end

# ---------------------------------------------------------------- GL helpers

function compile(src, typ)
    s = GL.glCreateShader(typ)
    GC.@preserve src GL.glShaderSource(s, 1, Ptr{GL.GLchar}[pointer(src)], C_NULL)
    GL.glCompileShader(s)
    ok = Ref{GL.GLint}(0); GL.glGetShaderiv(s, GL.GL_COMPILE_STATUS, ok)
    if ok[] == 0
        buf = zeros(UInt8, 4096); GL.glGetShaderInfoLog(s, 4096, C_NULL, buf)
        error("shader: " * String(buf[1:something(findfirst(==(0), buf), 4097)-1]))
    end
    return s
end

function program(vs, fs)
    p = GL.glCreateProgram()
    GL.glAttachShader(p, compile(vs, GL.GL_VERTEX_SHADER))
    GL.glAttachShader(p, compile(fs, GL.GL_FRAGMENT_SHADER))
    GL.glLinkProgram(p)
    ok = Ref{GL.GLint}(0); GL.glGetProgramiv(p, GL.GL_LINK_STATUS, ok)
    ok[] == 0 && error("link failed")
    return p
end

genbuf() = (r = Ref{GL.GLuint}(0); GL.glGenBuffers(1, r); r[])
gentex() = (r = Ref{GL.GLuint}(0); GL.glGenTextures(1, r); r[])
genvao() = (r = Ref{GL.GLuint}(0); GL.glGenVertexArrays(1, r); r[])
uloc(p, n) = GL.glGetUniformLocation(p, n)
getint(e) = (r = Ref{GL.GLint}(0); GL.glGetIntegerv(e, r); r[])

const LINE_VS = """
#version 330 core
layout(location=0) in vec2 pos;
layout(location=1) in float val;
uniform vec2 scale; uniform vec2 offset;
out float v;
void main(){ v = val; gl_Position = vec4(pos*scale + offset, 0.0, 1.0); }
"""
const LINE_FS = """
#version 330 core
in float v; uniform sampler2D lut; uniform vec2 range; out vec4 col;
void main(){ float t = clamp((v-range.x)/(range.y-range.x),0.0,1.0);
  col = texture(lut, vec2(t,0.5)); }
"""
const GRID_VS = """
#version 330 core
layout(location=0) in vec2 corner;      // 0..1 over the tile
uniform vec2 tile0; uniform vec2 tilesize;   // ground, relative to origin
uniform vec2 scale; uniform vec2 offset;
out vec2 cell;                           // cell coordinates inside the tile (0..TILE)
uniform float ncell;
void main(){ cell = corner*ncell; vec2 g = tile0 + corner*tilesize; gl_Position = vec4(g*scale+offset,0.0,1.0); }
"""
const GRID_FS = """
#version 330 core
in vec2 cell; out vec4 col;
uniform sampler2D vals; uniform sampler2D lut; uniform sampler2D cdf;
uniform vec2 range; uniform int histeq; uniform int shade; uniform float texn; // TILE+2
uniform vec3 light; uniform float zf; uniform float cellsize;
float sampleV(vec2 c, float lod){ return textureLod(vals, (c+1.0)/texn, lod).r; }
void main(){
  vec2 dx = dFdx(cell), dy = dFdy(cell);
  float rho = max(length(dx), length(dy));
  float lod = max(0.0, log2(rho));
  float v = sampleV(cell, lod);
  if (isnan(v)) discard;
  float t = clamp((v-range.x)/(range.y-range.x),0.0,1.0);
  if (histeq==1) t = texture(cdf, vec2(t,0.5)).r;
  vec3 c = texture(lut, vec2(t,0.5)).rgb;
  if (shade==1){
    float st = exp2(floor(lod));
    float e = sampleV(cell+vec2(st,0), lod), w = sampleV(cell-vec2(st,0), lod);
    float n = sampleV(cell+vec2(0,st), lod), s = sampleV(cell-vec2(0,st), lod);
    if (isnan(e)) e = v; if (isnan(w)) w = v; if (isnan(n)) n = v; if (isnan(s)) s = v;
    vec3 nrm = normalize(vec3(-(e-w)*zf/(2.0*st*cellsize), -(n-s)*zf/(2.0*st*cellsize), 1.0));
    float h = max(dot(nrm, light), 0.0);
    c *= 0.35 + 0.65*h;
  }
  col = vec4(c,1.0);
}
"""

# ---------------------------------------------------------------- GPU objects

mutable struct LineGPU
    vao::GL.GLuint; vbo_xy::GL.GLuint; vbo_v::GL.GLuint
    ls::LineSet
end

function upload_lines(ls::LineSet; chunk = 0)
    vao = genvao(); GL.glBindVertexArray(vao)
    b1 = genbuf(); b2 = genbuf()
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, b1)
    times = Float64[]
    if chunk == 0
        GL.glBufferData(GL.GL_ARRAY_BUFFER, sizeof(ls.xy), ls.xy, GL.GL_STATIC_DRAW)
    else
        GL.glBufferData(GL.GL_ARRAY_BUFFER, sizeof(ls.xy), C_NULL, GL.GL_STATIC_DRAW)
        nb = sizeof(ls.xy); off = 0
        while off < nb
            n = min(chunk, nb - off)
            t = @elapsed (GL.glBufferSubData(GL.GL_ARRAY_BUFFER, off, n, pointer(ls.xy) + off); GL.glFinish())
            push!(times, t); off += n
        end
    end
    GL.glVertexAttribPointer(0, 2, GL.GL_FLOAT, GL.GL_FALSE, 0, C_NULL); GL.glEnableVertexAttribArray(0)
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, b2)
    GL.glBufferData(GL.GL_ARRAY_BUFFER, sizeof(ls.val), ls.val, GL.GL_STATIC_DRAW)
    GL.glVertexAttribPointer(1, 1, GL.GL_FLOAT, GL.GL_FALSE, 0, C_NULL); GL.glEnableVertexAttribArray(1)
    GL.glBindVertexArray(0); GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0)
    return LineGPU(vao, b1, b2, ls), times
end

function tex2d(w, h, ifmt, fmt, typ, data; filt = GL.GL_LINEAR)
    t = gentex(); GL.glBindTexture(GL.GL_TEXTURE_2D, t)
    GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 1)
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, ifmt, w, h, 0, fmt, typ, data)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, filt)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_S, GL.GL_CLAMP_TO_EDGE)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_T, GL.GL_CLAMP_TO_EDGE)
    return t
end

function upload_tile(levels::Vector{Matrix{Float32}})
    A = levels[1]
    t = tex2d(size(A, 1), size(A, 2), GL.GL_R32F, GL.GL_RED, GL.GL_FLOAT, A; filt = GL.GL_LINEAR_MIPMAP_NEAREST)
    for (k, B) in enumerate(levels[2:end])
        GL.glTexImage2D(GL.GL_TEXTURE_2D, k, GL.GL_R32F, size(B, 1), size(B, 2), 0, GL.GL_RED, GL.GL_FLOAT, B)
    end
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAX_LEVEL, length(levels) - 1)
    return t
end

mutable struct Fbo
    fbo::GL.GLuint; tex::GL.GLuint; w::Int; h::Int
    msfbo::GL.GLuint; msrb::GL.GLuint; samples::Int
end

function ensure_fbo!(f::Union{Nothing,Fbo}, w, h, samples)
    f !== nothing && f.w == w && f.h == h && f.samples == samples && return f
    if f !== nothing
        GL.glDeleteFramebuffers(1, Ref(f.fbo)); GL.glDeleteTextures(1, Ref(f.tex))
        f.msfbo != 0 && (GL.glDeleteFramebuffers(1, Ref(f.msfbo)); GL.glDeleteRenderbuffers(1, Ref(f.msrb)))
    end
    tex = tex2d(w, h, GL.GL_RGBA8, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, C_NULL)
    r = Ref{GL.GLuint}(0); GL.glGenFramebuffers(1, r); fbo = r[]
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo)
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, tex, 0)
    msfbo = msrb = GL.GLuint(0)
    if samples > 1
        GL.glGenFramebuffers(1, r); msfbo = r[]
        GL.glGenRenderbuffers(1, r); msrb = r[]
        GL.glBindRenderbuffer(GL.GL_RENDERBUFFER, msrb)
        GL.glRenderbufferStorageMultisample(GL.GL_RENDERBUFFER, samples, GL.GL_RGBA8, w, h)
        GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, msfbo)
        GL.glFramebufferRenderbuffer(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_RENDERBUFFER, msrb)
    end
    st = GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER)
    st == GL.GL_FRAMEBUFFER_COMPLETE || error("FBO incomplete $st")
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0)
    return Fbo(fbo, tex, w, h, msfbo, msrb, samples)
end

# ---------------------------------------------------------------- scene

Base.@kwdef mutable struct View
    cx::Float64 = 50_000.0   # ground centre, relative to origin
    cy::Float64 = 50_000.0
    mpp::Float64 = 70.0      # metres per pixel
end

Base.@kwdef mutable struct Scene
    lines::Bool = true
    lod::Symbol = :full      # :full, :auto
    cull::Bool = true
    grid::Bool = false
    histeq::Bool = true
    shade::Bool = true
    samples::Int = 1
    imdraw::Int = 0          # >0: draw that many points with ImDrawList instead
    stream::Symbol = :none   # :tile, :lines - re-upload while drawing
    bg::Bool = false         # a worker thread reads + decimates all lines again and again meanwhile
end

mutable struct Ctx
    lprog::GL.GLuint; gprog::GL.GLuint
    lut::GL.GLuint; cdf::GL.GLuint
    levels::Vector{LineGPU}; bucket::Vector{Int}
    tiles::Dict{Tuple{Int,Int},GL.GLuint}; ntile::Tuple{Int,Int}
    quad::GL.GLuint
    grid::Grid; gorigin::NTuple{2,Float64}
    range::NTuple{2,Float32}
    fbo::Union{Nothing,Fbo}
    queries::Vector{GL.GLuint}; qframe::Int
    gpu_ms::Vector{Float64}
    drawn_pts::Int
    tiledata::Vector{Matrix{Float32}}
end

function draw_map!(c::Ctx, sc::Scene, v::View, w::Int, h::Int)
    c.fbo = ensure_fbo!(c.fbo, w, h, sc.samples)
    f = c.fbo
    q = c.queries[mod1(c.qframe, length(c.queries))]
    # read the query of 3 frames ago (no stall)
    if c.qframe > length(c.queries)
        res = Ref{GL.GLuint64}(0)
        GL.glGetQueryObjectui64v(q, GL.GL_QUERY_RESULT, res)
        push!(c.gpu_ms, res[] / 1e6)
    end
    GL.glBeginQuery(GL.GL_TIME_ELAPSED, q)
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, f.samples > 1 ? f.msfbo : f.fbo)
    GL.glViewport(0, 0, w, h)
    GL.glDisable(GL.GL_SCISSOR_TEST); GL.glDisable(GL.GL_BLEND); GL.glDisable(GL.GL_DEPTH_TEST)
    GL.glClearColor(0.12, 0.12, 0.14, 1); GL.glClear(GL.GL_COLOR_BUFFER_BIT)
    sx = 2 / (w * v.mpp); sy = 2 / (h * v.mpp)
    ox = -v.cx * sx; oy = -v.cy * sy
    # visible ground box
    gx0 = v.cx - w * v.mpp / 2; gx1 = v.cx + w * v.mpp / 2
    gy0 = v.cy - h * v.mpp / 2; gy1 = v.cy + h * v.mpp / 2
    if sc.grid
        g = c.grid
        GL.glUseProgram(c.gprog)
        p = c.gprog
        GL.glUniform2f(uloc(p, "scale"), sx, sy); GL.glUniform2f(uloc(p, "offset"), ox, oy)
        GL.glUniform2f(uloc(p, "range"), c.range...)
        GL.glUniform1i(uloc(p, "histeq"), sc.histeq); GL.glUniform1i(uloc(p, "shade"), sc.shade)
        GL.glUniform1f(uloc(p, "texn"), TILE + 2); GL.glUniform1f(uloc(p, "ncell"), TILE)
        az, alt = deg2rad(45), deg2rad(45)
        GL.glUniform3f(uloc(p, "light"), cos(alt) * sin(az), cos(alt) * cos(az), sin(alt))
        GL.glUniform1f(uloc(p, "zf"), 30f0); GL.glUniform1f(uloc(p, "cellsize"), g.dx)
        GL.glUniform1i(uloc(p, "vals"), 0); GL.glUniform1i(uloc(p, "lut"), 1); GL.glUniform1i(uloc(p, "cdf"), 2)
        GL.glActiveTexture(GL.GL_TEXTURE1); GL.glBindTexture(GL.GL_TEXTURE_2D, c.lut)
        GL.glActiveTexture(GL.GL_TEXTURE2); GL.glBindTexture(GL.GL_TEXTURE_2D, c.cdf)
        GL.glActiveTexture(GL.GL_TEXTURE0)
        GL.glBindVertexArray(c.quad)
        ts = TILE * g.dx
        for ((ti, tj), tex) in c.tiles
            # tile ground box: cell (i) centre at x0+(i-1)dx; tile edge at cell edge
            tx0 = g.x0 - g.dx / 2 - c.gorigin[1] + (ti - 1) * ts
            ty0 = g.y0 - g.dy / 2 - c.gorigin[2] + (tj - 1) * ts
            (tx0 > gx1 || tx0 + ts < gx0 || ty0 > gy1 || ty0 + ts < gy0) && continue
            GL.glUniform2f(uloc(p, "tile0"), tx0, ty0); GL.glUniform2f(uloc(p, "tilesize"), ts, ts)
            GL.glBindTexture(GL.GL_TEXTURE_2D, tex)
            GL.glDrawArrays(GL.GL_TRIANGLE_STRIP, 0, 4)
        end
    end
    c.drawn_pts = 0
    if sc.lines && sc.imdraw == 0
        # LOD: biggest bucket whose ground length (bucket * 10 m) is below 2 pixels
        k = 1
        if sc.lod == :auto
            for (i, b) in enumerate(c.bucket)
                b * 10.0 <= 2 * v.mpp && (k = i)
            end
        end
        L = c.levels[k]
        ls = L.ls
        firsts = Int32[]; counts = Int32[]
        for i in eachindex(ls.first)
            bb = ls.bbox[i]
            if sc.cull && (bb[1] > gx1 || bb[3] < gx0 || bb[2] > gy1 || bb[4] < gy0)
                continue
            end
            push!(firsts, ls.first[i]); push!(counts, ls.count[i])
        end
        c.drawn_pts = sum(counts; init = 0)
        p = c.lprog
        GL.glUseProgram(p)
        GL.glUniform2f(uloc(p, "scale"), sx, sy); GL.glUniform2f(uloc(p, "offset"), ox, oy)
        GL.glUniform2f(uloc(p, "range"), c.range...)
        GL.glUniform1i(uloc(p, "lut"), 0)
        GL.glActiveTexture(GL.GL_TEXTURE0); GL.glBindTexture(GL.GL_TEXTURE_2D, c.lut)
        GL.glBindVertexArray(L.vao)
        isempty(firsts) || GL.glMultiDrawArrays(GL.GL_LINE_STRIP, firsts, counts, length(firsts))
    end
    GL.glBindVertexArray(0); GL.glUseProgram(0)
    if f.samples > 1
        GL.glBindFramebuffer(GL.GL_READ_FRAMEBUFFER, f.msfbo); GL.glBindFramebuffer(GL.GL_DRAW_FRAMEBUFFER, f.fbo)
        GL.glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL.GL_COLOR_BUFFER_BIT, GL.GL_NEAREST)
    end
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0)
    GL.glEndQuery(GL.GL_TIME_ELAPSED)
    c.qframe += 1
    return f.tex
end

# ImDrawList option (c): AddPolyline per line, n points total from the full set
function imdraw_lines!(c::Ctx, v::View, n::Int, p0, w, h)
    dl = ig.GetWindowDrawList()
    ls = c.levels[1].ls
    left = n; i = 1
    pts = ig.ImVec2[]
    while left > 0 && i <= length(ls.first)
        f = ls.first[i]; m = min(ls.count[i], left)
        resize!(pts, m)
        for k in 0:m-1
            x = ls.xy[2(f+k)+1]; y = ls.xy[2(f+k)+2]
            pts[k+1] = ig.ImVec2(p0.x + w / 2 + (x - v.cx) / v.mpp, p0.y + h / 2 - (y - v.cy) / v.mpp)
        end
        GC.@preserve pts ig.AddPolyline(dl, Ptr{Cvoid}(pointer(pts)), m, 0xff40c0ff, 1f0, 0)
        left -= m; i += 1
    end
    c.drawn_pts = n - left
end

# ---------------------------------------------------------------- window and loop

function back_buffer_png(path, w, h)
    buf = Vector{UInt8}(undef, 4w * h)
    GL.glReadBuffer(GL.GL_BACK); GL.glPixelStorei(GL.GL_PACK_ALIGNMENT, 1)
    GL.glReadPixels(0, 0, w, h, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, buf)
    img = Array{UInt8}(undef, h, w, 3)
    for y in 1:h, x in 1:w, ch in 1:3
        img[y, x, ch] = buf[4((h - y) * w + x - 1)+ch]
    end
    PNGFiles.save(path, img)
end

function gpu_mem_kb()
    # GL_NVX_gpu_memory_info / GL_ATI_meminfo, when the driver has them
    ext = Set{String}()
    n = getint(GL.GL_NUM_EXTENSIONS)
    for i in 0:n-1
        push!(ext, unsafe_string(GL.glGetStringi(GL.GL_EXTENSIONS, i)))
    end
    if "GL_NVX_gpu_memory_info" in ext
        return getint(0x9049), "NVX current available"
    elseif "GL_ATI_meminfo" in ext
        r = zeros(GL.GLint, 4); GL.glGetIntegerv(0x87FC, r); return r[1], "ATI texture free"
    end
    return -1, "no memory info extension"
end

function main()
    t_all = time()
    # ---- CPU side, as the worker would do it
    say("== CPU side (would run on the worker) ==")
    say("threads: ", Threads.nthreads(), " (+", Threads.nthreads(:interactive), " interactive)")
    read_lines(joinpath(DATA, "db"))   # compile
    t = @elapsed ls = read_lines(joinpath(DATA, "db"))
    say("read 20M points X,Y,MAG (read_channel, mmap, warm page cache) + pack Float32 + bbox: ", ms(t),
        "  points=", length(ls.val), " lines=", length(ls.first))
    buckets = [1, 8, 64, 512]
    levels_cpu = LineSet[ls]
    for b in buckets[2:end]
        t = @elapsed push!(levels_cpu, decimate(ls, b))
        say(@sprintf("  LOD bucket %4d: %9d points (%.1f%%), build %s", b, length(levels_cpu[end].val),
            100length(levels_cpu[end].val) / length(ls.val), ms(t)))
    end
    g = open_grid(joinpath(DATA, "grid"))
    grid_tiles(g)   # compile (cheap enough)
    GC.gc()
    t = @elapsed tiles_cpu, cdf, nt, (tr, tt, tm) = grid_tiles(g)
    say("grid ", g.nx, "x", g.ny, " Float32: tiles ", nt, " total ", ms(t), " (read_rows ", ms(tr),
        ", cut tiles + histogram ", ms(tt), ", NaN-aware mips ", ms(tm), ")")
    vals = Float32[]
    lo, hi = Float32(g.vmin), Float32(g.vmax)

    # ---- window
    ig.set_backend(:GlfwOpenGL3)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3); GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 3)
    GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE); GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, true)
    W, H = 1600, 1000
    win = GLFW.CreateWindow(W, H, "spike4a")
    GLFW.MakeContextCurrent(win)
    GLFW.SwapInterval(0)
    ctx = ig.CreateContext()
    io = ig.GetIO(); io.IniFilename = C_NULL
    lib.ImGui_ImplGlfw_InitForOpenGL(Ptr{lib.GLFWwindow}(win.handle), true)
    lib.ImGui_ImplOpenGL3_Init("#version 330")
    say("\n== GL ==")
    say("GL_RENDERER: ", unsafe_string(GL.glGetString(GL.GL_RENDERER)))
    say("GL_VERSION: ", unsafe_string(GL.glGetString(GL.GL_VERSION)))
    say("GL_MAX_TEXTURE_SIZE: ", getint(GL.GL_MAX_TEXTURE_SIZE), "  GL_MAX_SAMPLES: ", getint(GL.GL_MAX_SAMPLES))
    lw = zeros(Float32, 2); GL.glGetFloatv(GL.GL_ALIASED_LINE_WIDTH_RANGE, lw)
    say("line width range: ", lw)
    m0 = gpu_mem_kb(); say("GPU memory info: ", m0)

    say("\n== uploads (each with glFinish) ==")
    lprog = program(LINE_VS, LINE_FS); gprog = program(GRID_VS, GRID_FS)
    lut = tex2d(256, 1, GL.GL_RGBA8, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, rainbow_lut())
    cdftex = tex2d(NLUT, 1, GL.GL_R32F, GL.GL_RED, GL.GL_FLOAT, cdf)
    gl_levels = LineGPU[]
    bytes_lines = 0
    for (k, L) in enumerate(levels_cpu)
        GL.glFinish()
        t = @elapsed (push!(gl_levels, upload_lines(L)[1]); GL.glFinish())
        bytes_lines += sizeof(L.xy) + sizeof(L.val)
        say(@sprintf("lines level %d: %.1f MB in %s (%.0f MB/s)", k, (sizeof(L.xy) + sizeof(L.val)) / 1e6, ms(t),
            (sizeof(L.xy) + sizeof(L.val)) / 1e6 / t))
    end
    # chunked upload of the full xy buffer, 8 MB per call (as a frame budget would do)
    for mb in (1, 4, 8, 32)
        tmp, times = upload_lines(ls; chunk = mb << 20)
        say(@sprintf("chunked xy upload glBufferSubData %2d MB: %d chunks, median %s, max %s per chunk", mb, length(times),
            ms(median(times)), ms(maximum(times))))
        GL.glDeleteBuffers(2, GL.GLuint[tmp.vbo_xy, tmp.vbo_v]); GL.glDeleteVertexArrays(1, Ref(tmp.vao))
    end
    for mb in (1, 4, 8, 32)
        n = mb << 20; times = Float64[]; bufs = GL.GLuint[]
        for off in 0:n:(sizeof(ls.xy) - n)
            b = genbuf(); push!(bufs, b); GL.glBindBuffer(GL.GL_ARRAY_BUFFER, b)
            push!(times, @elapsed (GL.glBufferData(GL.GL_ARRAY_BUFFER, n, pointer(ls.xy) + off, GL.GL_STATIC_DRAW); GL.glFinish()))
        end
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0); GL.glDeleteBuffers(length(bufs), bufs)
        say(@sprintf("new buffer per chunk glBufferData %2d MB: %d chunks, median %s, max %s (%.0f MB/s)", mb, length(times),
            ms(median(times)), ms(maximum(times)), mb * 1.048576 / median(times)))
    end
    tiles = Dict{Tuple{Int,Int},GL.GLuint}()
    tt = Float64[]
    bytes_tiles = 0
    for (key, lv) in tiles_cpu
        GL.glFinish()
        push!(tt, @elapsed (tiles[key] = upload_tile(lv); GL.glFinish()))
        bytes_tiles += sum(sizeof, lv)
    end
    say(@sprintf("grid: %d tiles of %d^2 R32F + mips, %.1f MB, total %s, per tile median %s max %s",
        length(tiles), TILE + 2, bytes_tiles / 1e6, ms(sum(tt)), ms(median(tt)), ms(maximum(tt))))
    # GPU mip generation for comparison (one tile)
    k1 = first(keys(tiles_cpu))
    A = tiles_cpu[k1][1]
    tg = tex2d(size(A)..., GL.GL_R32F, GL.GL_RED, GL.GL_FLOAT, A; filt = GL.GL_LINEAR_MIPMAP_NEAREST)
    GL.glFinish()
    t = @elapsed (GL.glGenerateMipmap(GL.GL_TEXTURE_2D); GL.glFinish())
    say("glGenerateMipmap one tile: ", ms(t), " (spreads NaN, so CPU NaN-aware mips used instead)")
    GL.glDeleteTextures(1, Ref(tg))
    say(@sprintf("GPU bytes allocated by the spike: lines %.0f MB (all 4 levels), grid %.0f MB", bytes_lines / 1e6, bytes_tiles / 1e6))
    m1 = gpu_mem_kb(); say("GPU memory info after upload: ", m1)

    quad = genvao(); GL.glBindVertexArray(quad)
    qb = genbuf(); GL.glBindBuffer(GL.GL_ARRAY_BUFFER, qb)
    qd = Float32[0, 0, 1, 0, 0, 1, 1, 1]
    GL.glBufferData(GL.GL_ARRAY_BUFFER, sizeof(qd), qd, GL.GL_STATIC_DRAW)
    GL.glVertexAttribPointer(0, 2, GL.GL_FLOAT, GL.GL_FALSE, 0, C_NULL); GL.glEnableVertexAttribArray(0)
    GL.glBindVertexArray(0)
    qs = Vector{GL.GLuint}(undef, 4); GL.glGenQueries(4, qs)
    # value range: p2..p98 from the cdf for lines and grid alike
    p(q) = lo + (hi - lo) * (findfirst(>=(q), cdf) - 0.5) / NLUT
    c = Ctx(lprog, gprog, lut, cdftex, gl_levels, buckets, tiles, nt, quad, g, ls.origin,
        (Float32(p(0.02)), Float32(p(0.98))), nothing, qs, 1, Float64[], 0, tiles_cpu[k1])

    # ---- scenarios
    scen = [
        ("lines full, whole survey", Scene(lod = :full), View(mpp = 70)),
        ("lines LOD auto, whole survey", Scene(lod = :auto), View(mpp = 70)),
        ("lines full, whole survey, MSAA 4x", Scene(lod = :full, samples = 4), View(mpp = 70)),
        ("lines full, zoom 10x, bbox cull", Scene(lod = :full), View(mpp = 7)),
        ("lines full, zoom 10x, no cull", Scene(lod = :full, cull = false), View(mpp = 7)),
        ("lines full, zoom 100x, bbox cull", Scene(lod = :full), View(mpp = 0.7)),
        ("grid only, whole, histeq+shade", Scene(lines = false, grid = true), View(mpp = 70)),
        ("grid only, zoom 20x, histeq+shade", Scene(lines = false, grid = true), View(mpp = 3.5)),
        ("grid only, whole, linear no shade", Scene(lines = false, grid = true, histeq = false, shade = false), View(mpp = 70)),
        ("grid + lines LOD, whole", Scene(grid = true, lod = :auto), View(mpp = 70)),
        ("grid + lines full, whole", Scene(grid = true, lod = :full), View(mpp = 70)),
        ("grid + lines, stream 1 tile/frame", Scene(grid = true, lod = :auto, stream = :tile), View(mpp = 70)),
        ("grid + lines, stream 8 MB lines/frame", Scene(grid = true, lod = :auto, stream = :lines), View(mpp = 70)),
        ("ImDrawList 200k points", Scene(imdraw = 200_000), View(mpp = 70)),
        ("ImDrawList 1M points", Scene(imdraw = 1_000_000), View(mpp = 70)),
        ("lines LOD, worker reads 20M meanwhile", Scene(lod = :auto, bg = true), View(mpp = 70)),
        ("grid+lines LOD, worker reads 20M", Scene(grid = true, lod = :auto, bg = true), View(mpp = 70)),
    ]
    shots = Dict(1 => "lines_full", 2 => "lines_lod", 4 => "lines_zoom10", 6 => "lines_zoom100", 9 => "grid_linear", 7 => "grid_whole",
                 8 => "grid_zoom", 10 => "grid_lines_lod", 14 => "imdraw_200k")
    NF = parseint = parse(Int, get(ENV, "NF", "150"))
    say("\n== frames (", NF, " per scenario, first 20 dropped; pan on an ellipse, about 20 px per frame; FBO = map window content) ==")
    say(@sprintf("%-40s %9s %9s %9s %9s %9s %10s", "scenario", "wall med", "wall p95", "cpu map", "gpu med", "gpu p95", "points"))
    streamtex = upload_tile(c.tiledata)
    streambuf = genbuf(); GL.glBindBuffer(GL.GL_ARRAY_BUFFER, streambuf)
    GL.glBufferData(GL.GL_ARRAY_BUFFER, 8 << 20, C_NULL, GL.GL_STREAM_DRAW); GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0)
    only = haskey(ENV, "SCEN") ? parse.(Int, split(ENV["SCEN"], ",")) : collect(eachindex(scen))
    for (si, (name, sc, v0)) in enumerate(scen)
        si in only || continue
        v = deepcopy(v0)
        walls = Float64[]; cpus = Float64[]; empty!(c.gpu_ms); c.qframe = 1
        last = time_ns()
        pts = 0
        stop = Threads.Atomic{Bool}(false); rounds = Threads.Atomic{Int}(0)
        bgtask = sc.bg ? Threads.@spawn(while !stop[]
            l2 = read_lines(joinpath(DATA, "db")); decimate(l2, 8); Threads.atomic_add!(rounds, 1)
        end) : nothing
        for fr in 1:NF
            GLFW.PollEvents()
            lib.ImGui_ImplOpenGL3_NewFrame(); lib.ImGui_ImplGlfw_NewFrame(); ig.NewFrame()
            vp = unsafe_load(ig.GetMainViewport())
            ig.SetNextWindowPos(ig.ImVec2(0, 0)); ig.SetNextWindowSize(ig.ImVec2(W, H))
            ig.Begin("Map", C_NULL, ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove)
            avail = ig.GetContentRegionAvail()
            fw, fh = Int(avail.x), Int(avail.y - 24)
            ig.Text(@sprintf("%s  frame %d  centre %.0f,%.0f  %.2f m/px", name, fr, v.cx, v.cy, v.mpp))
            p0 = ig.GetCursorScreenPos()
            tc = time_ns()
            if sc.stream == :tile
                GL.glBindTexture(GL.GL_TEXTURE_2D, streamtex)
                A = c.tiledata[1]
                GL.glTexSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, size(A)..., GL.GL_RED, GL.GL_FLOAT, A)
                GL.glBindTexture(GL.GL_TEXTURE_2D, 0)
            elseif sc.stream == :lines
                GL.glBindBuffer(GL.GL_ARRAY_BUFFER, streambuf)
                GL.glBufferSubData(GL.GL_ARRAY_BUFFER, 0, 8 << 20, pointer(ls.xy) + (fr % 10) * (8 << 20))
                GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0)
            end
            if sc.imdraw > 0
                tex = draw_map!(c, Scene(lines = false), v, fw, fh)
                ig.Image(ig.ImTextureRef(ig.ImTextureID(tex)), ig.ImVec2(fw, fh), ig.ImVec2(0, 1), ig.ImVec2(1, 0))
                imdraw_lines!(c, v, sc.imdraw, p0, fw, fh)
            else
                tex = draw_map!(c, sc, v, fw, fh)
                ig.Image(ig.ImTextureRef(ig.ImTextureID(tex)), ig.ImVec2(fw, fh), ig.ImVec2(0, 1), ig.ImVec2(1, 0))
            end
            ig.End()
            ig.Render()
            fbw, fbh = GLFW.GetFramebufferSize(win)
            GL.glViewport(0, 0, fbw, fbh); GL.glClearColor(0, 0, 0, 1); GL.glClear(GL.GL_COLOR_BUFFER_BIT)
            lib.ImGui_ImplOpenGL3_RenderDrawData(Ptr{Cint}(ig.GetDrawData()))
            tcpu = (time_ns() - tc) / 1e6
            if fr == NF - 1 && haskey(shots, si)
                GL.glFinish()
                back_buffer_png(joinpath(OUT, shots[si] * ".png"), fbw, fbh)
            end
            GLFW.SwapBuffers(win)
            now = time_ns()
            if fr > 20 && fr < NF - 1
                push!(walls, (now - last) / 1e6); push!(cpus, tcpu)
            end
            last = now
            pts = c.drawn_pts
            v.cx = v0.cx + 300 * v.mpp * sin(fr / 15); v.cy = v0.cy + 120 * v.mpp * cos(fr / 15)   # pan, about 20 px per frame
        end
        stop[] = true; bgtask === nothing || (wait(bgtask); say("  worker rounds during the scenario: ", rounds[], ", wall max ", round(maximum(walls); digits = 1), " ms"))
        gm = c.gpu_ms[min(21, end):end]
        say(@sprintf("%-40s %6.2f ms %6.2f ms %6.2f ms %6.2f ms %6.2f ms %10d", name, median(walls), quantile(walls, 0.95),
            median(cpus), median(gm), quantile(gm, 0.95), pts))
    end
    say("GPU memory info at end: ", gpu_mem_kb())
    lib.ImGui_ImplOpenGL3_Shutdown(); lib.ImGui_ImplGlfw_Shutdown(); ig.DestroyContext(ctx)
    GLFW.DestroyWindow(win)
    say("total ", round(time() - t_all; digits = 1), " s")
end

main()
close(LOG)
