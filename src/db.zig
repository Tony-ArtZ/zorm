pub const DB = struct {
    connectfn: fn (self: *const DB, conninfo: []const u8) void,
    disconnectfn: fn (self: *const DB) void,

    pub fn connect(self: *const DB, conninfo: []const u8) void {
        return self.connectfn(self, conninfo);
    }

    pub fn disconnect(self: *const DB) void {
        self.disconnectfn(self);
    }
};
