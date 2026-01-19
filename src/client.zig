const std = @import("std");
const Allocator = std.mem.Allocator;

const requezt = @import("requezt");

fn Args(comptime schema: type, comptime operation: []const u8) type {
    return @field(schema.Query, operation).Args;
}

fn contains(haystack: []const []const u8, needle: [:0]const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }

    return false;
}

fn Select(comptime T: type, comptime fields: []const []const u8) type {
    const info = @typeInfo(T).@"struct";

    var copy = info;
    copy.decls = &.{};
    copy.fields = &.{};

    for (info.fields) |field| {
        if (contains(fields, field.name)) {
            copy.fields = copy.fields ++ &[_]std.builtin.Type.StructField{field};
        }
    }

    return @Type(.{ .@"struct" = copy });
}

fn Return(comptime schema: type, comptime operation: []const u8, comptime fields: []const []const u8) type {
    const R = @field(schema.Query, operation).Return;

    switch (@typeInfo(R)) {
        .optional => |optional| return ?Select(optional.child, fields),
        .pointer => |pointer| {
            if (pointer.size != .slice or !pointer.is_const) @compileError("unsupported type: " ++ @typeName(R));
            return []const Select(pointer.child, fields);
        },
        .@"struct" => return Select(R, fields),
        else => @compileError("unsupported type: " ++ @typeName(R)),
    }
}

fn hasData(comptime T: type, value: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var has_data = false;

            inline for (info.fields) |field| {
                if (hasData(field.type, @field(value, field.name))) {
                    has_data = true;
                }
            }

            return has_data;
        },
        .optional => return value != null,
        else => return true,
    }
}

fn writeArg(comptime T: type, writer: *std.Io.Writer, name: ?[]const u8, value: T) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (name) |n| try writer.print("{s}:{{", .{n});

            inline for (info.fields) |field| {
                const field_value = @field(value, field.name);
                try writeArg(field.type, writer, field.name, field_value);
            }

            if (name != null) try writer.print("}},", .{});
        },
        .optional => |optional| {
            const unwrapped = value orelse return;
            try writeArg(optional.child, writer, name, unwrapped);
        },
        .int => try writer.print("{s}:{},", .{ name.?, value }),
        else => switch (T) {
            []const u8 => try writer.print("{s}:\"{s}\",", .{ name.?, value }),
            else => @compileError("unsupported type " ++ @typeName(T)),
        },
    }
}

fn GraphQLResponse(comptime schema: type, comptime operation: [:0]const u8, fields: []const []const u8) type {
    const ReturnValue = Return(schema, operation, fields);

    const Data = @Type(.{
        .@"struct" = .{
            .decls = &.{},
            .fields = &.{
                .{
                    .name = operation,
                    .type = ReturnValue,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(ReturnValue),
                },
            },
            .is_tuple = false,
            .layout = .auto,
        },
    });

    return union(enum) {
        const Self = @This();

        ok: std.json.Parsed(Success),
        err: std.json.Parsed(Errors),

        const Success = struct {
            data: Data,
        };

        const Error = struct {
            message: []const u8,
            locations: []const Location,
            path: []const []const u8,

            const Location = struct {
                line: usize,
                column: usize,
            };
        };

        const Errors = struct {
            errors: []const Error,
        };

        fn from(allocator: Allocator, slice: []const u8) !Self {
            const options: std.json.ParseOptions = .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            };

            const data = std.json.parseFromSlice(Success, allocator, slice, options) catch {
                const errors = std.json.parseFromSlice(Errors, allocator, slice, options) catch |e| {
                    std.log.err("{s}", .{slice});
                    return e;
                };
                return .{ .err = errors };
            };

            return .{ .ok = data };
        }

        pub fn unwrap(self: Self) !ReturnValue {
            return switch (self) {
                .ok => |ok| @field(ok.value.data, operation),
                .err => error.UnwrapOnError,
            };
        }

        pub fn deinit(self: Self) void {
            switch (self) {
                .ok => |data| data.deinit(),
                .err => |errors| errors.deinit(),
            }
        }
    };
}

pub fn Client(comptime url: []const u8, comptime schema: type) type {
    return struct {
        pub fn execute(
            allocator: Allocator,
            comptime operation: [:0]const u8,
            args: Args(schema, operation),
            comptime fields: []const []const u8,
        ) !GraphQLResponse(schema, operation, fields) {
            var client: requezt.Client = .init(allocator, .{});
            defer client.deinit();

            var allocating: std.Io.Writer.Allocating = .init(allocator);
            defer allocating.deinit();
            const writer = &allocating.writer;

            try writer.print("query{{{s}", .{operation});

            const has_args = hasData(@TypeOf(args), args);
            if (has_args) {
                try writer.print("(", .{});
                try writeArg(@TypeOf(args), writer, null, args);
                try writer.print(")", .{});
            }

            try writer.print("{{", .{});
            for (fields) |field| {
                try writer.print("{s},", .{field});
            }
            try writer.print("}}", .{});

            try writer.print("}}", .{});

            const query = try allocating.toOwnedSlice();
            defer allocator.free(query);

            var response = try client.postJson(
                url,
                .{
                    .query = query,
                    // .variables = args,
                },
                .{
                    .headers = .{
                        .content_type = "application/json",
                    },
                },
            );
            defer response.deinit();

            return .from(allocator, response.body_data);
        }
    };
}
