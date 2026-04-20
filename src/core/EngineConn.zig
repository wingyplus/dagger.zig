const std = @import("std");
const graphql = @import("./graphql.zig");

const EngineConn = @This();

graphql_client: graphql.Client,

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: std.process.Environ.Map) !*EngineConn {
    const session_token = environ_map.get("DAGGER_SESSION_TOKEN");
    const session_port = environ_map.get("DAGGER_SESSION_PORT");
    return .{
        .graphql_client = graphql.Client.init(
            allocator,
            io,
            session_token,
            try std.fmt.parseInt(u16, session_port, 10),
        ),
    };
}

pub fn deinit(self: *EngineConn) void {
    self.graphql_client.deinit();
}

pub fn execute(builder: *graphql.QueryBuilder) void {
    _ = builder; // autofix
}
