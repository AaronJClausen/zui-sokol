@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    mat4 tm;
};

in vec4 position;
in vec2 texcoord0;
in vec4 color0;
in float psize;
out vec4 uv;
out vec4 color;
out float brightness;

void main() {
    gl_Position = mvp * position;
    uv = tm * vec4(texcoord0, 0.0, 1.0);
    color = color0;
    brightness = psize;
}
@end

@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

in vec4 uv;
in vec4 color;
in float brightness;
out vec4 frag_color;

vec3 linearFromSrgb(vec3 encoded) {
    vec3 low = encoded / 12.92;
    vec3 high = pow((encoded + 0.055) / 1.055, vec3(2.4));
    return mix(low, high, step(vec3(0.04045), encoded));
}

void main() {
    vec4 texel = texture(sampler2D(tex, smp), uv.xy);
    frag_color = vec4(linearFromSrgb(texel.rgb) * linearFromSrgb(color.rgb) * brightness, texel.a * color.a);
}
@end

@program linear_light vs fs
