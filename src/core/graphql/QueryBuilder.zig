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

    pub fn from(allocator: std.mem.Allocator, val: anytype) !Value {
        const T = @TypeOf(val);
        const info = @typeInfo(T);
        if (T == []const u8) {
            return Value{ .string = val };
        } else if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .array and @typeInfo(info.pointer.child).array.child == u8) {
            return Value{ .string = val };
        } else if (T == i32 or T == i64 or T == u32 or T == u64) {
            return Value{ .int = @intCast(val) };
        } else if (T == f32 or T == f64) {
            return Value{ .float = @floatCast(val) };
        } else if (T == bool) {
            return Value{ .boolean = val };
        } else if (info == .optional) {
            if (val) |v| return try from(allocator, v) else return .null;
        } else if (info == .@"enum") {
            return Value{ .string = @tagName(val) };
        } else if (info == .pointer) {
            const ptr_info = info.pointer;
            if (ptr_info.size == .slice or (ptr_info.size == .one and @typeInfo(ptr_info.child) == .array)) {
                var list = std.ArrayListUnmanaged(Value).empty;
                errdefer {
                    for (list.items) |v| v.deinit(allocator);
                    list.deinit(allocator);
                }
                for (val) |item| try list.append(allocator, try from(allocator, item));
                return Value{ .array = try list.toOwnedSlice(allocator) };
            }
        } else if (info == .@"struct") {
            if (comptime @hasDecl(T, "toValue")) {
                return try val.toValue(allocator);
            }
            const fields_info = info.@"struct".fields;
            if (fields_info.len == 1 and std.mem.eql(u8, fields_info[0].name, "value") and fields_info[0].type == []const u8) {
                return Value{ .string = @field(val, "value") };
            }

            var input_fields = std.ArrayListUnmanaged(InputField).empty;
            errdefer {
                for (input_fields.items) |f| f.value.deinit(allocator);
                input_fields.deinit(allocator);
            }
            inline for (fields_info) |f| {
                const field_val = @field(val, f.name);
                if (@typeInfo(f.type) == .optional) {
                    if (field_val) |v| {
                        try input_fields.append(allocator, .{
                            .name = f.name,
                            .value = try from(allocator, v),
                        });
                    }
                } else {
                    try input_fields.append(allocator, .{
                        .name = f.name,
                        .value = try from(allocator, field_val),
                    });
                }
            }
            return Value{ .object = try input_fields.toOwnedSlice(allocator) };
        }
        return .null;
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .array => |a| {
                for (a) |v| v.deinit(allocator);
                allocator.free(a);
            },
            .object => |o| {
                for (o) |f| f.value.deinit(allocator);
                allocator.free(o);
            },
            else => {},
        }
    }

    pub fn build(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .string => |s| {
                try writer.writeByte('"');
                for (s) |c| {
                    if (c == '"') {
                        try writer.writeAll("\\\"");
                    } else if (c == '\n') {
                        try writer.writeAll("\\n");
                    } else {
                        try writer.writeByte(c);
                    }
                }
                try writer.writeByte('"');
            },
            .int => |i| try writer.print("{}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .boolean => |b| try writer.print("{}", .{b}),
            .array => |a| {
                try writer.writeByte('[');
                for (a, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try v.build(writer);
                }
                try writer.writeByte(']');
            },
            .object => |o| {
                try writer.writeByte('{');
                for (o, 0..) |f, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{s}: ", .{f.name});
                    try f.value.build(writer);
                }
                try writer.writeByte('}');
            },
            .null => try writer.writeAll("null"),
        }
    }
};

