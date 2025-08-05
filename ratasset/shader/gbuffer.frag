#version 420 core
layout (location = 0) out vec4 g_pos;
layout (location = 1) out vec4 g_norm;
layout (location = 2) out vec4 g_albedo;


layout (location = 0) in vec4 in_color;
layout (location = 1) in vec2 in_texcoord;
layout (location = 2) in vec3 in_normal;
layout (location = 3) in vec3 in_frag_pos;
layout (location = 4) in vec3 in_tangent;
layout (location = 5) flat in uint tindex;

layout (binding = 0) uniform sampler2D diffuse_texture;
layout (binding = 1) uniform sampler2D normal_texture;
layout (binding = 3) uniform sampler2DArray textures;

vec3 bumpNorm(){
    vec3 norm = normalize(in_normal);
    return norm;
    vec3 tangent = normalize(in_tangent);
    tangent = normalize(tangent - dot(tangent, norm) * norm);
    vec3 bitangent = cross(tangent, norm);
    //return tangent;
    vec3 bump_norm = normalize(texture(textures, vec3(in_texcoord, tindex + 1)).xyz * 2.0 - 1.0);
    vec3 new_norm;
    mat3 TBN = mat3(tangent, bitangent, norm);
    new_norm = normalize(TBN * bump_norm);
    return new_norm;
}


void main(){
    g_pos = vec4(in_frag_pos,1);
    //g_norm = vec4(texture(normal_texture, in_texcoord).rgb, 1);
    //g_norm = vec4(normalize(in_normal),1);
    g_norm = vec4(bumpNorm(),1);
    g_albedo.rgb = in_color.rgb * texture(textures, vec3(in_texcoord,tindex)).rgb;
    g_albedo.a = 1;
}
