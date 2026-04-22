const std = @import("std");
const testing = std.testing;
const graphql = @import("./graphql.zig");

const EngineConn = @This();

graphql_client: graphql.Client,

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: std.process.Environ.Map) !EngineConn {
    const session_token = environ_map.get("DAGGER_SESSION_TOKEN") orelse return error.MissingSessionToken;
    const session_port = environ_map.get("DAGGER_SESSION_PORT") orelse return error.MissingSessionPort;
    return .{
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

pub fn execute(builder: *graphql.QueryBuilder) void {
    _ = builder; // autofix
}
