const std = @import("std");
const testing = std.testing;
const graphql = @import("./graphql.zig");
const QueryBuilder = graphql.QueryBuilder;
const Client = graphql.Client;

const EngineConn = @This();

allocator: std.mem.Allocator,
graphql_client: Client,

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: std.process.Environ.Map) !EngineConn {
    const session_token = environ_map.get("DAGGER_SESSION_TOKEN") orelse return error.MissingSessionToken;
    const session_port = environ_map.get("DAGGER_SESSION_PORT") orelse return error.MissingSessionPort;
    return .{
        .allocator = allocator,
        .graphql_client = graphql.Client.init(
            allocator,
            io,
            session_token,
            try std.fmt.parseInt(u16, session_port, 10),
        ),
    };
}

test "init missing session token" {
    var envmap = std.process.Environ.Map.init(testing.allocator);
    defer envmap.deinit();

    try testing.expectError(error.MissingSessionToken, init(testing.allocator, testing.io, envmap));
}

test "init missing session port" {
    var envmap = std.process.Environ.Map.init(testing.allocator);
    defer envmap.deinit();

    try envmap.put("DAGGER_SESSION_TOKEN", "token");

    try testing.expectError(error.MissingSessionPort, init(testing.allocator, testing.io, envmap));
}

pub fn deinit(self: *EngineConn) void {
    self.graphql_client.deinit();
}

/// Execute a GraphQL query and return the leaf node value.
pub fn execute(self: *EngineConn, allocator: std.mem.Allocator, builder: *QueryBuilder) !std.json.Value {
    const query_str = try builder.build(allocator);
    defer allocator.free(query_str);

    var response_out: std.Io.Writer.Allocating = .init(allocator);
    const fetch_result = try self.graphql_client.request(.{ .query = query_str }, &response_out.writer);

    var body_list = response_out.toArrayList();
    defer body_list.deinit(allocator);

    if (fetch_result.status != .ok) {
        return error.HttpError;
    }

    var current = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body_list.items, .{});

    if (current != .object) return error.InvalidResponse;

    if (current.object.get("errors")) |errors| {
        if (errors == .array and errors.array.items.len > 0) {
            return error.GraphQLError;
        }
    }

    current = current.object.get("data") orelse return error.NoData;

    for (builder.fields.items) |field| {
        if (current != .object) return error.InvalidResponse;
        const name = if (field.alias.len > 0) field.alias else field.name;
        // Use only the first part of the name for lookup if it contains sub-selections.
        const lookup_name = if (std.mem.indexOfScalar(u8, name, ' ')) |idx| name[0..idx] else name;
        current = current.object.get(lookup_name) orelse return error.FieldNotFound;
    }

    return current;
}

test "execute: container echo hello" {
    const token = try testing.environ.getAlloc(testing.allocator, "DAGGER_SESSION_TOKEN");
    defer testing.allocator.free(token);
    const port_str = try testing.environ.getAlloc(testing.allocator, "DAGGER_SESSION_PORT");
    defer testing.allocator.free(port_str);

    var envmap = std.process.Environ.Map.init(testing.allocator);
    defer envmap.deinit();
    try envmap.put("DAGGER_SESSION_TOKEN", token);
    try envmap.put("DAGGER_SESSION_PORT", port_str);

    var conn = try init(testing.allocator, testing.io, envmap);
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{ .name = "container" });
    try qb.select(alloc, .{
        .name = "from",
        .args = &.{
            .{
                .name = "address",
                .value = .{ .string = "nginx" },
            },
        },
    });
    try qb.select(alloc, .{
        .name = "withExec",
        .args = &.{
            .{
                .name = "args",
                .value = .{
                    .array = &.{
                        .{ .string = "echo" },
                        .{ .string = "hello" },
                    },
                },
            },
        },
    });
    try qb.select(alloc, .{ .name = "stdout" });

    const val = try conn.execute(alloc, &qb);

    try testing.expect(val == .string);
    try testing.expectEqualStrings("hello\n", val.string);
}

test "execute: container envVariables" {
    const token = try testing.environ.getAlloc(testing.allocator, "DAGGER_SESSION_TOKEN");
    defer testing.allocator.free(token);
    const port_str = try testing.environ.getAlloc(testing.allocator, "DAGGER_SESSION_PORT");
    defer testing.allocator.free(port_str);

    var envmap = std.process.Environ.Map.init(testing.allocator);
    defer envmap.deinit();
    try envmap.put("DAGGER_SESSION_TOKEN", token);
    try envmap.put("DAGGER_SESSION_PORT", port_str);

    var conn = try init(testing.allocator, testing.io, envmap);
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qb = QueryBuilder.query();
    try qb.select(alloc, .{ .name = "container" });
    try qb.select(alloc, .{
        .name = "from",
        .args = &.{
            .{
                .name = "address",
                .value = .{ .string = "alpine" },
            },
        },
    });
    try qb.select(alloc, .{
        .name = "withEnvVariable",
        .args = &.{
            .{ .name = "name", .value = .{ .string = "FOO" } },
            .{ .name = "value", .value = .{ .string = "BAR" } },
        },
    });
    try qb.select(alloc, .{ .name = "envVariables { name value }" });

    const val = try conn.execute(alloc, &qb);

    try testing.expect(val == .array);
    var found = false;
    for (val.array.items) |item| {
        try testing.expect(item == .object);
        const name = item.object.get("name").?;
        const value = item.object.get("value").?;
        if (std.mem.eql(u8, name.string, "FOO")) {
            try testing.expectEqualStrings("BAR", value.string);
            found = true;
        }
    }
    try testing.expect(found);
}
