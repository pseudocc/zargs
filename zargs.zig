const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Final = @import("zargs/final.zig");
const Command = @import("zargs/command.zig");
const Help = @import("zargs/help.zig");
const ArgIterator = @import("zargs/iterator.zig");
pub const log = @import("zargs/log.zig");

const types = @import("zargs/types.zig");
pub const string = types.string;
pub const cstring = types.cstring;

pub const primary = @import("zargs/parse.zig");
const E = types.ParseError;

const Self = @This();

arena: std.heap.ArenaAllocator,
args: ArgIterator,
file: std.fs.File.Writer,

pub fn init(allocator: Allocator, args: []const cstring) Self {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .args = ArgIterator{ .args = args },
        .file = std.io.getStdErr().writer(),
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

fn Next(comptime kind: ArgIterator.ItemKind) type {
    return std.meta.TagPayload(ArgIterator.Item, kind);
}

fn next(self: *Self, comptime kind: ArgIterator.ItemKind) E!Next(kind) {
    switch (kind) {
        .string => self.args.short_chain = false,
        else => {},
    }
    if (self.args.next()) |arg| {
        if (arg != kind) {
            log.err("Unexpected argument: {}", .{arg});
            return E.UnexpectedArgument;
        }
        return @field(arg, @tagName(kind));
    }
    log.err("Missing argument: {s}", .{@tagName(kind)});
    return E.MissingArgument;
}

fn parseCommand(self: *Self, comptime T: type) E!T {
    if (self.args.peek()) |arg| {
        if (arg.isHelp()) {
            const help = Command.help(T, self.args.argv());
            self.file.print("{}", .{help}) catch {};
            return E.HelpRequested;
        }
        if (arg.isOption()) {
            log.err("Unknown option: {}", .{arg});
            return E.UnknownOption;
        }
    }

    const arg = try self.next(.string);
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, arg)) {
            log.debug("parseCommand: {s}", .{field.name});
            const value = try self.parse(field.type);
            return @unionInit(T, field.name, value);
        }
    }

    log.err("Unknown command: {s}", .{arg});
    return E.UnknownCommand;
}

fn parseFinalOne(comptime T: type, arg: []const u8, allocator: Allocator) E!T {
    if (T == string) {
        return allocator.dupeZ(u8, arg);
    }
    if (types.custom.parse_fn(T)) |parse_fn| {
        return parse_fn(arg, allocator);
    }
    return primary.parseAny(T, arg);
}

test parseFinalOne {
    const A = struct {
        x: i32,
        y: i32 = 42,

        pub fn parse(arg: []const u8, allocator: Allocator) E!@This() {
            _ = allocator;
            var parts = std.mem.splitScalar(u8, arg, ',');
            const x_part = std.mem.trim(u8, parts.next() orelse return E.MissingRequired, " ");
            const y_part = std.mem.trim(u8, parts.next() orelse return E.MissingRequired, " ");

            var a = std.mem.zeroInit(@This(), .{});
            if (x_part.len > 0) {
                a.x = try primary.parseInt(i32, x_part);
            }
            if (y_part.len > 0) {
                a.y = try primary.parseInt(i32, y_part);
            }

            return a;
        }
    };

    const allocator = testing.allocator;
    const a_1_2 = try parseFinalOne(A, "1,2", allocator);
    try testing.expectEqualDeep(A{ .x = 1, .y = 2 }, a_1_2);
    const a_1_default = try parseFinalOne(A, "1,", allocator);
    try testing.expectEqualDeep(A{ .x = 1 }, a_1_default);
}

fn countFinalMany(iterator: anytype) E!usize {
    var i: usize = 0;
    while (iterator.next()) |_| : (i += 1) {}
    if (i == 0) {
        return E.InvalidInput;
    }
    iterator.reset();
    log.debug("countFinalMany -> {d}", .{i});
    return i;
}

