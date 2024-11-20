const std = @import("std");
const field = @import("field.zig");

const Action = union(enum) {
    /// Instead of parsing the incoming argument,
    /// assign a fixed value for it.
    store: *const anyopaque,
    /// Instead of parsing the incoming argument,
    /// increase a fixed value for it.
    increment: comptime_int,
    /// Parse and assign the incoming argument.
    assign: void,
    /// Parse and append the incoming argument to a list.
    append: void,
};

const Delimiter = union(std.mem.DelimiterType) {
    sequence: []const u8,
    any: []const u8,
    scalar: u8,
};

const Help = struct {
    title: []const u8,
    description: []const u8,
    additional: ?struct {
        type: []const u8,
        default: ?[]const u8,
    },

    const FormatContext = struct {
        const INDENT = "  ";
        width: usize,
        offset: usize,
        x: usize,

        fn init(width: usize) FormatContext {
            return .{ .width = width, .offset = width / 3, .x = 0 };
        }

        fn title(ctx: *@This(), text: []const u8, writer: anytype) !void {
            try std.fmt.format(writer, INDENT ++ "{s}:", .{text});
            ctx.x += text.len + INDENT.len + 1;
            if (ctx.x >= ctx.offset) {
                try ctx.newline(writer);
            }
        }

        fn pad(ctx: *@This(), writer: anytype) !void {
            while (ctx.x < ctx.offset) : (ctx.x += 1) {
                try writer.writeByte(' ');
            }
        }

        fn newline(ctx: *@This(), writer: anytype) !void {
            try std.fmt.format(writer, "\n", .{});
            ctx.x = 0;
        }

        fn boundary(ctx: *@This(), writer: anytype) !void {
            try ctx.newline(writer);
            try ctx.newline(writer);
        }

        fn word(ctx: *@This(), text: []const u8, writer: anytype) !void {
            if (ctx.x + text.len + 1 >= ctx.width) {
                try ctx.newline(writer);
            }
            try ctx.pad(writer);
            try std.fmt.format(writer, " {s}", .{text});
            ctx.x += text.len + 1;
        }
    };

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len != 0)
            return std.fmt.invalidFmtError(fmt, self);

        var ctx = FormatContext.init(options.width orelse 80);
        try ctx.title(self.title, writer);
        if (self.description.len != 0) {
            var paragraphs = std.mem.splitSequence(u8, self.description, "\n\n");
            var first_paragraph = true;
            while (paragraphs.next()) |p| {
                if (first_paragraph) {
                    first_paragraph = false;
                } else {
                    try ctx.boundary(writer);
                }
                var words = std.mem.tokenizeAny(u8, p, " \n\t");
                while (words.next()) |word| {
                    try ctx.word(word, writer);
                }
            }
            try ctx.newline(writer);
            try ctx.pad(writer);
        }
        if (self.additional) |additional| {
            var buffer: [1024]u8 = undefined;
            const type_string = try std.fmt.bufPrint(&buffer, "({s})", .{additional.type});
            try ctx.word(type_string, writer);
            try ctx.word(additional.default orelse "required", writer);
        }
    }
};

test Help {
    std.testing.log_level = .debug;
    const help = Help{
        .title = "--output, -o",
        .description = "Output file path",
        .additional = .{
            .type = "string",
            .default = "/var/tmp/output.txt",
        },
    };
    std.log.info("\n{}", .{help});
}

path: []const []const u8,
action: Action = .assign,
long: []const u8 = "",
short: u8 = 0,
metavar: []const u8 = "",
delimiter: ?Delimiter = null,
description: []const u8 = "",

pub fn This(comptime self: @This(), comptime T: type) type {
    return field.DeepFieldType(T, self.path);
}

pub fn this(comptime self: @This(), comptime T: type, ptr: *T) *self.This(T) {
    return field.ptrOf(T, self.path, ptr);
}

pub fn isString(comptime self: @This(), comptime T: type) bool {
    return (self.delimiter == null and self.This(T) == []const u8);
}

pub fn isPositional(comptime self: @This()) bool {
    return self.long.len == 0 and self.short == 0;
}

pub fn isRequired(comptime self: @This(), comptime T: type) bool {
    return switch (self.action) {
        .assign => field.isRequired(T, self.path),
        else => false,
    };
}

pub fn title(comptime self: @This()) []const u8 {
    const print = std.fmt.comptimePrint;
    if (self.long.len != 0 and self.short != 0)
        return print("--{s}, -{c}", .{ self.long, self.short });
    if (self.long.len != 0)
        return print("--{s}", .{self.long});
    if (self.short != 0)
        return print("-{c}", .{self.short});
    if (self.metavar.len != 0)
        return self.metavar;

    const metavar = comptime join: {
        var buffer: [1024]u8 = undefined;
        var n: usize = 0;
        for (self.path) |name| {
            if (n != 0) {
                buffer[n] = '.';
                n += 1;
            }
            for (name) |c| {
                buffer[n] = std.ascii.toUpper(c);
                n += 1;
            }
        }
        break :join buffer[0..n].*;
    };
    return &metavar;
}

fn TokenIterator(comptime self: @This()) type {
    const delimiter = self.delimiter orelse @compileError("Argz.delimiter is required for collections");
    const activeTag = comptime std.meta.activeTag(delimiter);
    return std.mem.TokenIterator(u8, activeTag);
}

pub fn getArgz(comptime T: type) []const @This() {
    comptime if (@hasDecl(T, ".argz"))
        return T.@".argz";
    @compileError("@\".argz\" is required for Argz to parse " ++ @typeName(T));
}

pub fn tokenize(comptime self: @This(), buffer: []const u8) self.TokenIterator() {
    const delimiter = self.delimiter orelse @compileError("Argz.delimiter is required for collections");
    const activeTag = comptime std.meta.activeTag(delimiter);
    const payload = @field(delimiter, @tagName(activeTag));
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = payload,
    };
}
