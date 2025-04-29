const vpk = @import("vpk.zig");

pub const DeferredNotifyVtable = struct {
    notify_fn: *const fn (self: *@This(), id: vpk.VpkResId) void,

    pub fn notify(self: *@This(), id: vpk.VpkResId) void {
        self.notify_fn(self, id);
    }
};
