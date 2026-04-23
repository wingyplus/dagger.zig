const std = @import("std");
const schema = @import("schema.zig");
const generator = @import("generator.zig");

pub fn main(init: std.process.Init) !void {
    // Use arena allocator for everything in the generator to avoid manual freeing and leaks.
    const allocator = init.arena.allocator();
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);

    _ = args.next(); // skip program name
    const input_path = args.next() orelse {
        std.debug.print("Usage: codegen <introspection.json>\n", .{});
        std.process.exit(1);
    };

    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, input_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    const content = try allocator.alloc(u8, @intCast(file_len));

    _ = try file.readPositionalAll(io, content, 0);

    const parsed = try std.json.parseFromSlice(schema.Schema, allocator, content, .{
        .ignore_unknown_fields = true,
    });

    const output_file = try dir.createFile(io, "src/sdk.gen.zig", .{});
    defer output_file.close(io);

    var gen = generator.Generator.init(allocator, parsed.value);
    
    var write_buf: [4096]u8 = undefined;
    var writer = output_file.writer(io, &write_buf);
    try gen.generate(&writer.interface);
    try writer.flush();

    std.debug.print("Successfully generated src/sdk.gen.zig from {s}\n", .{input_path});
}
