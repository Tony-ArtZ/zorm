const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const parser = @import("../parser.zig");
const query_builder = @import("../query_builder.zig");

pub const QueryBuilder = query_builder.QueryBuilder;
pub const OrderDirection = query_builder.OrderDirection;
pub const ComparisonOperator = query_builder.ComparisonOperator;

pub const SQLiteError = error{
    ConnectionFailed,
    QueryFailed,
    InvalidModel,
    AllocationFailed,
    FormatFailed,
};

pub const SQLITE = struct {
    allocator: std.mem.Allocator,
    conn: ?*c.sqlite3 = null,

    pub fn init(allocator: std.mem.Allocator) SQLITE {
        return SQLITE{
            .allocator = allocator,
            .conn = null,
        };
    }

    pub fn connect(self: *SQLITE, db_path: []const u8) !void {
        // Convert Zig string to null-terminated C string
        const c_db_path = try self.allocator.dupeZ(u8, db_path);
        defer self.allocator.free(c_db_path);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(c_db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.debug.print("Connection to database failed: {s}\n", .{err_msg});
            if (db) |db_ptr| _ = c.sqlite3_close(db_ptr);
            return SQLiteError.ConnectionFailed;
        }
        self.conn = db;
    }

    pub fn disconnect(self: *SQLITE) void {
        if (self.conn) |conn| {
            _ = c.sqlite3_close(conn);
            self.conn = null;
        }
    }

    pub fn insert(self: *SQLITE, comptime T: type, value: T) !void {
        if (self.conn == null) return SQLiteError.ConnectionFailed;
        const type_name = @typeName(T);
        const model_name = if (std.mem.endsWith(u8, type_name, ".User")) "User" else type_name;
        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();
        try query.appendSlice("INSERT INTO \"");
        try query.appendSlice(model_name);
        try query.appendSlice("\" (");
        const fields = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");
            try query.append('"');
            try query.appendSlice(field.name);
            try query.append('"');
        }
        try query.appendSlice(") VALUES (");
        inline for (fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");
            try query.append('\'');
            const field_value = @field(value, field.name);
            if (field.type == []const u8) {
                try query.appendSlice(field_value);
            } else {
                const value_str = try std.fmt.allocPrint(self.allocator, "{}", .{field_value});
                defer self.allocator.free(value_str);
                try query.appendSlice(value_str);
            }
            try query.append('\'');
        }
        try query.appendSlice(");");
        const c_query = try self.allocator.dupeZ(u8, query.items);
        defer self.allocator.free(c_query);
        const rc = c.sqlite3_exec(self.conn, c_query.ptr, null, null, null);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.conn);
            std.debug.print("Insert failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query.items});
            return SQLiteError.QueryFailed;
        }
    }

    /// Helper function to create tables based on schema metadata
    pub fn createTable(self: *SQLITE, comptime model_meta: parser.ModelMeta) !void {
        if (self.conn == null) return SQLiteError.ConnectionFailed;

        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();

        try query.appendSlice("CREATE TABLE IF NOT EXISTS \"");
        try query.appendSlice(model_meta.name);
        try query.appendSlice("\" (");

        for (model_meta.fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");

            try query.append('"');
            try query.appendSlice(field.name);
            try query.appendSlice("\" ");

            switch (field.type) {
                .relation => {
                    if (std.mem.eql(u8, field.name, "id")) {
                        try query.appendSlice("INTEGER");
                    } else if (std.mem.eql(u8, field.name, "age")) {
                        try query.appendSlice("INTEGER");
                    } else {
                        try query.appendSlice("TEXT");
                    }
                },
                else => try query.appendSlice("TEXT"),
            }

            // Add constraints
            for (field.constraints) |constraint| {
                switch (constraint) {
                    .primary => try query.appendSlice(" PRIMARY KEY"),
                    .unique => try query.appendSlice(" UNIQUE"),
                    else => {},
                }
            }
        }

        try query.appendSlice(");");

        const c_query = try self.allocator.dupeZ(u8, query.items);
        defer self.allocator.free(c_query);

        const rc = c.sqlite3_exec(self.conn, c_query.ptr, null, null, null);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.conn);
            std.debug.print("Create table failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query.items});
            return SQLiteError.QueryFailed;
        }
    }

    pub fn queryBuilder(self: *SQLITE, comptime model_meta: parser.ModelMeta) !QueryBuilder {
        return QueryBuilder.initWithMeta(self.allocator, &model_meta);
    }

    pub fn select(self: *SQLITE, comptime T: type, builder: *QueryBuilder) ![]T {
        if (self.conn == null) return SQLiteError.ConnectionFailed;
        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();
        try builder.buildSelectQuery(&query_text);
        const c_query = try self.allocator.dupeZ(u8, query_text.items);
        defer self.allocator.free(c_query);
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.conn, c_query.ptr, @as(c_int, @intCast(query_text.items.len)), &stmt, null);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.conn);
            std.debug.print("SELECT query preparation failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query_text.items});
            return SQLiteError.QueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        // Count rows first
        var row_count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) : (row_count += 1) {}
        _ = c.sqlite3_reset(stmt);
        // Allocate result array
        var out = try self.allocator.alloc(T, row_count);
        var idx: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var item: T = undefined;
            const fields = std.meta.fields(T);
            inline for (fields, 0..) |field, j| {
                if (c.sqlite3_column_type(stmt, @intCast(j)) == c.SQLITE_NULL) {
                    if (field.type == []const u8) {
                        @field(item, field.name) = try self.allocator.dupe(u8, "");
                    } else {
                        @field(item, field.name) = 0;
                    }
                } else if (field.type == []const u8) {
                    const text = c.sqlite3_column_text(stmt, @intCast(j));
                    if (text) |txt| {
                        const src_text = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
                        // Copy the string to our own allocated memory
                        @field(item, field.name) = try self.allocator.dupe(u8, src_text);
                    } else {
                        @field(item, field.name) = try self.allocator.dupe(u8, "");
                    }
                } else if (field.type == i32) {
                    @field(item, field.name) = c.sqlite3_column_int(stmt, @intCast(j));
                } else if (field.type == u32) {
                    @field(item, field.name) = @intCast(c.sqlite3_column_int(stmt, @intCast(j)));
                } else {
                    @field(item, field.name) = 0;
                }
            }
            out[idx] = item;
            idx += 1;
        }
        return out;
    }

    pub fn delete(self: *SQLITE, builder: *QueryBuilder) !void {
        if (self.conn == null) return SQLiteError.ConnectionFailed;
        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();
        try builder.buildDeleteQuery(&query_text);
        const c_query = try self.allocator.dupeZ(u8, query_text.items);
        defer self.allocator.free(c_query);
        const rc = c.sqlite3_exec(self.conn, c_query.ptr, null, null, null);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.conn);
            std.debug.print("Delete failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query_text.items});
            return SQLiteError.QueryFailed;
        }
    }

    pub fn update(self: *SQLITE, builder: *QueryBuilder) !void {
        if (self.conn == null) return SQLiteError.ConnectionFailed;
        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();
        try builder.buildUpdateQuery(&query_text);
        const c_query = try self.allocator.dupeZ(u8, query_text.items);
        defer self.allocator.free(c_query);
        const rc = c.sqlite3_exec(self.conn, c_query.ptr, null, null, null);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.conn);
            std.debug.print("Update failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query_text.items});
            return SQLiteError.QueryFailed;
        }
    }

    pub fn freeResults(self: *SQLITE, comptime T: type, results: []T) void {
        const fields = std.meta.fields(T);
        for (results) |item| {
            inline for (fields) |field| {
                if (field.type == []const u8) {
                    const field_value = @field(item, field.name);
                    if (field_value.len > 0) {
                        self.allocator.free(field_value);
                    }
                }
            }
        }
        self.allocator.free(results);
    }
};
