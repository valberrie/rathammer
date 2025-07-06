const std = @import("std");
const graph = @import("graph");
const Gui = guis.Gui;
const Rec = graph.Rec;
const Rect = graph.Rect;
const DrawState = guis.DrawState;
const GuiHelp = guis.GuiHelp;
const guis = graph.RGui;
const iWindow = guis.iWindow;
const iArea = guis.iArea;
const Wg = guis.Widget;
const Context = @import("../editor.zig").Context;
const label = guis.label;
const async_util = @import("../async.zig");
const VisGroup = @import("../visgroup.zig");
pub const PauseWindow = struct {
    const Buttons = enum {
        unpause,
        quit,
        force_autosave,
        new_map,
        pick_map,

        pub fn id(self: @This()) usize {
            return @intFromEnum(self);
        }
    };

    const HelpText = struct {
        text: std.ArrayList(u8),
        name: std.ArrayList(u8),
    };

    vt: iWindow,
    area: iArea,

    editor: *Context,
    should_exit: bool = false,
    ent_select: u32 = 0,

    texts: std.ArrayList(HelpText),
    selected_text_i: usize = 0,

    tab_index: usize = 0,

    pub fn create(gui: *Gui, editor: *Context) !*PauseWindow {
        const self = gui.create(@This());
        self.* = .{
            .area = iArea.init(gui, Rec(0, 0, 0, 0)),
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .editor = editor,
            .texts = std.ArrayList(HelpText).init(gui.alloc),
        };
        self.area.draw_fn = &draw;
        self.area.deinit_fn = &area_deinit;

        if (std.fs.cwd().openDir("doc/en", .{ .iterate = true })) |doc_dir| {
            var dd = doc_dir;
            defer dd.close();
            var walker = try dd.walk(gui.alloc);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                switch (entry.kind) {
                    .file => {
                        if (std.mem.endsWith(u8, entry.basename, ".txt")) {
                            var vec = std.ArrayList(u8).init(gui.alloc);
                            try vec.appendSlice(entry.basename[0 .. entry.basename.len - 4]);
                            var text = std.ArrayList(u8).init(gui.alloc);
                            const in = try entry.dir.openFile(entry.basename, .{});
                            in.reader().readAllArrayList(&text, std.math.maxInt(usize)) catch {};
                            in.close();

                            try self.texts.append(.{ .text = text, .name = vec });
                        }
                    },
                    else => {},
                }
            }
            std.sort.insertion(HelpText, self.texts.items, {}, SortHelpText.lessThan);
        } else |_| {}

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        vt.deinit(gui);
        for (self.texts.items) |text| {
            text.text.deinit();
            text.name.deinit();
        }
        self.texts.deinit();
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn btnCb(vt: *iArea, id: usize, _: *Gui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        switch (@as(Buttons, @enumFromInt(id))) {
            .unpause => self.editor.paused = false,
            .quit => self.should_exit = true,
            .force_autosave => self.editor.autosaver.force = true,
            .new_map => {
                self.vt.needs_rebuild = true;
                const ed = self.editor;
                ed.initNewMap() catch {
                    std.debug.print("ERROR INIT NEW MAP\n", .{});
                };
                self.editor.paused = false;
            },
            .pick_map => {
                self.vt.needs_rebuild = true;
                async_util.SdlFileData.spawn(self.editor.alloc, &self.editor.async_asset_load, .pick_map) catch return;
            },
        }
    }

    pub fn commitCb(vt: *iArea, _: *Gui, _: []const u8, _: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        self.editor.selection.setToSingle(@intCast(self.ent_select)) catch return;
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.area.area = area;
        self.area.clearChildren(gui, vt);
        self.area.dirty(gui);
        //self.layout.reset(gui, vt);
        //start a vlayout
        //var ly = Vert{ .area = vt.area };
        //const max_w = gui.style.config.default_item_h * 30;
        //const w = @min(max_w, inset.w);
        const inset = GuiHelp.insetAreaForWindowFrame(gui, vt.area.area);
        _ = self.area.addEmpty(gui, vt, graph.Rec(0, 0, 0, 0));

        self.area.addChildOpt(gui, vt, Wg.Tabs.build(gui, inset, &.{ "main", "keybinds", "visgroup" }, vt, .{ .build_cb = &buildTabs, .cb_vt = &self.area, .index_ptr = &self.tab_index }));
    }

    fn buildTabs(win_vt: *iArea, vt: *iArea, tab: []const u8, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", win_vt));
        const eql = std.mem.eql;
        if (eql(u8, tab, "visgroup")) {
            buildVisGroups(self, gui, vt);

            //var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = vt.area };
            //vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, ly.getArea(), "Welcome to visgroup", null));
        }
        if (eql(u8, tab, "main")) {
            const max_w = gui.style.config.default_item_h * 30;
            const w = @min(max_w, vt.area.w);
            const side_l = (vt.area.w - w) / 2;
            var ly = guis.VerticalLayout{
                .padding = .{},
                .item_height = gui.style.config.default_item_h,
                .bounds = vt.area.replace(side_l, null, w, null),
            };
            ly.padding.left = 10;
            ly.padding.right = 10;
            ly.padding.top = 10;

            const ds = &self.editor.draw_state;
            if (self.editor.has_loaded_map) {
                vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Unpause", .{ .cb_fn = &btnCb, .id = Buttons.id(.unpause), .cb_vt = &self.area }));
            } else {
                var hy = guis.HorizLayout{
                    .bounds = ly.getArea() orelse return,
                    .count = 2,
                };
                vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "New map", .{ .cb_fn = &btnCb, .id = Buttons.id(.new_map), .cb_vt = &self.area }));
                vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "Load map", .{ .cb_fn = &btnCb, .id = Buttons.id(.pick_map), .cb_vt = &self.area }));
            }

            vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Quit", .{ .cb_fn = &btnCb, .id = Buttons.id(.quit), .cb_vt = &self.area }));
            vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Force autosave", .{ .cb_fn = &btnCb, .id = Buttons.id(.force_autosave), .cb_vt = &self.area }));

            {
                var hy = guis.HorizLayout{
                    .bounds = ly.getArea() orelse return,
                    .count = 4,
                };
                vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, hy.getArea(), "draw tools", .{ .bool_ptr = &ds.tog.tools }, null));
                vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, hy.getArea(), "draw sprite", .{ .bool_ptr = &ds.tog.sprite }, null));
                vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, hy.getArea(), "draw models", .{ .bool_ptr = &ds.tog.models }, null));
                vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, hy.getArea(), "ignore groups", .{ .bool_ptr = &self.editor.selection.ignore_groups }, null));
            }

            if (guis.label(vt, gui, win, ly.getArea(), "Camera move kind", .{})) |ar|
                vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &ds.cam3d.fwd_back_kind, .{}));
            if (guis.label(vt, gui, win, ly.getArea(), "New entity type", .{})) |ar|
                vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.editor.edit_state.default_group_entity, .{}));
            if (guis.label(vt, gui, win, ly.getArea(), "Entity render distance", .{})) |ar|
                vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, &ds.tog.model_render_dist, 64, 1024 * 10, .{ .nudge = 256 }));

            if (label(vt, gui, win, ly.getArea(), "Select entity id", .{})) |ar|
                vt.addChildOpt(gui, win, Wg.TextboxNumber.build(gui, ar, &self.ent_select, win, .{
                    .commit_vt = &self.area,
                    .commit_cb = &commitCb,
                }));

            //ly.pushHeight(Wg.TextView.heightForN(gui, 4));
            ly.pushRemaining();
            const help_area = ly.getArea() orelse return;
            const sp = help_area.split(.vertical, gui.style.config.text_h * 9);

            if (self.selected_text_i < self.texts.items.len) {
                vt.addChildOpt(gui, win, Wg.TextView.build(gui, sp[1], &.{self.texts.items[self.selected_text_i].text.items}, win, .{
                    .mode = .split_on_space,
                }));
            }

            vt.addChildOpt(gui, win, Wg.VScroll.build(gui, sp[0], .{
                .build_cb = &buildHelpScroll,
                .build_vt = &self.area,
                .win = win,
                .count = self.texts.items.len,
                .item_h = ly.item_height,
            }));
        }
    }

    pub fn btn_help_cb(vt: *iArea, id: usize, _: *Gui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        if (id >= self.texts.items.len) return;
        self.selected_text_i = id;
        self.vt.needs_rebuild = true;
    }

    pub fn buildHelpScroll(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, window: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", window_area));
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = vt.area };
        if (index >= self.texts.items.len) return;
        for (self.texts.items[index..], index..) |text, i| {
            //vt.addChildOpt(gui, window, Wg.Text.build(gui, ly.getArea(), "{s}", .{text.name.items}));
            vt.addChildOpt(gui, window, Wg.Button.build(gui, ly.getArea(), text.name.items[3..], .{
                .custom_draw = &Wg.Button.customButtonDraw_listitem,
                .id = i,
                .cb_fn = &btn_help_cb,
                .cb_vt = window_area,
                .user_1 = if (self.selected_text_i == i) 1 else 0,
            }));
        }
    }
};

