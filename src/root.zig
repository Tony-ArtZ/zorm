// Main library entry point for zorm
const std = @import("std");

pub const parser = @import("parser.zig");
pub const generator = @import("generator.zig");

// Backend modules
pub const pg = @import("backends/pg.zig");
pub const sqlite = @import("backends/sqlite.zig");
pub const queryBuilder = @import("query_builder.zig");

// Re-export commonly used types for generated schemas
pub const FieldType = parser.FieldType;
pub const Constraint = parser.Constraint;
pub const DatabaseType = parser.DatabaseType;

// Re-export commonly used types for library users
pub const PG = pg.PG;
pub const SQLITE = sqlite.SQLITE;
pub const QueryBuilder = queryBuilder.QueryBuilder;

// Re-export QueryBuilder enums
pub const OrderDirection = queryBuilder.OrderDirection;
pub const ComparisonOperator = queryBuilder.ComparisonOperator;
pub const LogicalOperator = queryBuilder.LogicalOperator;
pub const WhereCondition = queryBuilder.WhereCondition;
pub const OrderByClause = queryBuilder.OrderByClause;
test {
    std.testing.refAllDecls(@This());
}
