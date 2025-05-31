// Example usage of the ZORM library with generated schema
const std = @import("std");
const zorm = @import("zorm");
const schema = @import("generated_schema.zig"); // Generated from schema.zorm
const SQLITE = zorm.SQLITE;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize PostgreSQL backend
    var db = SQLITE.init(allocator);
    defer db.disconnect();

    // Connect to database
    // Replace with your actual connection string
    const conninfo = "test.db";
    try db.connect(conninfo);

    // Create the User table
    try db.createTable(schema.UserMeta);

    // Create a user instance
    const user = schema.User{
        .id = "1",
        .name = "John Doe",
        .email = "john@example.com",
        .age = "30",
    };

    // Insert the user
    try db.insert(schema.User, user);

    std.debug.print("User inserted successfully!\n", .{});
}
