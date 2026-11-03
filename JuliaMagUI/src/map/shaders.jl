# The GLSL shaders of the map pass. They follow the rules of the CPU renderer (cpu.jl).
# Positions are Float32 offsets from a layer origin; `ndc = (pos - c) * s` (`gl_transform`).

# The colour rule of `Core.colour_position` and the look-up table, shared by both programs.
# `u_flat` is set when the limits are equal or NaN; `u_table_n` is 0 without an equalization table.
const COLOUR_GLSL = """
uniform sampler2D u_lut;     // 256 by 1 RGBA8
uniform sampler2D u_table;   // u_table_n by 1 R32F
uniform int u_table_n;
uniform int u_flat;
uniform float u_lo;
uniform float u_hi;

float colour_position(float v) {
    if (u_flat != 0) return 0.5;
    float t = clamp((v - u_lo) / (u_hi - u_lo), 0.0, 1.0);
    if (u_table_n == 0) return t;
    float x = t * float(u_table_n - 1);
    int i = min(int(floor(x)), u_table_n - 2);
    float f = x - float(i);
    float a = texelFetch(u_table, ivec2(i, 0), 0).r;
    float b = texelFetch(u_table, ivec2(i + 1, 0), 0).r;
    return a + (b - a) * f;
}

// The look-up entry round(t * 255), a half to even as the CPU rounds.
vec3 lut_colour(float t) {
    return texelFetch(u_lut, ivec2(int(roundEven(t * 255.0)), 0), 0).rgb;
}
"""

const LINE_VS = """
#version 330 core
layout(location = 0) in vec2 pos;
layout(location = 1) in float val;
uniform vec2 u_c;
uniform vec2 u_s;
out float v_val;
void main() {
    v_val = val;
    gl_Position = vec4((pos - u_c) * u_s, 0.0, 1.0);
}
"""

const LINE_FS = """
#version 330 core
in float v_val;
uniform vec4 u_plain;
uniform float u_opacity;
out vec4 colour;
""" * COLOUR_GLSL * """
void main() {
    vec3 rgb = isnan(v_val) ? u_plain.rgb : lut_colour(colour_position(v_val));
    colour = vec4(rgb, u_opacity);
}
"""

# One quad per tile. `u_corner` holds the corners in the order of `gl_VertexID` (a triangle
# strip): low i low j, high i low j, low i high j, high i high j. `u_cells` is the cell range
# of the quad in the tile's texel numbers: texel k holds cell k of the tile, texel 0 and
# tile + 1 are the border.
const GRID_VS = """
#version 330 core
uniform vec2 u_c;
uniform vec2 u_s;
uniform vec2 u_corner[4];
uniform vec4 u_cells;
out vec2 v_cell;
void main() {
    vec2 ab = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    v_cell = mix(u_cells.xy, u_cells.zw, ab);
    gl_Position = vec4((u_corner[gl_VertexID] - u_c) * u_s, 0.0, 1.0);
}
"""

# Nearest: the cell's value. Bilinear: all four cells, NaN if any is NaN. Hillshade: central
# differences of the nearest cell's neighbours (a NaN one counts as the centre), turned by
# the grid rotation, as `shade_factor` in cpu.jl. The shaded colour is rounded to a byte as
# the CPU rounds it before it blends.
const GRID_FS = """
#version 330 core
in vec2 v_cell;
uniform sampler2D u_cells_tex;   // (tile + 2) by (tile + 2) R32F
uniform int u_last;              // tile + 1, the last texel
uniform int u_nearest;
uniform int u_shade;
uniform vec2 u_cell_size;        // world size of a cell at this level
uniform vec2 u_rot;              // cos and sin of the grid rotation
uniform vec3 u_sun;
uniform float u_z;
uniform float u_opacity;
out vec4 colour;
""" * COLOUR_GLSL * """
float cell(ivec2 p) {
    return texelFetch(u_cells_tex, clamp(p, ivec2(0), ivec2(u_last)), 0).r;
}

float neighbour(float v, float centre) { return isnan(v) ? centre : v; }

void main() {
    ivec2 near = ivec2(floor(v_cell + 0.5));
    float v;
    if (u_nearest != 0) {
        v = cell(near);
    } else {
        vec2 f0 = floor(v_cell);
        ivec2 p = ivec2(f0);
        vec2 t = v_cell - f0;
        float v00 = cell(p);
        float v10 = cell(p + ivec2(1, 0));
        float v01 = cell(p + ivec2(0, 1));
        float v11 = cell(p + ivec2(1, 1));
        if (isnan(v00) || isnan(v10) || isnan(v01) || isnan(v11)) discard;
        v = (1.0 - t.x) * (1.0 - t.y) * v00 + (1.0 - t.x) * t.y * v01 + t.x * (1.0 - t.y) * v10 + t.x * t.y * v11;
    }
    if (isnan(v)) discard;
    vec3 rgb = lut_colour(colour_position(v));
    if (u_shade != 0) {
        float c0 = cell(near);
        float l = neighbour(cell(near - ivec2(1, 0)), c0);
        float r = neighbour(cell(near + ivec2(1, 0)), c0);
        float dn = neighbour(cell(near - ivec2(0, 1)), c0);
        float up = neighbour(cell(near + ivec2(0, 1)), c0);
        float gu = (r - l) / (2.0 * u_cell_size.x) * u_z;
        float gv = (up - dn) / (2.0 * u_cell_size.y) * u_z;
        float gx = gu * u_rot.x - gv * u_rot.y;
        float gy = gu * u_rot.y + gv * u_rot.x;
        float h = max((-gx * u_sun.x - gy * u_sun.y + u_sun.z) / sqrt(gx * gx + gy * gy + 1.0), 0.0);
        rgb = roundEven(rgb * 255.0 * (0.25 + 0.75 * h)) / 255.0;
    }
    colour = vec4(rgb, u_opacity);
}
"""
