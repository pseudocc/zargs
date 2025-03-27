const std = @import("std");
const primary = @import("parse.zig");

pub const string = [:0]const u8;
pub const cstring = [*:0]const u8;

pub const ParseError = error{
    UnknownCommand,
    UnknownOption,
    UnexpectedArgument,
    HelpRequested,
    ArrayOverflow,
    ArrayUnderflow,
    MissingRequired,
} || primary.ParseError || std.meta.IntToEnumError;

pub const custom = struct {
    pub const PARSEFN = "parse";
    pub const HELPTYPE = "help_type";

    pub fn ParseFn(comptime T: type) type {
        return fn ([]const u8, std.mem.Allocator) ParseError!T;
    }

    pub fn parse_fn(comptime T: type) ?ParseFn(T) {
        switch (@typeInfo(T)) {
            .@"opaque", .@"struct", .@"union", .@"enum" => {},
            else => return null,
        }
        return if (@hasDecl(T, PARSEFN))
            @field(T, PARSEFN)
        else
            null;
    }

    pub fn help_type(comptime T: type) string {
        return if (@hasDecl(T, HELPTYPE))
            @field(T, HELPTYPE)
        else
            "";
    }
};
