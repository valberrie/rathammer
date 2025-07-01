const std = @import("std");
const edit = @import("editor.zig");
const Editor = edit.Context;
const Id = edit.EcsT.Id;
const graph = @import("graph");
const vpk = @import("vpk.zig");
const Vec3 = graph.za.Vec3;
const ecs = @import("ecs.zig");

//Stack based undo,
//we push operations onto the stack.
//undo calls undo on stack pointer and increments
//redo calls redo on stack poniter and decrements
//push clear anything after the stack pointer

/// Any operation which changes state of game world should implement iUndo.
/// See "UndoTemplate" for an example of implementation
pub const iUndo = struct {
    const Vt = @This();
    undo_fn: *const fn (*Vt, *Editor) void,
    redo_fn: *const fn (*Vt, *Editor) void,

    deinit_fn: *const fn (*Vt, std.mem.Allocator) void,

    pub fn undo(self: *Vt, editor: *Editor) void {
        self.undo_fn(self, editor);
    }

    pub fn redo(self: *Vt, editor: *Editor) void {
        self.redo_fn(self, editor);
    }

    pub fn deinit(self: *Vt, alloc: std.mem.Allocator) void {
        self.deinit_fn(self, alloc);
    }
};

pub const UndoGroup = struct {
    description: []const u8,
    items: std.ArrayList(*iUndo),

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.description);
        for (self.items.items) |vt|
            vt.deinit(alloc);
        self.items.deinit();
    }
};

pub const UndoContext = struct {
    const Self = @This();

    stack: std.ArrayList(UndoGroup),
    stack_pointer: usize,

    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .stack_pointer = 0,
            .stack = std.ArrayList(UndoGroup).init(alloc),
            .alloc = alloc,
        };
    }

    /// The returned array list should be treated as a stack.
    /// Each call to UndoContext.undo/redo will apply all the items in the arraylist at index stack_pointer.
    /// That is, the last item appended is the first item undone and the last redone.
    pub fn pushNew(self: *Self) !*std.ArrayList(*iUndo) {
        return try self.pushNewFmt("GenericUndo", .{});
    }

    pub fn pushNewFmt(self: *Self, comptime fmt: []const u8, args: anytype) !*std.ArrayList(*iUndo) {
        var desc = std.ArrayList(u8).init(self.alloc);
        try desc.writer().print(fmt, args);
        if (self.stack_pointer > self.stack.items.len)
            self.stack_pointer = self.stack.items.len; // Sanity

        for (self.stack.items[self.stack_pointer..]) |*item| {
            item.deinit(self.alloc);
            //for (item.items) |it|
            //    it.deinit(self.alloc);
            //item.deinit();
        }
        try self.stack.resize(self.stack_pointer); //Discard any
        self.stack_pointer += 1;
        const vec = std.ArrayList(*iUndo).init(self.alloc);
        const new_group = UndoGroup{
            .items = vec,
            .description = try desc.toOwnedSlice(),
        };
        try self.stack.append(new_group);
        return &self.stack.items[self.stack.items.len - 1].items;
    }

    pub fn undo(self: *Self, editor: *Editor) void {
        if (self.stack_pointer > self.stack.items.len or self.stack_pointer == 0) //What
            return;
        self.stack_pointer -= 1;
        const ar = self.stack.items[self.stack_pointer];
        var i = ar.items.items.len;
        while (i > 0) : (i -= 1) {
            ar.items.items[i - 1].undo(editor);
        }
        editor.notify("undo: {s}", .{ar.description}, 0xFF8C00ff) catch return;
    }

    pub fn redo(self: *Self, editor: *Editor) void {
        if (self.stack_pointer >= self.stack.items.len) return; //What to do?
        defer self.stack_pointer += 1;

        const th = self.stack.items[self.stack_pointer];
        applyRedo(th.items.items, editor);
        editor.notify("redo: {s}", .{th.description}, 0x8FBC_8F_ff) catch return;
    }

    pub fn deinit(self: *Self) void {
        for (self.stack.items) |*item| {
            item.deinit(self.alloc);
        }
        self.stack.deinit();
    }
};
///Rather than manually applying the operations when pushing a undo item,
///just call applyRedo on the stack you created.
pub fn applyRedo(list: []const *iUndo, editor: *Editor) void {
    for (list) |item|
        item.redo(editor);
}

