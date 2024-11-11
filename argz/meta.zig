const std = @import("std");
const testing = std.testing;

pub fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

test isOptional {
    const A = ?i32;
    const B = i32;
    try testing.expect(isOptional(A));
    try testing.expect(!isOptional(B));
}

pub fn OptionalPayload(comptime T: type) type {
    var payload = T;
    while (isOptional(payload)) {
        payload = @typeInfo(payload).optional.child;
    }
    return payload;
}

test OptionalPayload {
    const A = ?i32;
    const B = ??i64;
    try testing.expectEqual(OptionalPayload(A), i32);
    try testing.expectEqual(OptionalPayload(B), i64);
}

pub fn typeInfo(comptime T: type) std.builtin.Type {
    const This = OptionalPayload(T);
    return @typeInfo(This);
}
