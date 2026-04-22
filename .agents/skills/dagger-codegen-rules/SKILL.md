---
name: dagger-codegen-rules
description: >
  Rules for implementing Dagger SDK codegen from GraphQL introspection schema,
  targeted at the Zig SDK. Use whenever writing or modifying the Zig codegen
  pipeline — covering schema traversal, type classification, naming conventions,
  TypeRef unwrapping, arg splitting, and the return-value decision tree.
  Trigger on: codegen, SDK bindings, introspection schema, generate types from
  GraphQL, iterate types, iterate fields, enum codegen, object codegen,
  dagger.zig codegen, generate Zig bindings.
---

# Dagger SDK Codegen Rules (Zig)

Rules distilled from `cmd/codegen` (Go) and `sdk/elixir/dagger_codegen` (Elixir).
The traversal and classification rules are the same across all SDKs; naming
conventions are Zig-specific.

---

## 1. Schema Data Model

The introspection JSON response contains a `__schema` object with a `types` array.
Each entry is a **Type**:

```
Type:
  kind        — SCALAR | OBJECT | INPUT_OBJECT | ENUM | INTERFACE | UNION | LIST | NON_NULL
  name        — GraphQL identifier string
  description — documentation string
  fields      — []Field       (OBJECT types only)
  inputFields — []InputValue  (INPUT_OBJECT types only)
  enumValues  — []EnumValue   (ENUM types only)
```

A **Field** (method on an object):
```
Field:
  name              — GraphQL identifier
  description       — documentation string
  type              — TypeRef (return type)
  args              — []InputValue
  isDeprecated      — bool
  deprecationReason — string | null
```

An **InputValue** (argument or input-object field):
```
InputValue:
  name         — GraphQL identifier
  description  — documentation string
  type         — TypeRef
  defaultValue — string | null   (JSON-encoded; null means no default)
```

An **EnumValue**:
```
EnumValue:
  name              — GraphQL identifier (e.g. "SHARED")
  description       — documentation string
  isDeprecated      — bool
  deprecationReason — string | null
```

A **TypeRef** is a recursive structure encoding nullability and nesting:
```
TypeRef:
  kind   — NON_NULL | LIST | SCALAR | OBJECT | ENUM | INPUT_OBJECT
  name   — string (only set for concrete kinds, not NON_NULL/LIST)
  ofType — TypeRef | null (the wrapped type for NON_NULL and LIST)
```

---

## 2. Traversal Order and Filtering

### What to skip (always)

- Types whose name starts with `_` (internal GraphQL types)
- Built-in scalar types: `String`, `Float`, `Int`, `Boolean`, `DateTime`, `ID`

### Visit order

Process types in this exact sequence (sort alphabetically by name within each group):

1. **SCALAR** (custom scalars only, after skipping built-ins above)
2. **INPUT_OBJECT**
3. **OBJECT**
4. **ENUM**

### Sorting within a type

Before generating code for a type, sort its `fields` and `inputFields` alphabetically
by name. This produces deterministic output.

### Codegen entry point

```
for type in schema.types:
  skip if name starts with "_"
  skip if name in [String, Float, Int, Boolean, DateTime, ID]
  sort type.fields by name
  sort type.inputFields by name
  dispatch to generate_scalar / generate_object / generate_input / generate_enum
```

---

## 3. TypeRef Helpers

Use these predicates throughout code generation.

**is_optional(typeref)** — true if outermost kind is NOT `NON_NULL`.

**is_scalar(typeref)** — unwrap `NON_NULL`, true if kind is `SCALAR`.

**is_enum(typeref)** — unwrap `NON_NULL`, true if kind is `ENUM`.

**is_object(typeref)** — unwrap `NON_NULL`, true if kind is `OBJECT`.

**is_list(typeref)** — unwrap `NON_NULL`, true if kind is `LIST`.

**is_void(typeref)** — unwrap `NON_NULL`, true if kind is `SCALAR` and name is `"Void"`.

**is_id_type(typeref)** — unwrap `NON_NULL`, true if kind is `SCALAR` and name ends with `"ID"`.

**is_list_of(typeref, element_kind)** — true for the pattern:
`NON_NULL → LIST → NON_NULL → <element_kind>` or `LIST → NON_NULL → <element_kind>`.

**unwrap(typeref)** — strip `NON_NULL` and `LIST` wrappers to reach the base concrete type.

### Typical TypeRef shapes

| GraphQL type      | TypeRef chain                          |
|-------------------|----------------------------------------|
| `String!`         | NON_NULL → SCALAR("String")            |
| `String`          | SCALAR("String")                       |
| `[String!]!`      | NON_NULL → LIST → NON_NULL → SCALAR    |
| `Container!`      | NON_NULL → OBJECT("Container")         |
| `ContainerID!`    | NON_NULL → SCALAR("ContainerID")       |
| `[EnvVariable!]!` | NON_NULL → LIST → NON_NULL → OBJECT    |

---

## 4. Argument Classification

For any field's `args`, split into two groups:

**required_args** — `arg.type.kind == "NON_NULL"` AND `arg.defaultValue == null`
**optional_args** — `arg.type.kind != "NON_NULL"` OR `arg.defaultValue != null`

In the generated function signature, required args come first as explicit parameters;
optional args are grouped into a single optional struct parameter.

---

## 5. Special Type: Query → Client

The `"Query"` type is the GraphQL root. Map it to the Zig client type (e.g. `Client`).
Fields on `Query` become top-level `Client` methods.

---

