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
pub const PauseWindow = struct {
    const Buttons = enum {
        unpause,
        quit,
        force_autosave,

        pub fn id(self: @This()) usize {
            return @intFromEnum(self);
        }
    };
    vt: iWindow,
    area: iArea,

    text: std.ArrayList(u8),
    editor: *Context,
    should_exit: bool = false,
    ent_select: u32 = 0,

    pub fn create(gui: *Gui, editor: *Context) *PauseWindow {
        const self = gui.create(@This());
        self.* = .{
            .area = iArea.init(gui, Rec(0, 0, 0, 0)),
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .editor = editor,
            .text = std.ArrayList(u8).init(gui.alloc),
        };
        self.area.draw_fn = &draw;
        self.area.deinit_fn = &area_deinit;

        if (std.fs.cwd().openFile("pause.txt", .{})) |file| {
            file.reader().readAllArrayList(&self.text, std.math.maxInt(usize)) catch {};
            file.close();
        } else |_| {}

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        self.text.deinit();
        vt.deinit(gui);
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
        a.addChildOpt(gui, vt, Wg.Button.build(gui, ly.getArea(), "Unpause", .{ .cb_fn = &btnCb, .id = Buttons.id(.unpause), .cb_vt = &self.area }));
        a.addChildOpt(gui, vt, Wg.Button.build(gui, ly.getArea(), "Quit", .{ .cb_fn = &btnCb, .id = Buttons.id(.quit), .cb_vt = &self.area }));
        a.addChildOpt(gui, vt, Wg.Button.build(gui, ly.getArea(), "Force autosave", .{ .cb_fn = &btnCb, .id = Buttons.id(.force_autosave), .cb_vt = &self.area }));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "draw tools", .{ .bool_ptr = &ds.tog.tools }, null));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "draw sprite", .{ .bool_ptr = &ds.tog.sprite }, null));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "draw models", .{ .bool_ptr = &ds.tog.models }, null));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "ignore groups", .{ .bool_ptr = &self.editor.selection.ignore_groups }, null));
        a.addChildOpt(gui, vt, Wg.Combo.build(gui, ly.getArea(), &ds.cam3d.fwd_back_kind));
        a.addChildOpt(gui, vt, Wg.Combo.build(gui, ly.getArea(), &self.editor.edit_state.default_group_entity));
        a.addChildOpt(gui, vt, Wg.Slider.build(gui, ly.getArea(), &ds.tog.model_render_dist, 64, 1024 * 10, .{ .nudge = 256 }));

        a.addChildOpt(gui, vt, Wg.TextboxNumber.build(gui, ly.getArea(), &self.ent_select, vt, .{
            .commit_vt = &self.area,
            .commit_cb = &commitCb,
        }));

        //ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        ly.pushRemaining();
        a.addChildOpt(gui, vt, Wg.TextView.build(gui, ly.getArea(), &.{self.text.items}, vt, .{
            .mode = .split_on_space,
        }));
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

    pub fn buildScrollItems(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, window: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", window_area));
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = vt.area };
        for (index..10) |i| {
            vt.addChildOpt(gui, window, Wg.Text.build(gui, ly.getArea(), "item {d}", .{i}));
        }
        _ = self;
    }
};
