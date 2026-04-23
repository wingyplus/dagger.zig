const std = @import("std");
const testing = std.testing;
const dagger = @import("dagger");
const sdk = dagger.sdk;
const QueryBuilder = dagger.core.graphql.QueryBuilder;

fn getTestClient(allocator: std.mem.Allocator) !sdk.Client {
    const envmap = try testing.environ.createMap(allocator);
    return try dagger.connect(allocator, testing.io, envmap);
}

test "sdk: container stdout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const client = try getTestClient(allocator);

    var ctr = try client.container(.{});
    ctr = try ctr.from("alpine:3.20.2");
    ctr = try ctr.withExec(&.{ "cat", "/etc/alpine-release" }, .{});

    const version = try ctr.stdout();
    try testing.expectEqualStrings("3.20.2\n", version);
}

test "sdk: git repository" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const client = try getTestClient(allocator);

    const repo = try client.git("https://github.com/dagger/dagger", .{});
    const tree = try (try repo.tag("v0.3.0")).tree(.{});
    const file = try tree.file("README.md");
    const contents = try file.contents(.{});

    try testing.expect(std.mem.startsWith(u8, contents, "## What is Dagger?"));
}

test "sdk: container with env variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const client = try getTestClient(allocator);

    var ctr = try client.container(.{});
    ctr = try ctr.from("alpine:3.20.2");
    ctr = try ctr.withEnvVariable("FOO", "bar", .{});
    ctr = try ctr.withExec(&.{ "sh", "-c", "echo -n $FOO" }, .{});

    const out = try ctr.stdout();
    try testing.expectEqualStrings("bar", out);
}

test "sdk: directory entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const client = try getTestClient(allocator);

    var dir = try client.directory();
    dir = try dir.withNewFile("hello.txt", "Hello, world!", .{});
    dir = try dir.withNewFile("goodbye.txt", "Goodbye, world!", .{});

    const entries = try dir.entries(.{});
    try testing.expectEqual(@as(usize, 2), entries.len);
    // Entries might not be sorted
    var found_hello = false;
    var found_goodbye = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, "hello.txt")) found_hello = true;
        if (std.mem.eql(u8, entry, "goodbye.txt")) found_goodbye = true;
    }
    try testing.expect(found_hello);
    try testing.expect(found_goodbye);
}
