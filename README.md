# Hammer editor.
Wip


## Implemented: 
* loading of vmf, vpk, vmt, vtf, mdl, vvd, gameinfo, fgd 
* rendering of csg, models, point entities, skybox
* translation of solids and entities
* basic inspection


## TODO
* Writing vmf files.
* Actual editing.
* Much more
* alpha sorting

![d1_trainstation_01](doc/photo1.jpg)


### Running
```
git submodule update --init --recursive
zig build

# Example, running with tf2, assumes a symlink exists
ln path/to/steamapps/common/Team Fortress\ 2.
./zig-out/bin/zig-hammer --basedir "Team Fortress 2" --gameinfo "Team Fortress 2/tf" --vmf tf2maps/sdk_ctf_2fort.vmf


# If basedir and gameinfo are not specified it defaults to searching inside of "./Half-Life 2".

Just symlink "steamapps/common/Half-Life 2" to this directory.
```