test "Value.from" {
    const alloc = testing.allocator;

    const s = try Value.from(alloc, "hello");
    defer s.deinit(alloc);
    try testing.expectEqual(Value{ .string = "hello" }, s);

    const i = try Value.from(alloc, @as(i32, 42));
    defer i.deinit(alloc);
    try testing.expectEqual(Value{ .int = 42 }, i);

    const i64_val = try Value.from(alloc, @as(i64, -100));
    defer i64_val.deinit(alloc);
    try testing.expectEqual(Value{ .int = -100 }, i64_val);

    const u32_val = try Value.from(alloc, @as(u32, 100));
    defer u32_val.deinit(alloc);
    try testing.expectEqual(Value{ .int = 100 }, u32_val);

    const u64_val = try Value.from(alloc, @as(u64, 200));
    defer u64_val.deinit(alloc);
    try testing.expectEqual(Value{ .int = 200 }, u64_val);

    const f32_val = try Value.from(alloc, @as(f32, 3.14));
    defer f32_val.deinit(alloc);
    try testing.expect(f32_val == .float);
    try testing.expectApproxEqAbs(@as(f64, 3.14), f32_val.float, 0.0001);

    const f64_val = try Value.from(alloc, @as(f64, 2.718));
    defer f64_val.deinit(alloc);
    try testing.expectEqual(Value{ .float = 2.718 }, f64_val);

    const b = try Value.from(alloc, true);
    defer b.deinit(alloc);
    try testing.expectEqual(Value{ .boolean = true }, b);

    const opt = try Value.from(alloc, @as(?i32, null));
    defer opt.deinit(alloc);
    try testing.expectEqual(Value.null, opt);

    const opt_val = try Value.from(alloc, @as(?i32, 10));
    defer opt_val.deinit(alloc);
    try testing.expectEqual(Value{ .int = 10 }, opt_val);

    const MyEnum = enum { foo, bar };
    const e = try Value.from(alloc, MyEnum.foo);
    defer e.deinit(alloc);
    try testing.expectEqualStrings("foo", e.string);

    const arr = try Value.from(alloc, &[_]i32{ 1, 2, 3 });
    defer arr.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), arr.array.len);
    try testing.expectEqual(Value{ .int = 1 }, arr.array[0]);

    const slice: []const i32 = &[_]i32{ 4, 5 };
    const arr_slice = try Value.from(alloc, slice);
    defer arr_slice.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), arr_slice.array.len);
    try testing.expectEqual(Value{ .int = 4 }, arr_slice.array[0]);

    const nested = try Value.from(alloc, &[_][]const i32{ &[_]i32{1}, &[_]i32{ 2, 3 } });
    defer nested.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), nested.array.len);
    try testing.expectEqual(@as(usize, 1), nested.array[0].array.len);
    try testing.expectEqual(@as(usize, 2), nested.array[1].array.len);

    const StructWithValue = struct { value: []const u8 };
    const swv = try Value.from(alloc, StructWithValue{ .value = "from_struct" });
    defer swv.deinit(alloc);
    try testing.expectEqual(Value{ .string = "from_struct" }, swv);

    // Multi-field struct (Input Object)
    const BuildArg = struct { name: []const u8, value: []const u8 };
    const ba = try Value.from(alloc, BuildArg{ .name = "FOO", .value = "BAR" });
    defer ba.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), ba.object.len);
    try testing.expectEqualStrings("name", ba.object[0].name);
    try testing.expectEqualStrings("FOO", ba.object[0].value.string);
    try testing.expectEqualStrings("value", ba.object[1].name);
    try testing.expectEqualStrings("BAR", ba.object[1].value.string);

    // Struct with optional fields
    const OptStruct = struct { a: i32, b: ?i32 };
    const os1 = try Value.from(alloc, OptStruct{ .a = 1, .b = 2 });
    defer os1.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), os1.object.len);

    const os2 = try Value.from(alloc, OptStruct{ .a = 1, .b = null });
    defer os2.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), os2.object.len);
    try testing.expectEqualStrings("a", os2.object[0].name);

    // toValue override
    const Custom = struct {
        pub fn toValue(_: @This(), a: std.mem.Allocator) !Value {
            return try Value.from(a, "custom");
        }
    };
    const c = try Value.from(alloc, Custom{});
    defer c.deinit(alloc);
    try testing.expectEqualStrings("custom", c.string);
}

pub const Arg = struct {
    name: []const u8,
    value: Value,

    pub fn deinit(self: Arg, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }

    pub fn build(self: Arg, writer: *std.Io.Writer) !void {
        try writer.print("{s}: ", .{self.name});
        try self.value.build(writer);
    }
};

