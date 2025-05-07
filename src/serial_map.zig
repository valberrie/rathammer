const std = @import("std");

// We could serial the map using the ecs
// the more 1:1 the representaion is the better.

//Solid is well defined except for side.tex_id, which needs to be converted back into a path
//indexs does not *need* to be serialized.
//
//entity aswell, same thing with the ids.

pub const Entity = struct {};

pub const Map = struct {
    pub const World = struct {
        entities: []Entity,
    };

    version: []const u8,
    world: World,
};
