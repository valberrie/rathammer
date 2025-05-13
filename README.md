# Hammer editor.
Wip

## Implemented: 
* loading of vmf, vpk, vmt, vtf, mdl, vvd, gameinfo, fgd 
* rendering of csg, models, point entities, skybox
* translation of solids and entities
* basic inspection
* Texture and model browsing
* undo/redo
* serializing to json
* model placement
* asset browsing

## TODO
* Writing vmf files.
* Writing obj files
* alpha sorting
* Translation and rotation about arbitrary axis
* Write documentation

![d1_trainstation_01](doc/photo1.jpg)

### Building and running
```
git clone https://github.com/nmalthouse/rathammer.git
cd rathammer
git submodule update --init --recursive
zig build

# Example, running with hl2
./zig-out/bin/zig-hammer --custom_cwd ~/.local/share/Steam/steamapps/common --vmf my_maps/my_hl2map.vmf

The file 'config.vdf' defines various game configurations. The default is basic_hl2, which searches the set cwd for a directory named Half-Life 2
See config.vdf for defining other game configs.
```