fn buildVisGroups(self: *PauseWindow, gui: *Gui, area: *iArea) void {
    const Helper = struct {
        fn recur(vs: *VisGroup, vg: *VisGroup.Group, depth: usize, gui_: *Gui, vl: *guis.VerticalLayout, vt: *iArea, win: *iWindow) void {
            vl.padding.left = @floatFromInt(depth * 20);
            const the_bool = !vs.disabled.isSet(vg.id);
            //const changed = os9g.checkbox(vg.name, &the_bool);
            vt.addChildOpt(
                gui_,
                win,
                Wg.Checkbox.build(gui_, vl.getArea(), vg.name, .{
                    .cb_fn = &commit_cb,
                    .cb_vt = win.area,
                    .user_id = vg.id,
                }, the_bool),
            );
            for (vg.children.items) |id| {
                recur(
                    vs,
                    &vs.groups.items[id],
                    depth + 2,
                    gui_,
                    vl,
                    vt,
                    win,
                );
            }
        }

        fn commit_cb(user: *iArea, _: *Gui, val: bool, id: usize) void {
            const selfl: *PauseWindow = @alignCast(@fieldParentPtr("area", user));
            if (id > VisGroup.MAX_VIS_GROUP) return;
            selfl.editor.visgroups.setValueCascade(@intCast(id), val);
            selfl.editor.rebuildVisGroups() catch return;
            selfl.vt.needs_rebuild = true;
        }
    };
    var ly = guis.VerticalLayout{
        .padding = .{},
        .item_height = gui.style.config.default_item_h,
        .bounds = area.area,
    };

    if (self.editor.visgroups.getRoot()) |vg| {
        Helper.recur(&self.editor.visgroups, vg, 0, gui, &ly, area, &self.vt);
    }
}

pub const SortHelpText = struct {
    pub fn lessThan(_: void, a: PauseWindow.HelpText, b: PauseWindow.HelpText) bool {
        if (a.name.items.len < 3 or b.name.items.len < 3) return false;

        const an = std.fmt.parseInt(u32, a.name.items[0..3], 10) catch return false;
        const bn = std.fmt.parseInt(u32, b.name.items[0..3], 10) catch return true;
        return an < bn;
    }
};
