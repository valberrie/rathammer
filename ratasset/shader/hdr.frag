#version 420 core
out vec4 FragColor;

in vec2 TexCoords;
layout(binding = 0) uniform sampler2D hdrcolor;

uniform float exposure;
uniform float gamma = 2.2;

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}


vec3 change_luminance(vec3 color, float l_out) {
    float l_in = luminance(color);
    return color * (l_out / l_in);
}

vec3 reinhard(vec3 color, float max_white) {
    float old = luminance(color);
    float numerator = old * (1.0 + (old / (max_white * max_white)));
    float new = numerator / (1.0f + old);
    return change_luminance(color, new);
}

vec3 doGamma(vec3 color, float gam){
    return pow(color, vec3(1.0 / gam));
}

void main(){
    vec2 uv = TexCoords;
    vec3 result = texture(hdrcolor, uv).rgb;




    FragColor = vec4(doGamma(reinhard(result, exposure), gamma), 1);
}
