const testing = @import("std").testing;

pub const core = @import("./core.zig");
pub const sdk = @import("./sdk.gen.zig");

test {
    testing.refAllDecls(@This());
}
