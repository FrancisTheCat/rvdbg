#version 450

layout(location = 0)      in vec2  v_tex_coords;
layout(location = 1)      in vec2  v_position;
layout(location = 2)      in vec2  v_size;
layout(location = 3)      in vec4  v_color;
layout(location = 4)      in vec4  v_border_color;
layout(location = 5)      in float v_border_width;
layout(location = 6)      in float v_border_radius;
layout(location = 7) flat in int   v_has_font;

layout(location = 0) out vec4 f_color;

uniform vec2         u_resolution;
uniform vec2         u_scale;

uniform usampler2DMS u_font_stencil;
uniform uint         u_font_samples;
uniform bool         u_font_subpixel;

// adapted from https://iquilezles.org/articles/distfunctions2d/
float rounded_box_sdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p - b / 2) - b / 2 + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    f_color = vec4(1);

    float border_weight = 0;
    if (v_border_width != 0) {
        float d = rounded_box_sdf(v_position * u_scale, v_size * u_scale, v_border_radius) - 0.5;

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
        float d = rounded_box_sdf(v_position * u_scale, v_size * u_scale, v_border_radius) - 0.5;
        if (d > 0) {
            f_color.a = 0;
            return;
        } else if (d > -1) {
            f_color.a = -d;
        }
    }

    f_color *= v_color;

    if (v_has_font != 0) {
        if (u_font_subpixel) {
            uint counts[7] = { 0, 0, 0, 0, 0, 0, 0, };
            uint count     = 0;
            for (int offset = 0; offset < 7; offset += 1) {
                for (int sample_index = 0; sample_index < u_font_samples; sample_index += 1) {
                    uint value = texelFetch(
                        u_font_stencil,
                        ivec2(gl_FragCoord.xy) * ivec2(3, 1) + ivec2(offset - 3, 0),
                        sample_index
                    ).x % 2;

                    counts[offset] += value;
                    count          += value;
                }
            }

            vec3 channel_weights = vec3(0);
            for (int channel = 0; channel < 3; channel += 1) {
                const float WEIGHTS[] = {
                    1.0 / 9,
                    2.0 / 9,
                    3.0 / 9,
                    2.0 / 9,
                    1.0 / 9,
                };
                for (int i = 0; i < 5; i += 1) {
                    channel_weights[channel] += WEIGHTS[i] * counts[i + channel];
                }
            }

            channel_weights = pow(channel_weights / u_font_samples, vec3(1 / 2.2));

            f_color.rgb *= channel_weights;
            f_color.a   *= (channel_weights.x + channel_weights.y + channel_weights.z) / 3;
        } else {
            uint count = 0;
            for (int sample_index = 0; sample_index < u_font_samples; sample_index += 1) {
                count += texelFetch(
                    u_font_stencil,
                    ivec2(gl_FragCoord.xy),
                    sample_index
                ).x % 2;
            }
            f_color *= pow(float(count) / float(u_font_samples), 1 / 2.2);
        }
    }

    f_color = mix(f_color, v_border_color, border_weight);
}
