#version 420 core
layout (location = 0) in vec3 aPos;

uniform mat4 view = mat4(1.0f);
uniform mat4 model = mat4(1.0f);

void main(){
    gl_Position = view * model * vec4(aPos, 1.);
}
