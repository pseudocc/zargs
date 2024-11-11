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

path: []const []const u8,
action: Action = .assign,
long: []const u8 = "",
short: u8 = 0,
delimiter: ?Delimiter = null,

pub fn This(comptime self: @This(), comptime T: type) type {
    return field.DeepFieldType(T, self.path);
}

pub fn this(comptime self: @This(), comptime T: type, ptr: *T) *self.This(T) {
    return field.ptrOf(T, self.path, ptr);
}

pub fn isPositional(comptime self: @This()) bool {
    return self.long.len == 0 and self.short == 0;
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
