// Generated file - Do not edit manually
// Generated from schema.zorm

const std = @import("std");
const zorm = @import("zorm");

pub const FieldType = zorm.FieldType;
pub const Constraint = zorm.Constraint;
pub const DatabaseType = zorm.DatabaseType;

pub const MetaField = zorm.parser.MetaField;

pub const ModelMeta = zorm.parser.ModelMeta;

pub const DATABASE_TYPE = DatabaseType.postgres;

pub const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    age: []const u8,
};

pub const UserMeta = ModelMeta{
    .name = "User",
    .fields = &[_]MetaField{
        .{ .name = "id", .type = .relation, .constraints = &[_]Constraint{.primary} },
        .{ .name = "name", .type = .relation, .constraints = &[_]Constraint{} },
        .{ .name = "email", .type = .relation, .constraints = &[_]Constraint{.unique} },
        .{ .name = "age", .type = .relation, .constraints = &[_]Constraint{} },
    },
};

pub const Models = union(enum) {
    user: User,
};

pub const MODEL_NAMES = [_][]const u8{
    "User",
};
