#version 420 core
out vec4 FragColor;

in vec2 in_texcoord;

//uniform samplerCube skybox;
uniform sampler2D textures;

void main()
{    
    //FragColor = texture(textures, TexCoords);
    FragColor =  texture(textures, in_texcoord );
}
