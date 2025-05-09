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
* rotation gizmo.
* Translation and rotation about arbitrary axis
* Write documentation

![d1_trainstation_01](doc/photo1.jpg)

### Running
```
git submodule update --init --recursive
zig build

# Example, running with tf2, 
# First symlink the Game's directory for easy access.
ln path/to/steamapps/common/Team Fortress\ 2.
./zig-out/bin/zig-hammer --basedir "Team Fortress 2" --gamedir "Team Fortress 2/tf" --vmf my_tf2maps/sdk_ctf_2fort.vmf

# If basedir and gameinfo are not specified it defaults to searching inside of "./Half-Life 2".
```
