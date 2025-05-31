// Example usage of the ZORM query builder with PostgreSQL database
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
    const conninfo = "test.db";
    try db.connect(conninfo);

    // Create the User table
    try db.createTable(schema.UserMeta);

    // Insert some sample users
    const user1 = schema.User{
        .id = "1",
        .name = "Alice Smith",
        .email = "alice@example.com",
        .age = "25",
    };

    const user2 = schema.User{
        .id = "2",
        .name = "Bob Johnson",
        .email = "bob@example.com",
        .age = "17",
    };

    const user3 = schema.User{
        .id = "3",
        .name = "Charlie Brown",
        .email = "charlie@example.com",
        .age = "30",
    };

    try db.insert(schema.User, user1);
    try db.insert(schema.User, user2);
    try db.insert(schema.User, user3);

    std.debug.print("Sample users inserted successfully!\n\n", .{});

    // Now demonstrate query builder usage
    var qb = try zorm.QueryBuilder.init(allocator, &schema.UserMeta);
    defer qb.deinit();

    // Build a simple SELECT query with WHERE condition
    _ = try qb.selectAll();
    _ = try qb.where("age", zorm.ComparisonOperator.GT, "18");
    _ = try qb.orderBy("name", zorm.OrderDirection.ASC);
    _ = qb.limit(10);

    var query_buf = std.ArrayList(u8).init(allocator);
    defer query_buf.deinit();
    try qb.buildSelectQuery(&query_buf);
    std.debug.print("Generated SELECT query: {s}\n", .{query_buf.items});

    // Execute the query using the query builder
    const results = try db.select(schema.User, &qb);
    defer db.allocator.free(results);

    std.debug.print("\nQuery results (users over 18):\n", .{});
    for (results) |user| {
        std.debug.print("ID: {s}, Name: {s}, Email: {s}, Age: {s}\n", .{ user.id, user.name, user.email, user.age });
    }
}
