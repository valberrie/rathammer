#version 460 core

layout (location = 0) in vec3 vpos;
layout (location = 1) in vec3 light_pos;
layout (location = 2) in vec3 ambi_color;
layout (location = 3) in vec3 diff_color;
layout (location = 4) in vec3 spec_color;
layout (location = 5) in float constant;
layout (location = 6) in float linear;
layout (location = 7) in float quadratic;

layout (location = 0) out vec3 out_light_pos;
layout (location = 1) out vec3 out_ambi_color;
layout (location = 2) out vec3 out_diff_color;
layout (location = 3) out vec3 out_spec_color;
layout (location = 4) out float out_constant;
layout (location = 5) out float out_linear;
layout (location = 6) out float out_quadratic;

uniform mat4 model = mat4(1.0f);
uniform mat4 view = mat4(1.0f);

float calcRadius(){
    float lmin = 256.0 / 5.0;
    float lmax = max(max(diff_color.r,diff_color.g),diff_color.b);

    return (-linear + sqrt(pow(linear,2) - 4 * quadratic * (constant - lmin * lmax))) / (2 * quadratic);
}

void main(){
    float radius = calcRadius();
    
    gl_Position = view * vec4((vpos * radius + light_pos ) , 1);
    out_light_pos = light_pos;

    out_ambi_color = ambi_color;;
    out_diff_color = diff_color;
    out_spec_color = spec_color;
    out_constant = constant;
    out_linear = linear;
    out_quadratic = quadratic;

}

