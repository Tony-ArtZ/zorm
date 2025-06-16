const std = @import("std");
const parser = @import("../parser.zig");

// Import libpq (PostgreSQL C client library)
const c = @cImport({
    @cInclude("postgresql/libpq-fe.h");
});

pub const PGError = error{
    ConnectionFailed,
    QueryFailed,
    InvalidModel,
    AllocationFailed,
    FormatFailed,
};

const query_builder = @import("../query_builder.zig");
pub const QueryBuilder = query_builder.QueryBuilder;
pub const OrderDirection = query_builder.OrderDirection;
pub const ComparisonOperator = query_builder.ComparisonOperator;

pub const PG = struct {
    allocator: std.mem.Allocator,
    conn: ?*c.PGconn = null,

    pub fn init(allocator: std.mem.Allocator) PG {
        return PG{
            .allocator = allocator,
            .conn = null,
        };
    }

    pub fn queryBuilder(self: *PG, comptime model_meta: parser.ModelMeta) !QueryBuilder {
        return QueryBuilder.initWithMeta(self.allocator, &model_meta);
    }

    pub fn connect(self: *PG, conninfo: []const u8) !void {
        const c_conninfo = try self.allocator.dupeZ(u8, conninfo);
        defer self.allocator.free(c_conninfo);

        self.conn = c.PQconnectdb(c_conninfo.ptr);
        if (c.PQstatus(self.conn) != c.CONNECTION_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Connection to database failed: {s}\n", .{err_msg});
            c.PQfinish(self.conn);
            self.conn = null;
            return PGError.ConnectionFailed;
        }
    }

    pub fn disconnect(self: *PG) void {
        if (self.conn) |conn| {
            c.PQfinish(conn);
            self.conn = null;
        }
    }

    // Unified CRUD API
    pub fn createTable(self: *PG, comptime model_meta: parser.ModelMeta) !void {
        if (self.conn == null) return PGError.ConnectionFailed;

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

        const result = c.PQexec(self.conn, c_query.ptr);
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Create table failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query.items});
            return PGError.QueryFailed;
        }
    }

    pub fn insert(self: *PG, comptime T: type, value: T) !void {
        if (self.conn == null) return PGError.ConnectionFailed;

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

        const result = c.PQexec(self.conn, c_query.ptr);
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Insert failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query.items});
            return PGError.QueryFailed;
        }
    }

    pub fn update(self: *PG, builder: *QueryBuilder) !void {
        if (self.conn == null) return PGError.ConnectionFailed;

        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();

        try builder.buildUpdateQuery(&query_text);

        const c_query = try self.allocator.dupeZ(u8, query_text.items);
        defer self.allocator.free(c_query);

        const result = c.PQexec(self.conn, c_query.ptr);
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Update failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query_text.items});
            return PGError.QueryFailed;
        }
    }

    pub fn delete(self: *PG, builder: *QueryBuilder) !void {
        if (self.conn == null) return PGError.ConnectionFailed;

        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();

        try builder.buildDeleteQuery(&query_text);

        const c_query = try self.allocator.dupeZ(u8, query_text.items);
        defer self.allocator.free(c_query);

        const result = c.PQexec(self.conn, c_query.ptr);
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Delete failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query_text.items});
            return PGError.QueryFailed;
        }
    }

    pub fn select(self: *PG, comptime T: type, builder: *QueryBuilder) ![]T {
        if (self.conn == null) return PGError.ConnectionFailed;

        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();

        try builder.buildSelectQuery(&query_text);

        const c_query = try self.allocator.dupeZ(u8, query_text.items);
        defer self.allocator.free(c_query);

        const result = c.PQexec(self.conn, c_query.ptr);
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("SELECT query failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query_text.items});
            return PGError.QueryFailed;
        }

        const rows = c.PQntuples(result);
        const cols = c.PQnfields(result);

        if (rows < 0) {
            std.debug.print("SELECT returned negative row count: {}\n", .{rows});
            return PGError.QueryFailed;
        }
        var out = try self.allocator.alloc(T, @intCast(rows));
        for (0..@intCast(rows)) |i| {
            var item: T = undefined;
            const fields = std.meta.fields(T);
            inline for (fields, 0..) |field, j| {
                if (j >= cols) break;
                if (c.PQgetisnull(result, @intCast(i), @intCast(j)) != 0) {
                    if (field.type == []const u8) {
                        @field(item, field.name) = try self.allocator.dupe(u8, "");
                    } else {
                        @field(item, field.name) = undefined;
                    }
                } else {
                    const value = c.PQgetvalue(result, @intCast(i), @intCast(j));
                    if (field.type == []const u8) {
                        const src_text = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
                        @field(item, field.name) = try self.allocator.dupe(u8, src_text);
                    } else if (field.type == i32 or field.type == u32) {
                        const src_text = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
                        if (field.type == i32) {
                            @field(item, field.name) = std.fmt.parseInt(i32, src_text, 10) catch 0;
                        } else {
                            @field(item, field.name) = std.fmt.parseInt(u32, src_text, 10) catch 0;
                        }
                    } else {
                        @field(item, field.name) = undefined;
                    }
                }
            }
            out[i] = item;
        }
        return out;
    }

    pub fn freeResults(self: *PG, comptime T: type, results: []T) void {
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
