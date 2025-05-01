const std = @import("std");

pub const Tag = enum {
    newline,
    open_bracket,
    close_bracket,
    string,
    quoted_string,
};

pub const Token = struct {
    pub const Pos = struct { start: usize, end: usize };
    tag: Tag,
    pos: Pos,
};

pub const Tokenizer = struct {
    slice: []const u8,
    pos: usize = 0,
    
    pub fn next(self: *@This())!?Token{
        var res = Token{ .pos = .{ .start = self.pos, .end = self.pos }, .tag = .newline };
        if(self.pos >= self.slice.len)
            return null;
        while (self.pos < self.slice.len) : (self.pos += 1) {
            const ch = self.slice[self.pos];
            self.char_counter += 1;
            if (ch == '\n') {
                self.line_counter += 1;
                self.char_counter = 1;
            }
        }
        return res;
    }
};
