// Main library entry point for zorm
const std = @import("std");

pub const db = @import("db.zig");
pub const parser = @import("parser.zig");
pub const generator = @import("generator.zig");

// Backend modules
pub const pg = @import("backends/pg.zig");
pub const sqlite = @import("backends/sqlite.zig");

// Re-export commonly used types for generated schemas
pub const FieldType = parser.FieldType;
pub const Constraint = parser.Constraint;
pub const DatabaseType = parser.DatabaseType;

// Re-export commonly used types for library users
pub const DB = db.DB;
pub const PG = pg.PG;
pub const SQLITE = sqlite.SQLITE;

test {
    std.testing.refAllDecls(@This());
}
