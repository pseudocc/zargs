const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Argz = @import("argz/decl.zig");
const ArgIterator = @import("argz/iter.zig");

const Allocator = std.mem.Allocator;
const basic = @import("argz/parse.zig");
const metaz = @import("argz/meta.zig");
const E = basic.ParseError;

const log = if (builtin.is_test) struct {
    const debug = std.log.debug;
    const info = std.log.info;
    const warn = std.log.info;
    const err = std.log.info;
} else std.log.scoped(.argz);

fn parseCommand(comptime T: type, args: *ArgIterator, arena: Allocator) E!T {
    const next_arg = try nextString(args);
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, next_arg)) {
            const value = try parse(field.type, args, arena);
            return @unionInit(T, field.name, value);
        }
    }
    return E.CommandNotFound;
}

fn parseArg(comptime T: type, arg: []const u8) E!T {
    switch (@typeInfo(T)) {
        .@"struct" => @compileError("Nested structs are not supported"),
        else => return basic.parseAny(T, arg),
    }
}

fn nextString(args: *ArgIterator) E![]const u8 {
    args.short_chain = false;
    const arg = args.next() orelse return E.MissingArgument;
    return if (arg == .string) arg.string else E.MissingArgument;
}

fn reaction(
    comptime T: type,
    comptime z: Argz,
    ptr: *T,
    args: *ArgIterator,
    arena: Allocator,
) E!void {
    const This = z.This(T);
    const this: *This = z.this(T, ptr);
    const is_optional = comptime metaz.isOptional(This);
    const is_string = comptime (This == []const u8 and z.delimiter == null);

    log.debug(
        \\T: {s}, path: {s}, long: {s}, short: {c},
        \\delimiter: {any}, action: {},
    , .{
        @typeName(This),
        z.path,
        z.long,
        z.short,
        z.delimiter,
        z.action,
    });

    switch (z.action) {
        .store => |opaque_ptr| {
            const embedded: *const This = @alignCast(@ptrCast(opaque_ptr));
            this.* = embedded.*;
        },
        .increment => |inc| {
            switch (@typeInfo(This)) {
                .int => {
                    const value = this.*;
                    this.* = value + inc;
                },
                .@"enum" => {
                    const value = @intFromEnum(this.*);
                    this.* = @enumFromInt(value + inc);
                },
                else => @compileError("\"increment\" action is only supported for integers and enums, but got: " ++ @typeName(This)),
            }
        },
        .assign => {
            const arg = try nextString(args);
            switch (metaz.typeInfo(This)) {
                .pointer => |pointer| {
                    if (is_optional and std.mem.eql(u8, arg, "null")) {
                        if (this.*) |raw| {
                            arena.free(raw);
                        }
                        this.* = null;
                        return;
                    }

                    var raw: []pointer.child = if (is_optional)
                        @constCast(@ptrCast(this.*))
                    else
                        @constCast(this.*);
                    defer this.* = raw;
                    if (is_string) {
                        raw = try arena.realloc(raw, arg.len);
                        @memcpy(raw, arg);
                    } else {
                        var tokens = z.tokenize(arg);
                        var i: usize = 0;
                        while (tokens.next()) |_| : (i += 1) {}

                        if (i == 0)
                            return E.InvalidInput;

                        raw = try arena.realloc(raw, i);
                        tokens.reset();
                        i = 0;

                        while (tokens.next()) |token| : (i += 1) {
                            raw[i] = try parseArg(pointer.child, token);
                        }
                    }
                },
                .array => |array| {
                    if (is_optional and std.mem.eql(u8, arg, "null")) {
                        this.* = null;
                        return;
                    }

                    this.* = std.mem.zeroes([array.len]array.child);
                    var tokens = z.tokenize(arg);
                    var i: usize = 0;
                    while (tokens.next()) |token| : (i += 1) {
                        if (i >= array.len)
                            return E.ArrayOverflow;
                        this[i] = try parseArg(array.child, token);
                    }

                    if (i < array.len)
                        return E.ArrayUnderflow;
                },
                else => this.* = try parseArg(This, arg),
            }
        },
        .append => {
            const arg = try nextString(args);
            switch (metaz.typeInfo(This)) {
                .pointer => |pointer| {
                    if (is_optional and std.mem.eql(u8, arg, "null"))
                        return;

                    var raw: []pointer.child = if (is_optional)
                        @constCast(@ptrCast(this.*))
                    else
                        @constCast(this.*);
                    const initial_len = raw.len;
                    defer this.* = raw;
                    if (This == []const u8 and z.delimiter == null) {
                        // strings
                        raw = try arena.realloc(raw, initial_len + arg.len);
                        @memcpy(raw[initial_len..], arg);
                    } else {
                        var tokens = z.tokenize(arg);
                        var i: usize = 0;
                        while (tokens.next()) |_| : (i += 1) {}

                        if (i == 0)
                            return E.InvalidInput;

                        raw = try arena.realloc(raw, initial_len + i);
                        tokens.reset();
                        i = initial_len;

                        while (tokens.next()) |token| : (i += 1) {
                            raw[i] = try parseArg(pointer.child, token);
                        }
                    }
                },
                else => @compileError("\"append\" action is only supported for pointers, but got: " ++ @typeName(This)),
            }
        },
    }
}

