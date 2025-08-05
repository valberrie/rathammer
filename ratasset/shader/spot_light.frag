#version 420 core


layout (location = 0) in vec3 light_pos;
layout (location = 1) in vec3 ambi_color;
layout (location = 2) in vec3 diff_color;
layout (location = 3) in vec3 spec_color;
layout (location = 4) in float constant;
layout (location = 5) in float linear;
layout (location = 6) in float quadratic;
layout (location = 7) in vec3 spot_lightdir;
layout (location = 8) in float cutoff_outer;
layout (location = 9) in float cutoff_inner;

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
void main(){
    vec2 uv = (gl_FragCoord.xy - the_fucking_window_offset) / screenSize;

    if(draw_debug){
        FragColor = vec4(diff_color / 255,1);
        return;
    }

    vec3 frag_pos = texture(g_pos, uv).rgb;
    vec3 normal = texture(g_norm, uv).rgb;
    vec3 diffuse_g = texture(g_albedo, uv).rgb;

    
    // diffuse 
    vec3 light_dir = normalize(light_pos - frag_pos);
    float diff = max(dot(normal, light_dir), 0.0);
    vec3 diffuse = diff_color * diff;
    
    // specular
    vec3 view_dir = normalize(view_pos - frag_pos);
    vec3 reflect_dir = reflect(-light_dir, normal);  
    float spec = pow(max(dot(view_dir, reflect_dir), 0.0), 32);
    vec3 specular = specular_strength * spec * spec_color;
    
    // spotlight (soft edges)
    float theta = dot(light_dir, normalize(-spot_lightdir)); 
    float epsilon = (cutoff_inner - cutoff_outer);
    float intensity = clamp((theta - cutoff_outer) / epsilon, 0.0, 1.0);
    diffuse  *= intensity;
    specular *= intensity;
    
    // attenuation
    float dist    = length(light_pos - frag_pos);
    float attenuation = 1.0 / (constant + linear * dist + quadratic * (dist * dist));    
    diffuse   *= attenuation;
    specular *= attenuation;   
        
    vec3 result =  (diffuse + specular) * diffuse_g;
    FragColor = vec4(result, 1.0);

}