pub const SelectionUndo = struct {
    pub const Kind = enum { select, deselect };
    vt: iUndo,

    kind: Kind,
    id: Id,

    pub fn create(alloc: std.mem.Allocator, kind: Kind, id: Id) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .id = id,
            .kind = kind,
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        switch (self.kind) {
            .select => editor.selection.single_id = null,
            .deselect => editor.selection.single_id = self.id,
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        switch (self.kind) {
            .select => editor.selection.single_id = self.id,
            .deselect => editor.selection.single_id = null,
        }
    }
    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        alloc.destroy(self);
    }
};

pub const UndoTranslate = struct {
    vt: iUndo,

    vec: Vec3,
    angle_delta: Vec3,
    id: Id,

    pub fn create(alloc: std.mem.Allocator, vec: Vec3, angle_delta: ?Vec3, id: Id) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vec = vec,
            .angle_delta = angle_delta orelse Vec3.zero(),
            .id = id,
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid|
            solid.translate(self.id, self.vec.scale(-1), editor) catch return;
        if (editor.ecs.getOptPtr(self.id, .entity) catch return) |ent| {
            const bb = editor.ecs.getPtr(self.id, .bounding_box) catch return;
            ent.origin = ent.origin.add(self.vec.scale(-1));
            ent.angle = ent.angle.sub(self.angle_delta);
            bb.setFromOrigin(ent.origin);
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid|
            solid.translate(self.id, self.vec, editor) catch return;
        if (editor.ecs.getOptPtr(self.id, .entity) catch return) |ent| {
            const bb = editor.ecs.getPtr(self.id, .bounding_box) catch return;
            ent.origin = ent.origin.add(self.vec);
            ent.angle = ent.angle.add(self.angle_delta);
            bb.setFromOrigin(ent.origin);
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoDupeDeprecated = struct {
    vt: iUndo,

    parent_id: Id,
    own_id: Id,

    pub fn create(alloc: std.mem.Allocator, parent_id: Id, own_id: Id) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .parent_id = parent_id,
            .own_id = own_id,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        editor.ecs.destroyEntity(self.own_id) catch return;
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        inline for (ecs.EcsT.Fields, 0..) |field, i| {
            if (editor.ecs.getOptPtr(self.parent_id, @enumFromInt(i)) catch return) |comp| {
                if (@hasDecl(field.ftype, "dupe")) {
                    const duped = comp.dupe(&editor.ecs, self.own_id) catch return;
                    editor.ecs.attachComponentAndCreate(self.own_id, @enumFromInt(i), duped) catch return;
                } else {
                    @compileError("must declare a dupe(self) function ! " ++ field.name);
                }
            }
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoVertexTranslate = struct {
    vt: iUndo,

    id: Id,
    offset: Vec3,
    vert_indicies: []const u32,

    pub fn create(alloc: std.mem.Allocator, id: Id, offset: Vec3, vert_index: []const u32) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .id = id,
            .offset = offset,
            .vert_indicies = try alloc.dupe(u32, vert_index),
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateVerts(self.id, self.offset.scale(-1), editor, self.vert_indicies) catch return;
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateVerts(self.id, self.offset, editor, self.vert_indicies) catch return;
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.free(self.vert_indicies);
        alloc.destroy(self);
    }
};

//TODO deprecate, use UndoVertexTranslate
pub const UndoSolidFaceTranslate = struct {
    vt: iUndo,

    id: Id,
    side_id: usize,
    offset: Vec3,

    pub fn create(alloc: std.mem.Allocator, id: Id, side_id: usize, offset: Vec3) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .id = id,
            .side_id = side_id,
            .offset = offset,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateSide(self.id, self.offset.scale(-1), editor, self.side_id) catch return;
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateSide(self.id, self.offset, editor, self.side_id) catch return;
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

/// Rather than actually creating/deleting entities, this just unsleeps/sleeps them
/// On map serial, slept entities are omitted
/// Sleep/unsleep is idempotent so no need to sleep before calling applyAll
pub const UndoCreateDestroy = struct {
    pub const Kind = enum { create, destroy };
    vt: iUndo,

    id: Id,
    /// are we undoing a creation, or a destruction
    kind: Kind,

    pub fn create(alloc: std.mem.Allocator, id: Id, kind: Kind) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .id = id,
            .kind = kind,
        };
        return &obj.vt;
    }

    fn undoCreate(self: *@This(), editor: *Editor) !void {
        if (try editor.ecs.getOptPtr(self.id, .solid)) |solid| {
            try solid.removeFromMeshMap(self.id, editor);
        }
        editor.ecs.attach(self.id, .deleted, .{}) catch {};
        //try editor.ecs.sleepEntity(self.id);
    }

    fn redoCreate(self: *@This(), editor: *Editor) !void {
        _ = editor.ecs.removeComponentOpt(self.id, .deleted) catch {};
        //editor.ecs.attach(self.id, .deleted, .{}) catch {};
        if (try editor.ecs.getOptPtr(self.id, .solid)) |solid| {
            try solid.rebuild(self.id, editor);
        }
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (self.kind) {
            .create => self.undoCreate(editor) catch return,
            .destroy => self.redoCreate(editor) catch return,
        }
    }

    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (self.kind) {
            .destroy => self.undoCreate(editor) catch return,
            .create => self.redoCreate(editor) catch return,
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoTextureManip = struct {
    pub const State = struct {
        u: ecs.Side.UVaxis,
        v: ecs.Side.UVaxis,
        tex_id: vpk.VpkResId,
    };

    id: Id,
    face_id: u32,
    vt: iUndo,
    old: State,
    new: State,

    pub fn create(alloc: std.mem.Allocator, old: State, new: State, id: Id, face_id: u32) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .old = old,
            .new = new,
            .id = id,
            .face_id = face_id,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.set(self.old, editor) catch return;
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.set(self.new, editor) catch return;
    }

    fn set(self: *@This(), new: State, editor: *Editor) !void {
        if (try editor.ecs.getOptPtr(self.id, .solid)) |solid| {
            if (self.face_id >= solid.sides.items.len) return;
            const side = &solid.sides.items[self.face_id];
            side.u = new.u;
            side.v = new.v;
            if (new.tex_id != side.tex_id) {
                try solid.removeFromMeshMap(self.id, editor);
            }
            side.tex_id = new.tex_id;
            try solid.rebuild(self.id, editor);
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoChangeGroup = struct {
    const GroupId = ecs.Groups.GroupId;
    vt: iUndo,

    old: GroupId,
    new: GroupId,
    id: Id,

    pub fn create(alloc: std.mem.Allocator, old: GroupId, new: GroupId, id: Id) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .old = old,
            .new = new,
            .id = id,
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        setGroup(editor, self.id, self.old) catch return;
    }

    fn setGroup(editor: *Editor, id: Id, new_group: GroupId) !void {
        if (try editor.ecs.getOptPtr(id, .group)) |group| {
            group.id = new_group;
        } else {
            try editor.ecs.attach(id, .group, .{ .id = new_group });
        }
    }

    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        setGroup(editor, self.id, self.new) catch return;
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

/// This is a noop
pub const UndoTemplate = struct {
    vt: iUndo,

    pub fn create(alloc: std.mem.Allocator) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        _ = editor;
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        _ = editor;
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};
