@vs vs
layout(binding=0) uniform vs_params {
    float flips_rows;
};

out vec2 uv;

void main() {
    vec2 corner = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    uv = vec2(corner.x, mix(1.0 - corner.y, corner.y, flips_rows));
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    float sdr_white_scale;
};
layout(binding=0) uniform texture2D scene;
layout(binding=0) uniform sampler scene_sampler;

in vec2 uv;
out vec4 frag_color;

void main() {
    vec4 linear = texture(sampler2D(scene, scene_sampler), uv);
    frag_color = vec4(linear.rgb * sdr_white_scale, linear.a);
}
@end

@program present_scrgb vs fs
