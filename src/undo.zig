const std = @import("std");
const edit = @import("editor.zig");
const Editor = edit.Context;
const Id = edit.EcsT.Id;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;

//Stack based undo,
//we push operations onto the stack.
//undo calls undo on stack pointer and increments
//redo calls redo on stack poniter and decrements
//push clear anything after the stack pointer

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

pub const UndoContext = struct {
    const Self = @This();
    stack: std.ArrayList(std.ArrayList(*iUndo)),
    stack_pointer: usize,

    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .stack_pointer = 0,
            .stack = std.ArrayList(std.ArrayList(*iUndo)).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn pushNew(self: *Self) !*std.ArrayList(*iUndo) {
        if (self.stack_pointer > self.stack.items.len)
            self.stack_pointer = self.stack.items.len; // Sanity

        for (self.stack.items[self.stack_pointer..]) |item| {
            for (item.items) |it|
                it.deinit(self.alloc);
            item.deinit();
        }
        try self.stack.resize(self.stack_pointer); //Discard any
        self.stack_pointer += 1;
        const vec = std.ArrayList(*iUndo).init(self.alloc);
        try self.stack.append(vec);
        return &self.stack.items[self.stack.items.len - 1];
    }

    pub fn undo(self: *Self, editor: *Editor) void {
        if (self.stack_pointer > self.stack.items.len or self.stack_pointer == 0) //What
            return;
        self.stack_pointer -= 1;
        const ar = self.stack.items[self.stack_pointer].items;
        var i = ar.len;
        while (i > 0) : (i -= 1) {
            ar[i - 1].undo(editor);
        }
    }

    pub fn redo(self: *Self, editor: *Editor) void {
        if (self.stack_pointer >= self.stack.items.len) return; //What to do?
        defer self.stack_pointer += 1;

        applyRedo(self.stack.items[self.stack_pointer].items, editor);
    }

    pub fn deinit(self: *Self) void {
        for (self.stack.items) |item| {
            for (item.items) |it|
                it.deinit(self.alloc);
            item.deinit();
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
            .select => editor.edit_state.id = null,
            .deselect => editor.edit_state.id = self.id,
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        switch (self.kind) {
            .select => editor.edit_state.id = self.id,
            .deselect => editor.edit_state.id = null,
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
    id: Id,

    pub fn create(alloc: std.mem.Allocator, vec: Vec3, id: Id) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vec = vec,
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
            bb.setFromOrigin(ent.origin);
        }
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
        const self: *@This() = @fieldParentPtr("vt", vt);
        _ = self;
        _ = editor;
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        _ = self;
        _ = editor;
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        alloc.destroy(self);
    }
};
