const std = @import("std");
const testing = std.testing;
const root = @import("root");

const types = @import("types.zig");
const string = types.string;

pub const Base = struct {
    usage: string,
    commands: []const Command = &.{},
    named: []const Parameter = &.{},
    positional: []const Parameter = &.{},
    environment: []const Parameter = &.{},
};

argv: []const string,
base: Base,

pub fn format(
    self: @This(),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    if (fmt.len != 0)
        return std.fmt.invalidFmtError(fmt, self);
    var ctx = FormatContext.init(options.width orelse 80);

    {
        const offset = ctx.offset;
        ctx.offset = FormatContext.INDENT.len;
        defer ctx.offset = offset;

        try ctx.section("USAGE", writer);
        for (self.argv) |arg| {
            try ctx.word(arg, writer);
        }
        try ctx.paragraphs(self.base.usage, writer);
        try ctx.newline(writer);
    }

    const sections = .{
        .{ "COMMANDS", self.base.commands },
        .{ "OPTIONS", self.base.named },
        .{ "ARGUMENTS", self.base.positional },
        .{ "ENVIRONMENT", self.base.environment },
    };

    inline for (sections) |section| {
        const text = section[0];
        const values = section[1];
        if (values.len != 0) {
            try ctx.section(text, writer);
            for (values) |value| {
                try value.formatWith(&ctx, writer);
            }
        }
    }

    try ctx.newline(writer);
}

const Help = @This();

test Help {
    testing.log_level = .debug;
    const build = Command{
        .name = "build",
        .summary = "Build the project.",
    };
    const clean = Command{
        .name = "clean",
        .summary = "Clean the build artifacts.",
    };
    const command_help = Help{
        .argv = &.{"zargs"},
        .base = .{
            .usage = "[COMMAND ...] | [--help]",
            .commands = &.{ build, clean },
        },
    };
    std.log.debug("test Help.Command\n{}", .{command_help});

    const build_num = Parameter{
        .required = true,
        .title = "--build-num, -n NUMBER",
        .description =
        \\This is a FAKE build number for the build which is
        \\totally nonsense, just for testing.
        ,
        .type = "u32",
    };
    const log_level = Parameter{
        .required = false,
        .title = "--log-level, -l LEVEL",
        .description = "The log level for the program.",
        .type = "enum",
        .choices = &.{ "debug", "info", "warn", "error" },
    };
    const source_file = Parameter{
        .required = true,
        .title = "FILE",
        .description = "The source file to build.",
        .type = "string",
    };
    const secret = Parameter{
        .required = false,
        .title = "SSH_SECRET",
        .description = "SSH passphrase for the private key.",
        .type = "string",
    };
    const final_help = Help{
        .argv = &.{ "zargs", "build" },
        .base = .{
            .usage = "[OPTIONS] [ARGS ...]",
            .named = &.{ build_num, log_level },
            .positional = &.{source_file},
            .environment = &.{secret},
        },
    };
    std.log.debug("test Help.Final\n{}", .{final_help});
}

pub const named_help = Parameter{
    .title = "--help",
    .description = "Show this help message and exit.",
};

pub const Parameter = struct {
    required: bool = false,
    title: string,
    description: string,
    type: string = "",
    choices: ?[]const string = null,

    fn formatWith(self: @This(), ctx: *FormatContext, writer: anytype) !void {
        try ctx.title(self.title, writer);
        if (self.type.len != 0) {
            var buffer: [32]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buffer);
            if (self.required) {
                try std.fmt.format(stream.writer(), "required, ", .{});
            }
            try std.fmt.format(stream.writer(), "{s}", .{self.type});
            try ctx.write(.{
                .before = " (",
                .body = stream.getWritten(),
                .after = ")",
                .pad = true,
            }, writer);
        }

        if (self.description.len != 0) {
            try ctx.paragraphs(self.description, writer);
        }

        if (self.choices) |choices| {
            try ctx.newline(writer);
            try ctx.word("choices: [", writer);

            const offset = ctx.offset;
            ctx.offset = ctx.x;
            defer ctx.offset = offset;

            for (choices, 0..) |choice, i| {
                try ctx.write(.{
                    .before = if (i != 0) ", " else " ",
                    .body = choice,
                }, writer);
            }
            try ctx.word("]", writer);
        }

        try ctx.newline(writer);
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len != 0)
            return std.fmt.invalidFmtError(fmt, self);
        var ctx = FormatContext.init(options.width orelse 80);
        try formatWith(self, &ctx, writer);
    }
};

pub const Command = struct {
    name: string,
    summary: ?string,

    fn formatWith(self: @This(), ctx: *FormatContext, writer: anytype) !void {
        try ctx.title(self.name, writer);
        if (self.summary) |summary| {
            try ctx.paragraphs(summary, writer);
        }
        try ctx.newline(writer);
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len != 0)
            return std.fmt.invalidFmtError(fmt, self);
        var ctx = FormatContext.init(options.width orelse 80);
        try formatWith(self, &ctx, writer);
    }
};

pub const FormatContext = struct {
    const INDENT = "  ";
    width: usize,
    offset: usize,
    x: usize,
    y: usize,

    fn init(width: usize) FormatContext {
        return .{ .width = width, .offset = width / 4, .x = 0, .y = 0 };
    }

    fn section(ctx: *@This(), text: string, writer: anytype) !void {
        if (ctx.y != 0) {
            try ctx.newline(writer);
        }
        try ctx.write(.{ .body = text, .after = ":" }, writer);
        try ctx.newline(writer);
    }

    fn title(ctx: *@This(), text: []const u8, writer: anytype) !void {
        try ctx.write(.{
            .before = INDENT,
            .body = text,
        }, writer);
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
        ctx.y += 1;
    }

    const Content = struct {
        before: []const u8 = "",
        body: []const u8,
        after: []const u8 = "",
        pad: bool = false,

        fn len(self: Content) usize {
            return self.before.len + self.body.len + self.after.len;
        }

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            if (fmt.len != 0)
                return std.fmt.invalidFmtError(fmt, self);
            _ = options;
            try std.fmt.format(writer, "{s}{s}{s}", .{ self.before, self.body, self.after });
        }
    };

    fn write(ctx: *@This(), content: Content, writer: anytype) !void {
        const len = content.len();
        if (ctx.x + len >= ctx.width) {
            try ctx.newline(writer);
        }
        if (content.pad) {
            try ctx.pad(writer);
        }
        try std.fmt.format(writer, "{}", .{content});
        ctx.x += len;
    }

    fn paragraphs(ctx: *@This(), text: []const u8, writer: anytype) !void {
        var parts = std.mem.splitSequence(u8, text, "\n\n");
        var first = true;
        while (parts.next()) |p| {
            if (first) {
                first = false;
            } else {
                try ctx.newline(writer);
            }
            var words = std.mem.tokenizeAny(u8, p, " \n\t");
            while (words.next()) |w| {
                try ctx.word(w, writer);
            }
        }
    }

    fn word(ctx: *@This(), text: []const u8, writer: anytype) !void {
        try ctx.write(.{ .before = " ", .body = text, .pad = true }, writer);
    }
};
