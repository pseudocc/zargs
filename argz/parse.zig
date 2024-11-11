const std = @import("std");

const testing = std.testing;
const Type = std.builtin.Type;

pub const ParseError = error{
    UnknownOption,
    UnhandledPositional,
    MissingArgument,
    InvalidInput,
    IntegerOverflow,
    CommandNotFound,
    ArrayOverflow,
    ArrayUnderflow,
    NotSupported,
} || std.mem.Allocator.Error;

const E = ParseError;
pub const Boolean = enum {
    true,
    false,
};

pub fn parseAny(comptime T: type, arg: []const u8) ParseError!T {
    if (T == []const u8)
        return arg;
    switch (@typeInfo(T)) {
        .void => return,
        .optional => |inner| {
            if (std.mem.eql(u8, arg, "null"))
                return null;
            return try parseAny(inner.child, arg);
        },
        .bool => return parseBoolean(arg),
        .int => return parseInt(T, arg),
        .float => return parseFloat(T, arg),
        .@"enum" => return parseEnum(T, arg),
        .@"union" => return parseUnion(T, arg),
        .@"struct", .array, .pointer => @compileError("Complex types require a declaration of Argz: " ++ @typeName(T)),
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

pub fn parseBoolean(arg: []const u8) ParseError!bool {
    const boolean = try parseEnum(Boolean, arg);
    return boolean == .true;
}

test parseBoolean {
    const func = parseBoolean;
    try testing.expectEqual(true, try func("true"));
    try testing.expectEqual(false, try func("false"));
    try testing.expectError(E.InvalidInput, func("wrong"));
}

pub fn parseInt(comptime T: type, arg: []const u8) ParseError!T {
    return std.fmt.parseInt(T, arg, 0) catch |err| switch (err) {
        error.Overflow => E.IntegerOverflow,
        error.InvalidCharacter => E.InvalidInput,
    };
}

pub fn parseFloat(comptime T: type, arg: []const u8) ParseError!T {
    return std.fmt.parseFloat(T, arg) catch |err| switch (err) {
        error.InvalidCharacter => E.InvalidInput,
    };
}

pub fn parseEnum(comptime T: type, arg: []const u8) ParseError!T {
    return std.meta.stringToEnum(T, arg) orelse E.InvalidInput;
}

pub fn parseUnion(comptime T: type, arg: []const u8) ParseError!T {
    if (arg.len == 0)
        return E.MissingArgument;

    const last = arg[arg.len - 1];
    const tag_name = if (last != ')')
        arg
    else if (std.mem.indexOfScalar(u8, arg, '(')) |index|
        arg[0..index]
    else
        return E.InvalidInput;

    const inner = if (last != ')') "" else arg[tag_name.len + 1 .. arg.len - 1];
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, tag_name)) {
            const payload = try parseAny(field.type, inner);
            return @unionInit(T, field.name, payload);
        }
    }

    return E.InvalidInput;
}

test parseUnion {
    const func = parseUnion;
    const A = union(enum) {
        a: u8,
        b: u16,
        nothing: void,
    };
    const AA = union(enum) {
        a: A,
        b: void,
    };
    testing.log_level = .debug;
    try testing.expectEqual(A{ .a = 8 }, try func(A, "a(8)"));
    try testing.expectEqual(AA{ .a = .nothing }, try func(AA, "a(nothing)"));
    try testing.expectEqual(AA{ .a = .{ .b = 8 } }, try func(AA, "a(b(8))"));
}
