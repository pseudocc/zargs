const std = @import("std");
const root = @import("root");
const Help = @import("help.zig");

const types = @import("types.zig");
const string = types.string;
const cstring = types.cstring;

fn baseHelp(comptime T: type) Help.Base {
    comptime {
        const Tag = std.meta.Tag(T);
        const tags = std.meta.tags(Tag);

        var commands: [tags.len]Help.Command = undefined;
        for (tags, 0..) |tag, i| {
            commands[i] = .{
                .name = @tagName(tag),
                .summary = if (@hasDecl(T, "summary")) T.summary(tag) else null,
            };
        }
        const final_commands = commands[0..].*;
        const final_named = .{Help.named_help};

        const base = Help.Base{
            .usage = "[COMMAND ...] | [--help]",
            .commands = &final_commands,
            .named = &final_named,
        };
        return base;
    }
}

pub fn help(comptime T: type, argv: []const cstring) Help {
    const base = comptime baseHelp(T);
    return .{
        .argv = argv,
        .base = base,
    };
}

pub fn SummaryFn(comptime T: type) type {
    return fn (std.meta.Tag(T)) string;
}

test {
    const Payload = union(enum) {
        const Tag = std.meta.Tag(@This());

        number: u32,
        nothing: void,

        fn summary(active: Tag) string {
            return switch (active) {
                .number => "u32",
                .nothing => "void",
            };
        }
    };

    const summary: SummaryFn(Payload) = Payload.summary;
    try std.testing.expectEqual(summary(.number), "u32");
}
