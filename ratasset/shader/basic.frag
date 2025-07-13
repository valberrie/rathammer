#version 420 core
layout (location = 0) in vec4 in_color;
layout (location = 1) in vec2 in_texcoord;
layout (location = 2) in vec3 in_normal;
layout (location = 3) in vec3 in_frag_pos;
layout (location = 4) in vec3 in_tangent;
layout (location = 5) flat in uint tindex;

layout (location = 0) out vec4 FragColor;

layout (binding = 0) uniform sampler2D diffuse_texture;

vec3 light_dir = vec3(1,1,1);
vec3 ambient = vec3(190.0 / 255.0,  201.0 / 255.0, 220.0/255.0);
vec3 light_c = vec3(237.0 /255.0, 218.0 / 255.0, 143.0 / 255.0 );
float ambient_strength = 0.2;
float light_str = 0.3;
void main() {

    vec3 norm = normalize(in_normal);
    float diff = max(dot(norm, light_dir), 0.0);
    vec3 diffuse = light_str * diff * light_c;


    //FragColor = vec4(in_texcoord, 1,1);
    FragColor = texture(diffuse_texture, in_texcoord) * in_color;
    vec3 amb = ambient * ambient_strength;
    vec3 result = (ambient +  (diffuse )) * FragColor.rgb;
    FragColor.rgb = result;
    if (FragColor.a < 0.1){
        discard;
    }
};
