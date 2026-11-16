@vs vs
layout(binding=0) uniform vs_params {
    mat4 window_to_clip;
};

in vec2 position;
in vec2 local_position;
out vec2 local;

void main() {
    gl_Position = window_to_clip * vec4(position, 0.0, 1.0);
    local = local_position;
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec4 first_color;
    vec4 second_color;
    vec4 size_and_scale;
    vec4 pattern_and_phase;
};

in vec2 local;
out vec4 frag_color;

const float tau = 6.2831853;

float sheen(vec2 size, float phase) {
    float along = dot(local / max(size, vec2(1.0)), vec2(0.5));
    float from_band = along - (fract(phase) * 1.6 - 0.3);
    return exp(-from_band * from_band * 60.0);
}

float aurora(float scale, float phase) {
    vec2 point = local / max(scale, 1.0);
    float turn = phase * tau;
    float curtain = sin(point.x * 1.7 + turn + 1.3 * sin(point.y * 0.8 - turn * 0.5));
    float ripple = sin(point.y * 2.3 - turn * 0.7 + sin(point.x * 0.9 + turn));
    return clamp(0.5 + 0.3 * curtain + 0.2 * ripple, 0.0, 1.0);
}

void main() {
    float pattern = pattern_and_phase.x;
    float phase = pattern_and_phase.y;
    float amount = 0.0;
    if (pattern > 1.5) {
        amount = aurora(size_and_scale.z, phase);
    } else if (pattern > 0.5) {
        amount = sheen(size_and_scale.xy, phase);
    }
    frag_color = mix(first_color, second_color, amount);
}
@end

@program material vs fs
