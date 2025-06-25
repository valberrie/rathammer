const std = @import("std");
const graph = @import("graph");
const Gui = guis.Gui;
const ecs = @import("../ecs.zig");
const Rec = graph.Rec;
const Rect = graph.Rect;
const DrawState = guis.DrawState;
const GuiHelp = guis.GuiHelp;
const guis = graph.RGui;
const iWindow = guis.iWindow;
const iArea = guis.iArea;
const Wg = guis.Widget;
const Context = @import("../editor.zig").Context;
//TODO
// to get this to work we need to first add a getptr cb to all existing
// widgets and use that to obtain our values.
// second, we need an 'onUpdate' that lets us check if we need to rebuild by comparing
// old selection to new for example.
// or, we have the editor.selection emit an event.
pub const InspectorWindow = struct {
    const Self = @This();
    vt: iWindow,
    area: iArea,

    editor: *Context,
    selected_kv_index: usize = 0,
    kv_scroll_index: usize = 0,

    kv_id_map: std.AutoHashMap(usize, []const u8),
    kv_id_index: usize = 0,

    str: []const u8 = "ass",

    pub fn create(gui: *Gui, editor: *Context) *InspectorWindow {
        const self = gui.create(@This());
        self.* = .{
            .area = iArea.init(gui, Rec(0, 0, 0, 0)),
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .editor = editor,
            .kv_id_map = std.AutoHashMap(usize, []const u8).init(gui.alloc),
        };
        self.area.draw_fn = &draw;
        self.area.deinit_fn = &area_deinit;

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        self.kv_id_map.deinit();
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    fn resetIds(self: *Self) void {
        self.kv_id_map.clearRetainingCapacity();
        self.kv_id_index = 0;
    }

    /// name must be owned by someone else, probably editor.stringstorage
    fn getId(self: *Self, name: []const u8) usize {
        const id = self.kv_id_index;
        self.kv_id_index += 1;
        self.kv_id_map.put(id, name) catch return id;
        return id;
    }

    fn getNameFromId(self: *Self, id: usize) ?[]const u8 {
        return self.kv_id_map.get(id);
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.area.area = area;
        self.area.clearChildren(gui, vt);
        self.area.dirty(gui);
        //self.layout.reset(gui, vt);
        //start a vlayout
        //var ly = Vert{ .area = vt.area };
        const max_w = gui.style.config.default_item_h * 30;
        const inset = GuiHelp.insetAreaForWindowFrame(gui, vt.area.area);
        const w = @min(max_w, inset.w);
        var ly = guis.VerticalLayout{
            .padding = .{},
            .item_height = gui.style.config.default_item_h,
            .bounds = Rec(inset.x, inset.y, w, inset.h),
        };
        ly.padding.left = 10;
        ly.padding.right = 10;
        ly.padding.top = 10;
        const a = &self.area;

        const ds = &self.editor.draw_state;
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "draw tools", .{ .bool_ptr = &ds.tog.tools }, null));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "draw sprite", .{ .bool_ptr = &ds.tog.sprite }, null));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "draw models", .{ .bool_ptr = &ds.tog.models }, null));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "ignore groups", .{ .bool_ptr = &self.editor.selection.ignore_groups }, null));

        self.buildErr(gui, &ly) catch {};

        //a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), &self.bool2, "secnd button"));
        //a.addChildOpt(gui, vt, Wg.StaticSlider.build(gui, ly.getArea(), 4, 0, 10));
        //a.addChild(gui, vt, Wg.Combo(MyEnum).build(gui, ly.getArea() orelse return, &self.my_enum));
        //a.addChild(gui, vt, Wg.Combo(std.fs.File.Kind).build(gui, ly.getArea() orelse return, &self.fenum));

        //a.addChildOpt(gui, vt, Wg.Button.build(gui, ly.getArea(), "My button 2", null, null, 48));
        //a.addChildOpt(gui, vt, Wg.Button.build(gui, ly.getArea(), "My button 3", null, null, 48));
        //a.addChild(gui, vt, Wg.Colorpicker.build(gui, ly.getArea() orelse return, &self.color));

        //a.addChildOpt(gui, vt, Wg.Textbox.build(gui, ly.getArea()));
        //a.addChildOpt(gui, vt, Wg.Textbox.build(gui, ly.getArea()));
        //a.addChildOpt(gui, vt, Wg.TextboxNumber.build(gui, ly.getArea(), &self.number, vt));
        //a.addChildOpt(gui, vt, Wg.Slider.build(gui, ly.getArea(), &self.i32_n, -10, 10, .{}));
        //a.addChildOpt(gui, vt, Wg.Slider.build(gui, ly.getArea(), &self.i32_n, 0, 10, .{}));

        //ly.pushRemaining();
        //a.addChildOpt(gui, vt, Wg.VScroll.build(
        //    gui,
        //    ly.getArea(),
        //    &buildScrollItems,
        //    &self.area,
        //    vt,
        //    10,
        //    gui.style.config.default_item_h,
        //));
    }

    fn buildErr(self: *@This(), gui: *Gui, ly: anytype) !void {
        const ed = self.editor;
        const a = &self.area;
        const win = &self.vt;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id| {
            if (try ed.ecs.getOptPtr(sel_id, .entity)) |ent| {
                const aa = ly.getArea() orelse return;
                const Lam = struct {
                    fn commit(vtt: *iArea, id: usize) void {
                        const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                        const fields = lself.editor.fgd_ctx.ents.items;
                        lself.vt.needs_rebuild = true;
                        if (id >= fields.len) return;
                        const led = lself.editor;
                        if (led.selection.getGroupOwnerExclusive(&led.groups)) |lsel_id| {
                            if (led.ecs.getOptPtr(lsel_id, .entity) catch null) |lent| {
                                lent.setClass(led, fields[id].name) catch return;
                            }
                        }
                    }

                    fn name(vtt: *iArea, id: usize, _: *Gui) []const u8 {
                        const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                        const fields = lself.editor.fgd_ctx.ents.items;
                        if (id >= fields.len) return "BROKEN";
                        return fields[id].name;
                    }
                };
                a.addChildOpt(gui, win, Wg.ComboUser.build(gui, aa, .{
                    .user_vt = &self.area,
                    .commit_cb = &Lam.commit,
                    .name_cb = &Lam.name,
                    .current = ed.fgd_ctx.getId(ent.class) orelse 0,
                    .count = self.editor.fgd_ctx.ents.items.len,
                }));
                a.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ly.getArea(), .{ .init_string = ent.class }));
                const eclass = ed.fgd_ctx.getPtr(ent.class) orelse return;
                const fields = eclass.field_data.items;
                ly.pushRemaining();
                a.addChildOpt(gui, win, Wg.VScroll.build(gui, ly.getArea(), .{
                    .build_cb = &buildScrollItems,
                    .build_vt = a,
                    .win = win,
                    .count = fields.len,
                    .item_h = gui.style.config.default_item_h,
                    .index_ptr = &self.kv_scroll_index,
                }));
            }
        }
    }

    pub fn buildScrollItems(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        buildScrollItemsErr(window_area, vt, index, gui, win) catch return;
    }

    pub fn getKvsPtr(self: *Self) ?*ecs.KeyValues {
        const ed = self.editor;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id|
            return (ed.ecs.getOptPtr(sel_id, .key_values) catch null);
        return null;
    }

    pub fn buildScrollItemsErr(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, _: *iWindow) !void {
        var time = std.time.Timer.start() catch return;
        const self: *@This() = @alignCast(@fieldParentPtr("area", window_area));
        self.resetIds();
        var ly = guis.TableLayout{ .item_height = gui.style.config.default_item_h, .bounds = vt.area, .columns = 2 };
        const ed = self.editor;
        const a = vt;
        const win = &self.vt;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id| {
            if (ed.ecs.getOptPtr(sel_id, .entity) catch null) |ent| {
                const eclass = ed.fgd_ctx.getPtr(ent.class) orelse return;
                const fields = eclass.field_data.items;
                if (index >= fields.len) return;
                const kvs = if (try ed.ecs.getOptPtr(sel_id, .key_values)) |kv| kv else blk: {
                    try ed.ecs.attach(sel_id, .key_values, ecs.KeyValues.init(ed.alloc));
                    break :blk try ed.ecs.getPtr(sel_id, .key_values);
                };
                for (fields[index..], index..) |req_f, f_i| {
                    const cb_id = self.getId(req_f.name);
                    a.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), req_f.name, .{
                        .cb_vt = window_area,
                        .cb_fn = &select_kv_cb,
                        .id = f_i,
                        .custom_draw = &customButtonDraw,
                        .user_1 = if (self.selected_kv_index == f_i) 1 else 0,
                    }));
                    const res = try kvs.map.getOrPut(req_f.name);
                    if (!res.found_existing) {
                        var new_list = std.ArrayList(u8).init(ed.alloc);
                        try new_list.appendSlice(req_f.default);
                        res.value_ptr.* = .{ .string = new_list };
                    }
                    switch (req_f.type) {
                        .choices => |ch| {
                            const ar = ly.getArea();
                            try res.value_ptr.toString(kvs.map.allocator);
                            if (ch.items.len == 0) continue;
                            if (ch.items.len == 2 and std.mem.eql(u8, ch.items[0][0], "0")) {
                                const checked = !std.mem.eql(u8, res.value_ptr.string.items, ch.items[0][0]);
                                a.addChildOpt(gui, win, Wg.Checkbox.build(gui, ar, "", .{
                                    .cb_fn = &cb_commitCheckbox,
                                    .cb_vt = win.area,
                                    .user_id = cb_id,
                                }, checked));
                            }
                        },
                        .color255 => {
                            try res.value_ptr.toFloats(4);
                            const ar = ly.getArea() orelse return;
                            const sp = ar.split(.vertical, ar.w / 2);
                            const c = &res.value_ptr.floats.d;
                            const color = graph.ptypes.intColorFromVec3(graph.za.Vec3.new(c[0], c[1], c[2]), 1);
                            a.addChildOpt(gui, win, Wg.Colorpicker.build(gui, sp[0], color, .{
                                .user_id = cb_id,
                                .commit_vt = win.area,
                                .commit_cb = &cb_commitColor,
                            }));

                            a.addChildOpt(gui, win, Wg.TextboxNumber.build(gui, sp[1], c[3], win, .{
                                .user_id = cb_id,
                                .commit_cb = &setBrightness,
                                .commit_vt = win.area,
                                //.init_string = ed.printScratch("{d}", .{c[3]}) catch "100",
                            }));
                        },
                        else => {
                            const ar = ly.getArea();
                            switch (res.value_ptr.*) {
                                .string => |s| {
                                    a.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ar, .{
                                        .init_string = s.items,
                                        .user_id = cb_id,
                                        .commit_vt = win.area,
                                        .commit_cb = &cb_commitTextbox,
                                    }));
                                },
                                .floats => {},
                            }
                        },
                    }
                }
            }
        }
        std.debug.print("Built scroll in: {d:.2} us\n", .{time.read() / std.time.ns_per_us});
    }

    fn setBrightness(this_w: *iArea, _: *Gui, value: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_w));
        if (self.getNameFromId(id)) |field_name| {
            const kvs = self.getKvsPtr() orelse return;
            if (kvs.map.getPtr(field_name)) |ptr| {
                switch (ptr.*) {
                    .string => {},
                    .floats => {
                        if (ptr.floats.count == 4) {
                            ptr.floats.d[3] = std.fmt.parseFloat(f32, value) catch return;
                        }
                    },
                }
            }
        }
    }

    fn setKvStr(self: *Self, id: usize, value: []const u8) void {
        if (self.getNameFromId(id)) |field_name| {
            const kvs = self.getKvsPtr() orelse return;
            kvs.putString(field_name, value) catch return;
        }
    }

    fn setKvFloat(self: *Self, id: usize, floats: []const f32) void {
        if (floats.len > 4) return;
        if (self.getNameFromId(id)) |field_name| {
            const kvs = self.getKvsPtr() orelse return;
            if (kvs.map.getPtr(field_name)) |ptr| {
                switch (ptr.*) {
                    .string => {},
                    .floats => {
                        ptr.floats.count = @intCast(floats.len);
                        @memcpy(ptr.floats.d[0..floats.len], floats);
                    },
                }
            }
        }
    }

    pub fn cb_commitColor(this_w: *iArea, _: *Gui, val: u32, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_w));
        const charc = graph.ptypes.intToColor(val);
        if (self.getNameFromId(id)) |field_name| {
            const kvs = self.getKvsPtr() orelse return;
            const old = kvs.map.get(field_name) orelse return;
            if (old != .floats or old.floats.count != 4) return;
            self.setKvFloat(id, &.{
                @floatFromInt(charc.r),
                @floatFromInt(charc.g),
                @floatFromInt(charc.b),
                old.floats.d[3],
            });
        }
    }

    pub fn cb_commitCheckbox(this_window: *iArea, _: *Gui, val: bool, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        self.setKvStr(id, if (val) "1" else "0");
    }

    pub fn cb_commitTextbox(this_window: *iArea, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        self.setKvStr(id, string);
    }

    pub fn select_kv_cb(this_window: *iArea, id: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        _ = gui;
        win.needs_rebuild = true;
        self.selected_kv_index = id;
        //We need to rebuild buttons to show the selected mark
    }
};

pub fn customButtonDraw(vt: *iArea, d: DrawState) void {
    const self: *Wg.Button = @alignCast(@fieldParentPtr("vt", vt));
    d.ctx.rect(vt.area, 0xffff_ffff);
    if (self.opts.user_1 == 1) {
        const SELECTED_FIELD_COLOR = 0x6097dbff;
        d.ctx.rect(vt.area, SELECTED_FIELD_COLOR);
    }
    const ta = vt.area.inset(3 * d.scale);
    d.ctx.textClipped(ta, "{s}", .{self.text}, d.textP(0xff), .center);
}
