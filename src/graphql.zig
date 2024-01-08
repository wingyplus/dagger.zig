const std = @import("std");
const base64 = std.base64;
const heap = std.heap;
const http = std.http;
const json = std.json;
const Uri = std.Uri;
const testing = std.testing;

const QueryOptions = struct { token: []const u8, port: u16 };

const Query = struct {
    query: []const u8,
};

fn basicAuthUserPasswordAlloc(allocator: std.mem.Allocator, user: []const u8, password: []const u8) ![]const u8 {
    const user_pass = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, password });
    defer allocator.free(user_pass);
    const dst = try allocator.alloc(u8, base64.standard.Encoder.calcSize(user_pass.len));
    return base64.standard.Encoder.encode(dst, user_pass);
}

test basicAuthUserPasswordAlloc {
    const user_pass = try basicAuthUserPasswordAlloc(testing.allocator, "user", "");
    defer testing.allocator.free(user_pass);
    try testing.expectEqualStrings(user_pass, "dXNlcjo=");
}

/// Perform GraphQL query operation to Dagger.
pub fn execute(allocator: std.mem.Allocator, q: []const u8, opts: QueryOptions) !http.Client.FetchResult {
    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri: std.Uri = .{ .scheme = "http", .user = null, .password = null, .host = "127.0.0.1", .port = opts.port, .path = "/query", .query = null, .fragment = null };

    // Prepare authorization.
    const user_pass = try basicAuthUserPasswordAlloc(allocator, opts.token, "");
    defer allocator.free(user_pass);
    const basic_auth = try std.fmt.allocPrint(allocator, "Basic {s}", .{user_pass});
    defer allocator.free(basic_auth);

    var headers: http.Headers = .{ .allocator = allocator, .owned = true };
    defer headers.deinit();

    try headers.append("authorization", basic_auth);
    try headers.append("content-type", "application/json");

    const payload: Query = .{ .query = q };
    const req_body = try json.stringifyAlloc(allocator, payload, .{});
    defer allocator.free(req_body);

    return try client.fetch(allocator, .{ .method = .POST, .location = .{ .uri = uri }, .headers = headers, .payload = .{ .string = req_body } });
}

fn fetchenv(env: []const u8) !?[]const u8 {
    return std.os.getenv(env);
}

test execute {
    const token = (try fetchenv("DAGGER_SESSION_TOKEN")).?;
    const port = (try fetchenv("DAGGER_SESSION_PORT")).?;
    const q =
        \\query {
        \\  container {
        \\    from(address: "nginx") {
        \\      withExec(args: ["echo", "hello"]) {
        \\        stdout
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var result = try execute(testing.allocator, q, .{ .token = token, .port = try std.fmt.parseInt(u16, port, 10) });
    defer result.deinit();

    try testing.expectEqual("{\"data\":{\"container\":{\"from\":{\"withExec\":{\"stdout\":\"hello\n\"}}}}}", result.body);
}