fn parseFinalAny(
    comptime T: type,
    comptime param: Final.Declaration,
    container: *T,
    input: string,
    allocator: Allocator,
) E!void {
    const field = param.Field(T);
    const this = field.ptrOf(container);
    const concrete_type = field.concreteType();

    const append = switch (param.parameter) {
        .named => |named| named.action == .append,
        else => false,
    };

    if (concrete_type == string) {
        const ptr: ?string = this.*;

        this.* = if (append)
            try std.fmt.allocPrintZ(allocator, "{s}{s}{s}", .{
                ptr orelse "",
                if (param.delimiter) |d| d.sequence else "",
                input,
            })
        else
            try allocator.dupeZ(u8, input);

        return;
    }

    switch (@typeInfo(concrete_type)) {
        .pointer => |info| {
            var ptr: []info.child = if (field.is_optional)
                @constCast(@ptrCast(this.*))
            else
                @constCast(this.*);
            const initial_len = if (append) ptr.len else 0;
            defer this.* = ptr;

            var parts = param.split(input);
            const n = countFinalMany(&parts) catch |err| {
                log.err("Failed to parse {s}", .{param.title()});
                return err;
            };

            ptr = try allocator.realloc(ptr, initial_len + n);
            for (ptr[initial_len..]) |*p| {
                const part = parts.next().?;
                p.* = try parseFinalOne(info.child, part, allocator);
            }
        },
        .array => |info| {
            var parts = param.split(input);
            const n = countFinalMany(&parts) catch |err| {
                log.err("Failed to parse {s}", .{param.title()});
                return err;
            };
            if (n != info.len) {
                log.err("Array length mismatch: {d} != {d}", .{ n, info.len });
                return if (n > info.len) E.ArrayOverflow else E.ArrayUnderflow;
            }

            var array = std.mem.zeroes([info.len]info.child);
            defer this.* = array;

            for (&array) |*p| {
                const part = parts.next().?;
                p.* = try parseFinalOne(info.child, part, allocator);
            }
        },
        else => {
            this.* = try parseFinalOne(field.type, input, allocator);
        },
    }
}

test parseFinalAny {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Color = enum {
        red,
        green,
        blue,
    };
    const Container = struct {
        string: string,
        nullable_string: ?string,
        ascii: u8,
        pin: [6]u8,
        colors: ?[]const Color,
    };
    var container = std.mem.zeroInit(Container, .{});
    const param_string = Final.Declaration{
        .parameter = .{ .named = .{ .short = '0' } },
        .path = &.{"string"},
    };

    try parseFinalAny(Container, param_string, &container, "world", arena.allocator());
    try testing.expectEqualStrings("world", container.string);

    const param_nullable_string = Final.Declaration{
        .parameter = .{ .named = .{ .short = '0' } },
        .path = &.{"nullable_string"},
    };
    try parseFinalAny(Container, param_nullable_string, &container, "test", arena.allocator());
    try testing.expectEqualStrings("test", container.nullable_string.?);

    const param_nullable_string_append = Final.Declaration{
        .parameter = .{ .named = .{ .short = '0', .action = .append } },
        .path = &.{"nullable_string"},
    };
    try parseFinalAny(Container, param_nullable_string_append, &container, "ing", arena.allocator());
    try testing.expectEqualStrings("testing", container.nullable_string.?);

    const param_ascii = Final.Declaration{
        .parameter = .{ .named = .{ .short = '0' } },
        .path = &.{"ascii"},
    };
    try parseFinalAny(Container, param_ascii, &container, "124", arena.allocator());
    try testing.expectEqual(124, container.ascii);

    const param_pin = Final.Declaration{
        .parameter = .{ .named = .{ .short = '0' } },
        .path = &.{"pin"},
        .delimiter = .{ .scalar = ',' },
    };
    try parseFinalAny(Container, param_pin, &container, "1,2,3,4,5,6", arena.allocator());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &container.pin);

    const param_colors = Final.Declaration{
        .parameter = .{ .named = .{ .short = '0', .action = .append } },
        .path = &.{"colors"},
        .delimiter = .{ .scalar = ',' },
    };
    try parseFinalAny(Container, param_colors, &container, "red", arena.allocator());
    try testing.expectEqualSlices(Color, &.{.red}, container.colors.?);
    try parseFinalAny(Container, param_colors, &container, "green,blue", arena.allocator());
    try testing.expectEqualSlices(Color, &.{ .red, .green, .blue }, container.colors.?);
}

