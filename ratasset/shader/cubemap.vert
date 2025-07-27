#version 420 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec2 uv;

out vec2 in_texcoord;

uniform mat4 view;
uniform mat4 model;

void main()
{
    in_texcoord = uv;
    vec4 pos = view * model * vec4(aPos, 1.0);
    gl_Position = pos.xyww;
}  
