#version 420 core
layout (location = 0) in vec3 light_pos;
layout (location = 1) in vec3 ambi_color;
layout (location = 2) in vec3 diff_color;
layout (location = 3) in vec3 spec_color;
layout (location = 4) in float constant;
layout (location = 5) in float linear;
layout (location = 6) in float quadratic;

layout (location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D g_pos;
layout(binding = 1) uniform sampler2D g_norm;
layout(binding = 2) uniform sampler2D g_albedo;

uniform mat4 cam_view;
uniform vec3 view_pos;
uniform vec2 screenSize;
uniform vec2 the_fucking_window_offset;
uniform float exposure;
uniform float gamma = 2.2;
uniform bool draw_debug = false;

float specular_strength = 0.5;
vec3 calculatePointLight(vec3 normal,vec3 view_dir, vec3 frag_pos){
    vec3  ldir = normalize(light_pos - frag_pos);
    float diff = max(dot(normal, ldir), 0.0);
    vec3 diffuse1 = diff * diff_color;

    vec3 reflect_dir = reflect(-ldir, normal);
    float spec = pow(max(dot(view_dir, reflect_dir), 0.0), 32);
    vec3 specular = specular_strength * spec * spec_color;

    float dist    = length(light_pos - frag_pos);
    float attenuation = 1.0 / (constant + linear * dist + quadratic * (dist * dist));

    diffuse1 *= attenuation;
    specular *= attenuation;

    //vec3 ambient = ambient_strength * ambient_color;
    return (diffuse1 + specular);
}

void main(){
    vec2 uv = (gl_FragCoord.xy - the_fucking_window_offset) / screenSize;

    vec3 frag_pos = texture(g_pos, uv).rgb;
    vec3 normal = texture(g_norm, uv).rgb;
    vec3 diffuse = texture(g_albedo, uv).rgb;


    vec3 view_dir = normalize(view_pos - frag_pos);

    vec3 result =  calculatePointLight(normal, view_dir, frag_pos) * diffuse;

    FragColor = vec4(result, 1);

    if(draw_debug)
        FragColor = vec4(diff_color / 255,1);
}