fn parseFinal(self: *Self, comptime T: type) E!T {
    if (!@hasDecl(T, "zargs") or @TypeOf(T.zargs) != Final) {
        @compileError("Expected a struct with an `const zargs: zargs.Final` field");
    }

    const final: Final = T.zargs;
    var value = std.mem.zeroInit(T, .{});

    const allocator = self.arena.allocator();
    const env_params = final.parameters(.environment);
    inline for (env_params) |param| {
        const env = param.parameter.environment;
        for (std.os.environ) |cpair| {
            const pair = std.mem.sliceTo(cpair, 0);
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const input = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, env.name)) {
                log.debug("parseFinal(env): {s}={s}", .{ env.name, input });
                try parseFinalAny(T, param, &value, input, allocator);
            }
        }
    }

    const opt_params = comptime final.parameters(.named);
    var opt_finishes = std.mem.zeroes([opt_params.len]bool);
    const arg_params = comptime final.parameters(.positional);
    var arg_finishes = std.mem.zeroes([arg_params.len]bool);

    args_loop: while (self.args.peek()) |arg| {
        var found = false;
        if (arg.isHelp()) {
            const help = Final.help(T, self.args.argv());
            self.file.print("{}", .{help}) catch {};
            return E.HelpRequested;
        }
        if (arg.isOption()) {
            inline for (opt_params, 0..) |p, i| {
                const named = p.parameter.named;
                switch (arg) {
                    .long_option => |long| found = std.mem.eql(u8, long, named.long),
                    .short_option => |short| found = short == named.short,
                    else => unreachable,
                }

                if (found) {
                    opt_finishes[i] = true;
                    self.args.advance();

                    const field = p.Field(T);
                    const this = field.ptrOf(&value);
                    switch (named.action) {
                        .increment => |inc| {
                            log.debug("parseFinal(opt,increment): {}", .{arg});
                            switch (@typeInfo(field.type)) {
                                .int => {
                                    const former = this.*;
                                    this.* = former + inc;
                                },
                                .@"enum" => {
                                    const former = @intFromEnum(this.*);
                                    this.* = try std.meta.intToEnum(field.type, former + inc);
                                },
                                else => unreachable,
                            }
                        },
                        .assign => |maybe_constant| {
                            if (maybe_constant) |opaque_ptr| {
                                const constant: *const field.type = @alignCast(@ptrCast(opaque_ptr));
                                log.debug("parseFinal(opt,assign_constant): {} -> " ++
                                    if (field.concreteType() == string) "{s}" else "{any}", .{ arg, constant });
                                this.* = constant.*;
                            } else {
                                const next_arg = try self.next(.string);
                                log.debug("parseFinal(opt,assign): {} -> {s}", .{ arg, next_arg });
                                try parseFinalAny(T, p, &value, next_arg, allocator);
                            }
                        },
                        .append => {
                            const next_arg = try self.next(.string);
                            log.debug("parseFinal(opt,append): {} -> {s}", .{ arg, next_arg });
                            try parseFinalAny(T, p, &value, next_arg, allocator);
                        },
                    }

                    continue :args_loop;
                }
            }

            log.err("Unknown option: {}", .{arg});
            return E.UnknownOption;
        } else {
            inline for (arg_params, 0..) |p, i| if (!arg_finishes[i]) {
                const next_arg = self.next(.string) catch unreachable;
                log.debug("parseFinal(arg): {s} -> {s}", .{ p.title(), next_arg });
                try parseFinalAny(T, p, &value, next_arg, allocator);
                arg_finishes[i] = true;
                continue :args_loop;
            };

            log.err("Unexpected argument: {}", .{arg});
            return E.UnexpectedArgument;
        }
    }

    inline for (opt_params, 0..) |p, i| if (comptime p.isRequired(T)) {
        if (!opt_finishes[i]) {
            log.err("Missing required argument: {s}", .{p.title()});
            return E.MissingRequired;
        }
    };
    inline for (arg_params, 0..) |p, i| if (comptime p.isRequired(T)) {
        if (!arg_finishes[i]) {
            log.err("Missing required argument: {s}", .{p.title()});
            return E.MissingRequired;
        }
    };

    return value;
}

pub fn parse(self: *Self, comptime T: type) E!T {
    switch (@typeInfo(T)) {
        .void => return,
        .@"union" => return self.parseCommand(T),
        .@"struct" => return self.parseFinal(T),
        else => {
            const next_arg = try self.next(.string);
            return primary.parseAny(T, next_arg);
        },
    }
}

fn e2ePrepare(self: *Self, args: []const cstring) void {
    self.args = ArgIterator{ .args = args, .index = 0 };
}

