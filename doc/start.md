# Intro
RatHammer is an editor for Valve's Source engine maps, though it can also be used standalone as well.

I started developing RatHammer without the intention of it becoming a fully fledged editor, I initially wanted to create a sort of sandbox game I was calling 2x4 simulator, where players could build graybox style environments. In other words, the goal of rathammer is to make the creation of 3d environments enjoyable. 
The style of building the world out of many convex polyhedra is a core part of this.

I occasionally get the urge to make some 3D environments and Half Life 2, with its asset library and its 'easy' way of making level geometry make it a default.
The issue is that Hammer does not run on Linux, and the ergonomics are terrible.
You can't rebind keys for example, and if you use a keyboard layout other than Qwerty you will have to constantly switch layouts. Every operation requires you to move your left hand over to the enter key. And most editing requires you to orient yourself in 4 different views at once. In its current state RatHammer does not have full feature parity with Hammer, but it can do a lot of editing in a way that is much nicer.

I recommend starting RatHammer from a terminal so you can see error messages. If you use the built in Vbsp runner, the compile output of Vbsp, Vvis and Vrad is printed to this console as well.
```
rathammer --help # Show all the flags you can set
```
# Games
By Default RatHammer will search for Half Life 2 in your OS's default steam directory
```
On Windows "/Program Files (x86)/Steam/steamapps/common"
On Linux "$HOME/.local/share/Steam/steamapps/common"
```

All games are defined inside of 'config.vdf'.

To map for a different Source game or use it for custom levels, you must edit config.vdf and set the default_game appropriately
All paths for game configuration can be temporarily overridden with command line flags, use --help to see these.
If Rathammer fails to start, read through the console output and look for lines like this:
```
Failed to open directory Half-Life 2 in /tmp with error: error.FileNotFound
Set a custom cwd with --custom_cwd flag
```
Unless something horribly wrong happened (Windows builds can be finicky), RatHammer will usually give you good idea of why it can't start.

To load a vmf or json map you can use the --vmf flag, or you can select a map to load once the editor is started.

## Editing
Once you have successfully started RatHammer you will be greeted by a "pause menu", there are various global settings in here and documentation. Open and close the pause menu with 'Escape'
RatHammer was designed with 3D editing as the main form. There are 2d views but are relegated to speciality tasks that benefit from a orthographic view, such as alignment and selection of vertices in an axis aligned solid.
Navigation of the 3d view is done with the WASD keys the c key moves the camera down, and the space bar moves it up.
To un-capture the mouse cursor, hold the shift key

All keys can be remapped in the config.vdf file. By default all keys map to physical keys on the keyboard rather than symbols, so if you use a layout other than QWERTY, the keys are in the same place as they would be on a QWERTY layout. This behavior can be changed per key in the config.

## Selections
At any time, you can change the selection. To select an object put the cross-hair (or mouse cursor if you hold shift to uncapture) over an object and press 'E'.
To select more than one object, toggle the selection mode to 'many' using the tab key. 
In the top left corner of the 3d view there is information about the current selection and grid size etc.
To clear the current selection press ctrl+E
By having a separate key for selection, it means the mouse buttons can be used exclusively for object manipulation.

## How RatHammer specifies geometry.
Before you start editing it is important to understand how RatHammer stores brushes and what Source engine games expect of brushes.
Vmf and Bsp files store all brushes as a collection of intersecting planes. This forces any single brush to have certain properties:
* Be fully sealed or 'solid'.
* Be convex, I.E you can shrink wrap it without any air bubbles.
* No two faces can have the same normal.

The last one is important as it means you cannot cut a face in two, to texture it for example, without cutting the entire brush in two.

RatHammer stores and edits polygon meshes, more specifically, each brush is comprised of a set of vertices and 4 or more sides. Each side specifies a convex polygon by indexing into the vertices. RatHammer will not stop you from breaking the above rules, and will often allow you to export broken brushes to vmf, so be careful.

