const std = @import("std");
const testing = std.testing;

args: []const [:0]const u8,
index: usize = 0,
short_index: usize = 0,
short_chain: bool = false,

const Item = union(enum) {
    string: []const u8,
    short_option: u8,
    long_option: []const u8,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const bufPrint = std.fmt.bufPrint;
        const formatText = std.fmt.formatText;
        if (fmt.len != 0)
            return std.fmt.invalidFmtError(fmt, self);
        var buffer: [1024]u8 = undefined;
        const text = switch (self) {
            .string => |string| string,
            .short_option => |short| try bufPrint(&buffer, "-{c}", .{short}),
            .long_option => |long| try bufPrint(&buffer, "--{s}", .{long}),
        };
        try formatText(text, "s", options, writer);
    }
};

pub fn peek(self: *Self) ?Item {
    if (self.index >= self.args.len)
        return null;

    const arg = self.args[self.index];
    inline for (.{ "", "-", "--" }) |sep| {
        if (std.mem.eql(u8, sep, arg))
            return .{ .string = arg };
    }

    if (self.short_index != 0) {
        if (!self.short_chain)
            return .{ .string = arg[self.short_index..] };
        return .{ .short_option = arg[self.short_index] };
    }

    if (arg[0] == '-') {
        if (arg[1] == '-') {
            return .{ .long_option = arg[2..] };
        } else {
            self.short_index = 1;
            self.short_chain = true;
            return .{ .short_option = arg[1] };
        }
    }

    return .{ .string = arg };
}

pub fn advance(self: *Self) void {
    if (self.short_index != 0) {
        if (!self.short_chain) {
            self.short_index = 0;
            self.index += 1;
            return;
        }

        const arg = self.args[self.index];
        if (arg.len == self.short_index + 1) {
            self.short_index = 0;
            self.short_chain = false;
            self.index += 1;
        } else {
            self.short_index += 1;
        }
    } else {
        self.index += 1;
    }
}

pub fn next(self: *Self) ?Item {
    defer self.advance();
    return self.peek();
}

const Self = @This();

test Self {
    var args = Self{
        .args = &.{
            "hello",
            "-a",
            "--long",
            "world",
            "-bcdefh",
        },
    };

    try testing.expectEqualStrings(args.next().?.string, "hello");
    try testing.expectEqual(args.next().?.short_option, 'a');
    try testing.expectEqualStrings(args.next().?.long_option, "long");
    args.advance();
    try testing.expectEqual(args.next().?.short_option, 'b');
    try testing.expectEqual(args.next().?.short_option, 'c');
    args.advance();
    try testing.expectEqual(args.next().?.short_option, 'e');
    args.short_chain = false;
    try testing.expectEqualStrings(args.next().?.string, "fh");
}
