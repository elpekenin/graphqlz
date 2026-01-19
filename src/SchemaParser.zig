const std = @import("std");
const Allocator = std.mem.Allocator;

const ptk = @import("ptk");

const SchemaParser = @This();

const triple_quote = "\"\"\"";

tokenizer: Tokenizer,
core: ptk.ParserCore(Tokenizer, [_]Token{}),

pub fn init(self: *SchemaParser, source: []const u8, filename: ?[]const u8) void {
    self.tokenizer = .init(source, filename);
    self.core = .init(&self.tokenizer);
}

pub fn next(self: *SchemaParser, allocator: Allocator) !?Node {
    return .parse(allocator, self);
}

pub const T = union(enum) {
    flat: Flat,
    list: List,

    pub fn isDeprecated(self: T) bool {
        return switch (self) {
            inline else => |t| t.deprecated,
        };
    }

    const Flat = struct {
        name: []const u8,
        required: bool,
        deprecated: bool,
    };

    const List = struct {
        child: Flat,
        required: bool,
        deprecated: bool,
    };

    pub fn format(
        self: T,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .flat => |flat| {
                try writer.print("{s}", .{flat.name});
                if (flat.required) try writer.print("!", .{});
            },
            .list => |list| {
                try writer.print("[{s}{s}]", .{ list.child.name, if (list.child.required) "!" else "" });
                if (list.required) try writer.print("!", .{});
            },
        }
    }

    fn required(parser: *SchemaParser) !bool {
        const maybe_required = try parser.peek() orelse return error.InvalidSyntax;

        const is_required = maybe_required.type == .@"!";
        if (is_required) _ = try parser.is(.@"!");

        return is_required;
    }

    fn consumeDeprecated(parser: *SchemaParser) !bool {
        const deprecated = try parser.peek() orelse return false;
        if (deprecated.type != .directive) return false;

        if (!std.mem.eql(u8, "@deprecated", deprecated.text)) return false;

        // @deprecated(reason: "...")
        _ = try parser.is(.directive);
        _ = try parser.is(.@"(");

        const reason = try parser.is(.identifier);
        if (!std.mem.eql(u8, "reason", reason.text)) return error.InvalidSyntax;

        _ = try parser.is(.@":");

        // NOTE: strings are usually ignored, parse manually
        while (true) {
            const token = try parser.core.nextToken() orelse return error.InvalidSyntax;

            switch (token.type) {
                .comment,
                .newline,
                .triple_string,
                .whitespace,
                => continue,

                .string => break,

                else => return error.InvalidSyntax,
            }
        }

        _ = try parser.is(.@")");

        return true;
    }

    fn parse(parser: *SchemaParser) !T {
        const token = try parser.oneOf(.{ .@"[", .identifier });
        switch (token.type) {
            .@"[" => {
                const child: T = try .parse(parser);
                const flat = switch (child) {
                    .flat => |flat| flat,
                    .list => return error.NotSupported,
                };
                _ = try parser.is(.@"]");

                const is_required = try required(parser);
                const deprecated = try consumeDeprecated(parser);

                return .{
                    .list = .{
                        .child = flat,
                        .required = is_required,
                        .deprecated = deprecated,
                    },
                };
            },
            .identifier => {
                const is_required = try required(parser);
                const deprecated = try consumeDeprecated(parser);

                return .{
                    .flat = .{
                        .name = token.text,
                        .required = is_required,
                        .deprecated = deprecated,
                    },
                };
            },
            else => unreachable,
        }
    }
};

pub const TVar = struct {
    name: []const u8,
    type: T,

    pub fn format(
        self: TVar,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}: {f}", .{ self.name, self.type });
    }

    fn parse(parser: *SchemaParser) !TVar {
        const variable = try parser.is(.identifier);
        _ = try parser.is(.@":");
        const typ: T = try .parse(parser);

        return .{
            .name = variable.text,
            .type = typ,
        };
    }
};