## Tools
At the bottom of the 3d view there is a row of tools, the active tool has a green border around it. Above each icon is the keybinding used to activate that tool.
Some tools may perform an action when you 'activate' that tool again.
On the right of the screen is the inspector. In the 'tools' tab you will find settings and documentation for the current tool.
Most tools require you to "commit" the action. This is done by right clicking. So if you drag a gizmo, you must right click, before letting go of left click, to commit that translation.

### Translate tool
Click and drag the gizmo to translate.
Clicking the white cube above the gizmo will toggle between and translation and rotation gizmo.
Clicking on any part of the selected brushes will let you do a "smart move" If your cursor is > 30 degrees from the horizon, the solid is moved in the xy plane. Otherwise, the solid is moved in the plane of the face you clicked on. 

### Face translate tool.
A Specialized tool for moving the faces of a single solid in an arbitrary direction. If more than one entity is selected it will draw a bounding box around all selected and allow you to scale them proportionally. 


## Workspaces
RatHammer has a few different workspaces.

* alt + 1       main 3d view
* alt + 2       main 2d view
* alt + t       texture browser
* alt + m       model browser


## Using RatHammer as a generic level editor.
See the folder rat_custom in the git repository for a minimal example.

## The console
Press the tilda key to toggle the console.

The help command shows a list of commands.

Use the console to: load pointfile, load portalfile, select all entities with a specific class "select_class prop_static"


## Lighting Preview
Rathammer has deferred renderer that can be used to preview light_environment (sunlight), light, and light_spot.

In the pause menu, change the "renderer" to "def". If you don't have a light_environment entity, the world will be bright white! If a map has more than one light_environment, rathammer uses the last one that was set. Change the class of the one you want to use to something else and change it back to light_environment, the values will not be lost, but it will then be the controller of the sunlight.

The renderer is far from perfect currently, and may need manual tuning to make the lighting match Source's.

Under the graphics tab in the pause menu, there are lots of parameters to tune.

If you are on an iGPU and have lots of lights on screen, the framerate may drop. You can increase performance significantly by lowering the resolution of the 3d viewport using the "res scale" slider under graphics. 

## The json map format
For up to date documentation, look at the src/json_map.JsonMap struct.
Every map object (brush, light, prop_static, etc) is given a numeric id. Each of these id's can optionally have some components attached to it. Some of the serialized components include: [solid, entity, displacements, key_values, connections ].
The "objects" key in the json map stores a list of these id's and the attached components for each.
Most data is serialized directly from rathammer, with little transformation, so if you are puzzled about the purpose of a field look at src/ecs.zig to see what it does.
Components:


solid: defines a brush. Has a set of verticies (Vec3) and a set of sides which each contain indexes into the set of verticies.

entity: lights, props, etc.

key_values: Stores a list of arbitrary key value pairs for entities.

connections: Used for source engine style entity input-output. See [valve developer wiki](https://developer.valvesoftware.com/wiki/VMF_(Valve_Map_Format)#Connections)


## The Ratmap format
.ratmap is a container around a json map.

The main reason for this is to compress the json, which usually compresses to 1/20th the size. In the future it will hold a thumbnail and other (optional) files for a map.

A .ratmap is just a [tar](https://en.wikipedia.org/wiki/Tar_(computing)) file containing: 
* map.json.gz -> A [gzipped](https://en.wikipedia.org/wiki/Gzip) json map.

Maps are always saved to .ratmap but vmf's, json's, ratmaps's can all be loaded by the editor.

### func_useableladder
This entity is really annoying, it is only used by hl2 and portal. 
When you translate a func_useableladder entity, the origin of the entity is synced with the point0 field (the start of the ladder)
The point1 field (end of the ladder) must be set manually. An orange helper outlining the ladders bounds is drawn, but the second part of the hull (point1) can not be manipulated in 3d.

