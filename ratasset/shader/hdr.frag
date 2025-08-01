#version 460 core
out vec4 FragColor;

in vec2 TexCoords;
layout(binding = 0) uniform sampler2D hdrcolor;

uniform float exposure;
uniform float gamma = 2.2;

void main(){
    vec2 uv = TexCoords;
    vec3 result = texture(hdrcolor, uv).rgb;
    vec3 mapped = vec3(1.0) - exp(-result * exposure);
    mapped = pow(mapped, vec3(1.0/gamma));
    FragColor = vec4(mapped, 1.0);
}
