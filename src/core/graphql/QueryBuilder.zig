const std = @import("std");
const testing = std.testing;

/// A tagged union representing a GraphQL argument value.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    @"null",
};

/// A node in the selection chain. Each node holds a field name, optional alias,
/// optional arguments, and a pointer to the parent selection (prev).
/// Root nodes have prev=null and name="".
pub const Selection = struct {
    name: []const u8,
    alias: []const u8,
    args: std.StringArrayHashMapUnmanaged(Value),
    prev: ?*Selection,

    /// Creates a root selection. Caller owns the returned pointer and must free it
    /// (or use an arena allocator).
    pub fn init(allocator: std.mem.Allocator) !*Selection {
        const sel = try allocator.create(Selection);
        sel.* = .{
            .name = "",
            .alias = "",
            .args = .{},
            .prev = null,
        };
        return sel;
    }

    /// Returns a new child Selection with this as prev.
    pub fn select(self: *Selection, allocator: std.mem.Allocator, name: []const u8) !*Selection {
        return self.selectWithAlias(allocator, "", name);
    }

    /// Returns a new child Selection with an alias and this as prev.
    pub fn selectWithAlias(self: *Selection, allocator: std.mem.Allocator, alias: []const u8, name: []const u8) !*Selection {
        const sel = try allocator.create(Selection);
        sel.* = .{
            .name = name,
            .alias = alias,
            .args = .{},
            .prev = self,
        };
        return sel;
    }

    /// Adds an argument to this selection. Mutates in place. Returns self for chaining.
    pub fn arg(self: *Selection, allocator: std.mem.Allocator, name: []const u8, value: Value) !*Selection {
        try self.args.put(allocator, name, value);
        return self;
    }

    /// Builds the complete GraphQL query string. Caller owns the returned slice.
    pub fn build(self: *Selection, allocator: std.mem.Allocator) ![]const u8 {
        // Collect the chain from this node up to (but not including) root.
        // We store pointers in a temporary array in root-to-leaf order.
        var path = std.ArrayListUnmanaged(*Selection).empty;
        defer path.deinit(allocator);

        var cur: ?*Selection = self;
        while (cur) |node| {
            if (node.prev == null) {
                // This is the root node; stop here (don't include root in path)
                break;
            }
            try path.insert(allocator, 0, node);
            cur = node.prev;
        }

        // Build the query string using Io.Writer.Allocating.
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

            if (node.args.count() > 0) {
                try aw.writer.writeByte('(');
                var first = true;
                var iter = node.args.iterator();
                while (iter.next()) |entry| {
                    if (!first) {
                        try aw.writer.writeAll(", ");
                    }
                    first = false;
                    try aw.writer.writeAll(entry.key_ptr.*);
                    try aw.writer.writeByte(':');
                    try writeValue(&aw.writer, entry.value_ptr.*);
                }
                try aw.writer.writeByte(')');
            }
        }

        // Close each opened brace
        for (path.items) |_| {
            try aw.writer.writeByte('}');
        }

        var result_list = aw.toArrayList();
        defer result_list.deinit(allocator);
        return try allocator.dupe(u8, result_list.items);
    }

    /// Frees argument map entries for this selection only.
    /// Does NOT recurse into prev. Use an arena to free the whole chain.
    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
    }
};

/// Writes a Value to the writer, escaping strings appropriately.
fn writeValue(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .string => |s| {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '\\' => try writer.writeAll("\\\\"),
                    '"' => try writer.writeAll("\\\""),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        },
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .@"null" => try writer.writeAll("null"),
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "simple chain: query{a{b}}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const a = try root.select(alloc, "a");
    const b = try a.select(alloc, "b");

    const q = try b.build(alloc);
    try testing.expectEqualStrings("query{a{b}}", q);
}

test "args: alpine image file query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const image = try (try root.select(alloc, "core"))
        .select(alloc, "image");
    _ = try image.arg(alloc, "ref", .{ .string = "alpine" });
    const file = try image.select(alloc, "file");
    _ = try file.arg(alloc, "path", .{ .string = "/etc/alpine-release" });

    const q = try file.build(alloc);
    try testing.expectEqualStrings(
        \\query{core{image(ref:"alpine"){file(path:"/etc/alpine-release")}}}
    , q);
}

test "alias: query{foo:field(path:\"/etc\")}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const field = try root.selectWithAlias(alloc, "foo", "field");
    _ = try field.arg(alloc, "path", .{ .string = "/etc" });

    const q = try field.build(alloc);
    try testing.expectEqualStrings(
        \\query{foo:field(path:"/etc")}
    , q);
}

test "multiple args on one selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const op = try root.select(alloc, "op");
    _ = try op.arg(alloc, "first", .{ .string = "a" });
    _ = try op.arg(alloc, "second", .{ .string = "b" });

    const q = try op.build(alloc);
    try testing.expectEqualStrings(
        \\query{op(first:"a", second:"b")}
    , q);
}

test "int and bool argument types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const op = try root.select(alloc, "resize");
    _ = try op.arg(alloc, "width", .{ .int = 1920 });
    _ = try op.arg(alloc, "crop", .{ .boolean = true });

    const q = try op.build(alloc);
    try testing.expectEqualStrings("query{resize(width:1920, crop:true)}", q);
}

test "string escaping: quotes and newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Selection.init(alloc);
    const op = try root.select(alloc, "echo");
    _ = try op.arg(alloc, "msg", .{ .string = "say \"hello\"\nworld" });

    const q = try op.build(alloc);
    try testing.expectEqualStrings(
        \\query{echo(msg:"say \"hello\"\nworld")}
    , q);
}
