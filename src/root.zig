const c = @import("c");
const mem = std.mem;
const std = @import("std");

pub fn example() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    var cc: Context = try .init();
    defer cc.deinit();

    const src = (
        \\export const html = () => `<p>Hello, world</p>`;
        \\
    );

    try cc.register(arena.allocator(), "component", src);

    const result = try cc.render(arena.allocator(), "component");
    std.log.info("{s}", .{result});
}

fn handleException(ctx: *c.JSContext) !noreturn {
    const exception = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exception);

    const str = c.JS_ToCString(ctx, exception);
    defer c.JS_FreeCString(ctx, str);
    const error_message = mem.span(str);

    const stack = c.JS_GetPropertyStr(ctx, exception, "stack");
    defer c.JS_FreeValue(ctx, stack);

    const stack_str = c.JS_ToCString(ctx, stack);
    defer c.JS_FreeCString(ctx, stack_str);
    const stack_message = mem.span(stack_str);

    std.log.err("JS Exception: {s} {s}", .{ error_message, stack_message });

    return error.JSException;
}

const Context = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,

    map: std.StringHashMapUnmanaged(Component),

    pub const Component = struct {
        mod: c.JSValue,
    };

    pub fn init() !Context {
        const runtime = c.JS_NewRuntime() orelse return error.CannotAllocateJSRuntime;
        errdefer c.JS_FreeRuntime(runtime);

        const ctx = c.JS_NewContext(runtime) orelse return error.CannotAllocateJSContext;
        errdefer c.JS_FreeContext(ctx);

        return .{ .map = .empty, .rt = runtime, .ctx = ctx };
    }

    pub fn deinit(self: *Context) void {
        var it = self.map.valueIterator();
        while (it.next()) |component| {
            c.JS_FreeValue(self.ctx, component.mod);
        }
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
    }

    pub fn register(self: *Context, arena: mem.Allocator, name: []const u8, src: []const u8) !void {
        const key = try arena.dupe(u8, name);
        const mod = c.JS_Eval(
            self.ctx,
            @ptrCast(src),
            src.len,
            @ptrCast(key),
            c.JS_EVAL_TYPE_MODULE,
        );
        errdefer c.JS_FreeValue(self.ctx, mod);
        switch (mod.tag) {
            c.JS_TAG_EXCEPTION => try handleException(self.ctx),
            else => {},
        }

        const result = try self.map.getOrPut(arena, key);

        if (result.found_existing) return error.DuplicateComponentRegistered;

        result.value_ptr.* = .{
            .mod = mod,
        };
    }

    pub fn render(self: *Context, arena: mem.Allocator, name: []const u8) ![]const u8 {
        if (!self.map.contains(name)) return error.ComponentNotRegistered;

        var buf: std.ArrayList(u8) = .init(arena);
        defer buf.deinit();
        try buf.writer().print(
            \\import * as c from '{s}';
            \\globalThis.html = c.html();
        ,
            .{name},
        );

        const t = try buf.toOwnedSliceSentinel(0);

        const eval_result = c.JS_Eval(
            self.ctx,
            @ptrCast(t),
            t.len,
            "<input>",
            c.JS_EVAL_TYPE_MODULE,
        );
        defer c.JS_FreeValue(self.ctx, eval_result);
        switch (eval_result.tag) {
            c.JS_TAG_EXCEPTION => try handleException(self.ctx),
            else => {},
        }

        const global_object = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, global_object);

        const html = c.JS_GetPropertyStr(self.ctx, global_object, "html");
        defer c.JS_FreeValue(self.ctx, html);
        switch (html.tag) {
            c.JS_TAG_EXCEPTION => try handleException(self.ctx),
            c.JS_TAG_STRING => {},
            else => return error.UnexpectedValue,
        }

        const str = c.JS_ToCString(self.ctx, html);
        defer c.JS_FreeCString(self.ctx, str);

        const result: []const u8 = try arena.dupe(u8, mem.span(str));
        return result;
    }
};
