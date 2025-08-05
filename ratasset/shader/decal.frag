#version 420 core
layout (location = 0) in vec4 pos_cs;
layout (location = 1) in vec4 pos_view;
layout (location = 2) in vec3 decal_pos;

layout (location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D g_pos;
layout(binding = 1) uniform sampler2D g_norm;
layout(binding = 2) uniform sampler2D g_depth;
uniform mat4 cam_view;
uniform mat4 cam_view_inv;
uniform vec3 view_pos;
uniform vec2 screenSize;
uniform vec2 the_fucking_window_offset = vec2(0.0);
uniform float exposure;
uniform float gamma = 2.2;
uniform bool draw_debug = false;
uniform float far_clip;

void main(){
    vec2 uv = (gl_FragCoord.xy - the_fucking_window_offset) / screenSize;
    vec2 screen_pos = pos_cs.xy / pos_cs.w;

    vec3 frag_pos = texture(g_pos, uv).rgb;
    vec3 normal = texture(g_norm, uv).rgb;

    vec2 tex = vec2( (1 + screen_pos.x) / 2 + (0.5 / screenSize.x),
                     (1 - screen_pos.y) / 2 + (0.5 / screenSize.y));
    
    float depth  = texture(g_depth, uv).r;

    vec3 view_ray = pos_view.xyz * (far_clip / -pos_view.z);
    vec3 view_pos = view_ray * depth;
    vec3 world_pos = (vec4(view_pos,1) * cam_view_inv).xyz;
    vec3 obj_pos = (world_pos - decal_pos) / 64;

//if(length(abs(obj_pos)) > 1 )
        //discard;
    FragColor = vec4(1,1,1,1);
}

