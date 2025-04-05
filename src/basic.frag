#version 420 core
layout (location = 0) in vec4 in_color;
layout (location = 1) in vec2 in_texcoord;
layout (location = 2) in vec3 in_normal;
layout (location = 3) in vec3 in_frag_pos;
layout (location = 4) in vec3 in_tangent;
layout (location = 5) flat in uint tindex;

layout (location = 0) out vec4 FragColor;

layout (binding = 0) uniform sampler2D diffuse_texture;

void main() {
    //FragColor = vec4(in_texcoord, 1,1);
    FragColor = texture(diffuse_texture, in_texcoord) * in_color;
};