test "e2e" {
    var parser = init(testing.allocator, &.{});
    defer parser.deinit();

    {
        parser.e2ePrepare(&.{"42"});
        const integer = try parser.parse(i32);
        try testing.expectEqual(42, integer);
    }

    {
        const Math = union(enum) {
            add: struct {
                a: i32,
                b: i32,

                pub const zargs = Final{ .args = &.{
                    .{
                        .path = &.{"a"},
                        .parameter = .{ .positional = .{ .metavar = "A" } },
                    },
                    .{
                        .path = &.{"b"},
                        .parameter = .{ .positional = .{ .metavar = "B" } },
                    },
                } };
            },
            noop,
        };

        parser.e2ePrepare(&.{ "add", "1", "2" });
        const add = try parser.parse(Math);
        try testing.expectEqualDeep(Math{ .add = .{ .a = 1, .b = 2 } }, add);

        parser.e2ePrepare(&.{"noop"});
        const noop = try parser.parse(Math);
        try testing.expectEqual(Math.noop, noop);

        parser.e2ePrepare(&.{ "add", "1" });
        const failure = parser.parse(Math);
        try testing.expectError(E.MissingRequired, failure);
    }

    {
        const Simple = struct {
            optimize_level: u8,
            defines: []const string,
            file: string,

            pub const zargs = Final{ .args = &.{
                .{
                    .path = &.{"optimize_level"},
                    .parameter = .{
                        .named = .{
                            .long = "release",
                            .action = .{ .assign = &@as(u8, 3) },
                        },
                    },
                },
                .{
                    .path = &.{"optimize_level"},
                    .parameter = .{
                        .named = .{
                            .long = "debug",
                            .action = .{ .assign = &@as(u8, 0) },
                        },
                    },
                },
                .{
                    .path = &.{"defines"},
                    .parameter = .{
                        .named = .{
                            .short = 'D',
                            .action = .append,
                        },
                    },
                    .delimiter = .{ .scalar = ',' },
                },
                .{
                    .path = &.{"file"},
                    .parameter = .{ .positional = .{ .metavar = "FILE" } },
                },
            } };
        };

        parser.e2ePrepare(&.{ "--debug", "-D", "FOO", "-DBAR", "main.c" });
        const debug = try parser.parse(Simple);
        try testing.expectEqual(0, debug.optimize_level);
        try testing.expectEqual(2, debug.defines.len);
        try testing.expectEqualStrings("FOO", debug.defines[0]);
        try testing.expectEqualStrings("BAR", debug.defines[1]);
        try testing.expectEqualStrings("main.c", debug.file);
    }

    {
        const Cord = struct {
            x: i32,
            y: i32,

            pub const zargs = Final{ .args = &.{
                .{
                    .path = &.{"x"},
                    .parameter = .{ .named = .{
                        .short = 'l',
                        .action = .{ .increment = -1 },
                    } },
                },
                .{
                    .path = &.{"x"},
                    .parameter = .{ .named = .{
                        .short = 'r',
                        .action = .{ .increment = 1 },
                    } },
                },
                .{
                    .path = &.{"y"},
                    .parameter = .{ .named = .{
                        .short = 'u',
                        .action = .{ .increment = 1 },
                    } },
                },
                .{
                    .path = &.{"y"},
                    .parameter = .{ .named = .{
                        .short = 'd',
                        .action = .{ .increment = -1 },
                    } },
                },
            } };
        };

        parser.e2ePrepare(&.{"-llrud"});
        const cord = try parser.parse(Cord);
        try testing.expectEqualDeep(Cord{ .x = -1, .y = 0 }, cord);
    }

    {
        const CommandUsage = union(enum) {
            number: u32,
            nothing,

            const Tag = std.meta.Tag(@This());
            pub fn summary(active: Tag) string {
                return switch (active) {
                    .number => "print a number",
                    .nothing => "do nothing",
                };
            }
        };

        parser.args = ArgIterator{ .args = &.{ "command-test", "--help" } };
        parser.file.writeAll("=== BEGIN COMMAND HELP ===\n") catch {};
        defer parser.file.writeAll("=== END COMMAND HELP ===\n") catch {};

        const help = parser.parse(CommandUsage);
        try testing.expectError(E.HelpRequested, help);
    }

    {
        const Verbosity = enum {
            silent,
            normal,
            verbose,
            debug,
        };
        const FinalUsage = struct {
            verbose_level: Verbosity = .normal,
            fake_input: string,

            const verbose_up = Final.Declaration{
                .path = &.{"verbose_level"},
                .parameter = .{ .named = .{
                    .short = 'v',
                    .action = .{ .increment = 1 },
                } },
                .description = "Increase verbosity level.",
            };

            const quiet = Final.Declaration{
                .path = &.{"verbose_level"},
                .parameter = .{ .named = .{
                    .short = 'q',
                    .action = .{ .assign = &@as(Verbosity, .silent) },
                } },
                .description = "Quiet mode.",
            };

            const verbosity = Final.Declaration{
                .path = &.{"verbose_level"},
                .parameter = .{ .named = .{ .long = "verbosity", .metavar = "LEVEL" } },
                .description = "Set verbosity level.",
            };

            const input = Final.Declaration{
                .path = &.{"fake_input"},
                .parameter = .{ .positional = .{ .metavar = "INPUT" } },
                .description = "Fake input file.",
            };

            pub const zargs = Final{
                .args = &.{ verbose_up, quiet, verbosity, input },
                .summary = "Run a simple program.",
            };
        };

        parser.args = ArgIterator{ .args = &.{ "final-test", "--help" } };
        parser.file.writeAll("=== BEGIN FINAL HELP ===\n") catch {};
        defer parser.file.writeAll("=== END FINAL HELP ===\n") catch {};

        const help = parser.parse(FinalUsage);
        try testing.expectError(E.HelpRequested, help);
    }
}
