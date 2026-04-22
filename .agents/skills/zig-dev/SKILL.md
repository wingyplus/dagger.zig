---
name: zig-dev
description: >
  Zig programming language development guidance for Zig 0.16+. Use this skill
  whenever writing, reviewing, or debugging Zig code — including idiomatic
  patterns, memory management, error handling, comptime, the build system, and
  common pitfalls. Trigger on any Zig coding task, even if the user doesn't
  explicitly ask for "Zig guidance."
---

# Zig Development Guide (0.16+)

## Error Handling

Zig uses explicit error unions (`!T`) instead of exceptions.

- `try expr` propagates errors up — equivalent to `expr catch |err| return err`
- `catch` handles or transforms an error inline
- `errdefer` runs cleanup only on the error path, after a successful allocation

```zig
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}
```

Define error sets explicitly at stable API boundaries. Inferred error sets (`!T`) are fine for internal functions. Avoid `anyerror` except at true boundaries.

## Memory Management

Zig has no GC. Every allocation needs a corresponding free on every exit path.

- Always accept `std.mem.Allocator` as a parameter — never use a global
- `defer allocator.free(x)` — frees on all exit paths
- `errdefer allocator.free(x)` — frees only on error paths (pair with `defer` after the point of no return)
- `std.heap.ArenaAllocator` — allocate freely, free everything at once with `arena.deinit()`; ideal for request-scoped or short-lived data
- Prefer `std.ArrayListUnmanaged` in structs — the struct shouldn't store an allocator

```zig
// Arena for short-lived data
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const a = arena.allocator();

// errdefer before defer: free only if something fails after allocation
const buf = try allocator.alloc(u8, size);
errdefer allocator.free(buf);
try populate(buf);  // if this fails, errdefer frees buf
defer allocator.free(buf);  // on success, defer frees buf at scope exit
```

## I/O (Zig 0.16)

Zig 0.16 uses `std.Io` (capital I) as the I/O abstraction. Key types:

- `std.Io.Writer` — the writer interface; pass as `*std.Io.Writer`
- `std.Io.Writer.Allocating` — a writer that collects output into allocated memory

```zig
var aw: std.Io.Writer.Allocating = .init(allocator);
errdefer {
    var al = aw.toArrayList();
    al.deinit(allocator);
}
try aw.writer.writeAll("hello");
var list = aw.toArrayList();
defer list.deinit(allocator);
// list.items is the collected output
```

Pass `std.Io` through your call chain rather than creating it at call sites.

## JSON (Zig 0.16)

```zig
// Parse — leaky variant lets the allocator own the memory directly
const val = try std.json.parseFromSliceLeaky(std.json.Value, allocator, input, .{});

// Stringify
var out: std.Io.Writer.Allocating = .init(allocator);
var s = std.json.Stringify{ .writer = &out.writer };
try s.write(my_value);
```

`std.json.Value` is a tagged union: `.object`, `.array`, `.string`, `.integer`, `.float`, `.bool`, `.null`.

## Environment (Zig 0.16)

```zig
// Build an env map and look up keys
var env = std.process.Environ.Map.init(allocator);
defer env.deinit();
const token = env.get("MY_TOKEN") orelse return error.MissingToken;
```

In tests, use `testing.environ.getAlloc(testing.allocator, "KEY")` to read env vars.

## Comptime

Use `comptime` for generic behavior and type-level logic with zero runtime cost.

- `comptime T: type` makes functions generic
- `@TypeOf(x)` gets an expression's type at compile time
- `inline for` over a comptime tuple/array unrolls at compile time
- `@hasField`, `@hasDecl`, `@typeInfo` enable compile-time reflection

```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}
```

Reach for comptime when you need type parameterization. Prefer a plain function or tagged union when that's simpler.

## Slices, Arrays, and Strings

- `[N]T` — fixed-size array, size known at compile time
- `[]T` / `[]const T` — slice (pointer + length); the idiomatic choice for function parameters
- String literals are `[]const u8`
- `std.mem.eql(u8, a, b)` for string comparison (no `==` on slices)

```zig
fn greet(name: []const u8) void {
    std.debug.print("Hello, {s}!\n", .{name});
}
```

## Optionals

`?T` for values that may be absent.

```zig
const val = maybe orelse return error.NotFound;
if (config.timeout) |t| { /* use t */ }
```

## Tagged Unions

`union(enum)` for sum types. Always switch exhaustively.

```zig
const Token = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,
};

switch (token) {
    .string => |s| ...,
    .int => |n| ...,
    .boolean => |b| ...,
}
```

## Build System (build.zig)

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "mylib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
```

Use `b.addModule` for modules consumed by other build targets. Use `b.path(...)` for source file paths rather than string literals.

## Testing

```zig
const testing = std.testing;

test "my feature" {
    try testing.expectEqual(42, compute());
    try testing.expectEqualStrings("hello", result);
    try testing.expectError(error.NotFound, lookup("missing"));
}
```

- Tests live alongside the source in the same file or in `src/test_*.zig`
- Use `std.testing.allocator` — it detects leaks automatically
- For environment-dependent tests, guard with `testing.environ.getAlloc` and skip if the env var is absent

## Common Pitfalls

- **Use-after-free**: slices into freed memory are UB. Ownership must be clear at every callsite.
- **Integer overflow**: Debug/ReleaseSafe trap on overflow. Use `+%` (wrapping), `+|` (saturating), or `std.math.add` explicitly when overflow is expected.
- **Sentinel-terminated strings for C**: C FFI needs `[*:0]const u8`. Use `std.mem.span()` to go from a sentinel pointer to a slice.
- **`unreachable` vs `@panic`**: `unreachable` becomes UB in ReleaseFast — use it only when a branch is genuinely impossible. Use `@panic("message")` for explicit runtime errors.
- **Scope of `defer`**: `defer` runs at the end of the enclosing block, not the function. Declare it in the right scope.

## Style

- Functions and variables: `camelCase`
- Types and structs: `PascalCase`
- Constants: `SCREAMING_SNAKE_CASE` only for true compile-time constants from C headers; otherwise `camelCase`
- Prefer `const` over `var`; only use `var` when mutation is required
- Avoid abbreviations unless they're universally known (`idx`, `buf`, `alloc` are fine)
