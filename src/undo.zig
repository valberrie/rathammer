const std = @import("std");
const edit = @import("editor.zig");
const Editor = edit.Context;

//Stack based undo,
//we push operations onto the stack.
//undo calls undo on stack pointer and increments
//redo calls redo on stack poniter and decrements
//push clear anything after the stack pointer

pub const iUndo = struct {
    const Vt = @This();
    undo_fn: *const fn (*Vt, *Editor) void,
    redo_fn: *const fn (*Vt, *Editor) void,
};

pub const UndoContext = struct {};
