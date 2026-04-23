const std = @import("std");
const testing = std.testing;

const GraphQLClient = @This();

pub const Query = struct {
    query: []const u8,
};

allocator: std.mem.Allocator,
io: std.Io,
http_client: std.http.Client,
session_token: []const u8,
uri: std.Uri,

/// Creates a new GraphQLClient connected to the given session endpoint.
pub fn init(allocator: std.mem.Allocator, io: std.Io, session_token: []const u8, session_port: u16) GraphQLClient {
    return .{
        .allocator = allocator,
        .io = io,
        .http_client = .{ .allocator = allocator, .io = io },
        .session_token = session_token,
        .uri = .{
            .scheme = "http",
            .user = null,
            .password = null,
            .host = .{ .percent_encoded = "127.0.0.1" },
            .port = session_port,
            .path = .{ .percent_encoded = "/query" },
            .query = null,
            .fragment = null,
        },
    };
}

/// Releases resources held by the client. Must be called when done.
pub fn deinit(self: *GraphQLClient) void {
    self.http_client.deinit();
}

/// Sends a GraphQL query and streams the response body into `response_writer`.
pub fn request(self: *GraphQLClient, query: Query, response_writer: *std.Io.Writer) !std.http.Client.FetchResult {
    // Prepare authorization.
    const user_pass = try basicAuthUserPasswordAlloc(self.allocator, self.session_token, "");
    defer self.allocator.free(user_pass);
    const basic_auth = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{user_pass});
    defer self.allocator.free(basic_auth);

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    var stringify = std.json.Stringify{ .writer = &out.writer };
    try stringify.write(query);
    var body_list = out.toArrayList();
    defer body_list.deinit(self.allocator);

    return try self.http_client.fetch(.{
        .method = .POST,
        .location = .{ .uri = self.uri },
        .headers = .{
            .authorization = .{ .override = basic_auth },
            .content_type = .{ .override = "application/json" },
        },
        .payload = body_list.items,
        .response_writer = response_writer,
    });
}

test "GraphQLClient.request" {
    var env_map = try testing.environ.createMap(testing.allocator);
    defer env_map.deinit();
    const token = env_map.get("DAGGER_SESSION_TOKEN") orelse return error.MissingSessionToken;
    const port_str = env_map.get("DAGGER_SESSION_PORT") orelse return error.MissingSessionPort;

    var client = GraphQLClient.init(testing.allocator, testing.io, token, try std.fmt.parseInt(u16, port_str, 10));
    defer client.deinit();

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
    const result = try client.request(.{ .query = query }, &response.writer);
    try testing.expectEqual(.ok, result.status);

    var body = response.toArrayList();
    defer body.deinit(testing.allocator);

    try testing.expectEqualStrings("{\"data\":{\"container\":{\"from\":{\"withExec\":{\"stdout\":\"hello\\n\"}}}}}", body.items);
}

fn basicAuthUserPasswordAlloc(allocator: std.mem.Allocator, user: []const u8, password: []const u8) ![]const u8 {
    const user_pass = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, password });
    defer allocator.free(user_pass);
    const dst = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(user_pass.len));
    return std.base64.standard.Encoder.encode(dst, user_pass);
}

test basicAuthUserPasswordAlloc {
    const user_pass = try basicAuthUserPasswordAlloc(testing.allocator, "user", "");
    defer testing.allocator.free(user_pass);
    try testing.expectEqualStrings(user_pass, "dXNlcjo=");
}
