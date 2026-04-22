const testing = @import("std").testing;

pub const core = @import("./core.zig");

test {
    testing.refAllDecls(@This());
}
