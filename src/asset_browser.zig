const std = @import("std");
const graph = @import("graph");
const vpk = @import("vpk.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const guiutil = graph.gui_app;
const edit = @import("editor.zig");
const Config = @import("config.zig");
const Gui = graph.Gui;
//TODO center camera view on model on new model load

const log = std.log.scoped(.asset_browser);
pub const AssetBrowserGui = struct {
    const Self = @This();
    const IdVec = std.ArrayList(vpk.VpkResId);

    /// These are populated at init then left const
    model_list: IdVec,
    mat_list: IdVec,

    model_list_sub: IdVec,
    mat_list_sub: IdVec,

    model_search: Os9Gui.DynamicTextbox,
    mat_search: Os9Gui.DynamicTextbox,

    num_texture_column: usize = 4,
    start_index_model: usize = 0,
    start_index_mat: usize = 0,

    model_needs_rebuild: bool = true,
    mat_needs_rebuild: bool = true,

    selected_index_model: usize = 0,
    selected_index_mat: usize = 0,

    min_column: i32 = 1,
    max_column: i32 = 10,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .model_list = IdVec.init(alloc),
            .mat_list = IdVec.init(alloc),
            .model_list_sub = IdVec.init(alloc),
            .mat_list_sub = IdVec.init(alloc),
            .model_search = Os9Gui.DynamicTextbox.init(alloc),
            .mat_search = Os9Gui.DynamicTextbox.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.model_list.deinit();
        self.mat_list.deinit();
        self.model_list_sub.deinit();
        self.mat_list_sub.deinit();
        self.model_search.deinit();
        self.mat_search.deinit();
    }

    pub fn populate(
        self: *Self,
        vpkctx: *vpk.Context,
        exclude_prefix: []const u8,
        material_exclude_list: []const []const u8,
    ) !void {
        //const ep = "materials/";
        //TODO make these configurable
        //const exclude_list = [_][]const u8{
        //    "models", "gamepadui", "skybox", "vgui", "particle", "console", "sprites", "backpack",
        //};
        vpkctx.mutex.lock();
        defer vpkctx.mutex.unlock();
        const vmt = vpkctx.extension_map.get("vmt") orelse return;
        const mdl = vpkctx.extension_map.get("mdl") orelse return;
        var it = vpkctx.entries.iterator();
        var excluded: usize = 0;
        outer: while (it.next()) |item| {
            const id = item.key_ptr.* >> 48;
            if (id == vmt) {
                if (std.mem.startsWith(u8, item.value_ptr.path, exclude_prefix)) {
                    for (material_exclude_list) |ex| {
                        if (std.mem.startsWith(u8, item.value_ptr.path[exclude_prefix.len..], ex)) {
                            excluded += 1;
                            continue :outer;
                        }
                    }
                }
                try self.mat_list.append(item.key_ptr.*);
            } else if (id == mdl) {
                try self.model_list.append(item.key_ptr.*);
            }
        }
        log.info("excluded {d} materials", .{excluded});
    }

    pub fn drawEditWindow(
        self: *Self,
        screen_area: graph.Rect,
        os9gui: *Os9Gui,
        editor: *edit.Context,
        config: *const Config.Config,
        tab: enum { model, texture },
    ) !void {
        const should_focus_tb = os9gui.gui.isBindState(config.keys.focus_search.b, .rising);
        if (try os9gui.beginTlWindow(screen_area)) {
            defer os9gui.endTlWindow();

            switch (tab) {
                .model => {
                    if (self.model_needs_rebuild) {
                        self.start_index_model = 0;
                        self.model_needs_rebuild = false;
                        self.model_list_sub.clearRetainingCapacity();
                        const io = std.mem.indexOf;
                        for (self.model_list.items) |item| {
                            const tt = editor.vpkctx.entries.get(item) orelse continue;
                            if (io(u8, tt.path, self.model_search.arraylist.items) != null or io(u8, tt.name, self.model_search.arraylist.items) != null)
                                try self.model_list_sub.append(item);
                        }
                    }
                    const vl = try os9gui.beginV();
                    vl.padding.top = 0;
                    vl.padding.bottom = 0;
                    defer os9gui.endL();
                    os9gui.sliderEx(&self.start_index_model, 0, self.model_list.items.len, "", .{});
                    {
                        _ = try os9gui.beginH(2);
                        defer os9gui.endL();
                        const len = self.model_search.arraylist.items.len;
                        try os9gui.textbox2(&self.model_search, .{ .make_active = should_focus_tb });
                        os9gui.label("Results {d}", .{self.model_list_sub.items.len});
                        if (len != self.model_search.arraylist.items.len)
                            self.model_needs_rebuild = true;
                    }
                    for (self.model_list_sub.items[self.start_index_model..], self.start_index_model..) |model, i| {
                        const tt = editor.vpkctx.entries.get(model) orelse continue;
                        if (os9gui.buttonEx("{s}/{s}", .{ tt.path, tt.name }, .{ .disabled = self.selected_index_model == i })) {
                            self.selected_index_model = i;
                        }
                        if (os9gui.gui.layout.last_requested_bounds == null) //Hacky
                            break;
                    }
                },
                .texture => {
                    if (self.mat_needs_rebuild) {
                        self.start_index_mat = 0;
                        self.mat_needs_rebuild = false;
                        self.mat_list_sub.clearRetainingCapacity();
                        const io = std.mem.indexOf;
                        for (self.mat_list.items) |item| {
                            const tt = editor.vpkctx.entries.get(item) orelse continue;
                            if (io(u8, tt.path, self.mat_search.arraylist.items) != null or io(u8, tt.name, self.mat_search.arraylist.items) != null)
                                try self.mat_list_sub.append(item);
                        }
                    }

                    const vl = try os9gui.beginV();
                    defer os9gui.endL();
                    self.start_index_mat = @min(self.start_index_mat, self.mat_list_sub.items.len);
                    os9gui.sliderEx(&self.start_index_mat, 0, @divFloor(self.mat_list_sub.items.len, self.num_texture_column), "", .{});
                    os9gui.sliderEx(&self.num_texture_column, 1, 10, "num column", .{});
                    const len = self.mat_search.arraylist.items.len;
                    {
                        _ = try os9gui.beginH(2);
                        defer os9gui.endL();
                        try os9gui.textbox2(&self.mat_search, .{ .make_active = should_focus_tb });
                        os9gui.label("Results {d}", .{self.mat_list_sub.items.len});
                    }

                    if (len != self.mat_search.arraylist.items.len)
                        self.mat_needs_rebuild = true;
                    //const ar = os9gui.gui.getArea() orelse graph.Rec(0, 0, 0, 0);
                    vl.pushRemaining();
                    const scroll_area = os9gui.gui.getArea() orelse return error.broken;
                    os9gui.gui.draw9Slice(scroll_area, os9gui.style.getRect(.basic_inset), os9gui.style.texture, os9gui.scale);
                    const ins = scroll_area.inset(3 * os9gui.scale);
                    var index: i32 = @intCast(self.start_index_mat);
                    const md: i32 = @intFromFloat(os9gui.gui.getMouseWheelDelta() orelse 0);
                    const res_per_page = 4;
                    if (os9gui.gui.isKeyDown(.LCTRL)) {
                        var nc: i32 = @intCast(self.num_texture_column);
                        nc += md;
                        self.num_texture_column = @intCast(std.math.clamp(
                            nc,
                            self.min_column,
                            self.max_column,
                        ));
                    } else {
                        index += md * res_per_page;
                    }
                    const nc: f32 = @floatFromInt(self.num_texture_column);
                    self.start_index_mat = @intCast(std.math.clamp(
                        index,
                        0,
                        @as(i32, @intCast(self.model_list_sub.items.len)),
                    ));

                    //self.start_index_mat = @min(self.start_index_mat, self.model_list_sub.items.len);
                    _ = try os9gui.gui.beginLayout(Gui.SubRectLayout, .{ .rect = ins }, .{ .scissor = ins });
                    defer os9gui.gui.endLayout();

                    _ = try os9gui.beginL(Gui.TableLayout{
                        .columns = @intCast(self.num_texture_column),
                        .item_height = ins.w / nc,
                    });
                    defer os9gui.endL();
                    const acc_ind = @min(self.start_index_mat * self.num_texture_column, self.mat_list_sub.items.len);
                    //const missing = edit.missingTexture();
                    for (self.mat_list_sub.items[acc_ind..], acc_ind..) |model, i| {
                        const tex = editor.getTexture(model);
                        //if (tex.id == missing.id) {
                        try editor.loadTexture(model);
                        //continue;
                        //}
                        const area = os9gui.gui.getArea() orelse break;
                        const text_h = area.h / 8;
                        const click = os9gui.gui.clickWidget(area);
                        if (click == .click)
                            self.selected_index_mat = i;
                        //os9gui.gui.drawRectFilled(area, 0xffff);
                        os9gui.gui.drawRectTextured(area, 0xffffffff, tex.rect(), tex);
                        const tr = graph.Rec(area.x, area.y + area.h - text_h, area.w, text_h);
                        os9gui.gui.drawRectFilled(tr, 0xff);
                        const tt = editor.vpkctx.entries.get(model) orelse continue;
                        os9gui.gui.drawTextFmt(
                            "{s}/{s}",
                            .{ tt.path, tt.name },
                            tr,
                            text_h,
                            0xffffffff,
                            .{},
                            os9gui.font,
                        );
                        //os9gui.label("{s}/{s}", .{ model[0], model[1] });
                    }
                },
            }
            //os9gui.endTabs();
        }
    }
};
