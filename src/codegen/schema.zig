const std = @import("std");

pub const TypeKind = enum {
    SCALAR,
    OBJECT,
    INPUT_OBJECT,
    ENUM,
    INTERFACE,
    UNION,
    LIST,
    NON_NULL,
};

pub const Schema = struct {
    __schema: SchemaData,
};

pub const SchemaData = struct {
    types: []Type,
};

pub const Type = struct {
    kind: TypeKind,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    fields: ?[]Field = null,
    inputFields: ?[]InputValue = null,
    enumValues: ?[]EnumValue = null,
};

pub const Field = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    args: []InputValue,
    type: TypeRef,
    isDeprecated: bool,
    deprecationReason: ?[]const u8 = null,
};

pub const InputValue = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    type: TypeRef,
    defaultValue: ?[]const u8 = null,
};

pub const EnumValue = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    isDeprecated: bool,
    deprecationReason: ?[]const u8 = null,
};

pub const TypeRef = struct {
    kind: TypeKind,
    name: ?[]const u8 = null,
    ofType: ?*TypeRef = null,
};
