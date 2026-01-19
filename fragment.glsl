layout(location = 0)      in vec2  v_tex_coords;
layout(location = 1)      in vec2  v_position;
layout(location = 2)      in vec2  v_size;
layout(location = 3)      in vec4  v_color;
layout(location = 4)      in vec4  v_border_color;
layout(location = 5)      in float v_border_width;
layout(location = 6)      in float v_border_radius;
layout(location = 7) flat in int   v_use_texture;

layout(location = 0) out vec4 f_color;

uniform sampler2D u_texture;

// adapted from https://iquilezles.org/articles/distfunctions2d/
float rounded_box_sdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p - b / 2) - b / 2 + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    f_color = vec4(1);

    float border_weight = 0;
    if (v_border_width != 0) {
        float d = rounded_box_sdf(v_position, v_size, v_border_radius) - 0.5;

        if (d > 0) {
            f_color.a = 0;
            return;
        } else if (d > -1) {
            f_color   = v_border_color;
            f_color.a = -d;
            return;
        } else if (d > -v_border_width) {
            f_color = v_border_color;
            return;
        } else if (d > -(v_border_width + 1)) {
            border_weight = d + v_border_width + 1;
        }
    } else if (v_border_radius != 0) {
        float d = rounded_box_sdf(v_position, v_size, v_border_radius) - 0.5;
        if (d > 0) {
            f_color.a = 0;
            return;
        } else if (d > -1) {
            f_color.a = -d;
        }
    }

    f_color *= v_color;
    if (v_use_texture != 0) {
        f_color.a *= texture(u_texture, v_tex_coords).r;
    }

    f_color = mix(f_color, v_border_color, border_weight);
}
