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
pub fn request(allocator: std.mem.Allocator, io: std.Io, q: []const u8, opts: QueryOptions, response_writer: *std.Io.Writer) !http.Client.FetchResult {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri: std.Uri = .{
        .scheme = "http",
        .user = null,
        .password = null,
        .host = .{ .percent_encoded = "127.0.0.1" },
        .port = opts.port,
        .path = .{ .percent_encoded = "/query" },
        .query = null,
        .fragment = null,
    };

    // Prepare authorization.
    const user_pass = try basicAuthUserPasswordAlloc(allocator, opts.token, "");
    defer allocator.free(user_pass);
    const basic_auth = try std.fmt.allocPrint(allocator, "Basic {s}", .{user_pass});
    defer allocator.free(basic_auth);

    const payload: Query = .{ .query = q };

    var out: std.Io.Writer.Allocating = .init(allocator);
    var stringify = json.Stringify{ .writer = &out.writer };
    try stringify.write(payload);
    var body_list = out.toArrayList();
    defer body_list.deinit(allocator);

    return try client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .headers = .{
            .authorization = .{ .override = basic_auth },
            .content_type = .{ .override = "application/json" },
        },
        .payload = body_list.items,
        .response_writer = response_writer,
    });
}

test request {
    const token = try testing.environ.getAlloc(testing.allocator, "DAGGER_SESSION_TOKEN");
    defer testing.allocator.free(token);
    const port = try testing.environ.getAlloc(testing.allocator, "DAGGER_SESSION_PORT");
    defer testing.allocator.free(port);

    var response: std.Io.Writer.Allocating = .init(testing.allocator);

    const query =
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
    const result = try request(
        testing.allocator,
        testing.io,
        query,
        .{
            .token = token,
            .port = try std.fmt.parseInt(u16, port, 10),
        },
        &response.writer,
    );
    try testing.expectEqual(.ok, result.status);

    var body = response.toArrayList();
    defer body.deinit(testing.allocator);

    try testing.expectEqualStrings("{\"data\":{\"container\":{\"from\":{\"withExec\":{\"stdout\":\"hello\\n\"}}}}}", body.items);
}
