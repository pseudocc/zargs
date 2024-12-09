const std = @import("std");
const metaz = @import("meta.zig");
const testing = std.testing;

const builtin = std.builtin.Type;

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value: ?*const anyopaque,
    is_comptime: bool,
    offset: comptime_int,

    pub fn from(comptime T: type, field: builtin.StructField) StructField {
        return StructField{
            .name = field.name,
            .type = field.type,
            .default_value = field.default_value,
            .is_comptime = field.is_comptime,
            .offset = @offsetOf(T, field.name),
        };
    }

    pub fn isRequired(self: StructField) bool {
        return !metaz.isOptional(self.type) and self.default_value == null;
    }
};

pub fn Field(comptime T: type, comptime name: []const u8) StructField {
    const builtin_field = switch (@typeInfo(T)) {
        .@"struct" => |info| z: {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name))
                    break :z field;
            }
            @compileError("No such field: \"" ++ name ++ "\" in " ++ @typeName(T));
        },
        .optional => |info| Field(info.child, name),
        else => @compileError("Field lookup is only supported for structs"),
    };
    return StructField.from(T, builtin_field);
}

pub fn DeepField(comptime T: type, comptime path: []const []const u8) StructField {
    var now: StructField = std.mem.zeroInit(StructField, .{ .type = T });
    inline for (path) |name| {
        var next = Field(now.type, name);
        next.offset += now.offset;
        now = next;
    }
    return now;
}

fn count(comptime path: []const u8) usize {
    return std.mem.count(u8, path, ".") + 1;
}

pub fn splitPath(comptime path: []const u8) []const []const u8 {
    var result: [count(path) + 1][]const u8 = undefined;

    var fields = std.mem.tokenizeScalar(u8, path, '.');
    var i: usize = 0;
    while (fields.next()) |field| : (i += 1) {
        result[i] = field;
    }

    const final = result[0..i].*;
    return &final;
}

test splitPath {
    const fields = comptime splitPath("position.x");
    try std.testing.expectEqualStrings("position", fields[0]);
    try std.testing.expectEqualStrings("x", fields[1]);
}

pub fn ptrOf(comptime T: type, comptime fields: []const []const u8, container: *T) *DeepField(T, fields).type {
    const field = DeepField(T, fields);
    return @ptrFromInt(@intFromPtr(container) + field.offset);
}

test ptrOf {
    const Rectangle = struct {
        position: struct {
            x: u32,
            y: u32,
        },
        size: struct {
            width: u32,
            height: u32,
        },
    };
    var rect = Rectangle{
        .position = .{ .x = 1, .y = 2 },
        .size = .{ .width = 3, .height = 4 },
    };

    try std.testing.expectEqual(1, rect.position.x);
    const fields = comptime splitPath("position.x");
    try std.testing.expectEqual(0, DeepField(Rectangle, fields).offset);
    ptrOf(Rectangle, fields, &rect).* = 5;
    try std.testing.expectEqual(5, rect.position.x);
}

pub fn isRequired(comptime T: type, comptime path: []const []const u8) bool {
    var field: StructField = std.mem.zeroInit(StructField, .{ .type = T });
    inline for (path) |field_name| {
        field = Field(field.type, field_name);
        if (!field.isRequired())
            return false;
    }
    return true;
}

test isRequired {
    const A = struct {
        a: i32,
        b: ?i32,
        c: i32 = 0,
    };

    comptime {
        try testing.expectEqual(true, isRequired(A, &.{"a"}));
        try testing.expectEqual(false, isRequired(A, &.{"b"}));
        try testing.expectEqual(false, isRequired(A, &.{"c"}));
    }
}