pub const Field = struct {
    name: []const u8,
    alias: []const u8 = "",
    args: []const Arg = &.{},

    pub fn deinit(self: Field, allocator: std.mem.Allocator) void {
        for (self.args) |a| a.deinit(allocator);
        allocator.free(self.args);
    }

    pub fn build(self: Field, writer: *std.Io.Writer) !void {
        if (self.alias.len > 0) {
            try writer.print("{s}: {s}", .{ self.alias, self.name });
        } else {
            try writer.writeAll(self.name);
        }
        if (self.args.len > 0) {
            try writer.writeByte('(');
            for (self.args, 0..) |a, i| {
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

pub fn deinit(self: *QueryBuilder, allocator: std.mem.Allocator) void {
    for (self.fields.items) |f| f.deinit(allocator);
    self.fields.deinit(allocator);
}

/// Select appends a field to the selection chain.
pub fn select(self: *QueryBuilder, allocator: std.mem.Allocator, field: Field) !void {
    try self.fields.append(allocator, field);
}

/// Build a GraphQL query string.
pub fn build(self: *QueryBuilder, allocator: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer {
        var al = aw.toArrayList();
        al.deinit(allocator);
    }
    const writer = &aw.writer;

    try writer.writeAll("query{");
    for (self.fields.items, 0..) |f, i| {
        if (i > 0) try writer.writeByte('{');
        try f.build(writer);
    }
    for (0..self.fields.items.len - 1) |_| {
        try writer.writeByte('}');
    }
    try writer.writeByte('}');

    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
}

test "build simple query" {
    const alloc = testing.allocator;
    var qb = query();
    defer qb.deinit(alloc);

    try qb.select(alloc, .{ .name = "container" });
    const args = try alloc.alloc(Arg, 1);
    args[0] = .{ .name = "address", .value = .{ .string = "alpine" } };
    try qb.select(alloc, .{ .name = "from", .args = args });
    try qb.select(alloc, .{ .name = "id" });

    const q = try qb.build(alloc);
    defer alloc.free(q);

    try testing.expectEqualStrings("query{container{from(address: \"alpine\"){id}}}", q);
}

test "build query with alias" {
    const alloc = testing.allocator;
    var qb = query();
    defer qb.deinit(alloc);

    try qb.select(alloc, .{
        .name = "container",
        .alias = "c",
    });

    const q = try qb.build(alloc);
    defer alloc.free(q);

    try testing.expectEqualStrings("query{c: container}", q);
}

test "build query with multiple args" {
    const alloc = testing.allocator;
    var qb = query();
    defer qb.deinit(alloc);

    const args = try alloc.alloc(Arg, 2);
    args[0] = .{ .name = "first", .value = .{ .int = 1 } };
    args[1] = .{ .name = "second", .value = .{ .boolean = true } };
    try qb.select(alloc, .{
        .name = "op",
        .args = args,
    });

    const q = try qb.build(alloc);
    defer alloc.free(q);

    try testing.expectEqualStrings("query{op(first: 1, second: true)}", q);
}

test "build query with object and array args" {
    const alloc = testing.allocator;
    var qb = query();
    defer qb.deinit(alloc);

    const args = try alloc.alloc(Arg, 1);
    args[0] = .{
        .name = "msg",
        .value = .{ .string = "say \"hello\"\nworld" },
    };
    try qb.select(alloc, .{
        .name = "echo",
        .args = args,
    });

    const q = try qb.build(alloc);
    defer alloc.free(q);
    try testing.expectEqualStrings(
        \\query{echo(msg: "say \"hello\"\nworld")}
    , q);
}

test "nested input object" {
    const alloc = testing.allocator;
    var qb = query();
    defer qb.deinit(alloc);

    const inner_obj = try alloc.alloc(InputField, 1);
    inner_obj[0] = .{ .name = "active", .value = .{ .boolean = true } };
    const outer_obj = try alloc.alloc(InputField, 1);
    outer_obj[0] = .{
        .name = "filter",
        .value = .{
            .object = inner_obj,
        },
    };
    const args = try alloc.alloc(Arg, 1);
    args[0] = .{
        .name = "opts",
        .value = .{
            .object = outer_obj,
        },
    };
    try qb.select(alloc, .{
        .name = "op",
        .args = args,
    });

    const q = try qb.build(alloc);
    defer alloc.free(q);

    try testing.expectEqualStrings("query{op(opts: {filter: {active: true}})}", q);
}
