const std = @import("std");
const testing = std.testing;

pub const core = @import("./core.zig");
pub const sdk = @import("./sdk.gen.zig");

pub fn connect(allocator: std.mem.Allocator, io: std.Io, environ_map: std.process.Environ.Map) !sdk.Client {
    const EngineConn = core.EngineConn;
    const conn = try allocator.create(EngineConn);
    conn.* = try EngineConn.init(allocator, io, environ_map);
    const qb = try allocator.create(core.graphql.QueryBuilder);
    qb.* = core.graphql.QueryBuilder.query();
    return sdk.Client{
        .query_builder = qb,
        .engine_conn = conn,
        .allocator = allocator,
    };
}

test {
    testing.refAllDecls(@This());
}
