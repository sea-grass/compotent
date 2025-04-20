const c = @import("c");
const debug = std.debug;
const mem = std.mem;
const std = @import("std");

/// Used to encode an instance of a Zig struct as a JS object.
pub const Data = struct {
    payload: c.JSValue,

    pub fn init(comptime T: type, ctx: *Context, payload: T) !Data {
        const obj = try createObject(@TypeOf(payload), ctx, payload);
        errdefer c.JS_FreeValue(ctx.ctx, obj);

        return .{ .payload = obj };
    }

    pub fn deinit(self: Data, ctx: *Context) void {
        c.JS_FreeValue(ctx.ctx, self.payload);
    }

    fn createObject(comptime T: type, ctx: *Context, data: T) !c.JSValue {
        const value = c.JS_NewObject(ctx.ctx);
        errdefer c.JS_FreeValue(ctx.ctx, value);

        inline for (@typeInfo(T).@"struct".fields) |field| {
            try addProp(field.type, ctx, value, field.name, @field(data, field.name));
        }

        return value;
    }

    fn addProp(comptime T: type, ctx: *Context, obj: c.JSValue, name: []const u8, value: T) !void {
        const prop_value = try createValue(T, ctx, value);
        switch (c.JS_SetPropertyStr(ctx.ctx, obj, @ptrCast(name), prop_value)) {
            1 => {},
            else => @panic("Handle failure"),
        }
    }

    fn createValue(comptime T: type, ctx: *Context, value: T) !c.JSValue {
        return value: {
            switch (@typeInfo(T)) {
                .pointer => |pointer| {
                    switch (pointer.size) {
                        .slice => {
                            if (pointer.child == u8) {
                                break :value try createString(ctx, value);
                            } else {
                                break :value try createArray(pointer.child, ctx, value);
                            }
                        },
                        .one => {
                            switch (@typeInfo(pointer.child)) {
                                .array => |array| {
                                    switch (array.child) {
                                        u8 => break :value try createString(ctx, value),
                                        else => @compileLog("a", @typeInfo(T)),
                                    }
                                },
                                else => @compileLog("b", pointer.child, @typeInfo(pointer.child)),
                            }
                        },
                        else => @compileLog("c", @typeInfo(T)),
                    }
                },
                .@"struct" => {
                    break :value try createObject(T, ctx, value);
                },
                else => @compileLog("d", @typeInfo(T)),
            }
        };
    }

    fn createString(ctx: *Context, str: anytype) !c.JSValue {
        return c.JS_NewString(ctx.ctx, @ptrCast(str));
    }

    fn createArray(comptime T: type, ctx: *Context, arr: []const T) !c.JSValue {
        const js_arr = c.JS_NewArray(ctx.ctx);
        errdefer c.JS_FreeValue(js_arr);

        for (arr, 0..) |entry, index| {
            const value = try createValue(T, ctx, entry);
            switch (c.JS_DefinePropertyValueUint32(ctx.ctx, js_arr, @intCast(index), value, 0)) {
                1 => {},
                else => @panic("TODO"),
            }
        }

        return js_arr;
    }
};

pub const Context = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,

    map: std.StringHashMapUnmanaged(Component),

    pub const Component = struct {
        mod: c.JSValue,
    };

    pub const RenderOptions = struct {
        data: ?Data,
    };
    pub const RenderResult = struct {
        html: []const u8,
    };
    pub const Assets = struct {
        css: ?[]const u8 = null,
        js: ?[]const u8 = null,
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

    pub fn encode(self: *Context, comptime T: type, payload: T) !Data {
        return try Data.init(T, self, payload);
    }

    fn safeModuleName(name: []const u8) bool {
        const contains_unsafe_characters = if (mem.indexOfAny(u8, name, "'")) |_| true else false;

        return !contains_unsafe_characters;
    }

    pub fn register(self: *Context, arena: mem.Allocator, name: []const u8, src: []const u8) !void {
        debug.assert(safeModuleName(name));

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

    pub fn render(self: *Context, arena: mem.Allocator, name: []const u8, opts: RenderOptions) !RenderResult {
        debug.assert(safeModuleName(name));
        if (!self.map.contains(name)) return error.ComponentNotRegistered;

        const global_object = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, global_object);

        if (opts.data) |data| {
            const value = c.JS_DupValue(self.ctx, data.payload);
            const res = c.JS_SetPropertyStr(self.ctx, global_object, "data", value);
            std.log.info("Set global data res {d}", .{res});
        }

        var buf: std.ArrayList(u8) = .init(arena);
        defer buf.deinit();
        try buf.writer().print(
            \\import * as c from '{s}';
            \\globalThis.html = globalThis.data ? c.render(data) : c.render();
            \\globalThis.script = c.js;
            \\globalThis.style = c.css;
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

        const html = html: {
            const html = c.JS_GetPropertyStr(self.ctx, global_object, "html");
            defer c.JS_FreeValue(self.ctx, html);
            switch (html.tag) {
                c.JS_TAG_EXCEPTION => try handleException(self.ctx),
                c.JS_TAG_STRING => {},
                else => return error.UnexpectedValue,
            }

            const str = c.JS_ToCString(self.ctx, html);
            defer c.JS_FreeCString(self.ctx, str);

            break :html try arena.dupe(u8, mem.span(str));
        };

        return .{
            .html = html,
        };
    }

    pub fn getAssets(self: *Context, arena: mem.Allocator, name: []const u8) !Assets {
        debug.assert(safeModuleName(name));
        if (!self.map.contains(name)) return error.ComponentNotRegistered;

        const global_object = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, global_object);

        var buf: std.ArrayList(u8) = .init(arena);
        defer buf.deinit();
        try buf.writer().print(
            \\import * as c from '{s}';
            \\globalThis.html = globalThis.data ? c.render(data) : c.render();
            \\globalThis.script = c.js;
            \\globalThis.style = c.css;
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

        const js = js: {
            const js = c.JS_GetPropertyStr(self.ctx, global_object, "script");
            defer c.JS_FreeValue(self.ctx, js);
            switch (js.tag) {
                c.JS_TAG_EXCEPTION => try handleException(self.ctx),
                c.JS_TAG_STRING => {},
                else => return error.UnexpectedValue,
            }

            const str = c.JS_ToCString(self.ctx, js);
            defer c.JS_FreeCString(self.ctx, str);

            break :js try arena.dupe(u8, mem.span(str));
        };

        const css = css: {
            const css = c.JS_GetPropertyStr(self.ctx, global_object, "style");
            defer c.JS_FreeValue(self.ctx, css);
            switch (css.tag) {
                c.JS_TAG_EXCEPTION => try handleException(self.ctx),
                c.JS_TAG_STRING => {},
                else => return error.UnexpectedValue,
            }

            const str = c.JS_ToCString(self.ctx, css);
            defer c.JS_FreeCString(self.ctx, str);

            break :css try arena.dupe(u8, mem.span(str));
        };

        return .{
            .js = js,
            .css = css,
        };
    }
};

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
