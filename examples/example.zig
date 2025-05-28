// Example usage of the ZORM library with generated schema
const std = @import("std");
const zorm = @import("zorm");
const schema = @import("generated_schema.zig"); // Generated from schema.zorm
const PG = zorm.pg.PG;
const SQLITE = zorm.SQLITE;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize PostgreSQL backend
    var pg = SQLITE.init(allocator);
    defer pg.disconnect();

    // Connect to database
    // Replace with your actual connection string
    const conninfo = "test.db";
    try pg.connect(conninfo);

    // Create the User table
    try pg.createTable(schema.UserMeta);

    // Create a user instance
    const user = schema.User{
        .id = "1",
        .name = "John Doe",
        .email = "john@example.com",
        .age = "30",
    };

    // Insert the user
    try pg.insert(schema.User, user);

    std.debug.print("User inserted successfully!\n", .{});
}
