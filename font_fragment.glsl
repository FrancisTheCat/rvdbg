#version 450

layout (location = 0)      in vec2 v_tex_coord;
layout (location = 1) flat in int  v_bezier;

void main() {
    if (v_bezier != 0 && v_tex_coord.x * v_tex_coord.x - v_tex_coord.y > 0) {
        discard;
    }
}
