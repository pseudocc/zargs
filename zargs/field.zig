const std = @import("std");
const testing = std.testing;

const builtin = std.builtin.Type;
const types = @import("types.zig");
const string = types.string;

pub fn enumEntries(comptime T: type) []const string {
    comptime {
        const info = @typeInfo(T).@"enum";
        const len = info.fields.len;
        var array: [len]string = undefined;
        for (info.fields, 0..) |f, i| {
            array[i] = f.name;
        }
        const final = array[0..len];
        return final;
    }
}

pub const StructField = struct {
    type: type,
    container_type: type,
    is_optional: bool,
    default_value: ?*const anyopaque,
    offset: comptime_int,

    fn init(comptime T: type) StructField {
        return std.mem.zeroInit(StructField, .{
            .type = T,
            .container_type = T,
            .is_optional = @typeInfo(T) == .optional,
        });
    }

    fn from(comptime T: type, field: builtin.StructField) StructField {
        return .{
            .type = field.type,
            .container_type = T,
            .is_optional = @typeInfo(field.type) == .optional,
            .default_value = field.default_value_ptr,
            .offset = @offsetOf(T, field.name),
        };
    }

    pub fn ptrOf(self: StructField, container: *const anyopaque) *self.type {
        return @ptrFromInt(@intFromPtr(container) + self.offset);
    }

    test ptrOf {
        const Rectangle = struct {
            position: struct {
                x: u32,
                y: u32,
            },
            size: ?struct {
                width: u32,
                height: u32,
            },
        };
        var rect = Rectangle{
            .position = .{ .x = 1, .y = 2 },
            .size = .{ .width = 3, .height = 4 },
        };

        try std.testing.expectEqual(1, rect.position.x);
        const position_x = DeepField(Rectangle, &.{ "position", "x" });
        const size_height = DeepField(Rectangle, &.{ "size", "height" });
        const size = DeepField(Rectangle, &.{"size"});

        position_x.ptrOf(&rect).* = 5;
        try std.testing.expectEqual(5, rect.position.x);

        size_height.ptrOf(&rect).* = 6;
        try std.testing.expectEqual(6, rect.size.?.height);

        size.ptrOf(&rect).* = null;
        try std.testing.expectEqual(null, rect.size);
    }

    pub fn concreteType(self: StructField) type {
        comptime {
            return self.maybeOptional() orelse self.type;
        }
    }

    pub fn maybeOptional(self: StructField) ?type {
        comptime {
            return switch (@typeInfo(self.type)) {
                .optional => |info| info.child,
                else => null,
            };
        }
    }

    test maybeOptional {
        const C = struct { a: ?i32, b: i32 };

        comptime {
            try std.testing.expectEqual(i32, Field(C, "a").maybeOptional().?);
            try std.testing.expectEqual(null, Field(C, "b").maybeOptional());
        }
    }

    pub fn maybeDefault(self: StructField) ?self.type {
        comptime {
            if (self.default_value) |value| {
                const ptr: *align(1) const self.type = @ptrCast(value);
                const final = ptr.*;
                return final;
            }
            return if (self.is_optional) @as(self.type, null) else null;
        }
    }

    test maybeDefault {
        const C = struct {
            a: u8 = 1,
            b: struct {
                c: u8 = 2,
                d: u8,
            } = .{ .c = 3, .d = 4 },
            c: struct {
                d: u8 = 2,
                e: u8,
            },
            f: ?struct {
                g: u8 = 3,
                h: u8,
            },
        };

        comptime {
            try testing.expectEqual(1, DeepField(C, &.{"a"}).maybeDefault().?);
            try testing.expectEqual(3, DeepField(C, &.{ "b", "c" }).maybeDefault().?);
            try testing.expectEqual(4, DeepField(C, &.{ "b", "d" }).maybeDefault().?);
            try testing.expectEqual(null, DeepField(C, &.{"c"}).maybeDefault());
            try testing.expectEqual(null, DeepField(C, &.{ "c", "e" }).maybeDefault());
            try testing.expectEqual(null, DeepField(C, &.{"f"}).maybeDefault().?);
            try testing.expectEqual(null, DeepField(C, &.{ "f", "g" }).maybeDefault());
        }
    }

    fn formatType(comptime T: type) string {
        const format = std.fmt.comptimePrint;
        comptime {
            if (T == string)
                return "string";
            return switch (@typeInfo(T)) {
                .pointer => |info| format("[]{s}", .{formatType(info.child)}),
                .optional => |info| format("?{s}", .{formatType(info.child)}),
                .array => |info| format("[{d}]{s}", .{ info.len, formatType(info.child) }),
                .@"enum" => "enum",
                else => @typeName(T),
            };
        }
    }

    test formatType {
        const Case = struct {
            expected: string,
            actual: type,
        };
        const E = enum { A, B };
        const cases: []const Case = &.{
            .{ .expected = "u8", .actual = u8 },
            .{ .expected = "[]u8", .actual = []const u8 },
            .{ .expected = "string", .actual = [:0]const u8 },
            .{ .expected = "[3]i32", .actual = [3]i32 },
            .{ .expected = "?[]i32", .actual = ?[]i32 },
            .{ .expected = "enum", .actual = E },
            .{ .expected = "?enum", .actual = ?E },
            .{ .expected = "[]enum", .actual = []const E },
        };
        inline for (cases) |c| {
            try testing.expectEqualStrings(c.expected, comptime formatType(c.actual));
        }
    }

    pub fn typeName(self: StructField) string {
        return formatType(self.type);
    }

    pub fn maybeChoices(self: StructField) ?[]const string {
        const Pack = struct {
            base: []const string,
            payload: type,
        };
        comptime {
            const pack: Pack = if (self.maybeOptional()) |payload|
                .{ .base = &.{"null"}, .payload = payload }
            else
                .{ .base = &.{}, .payload = self.type };
            if (@typeInfo(pack.payload) != .@"enum")
                return null;
            return pack.base ++ enumEntries(pack.payload);
        }
    }

    test maybeChoices {
        const C = struct {
            a: enum { A, B },
            b: ?enum { C, D },
            c: i32,
        };

        const a_choices = comptime DeepField(C, &.{"a"}).maybeChoices().?;
        try testing.expectEqual(2, a_choices.len);
        try testing.expectEqualStrings("A", a_choices[0]);
        try testing.expectEqualStrings("B", a_choices[1]);

        const b_choices = comptime DeepField(C, &.{"b"}).maybeChoices().?;
        try testing.expectEqual(3, b_choices.len);
        try testing.expectEqualStrings("null", b_choices[0]);
        try testing.expectEqualStrings("C", b_choices[1]);
        try testing.expectEqualStrings("D", b_choices[2]);

        try testing.expectEqual(null, comptime DeepField(C, &.{"c"}).maybeChoices());
    }
};

pub fn Field(comptime T: type, comptime name: string) StructField {
    comptime switch (@typeInfo(T)) {
        .@"struct" => |info| {
            for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name))
                    return StructField.from(T, field);
            }
            const message = std.fmt.comptimePrint("No such field: \"{s}\" in {s}", .{ name, @typeName(T) });
            @compileError(message);
        },
        .optional => |info| return Field(info.child, name),
        else => @compileError("Field lookup is only supported for structs"),
    };
}

pub fn DeepField(comptime T: type, comptime path: []const string) StructField {
    comptime {
        var now = StructField.init(T);
        var optional_ancestor = false;
        for (path) |name| {
            const next = Field(now.type, name);
            if (now.default_value) |value| {
                const final = @as(*const now.type, @ptrCast(value)).*;
                now.default_value = &@field(final, name);
            } else if (!next.is_optional) {
                now.default_value = next.default_value;
            }

            now.type = next.type;
            now.offset += next.offset;
            now.is_optional = next.is_optional;

            optional_ancestor = optional_ancestor or now.is_optional;
            if (optional_ancestor) {
                now.default_value = null;
            }
        }
        return now;
    }
}

test StructField {
    testing.refAllDecls(StructField);
}
