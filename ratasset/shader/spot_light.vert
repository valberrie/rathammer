#version 420 core

layout (location = 0) in vec3 vpos;
layout (location = 1) in vec3 light_pos;
layout (location = 2) in vec3 ambi_color;
layout (location = 3) in vec3 diff_color;
layout (location = 4) in vec3 spec_color;
layout (location = 5) in float constant;
layout (location = 6) in float linear;
layout (location = 7) in float quadratic;

layout (location = 8) in float cutoff;
layout (location = 9) in float cutoff_outer;
layout (location = 10) in vec3 quatxyz;
layout (location = 11) in float q_w;

layout (location = 0) out vec3 out_light_pos;
layout (location = 1) out vec3 out_ambi_color;
layout (location = 2) out vec3 out_diff_color;
layout (location = 3) out vec3 out_spec_color;
layout (location = 4) out float out_constant;
layout (location = 5) out float out_linear;
layout (location = 6) out float out_quadratic;
layout (location = 7) out vec3 out_light_dir;
layout (location = 8) out float out_cuttoff_outer;
layout (location = 9) out float out_cuttoff_inner;

uniform mat4 model = mat4(1.0f);
uniform mat4 view = mat4(1.0f);

float calcRadius(){
    float lmin = 256.0 / 5.0;
    float lmax = max(max(diff_color.r,diff_color.g),diff_color.b);

    return (-linear + sqrt(pow(linear,2) - 4 * quadratic * (constant - lmin * lmax))) / (2 * quadratic);
}

//translated from zalgebra
vec4 fromAxis(vec3 axis, float angle) {
    float rot_sin = sin(radians(angle) / 2);
    vec3 quat_axis = axis * rot_sin;
    float w = cos(radians(angle) / 2);
    return vec4( quat_axis, w);
}

vec3 rotateVec(vec4 quat, vec3 vec){
    vec4 q = normalize(quat);
    vec3 b = q.xyz;
    float b2 = dot(b, b);

    return (vec * (q.w * q.w - b2)) + (b * dot(vec, b) * 2) + (cross(b, vec) * q.w * 2);
}

void main(){
    float radius = calcRadius();
    if(radius != radius)
        radius = 0.1;

    vec4 rot = vec4(quatxyz, q_w);


    float rad_scale = tan(radians(clamp(cutoff_outer, 5,85) )) * radius;

    mat3 scale = mat3(1.0f);
    scale[0][0] = radius;
    scale[1][1] = rad_scale ;
    scale[2][2] = rad_scale ;
    
    gl_Position = view * vec4( rotateVec(rot, vpos * scale) + light_pos  , 1);
    out_light_pos = light_pos;

    out_ambi_color = ambi_color;;
    out_diff_color = diff_color;
    out_spec_color = spec_color;
    out_constant = constant;
    out_linear = linear;
    out_quadratic = quadratic;
    out_light_dir = rotateVec(rot, vec3(1,0,0));

    out_cuttoff_outer = cos(radians(cutoff_outer));
    out_cuttoff_inner = cos(radians(cutoff));
}

