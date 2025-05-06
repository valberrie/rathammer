const std = @import("std");

// We could serial the map using the ecs

pub const Entity = struct {};

pub const Map = struct {
    pub const World = struct {
        entities: []Entity,
    };

    version: []const u8,
    world: World,
};
