#version 420 core

layout (location = 0) in vec3 vpos;
layout (location = 1) in vec3 decal_pos;
layout (location = 2) in vec3 decal_ext;

uniform mat4 view = mat4(1.0f);

layout (location = 0) out vec4 pos_cs;
layout (location = 1) out vec4 pos_view;
layout (location = 2) out vec3 decal_pos_out;

void main(){

    decal_pos_out = decal_pos;
    mat3 scale = mat3(1.0f);
    scale[0][0] = decal_ext.x;
    scale[1][1] = decal_ext.y ;
    scale[2][2] = decal_ext.z ;

    pos_view = vec4( vpos * 64 + decal_pos  , 1);
    pos_cs = view * pos_view;
    gl_Position = pos_cs;
}
