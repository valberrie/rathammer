const std = @import("std");
const graph = @import("graph");
const Gui = graph.Gui;
const ecs = @import("ecs.zig");
const fgd = @import("fgd.zig");
const Editor = @import("editor.zig").Context;
const Os9Gui = graph.Os9Gui;
const eql = std.mem.eql;

pub fn classCombo(os9gui: *Os9Gui, ent: *ecs.Entity, editor: *Editor) !void {
    const Ctx = struct {
        fgdctx: *fgd.EntCtx,
        index: usize = 0,

        pub fn next(ctx: *@This()) ?struct { usize, []const u8 } {
            if (ctx.index >= ctx.fgdctx.ents.items.len)
                return null;
            defer ctx.index += 1;
            return .{ ctx.index, ctx.fgdctx.ents.items[ctx.index].name };
        }
    };
    const old_i = editor.fgd_ctx.getId(ent.class) orelse 0;
    if (old_i >= editor.fgd_ctx.ents.items.len)
        return;
    var index = old_i;
    var ctx = Ctx{ .fgdctx = &editor.fgd_ctx };
    try os9gui.combo(
        "{s}",
        .{ent.class},
        &index,
        editor.fgd_ctx.ents.items.len,
        &ctx,
        Ctx.next,
    );
    if (index != old_i) {
        try ent.setClass(editor, editor.fgd_ctx.nameFromId(index) orelse ent.class);
    }
}

pub fn drawInspector(self: *Editor, screen_area: graph.Rect, os9gui: *graph.Os9Gui) !void {
    if (try os9gui.beginTlWindow(screen_area)) {
        defer os9gui.endTlWindow();
        const gui = &os9gui.gui;
        if (gui.getArea()) |win_area| {
            const area = win_area.inset(6 * os9gui.scale);
            _ = try gui.beginLayout(Gui.SubRectLayout, .{ .rect = area }, .{});
            defer gui.endLayout();

            //_ = try os9gui.beginH(2);
            //defer os9gui.endL();
            if (try os9gui.beginVScroll(&self.misc_gui_state.scroll_a, .{ .sw = area.w, .sh = 1000000 })) |scr| {
                defer os9gui.endVScroll(scr);
                if (self.getCurrentTool()) |tool| {
                    if (tool.guiDoc_fn) |gd| gd(tool, os9gui, self, scr.layout);
                    if (tool.gui_fn) |gf| gf(tool, os9gui, self, scr.layout);
                }
                //os9gui.label("Current Tool: {s}", .{@tagName(self.edit_state.state)});
                if (self.selection.getGroupOwnerExclusive(&self.groups)) |id| {
                    if (try self.ecs.getOptPtr(id, .entity)) |ent| {
                        try classCombo(os9gui, ent, self);

                        if (os9gui.button("force populate kvs")) {
                            if (self.fgd_ctx.getPtr(ent.class)) |base| {
                                const kvs = if (try self.ecs.getOptPtr(id, .key_values)) |kv| kv else blk: {
                                    try self.ecs.attach(id, .key_values, ecs.KeyValues.init(self.alloc));
                                    break :blk try self.ecs.getPtr(id, .key_values);
                                };
                                for (base.fields.items) |field| {
                                    var new_list = std.ArrayList(u8).init(self.alloc);
                                    try new_list.appendSlice(field.default);
                                    if (kvs.map.getPtr(field.name)) |old|
                                        old.deinit();
                                    try kvs.map.put(field.name, .{ .string = new_list });
                                }
                            }
                        }
                        const kvs = if (try self.ecs.getOptPtr(id, .key_values)) |kv| kv else blk: {
                            try self.ecs.attach(id, .key_values, ecs.KeyValues.init(self.alloc));
                            break :blk try self.ecs.getPtr(id, .key_values);
                        };
                        {
                            os9gui.hr();
                            if (self.fgd_ctx.getPtr(ent.class)) |base| {
                                const ITEM_HEIGHT = os9gui.style.config.default_item_h;
                                scr.layout.pushHeight(ITEM_HEIGHT * @as(f32, @floatFromInt(base.fields.items.len)));

                                _ = try os9gui.beginL(Gui.TableLayout{
                                    .columns = 2,

                                    .item_height = ITEM_HEIGHT,
                                });
                                for (base.fields.items) |req_field| {
                                    const res = try kvs.map.getOrPut(req_field.name);
                                    if (!res.found_existing) {
                                        var new_list = std.ArrayList(u8).init(self.alloc);
                                        try new_list.appendSlice(req_field.default);
                                        res.value_ptr.* = .{ .string = new_list };
                                    }
                                    os9gui.label("{s}", .{res.key_ptr.*});
                                    switch (req_field.type) {
                                        .choices => |ch| {
                                            if (res.value_ptr.* == .string)
                                                try doChoices(ch, os9gui, &res.value_ptr.string);
                                        },
                                        .angle => {
                                            try res.value_ptr.toFloats(3);
                                            _ = try os9gui.beginH(3);
                                            defer os9gui.endL();

                                            const a = &res.value_ptr.floats;

                                            try os9gui.textboxNumber(&a.d[0]);
                                            try os9gui.textboxNumber(&a.d[1]);
                                            try os9gui.textboxNumber(&a.d[2]);
                                        },
                                        .color255 => {
                                            _ = os9gui.gui.isFocused();
                                            _ = try os9gui.beginH(2);
                                            defer os9gui.endL();
                                            try res.value_ptr.toFloats(4);
                                            const color = &res.value_ptr.floats.d;
                                            const old_hsva = graph.ptypes.colorToHsva(
                                                .{
                                                    .r = @intFromFloat(std.math.clamp(color[0], 0, 255)),
                                                    .g = @intFromFloat(std.math.clamp(color[1], 0, 255)),
                                                    .b = @intFromFloat(std.math.clamp(color[2], 0, 255)),
                                                    .a = 255,
                                                },
                                            );
                                            var hsva = old_hsva;
                                            try os9gui.colorPicker(&hsva);
                                            if (!std.mem.eql(u8, std.mem.asBytes(&old_hsva), std.mem.asBytes(&hsva))) {
                                                const col = graph.ptypes.hsvaToColor(hsva);
                                                color[0] = @floatFromInt(col.r);
                                                color[1] = @floatFromInt(col.g);
                                                color[2] = @floatFromInt(col.b);
                                            }

                                            try os9gui.textboxNumber(&color[3]);
                                        },
                                        .material => {
                                            //TODO ensure it is a string
                                            _ = try os9gui.beginH(2);
                                            defer os9gui.endL();
                                            if (os9gui.button("Select")) {}
                                            try os9gui.textbox(&res.value_ptr.string);
                                        },
                                        .model => {
                                            _ = try os9gui.beginH(2);
                                            defer os9gui.endL();
                                            if (os9gui.button("Select")) {
                                                self.asset_browser.dialog_state = .{
                                                    .target_id = id,
                                                    .previous_pane_index = self.draw_state.tab_index,
                                                    .kind = .model,
                                                };
                                                self.draw_state.tab_index = self.draw_state.model_browser_tab_index;
                                            }
                                            try os9gui.textbox(&res.value_ptr.string);
                                        },
                                        .generic, .flags => {
                                            switch (res.value_ptr.*) {
                                                .string => try os9gui.textbox(&res.value_ptr.string),
                                                else => os9gui.label("", .{}),
                                            }
                                        },
                                    }
                                }
                            }
                            os9gui.endL();
                        }
                    }
                }
            }
            {
                _ = try os9gui.beginV();
                defer os9gui.endL();
                //try os9gui.textbox2(&textbox, .{});

                //os9gui.gui.drawText(displayed_slice.items, ar.pos(), 40, 0xff, os9gui.font);
            }
        }
    }
}

