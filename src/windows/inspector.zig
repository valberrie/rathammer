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
//TODO
// to get this to work we need to first add a getptr cb to all existing
// widgets and use that to obtain our values.
// second, we need an 'onUpdate' that lets us check if we need to rebuild by comparing
// old selection to new for example.
// or, we have the editor.selection emit an event.
pub const InspectorWindow = struct {
    vt: iWindow,
    area: iArea,

    editor: *Context,

    pub fn create(gui: *Gui, editor: *Context) *InspectorWindow {
        const self = gui.create(@This());
        self.* = .{
            .area = iArea.init(gui, Rec(0, 0, 0, 0)),
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .editor = editor,
        };
        self.area.draw_fn = &draw;
        self.area.deinit_fn = &area_deinit;

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
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
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), &ds.tog.tools, "draw tools"));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), &ds.tog.sprite, "draw sprite"));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), &ds.tog.models, "draw model"));
        a.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), &self.editor.selection.ignore_groups, "ignore groups"));
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
