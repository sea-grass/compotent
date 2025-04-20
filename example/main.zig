pub const std_options: std.Options = .{
    .log_level = .info,
};

/// Task: Render all pages
/// Render page:
/// - Get associated Template
/// - Emit Template preamble
/// - Emit styles for component page blocks
/// - Render all page blocks
/// - Emit scripts for component page blocks
/// - Emit Template postamble
/// Emit styles:
/// - Get unique component names for all component blocks
/// - Emit style preamble
/// - Emit all component css
/// - Emit style postamble
/// Render page block:
/// - One of:
///     - Render markdown block
///     - Render component block
/// Render markdown block:
/// - Render markdown
/// Render component block:
/// - Create JS data object from component props
/// - Render component, providing data object
pub const Website = struct {
    pages: []const Page,
    templates: std.StringHashMapUnmanaged(Template),
    components: std.StringHashMapUnmanaged(Component),

    pub const Page = struct {
        meta: std.StringHashMapUnmanaged([]const u8),
        blocks: []const Page.Block,

        pub const Block = union(enum) {
            markdown: []const u8,
            component: Block.Component,

            pub const Component = struct {
                name: []const u8,
                props: std.StringHashMapUnmanaged([]const u8),
            };
        };
    };

    pub const Template = struct {
        meta: std.StringHashMapUnmanaged([]const u8),
        blocks: []const Template.Block,

        pub const Block = union(enum) {
            html: []const u8,
        };
    };

    pub const Component = struct {
        meta: std.StringHashMapUnmanaged([]const u8),
        source: [:0]const u8,
    };
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var gpa: heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    var page_mem: [1024]Website.Page = undefined;
    var page_buf: std.ArrayListUnmanaged(Website.Page) = .initBuffer(&page_mem);

    // In order to allocate storage for at least 1024 hash map entries, I need between 4 and 5 times as much storage.
    // I'm curious to inspect `ensureTotalCapacity` to see what overhead is required.
    var page_meta_mem: [5 * 1024][]const u8 = undefined;
    var page_meta_fba: heap.FixedBufferAllocator = .init(@ptrCast(&page_meta_mem));

    var page_meta: std.StringHashMapUnmanaged([]const u8) = .empty;
    try page_meta.ensureTotalCapacity(page_meta_fba.allocator(), 1024);
    page_meta.putAssumeCapacity("title", "Hello, world");

    // Store at most 10 component props
    var prop_meta_mem: [5 * 10][]const u8 = undefined;
    var prop_meta_fba: heap.FixedBufferAllocator = .init(@ptrCast(&prop_meta_mem));
    var prop_meta: std.StringHashMapUnmanaged([]const u8) = .empty;
    try prop_meta.ensureTotalCapacity(prop_meta_fba.allocator(), 10);
    prop_meta.putAssumeCapacity("href", "/buy-now");
    prop_meta.putAssumeCapacity("text", "Buy for only $0.99");

    page_buf.appendAssumeCapacity(.{
        .meta = page_meta,
        .blocks = &.{
            .{ .markdown = "# Hello, world" },
            .{ .component = .{ .name = "button", .props = prop_meta } },
            .{ .markdown = "Thanks for reading." },
        },
    });

    // Store at most 1024 components
    var component_mem: [3 * 1024]Website.Component = undefined;
    var component_fba: heap.FixedBufferAllocator = .init(@ptrCast(&component_mem));

    var component_buf: std.StringHashMapUnmanaged(Website.Component) = .empty;
    try component_buf.ensureTotalCapacity(component_fba.allocator(), 1024);

    component_buf.putAssumeCapacity("button", .{
        .meta = undefined,
        .source = (
            \\export const render = (data) => `<a class="button" href="${data.href}">${data.text}</a>`;
            \\
        ),
    });

    component_buf.putAssumeCapacity("sample_component", .{
        .meta = undefined,
        .source = @embedFile("sample_component.js"),
    });

    const site: Website = .{
        .templates = undefined,
        .components = component_buf,
        .pages = page_buf.items,
    };

    var cc: Context = try .init();
    defer cc.deinit();

    var c_it = site.components.iterator();
    while (c_it.next()) |c| {
        try cc.register(arena.allocator(), c.key_ptr.*, c.value_ptr.*.source);
    }

    for (site.pages) |page| {
        var it = page.meta.iterator();
        while (it.next()) |entry| {
            try stdout.print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        for (page.blocks) |block| {
            switch (block) {
                .markdown => |md| {
                    try stdout.print("{s}\n", .{md});
                },
                .component => |component| {
                    const data: lib.Data = try cc.encode(std.StringHashMapUnmanaged([]const u8), component.props);
                    defer data.deinit(&cc);
                    const result = try cc.render(arena.allocator(), component.name, .{ .data = data });
                    try stdout.print("{s}\n", .{result.html});
                },
            }
        }
    }
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
const lib = compotent;
const compotent = @import("compotent");
const Context = lib.Context;
const std = @import("std");
