//! GraphQL to Zig (g2z)
//!
//! Create zig types to represent a GraphQL schema

const std = @import("std");
const assert = std.debug.assert;

const Parser = @import("gqlz").SchemaParser;

fn preamble(writer: *std.Io.Writer) !void {
    try writer.print(
        \\//! THIS FILE WAS GENERATED, DON'T EDIT MANUALLY
        \\
        \\// aliases for zig compatibility
        \\pub const Boolean = bool;
        \\pub const Float = f64;
        \\pub const ID = Int; // FIXME: should this be String?
        \\pub const Int = u64;
        \\pub const String = []const u8;
        \\
        \\
    , .{});
}

const ToZigOptions = struct {
    print_default: bool,
};

fn toZig(typ: Parser.T, writer: *std.Io.Writer, options: ToZigOptions) !void {
    switch (typ) {
        .flat => |flat| {
            if (!flat.required) {
                try writer.print("?", .{});
            }

            try writer.print("{s}", .{flat.name});

            if (!flat.required and options.print_default) {
                try writer.print(" = null", .{});
            }
        },

        .list => |list| {
            try writer.print("[]const {s}", .{list.child.name});

            if (!list.required and options.print_default) {
                try writer.print(" = &.{{}}", .{});
            }
        },
    }
}

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var args: std.process.ArgIterator = try .initWithAllocator(allocator);
    defer args.deinit();

    assert(args.skip());
    const filename = args.next() orelse {
        std.debug.print("missing FILENAME", .{});
        return 1;
    };

    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var reader = file.reader(&.{});

    const contents = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(contents);

    var parser: Parser = undefined;
    parser.init(contents, filename);

    var buffer: [1024]u8 = undefined;
    var file_writer: std.fs.File.Writer = .init(.stdout(), &buffer);
    const writer = &file_writer.interface;

    try preamble(writer);

    while (try parser.next(allocator)) |node| {
        defer node.deinit(allocator);

        switch (node) {
            // TODO: something here?
            .directive => {},

            .query => |query| {
                try writer.print("pub const Query = struct {{", .{});

                for (query.operations) |operation| {
                    if (operation.return_type.isDeprecated()) continue;

                    try writer.print(
                        \\
                        \\    pub const {s} = struct {{
                        \\        pub const Args = struct {{
                        \\
                    , .{operation.name});

                    for (operation.args) |arg| {
                        if (arg.type.isDeprecated()) continue;

                        try writer.print("            {s}: ", .{arg.name});
                        try toZig(arg.type, writer, .{
                            .print_default = true,
                        });
                        try writer.print(",\n", .{});
                    }

                    try writer.print(
                        \\        }};
                        \\        pub const Return = 
                    , .{});

                    try toZig(operation.return_type, writer, .{
                        .print_default = false,
                    });

                    try writer.print(
                        \\;
                        \\    }};
                        \\
                    , .{});
                }

                try writer.print("}};\n\n", .{});
            },

            inline .input, .type => |info| {
                try writer.print("pub const {s} = struct {{\n", .{info.name});

                // TODO: support `type Query` // `field.args`
                for (info.fields) |field| {
                    if (field.type.isDeprecated()) continue;

                    try writer.print("    {s}: ", .{field.name});
                    try toZig(field.type, writer, .{
                        .print_default = true,
                    });
                    try writer.print(",\n", .{});
                }

                try writer.print("}};\n\n", .{});
            },
        }
    }

    try writer.flush();
    return 0;
}
