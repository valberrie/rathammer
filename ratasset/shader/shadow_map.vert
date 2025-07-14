#version 420 core
layout (location = 0) in vec3 aPos;

uniform mat4 view;
uniform mat4 model;

void main(){
    gl_Position = view * model * vec4(aPos, 1.);
}
