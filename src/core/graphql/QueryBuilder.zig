const std = @import("std");
const testing = std.testing;

const QueryBuilder = @This();

pub const InputField = struct {
    name: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
    object: []const InputField,
    null,

    pub fn build(value: Value, writer: *std.Io.Writer) !void {
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
            .array => |a| {
                try writer.writeByte('[');
                for (a, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.build(writer);
                }
                try writer.writeByte(']');
            },
            .object => |fields| {
                try writer.writeByte('{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(f.name);
                    try writer.writeByte(':');
                    try f.value.build(writer);
                }
                try writer.writeByte('}');
            },
            .null => try writer.writeAll("null"),
        }
    }
};

pub const Arg = struct {
    name: []const u8,
    value: Value,

    pub fn build(arg: Arg, writer: *std.Io.Writer) !void {
        try writer.writeAll(arg.name);
        try writer.writeByte(':');
        try arg.value.build(writer);
    }
};

pub const Field = struct {
    name: []const u8,
    alias: []const u8 = "",
    args: []const Arg = &.{},

    pub fn build(field: Field, writer: *std.Io.Writer) !void {
        if (field.alias.len > 0) {
            try writer.writeAll(field.alias);
            try writer.writeByte(':');
        }
        try writer.writeAll(field.name);
        if (field.args.len > 0) {
            try writer.writeByte('(');
            for (field.args, 0..) |a, i| {
                if (i > 0) try writer.writeAll(", ");
                try a.build(writer);
            }
            try writer.writeByte(')');
        }
    }
};

fields: std.ArrayListUnmanaged(Field),

/// A root query.
pub fn query() QueryBuilder {
    return .{ .fields = .empty };
}

/// Select appends a field to the selection chain.
pub fn select(self: *QueryBuilder, allocator: std.mem.Allocator, field: Field) !void {
    try self.fields.append(allocator, .{
        .name = field.name,
        .alias = field.alias,
        .args = try allocator.dupe(Arg, field.args),
    });
}

/// Build a GraphQL query string.
pub fn build(self: *QueryBuilder, allocator: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer {
        var al = aw.toArrayList();
        al.deinit(allocator);
    }

    try aw.writer.writeAll("query");

    for (self.fields.items) |field| {
        try aw.writer.writeByte('{');
        try field.build(&aw.writer);
    }

    for (self.fields.items) |_| try aw.writer.writeByte('}');

    var result_list = aw.toArrayList();
    defer result_list.deinit(allocator);
    return try allocator.dupe(u8, result_list.items);
}

test "simple chain: query{a{b}}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{ .name = "a" });
    try qb.select(alloc, .{ .name = "b" });

    try testing.expectEqualStrings("query{a{b}}", try qb.build(alloc));
}

test "args: alpine image file query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{ .name = "core" });
    try qb.select(alloc, .{
        .name = "image",
        .args = &.{.{
            .name = "ref",
            .value = .{ .string = "alpine" },
        }},
    });
    try qb.select(alloc, .{
        .name = "file",
        .args = &.{.{
            .name = "path",
            .value = .{ .string = "/etc/alpine-release" },
        }},
    });

    try testing.expectEqualStrings(
        \\query{core{image(ref:"alpine"){file(path:"/etc/alpine-release")}}}
    , try qb.build(alloc));
}

test "alias: query{foo:field(path:\"/etc\")}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{
        .name = "field",
        .alias = "foo",
        .args = &.{.{
            .name = "path",
            .value = .{ .string = "/etc" },
        }},
    });

    try testing.expectEqualStrings(
        \\query{foo:field(path:"/etc")}
    , try qb.build(alloc));
}

test "multiple args on one selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{
        .name = "op",
        .args = &.{
            .{ .name = "first", .value = .{ .string = "a" } },
            .{ .name = "second", .value = .{ .string = "b" } },
        },
    });

    try testing.expectEqualStrings(
        \\query{op(first:"a", second:"b")}
    , try qb.build(alloc));
}

test "int and bool argument types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{
        .name = "resize",
        .args = &.{
            .{ .name = "width", .value = .{ .int = 1920 } },
            .{ .name = "crop", .value = .{ .boolean = true } },
        },
    });

    try testing.expectEqualStrings("query{resize(width:1920, crop:true)}", try qb.build(alloc));
}

test "input object argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{
        .name = "createUser",
        .args = &.{.{
            .name = "input",
            .value = .{
                .object = &.{
                    .{ .name = "name", .value = .{ .string = "Alice" } },
                    .{ .name = "age", .value = .{ .int = 30 } },
                },
            },
        }},
    });

    try testing.expectEqualStrings(
        \\query{createUser(input:{name:"Alice", age:30})}
    , try qb.build(alloc));
}

test "nested input object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{
        .name = "op",
        .args = &.{.{
            .name = "opts",
            .value = .{
                .object = &.{
                    .{
                        .name = "filter",
                        .value = .{
                            .object = &.{
                                .{ .name = "active", .value = .{ .boolean = true } },
                            },
                        },
                    },
                },
            },
        }},
    });

    try testing.expectEqualStrings(
        "query{op(opts:{filter:{active:true}})}",
        try qb.build(alloc),
    );
}

test "string escaping: quotes and newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{
        .name = "echo",
        .args = &.{
            .{
                .name = "msg",
                .value = .{ .string = "say \"hello\"\nworld" },
            },
        },
    });

    try testing.expectEqualStrings(
        \\query{echo(msg:"say \"hello\"\nworld")}
    , try qb.build(alloc));
}