## 6. Return Value Decision Tree

For each field, inspect `field.type` top-to-bottom:

```
1. is_void(type)
   → Execute the query; return void / error union.

2. is_list_of(type, "OBJECT")
   → Execute; for each item fetch its "id" value;
     reconstruct each as a lazy object via loadXFromID query. (see §7)

3. is_id_type(type)
     AND base_name_without_"ID" == parent_object_name
     AND field.name != "id"
   → ID conversion: execute to get the ID string, then construct a lazy
     object via loadXFromID. (see §7)

4. is_scalar(type)  [covers remaining scalars]
   → Execute the query; return the scalar value directly.

5. is_list_of(type, "SCALAR") OR is_list_of(type, "ENUM")
   → Execute; return the list (map enum wire strings through a parse function).

6. is_enum(type)
   → Execute; map the returned string through the enum's parse function.

7. is_object(type)  [default: object chaining]
   → Do NOT execute. Return a new lazy object with the field appended to
     the current query builder. The object holds a query_builder + client ref.
```

---

## 7. Load-from-ID Pattern

When a field returns a list of objects, or an ID scalar identifying the parent type,
reconstruct objects lazily via:

```
loadXFromID(id: XID!) → X
```

Example for `[EnvVariable!]!`:
1. Execute query selecting `envVariables { id }`
2. For each returned `id` string, build: `query → loadEnvVariableFromID(id: id)`
3. Return a list of lazy `EnvVariable` objects holding that builder

---

## 8. Naming Conventions (Zig)

Zig naming rules (from the language spec):

| Element | Convention | Example |
|---------|-----------|---------|
| Types, structs | `PascalCase` | `Container`, `EnvVariable` |
| Functions, methods | `camelCase` | `withExec`, `from`, `stdout` |
| Fields, variables | `camelCase` | `queryBuilder`, `sessionToken` |
| Enum tags | `camelCase` | `.shared`, `.private` |

### Mapping GraphQL names to Zig

**Type names** (Object, InputObject, Enum, Scalar):
- GraphQL names are already PascalCase — use as-is.
- `Query` → `Client`.

**Field / function names**:
- GraphQL field names are already camelCase — use as-is.
- Example: `withExec` → `withExec`, `envVariables` → `envVariables`.

**Enum value names**:
- GraphQL enum values are SCREAMING_SNAKE_CASE (e.g. `CACHE_VOLUME`).
- Convert to camelCase for Zig enum tags: `CACHE_VOLUME` → `.cacheVolume`,
  `SHARED` → `.shared`.
- Generate a `fromString([]const u8) !EnumName` function that maps wire strings
  back to enum tags.

**Argument / input field names**:
- GraphQL args are camelCase — use as-is.

---

## 9. Scalar Generation

Custom scalars are opaque string wrappers. Generate a Zig type alias or
single-field struct over `[]const u8`, preserving the GraphQL name:

```zig
pub const Platform = struct { value: []const u8 };
```

---

## 10. Input Object Generation

For each `INPUT_OBJECT` type, generate a Zig struct with:
- One field per `inputField`, named in camelCase (same as GraphQL name)
- Optional inputFields (`is_optional == true`): type is `?T`
- Required inputFields: type is `T` (non-null)

```zig
pub const BuildArg = struct {
    name: []const u8,
    value: []const u8,
};
```

---

## 11. Enum Generation

For each `ENUM` type:
1. Generate a Zig `enum` with a camelCase tag per value.
2. Generate a `fromString([]const u8) !EnumName` function.

```zig
pub const CacheSharingMode = enum {
    shared,
    private,
    locked,

    pub fn fromString(s: []const u8) !CacheSharingMode {
        if (std.mem.eql(u8, s, "SHARED")) return .shared;
        if (std.mem.eql(u8, s, "PRIVATE")) return .private;
        if (std.mem.eql(u8, s, "LOCKED")) return .locked;
        return error.UnknownEnumValue;
    }
};
```

---

## 12. Object Generation

For each `OBJECT` type, generate a Zig struct that holds:
- A `query_builder: QueryBuilder` accumulator
- A `client: *Client` reference (used to execute when a leaf is reached)

For each field in `type.fields` (sorted alphabetically):
- Generate a method following §4 (arg splitting) and §6 (return value decision tree).
- Required args become explicit parameters.
- Optional args become an optional struct parameter (defaulting to empty/null).
- If the type has an `id` field, implement serialization for ID-based chaining.

If a field is deprecated, emit a comment above the function with the reason.

---

## Quick Reference

| Situation | Rule |
|-----------|------|
| Type name starts with `_` | Skip |
| Type is String/Float/Int/Boolean/DateTime/ID | Skip |
| Type is `Query` | Rename to `Client` |
| Field returns `Void` | Execute → return `void` |
| Field returns list of objects | Execute → reconstruct each via `loadXFromID` |
| Field returns `TypeNameID` (self-referencing ID scalar) | Execute → wrap in `loadXFromID` lazy object |
| Field returns any other scalar | Execute → return value directly |
| Field returns enum | Execute → map through `fromString` |
| Field returns object | Don't execute → return lazy object with extended query builder |
| Arg: NON_NULL + no defaultValue | Required arg |
| Arg: nullable or has defaultValue | Optional arg |
| GraphQL type name | PascalCase (use as-is) |
| GraphQL field/arg name | camelCase (use as-is) |
| GraphQL enum value (SCREAMING_SNAKE) | camelCase Zig tag (e.g. `.cacheVolume`) |
