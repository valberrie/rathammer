const std = @import("std");

pub fn WriteVdf(out_stream_T: type) type {
    return struct {
        const Self = @This();
        out_stream: out_stream_T,

        indendation: usize = 0,
        state: enum {
            expecting_key,
            expecting_value,
        } = .expecting_key,
        strbuf: std.ArrayList(u8),

        pub fn init(alloc: std.mem.Allocator, stream: out_stream_T) Self {
            return .{
                .strbuf = std.ArrayList(u8).init(alloc),
                .out_stream = stream,
            };
        }

        pub fn deinit(self: *Self) void {
            self.strbuf.deinit();
        }

        //may clear self.strbuf
        fn sanitizeName(self: *Self, name: []const u8) ![]const u8 {
            var needs_quotes = false;
            for (name) |char| {
                switch (char) {
                    //This is more strict than the canonical vdfs.
                    //Having unescaped newlines inside of keys is bad, imo.
                    //Escaping is an option which is off by default in the Valve parsers, some vdf's use the '\' as a path
                    //seperator, so we can't force it on.
                    '{', '}', ' ', '\t' => {
                        needs_quotes = true;
                    },
                    '\\' => return error.backslashNotAllowed,
                    '"' => return error.quotesNotAllowed,
                    '\n', '\r' => return error.newlineNotAllowed,
                    else => {},
                    //TODO should we disallow all control chars?
                    //what about unicode?
                }
            }
            if (needs_quotes) {
                self.strbuf.clearRetainingCapacity();
                try self.strbuf.append('\"');
                try self.strbuf.appendSlice(name);
                try self.strbuf.append('\"');
                return self.strbuf.items;
            }
            return name;
        }

        fn indent(self: *Self) !void {
            _ = try self.out_stream.writeBytesNTimes("    ", self.indendation);
        }

        pub fn writeKey(self: *Self, key: []const u8) !void {
            if (self.state != .expecting_key)
                return error.invalidState;
            try self.indent();
            _ = try self.out_stream.write(try self.sanitizeName(key));
            _ = try self.out_stream.write(" ");
            self.state = .expecting_value;
        }

        pub fn beginObject(self: *Self) !void {
            if (self.state != .expecting_value)
                return error.invalidState;
            _ = try self.out_stream.write("{\n");
            self.indendation += 1;
            self.state = .expecting_key;
        }

        pub fn endObject(self: *Self) !void {
            if (self.state != .expecting_key)
                return error.invalidState;
            self.indendation -= 1;
            try self.indent();
            _ = try self.out_stream.write("}\n");
        }

        pub fn writeValue(self: *Self, value: []const u8) !void {
            if (self.state != .expecting_value)
                return error.invalidState;
            _ = try self.out_stream.write(try self.sanitizeName(value));
            _ = try self.out_stream.writeByte('\n');
            self.state = .expecting_key;
        }
    };
}

test {
    const alloc = std.testing.allocator;
    const out = std.io.getStdOut();
    const wr = out.writer();
    var s = WriteVdf(@TypeOf(wr)).init(alloc, wr);
    defer s.deinit();
    try s.writeKey("hello");
    try s.beginObject();
    {
        try s.writeKey("key1");
        try s.writeValue("val1");

        try s.writeKey("big key with  {} stuff");
        try s.writeValue("another value\thLL");

        try s.writeKey("My object");
        try s.beginObject();
        {
            try s.writeKey("Hello");
            try s.writeValue("world");
        }
        try s.endObject();
    }
    try s.endObject();
}