pub const Node = union(enum) {
    directive: Directive,
    input: Input,
    query: Query,
    type: Type,

    pub const Directive = struct {
        name: []const u8,
        arg: TVar,

        pub fn format(
            self: Directive,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("directive: {s}({f})", .{ self.name, self.arg });
        }
    };

    pub const Input = struct {
        name: []const u8,
        fields: []const TVar,

        pub fn format(
            self: Input,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{s} {{", .{self.name});
            for (self.fields) |field| try writer.print(" {f},", .{field});
            try writer.print("}}", .{});
        }
    };

    pub const Query = struct {
        operations: []const Operation,

        const Operation = struct {
            name: []const u8,
            args: []const TVar,
            return_type: T,
        };
    };

    pub const Type = struct {
        name: []const u8,
        fields: []const TVar,

        pub fn format(
            self: Type,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{s} {{", .{self.name});

            for (self.fields) |field| {
                try writer.print(" {s}: ", .{field.name});

                if (field.args.len > 0) {
                    try writer.print("(", .{});
                    for (field.args) |arg| try writer.print(" {f},", .{arg});
                    try writer.print(" )", .{});
                }

                try writer.print("{f},", .{field.type});
            }

            try writer.print(" }}", .{});
        }
    };

    pub fn parse(allocator: Allocator, parser: *SchemaParser) !?Node {
        const first_token = parser.oneOf(.{ .directive_decl, .input, .type }) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        switch (first_token.type) {
            .directive_decl => {
                const name = try parser.is(.directive);

                _ = try parser.is(.@"(");
                const arg: TVar = try .parse(parser);
                _ = try parser.is(.@")");

                const maybe_on = try parser.is(.identifier);
                if (!std.mem.eql(u8, "on", maybe_on.text)) return error.InvalidSyntax;

                // TODO: support all locations
                const maybe_field = try parser.is(.identifier);
                if (!std.mem.eql(u8, "FIELD", maybe_field.text)) return error.InvalidSyntax;

                return .{
                    .directive = .{
                        .name = name.text,
                        .arg = arg,
                    },
                };
            },

            .input => {
                const name = try parser.is(.identifier);

                _ = try parser.is(.@"{");
                const fields = try parseVariables(allocator, parser, .{
                    .stop = .@"}",
                    .separator = null,
                });
                _ = try parser.is(.@"}");

                return .{
                    .input = .{
                        .name = name.text,
                        .fields = fields,
                    },
                };
            },

            .type => {
                const name = try parser.is(.identifier);

                if (!std.mem.eql(u8, "Query", name.text)) {
                    _ = try parser.is(.@"{");
                    const fields = try parseVariables(allocator, parser, .{
                        .stop = .@"}",
                        .separator = null,
                    });
                    _ = try parser.is(.@"}");

                    return .{
                        .type = .{
                            .name = name.text,
                            .fields = fields,
                        },
                    };
                } else {
                    _ = try parser.is(.@"{");

                    var resolvers: std.ArrayList(Query.Operation) = .empty;
                    defer resolvers.deinit(allocator);
                    errdefer for (resolvers.items) |resolver| allocator.free(resolver.args);

                    while (true) {
                        const resolver_name = try parser.oneOf(.{ .identifier, .@"}" });
                        if (resolver_name.type == .@"}") break;

                        _ = try parser.is(.@"(");
                        const args = try parseVariables(allocator, parser, .{
                            .stop = .@")",
                            .separator = .@",",
                        });
                        _ = try parser.is(.@")");

                        _ = try parser.is(.@":");
                        const return_type: T = try .parse(parser);

                        const resolver: Query.Operation = .{
                            .name = resolver_name.text,
                            .args = args,
                            .return_type = return_type,
                        };
                        try resolvers.append(allocator, resolver);
                    }

                    return .{
                        .query = .{
                            .operations = try resolvers.toOwnedSlice(allocator),
                        },
                    };
                }
            },

            else => unreachable,
        }
    }

    pub fn deinit(self: Node, allocator: Allocator) void {
        switch (self) {
            .directive => {},
            .input => |input| allocator.free(input.fields),
            .query => |query| {
                for (query.operations) |resolver| {
                    allocator.free(resolver.args);
                }

                allocator.free(query.operations);
            },
            .type => |typ| allocator.free(typ.fields),
        }
    }

    pub fn format(
        self: Node,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |node| try writer.print(".{t}={f}", .{ self, node }),
        }
    }
};

pub const Token = enum {
    comment,
    directive,
    directive_decl,
    identifier,
    input,
    newline,
    string,
    triple_string,
    type,
    whitespace,

    @",",
    @":",
    @"!",
    @"(",
    @")",
    @"{",
    @"}",
    @"[",
    @"]",
};

const patterns: []const ptk.Pattern(Token) = &.{
    .create(.comment, ptk.matchers.sequenceOf(.{
        ptk.matchers.literal("#"),
        ptk.matchers.takeNoneOf("\r\n"),
        ptk.matchers.linefeed,
    })),
    .create(.triple_string, ptk.matchers.sequenceOf(.{
        ptk.matchers.literal(triple_quote),
        takeUntilTripleQuote,
        ptk.matchers.literal(triple_quote),
    })),

    .create(.string, ptk.matchers.sequenceOf(.{
        ptk.matchers.literal("\""),
        ptk.matchers.takeNoneOf("\""),
        ptk.matchers.literal("\""),
    })),

    .create(.newline, ptk.matchers.linefeed),
    .create(.whitespace, ptk.matchers.whitespace),

    .create(.directive, ptk.matchers.withPrefix("@", ptk.matchers.identifier)),
    .create(.directive_decl, ptk.matchers.literal("directive ")),
    .create(.input, ptk.matchers.literal("input ")),
    .create(.type, ptk.matchers.literal("type ")),
    .create(.@",", ptk.matchers.literal(",")),
    .create(.@":", ptk.matchers.literal(":")),
    .create(.@"!", ptk.matchers.literal("!")),
    .create(.@"(", ptk.matchers.literal("(")),
    .create(.@")", ptk.matchers.literal(")")),
    .create(.@"{", ptk.matchers.literal("{")),
    .create(.@"}", ptk.matchers.literal("}")),
    .create(.@"[", ptk.matchers.literal("[")),
    .create(.@"]", ptk.matchers.literal("]")),

    // very important to keep last, otherwise it shadows other types
    .create(.identifier, ptk.matchers.identifier),
};

const Tokenizer = ptk.Tokenizer(Token, patterns);
const ruleset = ptk.RuleSet(Token);

fn takeUntilTripleQuote(str: []const u8) ?usize {
    if (std.mem.indexOf(u8, str, triple_quote)) |index| {
        return index;
    }

    return str.len;
}

const ParseOptions = struct {
    stop: Token,
    separator: ?Token,
};

fn parseVariables(allocator: Allocator, parser: *SchemaParser, comptime options: ParseOptions) ![]const TVar {
    var variables: std.ArrayList(TVar) = .empty;
    defer variables.deinit(allocator);

    while (true) {
        const next_token = try parser.peek() orelse return error.InvalidSyntax;
        if (next_token.type == options.stop) break;

        const variable: TVar = try .parse(parser);
        try variables.append(allocator, variable);

        if (options.separator) |separator| {
            const maybe_separator = try parser.peek() orelse return error.InvalidSyntax;

            switch (maybe_separator.type) {
                separator => _ = try parser.is(separator),
                options.stop => break,
                else => return error.InvalidSyntax,
            }
        }
    }

    if (variables.items.len == 0) return error.NoVariablesFound;

    return variables.toOwnedSlice(allocator);
}

fn consumeNonRelevant(self: *SchemaParser) !void {
    while (true) {
        const token = try self.core.peek() orelse return;

        switch (token.type) {
            .comment,
            .newline,
            .string,
            .triple_string,
            .whitespace,
            => _ = try self.core.nextToken() orelse unreachable,

            else => return,
        }
    }
}

fn is(self: *SchemaParser, comptime token: Token) !Tokenizer.Token {
    try self.consumeNonRelevant();
    return self.core.accept(ruleset.is(token));
}

fn oneOf(self: *SchemaParser, tokens: anytype) !Tokenizer.Token {
    try self.consumeNonRelevant();
    return self.core.accept(ruleset.oneOf(tokens));
}

fn peek(self: *SchemaParser) !?Tokenizer.Token {
    const state = self.core.saveState();
    defer self.tokenizer.restoreState(state);

    try self.consumeNonRelevant();

    return self.core.peek();
}
