const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // deps
    const parser_toolkit = b.dependency("parser_toolkit", .{
        .target = target,
        .optimize = optimize,
    });

    const requezt = b.dependency("requezt", .{
        .target = target,
        .optimize = optimize,
    });

    // main module
    const gqlz = b.addModule("gqlz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ptk", .module = parser_toolkit.module("parser-toolkit") },
            .{ .name = "requezt", .module = requezt.module("requezt") },
        },
    });

    // graphql -> zig translation
    const g2z = b.step("g2z", "run GraphQL to Zig translation");
    const run_g2z = b.addRunArtifact(
        b.addExecutable(.{
            .name = "g2z",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/g2z.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gqlz", .module = gqlz },
                },
            }),
        }),
    );
    g2z.dependOn(&run_g2z.step);
    if (b.args) |args| run_g2z.addArgs(args);
}