pub fn doChoices(ch: anytype, os9gui: *Os9Gui, value: *std.ArrayList(u8)) !void {
    if (ch.items.len == 0)
        return;
    if (ch.items.len == 2 and std.mem.eql(u8, ch.items[0][0], "0")) {
        var checked: bool = !eql(u8, value.items, ch.items[0][0]);
        if (os9gui.checkbox("", &checked)) {
            const index: usize = if (checked) 1 else 0;
            value.clearRetainingCapacity();
            try value.appendSlice(ch.items[index][0]);
        }

        return;
    }
    const Ctx = struct {
        kvs: []const fgd.EntClass.Field.Type.KV,
        index: usize = 0,
        pub fn next(ctx: *@This()) ?struct { usize, []const u8 } {
            if (ctx.index >= ctx.kvs.len)
                return null;
            defer ctx.index += 1;
            return .{ ctx.index, ctx.kvs[ctx.index][1] };
        }
    };

    var index: usize = 0;
    for (ch.items, 0..) |kv, i| {
        if (eql(u8, kv[0], value.items)) {
            index = i;
            break;
        }
    }
    var ctx = Ctx{
        .kvs = ch.items,
    };
    const old_i = index;
    //TODO Check kvs is > 0
    try os9gui.combo(
        "{s}",
        .{ch.items[old_i][1]},
        &index,
        ch.items.len,
        &ctx,
        Ctx.next,
    );
    if (old_i != index) {
        value.clearRetainingCapacity();
        try value.appendSlice(ch.items[index][0]);
        //std.debug.print("Index changed new {s} -> {any}\n", .{ res.value_ptr.items, ch.items[index] });
    }
}
