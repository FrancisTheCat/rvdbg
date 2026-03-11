#version 460

layout (location = 0) in vec2  a_position;
layout (location = 1) in int   a_bezier;

layout (location = 0)      out vec2 v_tex_coord;
layout (location = 1) flat out int  v_bezier;

uniform vec2 u_resolution;
uniform vec2 u_scale;

struct DrawCommand {
	uint count;
	uint instance_count;
	uint first_vertex;
	uint base_instance;

    vec2 offset;
    vec2 scale;
};

layout (std430) readonly buffer draw_command_ssbo {
    DrawCommand draw_commands[];
};

void main() {
    switch (gl_VertexID % 3) {
    case 0: {
        v_tex_coord = vec2(0);
    } break;
    case 1: {
        v_tex_coord = vec2(0.5, 0);
    } break;
    case 2: {
        v_tex_coord = vec2(1);
    } break;
    }

    DrawCommand cmd = draw_commands[gl_DrawID];

    v_bezier    = a_bezier;
    gl_Position = vec4((2 * u_scale * (cmd.offset + a_position * cmd.scale) / u_resolution - 1) * vec2(1, -1), 0, 1);
}
