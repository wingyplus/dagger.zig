const std = @import("std");
const json = std.json;

test {
    _ = @import("./graphql.zig");
}

test "parse json" {
    const json_data =
        \\{
        \\  "data": {
        \\    "exec": "Hello"
        \\  }
        \\}
    ;

    const ExecResult = struct {
        exec: []const u8,
    };
    _ = ExecResult;

    const GraphQLResponse = struct {
        data: json.Value,
    };

    var parsed = try json.parseFromSlice(GraphQLResponse, std.testing.allocator, json_data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // const graphql_response: GraphQLResponse = parsed.value;
    // const value = graphql_response.data;
    // try std.testing.expectEqualStrings("Hello", value.string);
}
