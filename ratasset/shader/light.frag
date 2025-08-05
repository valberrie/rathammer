
#version 420 core
layout (location = 0) in vec4 color;
layout (location = 1) in vec2 texcoord;
layout (location = 2) in vec3 normal;

layout (location = 3) in vec3 frag_pos;

layout (location = 0) out vec4 FragColor;

layout (std140, binding = 0) uniform LightSpaceMatrices {
    mat4 lightSpaceMatrices[16];
};

uniform sampler2D diffuse_texture;
uniform sampler2DArray shadow_map;


uniform float cascadePlaneDistances[16];
uniform vec3 view_pos;
uniform mat4 view;
uniform vec3 light_dir;

uniform vec3 light_color;

int CASCADE_COUNT = 4;

float shadowCalculation(vec3 fp){
    vec4 fp_vs = view * vec4(fp, 1.0);
    float depth = abs(fp_vs.z);
    int layer = -1;
    for(int i = 0; i < CASCADE_COUNT; i++){
        if(depth < cascadePlaneDistances[i]){
            layer = i;
            break;
        }
    }
    if(layer == -1){
        layer = CASCADE_COUNT - 1;
    }
    mat4 ls = lightSpaceMatrices[layer];
    //vec4 frag_pos_ls = lightSpaceMatrices[layer] * vec4(fp, 1.0);
    vec4 frag_pos_ls = ls * vec4(fp, 1.0);
    vec3 proj_coord = frag_pos_ls.xyz / frag_pos_ls.w;
    proj_coord = proj_coord * 0.5 + 0.5;
    //float current_depth = proj_coord.z;
    //if(current_depth > 1.0){
    //    return 0.0;
    //}

    vec3 normal = normalize(normal);
    float bias = max(0.05 * (1.0 - dot(normal, light_dir)), 0.005);
    const float bias_mod = 0.5;
    bias *= 1 / (cascadePlaneDistances[layer] * bias_mod);

    float closest_depth = texture(shadow_map, vec3(proj_coord.xy, layer)).r;
    float current_depth = proj_coord.z;
    float shadow = current_depth - bias > closest_depth ? 0.9: 0.0;


    shadow = 0.0;
    vec2 texel_size = 1.0 / vec2(textureSize(shadow_map, 0));
    for(int x = -1; x <= 1; x++){
        for(int y = -1; y <= 1; y++){
            float pcf_depth = texture(shadow_map, vec3(proj_coord.xy  + vec2(x,y) * texel_size, layer)).r;
            shadow += (current_depth - bias) > pcf_depth ? 1.0: 0.0;
        }
    }

    shadow /= 9.0;
    return shadow;
}

void main() {
    float ambient_strength = 0.3;
    //vec3 light_color = vec3(240/255.0, 187/255.0, 117/255.0  );
    vec3 ambient_color = vec3(135 / 255.0, 172 / 255.0, 180 / 255.0 );
    float specular_strength = 0.5;

    vec3 norm = normalize(normal);
    float diff = max(dot(norm, light_dir), 0.0);
    vec3 diffuse = diff * light_color;

    vec3 view_dir = normalize(view_pos - frag_pos);
    vec3 reflect_dir = reflect(-light_dir, norm);
    float spec = pow(max(dot(view_dir, reflect_dir), 0.0), 32);
    vec3 specular = specular_strength * spec * light_color;

    float shadow = shadowCalculation(frag_pos);


    vec3 ambient = ambient_strength * ambient_color;
    vec3 result = (ambient + (1.0 - shadow) * (diffuse + specular)) * color.rgb * texture(diffuse_texture, texcoord).rgb;


    FragColor = vec4(result,1.0);
};