test reaction {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();

    const A = struct {
        number: i32,
        string: []const u8,
        nested: struct {
            primes: ?[]const u8,
            level: enum { one, two, three },
        },
    };
    var args: ArgIterator = .{
        .args = &.{ "24", "Kobe", " Bryant", "2,3", "5,7", "23", "two" },
        .index = 0,
    };

    const z_store_i32: Argz = .{
        .path = &.{"number"},
        .action = .{ .store = &@as(i32, 42) },
    };
    const z_assign_i32: Argz = .{
        .path = &.{"number"},
        .action = .assign,
    };
    const z_increment_i32: Argz = .{
        .path = &.{"number"},
        .action = .{ .increment = 1 },
    };
    const z_assign_string: Argz = .{
        .path = &.{"string"},
        .action = .assign,
    };
    const z_append_string: Argz = .{
        .path = &.{"string"},
        .action = .append,
    };
    const z_assign_nested_u8: Argz = .{
        .path = &.{ "nested", "primes" },
        .action = .assign,
        .delimiter = .{ .scalar = ',' },
    };
    const z_append_nested_u8: Argz = .{
        .path = &.{ "nested", "primes" },
        .action = .append,
        .delimiter = .{ .scalar = ',' },
    };
    const z_assign_nested_enum: Argz = .{
        .path = &.{ "nested", "level" },
        .action = .assign,
    };
    const z_increment_nested_enum: Argz = .{
        .path = &.{ "nested", "level" },
        .action = .{ .increment = 1 },
    };

    var a: A = std.mem.zeroInit(A, .{});
    defer arena.deinit();

    try reaction(A, z_store_i32, &a, &args, allocator);
    try testing.expectEqual(a.number, 42);
    try reaction(A, z_assign_i32, &a, &args, allocator);
    try testing.expectEqual(a.number, 24);
    try reaction(A, z_increment_i32, &a, &args, allocator);
    try testing.expectEqual(a.number, 25);

    try reaction(A, z_assign_string, &a, &args, allocator);
    try testing.expectEqualStrings(a.string, "Kobe");
    try reaction(A, z_append_string, &a, &args, allocator);
    try testing.expectEqualStrings(a.string, "Kobe Bryant");

    try reaction(A, z_append_nested_u8, &a, &args, allocator);
    try testing.expectEqualSlices(u8, a.nested.primes.?, &.{ 2, 3 });
    try reaction(A, z_append_nested_u8, &a, &args, allocator);
    try testing.expectEqualSlices(u8, a.nested.primes.?, &.{ 2, 3, 5, 7 });
    try reaction(A, z_assign_nested_u8, &a, &args, allocator);
    try testing.expectEqualSlices(u8, a.nested.primes.?, &.{23});

    try reaction(A, z_assign_nested_enum, &a, &args, allocator);
    try testing.expectEqual(a.nested.level, .two);
    try reaction(A, z_increment_nested_enum, &a, &args, allocator);
    try testing.expectEqual(a.nested.level, .three);
}

