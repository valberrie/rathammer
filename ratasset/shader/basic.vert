#version 420 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec2 texcoord;
layout (location = 2) in vec3 normal;
layout (location = 3) in uint color;
layout (location = 4) in vec3 tangent;
layout (location = 5) in uint tindex;

layout (location = 0) out vec4 out_color;
layout (location = 1) out vec2 out_texcoord;
layout (location = 2) out vec3 out_normal;
layout (location = 3) out vec3 frag_pos;
layout (location = 4) out vec3 out_tangent;
layout (location = 5) flat  out uint tex_index;

uniform mat4 model = mat4(1.0f);
uniform mat4 view = mat4(1.0f);

void main() {
    tex_index = tindex;
    vec4 world_pos = model * vec4(aPos,1.0);
    frag_pos = world_pos.xyz;
    out_color = unpackUnorm4x8(color).abgr;
    out_texcoord = texcoord;
    //out_normal = transpose(inverse(mat3(model))) * normal;
    out_normal = (model * vec4(normal,0.0)).xyz;
    gl_Position =   view * world_pos;
    out_tangent = (model * vec4(tangent, 0.0)).xyz;
};
