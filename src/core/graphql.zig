const testing = @import("std").testing;

pub const Client = @import("./graphql/Client.zig");
pub const QueryBuilder = @import("./graphql/QueryBuilder.zig");

test {
    testing.refAllDecls(@This());
}