fn parseFinal(comptime T: type, args: *ArgIterator, arena: Allocator) E!T {
    const argz = Argz.getArgz(T);
    var result = comptime std.mem.zeroInit(T, .{});
    var finishes: [argz.len]bool = .{false} ** argz.len;

    while (args.peek()) |arg| {
        var found = false;
        switch (arg) {
            .string => |string| log.debug("Parsing {s}", .{string}),
            .short_option => |short| log.debug("Parsing -{c}", .{short}),
            .long_option => |long| log.debug("Parsing --{s}", .{long}),
        }

        inline for (argz, 0..) |z, i| if (!finishes[i]) {
            switch (arg) {
                .long_option => |long| if (std.mem.eql(u8, long, z.long)) {
                    args.advance();
                    found = true;
                },
                .short_option => |short| if (short == z.short) {
                    args.advance();
                    found = true;
                },
                .string => if (z.isPositional()) {
                    found = true;
                },
            }

            if (found) {
                if (z.action != .append)
                    finishes[i] = true;
                try reaction(T, z, &result, args, arena);
                break;
            }
        };

        if (!found) {
            log.err("No match for argument: {}", .{arg});
            return if (arg == .string)
                E.UnhandledPositional
            else
                E.UnknownOption;
        }
    }

    return result;
}

fn parse(comptime T: type, args: *ArgIterator, arena: Allocator) E!T {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .void => return,
        // Subcommands
        .@"union" => parseCommand(T, args, arena),
        // Options, flags, and arguments
        .@"struct" => parseFinal(T, args, arena),
        else => basic: {
            const next_arg = try nextString(args);
            break :basic basic.parseAny(T, next_arg);
        },
    };
}

const Self = @This();

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn parse(self: *Parser, comptime T: type, args: []const [:0]const u8) E!T {
        var iter = ArgIterator{ .args = args };
        const allocator = self.arena.allocator();
        return Self.parse(T, &iter, allocator);
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }
};

test Parser {
    testing.log_level = .info;

    var parser = Parser.init(testing.allocator);
    defer parser.deinit();

    {
        const integer = try parser.parse(i32, &.{"42"});
        try testing.expectEqual(42, integer);
    }

    {
        const Commands = union(enum) {
            add: struct {
                a: i32,
                b: i32,

                pub const @".argz" = &.{
                    .{ .path = &.{"a"}, .action = .assign },
                    .{ .path = &.{"b"}, .action = .assign },
                };
            },
            noop: void,
        };

        const add = try parser.parse(Commands, &.{ "add", "42", "24" });
        try testing.expectEqualDeep(Commands{ .add = .{ .a = 42, .b = 24 } }, add);

        const noop = try parser.parse(Commands, &.{"noop"});
        try testing.expectEqual(Commands.noop, noop);
    }

    {
        const Simple = struct {
            optimize_level: i32,
            defines: []const []const u8,
            filename: []const u8,

            pub const @".argz" = &.{
                .{
                    .long = "release",
                    .path = &.{"optimize_level"},
                    .action = .{ .store = &@as(i32, 3) },
                },
                .{
                    .long = "debug",
                    .path = &.{"optimize_level"},
                    .action = .{ .store = &@as(i32, 0) },
                },
                .{
                    .short = 'D',
                    .path = &.{"defines"},
                    .action = .append,
                    .delimiter = .{ .scalar = ',' },
                },
                .{
                    .path = &.{"filename"},
                    .action = .assign,
                },
            };
        };

        const debug = try parser.parse(Simple, &.{ "--debug", "-D", "FOO", "-DBAR", "main.c" });
        try testing.expectEqual(0, debug.optimize_level);
        try testing.expectEqual(2, debug.defines.len);
        try testing.expectEqualStrings("FOO", debug.defines[0]);
        try testing.expectEqualStrings("BAR", debug.defines[1]);
        try testing.expectEqualStrings("main.c", debug.filename);

        const release = try parser.parse(Simple, &.{ "--release", "main.c", "-DFOO" });
        try testing.expectEqual(3, release.optimize_level);
        try testing.expectEqual(1, release.defines.len);
        try testing.expectEqualStrings("FOO", release.defines[0]);
        try testing.expectEqualStrings("main.c", release.filename);
    }
}
