const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");
const string = types.string;
const cstring = types.cstring;

args: []const cstring,
index: usize = 1,
short_index: usize = 0,
short_chain: bool = false,

pub const ItemKind = enum {
    string,
    short_option,
    long_option,
};

pub const Item = union(ItemKind) {
    string: string,
    short_option: u8,
    long_option: string,

    pub fn isHelp(self: Item) bool {
        return switch (self) {
            .long_option => std.mem.eql(u8, self.long_option, "help"),
            else => false,
        };
    }

    pub fn isOption(self: Item) bool {
        return switch (self) {
            .short_option, .long_option => true,
            else => false,
        };
    }

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
            .string => |value| value,
            .short_option => |value| try bufPrint(&buffer, "-{c}", .{value}),
            .long_option => |value| try bufPrint(&buffer, "--{s}", .{value}),
        };
        try formatText(text, "s", options, writer);
    }
};

pub fn peek(self: *Self) ?Item {
    if (self.index >= self.args.len)
        return null;

    const arg = std.mem.sliceTo(self.args[self.index], 0);
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

        const arg = std.mem.sliceTo(self.args[self.index], 0);
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

pub fn argv(self: Self) []const cstring {
    return self.args[0..self.index];
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
        .index = 0,
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
