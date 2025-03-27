const std = @import("std");
const testing = std.testing;
const field = @import("field.zig");
const Help = @import("help.zig");

const types = @import("types.zig");
const string = types.string;
const cstring = types.cstring;

const ArgIterator = @import("iterator.zig");

const Final = @This();

args: []const Declaration,
summary: string = "",

pub fn parameters(comptime zargs: Final, comptime kind: Declaration.ParameterKind) []const Declaration {
    comptime {
        var values: [zargs.args.len]Declaration = undefined;
        var i: usize = 0;
        for (zargs.args) |arg| {
            if (arg.parameter == kind) {
                values[i] = arg;
                i += 1;
            }
        }
        const final = values[0..i];
        return final;
    }
}

fn helpParameters(comptime final: Final, comptime Container: type, comptime kind: Declaration.ParameterKind) []const Help.Parameter {
    comptime {
        var params: [final.args.len + 1]Help.Parameter = undefined;
        var i: usize = 0;
        for (final.args) |arg| {
            if (arg.parameter == kind) {
                if (kind == .named and arg.parameter.named.hidden)
                    continue;
                params[i] = arg.help(Container);
                i += 1;
            }
        }
        if (kind == .named) {
            params[i] = Help.named_help;
            i += 1;
        }

        const final_params = params[0..i].*;
        return &final_params;
    }
}

fn baseHelp(comptime Container: type) Help.Base {
    if (!@hasDecl(Container, "zargs"))
        @compileError("Missing .zargs declaration");
    comptime {
        const final: Final = Container.zargs;
        const positional = final.helpParameters(Container, .positional);
        const named = final.helpParameters(Container, .named);
        const environment = final.helpParameters(Container, .environment);
        const usage = switch (positional.len) {
            0 => "[OPTIONS]",
            1 => "[OPTIONS] " ++ positional[0].title,
            else => "[OPTIONS] ARGUMENTS...",
        };
        return .{
            .usage = usage,
            .positional = positional,
            .named = named,
            .environment = environment,
        };
    }
}

pub fn help(comptime Container: type, argv: []const cstring) Help {
    const base = comptime baseHelp(Container);
    return .{
        .argv = argv,
        .base = base,
    };
}

const Delimiter = union(std.mem.DelimiterType) {
    sequence: []const u8,
    any: []const u8,
    scalar: u8,
};

