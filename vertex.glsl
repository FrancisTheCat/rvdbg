#version 450

layout(location = 0) in vec2 a_position;

layout(location = 1) in vec4 i_rect;
layout(location = 2) in vec4 i_tex_rect;
layout(location = 3) in vec4 i_color;
layout(location = 4) in vec4 i_border_color;
layout(location = 5) in vec2 i_border_width_radius;
layout(location = 6) in int  i_has_font;

layout(location = 0)      out vec2  v_tex_coords;
layout(location = 1)      out vec2  v_position;
layout(location = 2)      out vec2  v_size;
layout(location = 3)      out vec4  v_color;
layout(location = 4)      out vec4  v_border_color;
layout(location = 5)      out float v_border_width;
layout(location = 6)      out float v_border_radius;
layout(location = 7) flat out int   v_has_font;

uniform vec2 u_resolution;
uniform vec2 u_scale;

void main() {
    vec2 position   = mix(i_rect.xy,     i_rect.zw,     a_position);
    v_tex_coords    = mix(i_tex_rect.xy, i_tex_rect.zw, a_position);
    v_color         = i_color;
    v_size          = i_rect.zw - i_rect.xy;
    v_position      = a_position * v_size;
    v_has_font      = i_has_font;
    v_border_color  = i_border_color;
    v_border_width  = i_border_width_radius[0];
    v_border_radius = i_border_width_radius[1];
    gl_Position     = vec4((2 * u_scale * position / u_resolution - 1) * vec2(1, -1), 0, 1);
}
