const std = @import("std");
const builtin = @import("builtin");

pub const scope = .zargs;

fn log(
    comptime message_level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !std.log.logEnabled(message_level, scope))
        return;
    std.options.logFn(message_level, scope, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) {
        // log error during tests will be treated as a test failure
        warn(format, args);
    } else {
        @branchHint(.cold);
        log(.err, format, args);
    }
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    log(.warn, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    log(.info, format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    log(.debug, format, args);
}
