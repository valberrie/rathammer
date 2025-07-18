const graph = @import("graph");
const std = @import("std");
const DrawCtx = graph.ImmediateDrawingContext;
const Editor = @import("editor.zig").Context;

pub const ViewDrawState = struct {
    camstate: graph.ptypes.Camera3D.MoveState,
    draw: *DrawCtx,
    win: *graph.SDL.Window,
};

pub const iPane = struct {
    /// Called on every frame
    draw_fn: ?*const fn (*iPane, graph.Rect, *Editor, ViewDrawState, PaneId) void = null,
    deinit_fn: *const fn (*iPane, std.mem.Allocator) void,
};

pub const PaneId = usize;
pub const PaneReg = struct {
    const Self = @This();

    panes: std.ArrayList(*iPane),
    // Indicies into panes
    map: std.AutoHashMap(*iPane, PaneId),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .alloc = alloc,
            .panes = std.ArrayList(*iPane).init(alloc),
            .map = std.AutoHashMap(*iPane, PaneId).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.panes.items) |pane| {
            pane.deinit_fn(pane, self.alloc);
        }
        self.panes.deinit();
        self.map.deinit();
    }

    pub fn add(self: *Self, pane: *iPane) !PaneId {
        if (self.map.contains(pane)) {
            return error.alreadyPut;
        }

        const id = self.panes.items.len;
        try self.panes.append(pane);
        try self.map.put(pane, id);
        return id;
    }

    pub fn get(self: *Self, id: PaneId) ?*iPane {
        if (id >= self.panes.items.len) return null;
        return self.panes.items[id];
    }
};

pub const GuiPane = struct {
    const Self = @This();
    const guis = graph.RGui;
    const Gui = guis.Gui;
    vt: iPane,
    gui_ptr: *Gui,

    window_vt: *guis.iWindow,

    pub fn create(alloc: std.mem.Allocator, gui: *Gui, win: *guis.iWindow) !*iPane {
        var ret = try alloc.create(@This());
        ret.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .draw_fn = &draw_fn,
            },
            .window_vt = win,
            .gui_ptr = gui,
        };
        return &ret.vt;
    }

    pub fn draw_fn(vt: *iPane, screen_area: graph.Rect, editor: *Editor, _: ViewDrawState, pane_id: PaneId) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.gui_ptr.window_collector.append(self.window_vt) catch return;
        self.gui_ptr.updateWindowSize(self.window_vt, screen_area) catch return;
        if (editor.draw_state.grab_pane.owns(pane_id)) {
            self.gui_ptr.update(&.{self.window_vt}) catch return;
        }
    }

    pub fn deinit(vt: *iPane, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};