pub const Declaration = struct {
    const ParameterKind = enum {
        positional,
        named,
        environment,
    };

    const Parameter = union(ParameterKind) {
        positional: Positional,
        named: Named,
        environment: Environment,
    };

    const Positional = struct {
        metavar: string,
    };

    const Named = struct {
        const Action = union(enum) {
            /// Increase a fixed value, only integer and enum types
            /// are supported.
            increment: comptime_int,
            /// When `null`: Parse and assign the incoming argument,
            /// otherwise assign the fixed value.
            assign: ?*const anyopaque,
            /// Parse and append the incoming argument to a list.
            append: void,
        };

        long: []const u8 = "",
        short: u8 = 0,
        metavar: string = "",
        action: Action = .{ .assign = null },
        hidden: bool = false,
    };

    const Environment = struct {
        name: string,
        hidden: bool = false,
    };

    const Self = @This();

    path: []const string,
    parameter: Parameter,
    delimiter: ?Delimiter = null,
    description: string = "",

    pub fn Field(self: Self, comptime Container: type) field.StructField {
        const Closure = struct {
            type: type,

            pub fn format(
                c: @This(),
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                if (fmt.len != 0)
                    return std.fmt.invalidFmtError(fmt, c);
                _ = options;
                try std.fmt.format(writer, @tagName(Container), .{});
                for (self.path) |name| {
                    try std.fmt.format(writer, ".{s}", .{name});
                }
                try std.fmt.format(writer, ": {s}", .{@typeName(c.type)});
            }

            fn typeError(c: @This(), err: string) string {
                return std.fmt.comptimePrint("[{}]: {s}", .{ c, err });
            }
        };

        comptime {
            const struct_field = field.DeepField(Container, self.path);
            const closure = Closure{ .type = struct_field.type };
            if (struct_field.maybeOptional()) |payload| {
                if (@typeInfo(payload) == .optional) {
                    @compileError(closure.typeError("Nested optional types are not supported"));
                }
            }

            const concrete_type = struct_field.concreteType();

            if (concrete_type == string) {
                if (self.delimiter != null) {
                    @compileError(closure.typeError("String types' delimiter must be null"));
                }
                return struct_field;
            }

            switch (@typeInfo(concrete_type)) {
                .pointer => |info| {
                    if (info.size != .slice) {
                        @compileError(closure.typeError("Only support slices"));
                    }
                    if (info.sentinel_ptr != null) {
                        @compileError(closure.typeError("Sentinel terminated slices are not supported"));
                    }
                    if (self.delimiter == null) {
                        @compileError(closure.typeError("Slices must have a delimiter"));
                    }
                    if (info.child != string) {
                        const concrete_child = z: {
                            const child_info = @typeInfo(info.child);
                            break :z if (child_info == .optional) child_info.optional.child else info.child;
                        };
                        switch (@typeInfo(concrete_child)) {
                            .pointer, .array => @compileError(closure.typeError("2D collections are not supported")),
                            .optional => @compileError(closure.typeError("Nested optional types are not supported")),
                            .@"struct" => |child_info| {
                                if (types.custom.parse_fn(child_info.type) == null) {
                                    @compileError(closure.typeError("Child struct must have a parse function"));
                                }
                            },
                            else => {},
                        }
                    }
                },
                .array => |info| {
                    if (info.len == 0) {
                        @compileError(closure.typeError("Array length must be greater than zero"));
                    }
                    if (info.sentinel_ptr != null) {
                        @compileError(closure.typeError("Sentinel terminated arrays are not supported"));
                    }
                    if (self.delimiter == null) {
                        @compileError(closure.typeError("Array types must have a delimiter"));
                    }
                    if (info.child != string) {
                        const concrete_child = z: {
                            const child_info = @typeInfo(info.child);
                            break :z if (child_info == .optional) child_info.optional.child else info.child;
                        };
                        switch (@typeInfo(concrete_child)) {
                            .pointer, .array => @compileError(closure.typeError("2D collections are not supported")),
                            .optional => @compileError(closure.typeError("Nested optional types are not supported")),
                            .@"struct" => |child_info| {
                                if (types.custom.parse_fn(child_info.type) == null) {
                                    @compileError(closure.typeError("Child struct must have a parse function"));
                                }
                            },
                            else => {},
                        }
                    }
                },
                .@"union" => |info| {
                    if (info.tag_type == null) {
                        @compileError(closure.typeError("Only tagged unions are supported"));
                    }
                },
                .@"struct" => |info| {
                    if (types.custom.parse_fn(info.type) == null) {
                        @compileError(closure.typeError("Struct must have a parse function"));
                    }
                },
                .@"enum", .int, .float, .bool => {},
                else => @compileError(closure.typeError("Unsupported")),
            }

            return struct_field;
        }
    }

    fn maybeChoices(struct_field: field.StructField) ?[]const string {
        comptime {
            const concrete_type = struct_field.maybeOptional() orelse struct_field.type;
            const payload_field = switch (@typeInfo(concrete_type)) {
                inline .array, .pointer => |info| std.mem.zeroInit(field.StructField, .{
                    .type = struct_field.type,
                    .container_type = info.child,
                }),
                else => struct_field,
            };
            return payload_field.maybeChoices();
        }
    }

    pub fn isRequired(self: Self, comptime Container: type) bool {
        comptime {
            const final = self.Field(Container);
            return switch (self.parameter) {
                .named => |named| switch (named.action) {
                    .increment, .append => false,
                    .assign => |value| value == null and final.maybeDefault() == null,
                },
                .positional => final.maybeDefault() == null,
                .environment => false,
            };
        }
    }

    pub fn help(self: Self, comptime Container: type) Help.Parameter {
        comptime {
            const struct_field = self.Field(Container);
            const choices = switch (self.parameter) {
                .named => |named| switch (named.action) {
                    .increment, .append => null,
                    .assign => |value| if (value) |_| null else struct_field.maybeChoices(),
                },
                else => struct_field.maybeChoices(),
            };
            const type_name = switch (self.parameter) {
                .named => |named| switch (named.action) {
                    .increment => "",
                    .assign => |value| if (value) |_| "" else struct_field.typeName(),
                    else => struct_field.typeName(),
                },
                else => struct_field.typeName(),
            };
            return .{
                .title = self.title(),
                .description = self.description,
                .required = self.isRequired(Container),
                .type = type_name,
                .choices = choices,
            };
        }
    }

    pub fn title(self: Self) string {
        return comptime switch (self.parameter) {
            .positional => |p| p.metavar,
            .named => |n| named: {
                const print = std.fmt.comptimePrint;
                const maybe_metavar = if (n.metavar.len != 0) " " ++ n.metavar else "";
                if (n.long.len != 0 and n.short != 0)
                    break :named print("--{s}, -{c}" ++ maybe_metavar, .{ n.long, n.short });
                if (n.long.len != 0)
                    break :named print("--{s}" ++ maybe_metavar, .{n.long});
                if (n.short != 0)
                    break :named print("-{c}" ++ maybe_metavar, .{n.short});
                @compileError("Named parameter must have a long or short name");
            },
            .environment => |e| e.name,
        };
    }

    test title {
        const Case = struct {
            expected: string,
            actual: Parameter,
        };

        const cases: []const Case = &.{ .{
            .expected = "FILES",
            .actual = .{ .positional = .{ .metavar = "FILES" } },
        }, .{
            .expected = "--files, -f FILES",
            .actual = .{ .named = .{ .long = "files", .short = 'f', .metavar = "FILES" } },
        }, .{
            .expected = "--files FILES",
            .actual = .{ .named = .{ .long = "files", .metavar = "FILES" } },
        }, .{
            .expected = "--files",
            .actual = .{ .named = .{ .long = "files" } },
        }, .{
            .expected = "SOURCE_FILES",
            .actual = .{ .environment = .{ .name = "SOURCE_FILES" } },
        } };

        inline for (cases) |case| {
            const caller: Declaration = .{
                .path = &.{},
                .parameter = case.actual,
            };
            const actual = caller.title();
            try testing.expectEqualStrings(case.expected, actual);
        }
    }

    pub fn split(comptime self: Self, buffer: []const u8) SplitIterator(self.delimiter.?) {
        const payload = comptime z: {
            const delimiter = self.delimiter orelse unreachable;
            const activeTag = std.meta.activeTag(delimiter);
            break :z @field(delimiter, @tagName(activeTag));
        };
        return .{
            .index = 0,
            .buffer = buffer,
            .delimiter = payload,
        };
    }
};

fn SplitIterator(comptime delimiter: Delimiter) type {
    comptime {
        const activeTag = std.meta.activeTag(delimiter);
        return std.mem.SplitIterator(u8, activeTag);
    }
}

test Declaration {
    testing.refAllDecls(Declaration);
}
