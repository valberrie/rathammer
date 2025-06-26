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

    id_kv_map: std.StringHashMap(usize),
    kv_id_map: std.AutoHashMap(usize, []const u8),
    kv_id_index: usize = 0,

    selected_class_id: ?usize = null,

    str: []const u8 = "ass",

    pub fn create(gui: *Gui, editor: *Context) *InspectorWindow {
        const self = gui.create(@This());
        self.* = .{
            .area = iArea.init(gui, Rec(0, 0, 0, 0)),
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .editor = editor,
            .kv_id_map = std.AutoHashMap(usize, []const u8).init(gui.alloc),
            .id_kv_map = std.StringHashMap(usize).init(gui.alloc),
        };
        self.area.draw_fn = &draw;
        self.area.deinit_fn = &area_deinit;

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        self.kv_id_map.deinit();
        self.id_kv_map.deinit();
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    fn resetIds(self: *Self) void {
        self.kv_id_map.clearRetainingCapacity();
        self.id_kv_map.clearRetainingCapacity();
        self.kv_id_index = 0;
    }

    /// name must be owned by someone else, probably editor.stringstorage
    fn getId(self: *Self, name: []const u8) usize {
        if (self.id_kv_map.get(name)) |item| return item;
        const id = self.kv_id_index;
        self.kv_id_index += 1;
        self.kv_id_map.put(id, name) catch return id;
        self.id_kv_map.put(name, id) catch return id;
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
        const sp1 = vt.area.area;
        //const sp1 = vt.area.area.split(.horizontal, vt.area.area.h * 0.5);
        const inset = GuiHelp.insetAreaForWindowFrame(gui, sp1);
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

        //self.buildErr(gui, &ly) catch {};
        ly.pushRemaining();
        a.addChildOpt(gui, vt, Wg.Tabs.build(gui, ly.getArea(), &.{ "props", "io" }, vt, &buildTabs, &self.area));
    }

    fn buildTabs(user_vt: *iArea, vt: *iArea, tab_name: []const u8, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", user_vt));
        const eql = std.mem.eql;
        if (eql(u8, tab_name, "props")) {
            const sp = vt.area.split(.horizontal, vt.area.h * 0.5);
            {
                var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = sp[0] };
                ly.padding.left = 10;
                ly.padding.right = 10;
                ly.padding.top = 10;
                self.buildErr(gui, &ly, vt) catch {};
            }

            {
                var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = sp[1] };
                ly.padding.left = 10;
                ly.padding.right = 10;
                ly.padding.top = 10;
                self.buildValueEditor(gui, &ly, vt) catch {};
            }
            std.debug.print("Done big props\n", .{});
            return;
        }
        if (eql(u8, tab_name, "io")) {
            const sp = vt.area.split(.horizontal, vt.area.h * 0.5);
            var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = sp[1] };
            ly.padding.left = 10;
            ly.padding.right = 10;
            ly.padding.top = 10;

            const cons = self.getConsPtr() orelse return;

            vt.addChildOpt(gui, win, Wg.VScroll.build(gui, sp[0], .{
                .build_cb = &buildIoScrollCb,
                .build_vt = win.area,
                .win = win,
                .count = cons.list.items.len,
                .item_h = gui.style.config.default_item_h,
            }));
            //self.buildIoTab(gui, sp[0], vt) catch {};
            const names = [6][]const u8{ "Listen", "target", "input", "value", "delay", "fc" };
            for (names) |n| {
                const ar = ly.getArea() orelse break;
                const sp1 = ar.split(.vertical, ar.w / 2);
                vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, sp1[0], n, null));
            }
        }
    }

    fn buildErr(self: *@This(), gui: *Gui, ly: anytype, lay: *iArea) !void {
        const ed = self.editor;
        const a = &self.area;
        const win = &self.vt;
        self.selected_class_id = null;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id| {
            if (try ed.ecs.getOptPtr(sel_id, .entity)) |ent| {
                const aa = ly.getArea() orelse return;
                const Lam = struct {
                    fn commit(vtt: *iArea, id: usize, _: void) void {
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

                    fn name(vtt: *iArea, id: usize, _: *Gui, _: void) []const u8 {
                        const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                        const fields = lself.editor.fgd_ctx.ents.items;
                        if (id >= fields.len) return "BROKEN";
                        return fields[id].name;
                    }
                };
                self.selected_class_id = ed.fgd_ctx.getId(ent.class);
                lay.addChildOpt(gui, win, Wg.ComboUser(void).build(gui, aa, .{
                    .user_vt = &self.area,
                    .commit_cb = &Lam.commit,
                    .name_cb = &Lam.name,
                    .current = self.selected_class_id orelse 0,
                    .count = self.editor.fgd_ctx.ents.items.len,
                }, {}));
                lay.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ly.getArea(), .{ .init_string = ent.class }));
                const eclass = ed.fgd_ctx.getPtr(ent.class) orelse return;
                const fields = eclass.field_data.items;
                if (eclass.doc.len > 0) { //Doc string
                    ly.pushHeight(Wg.TextView.heightForN(gui, 4));
                    lay.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{eclass.doc}, win, .{
                        .mode = .split_on_space,
                    }));
                }
                ly.pushRemaining();
                lay.addChildOpt(gui, win, Wg.VScroll.build(gui, ly.getArea(), .{
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

    // If a kv is selected, this edits it
    fn buildValueEditor(self: *@This(), gui: *Gui, ly: anytype, lay: *iArea) !void {
        const ed = self.editor;
        const win = &self.vt;
        if (self.selected_class_id) |cid| {
            const class = &ed.fgd_ctx.ents.items[cid];
            if (self.selected_kv_index >= class.field_data.items.len) return;
            const field = &class.field_data.items[self.selected_kv_index];

            lay.addChildOpt(gui, &self.vt, Wg.Text.buildStatic(gui, ly.getArea(), field.name, null));
            if (field.doc_string.len > 0) {
                ly.pushHeight(Wg.TextView.heightForN(gui, 4));
                lay.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{field.doc_string}, win, .{
                    .mode = .split_on_space,
                }));
            }
            const kvs = self.getKvsPtr() orelse return;
            const val = kvs.map.getPtr(field.name) orelse return;
            const cb_id = self.getId(field.name);
            const ar = ly.getArea();
            switch (val.*) { //Put a textbox for all of them
                .string => |s| {
                    lay.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ar, .{
                        .init_string = s.items,
                        .user_id = cb_id,
                        .commit_vt = win.area,
                        .commit_cb = &cb_commitTextbox,
                    }));
                },
                .floats => {},
            }
            //Extra stuff for typed fields TODO put in a scroll
            switch (field.type) {
                .flags => |flags| {
                    try val.toString(kvs.map.allocator);
                    const mask = std.fmt.parseInt(u32, val.string.items, 10) catch null;
                    for (flags.items) |flag| {
                        const is_set = if (mask) |m| flag.mask & m > 0 else flag.on;
                        const packed_id: u64 = @as(u64, @intCast(flag.mask)) << 32 | cb_id;
                        lay.addChildOpt(gui, win, Wg.Checkbox.build(gui, ly.getArea(), flag.name, .{
                            .cb_fn = &cb_commitCheckbox,
                            .cb_vt = win.area,
                            .user_id = packed_id,
                        }, is_set));
                    }
                },
                .material => {},
                else => {},
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

    pub fn getConsPtr(self: *Self) ?*ecs.Connections {
        const ed = self.editor;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id|
            return (ed.ecs.getOptPtr(sel_id, .connections) catch null);
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
                const class_i = ed.fgd_ctx.base.get(ent.class) orelse return;
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
                        .model, .material => {
                            try res.value_ptr.toString(kvs.map.allocator);
                            const H = struct {
                                fn btn_cb(win_ar: *iArea, id: u64, _: *Gui, _: *iWindow) void {
                                    // if msb of id is set, its a texture not model
                                    // hacky yea.
                                    const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", win_ar));
                                    const idd = id << 1 >> 1; //clear msb;

                                    const is_mat = (id & (1 << 63) != 0);
                                    std.debug.print("is mat {any}\n", .{is_mat});
                                    lself.editor.asset_browser.dialog_state = .{
                                        .target_id = @intCast(idd),
                                        .previous_pane_index = lself.editor.draw_state.tab_index,
                                        .kind = if (is_mat) .texture else .model,
                                    };
                                    const ds = &lself.editor.draw_state;
                                    lself.editor.draw_state.tab_index = if (is_mat) ds.texture_browser_tab_index else ds.model_browser_tab_index;
                                }
                            };
                            const mask: u64 = if (req_f.type == .material) 1 << 63 else 0;
                            const idd: u64 = sel_id | mask;
                            a.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Select", .{
                                .cb_vt = window_area,
                                .cb_fn = &H.btn_cb,
                                .id = idd,
                            }));
                        },
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
                            } else {
                                var found: usize = 0;
                                for (ch.items, 0..) |choice, i| {
                                    if (std.mem.eql(u8, res.value_ptr.string.items, choice[0])) {
                                        found = i;
                                        break;
                                    }
                                }
                                self.buildChoice(.{ .class_i = class_i, .field_i = f_i, .count = ch.items.len, .current = found }, ar, gui, win, a);
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

    pub fn cb_commitCheckbox(this_window: *iArea, _: *Gui, val: bool, id: u64) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        const upper: u32 = @intCast(id >> 32);
        if (upper != 0) { //we store flags in upper 32
            const lower = id << 32 >> 32; //Clear upper
            const kvs = self.getKvsPtr() orelse return;
            const name = self.getNameFromId(lower) orelse return;
            const old_str = kvs.getString(name) orelse return;
            var mask = std.fmt.parseInt(u32, old_str, 10) catch 0;
            if (val) {
                mask = mask | upper; //add bit
            } else {
                mask = mask & ~upper; //remove bit
            }
            self.setKvStr(lower, self.editor.printScratch("{d}", .{mask}) catch return);
        } else {
            self.setKvStr(id, if (val) "1" else "0");
        }
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

    pub fn buildChoice(self: *@This(), info: anytype, area: ?Rect, gui: *Gui, win: *iWindow, vt: *iArea) void {
        //const ed = self.editor;
        const aa = area orelse return;
        const Lam = struct {
            fgd_class_index: usize,
            fgd_field_index: usize,

            fn commit(vtt: *iArea, id: usize, lam: @This()) void {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));

                const fields = lself.editor.fgd_ctx.ents.items;
                const f = fields[lam.fgd_class_index];
                const fie = f.field_data.items[lam.fgd_field_index];

                if (lself.getKvsPtr()) |kvs| {
                    kvs.putString(fie.name, fie.type.choices.items[id][0]) catch return;
                }
            }

            fn name(vtt: *iArea, id: usize, _: *Gui, lam: @This()) []const u8 {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                const class = lself.editor.fgd_ctx.ents.items[lam.fgd_class_index];
                const field = class.field_data.items[lam.fgd_field_index];
                if (field.type == .choices) {
                    if (id < field.type.choices.items.len)
                        return field.type.choices.items[id][1];
                }
                return "not a choice";
            }
        };
        vt.addChildOpt(gui, win, Wg.ComboUser(Lam).build(
            gui,
            aa,
            .{
                .user_vt = &self.area,
                .commit_cb = &Lam.commit,
                .name_cb = &Lam.name,
                .current = info.current,
                .count = info.count,
            },
            .{ .fgd_class_index = info.class_i, .fgd_field_index = info.field_i },
        ));
    }

    fn buildIoScrollCb(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", window_area));
        _ = win;
        self.buildIoTab(gui, vt.area, vt, index) catch return;
    }

    fn buildIoTab(self: *@This(), gui: *Gui, area: Rect, lay: *iArea, index: usize) !void {
        const cons = self.getConsPtr() orelse return;
        const win = &self.vt;
        const th = gui.style.config.text_h;
        const num_w = th * 2;
        const rem4 = @trunc((area.w - num_w * 2) / 4);
        const col_ws = [6]f32{ rem4, rem4, rem4, rem4, num_w, num_w };
        var tly = guis.TableLayoutCustom{ .item_height = gui.style.config.default_item_h, .bounds = area, .column_widths = &col_ws };
        if (index >= cons.list.items.len) return;
        for (cons.list.items[index..]) |con| {
            lay.addChildOpt(gui, win, Wg.Text.buildStatic(gui, tly.getArea(), con.listen_event, null));
            lay.addChildOpt(gui, win, Wg.Text.build(gui, tly.getArea(), "{s}", .{con.target.items}));
            lay.addChildOpt(gui, win, Wg.Text.buildStatic(gui, tly.getArea(), con.input, null));
            lay.addChildOpt(gui, win, Wg.Text.build(gui, tly.getArea(), "{s}", .{con.value.items}));
            lay.addChildOpt(gui, win, Wg.Text.build(gui, tly.getArea(), "{d}", .{con.delay}));
            lay.addChildOpt(gui, win, Wg.Text.build(gui, tly.getArea(), "{d}", .{con.fire_count}));
        }
    }
};

/// This should only be passed to Wg.Button !
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
