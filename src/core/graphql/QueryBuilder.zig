const std = @import("std");
const testing = std.testing;

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    null,
};

pub const Arg = struct {
    name: []const u8,
    value: Value,
};

pub const SelectOpts = struct {
    alias: []const u8 = "",
    args: []const Arg = &.{},
    sub_fields: []const []const u8 = &.{},
};

pub const Selection = struct {
    name: []const u8,
    alias: []const u8,
    args: []const Arg,
    sub_fields: []const []const u8,
    prev: ?*Selection,

    pub fn init(allocator: std.mem.Allocator) !*Selection {
        const sel = try allocator.create(Selection);
        sel.* = .{ .name = "", .alias = "", .args = &.{}, .sub_fields = &.{}, .prev = null };
        return sel;
    }

    pub fn select(self: *Selection, allocator: std.mem.Allocator, name: []const u8, opts: SelectOpts) !*Selection {
        const sel = try allocator.create(Selection);
        sel.* = .{
            .name = name,
            .alias = opts.alias,
            .args = try allocator.dupe(Arg, opts.args),
            .sub_fields = try allocator.dupe([]const u8, opts.sub_fields),
            .prev = self,
        };
        return sel;
    }

    pub fn build(self: *Selection, allocator: std.mem.Allocator) ![]const u8 {
        var path = std.ArrayListUnmanaged(*Selection).empty;
        defer path.deinit(allocator);

        var cur: ?*Selection = self;
        while (cur) |node| {
            if (node.prev == null) break;
            try path.insert(allocator, 0, node);
            cur = node.prev;
        }

        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer {
            var al = aw.toArrayList();
            al.deinit(allocator);
        }

        try aw.writer.writeAll("query");

        for (path.items) |node| {
            try aw.writer.writeByte('{');
            if (node.alias.len > 0) {
                try aw.writer.writeAll(node.alias);
                try aw.writer.writeByte(':');
            }
            try aw.writer.writeAll(node.name);
            if (node.args.len > 0) {
                try aw.writer.writeByte('(');
                for (node.args, 0..) |a, i| {
                    if (i > 0) try aw.writer.writeAll(", ");
                    try aw.writer.writeAll(a.name);
                    try aw.writer.writeByte(':');
                    try writeValue(&aw.writer, a.value);
                }
                try aw.writer.writeByte(')');
            }
        }

        const last = path.items[path.items.len - 1];
        if (last.sub_fields.len > 0) {
            try aw.writer.writeByte('{');
            for (last.sub_fields, 0..) |f, i| {
                if (i > 0) try aw.writer.writeByte(' ');
                try aw.writer.writeAll(f);
            }
            try aw.writer.writeByte('}');
        }

        for (path.items) |_| try aw.writer.writeByte('}');

        var result_list = aw.toArrayList();
        defer result_list.deinit(allocator);
        return try allocator.dupe(u8, result_list.items);
    }

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
        allocator.free(self.sub_fields);
    }
};

fn writeValue(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .string => |s| {
            try writer.writeByte('"');
            for (s) |c| switch (c) {
                '\\' => try writer.writeAll("\\\\"),
                '"' => try writer.writeAll("\\\""),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            };
            try writer.writeByte('"');
        },
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("null"),
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "simple chain: query{a{b}}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    var q = try root.select(alloc, "a", .{});
    q = try q.select(alloc, "b", .{});

    try testing.expectEqualStrings("query{a{b}}", try q.build(alloc));
}

test "args: alpine image file query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    var q = try root.select(alloc, "core", .{});
    q = try q.select(alloc, "image", .{ .args = &.{.{ .name = "ref", .value = .{ .string = "alpine" } }} });
    q = try q.select(alloc, "file", .{ .args = &.{.{ .name = "path", .value = .{ .string = "/etc/alpine-release" } }} });

    try testing.expectEqualStrings(
        \\query{core{image(ref:"alpine"){file(path:"/etc/alpine-release")}}}
    , try q.build(alloc));
}

test "alias: query{foo:field(path:\"/etc\")}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const q = try root.select(alloc, "field", .{
        .alias = "foo",
        .args = &.{.{ .name = "path", .value = .{ .string = "/etc" } }},
    });

    try testing.expectEqualStrings(
        \\query{foo:field(path:"/etc")}
    , try q.build(alloc));
}

test "multiple args on one selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const q = try root.select(alloc, "op", .{ .args = &.{
        .{ .name = "first", .value = .{ .string = "a" } },
        .{ .name = "second", .value = .{ .string = "b" } },
    } });

    try testing.expectEqualStrings(
        \\query{op(first:"a", second:"b")}
    , try q.build(alloc));
}

test "int and bool argument types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const q = try root.select(alloc, "resize", .{ .args = &.{
        .{ .name = "width", .value = .{ .int = 1920 } },
        .{ .name = "crop", .value = .{ .boolean = true } },
    } });

    try testing.expectEqualStrings("query{resize(width:1920, crop:true)}", try q.build(alloc));
}

test "sub_fields: multiple fields on last node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    var q = try root.select(alloc, "a", .{});
    q = try q.select(alloc, "b", .{ .sub_fields = &.{ "x", "y" } });

    try testing.expectEqualStrings("query{a{b{x y}}}", try q.build(alloc));
}

test "string escaping: quotes and newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const q = try root.select(alloc, "echo", .{
        .args = &.{.{ .name = "msg", .value = .{ .string = "say \"hello\"\nworld" } }},
    });

    try testing.expectEqualStrings(
        \\query{echo(msg:"say \"hello\"\nworld")}
    , try q.build(alloc));
}
