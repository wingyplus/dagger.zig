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

fn basicAuthUserPassword(allocator: std.mem.Allocator, user: []const u8, password: []const u8) ![]const u8 {
    var user_pass = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, password });
    defer allocator.free(user_pass);
    var dst = try allocator.alloc(u8, base64.standard.Encoder.calcSize(user_pass.len));
    return base64.standard.Encoder.encode(dst, user_pass);
}

test "basicAuthUserPassword" {
    var user_pass = try basicAuthUserPassword(testing.allocator, "user", "");
    defer testing.allocator.free(user_pass);
    try testing.expectEqualStrings(user_pass, "dXNlcjo=");
}

/// Perform GraphQL query operation to Dagger.
pub fn query(allocator: std.mem.Allocator, q: []const u8, opts: QueryOptions) !void {
    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var uri: std.Uri = .{ .scheme = "http", .user = null, .password = null, .host = "127.0.0.1", .port = opts.port, .path = "/query", .query = null, .fragment = null };

    var headers: http.Headers = .{ .allocator = allocator, .owned = true };
    defer headers.deinit();

    // TODO: make it clean.
    var auth = try std.fmt.allocPrint(allocator, "{s}:", .{opts.token});
    defer allocator.free(auth);

    // Prepare authorization.
    var user_pass = try basicAuthUserPassword(allocator, opts.token, "");
    defer allocator.free(user_pass);
    var basicAuth = try std.fmt.allocPrint(allocator, "Basic {s}", .{user_pass});
    defer allocator.free(basicAuth);

    try headers.append("authorization", basicAuth);
    try headers.append("content-type", "application/json");

    var payload: Query = .{ .query = q };
    var req_body = try json.stringifyAlloc(allocator, payload, .{});
    defer allocator.free(req_body);

    var req = try client.request(.POST, uri, headers, .{});
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = req_body.len };
    try req.start();
    try req.writeAll(req_body);
    try req.finish();
    try req.wait();

    const content_length = req.response.headers.getFirstValue("content-length") orelse @panic("content-length must be specify");
    const resp_body = try req.reader().readAllAlloc(allocator, try std.fmt.parseInt(usize, content_length, 10));
    defer allocator.free(resp_body);
    std.debug.print("Result: {s}\n", .{resp_body});
}

test "query" {
    const token = std.os.getenv("DAGGER_SESSION_TOKEN") orelse @panic("DAGGER_SESSION_TOKEN is required");
    const port = std.os.getenv("DAGGER_SESSION_PORT") orelse @panic("DAGGER_SESSION_PORT is required");
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
    try query(testing.allocator, q, .{ .token = token, .port = try std.fmt.parseInt(u16, port, 10) });
}
