pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var gpa: heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    var cc: Context = try .init();
    defer cc.deinit();

    try cc.register(arena.allocator(), "component", sample_component);

    const data: lib.Data = try cc.encode(Props, .{
        .title = "My Website",
        .navItems = &.{
            .{ .href = "/about", .text = "About us" },
        },
    });
    defer data.deinit(&cc);

    // Can render a component many times with different data.
    const result = try cc.render(arena.allocator(), "component", .{
        .data = data,
    });

    // Can retrieve assets associated with the component.
    const assets = try cc.getAssets(arena.allocator(), "component");

    // Write html document

    try stdout.print((
        \\<!doctype html>
        \\<html>
        \\<head>
    ), .{});
    if (assets.css) |css| {
        try stdout.print((
            \\<style>{s}</style>
        ), .{css});
    }
    try stdout.print((
        \\</head>
        \\<body>
    ), .{});
    try stdout.print("{s}", .{result.html});
    if (assets.js) |js| {
        try stdout.print((
            \\<script type="module">{s}</script>
        ), .{js});
    }
    try stdout.print((
        \\</body>
        \\</html>
        \\
    ), .{});
}

const Props = struct {
    title: []const u8,
    navItems: []const struct {
        href: []const u8,
        text: []const u8,
    },
};

const sample_component = @embedFile("sample_component.js");
const heap = std.heap;
const lib = @import("compotent_lib");
const Context = lib.Context;
const std = @import("std");
