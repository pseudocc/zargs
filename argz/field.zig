const std = @import("std");
const metaz = @import("meta.zig");
const testing = std.testing;

fn Field(comptime T: type, comptime name: []const u8) std.builtin.Type.StructField {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name))
                    return field;
            }
            @compileError("No such field: \"" ++ name ++ "\" in " ++ @typeName(T));
        },
        .optional => |info| Field(info.child, name),
        else => @compileError("Field lookup is only supported for structs"),
    }
}

pub fn FieldType(comptime T: type, comptime name: []const u8) type {
    return Field(T, name).type;
}

pub fn DeepFieldType(comptime T: type, comptime path: []const []const u8) type {
    var result: type = T;
    inline for (path) |field_name| {
        result = FieldType(result, field_name);
    }
    return result;
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

pub fn ptrOf(comptime T: type, comptime fields: []const []const u8, ptr: *T) *DeepFieldType(T, fields) {
    const fields_ty: [fields.len + 1]type = comptime ty: {
        var result: [fields.len + 1]type = undefined;
        var i: usize = 0;
        result[i] = @TypeOf(ptr.*);
        for (fields) |field| {
            result[i + 1] = FieldType(result[i], field);
            i += 1;
        }
        break :ty result;
    };
    var fields_ptr: [fields.len + 1]usize = undefined;
    fields_ptr[0] = @intFromPtr(ptr);
    inline for (fields, 0..) |field, i| {
        const typed_ptr: *fields_ty[i] = @ptrFromInt(fields_ptr[i]);
        fields_ptr[i + 1] = @intFromPtr(&@field(typed_ptr, field));
    }
    return @ptrFromInt(fields_ptr[fields.len]);
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
    ptrOf(Rectangle, fields, &rect).* = 5;
    try std.testing.expectEqual(5, rect.position.x);
}

fn isRequiredField(comptime field: std.builtin.Type.StructField) bool {
    return !metaz.isOptional(field.type) and field.default_value == null;
}

pub fn isRequired(comptime T: type, comptime path: []const []const u8) bool {
    var field: std.builtin.Type.StructField = Field(T, path[0]);
    if (!isRequiredField(field))
        return false;
    inline for (path[1..]) |field_name| {
        field = Field(field.type, field_name);
        if (!isRequiredField(field))
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
